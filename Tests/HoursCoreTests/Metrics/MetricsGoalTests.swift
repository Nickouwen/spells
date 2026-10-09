import Testing
@testable import HoursCore

private func d(_ month: Int, _ day: Int) -> LocalDate { LocalDate(year: 2026, month: month, day: day) }
private let h: Int64 = 3_600_000

@Suite struct MetricsGoalTests {
    @Test func weekdayToggles() {
        let g = Goal(dailyWorkMs: 6 * h)   // Mon–Fri default
        #expect(g.isScheduled(d(10, 5)))    // Mon
        #expect(g.isScheduled(d(10, 9)))    // Fri
        #expect(!g.isScheduled(d(10, 10)))  // Sat
        #expect(!g.isScheduled(d(10, 11)))  // Sun
        #expect(Goal(dailyWorkMs: h, weekdays: [1]).isScheduled(d(10, 11)))
    }

    @Test func streakSkipsWeekendsAndStopsAtMiss() {
        let g = Goal(dailyWorkMs: 6 * h)
        // Thu 10/1 miss · Fri 10/2 met · Sat/Sun no data · Mon 10/5 met · Tue 10/6 (today) met.
        let work: [LocalDate: Int64] = [d(10, 1): 2 * h, d(10, 2): 7 * h, d(10, 5): 6 * h, d(10, 6): 8 * h]
        #expect(Streak.compute(workMs: work, goal: g, today: d(10, 6)) == 3)
    }

    @Test func todayInProgressIsNotAMiss() {
        let g = Goal(dailyWorkMs: 6 * h)
        let work: [LocalDate: Int64] = [d(10, 5): 6 * h, d(10, 6): 1 * h]
        #expect(Streak.compute(workMs: work, goal: g, today: d(10, 6)) == 1)
    }

    @Test func missingScheduledDayBreaksStreak() {
        let g = Goal(dailyWorkMs: 6 * h)
        // Mon 10/5 absent (0 work) → streak is just Tue.
        let work: [LocalDate: Int64] = [d(10, 2): 7 * h, d(10, 6): 7 * h]
        #expect(Streak.compute(workMs: work, goal: g, today: d(10, 6)) == 1)
    }

    @Test func streakCrossesMonthBoundaryAndStopsAtEarliestData() {
        let g = Goal(dailyWorkMs: h, weekdays: Set(1...7))
        let work: [LocalDate: Int64] = [d(2, 27): h, d(2, 28): h, d(3, 1): h]
        #expect(Streak.compute(workMs: work, goal: g, today: d(3, 1)) == 3)
        #expect(Streak.compute(workMs: [:], goal: g, today: d(3, 1)) == 0)
        #expect(Streak.compute(workMs: work, goal: Goal(dailyWorkMs: h, weekdays: []), today: d(3, 1)) == 0)
    }
}
