import Foundation
import Testing
import ScryCore
@testable import ScryPipeline
import SpellsKit

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
        try "ask about the backfill".write(to: crashed.appending(path: "notes.txt"), atomically: true, encoding: .utf8)   // the live panel's notes
        ScryCaptures.recoverCrashed(root)
        let manifest = try ScryCapture.decode(Data(contentsOf: crashed.appending(path: "capture.json")))
        #expect(manifest.app == nil && manifest.audioFile == "audio.wav" && manifest.userNotes == "ask about the backfill")
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

    @Test func aProcessedCaptureIsKeptForAWeek() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "scry-kept-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: home) }
        let paths = SupportPaths(home: home, logs: home.appending(path: "logs"))
        func capture(in parent: URL, _ name: String) throws -> URL {
            let d = parent.appending(path: name, directoryHint: .isDirectory)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: d.appending(path: "audio.wav"))
            return d
        }
        let kept = ScryCaptures.kept(paths)
        // A capture from the app's folder moves to `kept`, so the next launch doesn't process it again.
        let done = try capture(in: ScryCaptures.root(paths), "today")
        let old = try capture(in: kept, "old"), elsewhere = try capture(in: home.appending(path: "tmp"), "cli")
        ScryCaptures.retire(done, paths: paths)
        #expect(!fm.fileExists(atPath: done.path) && fm.fileExists(atPath: kept.appending(path: "today/audio.wav").path))
        #expect(ScryCaptures.retryable(ScryCaptures.root(paths)).isEmpty)
        // Processed again from `kept`: it stays. From anywhere else: deleted, as before.
        ScryCaptures.retire(kept.appending(path: "today"), paths: paths)
        ScryCaptures.retire(elsewhere, paths: paths)
        #expect(fm.fileExists(atPath: kept.appending(path: "today").path) && !fm.fileExists(atPath: elsewhere.path))
        // Eight days on, the kept ones go.
        #expect(fm.fileExists(atPath: old.path))
        ScryCaptures.retire(try capture(in: ScryCaptures.root(paths), "later"), paths: paths, now: Date().addingTimeInterval(8 * 86400))
        #expect(!fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: kept.appending(path: "today").path))
    }
}
