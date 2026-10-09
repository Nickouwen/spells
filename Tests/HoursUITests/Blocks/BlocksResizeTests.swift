import Foundation
import Testing
import HoursCore
@testable import HoursUI

/// Edge drags on the Blocks column → exact edit drafts, then applied through a temp store via
/// `EditSession.commit` (the real editing model) and regrouped. UTC, Thu 1 Oct 2026 (a past day):
/// - A 09:00–10:20: Xcode "route.ts — operations-dashboard" (Coding, project 2) 09:00–10:00, Slack 10:00–10:20
/// - idle 10:20–11:00 (Break · 40m, away)
/// - B 11:00–12:00: Xcode "ingest.py — client-monitoring" (Coding, project 1)
/// - no spans 12:00–12:30 (Not tracking · 30m)
/// - C 12:30–13:00: Xcode client-monitoring
@Suite(.serialized) @MainActor struct BlocksResizeTests {
    typealias F = EditFixture
    static func at(_ h: Int, _ m: Int = 0) -> Int64 { F.at(h, m) }
    static let threshold: Int64 = 10 * 60_000
    static let dashboard: Int64 = 2, clientalpha: Int64 = 1

    static func raw(_ lo: Int64, _ hi: Int64, _ app: String, bundle: String, title: String? = nil,
                    kind: SpanKind = .active) -> RawSpan {
        RawSpan(seq: 0, startMs: lo, endMs: hi, tzId: "UTC", tzOffsetS: 0, kind: kind, bundleId: bundle,
                appName: app, title: title, url: nil)
    }

    static var dayRaw: [RawSpan] {
        [raw(at(9), at(10), "Xcode", bundle: "com.apple.dt.Xcode", title: "route.ts — operations-dashboard"),
         raw(at(10), at(10, 20), "Slack", bundle: "com.tinyspeck.slackmacgap"),
         raw(at(10, 20), at(11), "Slack", bundle: "com.tinyspeck.slackmacgap", kind: .idle),
         raw(at(11), at(12), "Xcode", bundle: "com.apple.dt.Xcode", title: "ingest.py — client-monitoring"),
         raw(at(12, 30), at(13), "Xcode", bundle: "com.apple.dt.Xcode", title: "ingest.py — client-monitoring")]
    }

    /// A fresh temp store holding the day (EditFixture's three acceptance spans are replaced by `dayRaw`).
    @MainActor final class Scene {
        let db: HoursDB
        let session: EditSession
        let undo = UndoManager()

        init(raw: [RawSpan] = BlocksResizeTests.dayRaw) throws {
            db = try HoursDB.open(at: FileManager.default.temporaryDirectory
                .appending(path: "hours-blocks-tests/\(UUID().uuidString)/hours.db"),
                                  role: .app, notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
            for s in raw { _ = try SpanWriter(db).append(s) }
            undo.groupsByEvent = false
            session = EditSession(db: db)
            session.undoManager = undo
            try refresh()
        }

        @discardableResult
        func refresh() throws -> DayData {
            let classifier = Classifier(categories: ClassifySeed.categories, rules: ClassifySeed.rules, projects: ClassifySeed.projects)
            let d = try DayData.load(store: Store(db), classifier: classifier, categories: ClassifySeed.categories,
                                     projects: ClassifySeed.projects, day: F.day, goal: nil,
                                     now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: F.tz)
            session.update(d)
            return d
        }

        var data: DayData { session.data! }
        var blocks: [WorkBlock] {
            MetricsBlocks.compute(spans: data.spans, categories: data.categories, breakThresholdMs: BlocksResizeTests.threshold)
        }
        func billable(_ project: Int64) -> Int64 {
            data.metrics.byProject.first { $0.key == project }?.workMs ?? 0
        }

        func plan(_ i: Int, _ edge: EditGesture.Edge, to t: Int64) -> EditPlan? {
            BlocksResize.plan(blocks[i], edge: edge, to: t, blocks: blocks, data: data, thresholdMs: BlocksResizeTests.threshold)
        }

        /// Commits `p` as one group and reloads.
        func apply(_ p: EditPlan) throws {
            try #require(session.commit(p) != nil)
            try refresh()
        }

        /// Plans, commits as one group, reloads. Returns the plan's drafts.
        func drag(_ i: Int, _ edge: EditGesture.Edge, to t: Int64) throws -> [EditDraft] {
            let p = try #require(plan(i, edge, to: t))
            try #require(session.commit(p) != nil)
            try refresh()
            return p.drafts
        }
    }

    static func extents(_ s: Scene) -> [Range<Int64>] { s.blocks.map { $0.startMs..<$0.endMs } }

    @Test func fixtureGroupsIntoThreeBlocks() throws {
        let s = try Scene()
        #expect(Self.extents(s) == [Self.at(9)..<Self.at(10, 20), Self.at(11)..<Self.at(12), Self.at(12, 30)..<Self.at(13)])
        #expect(s.blocks.map(\.dominantProjectId) == [Self.dashboard, Self.clientalpha, Self.clientalpha])
        #expect(s.blocks[0].dominantCategoryId == ClassifySeed.coding)
        #expect(BlocksResize.label(s.blocks[0], s.data) == "operations-dashboard")
    }

    /// Bottom edge outward into the break: an add labelled with the dominant project; it's now
    /// work + billable for that project, and replaces the idle beneath.
    @Test func outwardClaimAddsBillableToDominantProject() throws {
        let s = try Scene()
        let before = s.billable(Self.dashboard), work = s.data.metrics.workMs
        let drafts = try s.drag(0, .upper, to: Self.at(10, 45))
        #expect(drafts == [.add(Self.at(10, 20), Self.at(10, 45), label: "operations-dashboard",
                                categoryId: ClassifySeed.coding, projectId: Self.dashboard)])
        #expect(Self.extents(s).first == Self.at(9)..<Self.at(10, 45))
        #expect(s.billable(Self.dashboard) - before == 25 * 60_000)
        #expect(s.data.metrics.workMs - work == 25 * 60_000)
        #expect(!s.data.spans.contains { $0.span.kind == .idle && $0.span.startMs < Self.at(10, 45) })
        #expect(s.blocks[0].hasEdits)
    }

    /// Top edge outward: the same claim, before the block.
    @Test func outwardClaimOnTopEdge() throws {
        let s = try Scene()
        let drafts = try s.drag(1, .lower, to: Self.at(10, 50))
        #expect(drafts == [.add(Self.at(10, 50), Self.at(11), label: "client-monitoring",
                                categoryId: ClassifySeed.coding, projectId: Self.clientalpha)])
        #expect(Self.extents(s)[1] == Self.at(10, 50)..<Self.at(12))
    }

    /// Top edge inward: a delete over the trimmed range; the project loses that time.
    @Test func inwardTrimRemovesTime() throws {
        let s = try Scene()
        let before = s.billable(Self.dashboard)
        let drafts = try s.drag(0, .lower, to: Self.at(9, 15))
        #expect(drafts == [.delete(Self.at(9), Self.at(9, 15))])
        #expect(Self.extents(s).first == Self.at(9, 15)..<Self.at(10, 20))
        #expect(before - s.billable(Self.dashboard) == 15 * 60_000)
        // Bottom edge inward on C.
        #expect(try s.drag(2, .upper, to: Self.at(12, 50)) == [.delete(Self.at(12, 50), Self.at(13))])
        #expect(Self.extents(s).last == Self.at(12, 30)..<Self.at(12, 50))
    }

    /// Dragging past the break into the next block fills the gap exactly, so the two merge.
    @Test func crossBreakDragMergesBlocks() throws {
        let s = try Scene()
        let p = try #require(BlocksResize.proposal(s.blocks[1], edge: .upper, to: Self.at(12, 40), blocks: s.blocks, data: s.data, thresholdMs: Self.threshold))
        #expect(p.kind == .merge && p.changed == Self.at(12)..<Self.at(12, 30))
        let drafts = try s.drag(1, .upper, to: Self.at(12, 40))
        #expect(drafts == [.add(Self.at(12), Self.at(12, 30), label: "client-monitoring",
                                categoryId: ClassifySeed.coding, projectId: Self.clientalpha)])
        #expect(Self.extents(s) == [Self.at(9)..<Self.at(10, 20), Self.at(11)..<Self.at(13)])
        // And upward across the lunch break: A and B become one block.
        _ = try s.drag(1, .lower, to: Self.at(9, 30))
        #expect(Self.extents(s) == [Self.at(9)..<Self.at(13)])
    }

    /// ⌘Z (the session's UndoManager step) restores identical blocks, for each drag kind.
    @Test(arguments: [(0, EditGesture.Edge.upper, 10, 45), (0, .lower, 9, 15), (1, .upper, 12, 40)])
    func undoRestoresBlocks(_ i: Int, _ edge: EditGesture.Edge, _ h: Int, _ m: Int) throws {
        let s = try Scene()
        let original = s.blocks
        _ = try s.drag(i, edge, to: Self.at(h, m))
        #expect(s.blocks != original)
        #expect(s.undo.canUndo)
        s.undo.undo()
        try s.refresh()
        #expect(s.blocks == original)
    }

    /// The live block: bottom edge never drags; claims stop at the watermark (the live span's start).
    @Test func liveBlockClamps() throws {
        let d = DayData.fixture(date: LocalDate(year: 2026, month: 10, day: 5), now: (14, 32))
        let blocks = MetricsBlocks.compute(spans: d.spans, categories: d.categories, breakThresholdMs: Self.threshold)
        let live = try #require(blocks.last)
        #expect(BlocksResize.isLive(live, d))
        #expect(!BlocksResize.canDrag(live, .upper, d))
        #expect(BlocksResize.plan(live, edge: .upper, to: live.endMs + 600_000, blocks: blocks, data: d, thresholdMs: Self.threshold) == nil)
        #expect(BlocksResize.plan(live, edge: .upper, to: live.endMs - 600_000, blocks: blocks, data: d, thresholdMs: Self.threshold) == nil)
        let first = try #require(blocks.first)
        #expect(!BlocksResize.isLive(first, d))
        // Past-day blocks and today's earlier blocks still resize.
        #expect(BlocksResize.plan(first, edge: .upper, to: first.endMs + 600_000, blocks: blocks, data: d, thresholdMs: Self.threshold) != nil)
    }

    @Test func snapToFiveMinutesAndNeighbourEdges() throws {
        let tz = TimeZone(identifier: "Asia/Kolkata")!   // +05:30: the grid is local
        let base = LocalDate(year: 2026, month: 10, day: 1).dayInterval(in: tz).lowerBound   // 04:00 local
        let m: Int64 = 60_000
        #expect(BlocksResize.snap(base + 7 * m, targets: [], toleranceMs: m, timeZone: tz) == base + 5 * m)
        #expect(BlocksResize.snap(base + 8 * m, targets: [], toleranceMs: m, timeZone: tz) == base + 10 * m)
        #expect(BlocksResize.snap(base + 7 * m, targets: [base + 7 * m + 30_000], toleranceMs: m, timeZone: tz) == base + 7 * m + 30_000)
        #expect(BlocksResize.snap(base + 7 * m, targets: [base + 9 * m], toleranceMs: m, timeZone: tz) == base + 5 * m)
    }
}
