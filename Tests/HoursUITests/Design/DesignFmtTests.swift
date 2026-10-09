import Foundation
import Testing
@testable import HoursUI

@Suite struct DesignFmtTests {
    static let min: Int64 = 60_000, hour: Int64 = 3_600_000
    static let durationCases: [(Int64, String)] = [
        (0, "0m"),
        (1, "<1m"),
        (59_999, "<1m"),
        (min, "1m"),
        (89_999, "1m"),                       // 1.49 min rounds down
        (90_000, "2m"),                       // half up
        (42 * min, "42m"),
        (59 * min + 29_999, "59m"),
        (59 * min + 30_000, "1h"),            // rounds into the hour
        (hour, "1h"),
        (6 * hour, "6h"),                     // whole hours drop the minutes
        (6 * hour + 29_999, "6h"),
        (6 * hour + 42 * min, "6h 42m"),
        (6 * hour + 42 * min + 29_999, "6h 42m"),
        (25 * hour + 5 * min, "25h 5m"),      // no day rollover in durations
        (-42 * min, "\u{2212}42m"),
    ]

    @Test(arguments: durationCases)
    func duration(ms: Int64, expected: String) {
        #expect(Fmt.duration(ms: ms) == expected)
    }

    @Test func partsSplitValueAndUnit() {
        #expect(Fmt.durationParts(ms: 6 * 3_600_000 + 42 * 60_000) == [.init(value: "6", unit: "h"), .init(value: "42", unit: "m")])
        #expect(Fmt.durationParts(ms: 6 * 3_600_000) == [.init(value: "6", unit: "h")])
        #expect(Fmt.durationParts(ms: 30_000) == [.init(value: "<1", unit: "m")])
        #expect(Fmt.durationParts(ms: -60_000) == [.init(value: "1", unit: "m")])
    }

    @Test func spoken() {
        #expect(Fmt.durationSpoken(ms: 6 * 3_600_000 + 42 * 60_000) == "6 hours 42 minutes")
        #expect(Fmt.durationSpoken(ms: 3_600_000 + 60_000) == "1 hour 1 minute")
        #expect(Fmt.durationSpoken(ms: 10_000) == "less than a minute")
        #expect(Fmt.durationSpoken(ms: 6 * 3_600_000) == "6 hours")
    }

    @Test func clockIs24HourInZone() {
        // 2025-10-05 12:12:00 UTC
        let ms: Int64 = 1_759_666_320_000
        #expect(Fmt.clock(ms: ms, timeZone: TimeZone(identifier: "UTC")!) == "12:12")
        #expect(Fmt.clock(ms: ms, timeZone: TimeZone(identifier: "America/New_York")!) == "08:12")
        #expect(Fmt.clock(ms: ms + 9 * 3_600_000, timeZone: TimeZone(identifier: "UTC")!) == "21:12")
    }

    @Test func percent() {
        #expect(Fmt.percent(0.427) == "43%")
        #expect(Fmt.percent(0) == "0%")
        #expect(Fmt.percent(1) == "100%")
    }
}
