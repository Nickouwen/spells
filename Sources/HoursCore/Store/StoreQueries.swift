import Foundation
import GRDB

/// Read side. Everything downstream reads effective spans from here, never raw tables.
public struct Store: Sendable {
    public let db: HoursDB
    public init(_ db: HoursDB) { self.db = db }

    /// Effective spans of local day `day`, each clipped to [D hh:00, D+1 hh:00) in its **own** `tzId`
    /// (travel days can exceed 24 h; DST days are 23/25 h). The live span is included, ending at its last heartbeat.
    public func effectiveSpans(day: LocalDate, dayStartHour: Int = Hours.defaultDayStartHour) throws -> [EffectiveSpan] {
        // Candidate window covers every tz (UTC−12…+14) plus an hour of slack each side.
        let h: Int64 = 3_600_000
        let midnight = day.storeUTCMidnightMs + Int64(dayStartHour) * h
        let spans = try effective(lo: midnight - 15 * h, hi: midnight + 24 * h + 13 * h)
        var bounds: [String: Range<Int64>] = [:]
        return spans.compactMap { s in
            let b = bounds[s.tzId] ?? {
                let r = day.dayInterval(in: TimeZone(identifier: s.tzId) ?? .gmt, dayStartHour: dayStartHour)
                bounds[s.tzId] = r
                return r
            }()
            var c = s
            c.startMs = max(s.startMs, b.lowerBound); c.endMs = min(s.endMs, b.upperBound)
            return c.endMs > c.startMs ? c : nil
        }
    }

    /// Effective spans clipped to the absolute range [lo, hi).
    public func effectiveSpans(rangeFrom lo: Int64, to hi: Int64) throws -> [EffectiveSpan] {
        storeClip(try effective(lo: lo, hi: hi), lo, hi)
    }

    /// Raw spans touching [lo, hi) (start in range, plus the one predecessor that may extend into it),
    /// then the live span (seq 0) if it touches the range. Sorted by start.
    public func rawSpans(from lo: Int64, to hi: Int64) throws -> [RawSpan] {
        try db.writer.read { db in try Self.raw(db, lo, hi) }
    }

    /// Edits whose range overlaps [lo, hi), by seq. Because undo/note copy their target group's hull,
    /// every undo that can affect an overlapping edit overlaps too — no fixed-point widening needed.
    public func edits(overlapping lo: Int64, _ hi: Int64) throws -> [Edit] {
        try db.writer.read { db in try Self.edits(db, lo, hi) }
    }

    /// Every edit, by seq (edit history; ~10k/yr).
    public func allEdits() throws -> [Edit] {
        try db.writer.read { db in try Row.fetchAll(db, sql: "SELECT * FROM edit ORDER BY seq").map(Self.edit) }
    }

    private func effective(lo: Int64, hi: Int64) throws -> [EffectiveSpan] {
        let (raw, edits) = try db.writer.read { db in (try Self.raw(db, lo, hi), try Self.edits(db, lo, hi)) }
        return HoursCore.effectiveSpans(raw: raw, edits: edits)
    }

    static func raw(_ db: Database, _ lo: Int64, _ hi: Int64) throws -> [RawSpan] {
        let cols = "seq, start_ms, end_ms, tz_id, tz_offset_s, kind, bundle_id, app_name, title, url"
        var out: [RawSpan] = []
        if let p = try Row.fetchOne(db, sql: "SELECT \(cols) FROM span WHERE start_ms < ? ORDER BY start_ms DESC LIMIT 1",
                                    arguments: [lo]).map(span), p.endMs > lo {
            out.append(p)
        }
        out += try Row.fetchAll(db, sql: "SELECT \(cols) FROM span WHERE start_ms >= ? AND start_ms < ? ORDER BY start_ms",
                                arguments: [lo, hi]).map(span)
        if let live = try SpanWriter.fetchLive(db), live.startMs < hi, live.endMs > lo { out.append(live) }
        return out
    }

    static func edits(_ db: Database, _ lo: Int64, _ hi: Int64) throws -> [Edit] {
        try Row.fetchAll(db, sql: "SELECT * FROM edit WHERE lo_ms < ? AND hi_ms > ? ORDER BY seq",
                         arguments: [hi, lo]).map(edit)
    }

    static func span(_ r: Row) -> RawSpan {
        RawSpan(seq: r["seq"], startMs: r["start_ms"], endMs: r["end_ms"], tzId: r["tz_id"], tzOffsetS: r["tz_offset_s"],
                kind: SpanKind(rawValue: r["kind"]) ?? .active, bundleId: r["bundle_id"], appName: r["app_name"],
                title: r["title"], url: r["url"])
    }

    static func edit(_ r: Row) -> Edit {
        let op = EditOp(rawValue: r["op"]) ?? .note
        return Edit(seq: r["seq"], grp: r["grp"], createdMs: r["created_ms"], tzId: r["tz_id"], op: op,
                    loMs: r["lo_ms"], hiMs: r["hi_ms"], target: r["target"], payload: EditPayload(op: op, json: r["payload"]))
    }
}
