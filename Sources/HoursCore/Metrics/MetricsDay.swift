import Foundation

/// Every number for one day, computed from that day's classified spans (already clipped to the
/// 04:00–04:00 day by the store). Tiers: tracked ⊇ work ⊇ billable.
/// - tracked: active spans, minus `exclude` categories. Idle never counts.
/// - work: tracked with an `isWork` category (neutral counts; distracting and Uncategorized don't).
/// - billable: work with a project assigned.
// ponytail: no caching / derived tables — recompute per call. Add day_summary only if store perf demands it.
public struct DayMetrics: Sendable, Hashable {
    public struct Session: Sendable, Hashable {
        public var startMs: Int64
        public var endMs: Int64
        /// Focus sessions: productive ms only (tolerated blips excluded). Meetings: meeting ms.
        public var activeMs: Int64
        public var wallMs: Int64 { endMs - startMs }
        public init(startMs: Int64, endMs: Int64, activeMs: Int64) {
            self.startMs = startMs; self.endMs = endMs; self.activeMs = activeMs
        }
    }

    public struct Break: Sendable, Hashable {
        public var startMs: Int64
        public var endMs: Int64
        public var durationMs: Int64 { endMs - startMs }
        public init(startMs: Int64, endMs: Int64) { self.startMs = startMs; self.endMs = endMs }
    }

    /// App identity = bundle id (app name when there is none). Equality ignores `name`.
    public struct App: Sendable, Hashable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
        public static func == (a: App, b: App) -> Bool { a.id == b.id }
        public func hash(into h: inout Hasher) { h.combine(id) }
    }

    /// One breakdown row. Rows are sorted by trackedMs descending; Σ trackedMs = day tracked.
    public struct Row<Key: Hashable & Sendable>: Sendable, Hashable {
        public var key: Key
        public var trackedMs: Int64
        public var workMs: Int64
        public init(key: Key, trackedMs: Int64, workMs: Int64) {
            self.key = key; self.trackedMs = trackedMs; self.workMs = workMs
        }
    }

    public struct HourBucket: Sendable, Hashable {
        public var trackedMs: Int64 = 0
        public var workMs: Int64 = 0
        public init(trackedMs: Int64 = 0, workMs: Int64 = 0) { self.trackedMs = trackedMs; self.workMs = workMs }
    }

    public var trackedMs: Int64 = 0
    public var workMs: Int64 = 0
    public var billableMs: Int64 = 0
    /// Σ focus session productive ms.
    public var focusMs: Int64 = 0
    public var meetingMs: Int64 = 0
    /// Σ breaks (inactive gaps in [breakMin, awayMin)).
    public var breakMs: Int64 = 0
    /// Σ inactive gaps >= awayMin.
    public var awayMs: Int64 = 0
    /// Σ inactive gaps < breakMin.
    public var microPauseMs: Int64 = 0
    public var switches: Int = 0
    /// switches / tracked hour; nil under 30 min tracked.
    public var switchesPerHour: Double?
    /// focus / work; nil when there is no work. Not a score — one division from its inputs.
    public var focusRatio: Double?
    /// Workday start/end: first/last activity, ignoring stray blocks (< 10 min active, isolated by
    /// away gaps). Falls back to all activity when every block is stray. nil on an empty day.
    public var firstActivityMs: Int64?
    public var lastActivityMs: Int64?
    public var focusSessions: [Session] = []
    public var meetings: [Session] = []
    public var breaks: [Break] = []
    /// nil key = Uncategorized.
    public var byCategory: [Row<Int64?>] = []
    /// workMs of a project row = that project's billable ms; the nil row's workMs = unassigned work.
    public var byProject: [Row<Int64?>] = []
    public var byApp: [Row<App>] = []
    /// nil key = "(no site)" (non-browser spans).
    public var byHost: [Row<String?>] = []
    /// 24 buckets indexed by local clock hour (0 = midnight), from each span's own tz.
    public var hourly: [HourBucket] = Array(repeating: HourBucket(), count: 24)
    /// workMs / goal.dailyWorkMs, unclamped; nil without a goal. Weekday scheduling is the caller's
    /// call (`Goal.isScheduled`) — this function has no date.
    public var goalProgress: Double?

    public var unassignedWorkMs: Int64 { workMs - billableMs }

    public init() {}

    public static func compute(spans: [ClassifiedSpan], categories: [Category], goal: Goal? = nil,
                               config: MetricsConfig = .default) -> DayMetrics {
        var catById: [Int64: Category] = [:]
        for c in categories { catById[c.id] = c }
        return compute(MetricsSpan.resolve(spans, categories: catById), goal: goal, config: config)
    }

    static func compute(_ a: [MetricsSpan], goal: Goal?, config c: MetricsConfig) -> DayMetrics {
        var m = DayMetrics()
        var byCat = MetricsRows<Int64?>(), byProj = MetricsRows<Int64?>()
        var byApp = MetricsRows<App>(), byHost = MetricsRows<String?>()
        var focus: [MetricsSpan] = [], meeting: [MetricsSpan] = []
        var tzs: [String: TimeZone] = [:]

        for s in a {
            let d = s.durationMs, w = s.isWork ? d : 0
            m.trackedMs += d
            m.workMs += w
            if s.isWork, s.projectId != nil { m.billableMs += d }
            byCat.add(s.categoryId, d, w)
            byProj.add(s.projectId, d, w)
            byApp.add(s.app, d, w)
            byHost.add(s.host, d, w)
            if s.isFocus { focus.append(s) }
            if s.isMeeting { meeting.append(s) }
            let tz = tzs[s.tzId] ?? (TimeZone(identifier: s.tzId) ?? .gmt)
            tzs[s.tzId] = tz
            m.addHourly(s, tz: tz)
        }

        m.focusSessions = MetricsFocus.sessions(focus, c)
        m.focusMs = m.focusSessions.reduce(0) { $0 + $1.activeMs }
        m.meetings = MetricsFocus.meetings(meeting, c)
        m.meetingMs = m.meetings.reduce(0) { $0 + $1.activeMs }
        m.addGaps(a, c)
        m.addSwitches(a, c)
        m.addWorkday(a, c)

        m.focusRatio = m.workMs > 0 ? Double(m.focusMs) / Double(m.workMs) : nil
        m.switchesPerHour = m.trackedMs >= c.switchRateMinTrackedMs
            ? Double(m.switches) / (Double(m.trackedMs) / 3_600_000) : nil
        if let goal, goal.dailyWorkMs > 0 { m.goalProgress = Double(m.workMs) / Double(goal.dailyWorkMs) }

        m.byCategory = byCat.sorted
        m.byProject = byProj.sorted
        m.byApp = byApp.sorted
        m.byHost = byHost.sorted
        return m
    }

    /// Breaks / away / micro-pauses from inactive gaps between consecutive tracked spans.
    private mutating func addGaps(_ a: [MetricsSpan], _ c: MetricsConfig) {
        var end = a.first?.end ?? 0
        for s in a.dropFirst() {
            let g = s.start - end
            if g >= c.awayMinMs { awayMs += g }
            else if g >= c.breakMinMs { breaks.append(Break(startMs: end, endMs: s.start)); breakMs += g }
            else if g > 0 { microPauseMs += g }
            end = max(end, s.end)
        }
    }

    /// A switch = context-key change between consecutive non-glance spans, unless the gap between
    /// them is a break or longer (that's a resume, not a switch).
    private mutating func addSwitches(_ a: [MetricsSpan], _ c: MetricsConfig) {
        var prev: MetricsSpan?
        for s in a where s.durationMs >= c.switchDebounceMs {
            if let p = prev, s.key != p.key, s.start - p.end < c.breakMinMs { switches += 1 }
            prev = s
        }
    }

    private mutating func addWorkday(_ a: [MetricsSpan], _ c: MetricsConfig) {
        guard let first = a.first else { return }
        var blocks: [(start: Int64, end: Int64, active: Int64)] = [(first.start, first.end, 0)]
        for s in a {
            if s.start - blocks[blocks.count - 1].end >= c.awayMinMs { blocks.append((s.start, s.end, 0)) }
            blocks[blocks.count - 1].end = max(blocks[blocks.count - 1].end, s.end)
            blocks[blocks.count - 1].active += s.durationMs
        }
        let kept = blocks.filter { $0.active >= c.workdayMinActiveMs }
        let use = kept.isEmpty ? blocks : kept
        firstActivityMs = use.first?.start
        lastActivityMs = use.last?.end
    }

    /// Splits a span across local clock-hour boundaries. Offset is re-read per hour, so DST shifts land.
    private mutating func addHourly(_ s: MetricsSpan, tz: TimeZone) {
        let hourMs: Int64 = 3_600_000
        var t = s.start
        while t < s.end {
            let off = Int64(tz.secondsFromGMT(for: Date(timeIntervalSince1970: Double(t) / 1000))) * 1000
            let local = t + off
            let into = ((local % hourMs) + hourMs) % hourMs
            let next = min(s.end, t + hourMs - into)
            let hour = Int((((local - into) / hourMs) % 24 + 24) % 24)
            hourly[hour].trackedMs += next - t
            if s.isWork { hourly[hour].workMs += next - t }
            t = next
        }
    }
}

/// Breakdown accumulator. Output: trackedMs descending, ties in first-seen order (deterministic).
struct MetricsRows<K: Hashable & Sendable> {
    private var index: [K: Int] = [:]
    private var rows: [DayMetrics.Row<K>] = []

    mutating func add(_ key: K, _ tracked: Int64, _ work: Int64) {
        if let i = index[key] {
            rows[i].trackedMs += tracked; rows[i].workMs += work
        } else {
            index[key] = rows.count
            rows.append(DayMetrics.Row(key: key, trackedMs: tracked, workMs: work))
        }
    }

    var sorted: [DayMetrics.Row<K>] {
        rows.enumerated().sorted { ($1.element.trackedMs, $0.offset) < ($0.element.trackedMs, $1.offset) }
            .map(\.element)
    }
}
