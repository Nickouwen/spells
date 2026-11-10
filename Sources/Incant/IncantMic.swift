import Foundation
import SpellsKit

/// The microphone as 16 kHz mono s16le chunks of ~100 ms (Scribe's pcm_16000), plus a 0…1 level for
/// the overlay. SupportMic picks the device: the built-in mic when the default input is a Bluetooth
/// headset, so dictating doesn't flip the headset into its call profile. Start and stop run on the
/// main thread; buffers are collected on `q`.
final class IncantMic: @unchecked Sendable {
    private static let chunkBytes = 3200   // 100 ms at 16 kHz × 2 bytes
    private let mic = SupportMic()
    private let q = DispatchQueue(label: "dev.nic.spells.incant.mic")
    private var pending = Data(), running = false, onChunk: (@Sendable (Data) -> Void)?, currentLevel = 0.0
    private var startedAt: Date?   // until the first buffer: logs how long the mic took to open

    var level: Double { q.sync { currentLevel } }
    var deviceName: String { mic.deviceName }

    /// Call once at launch, after the microphone permission prompt. Picks the device up front, so
    /// `start()` at Fn-down only starts the session.
    func prepare() {
        mic.onPCM = { [weak self] samples in self?.received(samples) }
        do { try mic.select() } catch { SupportLog.incant.error("no usable audio input") }
    }

    func start(_ onChunk: @escaping @Sendable (Data) -> Void) throws {
        q.sync { self.onChunk = onChunk; pending = Data(); running = true; startedAt = Date() }
        do { try mic.start() } catch { q.sync { running = false; self.onChunk = nil }; throw error }
    }

    /// Stops capture and returns the audio not yet handed out as a chunk (< 100 ms).
    func stop() -> Data {
        mic.stop()
        return q.sync {
            defer { pending = Data(); running = false; onChunk = nil; currentLevel = 0 }
            return pending
        }
    }

    private func received(_ samples: [Int16]) {
        let rms = (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(samples.count, 1))).squareRoot() / 32768
        let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50))   // −50…0 dBFS → 0…1
        let bytes = samples.withUnsafeBytes { Data($0) }
        q.async { [self] in
            guard running else { return }
            if let t = startedAt {
                startedAt = nil
                SupportLog.incant.info("mic: \(self.mic.deviceName, privacy: .public), first audio after \(Int(Date().timeIntervalSince(t) * 1000), privacy: .public) ms")
            }
            currentLevel = level
            pending.append(bytes)
            if pending.count >= Self.chunkBytes { onChunk?(pending); pending = Data() }
        }
    }
}
