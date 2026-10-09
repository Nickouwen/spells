import Foundation
import HoursCore

/// One user gesture on the Day timeline. Each writes exactly one edit group (one undo step).
/// Split isn't here: it writes nothing (it only cuts the selection, see `EditSelection.split`).
public enum EditGesture: Sendable, Hashable {
    public enum Edge: Sendable, Hashable { case lower, upper }
    /// Drag an edge of the (single) selected range: inward = trim, outward over a gap = extend,
    /// outward over a touching neighbour = move the shared boundary.
    case resize(Edge, to: Int64)
    /// Drag the boundary between two touching segments from one instant to another.
    case moveBoundary(from: Int64, to: Int64)
    /// Earlier segment's attributes over the later ones; gaps ≤ 10 min between them are filled.
    case merge
    case recategorize(Int64)
    case assignProject(Int64)
    case markPersonal
    case delete
    /// Manual time; replaces tracked time beneath it (PLAN Q11).
    case add(Range<Int64>, label: String, categoryId: Int64?, projectId: Int64?)
}

/// What a gesture writes, and how the UI reports it.
public struct EditPlan: Sendable, Hashable {
    public var drafts: [EditDraft]
    /// Undo menu name ("Undo Recategorize").
    public var actionName: String
    /// Toast text ("Recategorized 1h 12m to Coding").
    public var summary: String
    /// Selection after commit (kept so ops chain: drag, then C).
    public var selection: [Range<Int64>]
    /// The longest tracked span under an assign, for "Always for …" (rule handoff to item 4).
    public var ruleSource: EffectiveSpan?
    public var ruleCategoryId: Int64?
    public var ruleProjectId: Int64?
}

/// Gesture → `[EditDraft]`. Pure over `DayData`; every range is clamped to the day and to the
/// watermark (live span start / now), so nothing is ever written over the open span.
public enum EditPlanner {
    /// Merge fills gaps up to this (PLAN Q11).
    public static let mergeGapMs: Int64 = 10 * 60_000
    /// Segments never shrink below this.
    public static let minSegmentMs: Int64 = 1_000
    /// Neighbours closer than this count as touching (matches the timeline's "not tracking" threshold).
    static let touchMs: Int64 = DayTimeline.minGapMs

    /// End of editable time: the live span's start, else "now" on today, else nil (past day).
    public static func watermark(_ data: DayData) -> Int64? {
        data.liveSpan?.span.startMs ?? data.nowMs
    }

    /// `r` limited to the day and the watermark; nil when nothing editable is left.
    public static func clamp(_ r: Range<Int64>, _ data: DayData) -> Range<Int64>? {
        let lo = max(r.lowerBound, data.bounds.lowerBound)
        let hi = min(r.upperBound, data.bounds.upperBound, watermark(data) ?? .max)
        return hi > lo ? lo..<hi : nil
    }

    public static func plan(_ g: EditGesture, selection: [Range<Int64>], in data: DayData) -> EditPlan? {
        let ranges = selection.compactMap { clamp($0, data) }
        switch g {
        case let .resize(edge, t): return resize(edge, to: t, selection: ranges, data)
        case let .moveBoundary(t0, t1): return moveBoundary(from: t0, to: t1, selection: selection, data)
        case .merge: return merge(selection: ranges, data)
        case let .recategorize(c):
            return assign(ranges, categoryId: c, projectId: nil, data, name: "Recategorize",
                          verb: "Recategorized", to: " to \(data.categoryName(c))")
        case let .assignProject(p):
            return assign(ranges, categoryId: nil, projectId: p, data, name: "Assign Project",
                          verb: "Assigned", to: " to \(data.projectName(p) ?? "project")")
        case .markPersonal:
            return assign(ranges, categoryId: personalId(data), projectId: nil, data, name: "Mark Personal",
                          verb: "Marked", to: " personal")
        case .delete:
            guard !ranges.isEmpty else { return nil }
            let summary = ranges.count == 1
                ? "Deleted \(clock(ranges[0].lowerBound, data))–\(clock(ranges[0].upperBound, data))"
                : "Deleted \(ranges.count) ranges · \(Fmt.duration(ms: trackedMs(ranges, data)))"
            return EditPlan(drafts: ranges.map { .delete($0.lowerBound, $0.upperBound) }, actionName: "Delete",
                            summary: summary, selection: [])
        case let .add(r, label, c, p):
            guard let r = clamp(r, data) else { return nil }
            let label = label.trimmingCharacters(in: .whitespaces).isEmpty ? "Manual entry" : label
            let replaced = trackedMs([r], data)
            var summary = "Added \(Fmt.duration(ms: r.upperBound - r.lowerBound)) · \(label)"
            if replaced > 0 { summary += " · replaced \(Fmt.duration(ms: replaced)) tracked" }
            return EditPlan(drafts: [.add(r.lowerBound, r.upperBound, label: label, categoryId: c, projectId: p)],
                            actionName: "Add Entry", summary: summary, selection: [r])
        }
    }

    // MARK: Gestures

    private static func assign(_ ranges: [Range<Int64>], categoryId: Int64?, projectId: Int64?, _ data: DayData,
                               name: String, verb: String, to: String) -> EditPlan? {
        guard !ranges.isEmpty else { return nil }
        let drafts = ranges.map { EditDraft.assign($0.lowerBound, $0.upperBound, categoryId: categoryId, projectId: projectId) }
        return EditPlan(drafts: drafts, actionName: name,
                        summary: "\(verb) \(Fmt.duration(ms: trackedMs(ranges, data)))\(to)", selection: ranges,
                        ruleSource: dominant(ranges, data), ruleCategoryId: categoryId, ruleProjectId: projectId)
    }

    private static func resize(_ edge: EditGesture.Edge, to t: Int64, selection: [Range<Int64>], _ data: DayData) -> EditPlan? {
        guard selection.count == 1, let sel = selection.first else { return nil }
        let inside = spans(in: sel, data)
        guard let seg = edge == .upper ? inside.last : inside.first else { return nil }
        let old = edge == .upper ? sel.upperBound : sel.lowerBound
        // Only an edge that sits on a segment edge resizes; an edge mid-segment just moves the selection.
        guard abs((edge == .upper ? seg.span.endMs : seg.span.startMs) - old) < minSegmentMs else { return nil }
        let wm = min(data.bounds.upperBound, watermark(data) ?? .max)

        // Inward: trim (delete what the edge uncovers).
        if edge == .upper, t < old {
            let t = max(t, sel.lowerBound + minSegmentMs)
            guard t < old else { return nil }
            return EditPlan(drafts: [.delete(t, old)], actionName: "Trim",
                            summary: "Trimmed \(Fmt.duration(ms: old - t))", selection: [sel.lowerBound..<t])
        }
        if edge == .lower, t > old {
            let t = min(t, sel.upperBound - minSegmentMs)
            guard t > old else { return nil }
            return EditPlan(drafts: [.delete(old, t)], actionName: "Trim",
                            summary: "Trimmed \(Fmt.duration(ms: t - old))", selection: [t..<sel.upperBound])
        }

        // Outward.
        let all = data.spans.map(\.span)
        if edge == .upper {
            guard t > old, old < wm else { return nil }
            let next = all.first { $0.startMs >= seg.span.endMs }
            if let next, next.startMs - old < touchMs {
                let hi = min(t, next.endMs, wm)
                guard hi > old else { return nil }   // never build an inverted Range (it traps)
                return boundary(old..<hi, attrsOf: seg, data, selection: [sel.lowerBound..<hi])
            }
            let hi = min(t, next?.startMs ?? .max, wm)
            return extend(old..<hi, from: seg, data, selection: [sel.lowerBound..<hi])
        } else {
            guard t < old else { return nil }
            let prev = all.last { $0.endMs <= seg.span.startMs }
            if let prev, old - prev.endMs < touchMs {
                let lo = max(t, prev.startMs, data.bounds.lowerBound)
                guard lo < old else { return nil }
                return boundary(lo..<old, attrsOf: seg, data, selection: [lo..<sel.upperBound])
            }
            let lo = max(t, prev?.endMs ?? .min, data.bounds.lowerBound)
            return extend(lo..<old, from: seg, data, selection: [lo..<sel.upperBound])
        }
    }

    private static func moveBoundary(from t0: Int64, to t1: Int64, selection: [Range<Int64>], _ data: DayData) -> EditPlan? {
        let all = data.spans
        guard t1 != t0,
              let a = all.last(where: { abs($0.span.endMs - t0) < touchMs && $0.span.startMs < t0 }),
              let c = all.first(where: { abs($0.span.startMs - t0) < touchMs && $0.span.endMs > t0 }) else { return nil }
        let wm = min(data.bounds.upperBound, watermark(data) ?? .max)
        guard c.span.endMs <= wm else { return nil }   // the live span's start isn't a movable boundary
        // A neighbour already under minSegmentMs (sub-second) can't shrink: nothing to move.
        if t1 > t0 {
            let hi = min(t1, c.span.endMs - minSegmentMs)
            guard hi > t0 else { return nil }
            return boundary(t0..<hi, attrsOf: a, data, selection: selection)
        }
        let lo = max(t1, a.span.startMs + minSegmentMs)
        guard lo < t0 else { return nil }
        return boundary(lo..<t0, attrsOf: c, data, selection: selection)
    }

    /// The moved piece takes `seg`'s category and project.
    // ponytail: an Uncategorized / project-less side can't be painted over the other — assign's nil
    // means "leave untouched" in the contract, there's no "clear". Needs a store verb to lift.
    private static func boundary(_ r: Range<Int64>, attrsOf seg: ClassifiedSpan, _ data: DayData,
                                 selection: [Range<Int64>]) -> EditPlan? {
        guard r.upperBound > r.lowerBound, seg.categoryId != nil || seg.projectId != nil else { return nil }
        return EditPlan(drafts: [.assign(r.lowerBound, r.upperBound, categoryId: seg.categoryId, projectId: seg.projectId)],
                        actionName: "Move Boundary",
                        summary: "Moved \(Fmt.duration(ms: r.upperBound - r.lowerBound)) to \(name(seg, data))",
                        selection: selection)
    }

    private static func extend(_ r: Range<Int64>, from seg: ClassifiedSpan, _ data: DayData,
                               selection: [Range<Int64>]) -> EditPlan? {
        guard r.upperBound > r.lowerBound else { return nil }
        return EditPlan(drafts: [.add(r.lowerBound, r.upperBound, label: "\(name(seg, data)) (extended)",
                                      categoryId: seg.categoryId, projectId: seg.projectId)],
                        actionName: "Extend", summary: "Extended \(name(seg, data)) by \(Fmt.duration(ms: r.upperBound - r.lowerBound))",
                        selection: selection)
    }

    /// Spans under the selection hull: the first one's category/project over the rest (one assign),
    /// plus a manual fill over each gap ≤ 10 min between them.
    private static func merge(selection: [Range<Int64>], _ data: DayData) -> EditPlan? {
        guard let lo = selection.first?.lowerBound, let hi = selection.last?.upperBound else { return nil }
        let segs = spans(in: lo..<hi, data).filter { $0.span.kind == .active }
        guard segs.count >= 2, let first = segs.first, let last = segs.last else { return nil }
        let wm = min(data.bounds.upperBound, watermark(data) ?? .max)
        var drafts: [EditDraft] = []
        let differs = segs.dropFirst().contains { $0.categoryId != first.categoryId || $0.projectId != first.projectId }
        if differs, first.categoryId != nil || first.projectId != nil {
            drafts.append(.assign(first.span.endMs, min(last.span.endMs, wm), categoryId: first.categoryId, projectId: first.projectId))
        }
        var filled: Int64 = 0
        for (a, b) in zip(segs, segs.dropFirst()) where b.span.startMs > a.span.endMs
            && b.span.startMs - a.span.endMs <= mergeGapMs && b.span.startMs <= wm {
            drafts.append(.add(a.span.endMs, b.span.startMs, label: name(first, data),
                               categoryId: first.categoryId, projectId: first.projectId))
            filled += b.span.startMs - a.span.endMs
        }
        guard !drafts.isEmpty else { return nil }
        var summary = "Merged \(segs.count) segments into \(name(first, data))"
        if filled > 0 { summary += " · filled \(Fmt.duration(ms: filled))" }
        return EditPlan(drafts: drafts, actionName: "Merge", summary: summary,
                        selection: [first.span.startMs..<min(last.span.endMs, wm)])
    }

    // MARK: Helpers

    /// Spans overlapping `r`, in order.
    static func spans(in r: Range<Int64>, _ data: DayData) -> [ClassifiedSpan] {
        data.spans.filter { $0.span.startMs < r.upperBound && $0.span.endMs > r.lowerBound }
    }

    /// Active (non-idle) time under the ranges.
    static func trackedMs(_ ranges: [Range<Int64>], _ data: DayData) -> Int64 {
        ranges.reduce(0) { sum, r in
            sum + spans(in: r, data).filter { $0.span.kind == .active }.reduce(0) {
                $0 + min($1.span.endMs, r.upperBound) - max($1.span.startMs, r.lowerBound)
            }
        }
    }

    /// Longest tracked active span (by overlap) under the ranges.
    static func dominant(_ ranges: [Range<Int64>], _ data: DayData) -> EffectiveSpan? {
        var best: (EffectiveSpan, Int64)?
        for r in ranges {
            for c in spans(in: r, data) where c.span.kind == .active && c.span.source == .tracked {
                let d = min(c.span.endMs, r.upperBound) - max(c.span.startMs, r.lowerBound)
                if d > (best?.1 ?? 0) { best = (c.span, d) }
            }
        }
        return best?.0
    }

    static func personalId(_ data: DayData) -> Int64 {
        data.categories.first { $0.key == "personal" }?.id ?? ClassifySeed.personal
    }

    /// What a segment is called in summaries: its category, else app / label.
    static func name(_ c: ClassifiedSpan, _ data: DayData) -> String {
        if c.categoryId != nil { return data.categoryName(c.categoryId) }
        if c.span.source == .manual { return c.span.label ?? "Manual entry" }
        return c.span.appName
    }

    static func clock(_ ms: Int64, _ data: DayData) -> String { Fmt.clock(ms: ms, timeZone: data.timeZone) }
}
