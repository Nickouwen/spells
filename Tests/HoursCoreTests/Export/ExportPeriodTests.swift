import Foundation
import Testing
@testable import HoursCore

@Suite struct ExportPeriodTests {
    func d(_ y: Int, _ m: Int, _ day: Int) -> LocalDate { LocalDate(year: y, month: m, day: day) }
    func p(_ a: LocalDate, _ b: LocalDate) -> ExportPeriod { ExportPeriod(from: a, through: b) }

    @Test func previousAndCurrentAroundThe15th() {
        // 09 acceptance 8: previous on 10-16 = [10-01, 10-16); on 11-01 = [10-16, 11-01).
        #expect(ExportPeriod.parse("previous", today: d(2026, 10, 16)) == p(d(2026, 10, 1), d(2026, 10, 15)))
        #expect(ExportPeriod.parse("previous", today: d(2026, 11, 1)) == p(d(2026, 10, 16), d(2026, 10, 31)))
        #expect(ExportPeriod.parse("previous", today: d(2026, 10, 15)) == p(d(2026, 9, 16), d(2026, 9, 30)))
        #expect(ExportPeriod.parse("current", today: d(2026, 10, 15)) == p(d(2026, 10, 1), d(2026, 10, 15)))
        #expect(ExportPeriod.parse("current", today: d(2026, 10, 16)) == p(d(2026, 10, 16), d(2026, 10, 31)))
        #expect(ExportPeriod.parse("current", today: d(2026, 9, 30)) == p(d(2026, 9, 16), d(2026, 9, 30)))
    }

    @Test func februaryAndYearBoundaries() {
        #expect(ExportPeriod.parse("current", today: d(2028, 2, 20)) == p(d(2028, 2, 16), d(2028, 2, 29)))   // leap
        #expect(ExportPeriod.parse("current", today: d(2026, 2, 20)) == p(d(2026, 2, 16), d(2026, 2, 28)))
        #expect(ExportPeriod.parse("current", today: d(2100, 2, 16)) == p(d(2100, 2, 16), d(2100, 2, 28)))   // century, not leap
        #expect(ExportPeriod.parse("current", today: d(2000, 2, 16)) == p(d(2000, 2, 16), d(2000, 2, 29)))   // 400-year leap
        #expect(ExportPeriod.parse("previous", today: d(2028, 3, 1)) == p(d(2028, 2, 16), d(2028, 2, 29)))
        #expect(ExportPeriod.parse("previous", today: d(2026, 1, 10)) == p(d(2025, 12, 16), d(2025, 12, 31)))
        #expect(ExportPeriod.parse("previous", today: d(2026, 4, 30)) == p(d(2026, 4, 1), d(2026, 4, 15)))
        #expect(ExportPeriod.parse("current", today: d(2026, 4, 30)) == p(d(2026, 4, 16), d(2026, 4, 30)))
    }

    @Test func todayFollowsTheFourAmDayStart() {
        // 02:00 on Oct 16 still belongs to store day Oct 15 → previous = Sep 16–30.
        let tz = TimeZone(identifier: "America/Vancouver")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let at2am = Int64(cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 2))!.timeIntervalSince1970 * 1000)
        let today = LocalDate.containing(ms: at2am, in: tz)
        #expect(today == d(2026, 10, 15))
        #expect(ExportPeriod.parse("previous", today: today) == p(d(2026, 9, 16), d(2026, 9, 30)))
    }

    @Test func explicitRanges() {
        let today = d(2026, 10, 5)
        #expect(ExportPeriod.parse("2026-09-01..2026-09-15", today: today) == p(d(2026, 9, 1), d(2026, 9, 15)))
        #expect(ExportPeriod.parse("2028-02-29..2028-02-29", today: today) == p(d(2028, 2, 29), d(2028, 2, 29)))
        for bad in ["2026-02-29..2026-03-01", "2026-09-15..2026-09-01", "2026-9-1..2026-9-15", "last", "2026-09-01"] {
            #expect(ExportPeriod.parse(bad, today: today) == nil, "\(bad)")
        }
        #expect(p(d(2026, 9, 16), d(2026, 9, 30)).days.count == 15)
        #expect(p(d(2028, 2, 16), d(2028, 3, 1)).days.map(\.description).suffix(2) == ["2028-02-29", "2028-03-01"])
    }
}
