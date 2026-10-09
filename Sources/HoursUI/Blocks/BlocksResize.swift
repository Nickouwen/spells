import Foundation
import CoreGraphics
import HoursCore

/// Dragging a block's top or bottom edge, as edits. Pure over `DayData` + the day's blocks; the
/// view commits the plan through `EditSession.commit` (one gesture = one group = one undo step).
/// - outward into a break: one `add` per idle / untracked sub-range of the newly covered range, so
///   active time under the drag (an excluded or private app) is never replaced. The adds carry the
///   block's dominant project and the dominant category within that project's spans, labelled with
///   the project (else category) name. Manual time replaces the idle beneath it, so the claim counts
///   as work, and as billable when there's a project;
/// - outward across the break into the neighbour: the same adds, clamped to the neighbour's edge;
/// - inward: `delete` over the trimmed range.
/// Every proposal is judged against the day regrouped with its edits applied, at the current
/// threshold: a claim leaving a break shorter than the threshold is a merge, and the extent is where
/// the block really ends up (a trim landing in idle stops at the next active edge).
/// Every range stops at the watermark (the live span isn't editable), so the live block's bottom
/// edge doesn't drag at all.
enum BlocksResize {
    static let snapMs: Int64 = 5 * 60_000
    /// A trim never shrinks a block below this.
    static let minBlockMs: Int64 = 60_000

    enum Kind: Hashable { case claim, merge, trim }

    /// Where a drag would leave the block: its regrouped extent, the range the drag covers, and the
    /// sub-ranges a claim actually fills (idle / untracked only).
    struct Proposal: Hashable {
        var extent: Range<Int64>
        var changed: Range<Int64>
        var kind: Kind
        var fills: [Range<Int64>] = []
        /// Active time inside `changed` the claim leaves alone, and its largest category.
        var skippedMs: Int64 = 0
        var skippedCategoryId: Int64? = nil

        var filledMs: Int64 { fills.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
    }

    /// What a block is called: its dominant project, else its dominant category.
    static func label(_ b: WorkBlock, _ data: DayData) -> String {
        data.projectName(b.dominantProjectId) ?? data.categoryName(b.dominantCategoryId)
    }

    /// The block holding today's open span.
    static func isLive(_ b: WorkBlock, _ data: DayData) -> Bool {
        guard data.isToday, let live = data.liveSpan?.span else { return false }
        return live.startMs >= b.startMs && live.startMs < b.endMs
    }

    static func canDrag(_ b: WorkBlock, _ edge: EditGesture.Edge, _ data: DayData) -> Bool {
        edge == .lower || !isLive(b, data)
    }

    /// Category + project a claim on `b` carries: the dominant project by active ms, then the
    /// dominant category within that project's spans (Uncategorized there → the block's dominant category).
    static func attribution(_ b: WorkBlock, _ data: DayData) -> (categoryId: Int64?, projectId: Int64?) {
        let p = b.dominantProjectId
        var order: [Int64?] = [], ms: [Int64?: Int64] = [:]
        for c in data.spans where c.span.kind == .active && c.projectId == p
            && c.span.endMs > b.startMs && c.span.startMs < b.endMs
            && data.category(c.categoryId)?.behavior != .exclude {
            let d = min(c.span.endMs, b.endMs) - max(c.span.startMs, b.startMs)
            if ms[c.categoryId] == nil { order.append(c.categoryId) }
            ms[c.categoryId, default: 0] += d
        }
        var best: Int64?, bestMs: Int64 = 0   // ties: first seen
        for k in order where ms[k, default: 0] > bestMs { best = k; bestMs = ms[k, default: 0] }
        return (best ?? b.dominantCategoryId, p)
    }

    /// The claim's label: its project, else its category.
    static func claimLabel(_ b: WorkBlock, _ data: DayData) -> String {
        let a = attribution(b, data)
        return data.projectName(a.projectId) ?? data.categoryName(a.categoryId)
    }

    static func proposal(_ b: WorkBlock, edge: EditGesture.Edge, to t: Int64, blocks: [WorkBlock],
                         data: DayData, thresholdMs: Int64) -> Proposal? {
        guard canDrag(b, edge, data), let i = blocks.firstIndex(of: b) else { return nil }
        let wm = min(data.bounds.upperBound, EditPlanner.watermark(data) ?? .max)
        let prev = i > 0 ? blocks[i - 1] : nil
        let next = i + 1 < blocks.count ? blocks[i + 1] : nil
        let changed: Range<Int64>
        let trim: Bool
        switch edge {
        case .lower where t < b.startMs:
            let lo = max(t, prev?.endMs ?? data.bounds.lowerBound, data.bounds.lowerBound)
            let hi = min(b.startMs, wm)
            guard lo < hi else { return nil }
            changed = lo..<hi; trim = false
        case .lower where t > b.startMs:
            let hi = min(t, b.endMs - minBlockMs, wm)
            guard hi > b.startMs else { return nil }
            changed = b.startMs..<hi; trim = true
        case .upper where t > b.endMs:
            let hi = min(t, next?.startMs ?? data.bounds.upperBound, wm)
            guard hi > b.endMs else { return nil }
            changed = b.endMs..<hi; trim = false
        case .upper where t < b.endMs:
            let lo = max(t, b.startMs + minBlockMs)
            let hi = min(b.endMs, wm)
            guard lo < hi else { return nil }
            changed = lo..<hi; trim = true
        default:
            return nil
        }

        var p = Proposal(extent: b.startMs..<b.endMs, changed: changed, kind: trim ? .trim : .claim)
        let drafts: [EditDraft]
        if trim {
            drafts = [.delete(changed.lowerBound, changed.upperBound)]
        } else {
            let (fills, skipped) = uncovered(changed, data)
            guard !fills.isEmpty else { return nil }   // all real time: nothing to claim
            p.fills = fills
            p.skippedMs = skipped.ms
            p.skippedCategoryId = skipped.categoryId
            let a = attribution(b, data)
            drafts = fills.map { .add($0.lowerBound, $0.upperBound, label: "", categoryId: a.categoryId, projectId: a.projectId) }
        }

        // Regroup the day as it would be, and find the block that keeps the undragged edge.
        let after = MetricsBlocks.compute(spans: simulate(data.spans, drafts), categories: data.categories,
                                          breakThresholdMs: thresholdMs)
        let anchor = edge == .lower ? b.endMs - 1 : b.startMs
        guard let nb = after.first(where: { $0.contains(anchor) }) else { return nil }
        p.extent = nb.startMs..<nb.endMs
        if !trim, (prev.map { nb.startMs < $0.endMs } ?? false) || (next.map { nb.endMs > $0.startMs } ?? false) {
            p.kind = .merge
        }
        return p
    }

    /// Sub-ranges of `r` with no active span (idle or untracked), plus the active time skipped and
    /// its largest category.
    static func uncovered(_ r: Range<Int64>, _ data: DayData) -> (fills: [Range<Int64>], skipped: (ms: Int64, categoryId: Int64?)) {
        var fills: [Range<Int64>] = []
        var cursor = r.lowerBound
        var byCat: [Int64?: Int64] = [:]
        for c in data.spans where c.span.kind == .active && c.span.endMs > r.lowerBound && c.span.startMs < r.upperBound {
            let lo = max(c.span.startMs, r.lowerBound), hi = min(c.span.endMs, r.upperBound)
            if lo > cursor { fills.append(cursor..<lo) }
            cursor = max(cursor, hi)
            byCat[c.categoryId, default: 0] += hi - lo
        }
        if cursor < r.upperBound { fills.append(cursor..<r.upperBound) }
        let top = byCat.max { $0.value != $1.value ? $0.value < $1.value : ($0.key ?? 0) > ($1.key ?? 0) }
        return (fills, (byCat.values.reduce(0, +), top?.key ?? nil))
    }

    /// `spans` with `drafts` applied the way the store does it (delete cuts; add cuts, then inserts manual time).
    static func simulate(_ spans: [ClassifiedSpan], _ drafts: [EditDraft]) -> [ClassifiedSpan] {
        var out = spans
        for d in drafts {
            out = out.flatMap { c -> [ClassifiedSpan] in
                guard c.span.startMs < d.hiMs, c.span.endMs > d.loMs else { return [c] }
                var pieces: [ClassifiedSpan] = []
                if c.span.startMs < d.loMs { var l = c; l.span.endMs = d.loMs; pieces.append(l) }
                if c.span.endMs > d.hiMs { var r = c; r.span.startMs = d.hiMs; pieces.append(r) }
                return pieces
            }
            if case let .add(label, cat, proj) = d.payload {
                let s = EffectiveSpan(startMs: d.loMs, endMs: d.hiMs, tzId: "", kind: .active, bundleId: nil, appName: "",
                                      title: nil, url: nil, categoryOverride: cat, projectOverride: proj, source: .manual,
                                      rawSeq: nil, label: label)
                out.append(ClassifiedSpan(span: s, categoryId: cat, projectId: proj))
            }
        }
        return out.sorted { $0.span.startMs < $1.span.startMs }
    }

    static func plan(_ b: WorkBlock, edge: EditGesture.Edge, to t: Int64, blocks: [WorkBlock], data: DayData,
                     thresholdMs: Int64) -> EditPlan? {
        guard let p = proposal(b, edge: edge, to: t, blocks: blocks, data: data, thresholdMs: thresholdMs) else { return nil }
        switch p.kind {
        case .trim:
            guard let r = EditPlanner.clamp(p.changed, data) else { return nil }
            return EditPlan(drafts: [.delete(r.lowerBound, r.upperBound)], actionName: "Trim Block",
                            summary: "Trimmed \(Fmt.duration(ms: r.upperBound - r.lowerBound)) from \(label(b, data))",
                            selection: [])
        case .claim, .merge:
            let fills = p.fills.compactMap { EditPlanner.clamp($0, data) }
            guard !fills.isEmpty else { return nil }
            let a = attribution(b, data), name = claimLabel(b, data)
            let d = Fmt.duration(ms: fills.reduce(0) { $0 + $1.upperBound - $1.lowerBound })
            var summary = p.kind == .merge ? "Merged blocks · filled \(d) as \(name)" : "Claimed \(d) for \(name)"
            if p.skippedMs > 0 { summary += " · skipped \(Fmt.duration(ms: p.skippedMs)) of \(data.categoryName(p.skippedCategoryId))" }
            if a.projectId == nil { summary += " (not billable — no project)" }
            return EditPlan(drafts: fills.map { .add($0.lowerBound, $0.upperBound, label: name, categoryId: a.categoryId,
                                                      projectId: a.projectId) },
                            actionName: p.kind == .merge ? "Merge Blocks" : "Extend Block", summary: summary, selection: [])
        }
    }

    /// The drag readout: `HH:mm · +25m`, `HH:mm · Merge +30m`, `HH:mm · −15m`, plus "skips N min of <category>".
    static func readout(_ p: Proposal?, edge: EditGesture.Edge, block b: WorkBlock, data: DayData) -> String {
        // Where the dragged edge lands: the regrouped edge for a trim (it can stop at the next active
        // time), the dragged-to time for a claim / merge (a merge's extent ends at the neighbour's far edge).
        let at = p.map { p in
            let r = p.kind == .trim ? p.extent : p.changed
            return edge == .lower ? r.lowerBound : r.upperBound
        } ?? (edge == .lower ? b.startMs : b.endMs)
        var text = Fmt.clock(ms: at, timeZone: data.timeZone)
        guard let p else { return text }
        switch p.kind {
        case .claim: text += " · +\(Fmt.duration(ms: p.filledMs))"
        case .merge: text += " · Merge +\(Fmt.duration(ms: p.filledMs))"
        case .trim: text += " · −\(Fmt.duration(ms: p.changed.upperBound - p.changed.lowerBound))"
        }
        if p.skippedMs > 0 {
            text += " · skips \(max(1, (p.skippedMs + 30_000) / 60_000)) min of \(data.categoryName(p.skippedCategoryId))"
        }
        return text
    }

    /// Where the drag's grip sits: the regrouped edge for a trim (it can stop at the next active time),
    /// the dragged-to time for a claim / merge; the raw drag time with no proposal.
    static func grip(_ p: Proposal?, drag d: BlocksDrag) -> Int64 {
        guard let p else { return d.ms }
        let r = p.kind == .trim ? p.extent : p.changed
        return d.edge == .lower ? r.lowerBound : r.upperBound
    }

    /// `r` with its `edge` at `ms` (a released edge settling), never shorter than 1 ms.
    static func moving(_ r: Range<Int64>, _ edge: EditGesture.Edge, to ms: Int64) -> Range<Int64> {
        edge == .lower ? min(ms, r.upperBound - 1)..<r.upperBound : r.lowerBound..<max(ms, r.lowerBound + 1)
    }

    /// The instant to keep selected after a drag commits: the middle of where the block ends up.
    static func selection(after p: Proposal?, block b: WorkBlock) -> Int64 {
        let r = p?.extent ?? b.startMs..<b.endMs
        return r.lowerBound + (r.upperBound - r.lowerBound) / 2
    }

    /// Nearest target within `toleranceMs`, else the nearest 5-minute mark in local time.
    static func snap(_ ms: Int64, targets: [Int64], toleranceMs: Int64, timeZone: TimeZone) -> Int64 {
        if let best = targets.min(by: { abs($0 - ms) < abs($1 - ms) }), abs(best - ms) <= toleranceMs { return best }
        let off = Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(ms) / 1000))) * 1000
        let local = ms + off
        let down = local - ((local % snapMs) + snapMs) % snapMs
        return (local - down < snapMs - (local - down) ? down : down + snapMs) - off
    }

    /// Snap targets for dragging `b`: the neighbouring blocks' edges, now, and the day's local hour and
    /// half-hour marks. Never `b`'s own edges (a small nudge would snap straight back).
    static func targets(_ b: WorkBlock, blocks: [WorkBlock], data: DayData) -> [Int64] {
        var t: [Int64] = []
        if let i = blocks.firstIndex(of: b) {
            if i > 0 { t += [blocks[i - 1].startMs, blocks[i - 1].endMs] }
            if i + 1 < blocks.count { t += [blocks[i + 1].startMs, blocks[i + 1].endMs] }
        }
        if let n = data.nowMs { t.append(n) }
        if let w = EditPlanner.watermark(data) { t.append(w) }
        var h = BlocksGeometry.hourFloor(data.bounds.lowerBound, data.timeZone)
        while h <= data.bounds.upperBound { t += [h, h + 1_800_000]; h += 3_600_000 }
        return t.filter { $0 != b.startMs && $0 != b.endMs }
    }
}

/// Auto-scroll while an edge drag nears the top or bottom of the page's scroll view.
enum BlocksAutoScroll {
    /// Distance from a visible edge where scrolling starts.
    static let zone: CGFloat = 40
    /// Points per tick at (or past) the edge.
    static let maxStep: CGFloat = 18

    /// Points to scroll this tick (negative = up) for a pointer `top`/`bottom` points from the
    /// visible edges: 0 outside the zone, growing linearly to `maxStep` at the edge.
    static func delta(top: CGFloat, bottom: CGFloat) -> CGFloat {
        if top < zone, top <= bottom { return -maxStep * min(1, (zone - top) / zone) }
        if bottom < zone { return maxStep * min(1, (zone - bottom) / zone) }
        return 0
    }
}
