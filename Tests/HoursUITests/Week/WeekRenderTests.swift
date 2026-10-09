import SwiftUI
import Testing
import HoursCore
@testable import HoursUI

/// Runtime render of `WeekView` at 1280×860 → `$TMPDIR/hours-week-<name>.png`, plus the render budget.
@Suite(.serialized) struct WeekRenderTests {
    static let size = CGSize(width: 1280, height: 860)

    @MainActor
    static func view(_ data: WeekData) -> some View {
        WeekView(data: data, onSelectDay: { _ in }, onNavigate: { _ in })
    }

    @MainActor
    @Test(arguments: ["light", "dark", "current", "empty"])
    func renderPNG(_ name: String) throws {
        let data: WeekData = switch name {
        case "current": .fixture(week: rd(2026, 10, 1), today: rd(2026, 10, 1))
        case "empty": .fixture(empty: true)
        default: .fixture()
        }
        let (url, rep) = try RangeRender.write(Self.view(data), size: Self.size, scheme: name == "dark" ? .dark : .light,
                                               name: "hours-week-\(name)")
        #expect(rep.size == Self.size)
        print("WeekView (\(name)): \(url.path)")
    }

    /// Full render of a fixture week — new window, layout, draw at 2× — in < 100 ms, after one
    /// warm-up render (Charts first-use cost is per process). Best of 3.
    @MainActor
    @Test func fixtureWeekRendersUnder100ms() {
        _ = RangeRender.bitmap(Self.view(.fixture(week: rd(2026, 9, 21))), size: Self.size, scheme: .light)
        let data = WeekData.fixture()
        let clock = ContinuousClock()
        let runs = (0..<3).map { _ in clock.measure { _ = RangeRender.bitmap(Self.view(data), size: Self.size, scheme: .light) } }
        let best = runs.min()!
        print("WeekView render: best \(best) of \(runs)")
        if perfEnforced { #expect(best < .milliseconds(100)) }
    }
}
