import Foundation
import GRDB

/// Tracker-side writes. The open span lives unchained in `live_span` (one mutable row); it becomes
/// an immutable chained `span` row only when closed. Every method is one IMMEDIATE transaction.
/// Closing clamps the live span's start to the last chained end, so a wall clock that came back
/// behind the chain (e.g. across a restart) loses that slice instead of tripping the overlap trigger.
public struct SpanWriter: Sendable {
    public let db: HoursDB
    public init(_ db: HoursDB) { self.db = db }

    /// The open span as a `RawSpan` (seq 0, endMs = last heartbeat), or nil.
    public func liveSpan() throws -> RawSpan? {
        try db.writer.read { db in try Self.fetchLive(db) }
    }

    /// Makes `live` the open span. An existing live span is closed at `live.startMs` first.
    public func open(live: RawSpan) throws {
        try close(at: live.startMs, next: live)
    }

    /// Chains the live span as [max(start, last chained end), endMs) — dropped if empty — and
    /// replaces it with `next` (or clears it). Returns the chained seq, or nil if nothing was chained.
    @discardableResult
    public func close(at endMs: Int64, next: RawSpan?) throws -> Int64? {
        if let next { try storeCheckNul(next.tzId, next.bundleId, next.appName, next.title, next.url) }
        let seq = try db.writer.write { db -> Int64? in
            var seq: Int64?
            if var live = try Self.fetchLive(db) {
                // Same expression as the overlap trigger, so a clamped row always passes it.
                if let chainEnd = try Int64.fetchOne(db, sql: "SELECT end_ms FROM span ORDER BY start_ms DESC LIMIT 1") {
                    live.startMs = max(live.startMs, chainEnd)
                }
                live.endMs = endMs
                // The live span's nonce, drawn when it opened, becomes the chained row's `blind`.
                let blind = try Data.fetchOne(db, sql: "SELECT blind FROM live_span WHERE id = 1")!
                if live.endMs > live.startMs { seq = try Self.insert(db, live, blind: blind) }
                try db.execute(sql: "DELETE FROM live_span")
            }
            if let next {
                try db.execute(sql: """
                    INSERT INTO live_span(id, start_ms, last_seen_ms, tz_id, tz_offset_s, kind,
                                          bundle_id, app_name, title, url, blind)
                    VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [next.startMs, max(next.startMs, next.endMs), next.tzId, next.tzOffsetS,
                                     next.kind.rawValue, next.bundleId, next.appName, next.title, next.url,
                                     ChainCodec.newBlind()])
            }
            return seq
        }
        db.didCommit()
        return seq
    }

    /// Advances the live span's `last_seen_ms` (every 30 s). No change notification.
    public func heartbeat(lastSeenMs: Int64) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE live_span SET last_seen_ms = MAX(last_seen_ms, ?)", arguments: [lastSeenMs])
        }
    }

    /// On tracker start: chain a leftover live span at its last heartbeat (undercounts ≤ one interval).
    @discardableResult
    public func recoverLiveSpan() throws -> Int64? {
        guard let live = try liveSpan() else { return nil }
        return try close(at: live.endMs, next: nil)
    }

    /// Chains an already-closed span directly (imports, tests). Returns its seq.
    @discardableResult
    public func append(_ span: RawSpan) throws -> Int64 {
        try storeCheckNul(span.tzId, span.bundleId, span.appName, span.title, span.url)
        let seq = try db.writer.write { db in try Self.insert(db, span, blind: ChainCodec.newBlind()) }
        db.didCommit()
        return seq
    }

    static func insert(_ db: Database, _ s: RawSpan, blind: Data) throws -> Int64 {
        let head = try Row.fetchOne(db, sql: "SELECT seq, hash FROM chain_head WHERE id = 1")!
        let seq: Int64 = head["seq"] + 1
        let prev: Data = head["hash"]
        let content = ChainCodec.spanContent(startMs: s.startMs, endMs: s.endMs, tzId: s.tzId,
                                             tzOffsetS: Int64(s.tzOffsetS), kind: s.kind.rawValue,
                                             bundleId: s.bundleId, appName: s.appName, title: s.title, url: s.url,
                                             blind: blind)
        let hash = ChainCodec.rowHash(seq: seq, prev: prev, content: content)
        try db.execute(sql: """
            INSERT INTO span(seq, start_ms, end_ms, tz_id, tz_offset_s, kind, bundle_id, app_name, title, url,
                             blind, content_hash, prev_hash, hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [seq, s.startMs, s.endMs, s.tzId, s.tzOffsetS, s.kind.rawValue, s.bundleId,
                             s.appName, s.title, s.url, blind, content, prev, hash])
        return seq
    }

    static func fetchLive(_ db: Database) throws -> RawSpan? {
        guard let r = try Row.fetchOne(db, sql: "SELECT * FROM live_span WHERE id = 1") else { return nil }
        return RawSpan(seq: 0, startMs: r["start_ms"], endMs: r["last_seen_ms"], tzId: r["tz_id"],
                       tzOffsetS: r["tz_offset_s"], kind: SpanKind(rawValue: r["kind"]) ?? .active,
                       bundleId: r["bundle_id"], appName: r["app_name"], title: r["title"], url: r["url"])
    }
}
