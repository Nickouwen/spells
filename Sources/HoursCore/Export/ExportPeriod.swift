import Foundation

/// A billing period: local dates `from`…`through`, inclusive. Each date is a store day
/// ([D 04:00, D+1 04:00) in each span's own tz), so the period total equals the Range view's.
public struct ExportPeriod: Sendable, Hashable, CustomStringConvertible {
    public var from: LocalDate
    public var through: LocalDate

    public init(from: LocalDate, through: LocalDate) { self.from = from; self.through = through }

    public var description: String { "\(from)..\(through)" }

    public var days: [LocalDate] {
        var out: [LocalDate] = [], d = from
        while d <= through { out.append(d); d = d.storeNextDay() }
        return out
    }

    /// The semi-month (1–15 or 16–EOM) containing `day`.
    public static func semiMonth(containing day: LocalDate) -> ExportPeriod {
        day.day <= 15
            ? ExportPeriod(from: LocalDate(year: day.year, month: day.month, day: 1),
                           through: LocalDate(year: day.year, month: day.month, day: 15))
            : ExportPeriod(from: LocalDate(year: day.year, month: day.month, day: 16),
                           through: LocalDate(year: day.year, month: day.month,
                                              day: daysInMonth(year: day.year, month: day.month)))
    }

    /// `current` | `previous` | `YYYY-MM-DD..YYYY-MM-DD`. `today` is the store day containing now.
    public static func parse(_ s: String, today: LocalDate) -> ExportPeriod? {
        switch s {
        case "current": return semiMonth(containing: today)
        case "previous": return semiMonth(containing: semiMonth(containing: today).from.storePrevDay())
        default:
            let parts = s.components(separatedBy: "..")
            guard parts.count == 2, let a = date(parts[0]), let b = date(parts[1]), a <= b else { return nil }
            return ExportPeriod(from: a, through: b)
        }
    }

    static func date(_ s: String) -> LocalDate? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, s.count == 10, (1...12).contains(p[1]),
              (1...daysInMonth(year: p[0], month: p[1])).contains(p[2]) else { return nil }
        return LocalDate(year: p[0], month: p[1], day: p[2])
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}
