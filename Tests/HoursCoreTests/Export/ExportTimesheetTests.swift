import Foundation
import Testing
@testable import HoursCore

@Suite struct ExportTimesheetTests {
    /// Hand-computed from the fixture (see `exportFixtureDB`):
    ///   09-16 operations-dashboard  seq 3                          1200 s → 0.33
    ///   09-16 spells  seq 2 trimmed 4800 + seq 6 600 + seq 7 1800    7200 s → 2.00
    ///   09-17 spells  seq 7 after 04:00                              1800 s → 0.50
    ///   09-18 spells  manual add (meetings is work)                  1200 s → 0.33  (label is private → "Manual entry")
    ///   09-30 spells  seq 8 before 04:00 on 10-01                    3600 s → 1.00
    /// Slack (work, no project), YouTube (not work), 09-15 and 10-01 04:00+ are not billable.
    static let golden = """
    date,project,hours,seconds,summary
    2026-09-16,operations-dashboard,0.33,1200,Code 0.3h
    2026-09-16,spells,2.00,7200,Code 1.3h; cmux 0.5h; Google Chrome 0.2h
    2026-09-17,spells,0.50,1800,cmux 0.5h
    2026-09-18,spells,0.33,1200,Manual entry 0.3h
    2026-09-30,spells,1.00,3600,cmux 1.0h

    """

    @Test func goldenPlainCSV() throws {
        let db = try exportFixtureDB()
        let data = try ExportPeriodData.load(db, period: exportFixturePeriod)
        #expect(String(decoding: data.timesheetCSV, as: UTF8.self) == Self.golden)

        let dir = exportTempDir()
        let r = try ExportBundle.write(db: db, period: exportFixturePeriod, mode: .plain, to: dir, tz: exportUTCZone)
        #expect(r.files == ["timesheet.csv"])
        #expect(try Data(contentsOf: dir.appending(path: "timesheet.csv")) == Data(Self.golden.utf8))
    }

    @Test func totalIsSumOfRoundedRows() throws {
        let data = try ExportPeriodData.load(try exportFixtureDB(), period: exportFixturePeriod)
        // D9: 0.33 + 2.00 + 0.50 + 0.33 + 1.00 = 4.16, although the exact 15 000 s would round to 4.17.
        #expect(data.totalHundredths == 416)
        #expect(ExportPeriodData.hours(data.totalHundredths) == "4.16")
        #expect(data.metrics.billableMs == 15_000_000)
        #expect(data.rows.map(\.ms).reduce(0, +) == data.metrics.billableMs)
        #expect(data.metrics.unassignedWorkMs == 1_800_000)   // Slack
    }

    @Test func roundingIsHalfUpPerRow() {
        #expect(ExportPeriodData.hours((18_000 * 100 + 1_800_000) / 3_600_000) == "0.01")   // 18 s = 0.005 h → up
        #expect(ExportPeriodData.hours((17_999 * 100 + 1_800_000) / 3_600_000) == "0.00")
        #expect(ExportPeriodData.hours(12_345) == "123.45")
        #expect(ExportPeriodData.hours(5) == "0.05")
    }

    @Test func witnessLinePinsTimesheetAndHead() throws {
        let db = try exportFixtureDB()
        let line = try ExportWitness.line(db: db, period: exportFixturePeriod)
        let head = try db.head()
        let csvHash = exportSHA256Hex(Data(Self.golden.utf8))
        #expect(line == "hours 2026-09-16..2026-09-30 | 4.16 h | timesheet.csv sha256:\(csvHash) | head #10 \(exportHex(head.hash)) | head not yet anchored")
    }
}
