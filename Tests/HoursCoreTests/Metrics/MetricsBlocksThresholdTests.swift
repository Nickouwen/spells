import Foundation
import Testing
@testable import HoursCore

/// Break threshold + minimum block length from the settings dictionary (W22 addition 8 / 6).
struct MetricsBlocksThresholdTests {
    static let thu = LocalDate(year: 2026, month: 10, day: 1)   // Thursday = weekday 5
    static let sat = LocalDate(year: 2026, month: 10, day: 3)   // Saturday = weekday 7

    @Test func defaultsWhenUnset() {
        #expect(BlocksThreshold.minutes(for: Self.thu, settings: [:]) == 10)
        #expect(BlocksThreshold.minBlockMinutes([:]) == 0)
        #expect(BlocksThreshold.overrides([:]).isEmpty)
    }

    @Test func weekdayOverrideWinsOverDefault() {
        let s = [BlocksThreshold.defaultKey: "15", BlocksThreshold.weekdayKey: "7:30, 2:5"]
        #expect(BlocksThreshold.weekday(Self.thu) == 5 && BlocksThreshold.weekday(Self.sat) == 7)
        #expect(BlocksThreshold.minutes(for: Self.thu, settings: s) == 15)
        #expect(BlocksThreshold.minutes(for: Self.sat, settings: s) == 30)
        #expect(BlocksThreshold.overrides(s) == [7: 30, 2: 5])
    }

    @Test func malformedValuesFallBack() {
        let s = [BlocksThreshold.defaultKey: "0", BlocksThreshold.weekdayKey: "9:30,5:abc,5:999,x,7:20",
                 BlocksThreshold.minBlockKey: "-3"]
        #expect(BlocksThreshold.defaultMinutes(s) == 10)
        #expect(BlocksThreshold.overrides(s) == [7: 20])
        #expect(BlocksThreshold.minutes(for: Self.thu, settings: s) == 10)
        #expect(BlocksThreshold.minBlockMinutes(s) == 0)
        #expect(BlocksThreshold.minBlockMinutes([BlocksThreshold.minBlockKey: "5"]) == 5)
    }

    /// 18-hour viewport: `blocks_window_hours` (4…24, default 18) and `blocks_window_start` (default 06:00).
    @Test func windowSettings() {
        #expect(BlocksThreshold.windowHours([:]) == 18)
        #expect(BlocksThreshold.windowStartMinutes([:]) == 360)
        #expect(BlocksThreshold.windowHours([BlocksThreshold.windowHoursKey: "12"]) == 12)
        #expect(BlocksThreshold.windowHours([BlocksThreshold.windowHoursKey: "30"]) == 18)
        #expect(BlocksThreshold.windowHours([BlocksThreshold.windowHoursKey: "x"]) == 18)
        #expect(BlocksThreshold.windowStartMinutes([BlocksThreshold.windowStartKey: "07:30"]) == 450)
        #expect(BlocksThreshold.windowStartMinutes([BlocksThreshold.windowStartKey: "25:00"]) == 360)
    }

    @Test func encodeRoundTrips() {
        #expect(BlocksThreshold.encode([:]) == nil)
        #expect(BlocksThreshold.encode([7: 30, 2: 5]) == "2:5,7:30")
        #expect(BlocksThreshold.overrides([BlocksThreshold.weekdayKey: BlocksThreshold.encode([1: 45, 6: 12])!]) == [1: 45, 6: 12])
    }
}
