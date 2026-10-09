import Foundation
import HoursCore

/// What one row of the Range table is keyed on. Same key semantics as `DayMetrics` breakdowns.
public enum RangeGroup: String, CaseIterable, Identifiable, Sendable {
    case category = "Category", project = "Project", app = "App", site = "Site"
    public var id: String { rawValue }
}

public enum RangeKey: Hashable, Sendable {
    /// nil = Uncategorized.
    case category(Int64?)
    /// nil = no project (unassigned).
    case project(Int64?)
    /// `DayMetrics.App.id` (bundle id, else app name).
    case app(String)
    /// nil = no site (non-browser time).
    case site(String?)
}

/// Per-day facts the view shows that `RangeMetrics` doesn't carry.
public struct RangeDay: Sendable, Hashable {
    public var date: LocalDate
    /// Holes in the tracker's own record (raw spans, active or idle) between the day's first and
    /// last span, each >= `RangeData.gapMinMs`. Edits never create gaps; only missing tracking does.
    public var gaps: [Range<Int64>]
    public var gapMs: Int64 { gaps.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
}

/// Drill-down for one key: where the time went, top first.
public struct RangeDetail: Sendable, Hashable {
    public struct Item: Sendable, Hashable { public var name: String; public var ms: Int64 }
    /// Window titles (manual entries: their label), top 20.
    public var titles: [Item] = []
    /// Site host for browser time, else app name; for a site key, the apps it was open in. Top 10.
    public var contexts: [Item] = []
}

/// Everything the Range view draws for one period. Totals come from `RangeMetrics` — the same
/// function export uses — so the view never re-adds spans itself.
public struct RangeData: Sendable {
    public var period: RangePeriod
    public var bounds: ClosedRange<LocalDate>
    /// Edited (effective) metrics: what's invoiced.
    public var metrics: RangeMetrics
    /// The same days with every edit ignored (raw tracker record), for the `±` marker.
    public var raw: RangeMetrics
    /// Every date in `bounds`, ascending (empty days included).
    public var days: [RangeDay]
    /// Distinct edit seqs that shaped any span in the period.
    public var editCount: Int
    public var categories: [HoursCore.Category]
    public var projects: [Project]
    public var timeZone: TimeZone
    var details: [RangeKey: RangeDetail]

    public static let gapMinMs: Int64 = 5 * 60_000

    public func detail(_ key: RangeKey) -> RangeDetail { details[key] ?? RangeDetail() }
    public var gapDays: [RangeDay] { days.filter { !$0.gaps.isEmpty } }
    /// Edited − raw billable.
    public var billableDeltaMs: Int64 { metrics.billableMs - raw.billableMs }

    /// What the invoice bills, in 0.01 h: each (day, project) row rounded, then summed — exactly the
    /// export's `timesheet.csv` total, which can differ from `metrics.billableMs` by rounding.
    public var invoiceHundredths: Int64 { metrics.billable.reduce(0) { $0 + ExportPeriodData.hundredths(ms: $1.ms) } }

    /// One project's invoice hours (0.01 h), same per-row rounding.
    public func invoiceHundredths(project id: Int64) -> Int64 {
        metrics.billable.reduce(0) { $0 + ($1.projectId == id ? ExportPeriodData.hundredths(ms: $1.ms) : 0) }
    }

    // MARK: Loading

    /// Reads the period from the store: edited spans per local day (the store's day clipping, as export does),
    /// plus the raw record over the same window for the `±` delta and tracker gaps.
    public static func load(store: Store, classifier: Classifier, categories: [HoursCore.Category], projects: [Project],
                            period: RangePeriod, today: LocalDate, timeZone: TimeZone = .current,
                            dayStartHour: Int = Hours.defaultDayStartHour) throws -> RangeData {
        let bounds = period.bounds(today: today)
        let dates = LocalDate.all(in: bounds)
        var edited: [LocalDate: [EffectiveSpan]] = [:]
        for d in dates { edited[d] = try store.effectiveSpans(day: d, dayStartHour: dayStartHour) }
        // Window wide enough for every tz, like the store's own candidate window.
        let h: Int64 = 3_600_000
        let lo = bounds.lowerBound.dayInterval(in: timeZone, dayStartHour: dayStartHour).lowerBound - 15 * h
        let hi = bounds.upperBound.dayInterval(in: timeZone, dayStartHour: dayStartHour).upperBound + 15 * h
        let raw = effectiveSpans(raw: try store.rawSpans(from: lo, to: hi), edits: [])
        return build(period: period, bounds: bounds, edited: edited,
                     raw: bucket(raw, into: bounds, dayStartHour: dayStartHour),
                     classifier: classifier, categories: categories, projects: projects, timeZone: timeZone)
    }

    /// Deterministic data from `DemoData` with seed classification, two tracker gaps and a few edits
    /// (an assign, a delete, a manual add) so every marker has something to show. No store involved.
    public static func fixture(period: RangePeriod = .previousBilling, today: LocalDate = LocalDate(year: 2026, month: 10, day: 5),
                               tzId: String = "America/Vancouver") -> RangeData {
        let tz = TimeZone(identifier: tzId)!
        let bounds = period.bounds(today: today)
        var spans = DemoData.spans(from: bounds.lowerBound, through: bounds.upperBound, tzId: tzId)
        let weekdays = LocalDate.all(in: bounds).filter { !$0.isWeekend }
        func at(_ d: LocalDate, _ h: Int, _ m: Int) -> Int64 {
            d.dayInterval(in: tz, dayStartHour: 0).lowerBound + Int64(h * 60 + m) * 60_000
        }
        // Tracker gaps: drop the raw spans that start inside a window (the tracker wasn't running).
        var holes: [Range<Int64>] = []
        if weekdays.count > 2 { holes.append(at(weekdays[2], 14, 0)..<at(weekdays[2], 15, 20)) }
        if weekdays.count > 7 { holes.append(at(weekdays[7], 9, 40)..<at(weekdays[7], 10, 25)) }
        spans.removeAll { s in holes.contains { $0.contains(s.startMs) } }
        for i in spans.indices { spans[i].seq = Int64(i + 1) }

        var edits: [Edit] = []
        func edit(_ op: EditOp, _ lo: Int64, _ hi: Int64, _ p: EditPayload) {
            let seq = Int64(spans.count + edits.count + 1)
            edits.append(Edit(seq: seq, grp: seq, createdMs: hi, tzId: tzId, op: op, loMs: lo, hiMs: hi, target: nil, payload: p))
        }
        if weekdays.count > 1 {
            edit(.assign, at(weekdays[1], 14, 0), at(weekdays[1], 15, 30), .assign(categoryId: ClassifySeed.coding, projectId: 6))
        }
        if weekdays.count > 4 { edit(.delete, at(weekdays[4], 16, 0), at(weekdays[4], 16, 25), .delete) }
        if weekdays.count > 5 {
            edit(.add, at(weekdays[5], 18, 0), at(weekdays[5], 18, 45),
                 .add(label: "Client call — Alex", categoryId: ClassifySeed.meetings, projectId: 2))
        }

        let classifier = Classifier(categories: ClassifySeed.categories, rules: ClassifySeed.rules, projects: ClassifySeed.projects)
        return build(period: period, bounds: bounds,
                     edited: bucket(effectiveSpans(raw: spans, edits: edits), into: bounds),
                     raw: bucket(effectiveSpans(raw: spans, edits: []), into: bounds),
                     classifier: classifier, categories: ClassifySeed.categories, projects: ClassifySeed.projects, timeZone: tz)
    }

    // MARK: Building

    static func build(period: RangePeriod, bounds: ClosedRange<LocalDate>, edited: [LocalDate: [EffectiveSpan]],
                      raw: [LocalDate: [EffectiveSpan]], classifier: Classifier,
                      categories: [HoursCore.Category], projects: [Project], timeZone: TimeZone) -> RangeData {
        let dates = LocalDate.all(in: bounds)
        var editedC: [LocalDate: [ClassifiedSpan]] = [:], rawC: [LocalDate: [ClassifiedSpan]] = [:]
        var editSeqs = Set<Int64>()
        var days: [RangeDay] = []
        for d in dates {
            let e = edited[d] ?? [], r = raw[d] ?? []
            editedC[d] = classifier.classifyAll(e)
            rawC[d] = classifier.classifyAll(r)
            for s in e { editSeqs.formUnion(s.editSeqs) }
            days.append(RangeDay(date: d, gaps: gaps(r)))
        }
        return RangeData(
            period: period, bounds: bounds,
            metrics: RangeMetrics.compute(days: editedC, categories: categories),
            raw: RangeMetrics.compute(days: rawC, categories: categories),
            days: days, editCount: editSeqs.count, categories: categories, projects: projects,
            timeZone: timeZone, details: index(editedC, categories: categories))
    }

    /// Splits spans into local days (each in its own tz), clipping at day boundaries — the store's rule.
    static func bucket(_ spans: [EffectiveSpan], into bounds: ClosedRange<LocalDate>,
                       dayStartHour: Int = Hours.defaultDayStartHour) -> [LocalDate: [EffectiveSpan]] {
        var out: [LocalDate: [EffectiveSpan]] = [:]
        var tzs: [String: TimeZone] = [:]
        for s in spans where s.endMs > s.startMs {
            let tz = tzs[s.tzId] ?? (TimeZone(identifier: s.tzId) ?? .gmt)
            tzs[s.tzId] = tz
            var d = LocalDate.containing(ms: s.startMs, in: tz, dayStartHour: dayStartHour)
            while true {
                let b = d.dayInterval(in: tz, dayStartHour: dayStartHour)
                guard b.lowerBound < s.endMs else { break }
                if bounds.contains(d) {
                    var c = s
                    c.startMs = max(s.startMs, b.lowerBound); c.endMs = min(s.endMs, b.upperBound)
                    if c.endMs > c.startMs { out[d, default: []].append(c) }
                }
                d = d.adding(days: 1)
            }
        }
        return out
    }

    /// Holes >= `gapMinMs` between consecutive raw spans of one day.
    static func gaps(_ raw: [EffectiveSpan]) -> [Range<Int64>] {
        let sorted = raw.sorted { $0.startMs < $1.startMs }
        var out: [Range<Int64>] = []
        var edge: Int64?
        for s in sorted {
            if let e = edge, s.startMs - e >= gapMinMs { out.append(e..<s.startMs) }
            edge = max(edge ?? s.endMs, s.endMs)
        }
        return out
    }

    /// Top titles/contexts per key, over the spans `RangeMetrics` counts (active, not excluded).
    static func index(_ days: [LocalDate: [ClassifiedSpan]], categories: [HoursCore.Category]) -> [RangeKey: RangeDetail] {
        var cats: [Int64: HoursCore.Category] = [:]
        for c in categories { cats[c.id] = c }
        var titles: [RangeKey: [String: Int64]] = [:], contexts: [RangeKey: [String: Int64]] = [:]
        for spans in days.values {
            for c in spans {
                let s = c.span
                guard s.kind == .active, s.endMs > s.startMs else { continue }
                let cat = c.categoryId.flatMap { cats[$0] }
                if cat?.behavior == .exclude { continue }
                let host = ClassifyURL.host(s.url)
                let title = s.label ?? s.title ?? "(no title)"
                let context = host ?? (s.appName.isEmpty ? "Manual entry" : s.appName)
                let appName = s.appName.isEmpty ? "Manual entry" : s.appName
                let keys: [RangeKey] = [.category(cat?.id), .project(c.projectId), .app(s.bundleId ?? s.appName), .site(host)]
                for k in keys {
                    titles[k, default: [:]][title, default: 0] += s.durationMs
                    if case .site = k {
                        contexts[k, default: [:]][appName, default: 0] += s.durationMs
                    } else if case .app = k {
                        if let host { contexts[k, default: [:]][host, default: 0] += s.durationMs }
                    } else {
                        contexts[k, default: [:]][context, default: 0] += s.durationMs
                    }
                }
            }
        }
        func top(_ m: [String: Int64]?, _ n: Int) -> [RangeDetail.Item] {
            (m ?? [:]).map { RangeDetail.Item(name: $0.key, ms: $0.value) }
                .sorted { ($0.ms, $1.name) > ($1.ms, $0.name) }
                .prefix(n).map { $0 }
        }
        var out: [RangeKey: RangeDetail] = [:]
        for k in titles.keys { out[k] = RangeDetail(titles: top(titles[k], 20), contexts: top(contexts[k], 10)) }
        return out
    }
}
