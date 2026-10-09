import Foundation

extension LocalDate {
    /// The day's bounds in `tz` as unix ms: [D hh:00, D+1 hh:00) local, hh = `dayStartHour`.
    /// DST-exact via Calendar, so a day is 23 h or 25 h around transitions.
    public func dayInterval(in tz: TimeZone, dayStartHour: Int = Hours.defaultDayStartHour) -> Range<Int64> {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let next = storeNextDay()
        let lo = cal.date(from: DateComponents(year: year, month: month, day: day, hour: dayStartHour))!
        let hi = cal.date(from: DateComponents(year: next.year, month: next.month, day: next.day, hour: dayStartHour))!
        return Self.ms(lo)..<Self.ms(hi)
    }

    /// The day (in `tz`, starting at `dayStartHour`) that instant `ms` belongs to.
    public static func containing(ms: Int64, in tz: TimeZone, dayStartHour: Int = Hours.defaultDayStartHour) -> LocalDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day, .hour],
                                   from: Date(timeIntervalSince1970: Double(ms) / 1000))
        let d = LocalDate(year: c.year!, month: c.month!, day: c.day!)
        return c.hour! < dayStartHour ? d.storePrevDay() : d
    }

    /// Midnight UTC of this date, as unix ms (a tz-free anchor for candidate windows).
    var storeUTCMidnightMs: Int64 {
        Self.ms(Self.utc.date(from: DateComponents(year: year, month: month, day: day))!)
    }

    func storeNextDay() -> LocalDate { storeShift(1) }
    func storePrevDay() -> LocalDate { storeShift(-1) }

    private func storeShift(_ days: Int) -> LocalDate {
        let d = Self.utc.date(byAdding: .day, value: days,
                              to: Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!)!
        let c = Self.utc.dateComponents([.year, .month, .day], from: d)
        return LocalDate(year: c.year!, month: c.month!, day: c.day!)
    }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
}
