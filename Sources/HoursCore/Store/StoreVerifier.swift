import Foundation
import GRDB

public struct VerifyResult: Sendable, Equatable {
    /// Rows checked before stopping.
    public var rows: Int64
    /// nil = the whole chain verifies.
    public var firstBadSeq: Int64?
    public var reason: String?
    public var ok: Bool { firstBadSeq == nil }
}

/// Walks span ∪ edit in seq order: contiguous from 1, prev links, recomputed content and row hashes,
/// final row == `chain_head`, and every anchor's head_hash == the row hash at its head_seq.
public enum ChainVerifier {
    public static func verify(_ db: HoursDB) throws -> VerifyResult {
        try db.writer.read { db in try verify(db) }
    }

    static func verify(_ db: Database) throws -> VerifyResult {
        guard let installId = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = 'install_id'") else {
            return VerifyResult(rows: 0, firstBadSeq: 1, reason: "missing install_id")
        }
        var anchors: [Int64: [Data]] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT head_seq, head_hash FROM anchor") {
            anchors[r["head_seq"], default: []].append(r["head_hash"])
        }
        let spans = try Row.fetchCursor(db, sql: """
            SELECT seq, start_ms, end_ms, tz_id, tz_offset_s, kind, bundle_id, app_name, title, url,
                   blind, content_hash, prev_hash, hash FROM span ORDER BY seq
            """)
        let edits = try Row.fetchCursor(db, sql: """
            SELECT seq, grp, created_ms, tz_id, op, lo_ms, hi_ms, target, payload,
                   blind, content_hash, prev_hash, hash FROM edit ORDER BY seq
            """)
        var s = try spans.next(), e = try edits.next()
        var expected: Int64 = 1
        var prev = ChainCodec.genesis(installId: installId)
        func fail(_ seq: Int64, _ why: String) -> VerifyResult {
            VerifyResult(rows: expected - 1, firstBadSeq: seq, reason: why)
        }

        while s != nil || e != nil {
            let isSpan: Bool
            if let s, let e { isSpan = (s["seq"] as Int64) < (e["seq"] as Int64) } else { isSpan = s != nil }
            let r = isSpan ? s! : e!
            let seq: Int64 = r["seq"]
            if seq != expected { return fail(expected, seq > expected ? "missing row" : "duplicate seq") }
            let content = isSpan
                ? ChainCodec.spanContent(startMs: r["start_ms"], endMs: r["end_ms"], tzId: r["tz_id"],
                                         tzOffsetS: r["tz_offset_s"], kind: r["kind"], bundleId: r["bundle_id"],
                                         appName: r["app_name"], title: r["title"], url: r["url"], blind: r["blind"])
                : ChainCodec.editContent(createdMs: r["created_ms"], tzId: r["tz_id"], op: r["op"], loMs: r["lo_ms"],
                                         hiMs: r["hi_ms"], target: r["target"], payload: r["payload"], grp: r["grp"],
                                         blind: r["blind"])
            if (r["prev_hash"] as Data) != prev { return fail(seq, "prev_hash mismatch") }
            if (r["content_hash"] as Data) != content { return fail(seq, "content_hash mismatch") }
            let hash = ChainCodec.rowHash(seq: seq, prev: prev, content: content)
            if (r["hash"] as Data) != hash { return fail(seq, "hash mismatch") }
            if let a = anchors.removeValue(forKey: seq), a.contains(where: { $0 != hash }) {
                return fail(seq, "anchor contradicts chain")
            }
            prev = hash
            expected += 1
            if isSpan { s = try spans.next() } else { e = try edits.next() }
        }

        let last = expected - 1
        let head = try Row.fetchOne(db, sql: "SELECT seq, hash FROM chain_head WHERE id = 1")!
        if (head["seq"] as Int64) != last || (head["hash"] as Data) != prev {
            return fail(last + 1, "chain_head mismatch")
        }
        if let beyond = anchors.keys.min() {
            return fail(beyond, beyond == 0 ? "anchor at genesis" : "anchor beyond head (truncated chain)")
        }
        return VerifyResult(rows: last, firstBadSeq: nil, reason: nil)
    }
}
