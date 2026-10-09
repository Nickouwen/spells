import Foundation
import CoreGraphics
import Testing
import HoursCore
@testable import HoursUI

/// One test per review finding (`plan/tasks/out/review-blocks.md` 1–7). Each failed before its fix.
/// Fixtures are UTC, Thu 1 Oct 2026, applied through a temp store like `BlocksResizeTests`.
@Suite(.serialized) @MainActor struct BlocksFixesTests {
    typealias R = BlocksResizeTests
    typealias Scene = BlocksResizeTests.Scene
    static func at(_ h: Int, _ m: Int = 0) -> Int64 { R.at(h, m) }
    static let xcode = "com.apple.dt.Xcode", slack = "com.tinyspeck.slackmacgap"

    // 1. A claim never overwrites active time beneath it.
    /// Block A 09:00–10:20, then idle 10:20–10:30, the login window (Excluded, active) 10:30–10:40,
    /// idle 10:40–11:00, block B from 11:00.
    static var excludedInBreak: [RawSpan] {
        [R.raw(at(9), at(10, 20), "Xcode", bundle: xcode, title: "route.ts — operations-dashboard"),
         R.raw(at(10, 20), at(10, 30), "Xcode", bundle: xcode, kind: .idle),
         R.raw(at(10, 30), at(10, 40), "loginwindow", bundle: "com.apple.loginwindow"),
         R.raw(at(10, 40), at(11), "Xcode", bundle: xcode, kind: .idle),
         R.raw(at(11), at(12), "Xcode", bundle: xcode, title: "ingest.py — client-monitoring")]
    }

    @Test func claimSkipsActiveTimeUnderTheDrag() throws {
        let s = try Scene(raw: Self.excludedInBreak)
        let p = try #require(BlocksResize.proposal(s.blocks[0], edge: .upper, to: Self.at(10, 50), blocks: s.blocks,
                                                   data: s.data, thresholdMs: R.threshold))
        #expect(BlocksResize.readout(p, edge: .upper, block: s.blocks[0], data: s.data).contains("skips 10 min of Excluded"))
        let label = "operations-dashboard"
        let drafts = try s.drag(0, .upper, to: Self.at(10, 50))
        #expect(drafts == [.add(Self.at(10, 20), Self.at(10, 30), label: label, categoryId: ClassifySeed.coding, projectId: R.dashboard),
                           .add(Self.at(10, 40), Self.at(10, 50), label: label, categoryId: ClassifySeed.coding, projectId: R.dashboard)])
        // The excluded span is still there, untouched.
        #expect(s.data.spans.contains { $0.span.startMs == Self.at(10, 30) && $0.span.endMs == Self.at(10, 40)
            && $0.categoryId == ClassifySeed.excluded && $0.span.source == .tracked })
        #expect(s.undo.canUndo)
        s.undo.undo()
        try s.refresh()
        #expect(s.data.spans.filter { $0.span.source == .manual }.isEmpty)
    }

    // 2. A claim that leaves a break under the threshold is a merge.
    @Test func claimLeavingShortBreakIsAMerge() throws {
        let s = try Scene()
        // B 11:00–12:00, not tracking 12:00–12:30, C from 12:30. Leave 5 min (< 10 min threshold).
        let p = try #require(BlocksResize.proposal(s.blocks[1], edge: .upper, to: Self.at(12, 25), blocks: s.blocks,
                                                   data: s.data, thresholdMs: R.threshold))
        #expect(p.kind == .merge)
        #expect(p.extent == Self.at(11)..<Self.at(13))
        // The readout's time is where the dragged edge is, not the merged block's far end.
        #expect(BlocksResize.readout(p, edge: .upper, block: s.blocks[1], data: s.data) == "12:25 · Merge +25m")
        let plan = try #require(s.plan(1, .upper, to: Self.at(12, 25)))
        #expect(plan.summary.hasPrefix("Merged"))
        #expect(plan.actionName == "Merge Blocks")
        try s.apply(plan)
        #expect(R.extents(s) == [Self.at(9)..<Self.at(10, 20), Self.at(11)..<Self.at(13)])
    }

    // 3. The trimmed block stays selected.
    @Test func trimKeepsSelection() throws {
        let s = try Scene()
        let b = s.blocks[0]   // 09:00–10:20; old midpoint 09:40
        let p = try #require(BlocksResize.proposal(b, edge: .lower, to: Self.at(9, 50), blocks: s.blocks, data: s.data,
                                                   thresholdMs: R.threshold))
        let sel = BlocksResize.selection(after: p, block: b)
        _ = try s.drag(0, .lower, to: Self.at(9, 50))
        let selected = try #require(s.blocks.first { $0.contains(sel) })
        #expect(selected.startMs == Self.at(9, 50) && selected.endMs == Self.at(10, 20))
    }

    // 4. Small nudges aren't snapped back to the block's own edge.
    @Test func smallNudgeIsNotSwallowed() throws {
        let s = try Scene()
        let b = s.blocks[1]   // starts 11:00
        let targets = BlocksResize.targets(b, blocks: s.blocks, data: s.data)
        // 6 px at 60 px/h = 6 min of tolerance: 11:04 used to snap back to 11:00.
        #expect(BlocksResize.snap(Self.at(11, 4), targets: targets, toleranceMs: 6 * 60_000, timeZone: s.data.timeZone)
                == Self.at(11, 5))
    }

    // 5. A trim landing inside idle shows the real resulting edge.
    /// Xcode 09:00–09:40, idle 09:40–09:45, Xcode 09:45–10:20 (one block), then B.
    static var idleInsideBlock: [RawSpan] {
        [R.raw(at(9), at(9, 40), "Xcode", bundle: xcode, title: "route.ts — operations-dashboard"),
         R.raw(at(9, 40), at(9, 45), "Xcode", bundle: xcode, kind: .idle),
         R.raw(at(9, 45), at(10, 20), "Xcode", bundle: xcode, title: "route.ts — operations-dashboard"),
         R.raw(at(11), at(12), "Xcode", bundle: xcode, title: "ingest.py — client-monitoring")]
    }

    @Test func trimIntoIdleShowsRealEdge() throws {
        let s = try Scene(raw: Self.idleInsideBlock)
        #expect(s.blocks[0].startMs == Self.at(9) && s.blocks[0].endMs == Self.at(10, 20))
        let p = try #require(BlocksResize.proposal(s.blocks[0], edge: .lower, to: Self.at(9, 42), blocks: s.blocks,
                                                   data: s.data, thresholdMs: R.threshold))
        #expect(p.extent == Self.at(9, 45)..<Self.at(10, 20))
        _ = try s.drag(0, .lower, to: Self.at(9, 42))
        #expect(R.extents(s).first == p.extent)
        // The bottom edge, symmetric: trimming to 09:43 leaves the block ending at 09:40.
        let s2 = try Scene(raw: Self.idleInsideBlock)
        let p2 = try #require(BlocksResize.proposal(s2.blocks[0], edge: .upper, to: Self.at(9, 43), blocks: s2.blocks,
                                                    data: s2.data, thresholdMs: R.threshold))
        #expect(p2.extent == Self.at(9)..<Self.at(9, 40))
    }

    // 6. Category and project come from the same spans; project-less claims say so.
    /// One block: Coding·clientalpha 25m, Coding·dashboard 20m, Communication·clientalpha 30m. Dominant
    /// project clientalpha (55m); dominant category overall Coding (45m), but within clientalpha it's
    /// Communication (30m). Then a break and a second block.
    static var mixedBlock: [RawSpan] {
        [R.raw(at(9), at(9, 25), "Xcode", bundle: xcode, title: "ingest.py — client-monitoring"),
         R.raw(at(9, 25), at(9, 45), "Xcode", bundle: xcode, title: "route.ts — operations-dashboard"),
         R.raw(at(9, 45), at(10, 15), "Slack", bundle: slack, title: "#client-monitoring"),
         R.raw(at(10, 15), at(10, 45), "Slack", bundle: slack, kind: .idle),
         R.raw(at(10, 45), at(11, 30), "Xcode", bundle: xcode, title: "ingest.py — client-monitoring")]
    }

    @Test func claimAttributesCategoryWithinDominantProject() throws {
        let s = try Scene(raw: Self.mixedBlock)
        #expect(s.blocks[0].dominantProjectId == R.clientalpha && s.blocks[0].dominantCategoryId == ClassifySeed.coding)
        let drafts = try s.drag(0, .upper, to: Self.at(10, 25))
        #expect(drafts == [.add(Self.at(10, 15), Self.at(10, 25), label: "client-monitoring",
                                categoryId: ClassifySeed.communication, projectId: R.clientalpha)])
        #expect(!(try #require(s.session.toast)).summary.contains("not billable"))
    }

    /// Untitled Slack has no project: the claim is category-only and the toast says it isn't billable.
    @Test func projectlessClaimIsDisclosed() throws {
        let raw = [R.raw(Self.at(9), Self.at(10), "Slack", bundle: Self.slack),
                   R.raw(Self.at(10), Self.at(10, 30), "Slack", bundle: Self.slack, kind: .idle),
                   R.raw(Self.at(10, 30), Self.at(11), "Xcode", bundle: Self.xcode)]
        let s = try Scene(raw: raw)
        let plan = try #require(s.plan(0, .upper, to: Self.at(10, 10)))
        #expect(plan.summary == "Claimed 10m for Communication (not billable — no project)")
        try s.apply(plan)
        #expect(s.session.toast?.summary.hasSuffix("(not billable — no project)") == true)
    }

    // 7. Dragging near the top or bottom of the page scrolls it.
    @Test func autoScrollNearEdges() {
        #expect(BlocksAutoScroll.delta(top: 4, bottom: 600) < 0)
        #expect(BlocksAutoScroll.delta(top: 600, bottom: 4) > 0)
        #expect(BlocksAutoScroll.delta(top: -30, bottom: 700) == -BlocksAutoScroll.maxStep)   // past the edge: full speed
        #expect(BlocksAutoScroll.delta(top: 300, bottom: 300) == 0)
        #expect(abs(BlocksAutoScroll.delta(top: 4, bottom: 600)) > abs(BlocksAutoScroll.delta(top: 30, bottom: 600)))
    }
}
