import Foundation

/// The one-line invoice witness (09 D2): period, billed hours, timesheet digest and the chain head.
/// Pasted into the invoice memo, the client's copy pins the head — a later chain must extend it.
public enum ExportWitness {
    /// `hours 2026-09-16..2026-09-30 | 61.25 h | timesheet.csv sha256:<64 hex> | head #4521 <64 hex> | anchored <genTime> by digicert`
    public static func line(db: HoursDB, period: ExportPeriod) throws -> String {
        let data = try ExportPeriodData.load(db, period: period)
        let head = try db.head()
        let anchor = try AnchorStore(db).list().last { $0.headSeq == head.seq && $0.genTimeMs != nil }
        return line(period: period, data: data, headSeq: head.seq, headHash: head.hash, anchor: anchor)
    }

    static func line(period: ExportPeriod, data: ExportPeriodData, headSeq: Int64, headHash: Data,
                     anchor: ChainAnchor?) -> String {
        let anchored = anchor.map { "anchored \(exportUTC($0.genTimeMs!)) by \($0.tsa ?? "tsa")" } ?? "head not yet anchored"
        return "hours \(period) | \(ExportPeriodData.hours(data.totalHundredths)) h"
            + " | timesheet.csv sha256:\(exportSHA256Hex(data.timesheetCSV))"
            + " | head #\(headSeq) \(exportHex(headHash)) | \(anchored)"
    }
}
