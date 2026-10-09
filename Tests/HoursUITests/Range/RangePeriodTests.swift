import Testing
import HoursCore
@testable import HoursUI

@Suite struct RangePeriodTests {
    @Test func billingHalvesAroundThe15th() {
        #expect(RangePeriod.currentBilling.bounds(today: rd(2026, 10, 15)) == rd(2026, 10, 1)...rd(2026, 10, 15))
        #expect(RangePeriod.currentBilling.bounds(today: rd(2026, 10, 1)) == rd(2026, 10, 1)...rd(2026, 10, 15))
        #expect(RangePeriod.currentBilling.bounds(today: rd(2026, 10, 16)) == rd(2026, 10, 16)...rd(2026, 10, 31))
        #expect(RangePeriod.currentBilling.bounds(today: rd(2026, 9, 30)) == rd(2026, 9, 16)...rd(2026, 9, 30))
    }

    /// Item 9's acceptance pair: `previous` on 10-16 → 1–15 Oct; on 11-01 → 16–31 Oct.
    @Test func previousBillingMatchesExportPresets() {
        #expect(RangePeriod.previousBilling.bounds(today: rd(2026, 10, 16)) == rd(2026, 10, 1)...rd(2026, 10, 15))
        #expect(RangePeriod.previousBilling.bounds(today: rd(2026, 11, 1)) == rd(2026, 10, 16)...rd(2026, 10, 31))
        #expect(RangePeriod.previousBilling.bounds(today: rd(2026, 10, 15)) == rd(2026, 9, 16)...rd(2026, 9, 30))
        #expect(RangePeriod.previousBilling.bounds(today: rd(2026, 10, 31)) == rd(2026, 10, 1)...rd(2026, 10, 15))
    }

    @Test func februaryAndLeapYear() {
        #expect(RangePeriod.currentBilling.bounds(today: rd(2026, 2, 20)) == rd(2026, 2, 16)...rd(2026, 2, 28))
        #expect(RangePeriod.currentBilling.bounds(today: rd(2028, 2, 16)) == rd(2028, 2, 16)...rd(2028, 2, 29))
        #expect(RangePeriod.previousBilling.bounds(today: rd(2028, 3, 3)) == rd(2028, 2, 16)...rd(2028, 2, 29))
        #expect(RangePeriod.previousBilling.bounds(today: rd(2026, 3, 15)) == rd(2026, 2, 16)...rd(2026, 2, 28))
        #expect(RangePeriod.thisMonth.bounds(today: rd(2028, 2, 1)) == rd(2028, 2, 1)...rd(2028, 2, 29))
        #expect(RangePeriod.thisMonth.bounds(today: rd(2100, 2, 10)) == rd(2100, 2, 1)...rd(2100, 2, 28))  // century, not leap
    }

    @Test func yearRollover() {
        #expect(RangePeriod.previousBilling.bounds(today: rd(2027, 1, 10)) == rd(2026, 12, 16)...rd(2026, 12, 31))
        #expect(RangePeriod.currentBilling.bounds(today: rd(2026, 12, 31)) == rd(2026, 12, 16)...rd(2026, 12, 31))
        // 1 Jan 2026 is a Thursday: its Monday-start week is 29 Dec 2025 – 4 Jan 2026.
        #expect(RangePeriod.thisWeek.bounds(today: rd(2026, 1, 1)) == rd(2025, 12, 29)...rd(2026, 1, 4))
        #expect(RangePeriod.lastWeek.bounds(today: rd(2026, 1, 1)) == rd(2025, 12, 22)...rd(2025, 12, 28))
    }

    @Test func weeksStartMonday() {
        // 5 Oct 2026 is a Monday; 11 Oct a Sunday.
        #expect(RangePeriod.thisWeek.bounds(today: rd(2026, 10, 5)) == rd(2026, 10, 5)...rd(2026, 10, 11))
        #expect(RangePeriod.thisWeek.bounds(today: rd(2026, 10, 11)) == rd(2026, 10, 5)...rd(2026, 10, 11))
        #expect(RangePeriod.lastWeek.bounds(today: rd(2026, 10, 5)) == rd(2026, 9, 28)...rd(2026, 10, 4))
    }

    @Test func customIsInclusiveAndOrderInsensitive() {
        #expect(RangePeriod.custom(rd(2026, 10, 9), rd(2026, 10, 2)).bounds(today: rd(2030, 1, 1)) == rd(2026, 10, 2)...rd(2026, 10, 9))
    }

    @Test func steppingWalksAdjacentPeriods() {
        let t = rd(2026, 10, 5)
        // Current (1–15 Oct) back → the previous preset (16–30 Sep), then further back → 1–15 Sep (custom).
        #expect(RangePeriod.currentBilling.stepped(-1, today: t) == .previousBilling)
        #expect(RangePeriod.previousBilling.stepped(-1, today: t) == .custom(rd(2026, 9, 1), rd(2026, 9, 15)))
        #expect(RangePeriod.previousBilling.stepped(1, today: t) == .currentBilling)
        #expect(RangePeriod.currentBilling.stepped(1, today: t) == .custom(rd(2026, 10, 16), rd(2026, 10, 31)))
        // A custom period shaped like a billing half keeps stepping by halves: leap Feb 16–29 → 1–15 Mar.
        #expect(RangePeriod.custom(rd(2028, 2, 16), rd(2028, 2, 29)).stepped(1, today: t) == .custom(rd(2028, 3, 1), rd(2028, 3, 15)))
        #expect(RangePeriod.custom(rd(2026, 10, 16), rd(2026, 10, 31)).stepped(1, today: t) == .custom(rd(2026, 11, 1), rd(2026, 11, 15)))
        #expect(RangePeriod.custom(rd(2026, 3, 1), rd(2026, 3, 15)).stepped(-1, today: t) == .custom(rd(2026, 2, 16), rd(2026, 2, 28)))
        #expect(RangePeriod.custom(rd(2026, 10, 2), rd(2026, 10, 4)).stepped(1, today: t) == .custom(rd(2026, 10, 5), rd(2026, 10, 7)))
        #expect(RangePeriod.thisMonth.stepped(-1, today: rd(2027, 1, 20)) == .custom(rd(2026, 12, 1), rd(2026, 12, 31)))
        #expect(RangePeriod.thisWeek.stepped(-1, today: t) == .lastWeek)
    }

    @Test func labels() {
        #expect(RangePeriod.label(rd(2026, 10, 1)...rd(2026, 10, 15)) == "1–15 Oct 2026")
        #expect(RangePeriod.label(rd(2026, 9, 28)...rd(2026, 10, 4)) == "28 Sep – 4 Oct 2026")
        #expect(RangePeriod.label(rd(2025, 12, 29)...rd(2026, 1, 4)) == "29 Dec 2025 – 4 Jan 2026")
    }
}
