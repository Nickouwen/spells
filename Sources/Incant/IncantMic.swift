import AVFoundation
import HoursCore

/// The microphone as 16 kHz mono s16le chunks of ~100 ms (Scribe's pcm_16000), plus a 0…1 level for
/// the overlay. The engine is prepared up front so `start()` at Fn-down is quick; a default-input change
/// (AirPods in/out) re-taps at the new format. Engine calls happen on the main thread; the tap's
/// buffers are collected on `q`.
final class IncantMic: @unchecked Sendable {
    private static let chunkBytes = 3200   // 100 ms at 16 kHz × 2 bytes
    private static let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let engine = AVAudioEngine()
    private let q = DispatchQueue(label: "dev.nic.spells.incant.mic")
    private var pending = Data(), running = false, onChunk: (@Sendable (Data) -> Void)?, currentLevel = 0.0
    private var tapped = false   // installTap() succeeded (no input device at launch = false until one appears)
    struct NoInput: Error {}

    var level: Double { q.sync { currentLevel } }

    /// Call once at launch, after the microphone permission prompt.
    func prepare() {
        installTap()
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in self?.rebuild() }
    }

    func start(_ onChunk: @escaping @Sendable (Data) -> Void) throws {
        if !tapped { installTap() }
        guard tapped else { throw NoInput() }
        q.sync { self.onChunk = onChunk; pending = Data(); running = true }
        do { try engine.start() } catch { q.sync { running = false; self.onChunk = nil }; throw error }
    }

    /// Stops capture and returns the audio not yet handed out as a chunk (< 100 ms).
    func stop() -> Data {
        engine.stop()
        q.sync {}   // let buffers the tap already handed to q land before reading pending
        // stop() frees what prepare() allocated; redo it now, off the next start's path. prepare() doesn't
        // run input (mic dot stays off): kAudioProcessPropertyIsRunningInput reads 0 after stop/prepare,
        // 1 only between start and stop (checked 2026-10-08).
        engine.prepare()
        return q.sync {
            defer { pending = Data(); running = false; onChunk = nil; currentLevel = 0 }
            return pending
        }
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: Self.out) else {
            SupportLog.incant.error("no usable audio input")
            tapped = false
            return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in self?.convert(buf, converter) }
        tapped = true
        engine.prepare()
    }

    /// The system stopped the engine because the input changed: re-tap at the new format.
    private func rebuild() {
        engine.inputNode.removeTap(onBus: 0)
        tapped = false
        installTap()
        if q.sync(execute: { running }) {
            do { try engine.start() } catch { SupportLog.incant.error("mic restart failed: \(error.localizedDescription, privacy: .public)") }
        }
        SupportLog.incant.info("audio input changed; mic re-tapped")
    }

    private func convert(_ buf: AVAudioPCMBuffer, _ converter: AVAudioConverter) {
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.out, frameCapacity: cap) else { return }
        // The input block runs synchronously inside convert(), so these never cross threads.
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let input = buf
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        let samples = UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength))
        let bytes = Data(buffer: samples)
        let rms = (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(samples.count, 1))).squareRoot() / 32768
        let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50))   // −50…0 dBFS → 0…1
        q.async { [self] in
            guard running else { return }
            currentLevel = level
            pending.append(bytes)
            if pending.count >= Self.chunkBytes { onChunk?(pending); pending = Data() }
        }
    }
}
