import Foundation
import HoursCore

/// Everything the Week view draws for one Monday–Sunday week. Totals are `RangeData`'s (the same
/// `RangeMetrics` export uses), so Week, Range and the CSV agree for the same days.
public struct WeekData: Sendable {
    /// The week as a 7-day range: edited + raw metrics, tracker gaps, edit count, config.
    public var range: RangeData
    /// The daily target from Settings; days outside its weekday toggles have no goal.
    public var goal: Goal?
    /// The store day "now" falls in. Days after it are future (ghost columns).
    public var today: LocalDate
    /// Scheduled days in a row at goal, walking back from `min(today, sunday)`.
    public var streak: Int
    /// Hour the store's day starts at; the heatmap's columns start here.
    public var dayStartHour: Int
    /// Each day's edited, classified spans (the Day view's input), for the Blocks mode.
    public var daySpans: [LocalDate: [ClassifiedSpan]] = [:]
    /// Break threshold per day, minutes (Blocks mode grouping).
    public var blockThresholdMin: [LocalDate: Int] = [:]
    /// The Blocks viewport (`blocks_window_hours` / `blocks_window_start`): hours visible at once, and
    /// the clock minutes it starts at by default.
    public var blockWindowHours = BlocksThreshold.defaultWindowHours
    public var blockWindowStartMin = BlocksThreshold.defaultWindowStartMin
    /// "Now" when it falls inside the week; drawn as a line on today's Blocks column.
    public var nowMs: Int64?

    public static let streakLookbackDays = 56

    // MARK: Loading

    /// Loads the week containing `day` (weeks start Monday) plus the look-back the streak needs.
    public static func load(store: Store, classifier: Classifier, categories: [HoursCore.Category], projects: [Project],
                            week day: LocalDate, goal: Goal?, now: Date = Date(), timeZone: TimeZone = .current,
                            dayStartHour: Int = Hours.defaultDayStartHour) throws -> WeekData {
        let today = LocalDate.containing(ms: Int64(now.timeIntervalSince1970 * 1000), in: timeZone, dayStartHour: dayStartHour)
        let mon = weekStart(day)
        let bounds = mon...mon.adding(days: 6)
        // RangeData.load's reads, inlined so the week's edited spans are fetched once and kept for Blocks.
        var edited: [LocalDate: [EffectiveSpan]] = [:]
        for d in LocalDate.all(in: bounds) { edited[d] = try store.effectiveSpans(day: d, dayStartHour: dayStartHour) }
        let h: Int64 = 3_600_000
        let weekLo = mon.dayInterval(in: timeZone, dayStartHour: dayStartHour).lowerBound
        let weekHi = bounds.upperBound.dayInterval(in: timeZone, dayStartHour: dayStartHour).upperBound
        let raw = effectiveSpans(raw: try store.rawSpans(from: weekLo - 15 * h, to: weekHi + 15 * h), edits: [])
        let range = RangeData.build(period: .custom(mon, bounds.upperBound), bounds: bounds, edited: edited,
                                    raw: RangeData.bucket(raw, into: bounds, dayStartHour: dayStartHour),
                                    classifier: classifier, categories: categories, projects: projects, timeZone: timeZone)
        var history: [LocalDate: Int64] = [:]
        if let goal, let lookback = lookback(week: mon, today: today) {
            let lo = lookback.lowerBound.dayInterval(in: timeZone, dayStartHour: dayStartHour).lowerBound - 15 * h
            let hi = lookback.upperBound.dayInterval(in: timeZone, dayStartHour: dayStartHour).upperBound + 15 * h
            let spans = try store.effectiveSpans(rangeFrom: lo, to: hi)
            history = workByDay(RangeData.bucket(spans, into: lookback, dayStartHour: dayStartHour),
                                classifier: classifier, categories: categories, goal: goal)
        }
        var data = assemble(range: range, goal: goal, today: today, history: history, dayStartHour: dayStartHour)
        // ponytail: spans are classified twice (here and inside RangeData.build); a week is a few hundred spans.
        data.daySpans = edited.mapValues { classifier.classifyAll($0) }
        let settings = try SettingStore(store.db).all()
        data.blockThresholdMin = Dictionary(uniqueKeysWithValues: data.dates.map { ($0, BlocksThreshold.minutes(for: $0, settings: settings)) })
        data.blockWindowHours = BlocksThreshold.windowHours(settings)
        data.blockWindowStartMin = BlocksThreshold.windowStartMinutes(settings)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        data.nowMs = (weekLo..<weekHi).contains(nowMs) ? nowMs : nil
        return data
    }

    /// Deterministic week from `DemoData` with seed classification: a tracker gap (Wed 14:00–15:20) and a
    /// manual add (Thu 18:00–18:45, client call) so the gap and `±` markers have something to show.
    /// Days after `today` are dropped (future); `empty` gives a week with no spans at all. `now` (a clock
    /// time on `today`) cuts today's spans there and sets `nowMs`; `thresholdMin` is every day's break threshold.
    public static func fixture(week: LocalDate = LocalDate(year: 2026, month: 9, day: 28),
                               today: LocalDate = LocalDate(year: 2026, month: 10, day: 5),
                               tzId: String = "America/Vancouver", goal: Goal? = Goal(dailyWorkMs: 7 * 3_600_000),
                               empty: Bool = false, now: (hour: Int, minute: Int)? = nil,
                               thresholdMin: Int = MetricsBlocks.defaultThresholdMin) -> WeekData {
        let tz = TimeZone(identifier: tzId) ?? .gmt
        let mon = weekStart(week)
        let sun = mon.adding(days: 6)
        let first = mon.adding(days: -streakLookbackDays)
        let last = min(sun, today)
        var spans = empty || last < first ? [] : DemoData.spans(from: first, through: last, tzId: tzId)
        func at(_ d: LocalDate, _ h: Int, _ m: Int) -> Int64 {
            d.dayInterval(in: tz, dayStartHour: 0).lowerBound + Int64(h * 60 + m) * 60_000
        }
        let wed = mon.adding(days: 2), thu = mon.adding(days: 3)
        let hole = at(wed, 14, 0)..<at(wed, 15, 20)
        spans.removeAll { hole.contains($0.startMs) }
        let nowMs = now.map { at(today, $0.hour, $0.minute) }
        if let nowMs { spans = spans.compactMap { s in s.startMs >= nowMs ? nil : { var c = s; c.endMs = min(c.endMs, nowMs); return c }() } }
        for i in spans.indices { spans[i].seq = Int64(i + 1) }
        var edits: [Edit] = []
        if !empty && thu <= today && (nowMs ?? .max) >= at(thu, 18, 45) {
            let seq = Int64(spans.count + 1)
            edits.append(Edit(seq: seq, grp: seq, createdMs: at(thu, 19, 0), tzId: tzId, op: .add,
                              loMs: at(thu, 18, 0), hiMs: at(thu, 18, 45), target: nil,
                              payload: .add(label: "Client call — Alex", categoryId: ClassifySeed.meetings, projectId: 2)))
        }
        let classifier = Classifier(categories: ClassifySeed.categories, rules: ClassifySeed.rules, projects: ClassifySeed.projects)
        let bounds = mon...sun
        let edited = effectiveSpans(raw: spans, edits: edits)
        let range = RangeData.build(period: .custom(mon, sun), bounds: bounds,
                                    edited: RangeData.bucket(edited, into: bounds),
                                    raw: RangeData.bucket(effectiveSpans(raw: spans, edits: []), into: bounds),
                                    classifier: classifier, categories: ClassifySeed.categories,
                                    projects: ClassifySeed.projects, timeZone: tz)
        var history: [LocalDate: Int64] = [:]
        if let goal, let lookback = lookback(week: mon, today: today) {
            history = workByDay(RangeData.bucket(edited, into: lookback), classifier: classifier,
                                categories: ClassifySeed.categories, goal: goal)
        }
        var data = assemble(range: range, goal: goal, today: today, history: history, dayStartHour: Hours.defaultDayStartHour)
        data.daySpans = RangeData.bucket(edited, into: bounds).mapValues { classifier.classifyAll($0) }
        data.blockThresholdMin = Dictionary(uniqueKeysWithValues: data.dates.map { ($0, thresholdMin) })
        data.nowMs = nowMs
        return data
    }

    static func assemble(range: RangeData, goal: Goal?, today: LocalDate, history: [LocalDate: Int64],
                         dayStartHour: Int) -> WeekData {
        var data = WeekData(range: range, goal: goal, today: today, streak: 0, dayStartHour: dayStartHour)
        if let goal {
            var work = history
            for d in range.metrics.days { work[d.date] = d.metrics.workMs }
            // Every date in the walk is present (0 if empty), so the walk runs back through the whole look-back.
            let end = min(today, data.sunday)
            var d = end.adding(days: -streakLookbackDays)
            while d <= end { work[d] = work[d] ?? 0; d = d.adding(days: 1) }
            // ponytail: the streak is capped by the look-back window (56 days); a longer run reads as ~40 workdays.
            data.streak = Streak.compute(workMs: work, goal: goal, today: end)
        }
        return data
    }

    /// Days before the week (and up to `today`) the streak walk may need, or nil if none.
    static func lookback(week mon: LocalDate, today: LocalDate) -> ClosedRange<LocalDate>? {
        let end = min(today, mon.adding(days: -1))
        let start = min(today, mon.adding(days: 6)).adding(days: -streakLookbackDays)
        return start <= end ? start...end : nil
    }

    static func workByDay(_ days: [LocalDate: [EffectiveSpan]], classifier: Classifier,
                          categories: [HoursCore.Category], goal: Goal) -> [LocalDate: Int64] {
        var out: [LocalDate: Int64] = [:]
        for (d, spans) in days where goal.isScheduled(d) {
            out[d] = DayMetrics.compute(spans: classifier.classifyAll(spans), categories: categories).workMs
        }
        return out
    }

    // MARK: Week shape

    /// Monday of the week containing `d` (calendar arithmetic, so DST never shifts it).
    public static func weekStart(_ d: LocalDate) -> LocalDate { d.adding(days: -d.isoWeekdayIndex) }

    public var monday: LocalDate { range.bounds.lowerBound }
    public var sunday: LocalDate { range.bounds.upperBound }
    /// Mon…Sun.
    public var dates: [LocalDate] { (0..<7).map { monday.adding(days: $0) } }
    public var metrics: RangeMetrics { range.metrics }
    public var isCurrentWeek: Bool { range.bounds.contains(today) }
    public var isEmpty: Bool { metrics.trackedMs == 0 }

    /// ISO-8601 week number (week 1 holds the year's first Thursday).
    public var weekNumber: Int {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.component(.weekOfYear, from: monday.rangeDate)
    }

    func dayMetrics(_ d: LocalDate) -> DayMetrics? { metrics.days.first { $0.date == d }?.metrics }
    func workMs(_ d: LocalDate) -> Int64 { dayMetrics(d)?.workMs ?? 0 }
    func isFuture(_ d: LocalDate) -> Bool { d > today }
    func hasGap(_ d: LocalDate) -> Bool { range.days.first { $0.date == d }.map { !$0.gaps.isEmpty } ?? false }

    // MARK: Goal

    /// The day's target, nil when the goal doesn't apply that weekday.
    public func goalMs(_ d: LocalDate) -> Int64? {
        guard let goal, goal.isScheduled(d) else { return nil }
        return goal.dailyWorkMs
    }

    /// Σ daily targets over the week's scheduled days.
    public var weeklyTargetMs: Int64 { dates.compactMap(goalMs).reduce(0, +) }

    /// Target through today for the current week (pro-rated pace); the full target otherwise.
    public var paceTargetMs: Int64 { dates.filter { !isFuture($0) }.compactMap(goalMs).reduce(0, +) }

    public func goalMet(_ d: LocalDate) -> Bool { goalMs(d).map { workMs(d) >= $0 } ?? false }

    /// Scheduled days at goal / scheduled days that count so far: past days, plus today once met
    /// (today isn't a miss until it's over).
    public var goalDays: (met: Int, of: Int) {
        let counted = dates.filter { goalMs($0) != nil && ($0 < today || ($0 == today && goalMet($0))) }
        return (counted.filter(goalMet).count, counted.count)
    }

    /// Edited − raw work, nil when no edit shaped the week.
    public var workDeltaMs: Int64? { range.editCount > 0 ? metrics.workMs - range.raw.workMs : nil }

    public var bestDay: LocalDate? {
        metrics.days.filter { $0.metrics.workMs > 0 }.max { $0.metrics.workMs < $1.metrics.workMs }?.date
    }

    // MARK: Heatmap

    /// 7 × 24 work ms: row = weekday (Mon first), column c = local clock hour `(dayStartHour + c) % 24`,
    /// so a row reads like the store's day (04:00 → 03:59).
    public var heat: [[Int64]] {
        dates.map { d in
            let hourly = dayMetrics(d)?.hourly ?? Array(repeating: DayMetrics.HourBucket(), count: 24)
            return (0..<24).map { c in hourly[(dayStartHour + c) % 24].workMs }
        }
    }

    /// Ramp step for an hour cell: 0 = none, then one step per 12 min of work (an hour holds ≤ 60).
    public static func heatLevel(_ ms: Int64) -> Int {
        guard ms > 0 else { return 0 }
        let step: Int64 = 12 * 60_000
        return Int(min(5, max(1, (ms + step - 1) / step)))
    }

    // MARK: Stacked bars

    struct Segment: Hashable {
        var day: Int, name: String, loMs: Int64, hiMs: Int64, isTop: Bool
    }

    /// Work categories by week work time: top 7, the rest folded into "Other" (grey).
    var legend: [(key: Int64, name: String, slot: Int?)] {
        let work = metrics.byCategory.filter { $0.workMs > 0 }.compactMap { r -> (Int64, String, Int?)? in
            guard let id = r.key else { return nil }
            let l = range.label(.category(id))
            return (id, l.name, l.slot)
        }
        var out = work.prefix(7).map { (key: $0.0, name: $0.1, slot: $0.2) }
        if work.count > 7 { out.append((key: -1, name: "Other", slot: nil)) }
        return out
    }

    /// Per-day work by category, stacked in legend order (bottom first). Bar height = the day's work.
    var segments: [Segment] {
        let legend = self.legend
        let order = Dictionary(uniqueKeysWithValues: legend.enumerated().map { ($1.key, $0) })
        var out: [Segment] = []
        for (i, d) in dates.enumerated() {
            guard let m = dayMetrics(d) else { continue }
            var parts = Array(repeating: Int64(0), count: legend.count)
            for r in m.byCategory where r.workMs > 0 {
                guard let k = r.key else { continue }
                parts[order[k] ?? legend.count - 1] += r.workMs
            }
            var lo: Int64 = 0
            let lastIdx = parts.lastIndex { $0 > 0 }
            for (j, ms) in parts.enumerated() where ms > 0 {
                out.append(Segment(day: i, name: legend[j].name, loMs: lo, hiMs: lo + ms, isTop: j == lastIdx))
                lo += ms
            }
        }
        return out
    }
}
