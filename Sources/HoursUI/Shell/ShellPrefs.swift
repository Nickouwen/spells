import Foundation
import HoursCore

/// Setting keys the shell reads/writes (SettingStore, unchained).
enum ShellPrefs {
    static let goalDailyWorkMs = "goal.daily_work_ms"
    /// Comma-separated Calendar weekdays, 1 = Sunday.
    static let goalWeekdays = "goal.weekdays"
    /// Read live by the helper (`TrackerIdleSetting`).
    static let idleThresholdS = TrackerIdleSetting.key

    static func goal(_ s: [String: String]) -> Goal? {
        guard let ms = s[goalDailyWorkMs].flatMap(Int64.init), ms > 0 else { return nil }
        let days = s[goalWeekdays].map { Set($0.split(separator: ",").compactMap { Int($0) }) } ?? [2, 3, 4, 5, 6]
        return Goal(dailyWorkMs: ms, weekdays: days)
    }

    static func write(goal: Goal?, to store: SettingStore) throws {
        try store.set(goalDailyWorkMs, goal.map { String($0.dailyWorkMs) })
        try store.set(goalWeekdays, goal.map { $0.weekdays.sorted().map(String.init).joined(separator: ",") })
    }

    static func idleThreshold(_ s: [String: String]) -> Int { TrackerIdleSetting.seconds(s) }
}
