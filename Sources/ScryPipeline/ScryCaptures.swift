import Foundation
import SpellsKit
import ScryCore

/// The capture dirs under `<home>/scry/captures`: failure bookkeeping, retry selection, crash recovery and
/// upload-spool cleanup. Shared by the recorder (launch) and the Spells Meetings view (Failed captures).
public enum ScryCaptures {
    public static let maxAttempts = 3

    public struct Failed: Sendable, Identifiable {
        public var id: URL { dir }
        public var dir: URL, date: Date, bytes: Int, error: String, attempts: Int
    }

    public static func root(_ paths: SupportPaths = .current()) -> URL {
        paths.home.appending(path: "scry/captures", directoryHint: .isDirectory)
    }

    /// Processed captures (audio, manifest, speakers) wait here for `keepDays`: the recording is the one thing
    /// that can't be made again, so a call can be transcribed a second time after a failure that only shows in
    /// the note (`spellsctl scry process <dir>`). About 230 MB per hour of call.
    public static let keepDays = 7.0
    public static func kept(_ paths: SupportPaths = .current()) -> URL {
        paths.home.appending(path: "scry/kept", directoryHint: .isDirectory)
    }

    /// After a successful run: a capture from `root` moves to `kept`, and kept ones recorded more than `keepDays`
    /// ago go. One already in `kept` (processed again) stays; one from anywhere else (`spellsctl`) is deleted.
    static func retire(_ dir: URL, paths: SupportPaths = .current(), now: Date = Date()) {
        let fm = FileManager.default, kept = kept(paths), parent = dir.deletingLastPathComponent().standardizedFileURL.path
        if parent == root(paths).standardizedFileURL.path {
            try? fm.createDirectory(at: kept, withIntermediateDirectories: true)
            // Can't be kept → it goes, rather than be processed again at the next launch.
            do { try fm.moveItem(at: dir, to: kept.appending(path: dir.lastPathComponent)) } catch { try? fm.removeItem(at: dir) }
        } else if parent != kept.standardizedFileURL.path {
            try? fm.removeItem(at: dir)
        }
        for d in dirs(kept) {   // a dir's modification date is when its last file was added: the end of the recording
            let recorded = (try? d.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(recorded) > keepDays * 86400 { try? fm.removeItem(at: d) }
        }
    }

    /// `error.txt` = "attempts: N" then the message (capped at 500 chars; never transcript text).
    public static func attempts(_ dir: URL) -> Int {
        guard let s = try? String(contentsOf: dir.appending(path: "error.txt"), encoding: .utf8),
              let first = s.split(separator: "\n").first, first.hasPrefix("attempts: ") else { return 0 }
        return Int(first.dropFirst("attempts: ".count)) ?? maxAttempts
    }

    static func recordFailure(_ dir: URL, _ error: any Error) {
        let text = "attempts: \(attempts(dir) + 1)\n" + String(String(describing: error).prefix(500))
        try? Data(text.utf8).write(to: dir.appending(path: "error.txt"))
    }

    /// Dirs with a manifest and audio that haven't failed `maxAttempts` times (oldest first).
    public static func retryable(_ root: URL = root()) -> [URL] {
        dirs(root).filter { has($0, "capture.json") && has($0, "audio.wav") && attempts($0) < maxAttempts }
    }

    /// Dirs whose last run failed (any attempt count), for the Meetings view.
    public static func failed(_ root: URL = root()) -> [Failed] {
        dirs(root).filter { has($0, "error.txt") }.map { d in
            let msg = (try? String(contentsOf: d.appending(path: "error.txt"), encoding: .utf8))?
                .split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let attrs = try? FileManager.default.attributesOfItem(atPath: d.appending(path: "audio.wav").path)
            return Failed(dir: d, date: (attrs?[.creationDate] as? Date) ?? .distantPast,
                          bytes: (attrs?[.size] as? Int) ?? 0, error: msg, attempts: attempts(d))
        }.sorted { $0.date > $1.date }
    }

    /// A recording killed mid-way leaves `audio.wav` with an unpatched header and no `capture.json`: patch
    /// the sizes from the file length and write a manifest (start = creation, end = modification, in person,
    /// no screenshots or notes), so it becomes processable.
    public static func recoverCrashed(_ root: URL = root()) {
        for d in dirs(root) where has(d, "audio.wav") && !has(d, "capture.json") {
            let wav = d.appending(path: "audio.wav")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: wav.path),
                  let size = attrs[.size] as? Int, size > 44, let h = try? FileHandle(forWritingTo: wav) else { continue }
            let data = (size - 44) / 4 * 4
            try? h.seek(toOffset: 4); try? h.write(contentsOf: le32(36 + data))
            try? h.seek(toOffset: 40); try? h.write(contentsOf: le32(data))
            try? h.close()
            let start = (attrs[.creationDate] as? Date) ?? Date(), end = (attrs[.modificationDate] as? Date) ?? start
            // The live panel saves your notes to notes.txt as you type; keep them.
            let notes = (try? String(contentsOf: d.appending(path: "notes.txt"), encoding: .utf8)) ?? ""
            let capture = ScryCapture(audioFile: "audio.wav", startedAt: start, endedAt: end, app: nil, screenshotText: [], userNotes: notes)
            try? capture.encoded().write(to: d.appending(path: "capture.json"))
            SupportLog.scry.info("recovered a crashed capture: \(d.lastPathComponent, privacy: .public)")
        }
    }

    /// Multipart upload spools (`scry-<uuid>.multipart`, the whole meeting's audio) a killed upload left in
    /// the temp dir.
    public static func cleanSpool(olderThan age: TimeInterval = 3600) {
        let tmp = FileManager.default.temporaryDirectory
        for f in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where f.lastPathComponent.hasPrefix("scry-") && f.pathExtension == "multipart" {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(m) > age { try? FileManager.default.removeItem(at: f) }
        }
    }

    private static func dirs(_ root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter(\.hasDirectoryPath)
    }
    private static func has(_ d: URL, _ name: String) -> Bool { FileManager.default.fileExists(atPath: d.appending(path: name).path) }
    private static func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
}
