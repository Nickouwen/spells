import Foundation
import Testing
import RewindCore
@testable import RewindUI

/// Dragging across empty time in the Blocks column → a manual entry (`BlocksAdd`). Fixture =
/// `BlocksResizeTests.dayRaw` (UTC, Thu 1 Oct 2026, a past day: no watermark):
/// A 09:00–10:20 (dashboard) · idle to 11:00 · B 11:00–12:00 (clientalpha) · untracked to 12:30 · C 12:30–13:00.
@Suite(.serialized) @MainActor struct BlocksAddTests {
    typealias R = BlocksResizeTests
    typealias Scene = BlocksResizeTests.Scene
    static func at(_ h: Int, _ m: Int = 0) -> Int64 { R.at(h, m) }

    @Test func gapsStopAtBlocksAndTheDay() throws {
        let s = try Scene()
        func gap(_ ms: Int64, min: Int64 = 0) -> Range<Int64>? { BlocksAdd.gap(at: ms, blocks: s.blocks, data: s.data, minBlockMs: min) }
        #expect(gap(Self.at(10, 30)) == Self.at(10, 20)..<Self.at(11))           // the break between A and B
        #expect(gap(Self.at(12, 10)) == Self.at(12)..<Self.at(12, 30))           // the untracked stretch
        #expect(gap(Self.at(9, 30)) == nil)                                      // inside A
        #expect(gap(Self.at(11)) == nil)                                         // B's first instant
        #expect(gap(Self.at(7)) == s.data.bounds.lowerBound..<Self.at(9))        // before the first block
        #expect(gap(Self.at(15)) == Self.at(13)..<s.data.bounds.upperBound)      // after the last

        // A 3-minute micro block inside the break is empty space when micro blocks are hidden.
        var raw = R.dayRaw
        raw.replaceSubrange(2...2, with: [R.raw(Self.at(10, 20), Self.at(10, 30), "Slack", bundle: "com.tinyspeck.slackmacgap", kind: .idle),
                                          R.raw(Self.at(10, 30), Self.at(10, 33), "Slack", bundle: "com.tinyspeck.slackmacgap"),
                                          R.raw(Self.at(10, 33), Self.at(11), "Slack", bundle: "com.tinyspeck.slackmacgap", kind: .idle)])
        let m = try Scene(raw: raw)
        #expect(BlocksAdd.gap(at: Self.at(10, 45), blocks: m.blocks, data: m.data, minBlockMs: 0) == Self.at(10, 33)..<Self.at(11))
        #expect(BlocksAdd.gap(at: Self.at(10, 45), blocks: m.blocks, data: m.data, minBlockMs: 5 * 60_000) == Self.at(10, 20)..<Self.at(11))
        #expect(BlocksAdd.gap(at: Self.at(10, 31), blocks: m.blocks, data: m.data, minBlockMs: 5 * 60_000) == Self.at(10, 20)..<Self.at(11))
    }

    @Test func gapsStopAtTheWatermark() throws {
        // Today at 12:45 (the watermark): the stretch after 13:00 hasn't happened, so it isn't empty.
        let s = try Scene()
        let live = DayData.assemble(date: s.data.date, timeZone: s.data.timeZone, bounds: s.data.bounds, spans: s.data.spans,
                                    categories: s.data.categories, projects: s.data.projects, goal: nil, nowMs: Self.at(12, 45),
                                    rawWorkMs: nil, tracker: s.data.tracker)
        let blocks = MetricsBlocks.compute(spans: live.spans, categories: live.categories, breakThresholdMs: R.threshold)
        #expect(BlocksAdd.gap(at: Self.at(12, 10), blocks: blocks, data: live, minBlockMs: 0) == Self.at(12)..<Self.at(12, 30))
        #expect(BlocksAdd.gap(at: Self.at(13, 30), blocks: blocks, data: live, minBlockMs: 0) == nil)
    }

    @Test func rangesClampSnapAndSuggest() throws {
        let s = try Scene()
        let gap = Self.at(10, 20)..<Self.at(11)
        #expect(BlocksAdd.range(from: Self.at(10, 30), to: Self.at(10, 50), in: gap) == Self.at(10, 30)..<Self.at(10, 50))
        #expect(BlocksAdd.range(from: Self.at(10, 50), to: Self.at(10, 30), in: gap) == Self.at(10, 30)..<Self.at(10, 50))   // upward drag
        #expect(BlocksAdd.range(from: Self.at(10, 30), to: Self.at(11, 30), in: gap) == Self.at(10, 30)..<Self.at(11))       // stops at B
        #expect(BlocksAdd.range(from: Self.at(10, 30), to: Self.at(10, 30) + 30_000, in: gap) == nil)                          // a slip

        // Snap targets: the gap's edges, the hour and half-hour marks (no "now" on a past day).
        let targets = BlocksAdd.targets(gap, data: s.data)
        #expect(targets.contains(Self.at(10, 20)) && targets.contains(Self.at(11)) && targets.contains(Self.at(10, 30)))
        #expect(BlocksResize.snap(Self.at(10, 58), targets: targets, toleranceMs: 180_000, timeZone: s.data.timeZone) == Self.at(11))
        #expect(BlocksResize.snap(Self.at(10, 22), targets: targets, toleranceMs: 180_000, timeZone: s.data.timeZone) == Self.at(10, 20))

        // Add Entry Here: 30 min forward, moved back to fit, shortened to a short gap, none in a tiny one.
        #expect(BlocksAdd.suggested(at: Self.at(10, 25), in: gap) == Self.at(10, 25)..<Self.at(10, 55))
        #expect(BlocksAdd.suggested(at: Self.at(10, 50), in: gap) == Self.at(10, 30)..<Self.at(11))
        #expect(BlocksAdd.suggested(at: Self.at(12, 5), in: Self.at(12)..<Self.at(12, 30)) == Self.at(12)..<Self.at(12, 30))
        #expect(BlocksAdd.suggested(at: Self.at(12), in: Self.at(12)..<(Self.at(12) + 30_000)) == nil)
        #expect(BlocksAdd.readout(Self.at(10, 30)..<Self.at(10, 50), data: s.data) == "10:30–10:50 · 20m")

        // The form starts on the nearest block's category (Coding here), never Uncategorized (not work).
        let coding = try #require(s.data.categories.first { $0.key == "coding" }).id
        #expect(BlocksAdd.defaultCategory(for: Self.at(10, 30)..<Self.at(10, 50), blocks: s.blocks) == coding)
        #expect(BlocksAdd.defaultCategory(for: Self.at(7)..<Self.at(8), blocks: s.blocks) == coding)
        #expect(BlocksAdd.defaultCategory(for: Self.at(7)..<Self.at(8), blocks: []) == nil)
    }

    @Test func addEntryWritesManualTimeAndRegroups() throws {
        let s = try Scene()
        let before = s.billable(R.dashboard)
        let coding = try #require(s.data.categories.first { $0.key == "coding" }).id
        let e = EditSession.NewEntry(range: Self.at(10, 30)..<Self.at(10, 50), label: "Standup", categoryId: coding, projectId: R.dashboard)
        let plan = try #require(BlocksAdd.plan(e, data: s.data))
        #expect(plan.drafts == [.add(Self.at(10, 30), Self.at(10, 50), label: "Standup", categoryId: coding, projectId: R.dashboard)])
        #expect(plan.actionName == "Add Entry")
        #expect(plan.selection.isEmpty)
        try s.apply(plan)

        // 10 min of idle either side, exactly the threshold: the entry is its own block between A and B.
        #expect(s.blocks.map { [$0.startMs, $0.endMs] } == [[Self.at(9), Self.at(10, 20)], [Self.at(10, 30), Self.at(10, 50)],
                                                              [Self.at(11), Self.at(12)], [Self.at(12, 30), Self.at(13)]])
        let added = s.blocks[1]
        #expect(added.dominantProjectId == R.dashboard)
        #expect(BlocksColumn.claimed(added, s.data) == [Self.at(10, 30)..<Self.at(10, 50)])
        #expect(s.data.spans.first { $0.span.source == .manual }?.span.label == "Standup")
        #expect(s.billable(R.dashboard) - before == 20 * 60_000)

        // One undo group.
        s.undo.undo(); try s.refresh()
        #expect(s.blocks.count == 3)
        #expect(s.billable(R.dashboard) == before)

        // No label → "Manual entry"; a range that fills the gap merges into both neighbours.
        let fill = try #require(BlocksAdd.plan(EditSession.NewEntry(range: Self.at(10, 20)..<Self.at(11)), data: s.data))
        #expect(fill.drafts == [.add(Self.at(10, 20), Self.at(11), label: "Manual entry", categoryId: nil, projectId: nil)])
        try s.apply(fill)
        #expect(s.blocks.map(\.startMs).prefix(2) == [Self.at(9), Self.at(12, 30)])
    }
}
