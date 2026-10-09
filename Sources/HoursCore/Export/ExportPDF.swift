import Foundation

/// The invoice-ready PDF timesheet (09, PDF layout). Every number comes from `ExportPeriodData` — the
/// same model `timesheet.csv` renders — so PDF and CSV cannot disagree. Drawing is in `ExportPDFRender`.
public enum ExportPDF {
    /// Everything the PDF shows, gathered once. `render` is pure over this.
    public struct Document: Sendable {
        public var data: ExportPeriodData
        public var mode: ExportMode
        public var disclosure: Disclosure
        public var tz: TimeZone
        public var generatedMs: Int64
        public var name: String
        public var headSeq: Int64
        public var headHash: Data
        /// The anchor whose head is the current head (nil = head not yet anchored), as in the witness line.
        public var headAnchor: ChainAnchor?
        /// Audit appendix: anchors requested from the period start through the first one after its end.
        public var anchors: [ChainAnchor]
        /// Audit appendix: edits overlapping the period (same scoping as the bundle's edits.csv).
        public var edits: [Edit]
        /// End of the period's last store day, unix ms (edits created at or after it are flagged).
        public var periodEndMs: Int64
        public var witness: String
    }

    public struct Result: Sendable {
        public var data: ExportPeriodData
        public var url: URL
        public var pages: Int
    }

    /// Setting for the "Consultant" line (Settings → Data). Absent/blank = `NSFullUserName()`.
    public static let consultantNameKey = "consultant_name"

    public static func consultantName(_ settings: [String: String]) -> String {
        let n = settings[consultantNameKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? NSFullUserName() : n
    }

    /// `timesheet-<from>_<through>.pdf`.
    public static func fileName(_ period: ExportPeriod) -> String { "timesheet-\(period.from)_\(period.through).pdf" }

    public static func load(db: HoursDB, period: ExportPeriod, mode: ExportMode, disclosure: Disclosure = .L0,
                            tz: TimeZone = .current, generatedMs: Int64? = nil, name: String? = nil) throws -> Document {
        let data = try ExportPeriodData.load(db, period: period)
        let head = try db.head()
        let all = try AnchorStore(db).list()
        let headAnchor = all.last { $0.headSeq == head.seq && $0.genTimeMs != nil }
        // ponytail: same current-tz period bounds as ExportBundle's edit scoping.
        let lo = period.from.dayInterval(in: tz).lowerBound, hi = period.through.dayInterval(in: tz).upperBound
        var anchors: [ChainAnchor] = []
        if mode == .audit {
            for a in all where a.requestedMs >= lo {
                anchors.append(a)
                if a.requestedMs >= hi { break }
            }
        }
        return Document(data: data, mode: mode, disclosure: disclosure, tz: tz,
                        generatedMs: generatedMs ?? Int64(Date().timeIntervalSince1970 * 1000),
                        name: try name ?? consultantName(SettingStore(db).all()), headSeq: head.seq, headHash: head.hash, headAnchor: headAnchor,
                        anchors: anchors, edits: mode == .audit ? try Store(db).edits(overlapping: lo, hi) : [],
                        periodEndMs: hi,
                        witness: ExportWitness.line(period: period, data: data, headSeq: head.seq, headHash: head.hash,
                                                    anchor: headAnchor))
    }

    /// Writes `dir/timesheet-<from>_<through>.pdf`.
    @discardableResult
    public static func write(db: HoursDB, period: ExportPeriod, mode: ExportMode, disclosure: Disclosure = .L0,
                             to dir: URL, tz: TimeZone = .current, generatedMs: Int64? = nil,
                             name: String? = nil) throws -> Result {
        let doc = try load(db: db, period: period, mode: mode, disclosure: disclosure, tz: tz,
                           generatedMs: generatedMs, name: name)
        let (pdf, pages) = ExportPDFRender.render(doc)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: fileName(period))
        try pdf.write(to: url, options: .atomic)
        return Result(data: doc.data, url: url, pages: pages)
    }

    // MARK: - Derived tables (all from the export model)

    /// Billable ms per project, with per-category split. Sums equal `data.rows` per project exactly.
    struct ProjectBreakdown {
        var project: String
        var ms: Int64
        /// Σ of this project's rounded day rows (D9) — what the invoice bills.
        var hundredths: Int64
        var days: Int
        var categories: [(name: String, ms: Int64)]
    }

    static func projects(_ data: ExportPeriodData) -> [ProjectBreakdown] {
        let cats = Dictionary(uniqueKeysWithValues: data.config.categories.map { ($0.id, $0) })
        let names = Dictionary(uniqueKeysWithValues: data.config.projects.map { ($0.id, $0.name) })
        var byCat: [String: [String: Int64]] = [:]
        for spans in data.days.values {
            for c in spans where exportIsWork(c, cats) {
                guard let p = c.projectId, let cat = c.categoryId.flatMap({ cats[$0] }) else { continue }
                byCat[names[p] ?? "#\(p)", default: [:]][cat.name, default: 0] += c.span.durationMs
            }
        }
        return Dictionary(grouping: data.rows, by: \.project).map { project, rows in
            ProjectBreakdown(project: project, ms: rows.reduce(0) { $0 + $1.ms },
                             hundredths: rows.reduce(0) { $0 + $1.hundredths }, days: Set(rows.map(\.date)).count,
                             categories: (byCat[project] ?? [:]).map { ($0.key, $0.value) }
                                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 })
        }.sorted { $0.ms != $1.ms ? $0.ms > $1.ms : $0.project < $1.project }
    }

    /// Splits `total` hundredths over `weights` in proportion (largest remainder), so the parts sum to `total`.
    static func allocate(_ total: Int64, _ weights: [Int64]) -> [Int64] {
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return weights.map { _ in 0 } }
        var parts = weights.map { $0 * total / sum }
        let byRemainder = weights.indices.sorted { (weights[$0] * total % sum, $1) > (weights[$1] * total % sum, $0) }
        for i in byRemainder.prefix(Int(total - parts.reduce(0, +))) { parts[i] += 1 }
        return parts
    }

    /// Clients of the billed projects ("" when none is set).
    static func client(_ data: ExportPeriodData) -> String {
        let billed = Set(data.rows.map(\.project))
        let clients = data.config.projects.filter { billed.contains($0.name) }.compactMap(\.client)
        return Array(Set(clients)).sorted().joined(separator: ", ")
    }

    /// Billable ms that came from manual entries.
    static func manualMs(_ data: ExportPeriodData) -> Int64 {
        let cats = Dictionary(uniqueKeysWithValues: data.config.categories.map { ($0.id, $0) })
        return data.days.values.joined()
            .filter { $0.span.source == .manual && $0.projectId != nil && exportIsWork($0, cats) }
            .reduce(0) { $0 + $1.span.durationMs }
    }

    /// One edit's appendix detail. Payloads (labels, notes, assignments) are private: shown only at L2.
    static func editDetail(_ e: Edit, _ data: ExportPeriodData, _ disclosure: Disclosure) -> String {
        let cats = Dictionary(uniqueKeysWithValues: data.config.categories.map { ($0.id, $0.name) })
        let projects = Dictionary(uniqueKeysWithValues: data.config.projects.map { ($0.id, $0.name) })
        func names(_ c: Int64?, _ p: Int64?) -> String {
            [c.map { cats[$0] ?? "#\($0)" }, p.map { projects[$0] ?? "#\($0)" }].compactMap { $0 }.joined(separator: " · ")
        }
        let shown = disclosure == .L2
        switch e.payload {
        case .delete: return "Time removed"
        case .undo: return "Reverts edit group #\(e.target.map(String.init) ?? "?")"
        case let .add(label, c, p):
            return shown ? [label, names(c, p)].filter { !$0.isEmpty }.joined(separator: " — ") : ExportPeriodData.manualLabel
        case let .assign(c, p): return shown ? "Reassigned: \(names(c, p))" : "Reassigned (details withheld)"
        case let .note(text): return shown ? "Note on group #\(e.target.map(String.init) ?? "?"): \(text)" : "Note (withheld)"
        }
    }
}
