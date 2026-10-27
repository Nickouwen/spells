import Foundation

/// Daily work-hours target with weekday toggles (PLAN Q13). Week target = Σ over scheduled days.
public struct Goal: Codable, Sendable, Hashable {
    public var dailyWorkMs: Int64
    /// Calendar weekdays the target applies to: 1 = Sunday … 7 = Saturday.
    public var weekdays: Set<Int>

    public init(dailyWorkMs: Int64, weekdays: Set<Int> = [2, 3, 4, 5, 6]) {
        self.dailyWorkMs = dailyWorkMs; self.weekdays = weekdays
    }

    public func isScheduled(_ day: LocalDate) -> Bool { weekdays.contains(MetricsCalendar.weekday(day)) }
}

public enum Streak {
    /// Consecutive scheduled days, walking back from `today`, with work >= goal. Unscheduled days are
    /// skipped. Today counts if already met and is never a miss (the day isn't over). Days absent
    /// from `workMs` are 0 work; the walk stops at the earliest date present.
    public static func compute(workMs: [LocalDate: Int64], goal: Goal, today: LocalDate) -> Int {
        guard !goal.weekdays.isEmpty, let earliest = workMs.keys.min() else { return 0 }
        var count = 0
        var d = today
        while d >= earliest {
            if goal.isScheduled(d) {
                if (workMs[d] ?? 0) >= goal.dailyWorkMs { count += 1 } else if d != today { break }
            }
            d = MetricsCalendar.previous(d)
        }
        return count
    }
}

private enum MetricsCalendar {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .gmt
        return c
    }()

    static func date(_ d: LocalDate) -> Date {
        cal.date(from: DateComponents(year: d.year, month: d.month, day: d.day))!
    }

    static func weekday(_ d: LocalDate) -> Int { cal.component(.weekday, from: date(d)) }

    static func previous(_ d: LocalDate) -> LocalDate {
        let c = cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: -1, to: date(d))!)
        return LocalDate(year: c.year!, month: c.month!, day: c.day!)
    }
}
