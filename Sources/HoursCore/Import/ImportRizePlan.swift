import Foundation

/// One manual `add` to write: a run of contiguous Rize events with the same label, category and project.
public struct RizeBlock: Sendable, Hashable {
    public var loMs: Int64
    public var hiMs: Int64
    /// "Rize · <site host or app name>".
    public var label: String
    public var categoryId: Int64?
    /// Rize's category key (nil = no category found for this app/site).
    public var rizeCategory: String?
    public var project: String?
    public var durationMs: Int64 { hiMs - loMs }
}

/// What an import would do. Pure output of `RizeImportPlanner.plan`; the dry run prints it.
public struct RizeImportPlan: Sendable {
    public var blocks: [RizeBlock]
    public var events = 0
    /// Contiguous same-label runs considered (after `--since`), before clipping.
    public var sourceBlocks = 0
    public var sourceMs: Int64 = 0
    public var idleMs: Int64 = 0
    public var alreadyImportedBlocks = 0, alreadyImportedMs: Int64 = 0
    public var overlapBlocks = 0, overlapMs: Int64 = 0
    /// Blocks that survive only in part (some of their time was already imported or tracked).
    public var clippedBlocks = 0
    /// Rize category name by key, for display.
    public var rizeCategoryNames: [String: String] = [:]
    /// Per Rize summary day: (date, event time inside Rize's bucket, Rize's trackedTime) in ms.
    public var daily: [(date: String, eventsMs: Int64, rizeMs: Int64)] = []

    public var totalMs: Int64 { blocks.reduce(0) { $0 + $1.durationMs } }
}

public enum RizeImportPlanner {
    static let labelPrefix = "Rize · "

    /// - Parameters:
    ///   - alreadyImported: ranges of earlier Rize imports in the store (live adds labelled "Rize · ").
    ///   - tracked: everything else Hours already has — raw spans, other manual adds, [live span start, ∞).
    ///   Both may be unsorted/overlapping. Imported time never overlaps either.
    public static func plan(_ snap: RizeSnapshot, since: LocalDate? = nil,
                            alreadyImported: [Range<Int64>] = [], tracked: [Range<Int64>] = [],
                            dayStartHour: Int = Hours.defaultDayStartHour) throws -> RizeImportPlan {
        let tz = snap.tz
        var plan = RizeImportPlan(blocks: [])
        plan.events = snap.events.count

        // Category per (Rize day, site host | app name): the largest appsAndWebsites row wins; any-day fallback.
        var byDay: [String: [String: (RizeCategory, Int)]] = [:], anyDay: [String: (RizeCategory, Int)] = [:]
        for (date, rows) in snap.appsAndWebsites {
            for r in rows {
                let k = r.urlHost.flatMap(host).map { "w|" + $0 } ?? r.appName.map { "a|" + $0 }
                guard let k else { continue }
                if (byDay[date]?[k]?.1 ?? -1) < r.timeSpent { byDay[date, default: [:]][k] = (r.timeCategory, r.timeSpent) }
                if (anyDay[k]?.1 ?? -1) < r.timeSpent { anyDay[k] = (r.timeCategory, r.timeSpent) }
            }
        }

        // Events → labelled pieces. Site events beat the browser's app event over the same time;
        // within each kind, the earlier-starting event keeps any overlap.
        struct Piece { var lo, hi: Int64; var label: String; var cat: RizeCategory? }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        func rizeDay(_ ms: Int64) -> String {   // Rize days are local midnight to midnight
            let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(ms) / 1000))
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        var sites: [Piece] = [], apps: [Piece] = []
        for e in snap.events {
            let lo = try rizeMs(e.startTime), hi = try rizeMs(e.endTime)
            guard hi > lo else { continue }
            let h = e.urlHost.flatMap(host)
            let app = e.appName.flatMap { $0.isEmpty ? nil : $0 }
            let k = h.map { "w|" + $0 } ?? app.map { "a|" + $0 }
            let cat = k.flatMap { k in byDay[rizeDay(lo)]?[k]?.0 ?? anyDay[k]?.0 }
            let p = Piece(lo: lo, hi: hi, label: labelPrefix + (h ?? app ?? "unknown"), cat: cat)
            if h != nil { sites.append(p) } else { apps.append(p) }
        }
        func flatten(_ ps: [Piece]) -> [Piece] {
            var cursor = Int64.min
            return ps.sorted { $0.lo < $1.lo }.compactMap { p in
                defer { cursor = max(cursor, p.hi) }
                var q = p
                q.lo = max(q.lo, cursor)
                return q.hi > q.lo ? q : nil
            }
        }
        let siteFlat = flatten(sites)
        let siteCover = importMerge(siteFlat.map { $0.lo..<$0.hi })
        var pieces = siteFlat
        for p in flatten(apps) {
            for r in importSubtract(p.lo..<p.hi, siteCover) { var q = p; q.lo = r.lowerBound; q.hi = r.upperBound; pieces.append(q) }
        }
        pieces.sort { $0.lo < $1.lo }

        // Idle categories are not tracked time.
        pieces = pieces.filter { p in
            if p.cat?.idle == true { plan.idleMs += p.hi - p.lo; return false }
            return true
        }

        // Cross-check against Rize's own day totals, before --since and clipping.
        let cover = importMerge(pieces.map { $0.lo..<$0.hi })
        for b in snap.summaryBuckets.sorted(by: { $0.date < $1.date }) {
            let lo = try rizeMs(b.startTime), hi = try rizeMs(b.endTime)
            plan.daily.append((b.date, importOverlap(lo..<hi, cover), Int64(b.trackedTime) * 1000))
        }

        // Project = the Rize time entry covering the piece's midpoint.
        let entries = try snap.timeEntries.compactMap { t -> (Range<Int64>, String)? in
            guard let name = t.project?.name, !name.isEmpty else { return nil }
            let lo = try rizeMs(t.startTime), hi = try rizeMs(t.endTime)
            return hi > lo ? (lo..<hi, name) : nil
        }
        func project(_ lo: Int64, _ hi: Int64) -> String? {
            let mid = lo + (hi - lo) / 2
            return entries.first { $0.0.contains(mid) }?.1
        }

        // --since (Hours day boundary), then merge contiguous runs into blocks.
        let floor = since?.dayInterval(in: tz, dayStartHour: dayStartHour).lowerBound ?? .min
        var blocks: [RizeBlock] = []
        for p in pieces where p.hi > floor {
            let lo = max(p.lo, floor)
            let cat = p.cat.map { RizeCategoryMap.map($0.key).categoryId } ?? nil
            if let c = p.cat { plan.rizeCategoryNames[c.key] = c.name }
            let b = RizeBlock(loMs: lo, hiMs: p.hi, label: p.label, categoryId: cat, rizeCategory: p.cat?.key,
                              project: project(lo, p.hi))
            if var last = blocks.last, last.hiMs == b.loMs, last.label == b.label,
               last.rizeCategory == b.rizeCategory, last.project == b.project {
                last.hiMs = b.hiMs
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(b)
            }
        }
        plan.sourceBlocks = blocks.count
        plan.sourceMs = blocks.reduce(0) { $0 + $1.durationMs }

        // Clip: earlier imports first (so a re-run reports them as such), then Hours-tracked time.
        let done = importMerge(alreadyImported), seen = importMerge(tracked)
        for b in blocks {
            let afterDone = importSubtract(b.loMs..<b.hiMs, done)
            let doneMs = b.durationMs - afterDone.reduce(Int64(0)) { $0 + $1.upperBound - $1.lowerBound }
            var left: [Range<Int64>] = []
            for r in afterDone { left += importSubtract(r, seen) }
            let leftMs = left.reduce(Int64(0)) { $0 + $1.upperBound - $1.lowerBound }
            plan.alreadyImportedMs += doneMs
            plan.overlapMs += b.durationMs - doneMs - leftMs
            if left.isEmpty {
                if afterDone.isEmpty { plan.alreadyImportedBlocks += 1 } else { plan.overlapBlocks += 1 }
                continue
            }
            if leftMs < b.durationMs { plan.clippedBlocks += 1 }
            for r in left { var c = b; c.loMs = r.lowerBound; c.hiMs = r.upperBound; plan.blocks.append(c) }
        }
        return plan
    }

    static func host(_ h: String) -> String? {
        let n = ClassifyURL.normalizeHost(h)
        return n.isEmpty ? nil : n
    }
}

// MARK: - Interval sets (half-open, ms)

/// Sorted, disjoint, adjacent ranges merged.
func importMerge(_ xs: [Range<Int64>]) -> [Range<Int64>] {
    var out: [Range<Int64>] = []
    for r in xs.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
        if let last = out.last, r.lowerBound <= last.upperBound {
            out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
        } else {
            out.append(r)
        }
    }
    return out
}

/// `r` minus a merged set.
func importSubtract(_ r: Range<Int64>, _ merged: [Range<Int64>]) -> [Range<Int64>] {
    var out: [Range<Int64>] = []
    var lo = r.lowerBound
    var i = importFirst(merged, after: lo)
    while i < merged.count, merged[i].lowerBound < r.upperBound {
        if merged[i].lowerBound > lo { out.append(lo..<merged[i].lowerBound) }
        lo = max(lo, merged[i].upperBound)
        i += 1
    }
    if lo < r.upperBound { out.append(lo..<r.upperBound) }
    return out
}

/// Total ms of a merged set inside `r`.
func importOverlap(_ r: Range<Int64>, _ merged: [Range<Int64>]) -> Int64 {
    var total: Int64 = 0
    var i = importFirst(merged, after: r.lowerBound)
    while i < merged.count, merged[i].lowerBound < r.upperBound {
        total += min(merged[i].upperBound, r.upperBound) - max(merged[i].lowerBound, r.lowerBound)
        i += 1
    }
    return total
}

/// Index of the first range ending after `ms`.
private func importFirst(_ merged: [Range<Int64>], after ms: Int64) -> Int {
    var lo = 0, hi = merged.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if merged[mid].upperBound <= ms { lo = mid + 1 } else { hi = mid }
    }
    return lo
}
