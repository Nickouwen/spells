import Foundation
import HoursCore

/// Keyboard, menu and detail-panel actions on one block, as edit plans (one group = one undo step
/// each). Pure over `DayData`; the view commits through `EditSession.commit`.
enum BlocksActions {
    static let nudgeMs: Int64 = 5 * 60_000

    /// ⌘⌥↑/↓ moves the top edge, ⌘⌥⇧↑/↓ the bottom edge, 5 min per press (`earlier` = ↑). Same
    /// edits as dragging the edge there (claim / merge / trim), without snapping.
    static func nudge(_ b: WorkBlock, edge: EditGesture.Edge, earlier: Bool, blocks: [WorkBlock], data: DayData,
                      thresholdMs: Int64) -> EditPlan? {
        let from = edge == .lower ? b.startMs : b.endMs
        return BlocksResize.plan(b, edge: edge, to: from + (earlier ? -nudgeMs : nudgeMs), blocks: blocks, data: data,
                                 thresholdMs: thresholdMs)
    }

    /// The range a split at `t` deletes: exactly one threshold long (a gap that long always breaks a
    /// block), centred on `t`, shifted inward so at least 1 min of the block survives on each side
    /// and nothing past the watermark is touched. nil when the block is shorter than threshold + 2 min.
    static func splitGap(_ b: WorkBlock, at t: Int64, data: DayData, thresholdMs: Int64) -> Range<Int64>? {
        let keep = BlocksResize.minBlockMs
        let lo0 = max(b.startMs + keep, t - thresholdMs / 2)
        let hi = min(lo0 + thresholdMs, b.endMs - keep, EditPlanner.watermark(data) ?? .max)
        let lo = hi - thresholdMs
        guard lo >= b.startMs + keep, b.contains(t) else { return nil }
        return lo..<hi
    }

    /// Split at the pointer (S / "Split Here"): one `delete` of `splitGap`, so the halves regroup as
    /// two blocks either side of a break. The deleted minutes are gone (undo restores them).
    static func split(_ b: WorkBlock, at t: Int64, data: DayData, thresholdMs: Int64) -> EditPlan? {
        guard let g = splitGap(b, at: t, data: data, thresholdMs: thresholdMs) else { return nil }
        let mid = g.lowerBound + (g.upperBound - g.lowerBound) / 2
        return EditPlan(drafts: [.delete(g.lowerBound, g.upperBound)], actionName: "Split Block",
                        summary: "Split \(BlocksResize.label(b, data)) at \(Fmt.clock(ms: mid, timeZone: data.timeZone))"
                            + " · removed \(Fmt.duration(ms: g.upperBound - g.lowerBound))",
                        selection: [])
    }

    /// The project chip: one `assign` (project only) over the whole block, up to the watermark. The
    /// toast's "Always for …" offers a rule for the block's longest tracked span.
    static func assignProject(_ b: WorkBlock, _ projectId: Int64, data: DayData) -> EditPlan? {
        guard let r = EditPlanner.clamp(b.startMs..<b.endMs, data) else { return nil }
        return EditPlan(drafts: [.assign(r.lowerBound, r.upperBound, categoryId: nil, projectId: projectId)],
                        actionName: "Assign Project",
                        summary: "Assigned \(Fmt.duration(ms: EditPlanner.trackedMs([r], data))) to \(data.projectName(projectId) ?? "project")",
                        selection: [], ruleSource: EditPlanner.dominant([r], data), ruleCategoryId: nil,
                        ruleProjectId: projectId)
    }

    /// "Always for these apps": one rule per top app / site of the block (host rule for a site,
    /// else app rule), drafted by `ClassifyRuleSuggester` from that context's longest tracked span.
    static func rules(_ b: WorkBlock, projectId: Int64, data: DayData) -> [(name: String, rule: Rule)] {
        b.topContexts.compactMap { ctx -> (name: String, rule: Rule)? in
            let spans = data.spans.filter { c in
                let s = c.span
                guard s.kind == .active, s.source == .tracked, s.endMs > b.startMs, s.startMs < b.endMs else { return false }
                return ctx.isHost ? DayRows.host(s.url) == ctx.name : DayRows.host(s.url) == nil && s.appName == ctx.name
            }
            guard let s = spans.max(by: { $0.span.durationMs < $1.span.durationMs })?.span else { return nil }
            return ClassifyRuleSuggester.rule(from: s, field: ctx.isHost ? .host : .app, projectId: projectId)
                .map { (ctx.name, $0) }
        }
    }

    /// "Xcode, github.com": the apps `rules` covers (manual entries have none); nil when there are none.
    static func ruleLabel(_ b: WorkBlock, data: DayData) -> String? {
        let names = rules(b, projectId: 0, data: data).map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
}
