import Foundation

/// Where the Blocks view's display settings live: the store's `setting` table (unchained, mutable).
/// Display-only: changing them regroups, never writes edits.
/// - `break_threshold_min`: the default break threshold, minutes.
/// - `break_threshold_weekday_min`: per-weekday overrides, `"2:15,7:30"` (Calendar weekday, 1 = Sunday,
///   the `goal.weekdays` convention → minutes). Absent weekdays use the default.
/// - `blocks_min_minutes`: blocks shorter than this draw as micro ticks and leave the count (0 = show all).
/// - `blocks_window_hours` / `blocks_window_start` (`"HH:mm"`): the column shows this many hours at its
///   default zoom, scrolled to start here, so a block's height means the same duration on every day.
public enum BlocksThreshold {
    public static let defaultKey = MetricsBlocks.thresholdKey
    public static let weekdayKey = "break_threshold_weekday_min"
    public static let minBlockKey = "blocks_min_minutes"
    public static let minBlockPresets = [0, 2, 5, 10]
    public static let range = 1...180
    public static let windowHoursKey = "blocks_window_hours"
    public static let windowStartKey = "blocks_window_start"
    public static let defaultWindowHours = 18
    public static let defaultWindowStartMin = 6 * 60
    public static let windowHoursRange = 4...24

    /// The break threshold in force on `day`: its weekday's override, else the default.
    public static func minutes(for day: LocalDate, settings: [String: String]) -> Int {
        overrides(settings)[weekday(day)] ?? defaultMinutes(settings)
    }

    public static func defaultMinutes(_ settings: [String: String]) -> Int {
        settings[defaultKey].flatMap { Int($0) }.flatMap(valid) ?? MetricsBlocks.defaultThresholdMin
    }

    /// Weekday (1 = Sunday … 7 = Saturday) → minutes. Malformed or out-of-range entries are ignored.
    public static func overrides(_ settings: [String: String]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for pair in (settings[weekdayKey] ?? "").split(separator: ",") {
            let kv = pair.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let d = Int(kv[0]), (1...7).contains(d), let m = Int(kv[1]).flatMap(valid) else { continue }
            out[d] = m
        }
        return out
    }

    /// The setting value for `overrides`; nil (remove the key) when empty.
    public static func encode(_ overrides: [Int: Int]) -> String? {
        overrides.isEmpty ? nil : overrides.keys.sorted().map { "\($0):\(overrides[$0]!)" }.joined(separator: ",")
    }

    public static func minBlockMinutes(_ settings: [String: String]) -> Int {
        settings[minBlockKey].flatMap { Int($0) }.map { max(0, $0) } ?? 0
    }

    /// Hours the column shows at its default zoom (4…24; default 18).
    public static func windowHours(_ settings: [String: String]) -> Int {
        settings[windowHoursKey].flatMap { Int($0) }.flatMap { windowHoursRange.contains($0) ? $0 : nil } ?? defaultWindowHours
    }

    /// Clock minutes after midnight the column scrolls to by default (default 06:00).
    public static func windowStartMinutes(_ settings: [String: String]) -> Int {
        settings[windowStartKey].flatMap(StandupSettings.parseTime) ?? defaultWindowStartMin
    }

    /// Calendar weekday of `day`, 1 = Sunday.
    public static func weekday(_ day: LocalDate) -> Int {
        cal.component(.weekday, from: cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!)
    }

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .gmt
        return c
    }()

    private static func valid(_ m: Int) -> Int? { range.contains(m) ? m : nil }
}
