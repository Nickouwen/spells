import Foundation
import Testing
@testable import HoursCore

/// Work blocks: hand-built days, expectations computed by hand.
struct MetricsBlocksTests {
    typealias F = MetricsFixture
    static let d = 6
    static func t(_ h: Int, _ m: Int, _ s: Int = 0) -> Int64 { F.t(d, h, m, s) }
    static func mins(_ n: Int64) -> Int64 { n * 60_000 }
    static func spans(_ d: MetricsBlocks.Day) -> [Range<Int64>] { d.blocks.map { $0.startMs..<$0.endMs } }

    static func blocks(_ spans: [ClassifiedSpan], thresholdMin: Int = 10) -> MetricsBlocks.Day {
        MetricsBlocks.day(spans: spans, categories: F.categories, breakThresholdMs: Int64(thresholdMin) * 60_000)
    }

    @Test func emptyDay() {
        let day = Self.blocks([])
        #expect(day.blocks.isEmpty)
        #expect(day.breaks.isEmpty)
        // Only idle / excluded time: still nothing to group.
        let quiet = Self.blocks([F.idle(Self.t(9, 0), Self.t(10, 0)),
                                 F.span(Self.t(10, 0), Self.t(10, 30), "loginwindow", F.excluded)])
        #expect(quiet.blocks.isEmpty)
    }

    /// A gap exactly at the threshold breaks; one second shorter joins.
    @Test func thresholdBoundary() {
        let equal = Self.blocks([F.span(Self.t(9, 0), Self.t(10, 0), F.xcode, F.coding),
                                 F.span(Self.t(10, 10), Self.t(11, 0), F.xcode, F.coding)])
        #expect(Self.spans(equal) == [Self.t(9, 0)..<Self.t(10, 0), Self.t(10, 10)..<Self.t(11, 0)])
        #expect(equal.breaks == [BlockBreak(startMs: Self.t(10, 0), endMs: Self.t(10, 10), kind: .notTracking)])

        let shorter = Self.blocks([F.span(Self.t(9, 0), Self.t(10, 0), F.xcode, F.coding),
                                   F.span(Self.t(10, 9, 59), Self.t(11, 0), F.xcode, F.coding)])
        #expect(shorter.blocks.count == 1)
        #expect(shorter.blocks[0].startMs == Self.t(9, 0) && shorter.blocks[0].endMs == Self.t(11, 0))
        #expect(shorter.blocks[0].activeMs == Self.mins(110) + 1000)
        #expect(shorter.blocks[0].idleInsideMs == 0)   // a tracker gap, not idle
        #expect(shorter.breaks.isEmpty)
    }

    /// Short idle joins the block (counted as idle inside); long idle is an "away" break.
    @Test func idleInsideVsOutside() {
        let spans = [
            F.span(Self.t(9, 0), Self.t(9, 50), F.xcode, F.coding, project: F.projA),
            F.idle(Self.t(9, 50), Self.t(9, 57)),                                         // 7 min: inside
            F.span(Self.t(9, 57), Self.t(10, 30), F.slack, F.communication),
            F.idle(Self.t(10, 30), Self.t(11, 15)),                                       // 45 min: break
            F.span(Self.t(11, 15), Self.t(12, 0), F.xcode, F.coding, project: F.projB),
        ]
        let day = Self.blocks(spans)
        #expect(day.blocks.count == 2)
        let a = day.blocks[0]
        #expect(a.startMs == Self.t(9, 0) && a.endMs == Self.t(10, 30))
        #expect(a.activeMs == Self.mins(83))
        #expect(a.idleInsideMs == Self.mins(7))
        #expect(a.byCategory == [.init(key: F.coding.id, ms: Self.mins(50)), .init(key: F.communication.id, ms: Self.mins(33))])
        #expect(a.dominantCategoryId == F.coding.id)
        #expect(a.dominantProjectId == F.projA)
        #expect(a.topContexts.map(\.name) == ["Xcode", "slackmacgap"])
        #expect(day.breaks == [BlockBreak(startMs: Self.t(10, 30), endMs: Self.t(11, 15), kind: .away)])
        #expect(day.blocks[1].dominantProjectId == F.projB)
        #expect(day.blocks[1].idleInsideMs == 0)
    }

    /// Raising the threshold merges two blocks over the break between them.
    @Test func mergeAfterThresholdIncrease() {
        let spans = [
            F.span(Self.t(9, 0), Self.t(10, 0), F.xcode, F.coding),
            F.idle(Self.t(10, 0), Self.t(10, 20)),
            F.span(Self.t(10, 20), Self.t(11, 0), F.safari, F.coding, url: "https://www.github.com/x"),
        ]
        let at10 = Self.blocks(spans, thresholdMin: 10)
        #expect(at10.blocks.count == 2)
        #expect(at10.breaks.map(\.kind) == [.away])
        let at30 = Self.blocks(spans, thresholdMin: 30)
        #expect(at30.blocks.count == 1)
        #expect(at30.breaks.isEmpty)
        #expect(at30.blocks[0].activeMs == Self.mins(100))
        #expect(at30.blocks[0].idleInsideMs == Self.mins(20))
        #expect(at30.blocks[0].wallMs == Self.mins(120))
        #expect(at30.blocks[0].topContexts == [.init(name: "Xcode", isHost: false, ms: Self.mins(60)),
                                               .init(name: "github.com", isHost: true, ms: Self.mins(40))])
    }

    /// Excluded-category time is a gap: not active, not idle; long enough, it's a "not tracking" break.
    @Test func excludedActsAsGap() {
        let spans = [
            F.span(Self.t(9, 0), Self.t(10, 0), F.xcode, F.coding),
            F.span(Self.t(10, 0), Self.t(10, 25), "loginwindow", F.excluded),
            F.span(Self.t(10, 25), Self.t(11, 0), F.xcode, F.coding),
            F.span(Self.t(11, 0), Self.t(11, 5), "loginwindow", F.excluded),
            F.span(Self.t(11, 5), Self.t(11, 30), F.xcode, F.coding),
        ]
        let day = Self.blocks(spans)
        #expect(Self.spans(day) == [Self.t(9, 0)..<Self.t(10, 0), Self.t(10, 25)..<Self.t(11, 30)])
        #expect(day.breaks == [BlockBreak(startMs: Self.t(10, 0), endMs: Self.t(10, 25), kind: .notTracking)])
        #expect(day.blocks[1].activeMs == Self.mins(60))    // the 5-min excluded stretch joins but doesn't count
        #expect(day.blocks[1].idleInsideMs == 0)
        #expect(day.blocks[1].byCategory == [.init(key: F.coding.id, ms: Self.mins(60))])
    }

    @Test func editedFlagAndUncategorizedDominance() {
        var manual = F.span(Self.t(9, 30), Self.t(10, 0), "", F.coding, project: F.projA)
        manual.span.source = .manual; manual.span.label = "Pairing"; manual.span.rawSeq = nil; manual.span.editSeqs = [7]
        let spans = [F.span(Self.t(9, 0), Self.t(9, 30), F.mail, nil), manual,
                     F.span(Self.t(10, 0), Self.t(10, 45), F.finder, nil),
                     F.span(Self.t(12, 0), Self.t(12, 30), F.xcode, F.coding)]
        let day = Self.blocks(spans)
        #expect(day.blocks.count == 2)
        #expect(day.blocks[0].hasEdits)
        #expect(!day.blocks[1].hasEdits)
        #expect(day.blocks[0].dominantCategoryId == nil)                     // 75 min Uncategorized vs 30 Coding
        #expect(day.blocks[0].dominantProjectId == nil)                      // 75 min without a project
        #expect(day.blocks[0].byProject == [.init(key: nil, ms: Self.mins(75)), .init(key: F.projA, ms: Self.mins(30))])
        #expect(day.blocks[0].topContexts.map(\.name) == ["finder", "mail", "Pairing"])
    }
}
