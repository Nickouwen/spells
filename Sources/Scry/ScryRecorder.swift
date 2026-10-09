import AVFoundation
import CoreAudio
import HoursCore

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

    var onMic: (@Sendable (Data) -> Void)?
    var onSystem: (@Sendable (Data) -> Void)?

    private let q = DispatchQueue(label: "dev.nic.spells.scry.recorder")
    private let engine = AVAudioEngine()
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
    // in flight (on another thread) when `stop` runs; whoever finishes last tears it down.
    private let tapLock = NSLock()
    private var tapStarting = false, tapStopped = false

    init(audio: URL) throws { wav = try ScryWAV(url: audio) }

    // MARK: Mic

    func startMic() throws {
        installMicTap()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // The system stopped the engine because the input changed (AirPods in/out): re-tap at the new format.
            guard let self else { return }
            engine.inputNode.removeTap(onBus: 0)
            installMicTap()
            do { try engine.start() } catch { SupportLog.scry.error("mic restart failed: \(error.localizedDescription, privacy: .public)") }
            SupportLog.scry.info("audio input changed; mic re-tapped")
        }
        try engine.start()
    }

    private func installMicTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let resample = ScryResampler(from: format) else {
            SupportLog.scry.error("no usable audio input"); return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in
            guard let self else { return }
            let pcm = resample.convert(buf)
            q.async { self.append(pcm, system: false) }
        }
    }

    // MARK: System audio (process tap → private aggregate device → IOProc)

    /// Blocks until coreaudiod answers — for as long as the first-run "System Audio Recording" prompt is
    /// up — so the app calls it off the main thread. A no-op once `stop` has run.
    func startSystem() throws {
        guard tapLock.withLock({ () -> Bool in if tapStopped { return false }; tapStarting = true; return true }) else { return }
        do { try createTap() } catch { tapLock.withLock { tapStarting = false }; throw error }
        if tapLock.withLock({ tapStarting = false; return tapStopped }) { stopSystem() }   // stopped while it was starting
    }

    private func createTap() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: ScryAudioProcesses.object(pid: getpid()).map { [$0] } ?? [])
        desc.uuid = UUID(); desc.isPrivate = true; desc.muteBehavior = .unmuted
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else { throw TapFailed(step: "create tap", status: st) }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let outUID = ScryAudioProcesses.string(ScryAudioProcesses.prop(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)),
                                               kAudioDevicePropertyDeviceUID)
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
        q.sync { withSystem = true }   // before the first buffer lands, so ch 1 isn't padded under it
        st = AudioDeviceStart(agg, proc)
        guard st == noErr else { q.sync { withSystem = false }; stopSystem(); throw TapFailed(step: "start device", status: st) }
        SupportLog.scry.info("system tap: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
    }

    private func stopSystem() {
        if let proc { AudioDeviceStop(agg, proc); AudioDeviceDestroyIOProcID(agg, proc) }
        if agg != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(agg) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        proc = nil; agg = AudioObjectID(kAudioObjectUnknown); tap = AudioObjectID(kAudioObjectUnknown)
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
            sys += pcm; sumSq.1 += ss; received.1 += pcm.count
            if !sysNonZero, pcm.contains(where: { $0 != 0 }) { sysNonZero = true }
            onSystem?(data)
        } else {
            mic += pcm; sumSq.0 += ss; received.0 += pcm.count
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
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        if !tapLock.withLock({ tapStopped = true; return tapStarting }) { stopSystem() }
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

    init?(from format: AVAudioFormat) {
        guard let c = AVAudioConverter(from: format, to: Self.out) else { return nil }
        c.downmix = true
        converter = c
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
