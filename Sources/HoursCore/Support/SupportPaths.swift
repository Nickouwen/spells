import Foundation

/// Where hours keeps its files. `SPELLS_HOME` relocates everything (db, backups, exports, logs)
/// so tests and dev runs never touch the real ~/Library dirs.
public struct SupportPaths: Sendable, Equatable {
    /// `~/Library/Application Support/Spells/` (or `$SPELLS_HOME`).
    public var home: URL
    /// `~/Library/Logs/Spells/` (or `$SPELLS_HOME/logs`).
    public var logs: URL

    public var db: URL { home.appending(path: "hours.db") }
    public var backups: URL { home.appending(path: "backups", directoryHint: .isDirectory) }
    public var exports: URL { home.appending(path: "exports", directoryHint: .isDirectory) }

    public init(home: URL, logs: URL) {
        self.home = home
        self.logs = logs
    }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> SupportPaths {
        if let custom = environment["SPELLS_HOME"], !custom.isEmpty {
            let home = URL(filePath: (custom as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            return SupportPaths(home: home, logs: home.appending(path: "logs", directoryHint: .isDirectory))
        }
        let library = URL.libraryDirectory
        return SupportPaths(
            home: library.appending(path: "Application Support/Spells", directoryHint: .isDirectory),
            logs: library.appending(path: "Logs/Spells", directoryHint: .isDirectory))
    }

    /// Creates home, backups, exports and logs if missing.
    public func createDirectories() throws {
        for dir in [home, backups, exports, logs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
