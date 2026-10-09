import Foundation

/// Store side of the Rize import: reads what Hours already covers, writes blocks as manual `add` edits.
/// Imported time never becomes raw spans — it must not pose as Hours-observed.
public struct RizeImporter: Sendable {
    public let db: HoursDB
    public init(_ db: HoursDB) { self.db = db }

    public struct Result: Sendable {
        public var groups: [Int64] = []
        public var blocks = 0
        public var ms: Int64 = 0
        public var createdProjects: [String] = []
    }

    /// Plans against the store's current contents (idempotency + overlap come from here).
    public func plan(_ snap: RizeSnapshot, since: LocalDate? = nil) throws -> RizeImportPlan {
        let times = try snap.events.flatMap { [try rizeMs($0.startTime), try rizeMs($0.endTime)] }
        guard let lo = times.min(), let hi = times.max() else { return RizeImportPlan(blocks: []) }
        let c = try coverage(from: lo, to: hi)
        return try RizeImportPlanner.plan(snap, since: since, alreadyImported: c.rize, tracked: c.tracked)
    }

    /// Earlier Rize imports (live adds labelled "Rize · ") vs everything else Hours has over [lo, hi):
    /// raw spans of any kind (idle is observed too), other live adds, and [live span start, ∞).
    /// Reads tables directly, not `effectiveSpans`: a deleted tracked range must stay unfillable,
    /// and replaying months of adds through the derivation would be quadratic.
    public func coverage(from lo: Int64, to hi: Int64) throws -> (rize: [Range<Int64>], tracked: [Range<Int64>]) {
        let store = Store(db)
        var tracked = try store.rawSpans(from: lo, to: hi).filter { $0.seq != 0 && $0.endMs > $0.startMs }
            .map { $0.startMs..<$0.endMs }
        if let live = try SpanWriter(db).liveSpan() { tracked.append(live.startMs..<Int64.max) }
        var rize: [Range<Int64>] = []
        for e in Self.liveEdits(try store.edits(overlapping: lo, hi)) {
            guard case let .add(label, _, _) = e.payload, e.hiMs > e.loMs else { continue }
            if label.hasPrefix(RizeImportPlanner.labelPrefix) { rize.append(e.loMs..<e.hiMs) } else { tracked.append(e.loMs..<e.hiMs) }
        }
        return (rize, tracked)
    }

    /// Project names the plan uses that Hours doesn't have yet (case-insensitive), sorted.
    public func missingProjects(_ plan: RizeImportPlan) throws -> [String] {
        let have = Set(try ConfigStore(db).projects().map { $0.name.lowercased() })
        return Set(plan.blocks.compactMap(\.project)).filter { !have.contains($0.lowercased()) }.sorted()
    }

    /// Writes the plan: one edit group of `add`s per Hours month (04:00 days, snapshot zone),
    /// each followed by a `note` group naming the source and its digest.
    public func apply(_ plan: RizeImportPlan, snap: RizeSnapshot, sourceName: String, sha256: String,
                      nowMs: Int64? = nil) throws -> Result {
        var result = Result()
        guard !plan.blocks.isEmpty else { return result }
        let config = ConfigStore(db)
        for name in try missingProjects(plan) {
            try config.insert(Project(id: 0, name: name))
            result.createdProjects.append(name)
        }
        let projectIds = Dictionary(try config.projects().map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
        let categoryIds = Set(try config.categories().map(\.id))

        let tz = snap.tz
        let byMonth = Dictionary(grouping: plan.blocks) { b -> String in
            let d = LocalDate.containing(ms: b.loMs, in: tz)
            return String(format: "%04d-%02d", d.year, d.month)
        }
        let now = nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let today = LocalDate.containing(ms: now, in: tz, dayStartHour: 0)
        let writer = EditWriter(db)
        for month in byMonth.keys.sorted() {
            let drafts = byMonth[month]!.sorted { $0.loMs < $1.loMs }.map { b in
                EditDraft.add(b.loMs, b.hiMs, label: b.label,
                              categoryId: b.categoryId.flatMap { categoryIds.contains($0) ? $0 : nil },
                              projectId: b.project.flatMap { projectIds[$0.lowercased()] })
            }
            let grp = try writer.apply(drafts, createdMs: now, tzId: tz.identifier)
            try writer.apply([.note(group: grp, text: "Imported from Rize \(sourceName) sha256:\(sha256) on \(today)")],
                             createdMs: now, tzId: tz.identifier)
            result.groups.append(grp)
            result.blocks += drafts.count
            result.ms += drafts.reduce(0) { $0 + $1.hiMs - $1.loMs }
        }
        return result
    }

    /// Edits not reverted by a live undo (undo-of-undo = redo), as in `effectiveSpans`.
    static func liveEdits(_ edits: [Edit]) -> [Edit] {
        var undone = Set<Int64>(), live: [Edit] = []
        for e in edits.sorted(by: { $0.seq > $1.seq }) where !undone.contains(e.grp) {
            if e.op == .undo, let t = e.target { undone.insert(t) } else { live.append(e) }
        }
        return live
    }
}
