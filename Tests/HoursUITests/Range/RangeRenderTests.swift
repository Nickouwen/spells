import SwiftUI
import Testing
import HoursCore
@testable import HoursUI

/// Runtime render: `RangeView` for the previous billing period of fixture data, light + dark,
/// each group-by, at 1280×860 → `$TMPDIR/hours-range-<scheme>-<group>.png`; plus the detail sheet.
@Suite(.serialized) struct RangeRenderTests {
    static let today = rd(2026, 10, 5)

    @MainActor
    @Test(arguments: [ColorScheme.light, .dark])
    func renderRangeView(scheme: ColorScheme) throws {
        let data = RangeData.fixture(period: .previousBilling, today: Self.today)
        for group in RangeGroup.allCases {
            let view = RangeView(data: data, period: .constant(.previousBilling), today: Self.today, group: group)
            let name = "hours-range-\(scheme == .dark ? "dark" : "light")-\(group.rawValue.lowercased())"
            let (url, rep) = try RangeRender.write(view, size: CGSize(width: 1280, height: 860), scheme: scheme, name: name)
            #expect(rep.size == CGSize(width: 1280, height: 860))
            print("RangeView (\(scheme), \(group.rawValue)): \(url.path)")
        }
    }

    @MainActor
    @Test(arguments: [ColorScheme.light, .dark])
    func renderDetailSheet(scheme: ColorScheme) throws {
        let data = RangeData.fixture(period: .previousBilling, today: Self.today)
        let row = try #require(data.rows(.project).first)
        let view = RangeDetailView(data: data, row: row) {}
        let name = "hours-range-detail-\(scheme == .dark ? "dark" : "light")"
        let (url, _) = try RangeRender.write(view, size: CGSize(width: RangeDetailView.width, height: RangeDetailView.height), scheme: scheme, name: name)
        print("RangeDetailView (\(scheme)): \(url.path)")
    }

    /// 31-day fixture: build once, warm the process (Charts/Table first-use cost is per process,
    /// not per view), then a full render — new window, layout, draw at 2× — must finish in < 100 ms.
    /// Best of 3, so a parallel build on the machine doesn't make it flaky.
    @MainActor
    @Test func thirtyOneDayRenderUnder100ms() {
        let data = RangeData.fixture(period: .thisMonth, today: rd(2026, 10, 20))
        #expect(data.days.count == 31)
        let size = CGSize(width: 1280, height: 860)
        _ = RangeRender.bitmap(RangeView(data: RangeData.fixture(period: .thisWeek, today: Self.today),
                                         period: .constant(.thisWeek), today: Self.today), size: size, scheme: .light)
        let clock = ContinuousClock()
        let runs = (0..<3).map { _ in
            clock.measure {
                _ = RangeRender.bitmap(RangeView(data: data, period: .constant(.thisMonth), today: rd(2026, 10, 20)),
                                       size: size, scheme: .light)
            }
        }
        let best = runs.min()!
        print("RangeView 31-day render: best \(best) of \(runs)")
        if perfEnforced { #expect(best < .milliseconds(100)) }
    }
}
