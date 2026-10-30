import AVFoundation
import CoreAudio
import SpellsKit

/// One recording: your mic (AVAudioEngine) and the system audio (a process tap that leaves this process
/// out), both converted to 16 kHz mono s16le and stream-written as a 2-channel WAV (ch 0 mic, ch 1 system;
/// ch 1 stays silent without the tap). The two sources are queued per channel and written in step; on
/// stop the shorter is padded with silence. `onMic` / `onSystem` get the same PCM for the live sockets.
/// All buffer work runs on `q`.
final class ScryRecorder: @unchecked Sendable {
    struct Stats { var frames: Int; var micSamples: Int; var systemSamples: Int; var micRMS: Double; var systemRMS: Double
                   var systemAllZero: Bool }
    struct TapFailed: Error, CustomStringConvertible { var step: String; var status: OSStatus
                                                      var description: String { "\(step) failed (\(status))" } }

    // On `q` (read per chunk); set with `feed`, which may run mid-recording.
    private var onMic: (@Sendable (Data) -> Void)?, onSystem: (@Sendable (Data) -> Void)?
    func feed(mic: (@Sendable (Data) -> Void)?, system: (@Sendable (Data) -> Void)?) {
        q.async { self.onMic = mic; self.onSystem = system }
    }

    private let q = DispatchQueue(label: "dev.nic.spells.scry.recorder")
    /// Replaced on restart: after a device change the old engine's input keeps its stale format (-10868).
    private var engine = AVAudioEngine()
    private let wav: ScryWAV
    private var configObserver: (any NSObjectProtocol)?
    private var tap = AudioObjectID(kAudioObjectUnknown), agg = AudioObjectID(kAudioObjectUnknown), proc: AudioDeviceIOProcID?
    // On `q`:
    private var mic: [Int16] = [], sys: [Int16] = [], withSystem = false, running = true
    private var sumSq = (0.0, 0.0), received = (0, 0), sysNonZero = false
    private var lastLevel = (0.0, 0.0)   // the latest chunk's level per channel, 0…1 (for the pill's bars)

    /// The louder side right now (you or the call), 0…1 on a −50…0 dBFS scale.
    var level: Double { q.sync { max(lastLevel.0, lastLevel.1) } }
    // Guarded by `tapLock`: creating the tap blocks while its permission prompt is up, so it may still be
    // in flight (on `tapQ`) when `stop` runs; whoever finishes last tears it down.
    private let tapLock = NSLock()
    private var tapStarting = false, tapStopped = false
    /// All tap setup/teardown runs here, one job at a time (start, rebuilds, device-change listeners).
    private let tapQ = DispatchQueue(label: "dev.nic.spells.scry.tap", qos: .userInitiated)
    /// The output device the aggregate was built on, and the listeners that watch it (on `tapQ`).
    private var outDevice = AudioObjectID(kAudioObjectUnknown), outUID = ""
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var rebuildPending = false
    // Liveness (on `q`): when each channel last delivered samples; the watchdog rebuilds a dead source.
    // A running tap delivers buffers even in silence, so "no samples" means dead, not quiet.
    private var lastMicAt = Date(), lastSysAt = Date(), lastMicRestart = Date.distantPast, lastTapRebuild = Date.distantPast
    private var watchdog: (any DispatchSourceTimer)?
    private(set) var tapRebuilds = 0
    static let staleAfter: TimeInterval = 10, retryEvery: TimeInterval = 15

    init(audio: URL) throws {
        wav = try ScryWAV(url: audio)
        let w = DispatchSource.makeTimerSource(queue: q)
        w.schedule(deadline: .now() + 5, repeating: 5)
        w.setEventHandler { [weak self] in self?.check() }
        w.resume()
        watchdog = w
    }

    /// False while the tap looks dead (the pill says "no call audio"): see `check`.
    var systemAlive: Bool { q.sync { !systemStale } }
    private var systemStale = false

    /// Every 5 s on `q`: a source that stopped delivering is restarted — the mic engine in place, the tap
    /// rebuilt on the current output device — at most once per `retryEvery`. The mic always delivers (silence
    /// included); the tap only delivers while some process plays, so it counts as dead only when another
    /// process is running output and nothing arrives for `staleAfter`.
    private func check() {
        guard running else { return }
        let now = Date()
        if now.timeIntervalSince(lastMicAt) > Self.staleAfter, now.timeIntervalSince(lastMicRestart) > Self.retryEvery {
            lastMicRestart = now
            SupportLog.scry.error("mic delivered nothing for \(Int(now.timeIntervalSince(self.lastMicAt)), privacy: .public) s; restarting it")
            DispatchQueue.main.async { [weak self] in self?.restartMic() }
        }
        systemStale = withSystem && now.timeIntervalSince(lastSysAt) > Self.staleAfter && ScryAudioProcesses.anyRunningOutput()
        if systemStale, now.timeIntervalSince(lastTapRebuild) > Self.retryEvery {
            lastTapRebuild = now
            rebuildSystem(reason: "no system audio for \(Int(now.timeIntervalSince(lastSysAt))) s while a process plays")
        }
    }

    // MARK: Mic

    func startMic() throws {
        installMicTap()
        observeConfigChanges()
        try engine.start()
    }

    private func observeConfigChanges() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // The system stopped the engine because a default device changed (AirPods in/out): start afresh.
            self?.restartMic()
            SupportLog.scry.info("audio devices changed; mic restarted")
        }
    }

    /// Main thread: a fresh engine on the current default devices (the old one's input node keeps the old
    /// hardware format and refuses to start). If this fails, the watchdog tries again in `retryEvery`.
    private func restartMic() {
        guard q.sync(execute: { running }) else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine = AVAudioEngine()
        installMicTap()
        observeConfigChanges()
        do { try engine.start() } catch { SupportLog.scry.error("mic restart failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// Taps the input in whatever format it delivers (asking for a format after a device change raises
    /// "Failed to create tap due to format mismatch"); the resampler follows the buffers' format.
    private func installMicTap() {
        nonisolated(unsafe) var resample: ScryResampler?   // the tap block runs serially on the render thread
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
            guard let self, buf.format.sampleRate > 0 else { return }
            if resample?.input != buf.format { resample = ScryResampler(from: buf.format) }
            guard let pcm = resample?.convert(buf) else { return }
            q.async { self.append(pcm, system: false) }
        }
    }

    // MARK: System audio (process tap → private aggregate device → IOProc)

    /// Blocks until coreaudiod answers — for as long as the first-run "System Audio Recording" prompt is
    /// up — so the app calls it off the main thread. A no-op once `stop` has run.
    func startSystem() throws {
        try tapQ.sync {
            guard begin() else { return }
            defer { end() }
            try createTap()
            watchOutputDevice()
        }
    }

    /// Marks a tap job as running (false: the recording has stopped, do nothing).
    private func begin() -> Bool { tapLock.withLock { if tapStopped { return false }; tapStarting = true; return true } }
    /// Ends a tap job; if `stop` ran meanwhile, this job tears the tap down.
    private func end() { if tapLock.withLock({ tapStarting = false; return tapStopped }) { stopSystem() } }

    /// The tap follows the processes, but the aggregate it is read through is clocked by the output device
    /// it was built on. When the default output moves (AirPods in or out), or that device changes its format
    /// (AirPods flipping between the hands-free and music profiles when the mic moves on or off them), or dies,
    /// the aggregate goes quiet or garbles: rebuild on the current device. Debounced, since one switch fires
    /// several notifications.
    private func watchOutputDevice() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        listen(system, kAudioHardwarePropertyDefaultOutputDevice, "default output changed")
        if outDevice != kAudioObjectUnknown {
            listen(outDevice, kAudioDevicePropertyNominalSampleRate, "output device changed its sample rate")
            listen(outDevice, kAudioDevicePropertyStreamConfiguration, "output device changed its streams")
            listen(outDevice, kAudioDevicePropertyDeviceIsAlive, "output device went away")
        }
    }

    private func listen(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ reason: String) {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectAddPropertyListenerBlock(obj, &addr, tapQ) { [weak self] _, _ in
            guard let self, !rebuildPending else { return }
            if sel == kAudioHardwarePropertyDefaultOutputDevice {   // only a real move, not a re-announcement of the same device
                let now = ScryAudioProcesses.string(ScryAudioProcesses.prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)),
                                                    kAudioDevicePropertyDeviceUID)
                guard now != outUID else { return }
            }
            rebuildPending = true
            tapQ.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                rebuildPending = false
                rebuildSystem(reason: reason)
            }
        }
        if st == noErr { deviceListeners.append((obj, addr)) }
    }

    private func unlisten() {
        for (obj, addr) in deviceListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(obj, &a, tapQ) { _, _ in }   // ponytail: the block identity isn't needed to remove a queue listener
        }
        deviceListeners.removeAll()
    }

    /// Tears the tap down and builds it again on the current default output device. Any thread.
    func rebuildSystem(reason: String) {
        tapQ.async { [self] in
            guard begin() else { return }
            defer { end() }
            stopSystem()
            do {
                try createTap()
                watchOutputDevice()
                q.async { self.tapRebuilds += 1; self.lastSysAt = Date(); self.lastTapRebuild = Date() }
                SupportLog.scry.info("system tap rebuilt (\(reason, privacy: .public))")
            } catch {
                SupportLog.scry.error("system tap rebuild failed (\(reason, privacy: .public)): \(String(describing: error), privacy: .public)")
                q.async { self.lastTapRebuild = Date() }   // the watchdog tries again in `retryEvery`
            }
        }
    }

    private func createTap() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: ScryAudioProcesses.object(pid: getpid()).map { [$0] } ?? [])
        desc.uuid = UUID(); desc.isPrivate = true; desc.muteBehavior = .unmuted
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else { throw TapFailed(step: "create tap", status: st) }
        let system = AudioObjectID(kAudioObjectSystemObject)
        outDevice = ScryAudioProcesses.prop(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
        outUID = ScryAudioProcesses.string(outDevice, kAudioDevicePropertyDeviceUID)
        let outUID = self.outUID
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Scry", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID, kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard st == noErr else { stopSystem(); throw TapFailed(step: "create aggregate device", status: st) }
        var asbd = ScryAudioProcesses.prop(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd), let resample = ScryResampler(from: format) else {
            stopSystem(); throw TapFailed(step: "read tap format", status: -1)
        }
        st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, q) { [weak self] _, input, _, _, _ in
            guard let self, let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            append(resample.convert(buf), system: true)   // already on q
        }
        guard st == noErr else { stopSystem(); throw TapFailed(step: "create IOProc", status: st) }
        q.sync { withSystem = true; lastSysAt = Date() }   // before the first buffer lands, so ch 1 isn't padded under it
        st = AudioDeviceStart(agg, proc)
        guard st == noErr else { q.sync { withSystem = false }; stopSystem(); throw TapFailed(step: "start device", status: st) }
        SupportLog.scry.info("system tap: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch, on \(ScryAudioProcesses.string(self.outDevice, kAudioObjectPropertyName), privacy: .public)")
    }

    private func stopSystem() {
        unlisten()
        if let proc { AudioDeviceStop(agg, proc); AudioDeviceDestroyIOProcID(agg, proc) }
        if agg != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(agg) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        proc = nil; agg = AudioObjectID(kAudioObjectUnknown); tap = AudioObjectID(kAudioObjectUnknown); outDevice = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Writing

    private func append(_ pcm: [Int16], system: Bool) {
        guard running, !pcm.isEmpty else { return }
        let ss = pcm.reduce(0.0) { $0 + Double($1) * Double($1) }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        let rms = (ss / Double(pcm.count)).squareRoot() / 32768
        let lv = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50))
        if system { lastLevel.1 = lv } else { lastLevel.0 = lv }
        if system {
            sys += pcm; sumSq.1 += ss; received.1 += pcm.count; lastSysAt = Date()
            if !sysNonZero, pcm.contains(where: { $0 != 0 }) { sysNonZero = true }
            onSystem?(data)
        } else {
            mic += pcm; sumSq.0 += ss; received.0 += pcm.count; lastMicAt = Date()
            onMic?(data)
        }
        drain(final: false)
    }

    /// Writes the frames both channels have. Without the tap, ch 1 is silence. ponytail: a source more than
    /// 2 s behind (stalled tap or mic) is padded with silence, so the channels stay roughly aligned and the
    /// queues bounded — no drift correction beyond that.
    private func drain(final: Bool) {
        if !withSystem { sys += repeatElement(0, count: max(0, mic.count - sys.count)) }
        if final || abs(mic.count - sys.count) > 32_000 {
            let n = max(mic.count, sys.count)
            mic += repeatElement(0, count: n - mic.count); sys += repeatElement(0, count: n - sys.count)
        }
        let n = min(mic.count, sys.count)
        guard n > 0 else { return }
        wav.write(mic: mic[..<n], system: sys[..<n])
        mic.removeFirst(n); sys.removeFirst(n)
    }

    /// Stops both sources, flushes (padding the shorter channel), patches the WAV header.
    func stop() -> Stats {
        watchdog?.cancel(); watchdog = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        // Not starting or rebuilding right now → tear down here; otherwise that job does it when it ends.
        if !tapLock.withLock({ tapStopped = true; return tapStarting }) { tapQ.sync { stopSystem() } }
        return q.sync {
            drain(final: true)
            running = false
            wav.close()
            func rms(_ s: Double, _ n: Int) -> Double { n > 0 ? (s / Double(n)).squareRoot() / 32768 : 0 }
            return Stats(frames: wav.frames, micSamples: received.0, systemSamples: received.1,
                         micRMS: rms(sumSq.0, received.0), systemRMS: rms(sumSq.1, received.1), systemAllZero: !sysNonZero)
        }
    }
}

/// Any PCM format → 16 kHz mono s16le (stereo is mixed down). Stateful (the resampler), so one per source.
final class ScryResampler: @unchecked Sendable {
    private static let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let converter: AVAudioConverter

    let input: AVAudioFormat

    init?(from format: AVAudioFormat) {
        guard let c = AVAudioConverter(from: format, to: Self.out) else { return nil }
        c.downmix = true
        converter = c; input = format
    }

    func convert(_ buf: AVAudioPCMBuffer) -> [Int16] {
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.out, frameCapacity: cap) else { return [] }
        // The input block runs synchronously inside convert(), so these never cross threads.
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let input = buf
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        return Array(UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
    }
}

/// A 16 kHz 2-channel s16le WAV written as it goes; `close` patches the RIFF and data sizes.
final class ScryWAV {
    private let handle: FileHandle
    private(set) var frames = 0

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(dataBytes: 0)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    /// False once a write failed (disk full): later writes are dropped, the header covers what was written.
    private(set) var ok = true

    func write(mic: ArraySlice<Int16>, system: ArraySlice<Int16>) {
        guard ok else { return }
        var inter = [Int16](); inter.reserveCapacity(mic.count * 2)
        for (m, s) in zip(mic, system) { inter.append(m.littleEndian); inter.append(s.littleEndian) }
        do {   // throwing write: the old non-throwing one raised an ObjC exception on a full disk
            try handle.write(contentsOf: inter.withUnsafeBufferPointer { Data(buffer: $0) })
            frames += mic.count
        } catch {
            ok = false
            SupportLog.scry.error("recording write failed; keeping what's written: \(error.localizedDescription, privacy: .public)")
        }
    }

    func close() {
        let dataBytes = frames * 4
        try? handle.seek(toOffset: 4); try? handle.write(contentsOf: Self.le32(36 + dataBytes))
        try? handle.seek(toOffset: 40); try? handle.write(contentsOf: Self.le32(dataBytes))
        try? handle.close()
    }

    static func header(dataBytes: Int) -> Data {
        var d = Data("RIFF".utf8) + le32(36 + dataBytes) + Data("WAVEfmt ".utf8)
        d += le32(16) + le16(1) + le16(2) + le32(16000) + le32(16000 * 4) + le16(4) + le16(16)   // PCM, 2 ch, 16 kHz, 16-bit
        return d + Data("data".utf8) + le32(dataBytes)
    }
    private static func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
    private static func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
}
