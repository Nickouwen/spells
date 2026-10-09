import SwiftUI
import Testing
import HoursCore
@testable import HoursUI

/// Runtime renders of the Week's Blocks mode → `$TMPDIR/hours-weekblocks-*.png`, plus the render budget.
/// The fixture is the current week on Fri 2 Oct at 15:10: four full days, today cut at now, a future weekend.
@Suite(.serialized) struct WeekBlocksRenderTests {
    @MainActor
    static func view(_ data: WeekData) -> some View {
        WeekView(data: data, onSelectDay: { _ in }, onNavigate: { _ in }, pinnedMode: .blocks)
    }

    static let current = WeekData.fixture(today: rd(2026, 10, 2), now: (15, 10))

    @MainActor
    @Test(arguments: [
        ("light", 1440.0, 900.0), ("dark", 1440, 900), ("1180x760-light", 1180, 760), ("1180x760-dark", 1180, 760),
        ("past-light", 1440, 900), ("900x600-light", 900, 600), ("tall-light", 1180, 1100),
    ])
    func renderPNG(_ name: String, _ w: Double, _ h: Double) throws {
        let size = CGSize(width: w, height: h)
        let data = name.hasPrefix("past") ? WeekData.fixture() : Self.current
        let (url, rep) = try RangeRender.write(Self.view(data), size: size, scheme: name.hasSuffix("dark") ? .dark : .light,
                                               name: "hours-weekblocks-\(name)")
        #expect(rep.size == size)
        print("WeekBlocks (\(name)): \(url.path)")
    }

    /// Full render of the fixture week in Blocks mode — window, layout, draw at 2× — < 100 ms after a warm-up. Best of 3.
    @MainActor
    @Test func fixtureWeekBlocksRendersUnder100ms() {
        let size = CGSize(width: 1440, height: 900)
        _ = RangeRender.bitmap(Self.view(.fixture(week: rd(2026, 9, 21))), size: size, scheme: .light)
        let clock = ContinuousClock()
        let runs = (0..<3).map { _ in clock.measure { _ = RangeRender.bitmap(Self.view(Self.current), size: size, scheme: .light) } }
        let best = runs.min()!
        print("WeekBlocks render: best \(best) of \(runs)")
        if perfEnforced { #expect(best < .milliseconds(100)) }
    }
}
