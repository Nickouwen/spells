import Foundation
import GRDB

/// A timestamp attestation of the chain head (item 9 fills these). Insert-only, not chained.
public struct ChainAnchor: Sendable, Hashable {
    public var id: Int64
    public var headSeq: Int64
    public var headHash: Data
    /// e.g. "rfc3161".
    public var method: String
    public var tsa: String?
    public var requestedMs: Int64
    public var genTimeMs: Int64?
    public var token: Data?
    public var nonce: Data?

    public init(id: Int64 = 0, headSeq: Int64, headHash: Data, method: String, tsa: String? = nil,
                requestedMs: Int64, genTimeMs: Int64? = nil, token: Data? = nil, nonce: Data? = nil) {
        self.id = id; self.headSeq = headSeq; self.headHash = headHash; self.method = method; self.tsa = tsa
        self.requestedMs = requestedMs; self.genTimeMs = genTimeMs; self.token = token; self.nonce = nonce
    }
}

public struct AnchorStore: Sendable {
    public let db: HoursDB
    public init(_ db: HoursDB) { self.db = db }

    @discardableResult
    public func insert(_ a: ChainAnchor) throws -> Int64 {
        let id = try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO anchor(head_seq, head_hash, method, tsa, requested_ms, gen_time_ms, token, nonce)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [a.headSeq, a.headHash, a.method, a.tsa, a.requestedMs, a.genTimeMs, a.token, a.nonce])
            return db.lastInsertedRowID
        }
        db.didCommit()
        return id
    }

    /// All anchors, oldest first.
    public func list() throws -> [ChainAnchor] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM anchor ORDER BY id").map {
                ChainAnchor(id: $0["id"], headSeq: $0["head_seq"], headHash: $0["head_hash"], method: $0["method"],
                            tsa: $0["tsa"], requestedMs: $0["requested_ms"], genTimeMs: $0["gen_time_ms"],
                            token: $0["token"], nonce: $0["nonce"])
            }
        }
    }
}

/// Key/value settings (`install_id`, idle threshold, goals…). Mutable, unchained.
public struct SettingStore: Sendable {
    public let db: HoursDB
    public init(_ db: HoursDB) { self.db = db }

    public func get(_ key: String) throws -> String? {
        try db.writer.read { db in try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key]) }
    }

    /// nil removes the key. `notify: false` skips the change-feed post — for a write another commit
    /// has already announced (the helper's `last_event_ms` refresh next to a span write).
    public func set(_ key: String, _ value: String?, notify: Bool = true) throws {
        try db.writer.write { db in
            if let value {
                try db.execute(sql: "INSERT INTO setting(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key])
            }
        }
        if notify { db.didCommit() }
    }

    public func all() throws -> [String: String] {
        try db.writer.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT key, value FROM setting").map {
                ($0["key"] as String, $0["value"] as String)
            })
        }
    }
}
