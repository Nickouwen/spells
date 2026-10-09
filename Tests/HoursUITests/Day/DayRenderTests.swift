import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import Testing
import HoursCore
@testable import HoursUI

/// Runtime render of the Day view to `$TMPDIR/hours-day-*.png` (1280×860 pt @2x) for visual review,
/// plus the render-time budget.
@Suite(.serialized) struct DayRenderTests {
    static let size = CGSize(width: 1280, height: 860)

    @MainActor
    static func render(_ data: DayData, scheme: ColorScheme, hoverMs: Int64? = nil) -> CGImage? {
        let view = DayView(data: data, scrollable: false, previewHoverMs: hoverMs)
            .frame(width: size.width, height: size.height, alignment: .top)
            .environment(\.colorScheme, scheme)
        let r = ImageRenderer(content: view)
        r.scale = 2
        return r.cgImage
    }

    @MainActor
    static func write(_ image: CGImage, _ name: String) throws -> String {
        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("hours-day-\(name).png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url.path
    }

    @MainActor
    @Test(arguments: ["light", "dark", "empty", "today"])
    func renderPNG(_ name: String) throws {
        let today = LocalDate(year: 2026, month: 10, day: 5)
        let data: DayData = switch name {
        case "empty": .fixture(date: LocalDate(year: 2026, month: 10, day: 3), empty: true)
        case "today": .fixture(date: today, now: (14, 32))
        default: .fixture()
        }
        // The "today" render pins a hover so the tooltip is reviewable too.
        let hover = name == "today" ? data.bounds.lowerBound + Int64((10 - 4) * 60 + 14) * 60_000 : nil
        let image = try #require(Self.render(data, scheme: name == "dark" ? .dark : .light, hoverMs: hover))
        #expect(image.width == Int(Self.size.width) * 2 && image.height == Int(Self.size.height) * 2)
        print("DayView (\(name)): \(try Self.write(image, name))")
    }

    /// A fixture day renders in < 100 ms (after one warm-up render that pays SwiftUI/Charts first-use cost).
    @MainActor
    @Test func fixtureDayRendersUnder100ms() throws {
        _ = Self.render(.fixture(date: LocalDate(year: 2026, month: 9, day: 29)), scheme: .light)
        let data = DayData.fixture()
        var best = Duration.seconds(10)
        for _ in 0..<3 {
            let t = ContinuousClock.now
            _ = try #require(Self.render(data, scheme: .light))
            best = min(best, ContinuousClock.now - t)
        }
        print("DayView render: \(best)")
        if perfEnforced { #expect(best < .milliseconds(100)) }
    }
}
