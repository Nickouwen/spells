import Foundation
import HoursCore

/// Day arithmetic the shell needs. Prefixed names: W10/W11 may add their own LocalDate helpers.
extension LocalDate {
    func shellShifted(by days: Int) -> LocalDate {
        let cal = ShellCalendar.utc
        let noon = cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        let c = cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: days, to: noon)!)
        return LocalDate(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Noon UTC of the date, for DatePicker / formatters (tz-free).
    var shellDate: Date {
        ShellCalendar.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    init(shellDate date: Date, in tz: TimeZone = .current) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    /// "Mon 5 Oct".
    var shellTitle: String {
        var style = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        style.timeZone = TimeZone(identifier: "UTC")!
        return shellDate.formatted(style)
    }
}

enum ShellCalendar {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func today(nowMs: Int64, in tz: TimeZone) -> LocalDate {
        LocalDate.containing(ms: nowMs, in: tz)
    }
}
