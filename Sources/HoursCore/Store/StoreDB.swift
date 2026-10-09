import Foundation
import GRDB

public enum StoreError: Error, Equatable, Sendable {
    case schemaTooNew(found: Int, known: Int)
    case emptyGroup
    case emptyRange
    case unknownGroup(Int64)
    case nulByte
}

/// The one SQLite file. Tracker: `DatabaseQueue` (small cache). App: `DatabasePool` (concurrent reads).
/// Both: WAL, synchronous=NORMAL, busy_timeout 5 s, foreign keys on, IMMEDIATE write transactions
/// (GRDB 7's default for `write {}`), so the chain head read + insert can't interleave across processes.
public final class HoursDB: Sendable {
    public enum Role: Sendable { case tracker, app }

    public let writer: any DatabaseWriter
    public let role: Role
    /// Darwin notification name posted after commits; tests pass a unique one.
    public let notifyName: String

    private init(writer: any DatabaseWriter, role: Role, notifyName: String) {
        self.writer = writer; self.role = role; self.notifyName = notifyName
    }

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "hours/hours.db")
    }

    public static func open(at url: URL, role: Role,
                            notifyName: String = Hours.dbChangedNotification) throws -> HoursDB {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        config.journalMode = .wal
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            if role == .tracker { try db.execute(sql: "PRAGMA cache_size = -512") }
        }
        // Switching a fresh file to WAL takes an exclusive lock that SQLite's busy handler doesn't
        // wait on, so app + helper opening a brand-new DB together can get SQLITE_BUSY. Retry.
        func makeWriter() throws -> any DatabaseWriter {
            switch role {
            case .tracker: try DatabaseQueue(path: url.path, configuration: config)
            case .app: try DatabasePool(path: url.path, configuration: config)
            }
        }
        var attempt = 0
        let writer: any DatabaseWriter
        while true {
            do { writer = try makeWriter(); break } catch let e as DatabaseError
                where (e.resultCode == .SQLITE_BUSY || e.resultCode == .SQLITE_LOCKED) && attempt < 50 {
                attempt += 1
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        try writer.write { db in try StoreSchema.migrate(db) }
        return HoursDB(writer: writer, role: role, notifyName: notifyName)
    }

    /// Posts the change notification (both processes receive it, including the poster).
    func didCommit() { ChangeFeed.post(name: notifyName) }

    /// Current chain head (seq 0 = genesis).
    public func head() throws -> (seq: Int64, hash: Data) {
        try writer.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT seq, hash FROM chain_head WHERE id = 1")!
            return (row["seq"], row["hash"])
        }
    }
}

func storeNowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

func storeCheckNul(_ strings: String?...) throws {
    for s in strings where s?.utf8.contains(0) == true { throw StoreError.nulByte }
}
