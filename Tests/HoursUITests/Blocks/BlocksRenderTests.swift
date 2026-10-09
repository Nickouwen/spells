import Foundation
import AppKit
import SwiftUI
import Testing
import HoursCore
@testable import HoursUI

/// Runtime renders of the Blocks day view → `$TMPDIR/hours-blocks-*.png` at 1440×900:
/// - `t5-{light,dark}`: Thu 1 Oct fixture, breaks ≥ 5 min, the afternoon block selected (detail panel)
/// - `t30-{light,dark}`: same day, breaks ≥ 30 min (the 25-min tracker gap joins a block), nothing selected
/// - `drag-light`: mid-drag of the morning block's bottom edge into the lunch break (hot handle, ghost extent)
/// - `today-light`: "today" at 14:32 with the now line and the live block
@Suite(.serialized) @MainActor struct BlocksRenderTests {
    static let size = CGSize(width: 1440, height: 900)
    static let data = DayData.fixture()

    static func at(_ d: DayData, _ h: Int, _ m: Int = 0) -> Int64 {
        d.bounds.lowerBound + Int64((h - Hours.defaultDayStartHour) * 60 + m) * 60_000
    }

    static var hooks: DayEditHooks {
        DayEditHooks(overlay: { _ in AnyView(EmptyView()) }, laneDrag: { _, _, _, _ in }, hover: { _, _ in },
                     contextMenu: { _ in AnyView(EmptyView()) })
    }

    static func view(_ d: DayData, _ preview: BlocksPreview) -> some View {
        DayView(data: d, onNavigate: { _ in }, selectedRange: .constant(nil), editHooks: hooks, scrollable: false,
                blocksPreview: preview)
    }

    static func blocks(_ d: DayData, _ min: Int) -> [WorkBlock] {
        MetricsBlocks.compute(spans: d.spans, categories: d.categories, breakThresholdMs: Int64(min) * 60_000)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func threshold5(_ scheme: ColorScheme) throws {
        #expect(Self.blocks(Self.data, 5).count == 3)   // morning · after lunch · after the tracker gap
        let preview = BlocksPreview(thresholdMin: 5, selectedMs: Self.at(Self.data, 16, 30))
        let path = try BlocksRender.png(Self.view(Self.data, preview), size: Self.size, scheme: scheme,
                                        name: "t5-\(scheme == .dark ? "dark" : "light")")
        print("BlocksRender: \(path)")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func threshold30(_ scheme: ColorScheme) throws {
        #expect(Self.blocks(Self.data, 30).count == 2)
        let path = try BlocksRender.png(Self.view(Self.data, BlocksPreview(thresholdMin: 30)), size: Self.size, scheme: scheme,
                                        name: "t30-\(scheme == .dark ? "dark" : "light")")
        print("BlocksRender: \(path)")
    }

    @Test func midDrag() throws {
        let b = try #require(Self.blocks(Self.data, 10).first)
        let preview = BlocksPreview(thresholdMin: 10, hoverMs: b.endMs,
                                    drag: BlocksDrag(blockStartMs: b.startMs, edge: .upper, ms: Self.at(Self.data, 13, 15)))
        let path = try BlocksRender.png(Self.view(Self.data, preview), size: Self.size, scheme: .light, name: "drag-light")
        print("BlocksRender: \(path)")
    }

    @Test func today() throws {
        let d = DayData.fixture(date: LocalDate(year: 2026, month: 10, day: 5), now: (14, 32))
        let preview = BlocksPreview(thresholdMin: 10, selectedMs: Self.at(d, 14, 0))
        let path = try BlocksRender.png(Self.view(d, preview), size: Self.size, scheme: .light, name: "today-light")
        print("BlocksRender: \(path)")
    }
}

/// Renders through a real offscreen window (AppKit-backed controls draw too).
@MainActor
enum BlocksRender {
    static func png<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, name: String, prefix: String = "hours-blocks-") throws -> String {
        let root = view.frame(width: size.width, height: size.height, alignment: .top).environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        win.contentView = nil
        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)\(name).png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url.path
    }
}
