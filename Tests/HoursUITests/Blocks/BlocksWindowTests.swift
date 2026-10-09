import Foundation
import CoreGraphics
import Testing
import HoursCore
@testable import HoursUI

/// The 18-hour default viewport: the column's scale is fixed (visible height / 18 h), the whole 04:00
/// day scrolls, and the default scroll shows 06:00–24:00 unless the day's activity needs otherwise.
struct BlocksWindowTests {
    static let h: Int64 = 3_600_000, m: Int64 = 60_000
    /// Thu 1 Oct 2026, UTC: the store day is 04:00 → 04:00.
    static let day = LocalDate(year: 2026, month: 10, day: 1)
    static let tz = TimeZone(identifier: "UTC")!
    static let bounds = day.dayInterval(in: Self.tz)
    static func at(_ hh: Int, _ mm: Int = 0) -> Int64 { bounds.lowerBound + Int64((hh - 4) * 60 + mm) * m }
    static let six = BlocksGeometry.windowStart(day, timeZone: tz, minutes: 360)

    static func top(first: Int64?, last: Int64?, focus: Range<Int64>? = nil, hours: Int64 = 18) -> Int64 {
        BlocksGeometry.defaultTop(range: bounds, windowStart: six, windowMs: hours * h, first: first, last: last, focus: focus)
    }

    @Test func clickZoomFitsAndCentresTheBlock() {
        // A 1 h block on the 18 h view: 18 / 1.6 = 11.25×, capped at 6×; a 12 h block fits at 0.9375×.
        #expect(BlocksGeometry.focusZoom(Self.at(10)..<Self.at(11), windowHours: 18) == BlocksGeometry.maxZoom)
        #expect(BlocksGeometry.focusZoom(Self.at(8)..<Self.at(20), windowHours: 18) == 0.9375)
        // Centred: the block's midpoint sits at the viewport's middle.
        let geo = BlocksGeometry.day(bounds: Self.bounds, windowHours: 18, zoom: 6)
        let r = Self.at(12)..<Self.at(13)
        let mid = geo.offset(centring: r) + geo.viewport / 2
        #expect(abs(mid - geo.y(Self.at(12, 30))) < 1)
    }

    @Test func scaleIsVisibleHeightOver18Hours() {
        #expect(BlocksGeometry.pxPerHour(windowHours: 18, zoom: 1) * 18 + 2 * BlocksGeometry.topPad == BlocksGeometry.viewportHeight)
        let geo = BlocksGeometry.day(bounds: Self.bounds, windowHours: 18)
        #expect(geo.startMs == Self.bounds.lowerBound && geo.endMs == Self.bounds.upperBound)   // the whole day scrolls
        #expect(geo.y(Self.at(7)) - geo.y(Self.at(6)) == geo.pxPerHour)
        // Zoom scales it; zoom 1 (reset) is the 18 h scale again; a 12 h window is taller per hour.
        #expect(BlocksGeometry.day(bounds: Self.bounds, windowHours: 18, zoom: 2).pxPerHour == 2 * geo.pxPerHour)
        #expect(BlocksGeometry.day(bounds: Self.bounds, windowHours: 12).pxPerHour == geo.pxPerHour * 1.5)
        // Same scale on any day, whatever its activity: a block's height means the same duration.
        let other = LocalDate(year: 2026, month: 10, day: 3).dayInterval(in: Self.tz)
        #expect(BlocksGeometry.day(bounds: other, windowHours: 18).pxPerHour == geo.pxPerHour)
    }

    /// W25: the Day card fills the window, so the 18 h scale comes from the visible height it gets.
    @Test func scaleFollowsTheFilledHeight() {
        // 700 pt to fill − card chrome (2 × 16 padding + 26 header + 2 × 12 gaps + 16 legend = 98) = 602 visible.
        #expect(BlocksCard.chromeH == 98)
        #expect(BlocksCard.viewport(fillHeight: 700) == 602)
        #expect(BlocksCard.viewport(fillHeight: nil) == BlocksGeometry.viewportHeight)
        #expect(BlocksCard.viewport(fillHeight: 300) == BlocksGeometry.minViewportHeight)   // short window: the page scrolls
        let geo = BlocksGeometry.day(bounds: Self.bounds, windowHours: 18, viewport: 602)
        #expect(geo.pxPerHour == CGFloat(602 - 16) / 18)
        // 06:00 at the top → 24:00's line sits just above the bottom of the taller viewport.
        #expect(geo.y(Self.at(24)) - geo.offset(top: Self.at(6)) == 602 - BlocksGeometry.topPad)
        // The scroll clamp uses this viewport: the furthest offset leaves exactly 602 pt showing.
        #expect(geo.offset(top: Self.bounds.upperBound) == geo.height - 602)
    }

    @Test func windowStartIsLocalClock() {
        #expect(Self.six == Self.at(6))
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let laDay = Self.day.dayInterval(in: la)
        #expect(BlocksGeometry.windowStart(Self.day, timeZone: la, minutes: 360) == laDay.lowerBound + 2 * Self.h)
        // Before the 04:00 day start means the next morning.
        #expect(BlocksGeometry.windowStart(Self.day, timeZone: Self.tz, minutes: 60) == Self.at(25))
    }

    @Test func defaultScrollIs0600To2400() {
        #expect(Self.top(first: nil, last: nil) == Self.at(6))
        #expect(Self.top(first: Self.at(9, 5), last: Self.at(18, 40)) == Self.at(6))
        // Scroll offset puts 06:00's hour line just under the top pad, and 24:00's just above the bottom.
        let geo = BlocksGeometry.day(bounds: Self.bounds, windowHours: 18)
        let off = geo.offset(top: Self.at(6))
        #expect(off == 2 * geo.pxPerHour)
        #expect(geo.y(Self.at(24)) - off == BlocksGeometry.viewportHeight - BlocksGeometry.topPad)
    }

    /// Activity before 06:00: the first block is visible (an hour line above it), scale unchanged.
    @Test func earlyStartScrollsUp() {
        #expect(Self.top(first: Self.at(5, 10), last: Self.at(17)) == Self.at(4))
        #expect(Self.top(first: Self.at(5, 40), last: Self.at(17)) == Self.at(5))
    }

    /// Activity past midnight: scroll down to show it, but never past the first block.
    @Test func lateEndScrollsDownButKeepsFirstBlock() {
        #expect(Self.top(first: Self.at(10), last: Self.at(25, 30)) == Self.at(8))     // 08:00–02:00
        #expect(Self.top(first: Self.at(5, 30), last: Self.at(26)) == Self.at(5))      // first block wins
        #expect(Self.top(first: Self.at(11), last: Self.at(27, 59)) == Self.at(10))    // clamped: 10:00–04:00
    }

    /// Opening a block from the Week: it's scrolled into view.
    @Test func focusedBlockIsVisible() {
        #expect(Self.top(first: Self.at(5), last: Self.at(26), focus: Self.at(24, 30)..<Self.at(25, 30)) == Self.at(8))
        #expect(Self.top(first: Self.at(9), last: Self.at(18), focus: Self.at(9)..<Self.at(10)) == Self.at(6))
    }

    /// The live column draws the whole day: every block, wherever it is, is inside the content.
    @Test func cardGeometryCoversTheDay() {
        let d = DayData.fixture()
        let geo = BlocksGeometry.day(bounds: d.bounds, windowHours: 18)
        #expect(geo.height == 24 * geo.pxPerHour + 2 * BlocksGeometry.topPad)
        #expect(geo.height > BlocksGeometry.viewportHeight)
    }
}
