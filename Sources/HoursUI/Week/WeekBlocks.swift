import Foundation
import HoursCore

/// How the Week page shows the week: per-day bars + heatmap (default) or seven columns of work blocks.
/// Persisted per user in `UserDefaults` (`week.mode`).
enum WeekMode: String, CaseIterable, Hashable {
    case bars, blocks

    static let storageKey = "week.mode"
    var title: String { self == .bars ? "Bars" : "Blocks" }
}

/// Where clicking a block in the week goes: that day, in the Day view's Blocks mode, with the block selected.
struct WeekBlockRoute: Hashable {
    var day: LocalDate
    var mode: DayMode
    /// An instant inside the block (its midpoint), which is how the Blocks card holds its selection.
    var selectedMs: Int64

    static func open(_ b: WorkBlock, on day: LocalDate) -> WeekBlockRoute {
        WeekBlockRoute(day: day, mode: .blocks, selectedMs: b.startMs + b.wallMs / 2)
    }

    /// What the host can do today without a selection hook: flip the Day view's stored mode, then open the day.
    func apply(defaults: UserDefaults = .standard, onSelectDay: (LocalDate) -> Void) {
        defaults.set(mode.rawValue, forKey: DayMode.storageKey)
        onSelectDay(day)
    }
}

/// The Blocks mode's numbers: each day grouped by `MetricsBlocks` at its own threshold, per-day and
/// week totals, and the time axis every column shares.
struct WeekBlocks: Sendable {
    struct Day: Sendable {
        var date: LocalDate
        var blocks: [WorkBlock]
        var breaks: [BlockBreak]
        var thresholdMin: Int
        /// Start of the store day (04:00 local).
        var startMs: Int64

        var count: Int { blocks.count }
        var totalMs: Int64 { blocks.reduce(0) { $0 + $1.wallMs } }
        var averageMs: Int64? { count > 0 ? totalMs / Int64(count) : nil }
        var longestMs: Int64? { blocks.map(\.wallMs).max() }
        var breakMs: Int64 { breaks.reduce(0) { $0 + $1.durationMs } }
    }

    var days: [Day]
    var timeZone: TimeZone
    var dayStartHour: Int
    /// The columns' time line as clock ms after day start: the whole 04:00 day (it scrolls).
    var axis: Range<Int64> = 0..<24 * hour
    /// The viewport's span (`blocks_window_hours`, 18 h) — the Day column's scale.
    var windowMs: Int64 = Int64(BlocksThreshold.defaultWindowHours) * hour
    /// Offset at the viewport's top by default: `blocks_window_start` (06:00), moved for the week's
    /// earliest block start / latest end the way the Day column moves for its day.
    var top: Int64 = 2 * hour

    var count: Int { days.reduce(0) { $0 + $1.count } }
    var averageMs: Int64? { count > 0 ? days.reduce(0) { $0 + $1.totalMs } / Int64(count) : nil }
    var longestMs: Int64? { days.compactMap(\.longestMs).max() }
    var breakMs: Int64 { days.reduce(0) { $0 + $1.breakMs } }

    static let hour: Int64 = 3_600_000

    static func build(_ data: WeekData) -> WeekBlocks {
        let tz = data.range.timeZone
        let days = data.dates.map { d in
            let minutes = data.blockThresholdMin[d] ?? MetricsBlocks.defaultThresholdMin
            let day = MetricsBlocks.day(spans: data.daySpans[d] ?? [], categories: data.range.categories,
                                        breakThresholdMs: Int64(minutes) * 60_000)
            return Day(date: d, blocks: day.blocks, breaks: day.breaks, thresholdMin: minutes,
                       startMs: d.dayInterval(in: tz, dayStartHour: data.dayStartHour).lowerBound)
        }
        var out = WeekBlocks(days: days, timeZone: tz, dayStartHour: data.dayStartHour)
        out.windowMs = Int64(data.blockWindowHours) * hour
        var lo = Int64.max, hi = Int64.min
        for day in days {
            for b in day.blocks {
                lo = min(lo, out.offset(b.startMs, day))
                hi = max(hi, out.offset(b.endMs, day))
            }
        }
        let start = Int64(data.blockWindowStartMin - data.dayStartHour * 60 + (data.blockWindowStartMin < data.dayStartHour * 60 ? 24 * 60 : 0)) * 60_000
        out.top = BlocksGeometry.defaultTop(range: out.axis, windowStart: start, windowMs: out.windowMs,
                                            first: lo <= hi ? lo : nil, last: lo <= hi ? hi : nil)
        return out
    }

    /// Clock time after the day's start, so every column lines up by wall clock (a DST night folds or
    /// skips its hour rather than shifting the rest of the day).
    func offset(_ ms: Int64, _ day: Day) -> Int64 { local(ms) - local(day.startMs) }

    private func local(_ ms: Int64) -> Int64 {
        ms + Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(ms) / 1000))) * 1000
    }

    /// The block on `dayIndex` covering clock offset `off`, if any.
    func block(day dayIndex: Int, atOffset off: Int64) -> WorkBlock? {
        guard days.indices.contains(dayIndex) else { return nil }
        let day = days[dayIndex]
        return day.blocks.first { offset($0.startMs, day) <= off && off < offset($0.endMs, day) }
    }

    /// `HH:00` for an axis hour mark.
    func hourLabel(_ off: Int64) -> String { String(format: "%02d:00", (dayStartHour + Int(off / Self.hour)) % 24) }
}
