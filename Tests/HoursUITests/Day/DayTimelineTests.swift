import Foundation
import Testing
import SwiftUI
import HoursCore
@testable import HoursUI

@Suite struct DayTimelineTests {
    static let t0: Int64 = 1_790_000_000_000   // arbitrary instant; "09:00" in these tests
    static let min: Int64 = 60_000

    static func span(_ a: Int64, _ b: Int64, _ app: String, cat: Int64? = ClassifySeed.coding) -> ClassifiedSpan {
        ClassifiedSpan(span: EffectiveSpan(startMs: t0 + a * min, endMs: t0 + b * min, tzId: "UTC", kind: .active,
                                           bundleId: nil, appName: app, title: nil, url: nil, rawSeq: 1),
                       categoryId: cat, projectId: nil)
    }

    /// 09:00–09:30 A, 09:30–10:00 B, tracker off 10:00–10:30, 10:30–11:00 C.
    static let spans = [span(0, 30, "A"), span(30, 60, "B"), span(90, 120, "C")]

    static func data(_ spans: [ClassifiedSpan]) -> DayData {
        DayData.assemble(date: LocalDate(year: 2026, month: 9, day: 1), timeZone: .gmt,
                         bounds: (t0 - 5 * 60 * min)..<(t0 + 19 * 60 * min), spans: spans,
                         categories: ClassifySeed.categories, projects: [], goal: nil, nowMs: nil, rawWorkMs: nil,
                         tracker: .unknown)
    }

    @Test func hitTestByX() {
        // 2 h over 1200 pt → 6 s per point.
        let vp = DayViewport(window: DayWindow(startMs: Self.t0, lengthMs: 120 * Self.min), width: 1200)
        let cases: [(CGFloat, Int?)] = [
            (0, 0), (150, 0), (299.9, 0),          // A
            (300, 1), (599, 1),                    // B starts exactly at 09:30
            (600, nil), (650, nil), (899, nil),    // the gap: no span
            (900, 2), (1199, 2),                   // C
            (1200, nil), (-5, nil),                // past the end (half-open) / before the start
        ]
        for (x, want) in cases {
            #expect(vp.spanIndex(atX: x, in: Self.spans) == want, "x = \(x)")
        }
        #expect(vp.x(Self.t0 + 30 * Self.min) == 300)
        #expect(vp.ms(atX: 900) == Self.t0 + 90 * Self.min)
    }

    @Test func hitTestAfterZoomAndPan() {
        let b = (Self.t0 - 9 * 60 * Self.min)..<(Self.t0 + 15 * 60 * Self.min)
        let w = DayWindow(startMs: Self.t0, lengthMs: 120 * Self.min)
            .zoomed(by: 2, anchorMs: Self.t0 + 30 * Self.min, in: b)   // 1 h window; 09:30 stays at x = 300
        let vp = DayViewport(window: w, width: 1200)
        #expect(w.lengthMs == 60 * Self.min)
        #expect(vp.x(Self.t0 + 30 * Self.min) == 300)
        #expect(vp.spanIndex(atX: 299, in: Self.spans) == 0)
        #expect(vp.spanIndex(atX: 301, in: Self.spans) == 1)
        // Zoom clamps to 15 min and to the day; pan clamps to the day.
        #expect(w.zoomed(by: 1000, anchorMs: Self.t0, in: b).lengthMs == DayWindow.minLengthMs)
        let out = w.zoomed(by: 0.001, anchorMs: Self.t0, in: b)
        #expect(out.startMs == b.lowerBound && out.lengthMs == b.upperBound - b.lowerBound)
        #expect(w.panned(byMs: -100 * 60 * Self.min, in: b).startMs == b.lowerBound)
    }

    @Test func clickZoomFramesTheSpan() {
        let b = (Self.t0 - 9 * 60 * Self.min)..<(Self.t0 + 15 * 60 * Self.min)
        // 30 min span → 10 min either side.
        let w = DayWindow.focus(Self.t0..<(Self.t0 + 30 * Self.min), in: b)
        #expect(w.startMs == Self.t0 - 10 * Self.min && w.lengthMs == 50 * Self.min)
        // 1 min span → centred in the 15 min minimum.
        let tiny = DayWindow.focus(Self.t0..<(Self.t0 + Self.min), in: b)
        #expect(tiny.lengthMs == DayWindow.minLengthMs && tiny.startMs + tiny.lengthMs / 2 == Self.t0 + Self.min / 2)
        // At the day's edge → clamped inside it.
        #expect(DayWindow.focus(b.lowerBound..<(b.lowerBound + Self.min), in: b).startMs == b.lowerBound)
    }

    @Test func gapsAreItems() {
        let items = DayTimeline.items(Self.data(Self.spans))
        #expect(items.map(\.kind) == [.active, .active, .gap, .active])
        #expect(items[2].durationMs == 30 * Self.min)
    }

    @Test func lodKeepsTotalDuration() {
        let items = DayTimeline.items(DayData.fixture())
        let total = items.reduce(0) { $0 + $1.durationMs }
        let spanCount = items.filter { $0.kind != .gap }.count
        for msPerPoint in [500.0, 6_000, 30_000, 120_000, 600_000] {
            let merged = DayTimeline.lod(items, msPerPoint: msPerPoint)
            #expect(merged.reduce(0) { $0 + $1.durationMs } == total, "msPerPoint \(msPerPoint)")
            #expect(merged.filter { $0.kind != .gap }.reduce(0) { $0 + $1.count } == spanCount)
            #expect(merged.filter { $0.kind == .gap }.count == items.filter { $0.kind == .gap }.count)
            #expect(zip(merged, merged.dropFirst()).allSatisfy { $0.endMs <= $1.startMs })
        }
        #expect(DayTimeline.lod(items, msPerPoint: 600_000).count < items.count / 3)
        #expect(DayTimeline.lod(items, msPerPoint: 500).count == items.count)   // zoomed in: nothing merges
    }

    @Test func lodMergesTinyAlternatingSpans() {
        // 2000 alternating 30 s spans (the "flicker" day). At 1 min/pt each is 0.5 pt wide.
        let spans = (0..<2000).map { i -> ClassifiedSpan in
            let a = Self.t0 + Int64(i) * 30_000
            return ClassifiedSpan(span: EffectiveSpan(startMs: a, endMs: a + 30_000, tzId: "UTC", kind: .active, bundleId: nil,
                                                      appName: i % 2 == 0 ? "A" : "B", title: nil, url: nil, rawSeq: Int64(i + 1)),
                                  categoryId: i % 2 == 0 ? ClassifySeed.coding : ClassifySeed.communication, projectId: nil)
        }
        let merged = DayTimeline.lod(DayTimeline.items(Self.data(spans)), msPerPoint: 60_000)
        #expect(merged.count <= 300)
        #expect(merged.reduce(0) { $0 + $1.durationMs } == 2000 * 30_000)
    }

    @Test func ticksAlignToLocalHours() {
        let tz = TimeZone(identifier: "Asia/Kolkata")!   // +05:30, so local hours aren't UTC hours
        let start: Int64 = 1_790_000_123_000
        let vp = DayViewport(window: DayWindow(startMs: start, lengthMs: 8 * 60 * Self.min), width: 1000)
        let (step, ticks) = vp.ticks(tz: tz)
        #expect(step == 60 * Self.min)
        #expect(!ticks.isEmpty && ticks.allSatisfy { Fmt.clock(ms: $0, timeZone: tz).hasSuffix(":00") })
        #expect(ticks.first! >= start && ticks.first! - start < step)
    }

    /// The Canvas wrapper draws the interpolated window, filter crossfade and flash alpha mid-tween.
    @MainActor @Test func tweenCanvasInterpolates() {
        let from = DayWindow(startMs: Self.t0, lengthMs: 120 * Self.min)
        // Rest: the step equals the target, so no fade is running.
        var v = DayTweenCanvas(window: from, filterStep: 3, filterTarget: 3, flashStep: 7, flashTarget: 7) { _, _, _ in }
        #expect(v.filterProgress == 1 && v.flashAlpha == 0)
        // Halfway from (t0, 2 h) to (t0 + 1 h, 1 h); each counter has stepped once and is halfway there.
        v.filterTarget = 4; v.flashTarget = 8
        v.animatableData = .init(.init(Double(Self.t0 + 30 * Self.min), Double(90 * Self.min)), .init(3.5, 7.25))
        #expect(v.window == DayWindow(startMs: Self.t0 + 30 * Self.min, lengthMs: 90 * Self.min))
        #expect(v.filterProgress == 0.5)
        #expect(v.flashAlpha == 0.75)
    }

    /// The edit overlay is built from the interpolated window, so its handles move with the blocks.
    @MainActor @Test func tweenOverlayGetsInterpolatedViewport() {
        var seen: DayViewport?
        var v = DayTweenWindow(window: DayWindow(startMs: Self.t0, lengthMs: 120 * Self.min)) { w in
            seen = DayViewport(window: w, width: 1200)
            return EmptyView()
        }
        v.animatableData = .init(Double(Self.t0 + 30 * Self.min), Double(90 * Self.min))
        _ = v.body
        #expect(seen?.window == DayWindow(startMs: Self.t0 + 30 * Self.min, lengthMs: 90 * Self.min))
        #expect(seen?.x(Self.t0 + 30 * Self.min) == 0)
    }

    /// Grips split into a window-independent candidate scan and a per-frame window filter.
    @MainActor @Test func gripCandidatesThenWindowFilter() {
        let d = Self.data(Self.spans)
        let boundary = Self.t0 + 30 * Self.min   // A|B touch; B→C is a tracker gap, not a grip
        #expect(EditOverlay.gripCandidates(d, selection: EditSelection()) == [1])
        #expect(EditOverlay.gripCandidates(d, selection: EditSelection([Self.t0..<boundary])).isEmpty)   // a handle, not a grip
        let vp = DayViewport(window: DayWindow(startMs: Self.t0, lengthMs: 120 * Self.min), width: 1200)
        #expect(EditOverlay.grips(d, candidates: [1], vp: vp) == [boundary])
        #expect(EditOverlay.grips(d, selection: EditSelection(), vp: vp) == [boundary])
        // Outside the window, or neighbours under 24 pt wide (whole day in 100 pt): no grip.
        #expect(EditOverlay.grips(d, candidates: [1], vp: DayViewport(window: DayWindow(startMs: boundary, lengthMs: 60 * Self.min), width: 1200)).isEmpty)
        #expect(EditOverlay.grips(d, candidates: [1], vp: DayViewport(window: DayWindow(startMs: Self.t0, lengthMs: 24 * 60 * Self.min), width: 100)).isEmpty)
    }

    @Test func filterOpacityCrossfades() {
        let a: Int64? = 1, b: Int64? = 2
        // Off → A: other categories dim, A stays.
        #expect(DayTimeline.filterOpacity(b, from: nil, to: .some(a), t: 0) == 1)
        #expect(abs(DayTimeline.filterOpacity(b, from: nil, to: .some(a), t: 0.5) - 0.61) < 1e-9)
        #expect(DayTimeline.filterOpacity(a, from: nil, to: .some(a), t: 0.5) == 1)
        // A → B: A fades down while B comes up; Uncategorized (nil id) stays dim.
        #expect(DayTimeline.filterOpacity(a, from: .some(a), to: .some(b), t: 1) == 0.22)
        #expect(DayTimeline.filterOpacity(b, from: .some(a), to: .some(b), t: 1) == 1)
        #expect(DayTimeline.filterOpacity(nil, from: .some(a), to: .some(b), t: 0.5) == 0.22)
        // `.some(nil)` filters to Uncategorized.
        #expect(DayTimeline.filterOpacity(nil, from: nil, to: .some(nil), t: 1) == 1)
        // A counter overshooting its target (an interrupted fade) clamps.
        #expect(DayTimeline.tweenProgress(2.5, to: 4) == 0)
        #expect(DayTimeline.tweenProgress(4, to: 4) == 1)
    }
}
