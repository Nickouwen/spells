import Foundation
import Testing
@testable import HoursCore

@Suite struct StoreDayTests {
    let ny = TimeZone(identifier: "America/New_York")!
    static let h: Int64 = 3_600_000

    /// ISO-8601 UTC → ms.
    static func z(_ s: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: s)!.timeIntervalSince1970 * 1000)
    }

    @Test func dstDayLengthsWithDayStart4() {
        // Spring forward 2026-03-08 02:00 local falls inside day 3/7 (3/7 04:00 EST → 3/8 04:00 EDT).
        let d37 = LocalDate(year: 2026, month: 3, day: 7).dayInterval(in: ny, dayStartHour: 4)
        #expect(d37 == Self.z("2026-03-07T09:00:00Z")..<Self.z("2026-03-08T08:00:00Z"))
        #expect(d37.count == 23 * Int(Self.h))
        let d38 = LocalDate(year: 2026, month: 3, day: 8).dayInterval(in: ny, dayStartHour: 4)
        #expect(d38.count == 24 * Int(Self.h))
        // Fall back 2026-11-01 02:00 EDT → 01:00 EST falls inside day 10/31.
        let d1031 = LocalDate(year: 2026, month: 10, day: 31).dayInterval(in: ny, dayStartHour: 4)
        #expect(d1031 == Self.z("2026-10-31T08:00:00Z")..<Self.z("2026-11-01T09:00:00Z"))
        #expect(d1031.count == 25 * Int(Self.h))
    }

    @Test func dstDayLengthsAtMidnight() {
        // 02's original checks: local day 3/8 is 05:00Z → 04:00Z next day; 11/1 is 04:00Z → 05:00Z.
        #expect(LocalDate(year: 2026, month: 3, day: 8).dayInterval(in: ny, dayStartHour: 0)
                == Self.z("2026-03-08T05:00:00Z")..<Self.z("2026-03-09T04:00:00Z"))
        #expect(LocalDate(year: 2026, month: 11, day: 1).dayInterval(in: ny, dayStartHour: 0)
                == Self.z("2026-11-01T04:00:00Z")..<Self.z("2026-11-02T05:00:00Z"))
    }

    @Test func containing() {
        // 2026-03-08 03:30 EDT doesn't exist; 07:30Z = 03:30 EDT → before 04:00 → day 3/7.
        #expect(LocalDate.containing(ms: Self.z("2026-03-08T07:30:00Z"), in: ny, dayStartHour: 4)
                == LocalDate(year: 2026, month: 3, day: 7))
        #expect(LocalDate.containing(ms: Self.z("2026-03-08T08:00:00Z"), in: ny, dayStartHour: 4)
                == LocalDate(year: 2026, month: 3, day: 8))
        #expect(LocalDate.containing(ms: Self.z("2026-01-01T04:59:59Z"), in: ny, dayStartHour: 0)
                == LocalDate(year: 2025, month: 12, day: 31))
    }

    @Test func spanSplitsAcrossLocalMidnight() throws {
        // 02: span 2026-03-08T04:30Z–05:30Z (23:30–00:30 EST) → 30 min in 3/7 and 30 min in 3/8 (midnight days).
        let db = try storeTempDB()
        try SpanWriter(db).append(storeRaw(0, Self.z("2026-03-08T04:30:00Z"), Self.z("2026-03-08T05:30:00Z"),
                                           tz: "America/New_York"))
        let store = Store(db)
        func total(_ d: Int, _ hh: Int) throws -> Int64 {
            try store.effectiveSpans(day: LocalDate(year: 2026, month: 3, day: d), dayStartHour: hh)
                .reduce(0) { $0 + $1.durationMs }
        }
        #expect(try total(7, 0) == 30 * 60_000)
        #expect(try total(8, 0) == 30 * 60_000)
        // With the 04:00 boundary the whole hour belongs to 3/7.
        #expect(try total(7, 4) == 60 * 60_000)
        #expect(try total(8, 4) == 0)
    }

    @Test func flightSpansLandInTheirOwnLocalDay() throws {
        // NY 2026-06-10 23:00–23:30 EDT, then Amsterdam 07:00–08:00 CEST 6/11 (= 01:00–02:00 EDT,
        // which NY would put on 6/10). Each span is placed by its own tz.
        let db = try storeTempDB()
        let w = SpanWriter(db)
        try w.append(storeRaw(0, Self.z("2026-06-11T03:00:00Z"), Self.z("2026-06-11T03:30:00Z"), app: "NY",
                              tz: "America/New_York"))
        try w.append(storeRaw(0, Self.z("2026-06-11T05:00:00Z"), Self.z("2026-06-11T06:00:00Z"), app: "AMS",
                              tz: "Europe/Amsterdam"))
        let store = Store(db)
        #expect(try store.effectiveSpans(day: LocalDate(year: 2026, month: 6, day: 10)).map(\.appName) == ["NY"])
        #expect(try store.effectiveSpans(day: LocalDate(year: 2026, month: 6, day: 11)).map(\.appName) == ["AMS"])
    }

    @Test func dayIncludesPredecessorAndEditsFromOutsideWindow() throws {
        // A long span starting the previous day, and an assign whose range starts before the window.
        let db = try storeTempDB()
        let start = Self.z("2026-05-01T00:00:00Z"), end = Self.z("2026-05-03T00:00:00Z")
        try SpanWriter(db).append(storeRaw(0, start, end))
        try EditWriter(db).apply([.assign(start, end, categoryId: 8, projectId: nil)])
        let out = try Store(db).effectiveSpans(day: LocalDate(year: 2026, month: 5, day: 2), dayStartHour: 0)
        #expect(out.map(\.storeShape) == [[Self.z("2026-05-02T00:00:00Z"), Self.z("2026-05-03T00:00:00Z"), 1, 8]])
    }
}
