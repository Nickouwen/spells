import Foundation
import HoursCore

/// Today's totals for the status menu and the island: effective spans → classify → DayMetrics, read
/// on the tracker's own connection. The live span (rawSeq 0) is counted up to its last heartbeat;
/// `workMs(nowMs:)` adds the time since then when it is work, so the island can tick between queries.
// ponytail: full Classifier + DayMetrics per call (a few ms for a normal day, measured in the W15
// artifact); called per menu open, per DB change and per 30 s tick. Cache by rulesRevision if
// 1,500-span days ever show up in the budget.
struct TrackerIslandToday: Equatable {
    struct Live: Equatable {
        var appName: String
        var categoryName: String
        var colorSlot: Int?
        var isWork: Bool
        /// Last heartbeat: the live span is counted up to here.
        var endMs: Int64
    }

    var workMs: Int64 = 0
    var trackedMs: Int64 = 0
    var focusMs: Int64 = 0
    var billableMs: Int64 = 0
    var throughMs: Int64?
    var goalMs: Int64?
    var live: Live?

    /// Work so far plus the live span's unrecorded tail (only if it is work).
    func workMs(nowMs: Int64) -> Int64 {
        guard let live, live.isWork else { return workMs }
        return workMs + max(0, nowMs - live.endMs)
    }

    /// workMs / goal, unclamped; nil without a goal scheduled today.
    func goalProgress(nowMs: Int64) -> Double? {
        goalMs.map { Double(workMs(nowMs: nowMs)) / Double($0) }
    }

    static func load(db: HoursDB, nowMs: Int64) throws -> TrackerIslandToday {
        let day = LocalDate.containing(ms: nowMs, in: .current, dayStartHour: Hours.defaultDayStartHour)
        let spans = try Store(db).effectiveSpans(day: day, dayStartHour: Hours.defaultDayStartHour)
        let config = ConfigStore(db)
        let categories = try config.categories()
        let classifier = Classifier(categories: categories, rules: try config.rules(), projects: try config.projects())
        let classified = classifier.classifyAll(spans)
        let goal = goal(try SettingStore(db).all())
        let m = DayMetrics.compute(spans: classified, categories: categories, goal: goal)
        var t = TrackerIslandToday(workMs: m.workMs, trackedMs: m.trackedMs, focusMs: m.focusMs,
                                   billableMs: m.billableMs, throughMs: spans.map(\.endMs).max())
        if let goal, goal.isScheduled(day) { t.goalMs = goal.dailyWorkMs }
        func live(_ appName: String, _ categoryId: Int64?, endMs: Int64) -> Live {
            let cat = categories.first { $0.id == categoryId }
            return Live(appName: appName, categoryName: cat?.name ?? "Uncategorized",
                        colorSlot: cat?.colorSlot, isWork: cat?.isWork ?? false, endMs: endMs)
        }
        if let c = classified.last(where: { $0.span.rawSeq == 0 && $0.span.kind == .active }) {
            t.live = live(c.span.appName, c.categoryId, endMs: c.span.endMs)
        } else if !classified.contains(where: { $0.span.rawSeq == 0 }), let r = try SpanWriter(db).liveSpan(), r.kind == .active {
            // Just opened (zero length until the first heartbeat), so the day query clipped it out.
            let key = ClassifyKey(bundleId: r.bundleId, appName: r.appName, title: r.title, url: r.url)
            t.live = live(r.appName, classifier.resolve(key).categoryId, endMs: r.endMs)
        }
        return t
    }

    /// Same keys and defaults as the app's `ShellPrefs.goal` (HoursUI isn't linked into the helper).
    static func goal(_ s: [String: String]) -> Goal? {
        guard let ms = s["goal.daily_work_ms"].flatMap(Int64.init), ms > 0 else { return nil }
        let days = s["goal.weekdays"].map { Set($0.split(separator: ",").compactMap { Int($0) }) } ?? [2, 3, 4, 5, 6]
        return Goal(dailyWorkMs: ms, weekdays: days)
    }
}
