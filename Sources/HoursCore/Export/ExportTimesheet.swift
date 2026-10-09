import Foundation

/// Classification config as of export. Falls back to the bundled seed when the DB has none yet.
public struct ExportConfig: Sendable {
    public var categories: [Category]
    public var projects: [Project]
    public var rules: [Rule]
    public var fromSeed: Bool

    public static func load(_ db: HoursDB) throws -> ExportConfig {
        let cfg = ConfigStore(db)
        let cats = try cfg.categories()
        // ponytail: seed fallback until the app seeds the config tables (W8/W9); then it never triggers.
        if cats.isEmpty {
            return ExportConfig(categories: ClassifySeed.categories, projects: ClassifySeed.projects,
                                rules: ClassifySeed.rules, fromSeed: true)
        }
        return ExportConfig(categories: cats, projects: try cfg.projects(), rules: try cfg.rules(), fromSeed: false)
    }

    /// Canonical JSON of categories, projects and enabled+disabled rules (sorted keys) — the audit's rules snapshot.
    public var snapshotJSON: Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        struct Snap: Encodable { var categories: [Category]; var projects: [Project]; var rules: [Rule]; var fromSeed: Bool }
        return try! enc.encode(Snap(categories: categories, projects: projects, rules: rules, fromSeed: fromSeed)) + Data("\n".utf8)
    }
}

/// One billing period, classified: per-day spans, range metrics and the invoice rows.
public struct ExportPeriodData: Sendable {
    /// item 5 billable tier, stamped into the audit summary.
    public static let definitionVersion = "billable = active ∧ category.is_work ∧ project assigned (item 5, v1)"
    /// Stands in for a manual entry's (private) label wherever the disclosure level hides it.
    public static let manualLabel = "Manual entry"

    public struct Row: Sendable, Hashable {
        public var date: LocalDate
        public var project: String
        public var ms: Int64
        /// Hours × 100, rounded half-up per row (D9).
        public var hundredths: Int64
        public var summary: String
    }

    public var period: ExportPeriod
    public var config: ExportConfig
    public var days: [LocalDate: [ClassifiedSpan]]
    public var metrics: RangeMetrics
    public var rows: [Row]

    /// Period total = Σ displayed rounded rows (D9).
    public var totalHundredths: Int64 { rows.reduce(0) { $0 + $1.hundredths } }

    public static func load(_ db: HoursDB, period: ExportPeriod) throws -> ExportPeriodData {
        let config = try ExportConfig.load(db)
        // Same precedence as the app (rules > Jev cache > Browsing), so Range totals match the export.
        let classifier = Classifier(categories: config.categories, rules: config.rules, projects: config.projects,
                                    jev: try JevCacheStore(db).snapshot())
        let store = Store(db)
        var days: [LocalDate: [ClassifiedSpan]] = [:]
        for d in period.days { days[d] = classifier.classifyAll(try store.effectiveSpans(day: d)) }
        return build(period: period, config: config, days: days)
    }

    static func build(period: ExportPeriod, config: ExportConfig, days: [LocalDate: [ClassifiedSpan]]) -> ExportPeriodData {
        let metrics = RangeMetrics.compute(days: days, categories: config.categories)
        let cats = Dictionary(uniqueKeysWithValues: config.categories.map { ($0.id, $0) })
        let names = Dictionary(uniqueKeysWithValues: config.projects.map { ($0.id, $0.name) })
        let rows = metrics.billable.map { b in
            var byApp: [String: Int64] = [:]
            for c in days[b.date] ?? [] where c.projectId == b.projectId && exportIsWork(c, cats) {
                // The label is private edit payload; the timesheet is disclosure-independent (it backs the
                // witness line), so it never shows it.
                let name = c.span.source == .manual ? Self.manualLabel : c.span.appName
                byApp[name, default: 0] += c.span.durationMs
            }
            let top = byApp.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3)
            let summary = top.map { "\($0.key) \(String(format: "%.1f", Double($0.value) / 3_600_000))h" }
                .joined(separator: "; ")
            return Row(date: b.date, project: names[b.projectId] ?? "#\(b.projectId)", ms: b.ms,
                       hundredths: hundredths(ms: b.ms), summary: summary)
        }
        return ExportPeriodData(period: period, config: config, days: days, metrics: metrics,
                                rows: rows.sorted { ($0.date, $0.project) < ($1.date, $1.project) })
    }

    /// `timesheet.csv`: one row per day×project with billable time, sorted by date then project name.
    public var timesheetCSV: Data {
        ExportCSV.render(header: ["date", "project", "hours", "seconds", "summary"], rows: rows.map {
            [$0.date.description, $0.project, Self.hours($0.hundredths), String($0.ms / 1000), $0.summary]
        })
    }

    /// One invoice row's hours in 0.01 h, half up. The invoice total is Σ of these per (day, project)
    /// row — Range shows the same figure (`RangeData.invoiceHundredths`).
    public static func hundredths(ms: Int64) -> Int64 { (ms * 100 + 1_800_000) / 3_600_000 }

    /// `1234` → `"12.34"`.
    public static func hours(_ hundredths: Int64) -> String { String(format: "%lld.%02lld", hundredths / 100, hundredths % 100) }
}

/// Work-tier test matching item 5: active, known category, `is_work`, not excluded.
func exportIsWork(_ c: ClassifiedSpan, _ cats: [Int64: Category]) -> Bool {
    guard c.span.kind == .active, let cat = c.categoryId.flatMap({ cats[$0] }) else { return false }
    return cat.isWork && cat.behavior != .exclude
}
