import Foundation

/// Published, explainable thresholds (plan 05). Durations in ms.
public struct MetricsConfig: Sendable, Hashable {
    /// A focus session needs at least this many productive ms.
    public var focusMinMs: Int64 = 15 * 60_000
    /// Gaps between productive spans up to this long are tolerated inside a session.
    public var focusTolMs: Int64 = 120_000
    /// Productive ms / session wall ms must reach this share.
    public var focusShare: Double = 0.75
    /// Inactive gap at or above this is a break; below it is a micro-pause.
    public var breakMinMs: Int64 = 5 * 60_000
    /// Inactive gap at or above this is "away", not a break.
    public var awayMinMs: Int64 = 180 * 60_000
    /// Spans shorter than this are glances and never count as a context switch.
    public var switchDebounceMs: Int64 = 3_000
    /// Activity blocks (separated by away gaps) with less active time are ignored for workday start/end.
    public var workdayMinActiveMs: Int64 = 10 * 60_000
    public var meetingMergeGapMs: Int64 = 120_000
    public var meetingMinMs: Int64 = 120_000
    /// Switches/hour is nil below this much tracked time (rate is noise on tiny samples).
    public var switchRateMinTrackedMs: Int64 = 30 * 60_000

    public init() {}
    public static let `default` = MetricsConfig()
}
