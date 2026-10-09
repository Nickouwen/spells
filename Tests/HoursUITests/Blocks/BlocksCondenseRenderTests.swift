import Foundation
import SwiftUI
import Testing
import HoursCore
@testable import HoursUI

/// W25 renders → `$TMPDIR/hours-condensed-*.png`: the condensed Blocks mode (compact stats, the
/// breakdowns in the side panel, the column filling the window) at 1440×900 and 1180×760, light and
/// dark, with nothing selected (`<size>-<scheme>`) and the afternoon block selected
/// (`<size>-<scheme>-selected`). Plus `timeline-1440x900-light`: Timeline mode, which W25 leaves alone.
@Suite(.serialized) @MainActor struct BlocksCondenseRenderTests {
    typealias Base = BlocksRenderTests
    static let data = DayData.fixture()
    static let sizes = [CGSize(width: 1440, height: 900), CGSize(width: 1180, height: 760)]

    static func name(_ size: CGSize) -> String { "\(Int(size.width))x\(Int(size.height))" }

    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func condensed(_ scheme: ColorScheme, _ selected: Bool) throws {
        let preview = BlocksPreview(thresholdMin: 10, selectedMs: selected ? Base.at(Self.data, 16, 30) : nil)
        for size in Self.sizes {
            let name = "\(Self.name(size))-\(scheme == .dark ? "dark" : "light")\(selected ? "-selected" : "")"
            let path = try BlocksRender.png(Base.view(Self.data, preview), size: size, scheme: scheme, name: name,
                                            prefix: "hours-condensed-")
            print("BlocksRender: \(path)")
        }
    }

    /// A tall window, so the whole side panel (all four sections, the editing hint) shows unscrolled.
    @Test func tallPanel() throws {
        let path = try BlocksRender.png(Base.view(Self.data, BlocksPreview(thresholdMin: 10)), size: CGSize(width: 1440, height: 1640),
                                        scheme: .light, name: "1440x1640-light", prefix: "hours-condensed-")
        print("BlocksRender: \(path)")
    }

    @Test func timelineUnchanged() throws {
        let defaults = try #require(UserDefaults(suiteName: "hours-condense-render-\(UUID().uuidString)"))
        defaults.set(DayMode.timeline.rawValue, forKey: DayMode.storageKey)
        let view = DayView(data: Self.data, scrollable: false).defaultAppStorage(defaults)
        let path = try BlocksRender.png(view, size: Self.sizes[0], scheme: .light, name: "timeline-1440x900-light",
                                        prefix: "hours-condensed-")
        print("BlocksRender: \(path)")
    }
}
