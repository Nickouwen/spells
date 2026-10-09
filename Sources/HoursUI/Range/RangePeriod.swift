import Foundation
import HoursCore

/// A reporting period, resolved against "today" into an inclusive run of local days.
///
/// Boundary semantics (shared with item 9's export presets; the orchestrator reconciles):
/// - A period is an inclusive `ClosedRange<LocalDate>`. Each `LocalDate` is the store's day,
///   `[D 04:00, D+1 04:00)` in each span's own tz (`Hours.defaultDayStartHour`), so "1–15" covers
///   `[1st 04:00, 16th 04:00)` local and a late-night span on the 15th stays on the 15th.
/// - Billing halves: day 1…15 and day 16…end-of-month (calendar EOM: 28/29/30/31).
/// - `currentBilling` = the half containing today (runs to its last day even if that's in the future).
/// - `previousBilling` = the half before it: on day ≤ 15 → 16…EOM of last month; on day ≥ 16 → 1…15 of this month.
/// - Weeks start Monday (`thisWeek` = Mon…Sun containing today). Months are calendar months.
/// - `custom(a, b)` is inclusive and order-insensitive.
/// - "today" is itself a store day (`LocalDate.containing(ms: now, in: .current)`), so 02:00 on the 16th is still the 15th.
public enum RangePeriod: Hashable, Sendable {
    case currentBilling, previousBilling, thisWeek, lastWeek, thisMonth
    case custom(LocalDate, LocalDate)

    /// Presets in menu order.
    public static let presets: [RangePeriod] = [.currentBilling, .previousBilling, .thisWeek, .lastWeek, .thisMonth]

    public func bounds(today t: LocalDate) -> ClosedRange<LocalDate> {
        switch self {
        case .currentBilling:
            return t.day <= 15 ? t.withDay(1)...t.withDay(15) : t.withDay(16)...t.endOfMonth
        case .previousBilling:
            if t.day >= 16 { return t.withDay(1)...t.withDay(15) }
            let p = t.withDay(1).adding(days: -1)
            return p.withDay(16)...p.endOfMonth
        case .thisWeek:
            let mon = t.adding(days: -t.isoWeekdayIndex)
            return mon...mon.adding(days: 6)
        case .lastWeek:
            let mon = t.adding(days: -t.isoWeekdayIndex - 7)
            return mon...mon.adding(days: 6)
        case .thisMonth:
            return t.withDay(1)...t.endOfMonth
        case let .custom(a, b):
            return min(a, b)...max(a, b)
        }
    }

    /// Menu label for presets; date span for custom.
    public var name: String {
        switch self {
        case .currentBilling: "Current billing period"
        case .previousBilling: "Previous billing period"
        case .thisWeek: "This week"
        case .lastWeek: "Last week"
        case .thisMonth: "This month"
        case .custom: "Custom"
        }
    }

    /// The adjacent period (`delta` = ±1), judged by shape so a stepped-to custom period keeps
    /// stepping the same way: a billing half (1–15 / 16–EOM) steps by half-month, a whole calendar
    /// month by month, anything else (weeks included) by its own length. Lands back on a preset
    /// when the bounds match one.
    public func stepped(_ delta: Int, today: LocalDate) -> RangePeriod {
        let b = bounds(today: today)
        let a = b.lowerBound, z = b.upperBound
        let sameMonth = a.year == z.year && a.month == z.month
        let next: ClosedRange<LocalDate>
        if sameMonth && a.day == 1 && z == a.endOfMonth {
            let first = delta > 0 ? z.adding(days: 1) : a.adding(days: -1).withDay(1)
            next = first...first.endOfMonth
        } else if sameMonth && a.day == 1 && z.day == 15 {
            next = delta > 0 ? a.withDay(16)...a.endOfMonth : RangePeriod.previousBilling.bounds(today: a)
        } else if sameMonth && a.day == 16 && z == a.endOfMonth {
            next = delta > 0 ? RangePeriod.currentBilling.bounds(today: z.adding(days: 1)) : a.withDay(1)...a.withDay(15)
        } else {
            let len = a.days(to: z) + 1
            next = a.adding(days: len * delta)...z.adding(days: len * delta)
        }
        return Self.presets.first { $0.bounds(today: today) == next } ?? .custom(next.lowerBound, next.upperBound)
    }

    /// `1–15 Oct 2026`, `16–31 Oct 2026`, `28 Sep – 4 Oct 2026`, `29 Dec 2025 – 4 Jan 2026`.
    public static func label(_ b: ClosedRange<LocalDate>) -> String {
        let a = b.lowerBound, z = b.upperBound
        if a.year == z.year && a.month == z.month {
            return a == z ? "\(a.day) \(a.monthName) \(a.year)" : "\(a.day)–\(z.day) \(a.monthName) \(a.year)"
        }
        if a.year == z.year { return "\(a.day) \(a.monthName) – \(z.day) \(z.monthName) \(z.year)" }
        return "\(a.day) \(a.monthName) \(a.year) – \(z.day) \(z.monthName) \(z.year)"
    }
}

// MARK: - LocalDate calendar helpers (UTC Gregorian arithmetic: dates have no time zone)

extension LocalDate {
    static let rangeCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    var rangeDate: Date { Self.rangeCal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))! }

    init(rangeDate d: Date) {
        let c = Self.rangeCal.dateComponents([.year, .month, .day], from: d)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    func adding(days n: Int) -> LocalDate {
        LocalDate(rangeDate: Self.rangeCal.date(byAdding: .day, value: n, to: rangeDate)!)
    }

    func withDay(_ d: Int) -> LocalDate { LocalDate(year: year, month: month, day: d) }

    var endOfMonth: LocalDate {
        withDay(Self.rangeCal.range(of: .day, in: .month, for: rangeDate)!.count)
    }

    /// Monday = 0 … Sunday = 6.
    var isoWeekdayIndex: Int { (Self.rangeCal.component(.weekday, from: rangeDate) + 5) % 7 }

    func days(to other: LocalDate) -> Int {
        Self.rangeCal.dateComponents([.day], from: rangeDate, to: other.rangeDate).day!
    }

    // ponytail: English month/weekday names, matching Fmt's fixed formats; localise with the rest of the UI.
    var monthName: String {
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][month - 1]
    }
    var weekdayLetter: String { ["M", "T", "W", "T", "F", "S", "S"][isoWeekdayIndex] }
    var isWeekend: Bool { isoWeekdayIndex >= 5 }
    /// `Mon 5 Oct`.
    var rangeShortLabel: String {
        "\(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][isoWeekdayIndex]) \(day) \(monthName)"
    }

    /// Every date in `b`, ascending.
    static func all(in b: ClosedRange<LocalDate>) -> [LocalDate] {
        var out: [LocalDate] = [], d = b.lowerBound
        while d <= b.upperBound { out.append(d); d = d.adding(days: 1) }
        return out
    }
}
