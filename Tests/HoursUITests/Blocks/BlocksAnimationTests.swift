import Foundation
import SwiftUI
import Testing
import HoursCore
@testable import HoursUI

/// The Blocks animations' interpolated values: the zoom glide's scale (and the scroll offset it
/// keeps in step with), the resize settle's edge, and the edit flash's fade.
@Suite @MainActor struct BlocksAnimationTests {
    typealias R = BlocksResizeTests

    /// Mid-glide, the column draws (and lays out) at the interpolated scale.
    @Test func columnInterpolatesItsScale() {
        let d = DayData.fixture()
        let day = MetricsBlocks.day(spans: d.spans, categories: d.categories, breakThresholdMs: 10 * 60_000)
        let g1 = BlocksGeometry.day(bounds: d.bounds, windowHours: 18), g4 = BlocksGeometry.day(bounds: d.bounds, windowHours: 18, zoom: 4)
        var col = BlocksColumn(data: d, day: day, geo: g1, thresholdMs: 10 * 60_000, editable: false,
                               selectedMs: .constant(nil), commit: { _ in })
        col.animatableData = (g1.pxPerHour + g4.pxPerHour) / 2
        #expect(col.geo.pxPerHour == 2.5 * g1.pxPerHour)
        let noon = d.bounds.lowerBound + 8 * BlocksGeometry.hourMs
        #expect(abs(col.geo.y(noon) - (g1.y(noon) + g4.y(noon)) / 2) < 0.001)
        #expect(abs(col.geo.height - (g1.height + g4.height) / 2) < 0.001)
    }

    /// Why scale and scroll stay in step: the centring offset is linear in the scale, so the scroll's
    /// interpolation between the two offsets is the offset at the interpolated scale.
    @Test func zoomOffsetIsLinearInScale() {
        let d = DayData.fixture()
        let r = d.bounds.lowerBound + 9 * BlocksGeometry.hourMs..<d.bounds.lowerBound + 10 * BlocksGeometry.hourMs
        let g1 = BlocksGeometry.day(bounds: d.bounds, windowHours: 18, zoom: 1.5)
        let g6 = BlocksGeometry.day(bounds: d.bounds, windowHours: 18, zoom: 6)
        var mid = g1
        mid.pxPerHour = (g1.pxPerHour + g6.pxPerHour) / 2
        #expect(abs(mid.offset(centring: r) - (g1.offset(centring: r) + g6.offset(centring: r)) / 2) < 1)
    }

    /// The glide's drawing shift: the old offset at the old scale, none at the new one, and in
    /// between the anchor (here the top time) stays at the same place on screen.
    @Test func glideShiftKeepsTheAnchorPut() {
        let d = DayData.fixture()
        let top = d.bounds.lowerBound + 2 * BlocksGeometry.hourMs   // unclamped at both scales
        let g1 = BlocksGeometry.day(bounds: d.bounds, windowHours: 18), g4 = BlocksGeometry.day(bounds: d.bounds, windowHours: 18, zoom: 4)
        let glide = BlocksGeometry.Glide(fromPx: g1.pxPerHour, fromY: g1.offset(top: top), toPx: g4.pxPerHour, toY: g4.offset(top: top))
        #expect(glide.shift(at: g1.pxPerHour) == glide.toY - glide.fromY)
        #expect(glide.shift(at: g4.pxPerHour) == 0)
        var mid = g1
        mid.pxPerHour = (g1.pxPerHour + g4.pxPerHour) / 2
        // On screen = content y + shift − real offset (toY): the top time stays at the top pad.
        #expect(abs(mid.y(top) + glide.shift(at: mid.pxPerHour) - glide.toY - BlocksGeometry.topPad) < 0.5)
    }

    /// The settle canvas draws its edge at the interpolated time.
    @Test func canvasInterpolatesTheSettlingEdge() {
        var c = BlocksCanvas(edgeMs: 1_000) { _, _, _ in }
        c.animatableData = 1_000 + 0.5 * (61_000 - 1_000)
        #expect(c.edge == 31_000)
    }

    /// A merge's grip is the dragged-to edge of the gap; it settles at the neighbour's far edge.
    @Test func settleRunsFromTheGripToTheRegroupedEdge() throws {
        let s = try R.Scene()
        let d = BlocksDrag(blockStartMs: s.blocks[1].startMs, edge: .upper, ms: R.at(12, 40))
        let p = try #require(BlocksResize.proposal(s.blocks[1], edge: .upper, to: d.ms, blocks: s.blocks, data: s.data,
                                                   thresholdMs: R.threshold))
        #expect(BlocksResize.grip(p, drag: d) == R.at(12, 30))
        #expect(p.extent.upperBound == R.at(13))
        #expect(BlocksResize.grip(nil, drag: d) == d.ms)
        // Mid-settle: the block's bottom edge at the settling time; the top edge stays.
        let b = R.at(11)..<R.at(12, 30)
        #expect(BlocksResize.moving(b, .upper, to: R.at(12, 45)) == R.at(11)..<R.at(12, 45))
        #expect(BlocksResize.moving(b, .lower, to: R.at(10, 50)) == R.at(10, 50)..<R.at(12, 30))
        #expect(BlocksResize.moving(b, .lower, to: R.at(13)) == R.at(12, 30) - 1..<R.at(12, 30))   // never inverted
    }

    /// The edit flash: full ink, fading out (ease-out: past half by mid-way) over `Theme.Motion.flash`.
    @Test func flashFadesOut() {
        let t = KeyframeTimeline(initialValue: 0.0) { BlocksColumn.flashFade }
        #expect(t.duration == Theme.Motion.flash)
        #expect(t.value(time: 0) == 1)
        #expect(t.value(time: Theme.Motion.flash / 2) < 0.5)
        #expect(t.value(time: Theme.Motion.flash) == 0)
    }
}
