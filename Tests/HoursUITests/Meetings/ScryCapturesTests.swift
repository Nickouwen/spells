import Foundation
import Testing
import ScryCore
import ScryPipeline

@Suite struct ScryCapturesTests {
    @Test func crashedCaptureIsRecoveredAndFailuresAreCounted() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scry-captures-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        // A crash mid-recording: a WAV with header sizes still 0, no manifest.
        let crashed = root.appending(path: "a", directoryHint: .isDirectory)
        try fm.createDirectory(at: crashed, withIntermediateDirectories: true)
        var wav = Data("RIFF".utf8) + Data(count: 4) + Data("WAVEfmt ".utf8) + Data(count: 20) + Data("data".utf8) + Data(count: 4)
        wav += Data(count: 32_000)
        try wav.write(to: crashed.appending(path: "audio.wav"))
        ScryCaptures.recoverCrashed(root)
        let manifest = try ScryCapture.decode(Data(contentsOf: crashed.appending(path: "capture.json")))
        #expect(manifest.app == nil && manifest.audioFile == "audio.wav")
        let patched = try Data(contentsOf: crashed.appending(path: "audio.wav"))
        #expect(patched[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 32_000)
        #expect(ScryCaptures.retryable(root).map { $0.resolvingSymlinksInPath() } == [crashed.resolvingSymlinksInPath()])

        // Failed twice: still retried; three times: waits in Failed captures.
        try "attempts: 2\nScribe HTTP 503".write(to: crashed.appending(path: "error.txt"), atomically: true, encoding: .utf8)
        #expect(ScryCaptures.attempts(crashed) == 2 && ScryCaptures.retryable(root).count == 1)
        try "attempts: 3\nScribe HTTP 503".write(to: crashed.appending(path: "error.txt"), atomically: true, encoding: .utf8)
        #expect(ScryCaptures.retryable(root).isEmpty)
        let f = try #require(ScryCaptures.failed(root).first)
        #expect(f.attempts == 3 && f.error == "Scribe HTTP 503" && f.bytes == patched.count)
    }
}
