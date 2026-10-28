import Foundation
import Synchronization

/// One Scry note file: where it lives, its text (action-item line numbers index into it) and the parse.
public struct ScryNoteFile: Identifiable, Equatable, Sendable {
    public let url: URL
    public let markdown: String
    public let note: ScryNote
    public let actions: [ScryActions.Item]
    public var id: URL { url }

    public init(url: URL, markdown: String, note: ScryNote) {
        self.url = url; self.markdown = markdown; self.note = note
        actions = ScryActions.items(in: markdown)
    }

    public var startMs: Int64 { Int64(note.meta.startedAt.timeIntervalSince1970 * 1000) }
    public var endMs: Int64 { Int64(note.meta.endedAt.timeIntervalSince1970 * 1000) }
    public var openCount: Int { actions.filter { !$0.done }.count }
    /// Speakers in order of first word.
    public var speakers: [String] {
        var seen = Set<String>()
        return note.segments.map(\.speaker).filter { seen.insert($0).inserted }
    }
}

/// The notes folder: file I/O and pure transforms shared by Scry's Meetings window, Rewind's Blocks
/// (meetings during a block) and the standup. Reads/writes run off the main actor.
public enum ScryNotes {
    /// Every note under `root` (recursive `*.md` that parse as one), newest first. A note is re-read only
    /// when its size or modification date changed since the last load (the Meetings view loads on every
    /// show and after every edit).
    public static func load(_ root: URL) -> [ScryNoteFile] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys))?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "md" } ?? []
        return files.compactMap { url in
            let v = try? url.resourceValues(forKeys: keys)
            let stamp = Cached.Stamp(modified: v?.contentModificationDate ?? .distantPast, size: v?.fileSize ?? -1)
            if let c = cache.withLock({ $0[url.path] }), c.stamp == stamp { return c.file }
            guard let md = try? String(contentsOf: url, encoding: .utf8), let note = ScryNote.parse(md) else { return nil }
            let file = ScryNoteFile(url: url, markdown: md, note: note)
            cache.withLock { $0[url.path] = Cached(stamp: stamp, file: file) }
            return file
        }.sorted { $0.note.meta.startedAt > $1.note.meta.startedAt }
    }

    private struct Cached {
        struct Stamp: Equatable { var modified: Date, size: Int }
        var stamp: Stamp, file: ScryNoteFile
    }
    private static let cache = Mutex<[String: Cached]>([:])

    /// Rewrites a note's transcript with `ScryTranscript.tidiedMarkdown` (echo lines dropped, words joined
    /// into turns). Nothing is written when the transcript already reads that way; returns whether it changed.
    @discardableResult public static func tidy(_ url: URL) throws -> Bool {
        let md = try String(contentsOf: url, encoding: .utf8)
        let out = ScryTranscript.tidiedMarkdown(md)
        guard out != md else { return false }
        try out.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// Notes whose [start, end] overlaps `r` (a work block), oldest first.
    public static func overlapping(_ notes: [ScryNoteFile], _ r: Range<Int64>) -> [ScryNoteFile] {
        notes.filter { $0.startMs < r.upperBound && $0.endMs > r.lowerBound }.reversed()
    }

    /// `from` → `to` in the speaker map and every segment. A label nobody named yet ("Speaker B") gets a
    /// map entry. Blank or unchanged names are a no-op.
    public static func renamed(_ note: ScryNote, from: String, to: String) -> ScryNote {
        let name = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != from else { return note }
        var n = note
        var mapped = false
        for (label, value) in n.meta.speakers where value == from { n.meta.speakers[label] = name; mapped = true }
        if !mapped { n.meta.speakers[from] = name }
        for i in n.segments.indices where n.segments[i].speaker == from { n.segments[i].speaker = name }
        return n
    }

    /// Flips one action-item checkbox in the file on disk. The file is re-read and the item matched by
    /// owner + task (at its line, else wherever a hand edit moved it); if it's gone, nothing is written.
    public static func toggle(_ url: URL, line: Int, owner: String, task: String) throws -> ScryNoteFile? {
        let fresh = try String(contentsOf: url, encoding: .utf8)
        let items = ScryActions.items(in: fresh)
        guard let target = items.first(where: { $0.line == line && $0.owner == owner && $0.task == task })
                ?? items.first(where: { $0.owner == owner && $0.task == task })
        else { return ScryNote.parse(fresh).map { ScryNoteFile(url: url, markdown: fresh, note: $0) } }
        return try write(ScryActions.toggled(fresh, line: target.line), to: url)
    }

    /// Appends an action item (owner "You" for ones you add by hand) and re-reads the note.
    public static func addAction(_ url: URL, owner: String, task: String) throws -> ScryNoteFile? {
        try write(ScryActions.added(try String(contentsOf: url, encoding: .utf8), owner: owner, task: task), to: url)
    }

    /// Removes one action item, matched like `toggle`; gone already → nothing is written.
    public static func removeAction(_ url: URL, line: Int, owner: String, task: String) throws -> ScryNoteFile? {
        let fresh = try String(contentsOf: url, encoding: .utf8)
        let items = ScryActions.items(in: fresh)
        guard let target = items.first(where: { $0.line == line && $0.owner == owner && $0.task == task })
                ?? items.first(where: { $0.owner == owner && $0.task == task })
        else { return ScryNote.parse(fresh).map { ScryNoteFile(url: url, markdown: fresh, note: $0) } }
        return try write(ScryActions.removed(fresh, line: target.line), to: url)
    }

    /// The note file to the Trash (recoverable). Its capture folder, if any, is untouched.
    public static func delete(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Renames a speaker by text substitution only: transcript lines (`**[mm:ss] From:**`), action-item
    /// owners (`**From**:`) and the frontmatter `speakers` map. Everything else stays byte-identical.
    public static func rename(_ url: URL, from: String, to: String) throws -> ScryNoteFile? {
        let name = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != from else { return nil }
        return try write(renamedText(try String(contentsOf: url, encoding: .utf8), from: from, to: name), to: url)
    }

    public static func renamedText(_ md: String, from: String, to: String) -> String {
        var inFront = false, frontSeen = false
        let lines = md.components(separatedBy: "\n").map { line -> String in
            if line == "---" { if !frontSeen { inFront = true; frontSeen = true } else if inFront { inFront = false }; return line }
            if inFront, line.hasPrefix("speakers:") { return renamedSpeakersLine(line, from: from, to: to) }
            if let r = line.range(of: #"^\*\*\[\d+:\d\d\] "#, options: .regularExpression),
               line[r.upperBound...].hasPrefix(from + ":**") {
                return String(line[..<r.upperBound]) + to + line[line.index(r.upperBound, offsetBy: from.count)...]
            }
            if line.range(of: #"^\s*- \[[ xX]\] "#, options: .regularExpression) != nil {
                return line.replacingOccurrences(of: "**\(from)**:", with: "**\(to)**:")
            }
            return line
        }
        return lines.joined(separator: "\n")
    }

    /// `speakers: {"Speaker A":"Alex"}` → the label that showed `from` now maps to `to` (or `from` itself
    /// becomes a mapped label).
    private static func renamedSpeakersLine(_ line: String, from: String, to: String) -> String {
        let json = line.dropFirst("speakers:".count).trimmingCharacters(in: .whitespaces)
        var map = (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
        var mapped = false
        for (label, value) in map where value == from { map[label] = to; mapped = true }
        if !mapped { map[from] = to }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return "speakers: " + (String(data: (try? enc.encode(map)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}")
    }

    private static func write(_ markdown: String, to url: URL) throws -> ScryNoteFile? {
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return ScryNote.parse(markdown).map { ScryNoteFile(url: url, markdown: markdown, note: $0) }
    }
}
