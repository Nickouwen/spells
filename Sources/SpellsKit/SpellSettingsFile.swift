import Foundation

/// A module's settings: `<home>/<spell>/settings.json`, a flat string dictionary. Each module owns its
/// file; another module may read it (Rewind reads Scry's notes folder) but never writes it. Replaces the
/// rows these spells kept in Rewind's `setting` table before the module split (2026-10).
public struct SpellSettingsFile: Sendable, Equatable {
    public let url: URL

    public init(spell: String, paths: SupportPaths = .current()) {
        url = paths.home.appending(path: spell, directoryHint: .isDirectory).appending(path: "settings.json")
    }
    public static func incant(_ paths: SupportPaths = .current()) -> SpellSettingsFile { .init(spell: "incant", paths: paths) }
    public static func scry(_ paths: SupportPaths = .current()) -> SpellSettingsFile { .init(spell: "scry", paths: paths) }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Empty when the file is missing or unreadable: callers fall back to defaults.
    public func all() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Merges `rows` into the file (nil removes a key). Atomic write; creates the folder.
    public func merge(_ rows: [String: String?]) throws {
        var all = all()
        for (k, v) in rows { all[k] = v }
        try replace(all)
    }

    public func set(_ key: String, _ value: String?) throws { try merge([key: value]) }

    public func replace(_ rows: [String: String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rows).write(to: url, options: .atomic)
    }
}
