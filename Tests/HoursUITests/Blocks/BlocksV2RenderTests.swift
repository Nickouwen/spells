import Foundation
import SwiftUI
import Testing
import HoursCore
@testable import HoursUI

/// W22 renders → `$TMPDIR/hours-blocks2-*.png` (1440×900; the Day page unscrolled, the column at
/// its default 18 h viewport). Edits are applied to the fixture the way the store would
/// (`BlocksResize.simulate`), so claimed time is real manual spans.
/// - `claim-{light,dark}`: the morning block claimed into lunch → hatched
/// - `split-light`: the last block split at 16:30 → two blocks either side of a 10-min gap
/// - `picker-{light,dark}`: project chip picker open on the selected block
/// - `micro-light`: minimum length 5 min, a 3-min block drawn as a tick
/// - `merge-light`: dragging a block's bottom to leave a 5-min gap → ghost + "Merge"
/// - `late-light`: activity past midnight scrolls the viewport down, scale unchanged
/// - `fromweek-light`: a block opened from the Week, selected and in view
@Suite(.serialized) @MainActor struct BlocksV2RenderTests {
    typealias Base = BlocksRenderTests
    static let data = DayData.fixture()

    static func at(_ h: Int, _ m: Int = 0) -> Int64 { Base.at(data, h, m) }

    static func blocks(_ d: DayData, _ min: Int = 10) -> [WorkBlock] { Base.blocks(d, min) }

    /// `d` with `drafts` applied, or `extra` spans added.
    static func edited(_ d: DayData, _ drafts: [EditDraft] = [], extra: [ClassifiedSpan] = []) -> DayData {
        DayData.assemble(date: d.date, timeZone: d.timeZone, bounds: d.bounds, spans: BlocksResize.simulate(d.spans, drafts) + extra,
                         categories: d.categories, projects: d.projects, goal: nil, nowMs: d.nowMs, rawWorkMs: nil, tracker: d.tracker)
    }

    static func tracked(_ lo: Int64, _ hi: Int64, _ app: String, category: Int64?) -> ClassifiedSpan {
        let s = EffectiveSpan(startMs: lo, endMs: hi, tzId: "America/Vancouver", kind: .active, bundleId: nil, appName: app,
                              title: nil, url: nil, categoryOverride: nil, projectOverride: nil, source: .tracked, rawSeq: 1, label: nil)
        return ClassifiedSpan(span: s, categoryId: category, projectId: nil)
    }

    static func render(_ d: DayData, _ preview: BlocksPreview, _ name: String, scheme: ColorScheme = .light,
                       request: WeekBlockRoute? = nil) throws {
        let view = Base.view(d, preview).environment(\.blocksOpenRequest, request)
        let path = try BlocksRender.png(view, size: Base.size, scheme: scheme, name: name, prefix: "hours-blocks2-")
        print("BlocksRender: \(path)")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func claim(_ scheme: ColorScheme) throws {
        let b = try #require(Self.blocks(Self.data).first)
        let plan = try #require(BlocksResize.plan(b, edge: .upper, to: Self.at(13, 15), blocks: Self.blocks(Self.data),
                                                  data: Self.data, thresholdMs: 600_000))
        let d = Self.edited(Self.data, plan.drafts)
        #expect(!BlocksColumn.claimed(Self.blocks(d)[0], d).isEmpty)
        try Self.render(d, BlocksPreview(thresholdMin: 10, selectedMs: Self.at(10)), "claim-\(scheme == .dark ? "dark" : "light")",
                        scheme: scheme)
    }

    @Test func split() throws {
        let last = try #require(Self.blocks(Self.data).last)
        let plan = try #require(BlocksActions.split(last, at: Self.at(16, 30), data: Self.data, thresholdMs: 600_000))
        let d = Self.edited(Self.data, plan.drafts)
        #expect(Self.blocks(d).count == Self.blocks(Self.data).count + 1)
        try Self.render(d, BlocksPreview(thresholdMin: 10, selectedMs: Self.at(17)), "split-light")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func picker(_ scheme: ColorScheme) throws {
        try Self.render(Self.data, BlocksPreview(thresholdMin: 10, selectedMs: Self.at(14), projectPickerOpen: true),
                        "picker-\(scheme == .dark ? "dark" : "light")", scheme: scheme)
    }

    @Test func micro() throws {
        let d = Self.edited(Self.data, extra: [Self.tracked(Self.at(19, 30), Self.at(19, 33), "Slack", category: ClassifySeed.communication)])
        #expect(Self.blocks(d).contains { $0.wallMs == 3 * 60_000 })
        try Self.render(d, BlocksPreview(thresholdMin: 10, minBlockMin: 5), "micro-light")
    }

    @Test func merge() throws {
        let bs = Self.blocks(Self.data)
        let b = try #require(bs.first { $0.contains(Self.at(14)) })
        let next = try #require(bs.first { $0.startMs > b.endMs })
        let to = next.startMs - 5 * 60_000
        let p = try #require(BlocksResize.proposal(b, edge: .upper, to: to, blocks: bs, data: Self.data, thresholdMs: 600_000))
        #expect(p.kind == .merge)
        try Self.render(Self.data, BlocksPreview(thresholdMin: 10, hoverMs: b.endMs,
                                                 drag: BlocksDrag(blockStartMs: b.startMs, edge: .upper, ms: to)), "merge-light")
    }

    @Test func late() throws {
        let d = Self.edited(Self.data, extra: [Self.tracked(Self.at(23, 10), Self.at(25, 20), "Xcode", category: ClassifySeed.coding)])
        #expect(BlocksCard.defaultOffset(d, settings: [:], thresholdMs: 600_000, selectedMs: nil)
                > BlocksCard.defaultOffset(Self.data, settings: [:], thresholdMs: 600_000, selectedMs: nil))
        try Self.render(d, BlocksPreview(thresholdMin: 10), "late-light")
    }

    @Test func fromWeek() throws {
        let b = try #require(Self.blocks(Self.data).first { $0.contains(Self.at(14)) })
        try Self.render(Self.data, BlocksPreview(thresholdMin: 10), "fromweek-light", request: .open(b, on: Self.data.date))
    }
}
