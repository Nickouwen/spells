import Foundation

/// A range = Σ of its days. Range-level ratios come from summed inputs, never averaged averages,
/// so Range totals equal the export exactly.
public struct RangeMetrics: Sendable, Hashable {
    public struct Day: Sendable, Hashable {
        public var date: LocalDate
        public var metrics: DayMetrics
    }

    /// Billable ms for one (day, project) — the unit item 9 rounds on.
    public struct Billable: Sendable, Hashable {
        public var date: LocalDate
        public var projectId: Int64
        public var ms: Int64
    }

    /// Days in date order (only the dates passed in).
    public var days: [Day] = []
    public var trackedMs: Int64 = 0
    public var workMs: Int64 = 0
    public var billableMs: Int64 = 0
    public var focusMs: Int64 = 0
    public var meetingMs: Int64 = 0
    public var breakMs: Int64 = 0
    public var focusSessionCount = 0
    public var meetingCount = 0
    public var switches = 0
    public var switchesPerHour: Double?
    public var focusRatio: Double?
    public var avgFocusSessionMs: Int64?
    /// Summed day breakdowns; same key semantics as `DayMetrics`.
    public var byCategory: [DayMetrics.Row<Int64?>] = []
    /// workMs of a project row = billable ms for the whole range (invoice line).
    public var byProject: [DayMetrics.Row<Int64?>] = []
    public var byApp: [DayMetrics.Row<DayMetrics.App>] = []
    public var byHost: [DayMetrics.Row<String?>] = []
    /// Per (day, project) billable, date then project order. Σ ms = billableMs.
    public var billable: [Billable] = []

    public var unassignedWorkMs: Int64 { workMs - billableMs }

    public init() {}

    /// `days`: each date's classified spans, already clipped to that day by the store.
    public static func compute(days: [LocalDate: [ClassifiedSpan]], categories: [Category], goal: Goal? = nil,
                               config: MetricsConfig = .default) -> RangeMetrics {
        var catById: [Int64: Category] = [:]
        for c in categories { catById[c.id] = c }
        var r = RangeMetrics()
        var byCat = MetricsRows<Int64?>(), byProj = MetricsRows<Int64?>()
        var byApp = MetricsRows<DayMetrics.App>(), byHost = MetricsRows<String?>()

        for date in days.keys.sorted() {
            let m = DayMetrics.compute(MetricsSpan.resolve(days[date]!, categories: catById), goal: goal, config: config)
            r.days.append(Day(date: date, metrics: m))
            r.trackedMs += m.trackedMs
            r.workMs += m.workMs
            r.billableMs += m.billableMs
            r.focusMs += m.focusMs
            r.meetingMs += m.meetingMs
            r.breakMs += m.breakMs
            r.focusSessionCount += m.focusSessions.count
            r.meetingCount += m.meetings.count
            r.switches += m.switches
            for x in m.byCategory { byCat.add(x.key, x.trackedMs, x.workMs) }
            for x in m.byApp { byApp.add(x.key, x.trackedMs, x.workMs) }
            for x in m.byHost { byHost.add(x.key, x.trackedMs, x.workMs) }
            var dayBillable: [Billable] = []
            for x in m.byProject {
                byProj.add(x.key, x.trackedMs, x.workMs)
                if let p = x.key, x.workMs > 0 { dayBillable.append(Billable(date: date, projectId: p, ms: x.workMs)) }
            }
            r.billable += dayBillable.sorted { $0.projectId < $1.projectId }
        }

        r.byCategory = byCat.sorted
        r.byProject = byProj.sorted
        r.byApp = byApp.sorted
        r.byHost = byHost.sorted
        r.focusRatio = r.workMs > 0 ? Double(r.focusMs) / Double(r.workMs) : nil
        r.switchesPerHour = r.trackedMs >= config.switchRateMinTrackedMs
            ? Double(r.switches) / (Double(r.trackedMs) / 3_600_000) : nil
        r.avgFocusSessionMs = r.focusSessionCount > 0 ? r.focusMs / Int64(r.focusSessionCount) : nil
        return r
    }
}
