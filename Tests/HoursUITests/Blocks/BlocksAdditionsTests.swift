import Foundation
import CoreGraphics
import Testing
import HoursCore
@testable import HoursUI

/// W22 additions (review-blocks.md additions 1–6, 8): exact edit drafts → blocks through a temp store,
/// and undo. Fixture = `BlocksResizeTests.dayRaw` (UTC, Thu 1 Oct 2026):
/// A 09:00–10:20 (dashboard) · idle to 11:00 · B 11:00–12:00 (clientalpha) · untracked to 12:30 · C 12:30–13:00.
@Suite(.serialized) @MainActor struct BlocksAdditionsTests {
    typealias R = BlocksResizeTests
    typealias Scene = BlocksResizeTests.Scene
    static func at(_ h: Int, _ m: Int = 0) -> Int64 { R.at(h, m) }

    static func nudge(_ s: Scene, _ i: Int, _ edge: EditGesture.Edge, earlier: Bool) -> EditPlan? {
        BlocksActions.nudge(s.blocks[i], edge: edge, earlier: earlier, blocks: s.blocks, data: s.data, thresholdMs: R.threshold)
    }

    // 1. Keyboard edge nudging: ⌘⌥↑/↓ top edge, ⌘⌥⇧↑/↓ bottom edge, 5 min, one undo group per press.
    @Test func nudgeEachEdgeFiveMinutes() throws {
        let s = try Scene()
        let label = "client-monitoring"
        #expect(Self.nudge(s, 1, .lower, earlier: true)?.drafts
                == [.add(Self.at(10, 55), Self.at(11), label: label, categoryId: ClassifySeed.coding, projectId: R.clientalpha)])
        #expect(Self.nudge(s, 1, .lower, earlier: false)?.drafts == [.delete(Self.at(11), Self.at(11, 5))])
        #expect(Self.nudge(s, 1, .upper, earlier: true)?.drafts == [.delete(Self.at(11, 55), Self.at(12))])
        #expect(Self.nudge(s, 1, .upper, earlier: false)?.drafts
                == [.add(Self.at(12), Self.at(12, 5), label: label, categoryId: ClassifySeed.coding, projectId: R.clientalpha)])

        let original = s.blocks
        try s.apply(try #require(Self.nudge(s, 1, .lower, earlier: true)))
        #expect(R.extents(s)[1] == Self.at(10, 55)..<Self.at(12))
        try s.apply(try #require(Self.nudge(s, 1, .lower, earlier: true)))
        #expect(R.extents(s)[1] == Self.at(10, 50)..<Self.at(12))
        // Each press is its own undo step.
        s.undo.undo(); try s.refresh()
        #expect(R.extents(s)[1] == Self.at(10, 55)..<Self.at(12))
        s.undo.undo(); try s.refresh()
        #expect(s.blocks == original)
    }

    // 2. Snapping: neighbours' edges, now, hour/half-hour marks; never the block's own edges.
    @Test func snapTargets() throws {
        let s = try Scene()
        let b = s.blocks[1]
        let t = Set(BlocksResize.targets(b, blocks: s.blocks, data: s.data))
        #expect(t.isSuperset(of: [Self.at(9), Self.at(10, 20), Self.at(12, 30), Self.at(13), Self.at(10, 30), Self.at(14, 30)]))
        #expect(!t.contains(Self.at(11)) && !t.contains(Self.at(12)))
        let tol: Int64 = 6 * 60_000
        #expect(BlocksResize.snap(Self.at(12, 26), targets: Array(t), toleranceMs: tol, timeZone: s.data.timeZone) == Self.at(12, 30))
        #expect(BlocksResize.snap(Self.at(10, 17), targets: Array(t), toleranceMs: tol, timeZone: s.data.timeZone) == Self.at(10, 20))
        // Today: "now" is a target.
        let d = DayData.fixture(date: LocalDate(year: 2026, month: 10, day: 5), now: (14, 32))
        let blocks = MetricsBlocks.compute(spans: d.spans, categories: d.categories, breakThresholdMs: R.threshold)
        #expect(BlocksResize.targets(blocks[0], blocks: blocks, data: d).contains(try #require(d.nowMs)))
    }

    // 3. Project chip: one `assign` (project only) over the block; "Always for these apps" rules.
    @Test func projectChipAssignsTheWholeBlock() throws {
        let s = try Scene()
        let a = s.blocks[0]
        let plan = try #require(BlocksActions.assignProject(a, R.clientalpha, data: s.data))
        #expect(plan.drafts == [.assign(Self.at(9), Self.at(10, 20), categoryId: nil, projectId: R.clientalpha)])
        let original = s.blocks
        try s.apply(plan)
        #expect(R.extents(s) == original.map { $0.startMs..<$0.endMs })
        #expect(s.blocks[0].dominantProjectId == R.clientalpha)
        #expect(s.blocks[0].byProject == [WorkBlock.Share(key: R.clientalpha, ms: 80 * 60_000)])
        #expect(s.blocks[0].dominantCategoryId == ClassifySeed.coding)   // categories untouched
        s.undo.undo(); try s.refresh()
        #expect(s.blocks == original)

        let rules = BlocksActions.rules(a, projectId: R.clientalpha, data: s.data)
        #expect(rules.map(\.name) == ["Xcode", "Slack"])
        #expect(rules.allSatisfy { $0.rule.projectId == R.clientalpha && $0.rule.categoryId == nil && $0.rule.origin == .user })
        #expect(BlocksActions.ruleLabel(a, data: s.data) == "Xcode, Slack")
    }

    // 4. Claimed-vs-tracked: the manual spans inside a block are what's hatched.
    @Test func claimedTimeIsHatched() throws {
        let s = try Scene()
        #expect(BlocksColumn.claimed(s.blocks[0], s.data).isEmpty)
        _ = try s.drag(0, .upper, to: Self.at(10, 45))
        #expect(BlocksColumn.claimed(s.blocks[0], s.data) == [Self.at(10, 20)..<Self.at(10, 45)])
        #expect(BlocksColumn.claimed(s.blocks[1], s.data).isEmpty)
    }

    // 5. Split at the pointer: delete one threshold-long gap centred on it; the halves regroup as two blocks.
    @Test func splitDeletesAThresholdGap() throws {
        let s = try Scene()
        let original = s.blocks
        let plan = try #require(BlocksActions.split(s.blocks[0], at: Self.at(9, 30), data: s.data, thresholdMs: R.threshold))
        #expect(plan.drafts == [.delete(Self.at(9, 25), Self.at(9, 35))])
        try s.apply(plan)
        #expect(R.extents(s) == [Self.at(9)..<Self.at(9, 25), Self.at(9, 35)..<Self.at(10, 20),
                                 Self.at(11)..<Self.at(12), Self.at(12, 30)..<Self.at(13)])
        s.undo.undo(); try s.refresh()
        #expect(s.blocks == original)

        // Near an edge the gap shifts inward, keeping a minute on that side; still two blocks.
        let edge = try #require(BlocksActions.splitGap(s.blocks[0], at: Self.at(9, 2), data: s.data, thresholdMs: R.threshold))
        #expect(edge == Self.at(9, 1)..<Self.at(9, 11))
        try s.apply(try #require(BlocksActions.split(s.blocks[0], at: Self.at(9, 2), data: s.data, thresholdMs: R.threshold)))
        #expect(R.extents(s).prefix(2) == [Self.at(9)..<Self.at(9, 1), Self.at(9, 11)..<Self.at(10, 20)])
        // Too short for a threshold gap plus a minute each side.
        #expect(BlocksActions.split(s.blocks.last!, at: Self.at(12, 45), data: s.data, thresholdMs: 30 * 60_000) == nil)
    }

    // 6. Minimum block length: short blocks are micro, outside the count. Display only.
    @Test func microBlocksLeaveTheCount() throws {
        let s = try Scene(raw: R.dayRaw + [R.raw(Self.at(14), Self.at(14, 3), "Slack", bundle: "com.tinyspeck.slackmacgap")])
        let day = MetricsBlocks.day(spans: s.data.spans, categories: s.data.categories, breakThresholdMs: R.threshold)
        #expect(day.blocks.count == 4)
        #expect(BlocksCard.summary(day, minBlockMs: 0) == "4 blocks · 3 breaks")
        #expect(BlocksCard.summary(day, minBlockMs: 5 * 60_000) == "3 blocks · 3 breaks · 1 micro")
        #expect(BlocksCard.summary(day, minBlockMs: 40 * 60_000) == "2 blocks · 3 breaks · 2 micro")
        #expect(try Store(s.db).allEdits().isEmpty)
    }

    // 8. Per-weekday thresholds live in store settings; the header writes the default unless "only on <weekday>".
    @Test func thresholdWritesGoToStoreSettings() throws {
        let s = try Scene()
        let store = BlocksStore(db: s.db)
        store.loadIfNeeded()
        let thu = LocalDate(year: 2026, month: 10, day: 1), fri = LocalDate(year: 2026, month: 10, day: 2)
        store.setThreshold(25, for: thu, weekdayOnly: false)
        #expect(BlocksThreshold.minutes(for: thu, settings: store.settings) == 25)
        store.setWeekdayOnly(true, for: thu)
        store.setThreshold(40, for: thu, weekdayOnly: true)
        #expect(BlocksThreshold.minutes(for: thu, settings: store.settings) == 40)
        #expect(BlocksThreshold.minutes(for: fri, settings: store.settings) == 25)
        let saved = try SettingStore(s.db).all()
        #expect(saved[BlocksThreshold.defaultKey] == "25" && saved[BlocksThreshold.weekdayKey] == "5:40")
        store.setWeekdayOnly(false, for: thu)
        #expect(try SettingStore(s.db).all()[BlocksThreshold.weekdayKey] == nil)
        #expect(BlocksThreshold.minutes(for: thu, settings: store.settings) == 25)
    }

    // Week → Day: the opened block is selected on its day only, and scrolled into view.
    @Test func weekOpenRequestSelectsAndScrolls() throws {
        let d = DayData.fixture()
        let blocks = MetricsBlocks.compute(spans: d.spans, categories: d.categories, breakThresholdMs: R.threshold)
        let last = try #require(blocks.last)
        let route = WeekBlockRoute.open(last, on: d.date)
        #expect(BlocksCard.requestedSelection(route, on: d.date) == route.selectedMs)
        #expect(BlocksCard.requestedSelection(route, on: d.date.adding(days: 1)) == nil)
        // A 6-hour window doesn't reach the evening block from 06:00; selecting it scrolls there.
        let settings = [BlocksThreshold.windowHoursKey: "6"]
        let plain = BlocksCard.defaultOffset(d, settings: settings, thresholdMs: R.threshold, selectedMs: nil)
        let focused = BlocksCard.defaultOffset(d, settings: settings, thresholdMs: R.threshold, selectedMs: route.selectedMs)
        let geo = BlocksGeometry.day(bounds: d.bounds, windowHours: 6)
        #expect(focused > plain)
        #expect(geo.y(last.endMs) <= focused + BlocksGeometry.viewportHeight)
    }
}
