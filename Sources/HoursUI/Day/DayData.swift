import Foundation
import HoursCore

/// Everything the Day view draws, as one Sendable value. The shell builds it with `load`
/// (and rebuilds it on DB change / the ≤ 1/min "now" tick); previews and tests use `fixture`.
public struct DayData: Sendable, Hashable {
    public var date: LocalDate
    public var timeZone: TimeZone
    /// The local day's bounds, [D 04:00, D+1 04:00) in `timeZone`.
    public var bounds: Range<Int64>
    /// Effective spans of the day, classified, sorted by start.
    public var spans: [ClassifiedSpan]
    public var metrics: DayMetrics
    public var categories: [HoursCore.Category]
    public var projects: [Project]
    public var goal: Goal?
    public var isToday: Bool
    /// "Now" for today (drives the now marker); nil for past days.
    public var nowMs: Int64?
    /// The open span (rawSeq 0), ending at its last heartbeat. Today only.
    public var liveSpan: ClassifiedSpan?
    /// Work time before edits; nil when no span that day carries an edit.
    public var rawWorkMs: Int64?
    public var tracker: TrackerHealth
    /// W24: where each un-edited tracked window's category came from (Rule / Jev % / Fallback). Filled by `load`.
    public var categorySources: [ClassifyKey: ClassifySource] = [:]

    public init(date: LocalDate, timeZone: TimeZone, bounds: Range<Int64>, spans: [ClassifiedSpan],
                metrics: DayMetrics, categories: [HoursCore.Category], projects: [Project], goal: Goal?,
                isToday: Bool, nowMs: Int64?, liveSpan: ClassifiedSpan?, rawWorkMs: Int64?,
                tracker: TrackerHealth = .unknown) {
        self.date = date; self.timeZone = timeZone; self.bounds = bounds; self.spans = spans
        self.metrics = metrics; self.categories = categories; self.projects = projects; self.goal = goal
        self.isToday = isToday; self.nowMs = nowMs; self.liveSpan = liveSpan; self.rawWorkMs = rawWorkMs
        self.tracker = tracker
    }

    /// Reads the day from the store, classifies, computes metrics.
    public static func load(store: Store, classifier: Classifier, categories: [HoursCore.Category],
                            projects: [Project], day: LocalDate, goal: Goal?,
                            now: Date = Date(), timeZone: TimeZone = .current,
                            tracker: TrackerHealth = .unknown) throws -> DayData {
        let bounds = day.dayInterval(in: timeZone)
        let spans = classifier.classifyAll(try store.effectiveSpans(day: day))
        var rawWork: Int64?
        if spans.contains(where: { !$0.span.editSeqs.isEmpty }) {
            let raw = try store.rawSpans(from: bounds.lowerBound, to: bounds.upperBound)
            rawWork = workMs(unedited: raw, bounds: bounds, classifier: classifier, categories: categories)
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var data = assemble(date: day, timeZone: timeZone, bounds: bounds, spans: spans, categories: categories,
                            projects: projects, goal: goal, nowMs: bounds.contains(nowMs) ? nowMs : nil,
                            rawWorkMs: rawWork, tracker: tracker)
        for c in spans where c.span.kind == .active && c.span.source == .tracked && c.span.categoryOverride == nil {
            let key = ClassifyKey(c.span)
            if data.categorySources[key] == nil, let s = classifier.source(c.span) { data.categorySources[key] = s }
        }
        return data
    }

    /// "Rule", "Jev 92 %", "Edited", "Fallback"; nil for idle and Uncategorized.
    func sourceLabel(_ c: ClassifiedSpan) -> String? {
        guard c.span.kind == .active, c.categoryId != nil else { return nil }
        if c.span.categoryOverride != nil { return ClassifySource.edited.label }
        return categorySources[ClassifyKey(c.span)]?.label
    }

    /// A deterministic demo day from `DemoData`, classified with the seed config.
    /// - `trackerGap`: cut 15:10–15:35 out of the raw spans (tracker not running) to exercise the gap state.
    /// - `edited`: one assign edit (16:00–16:20 → Personal) so the `±` marker shows.
    /// - `now`: (hour, minute) makes it "today": spans stop there and the last one is live.
    public static func fixture(date: LocalDate = LocalDate(year: 2026, month: 10, day: 1),
                               tzId: String = "America/Vancouver", trackerGap: Bool = true,
                               edited: Bool = true, now: (hour: Int, minute: Int)? = nil,
                               empty: Bool = false, tracker: TrackerHealth = .unknown,
                               goal: Goal? = Goal(dailyWorkMs: 7 * 3_600_000)) -> DayData {
        let tz = TimeZone(identifier: tzId) ?? .gmt
        let bounds = date.dayInterval(in: tz)
        let at = { (h: Int, m: Int) in bounds.lowerBound + Int64((h - Hours.defaultDayStartHour) * 3600 + m * 60) * 1000 }
        let classifier = Classifier(categories: ClassifySeed.categories, rules: ClassifySeed.rules,
                                    projects: ClassifySeed.projects)

        var raw = empty ? [] : DemoData.spans(from: date, through: date, tzId: tzId)
        if trackerGap { raw = cut(raw, at(15, 10), at(15, 35)) }
        let nowMs = now.map { at($0.hour, $0.minute) }
        if let nowMs { raw = raw.compactMap { s in s.startMs >= nowMs ? nil : { var c = s; c.endMs = min(c.endMs, nowMs); return c }() } }
        for i in raw.indices { raw[i].seq = Int64(i + 1) }
        if nowMs != nil, !raw.isEmpty { raw[raw.count - 1].seq = 0 }

        var edits: [Edit] = []
        if edited && !raw.isEmpty && (nowMs ?? .max) > at(16, 20) {
            edits.append(Edit(seq: Int64(raw.count + 1), grp: Int64(raw.count + 1), createdMs: at(18, 0), tzId: tzId,
                              op: .assign, loMs: at(16, 0), hiMs: at(16, 20), target: nil,
                              payload: .assign(categoryId: ClassifySeed.personal, projectId: nil)))
        }
        let spans = classifier.classifyAll(effectiveSpans(raw: raw, edits: edits))
        let rawWork = edits.isEmpty ? nil
            : workMs(unedited: raw, bounds: bounds, classifier: classifier, categories: ClassifySeed.categories)
        return assemble(date: date, timeZone: tz, bounds: bounds, spans: spans, categories: ClassifySeed.categories,
                        projects: ClassifySeed.projects, goal: goal, nowMs: nowMs, rawWorkMs: rawWork, tracker: tracker)
    }

    static func assemble(date: LocalDate, timeZone: TimeZone, bounds: Range<Int64>, spans: [ClassifiedSpan],
                         categories: [HoursCore.Category], projects: [Project], goal: Goal?, nowMs: Int64?,
                         rawWorkMs: Int64?, tracker: TrackerHealth) -> DayData {
        let sorted = spans.sorted { $0.span.startMs < $1.span.startMs }
        let scheduledGoal = goal.flatMap { $0.isScheduled(date) ? $0 : nil }
        return DayData(date: date, timeZone: timeZone, bounds: bounds, spans: sorted,
                       metrics: DayMetrics.compute(spans: sorted, categories: categories, goal: scheduledGoal),
                       categories: categories, projects: projects, goal: scheduledGoal, isToday: nowMs != nil,
                       nowMs: nowMs, liveSpan: nowMs == nil ? nil : sorted.last { $0.span.rawSeq == 0 },
                       rawWorkMs: rawWorkMs, tracker: tracker)
    }

    static func workMs(unedited raw: [RawSpan], bounds: Range<Int64>, classifier: Classifier,
                       categories: [HoursCore.Category]) -> Int64 {
        let spans = effectiveSpans(raw: raw, edits: []).compactMap { s -> EffectiveSpan? in
            var c = s
            c.startMs = max(s.startMs, bounds.lowerBound); c.endMs = min(s.endMs, bounds.upperBound)
            return c.endMs > c.startMs ? c : nil
        }
        return DayMetrics.compute(spans: classifier.classifyAll(spans), categories: categories).workMs
    }

    /// Removes [lo, hi) from raw spans (fixture-only: simulates the tracker being off).
    static func cut(_ raw: [RawSpan], _ lo: Int64, _ hi: Int64) -> [RawSpan] {
        raw.flatMap { s -> [RawSpan] in
            guard s.startMs < hi, s.endMs > lo else { return [s] }
            var out: [RawSpan] = []
            if s.startMs < lo { var l = s; l.endMs = lo; out.append(l) }
            if s.endMs > hi { var r = s; r.startMs = hi; out.append(r) }
            return out
        }
    }

    // MARK: Lookups the view needs

    public var isEmpty: Bool { !spans.contains { $0.span.kind == .active } }

    func category(_ id: Int64?) -> HoursCore.Category? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    func categoryName(_ id: Int64?) -> String { category(id)?.name ?? "Uncategorized" }
    func slot(_ id: Int64?) -> Int? { category(id)?.colorSlot }
    func projectName(_ id: Int64?) -> String? { id.flatMap { pid in projects.first { $0.id == pid }?.name } }

    /// Why a break gap has no active time: the tracker saw the user idle (an `idle` span covers at
    /// least half of it), or it wasn't recording at all (asleep, locked, quit, paused). Both count as breaks.
    enum BreakKind: Equatable { case away, notTracking }

    func breakKind(_ b: DayMetrics.Break) -> BreakKind {
        let idle = spans.reduce(Int64(0)) { acc, c in
            guard c.span.kind == .idle else { return acc }
            return acc + max(0, min(c.span.endMs, b.endMs) - max(c.span.startMs, b.startMs))
        }
        return idle * 2 >= b.durationMs ? .away : .notTracking
    }

    /// Last tracked instant (live span's heartbeat on today).
    var trackedThroughMs: Int64? { spans.last?.span.endMs }
}

extension LocalDate {
    /// Calendar-day shift (DST-safe: works on the date, not on ms).
    func dayShift(_ days: Int) -> LocalDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let d = cal.date(byAdding: .day, value: days, to: cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!)!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return LocalDate(year: c.year!, month: c.month!, day: c.day!)
    }
}
