import Foundation
import CoreGraphics
import HoursCore

/// One drawable block on the timeline: a span, a level-of-detail merge of several, or a gap
/// where the tracker wasn't running (≠ idle: idle is recorded, a gap is not).
struct DayTimelineItem: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case active, idle, gap }
    var startMs: Int64
    var endMs: Int64
    var kind: Kind
    var categoryId: Int64?
    var slot: Int?
    /// First underlying span (index into `DayData.spans`); nil for gaps.
    var spanIndex: Int?
    /// Spans merged into this block.
    var count: Int
    /// Summed duration of the merged spans (LOD keeps this exact; gaps between members aren't counted).
    var durationMs: Int64
    /// Largest member's duration — decides the colour of a mixed LOD block.
    var dominantMs: Int64
    var edited: Bool
    var isMeeting: Bool
    var isLive: Bool
    var isManual: Bool
}

enum DayTimeline {
    /// VoiceOver label for the whole timeline; the blocks follow as its child elements.
    static func accessibilitySummary(_ d: DayData, items: [DayTimelineItem]) -> String {
        guard let a = d.metrics.firstActivityMs, let b = d.metrics.lastActivityMs else { return "Timeline, nothing tracked" }
        let gaps = items.filter { $0.kind == .gap }.count
        let sessions = d.metrics.focusSessions.count
        var s = "Timeline, \(Fmt.clock(ms: a, timeZone: d.timeZone)) to \(Fmt.clock(ms: b, timeZone: d.timeZone)), "
            + "\(Fmt.durationSpoken(ms: d.metrics.trackedMs)) tracked, \(sessions) focus session\(sessions == 1 ? "" : "s")"
        if gaps > 0 { s += ", \(gaps) tracker gap\(gaps == 1 ? "" : "s")" }
        return s
    }

    /// Gaps shorter than this between spans are not drawn as "tracker off".
    static let minGapMs: Int64 = 60_000

    /// Spans → blocks, plus gap blocks between consecutive spans. Excluded categories (lock screen)
    /// draw like idle: recorded, but not activity.
    static func items(_ data: DayData) -> [DayTimelineItem] {
        var catById: [Int64: HoursCore.Category] = [:]
        for c in data.categories { catById[c.id] = c }
        var out: [DayTimelineItem] = []
        out.reserveCapacity(data.spans.count + 8)
        var lastEnd: Int64?
        for (i, c) in data.spans.enumerated() {
            let s = c.span
            if let lastEnd, s.startMs - lastEnd >= minGapMs {
                out.append(DayTimelineItem(startMs: lastEnd, endMs: s.startMs, kind: .gap, categoryId: nil, slot: nil,
                                           spanIndex: nil, count: 0, durationMs: s.startMs - lastEnd, dominantMs: 0,
                                           edited: false, isMeeting: false, isLive: false, isManual: false))
            }
            let cat = c.categoryId.flatMap { catById[$0] }
            let idle = s.kind == .idle || cat?.behavior == .exclude
            out.append(DayTimelineItem(startMs: s.startMs, endMs: s.endMs, kind: idle ? .idle : .active,
                                       categoryId: idle ? nil : cat?.id, slot: idle ? nil : cat?.colorSlot,
                                       spanIndex: i, count: 1, durationMs: s.durationMs, dominantMs: s.durationMs,
                                       edited: !s.editSeqs.isEmpty, isMeeting: cat?.behavior == .meeting,
                                       isLive: s.rawSeq == 0 && data.isToday, isManual: s.source == .manual))
            lastEnd = max(lastEnd ?? s.endMs, s.endMs)
        }
        return out
    }

    /// Level of detail: at `msPerPoint`, blocks narrower than `minWidth` merge into an adjacent
    /// block of the same category; two neighbouring sub-minimum blocks of different categories
    /// merge into one coloured by its largest member. Gaps never merge. Σ durationMs is preserved.
    static func lod(_ items: [DayTimelineItem], msPerPoint: Double, minWidth: CGFloat = 3) -> [DayTimelineItem] {
        guard msPerPoint > 0 else { return items }
        let minMs = Int64(Double(minWidth) * msPerPoint)
        let touchMs = Int64(msPerPoint)
        var out: [DayTimelineItem] = []
        out.reserveCapacity(min(items.count, 512))
        for item in items {
            guard var last = out.last, last.kind == item.kind, item.kind != .gap,
                  item.startMs - last.endMs <= touchMs else { out.append(item); continue }
            let lastTiny = last.endMs - last.startMs < minMs, itemTiny = item.endMs - item.startMs < minMs
            let sameCategory = last.categoryId == item.categoryId
            guard (sameCategory && (lastTiny || itemTiny)) || (lastTiny && itemTiny) else { out.append(item); continue }
            if item.dominantMs > last.dominantMs {
                last.categoryId = item.categoryId; last.slot = item.slot; last.dominantMs = item.dominantMs
                last.isMeeting = item.isMeeting
            }
            last.endMs = max(last.endMs, item.endMs)
            last.count += item.count
            last.durationMs += item.durationMs
            last.edited = last.edited || item.edited
            last.isLive = last.isLive || item.isLive
            last.isManual = last.isManual && item.isManual
            out[out.count - 1] = last
        }
        return out
    }

    /// Index of the span containing `ms` (start ≤ ms < end), by binary search over start-sorted spans.
    static func spanIndex(at ms: Int64, in spans: [ClassifiedSpan]) -> Int? {
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].span.startMs <= ms { lo = mid + 1 } else { hi = mid }
        }
        let i = lo - 1
        guard i >= 0, ms < spans[i].span.endMs else { return nil }
        return i
    }

    /// Index of the block containing `ms`, same search over blocks.
    static func itemIndex(at ms: Int64, in items: [DayTimelineItem]) -> Int? {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].startMs <= ms { lo = mid + 1 } else { hi = mid }
        }
        let i = lo - 1
        guard i >= 0, ms < items[i].endMs else { return nil }
        return i
    }

    /// Runs of the same project over adjacent spans (gaps ≤ 2 min bridge). Unassigned time is skipped.
    static func projectRuns(_ spans: [ClassifiedSpan]) -> [(projectId: Int64, startMs: Int64, endMs: Int64)] {
        var out: [(projectId: Int64, startMs: Int64, endMs: Int64)] = []
        for c in spans where c.span.kind == .active {
            guard let p = c.projectId else { continue }
            if let last = out.last, last.projectId == p, c.span.startMs - last.endMs <= 120_000 {
                out[out.count - 1].endMs = max(last.endMs, c.span.endMs)
            } else {
                out.append((p, c.span.startMs, c.span.endMs))
            }
        }
        return out
    }

    /// 0 → 1 as an animated counter `v` closes on `target` (a change steps the target by 1).
    static func tweenProgress(_ v: Double, to target: Double) -> Double { 1 - min(max(target - v, 0), 1) }

    /// Block opacity under the legend filter (`.some(id)` dims every other category), crossfading
    /// from the previous filter `from` as `t` goes 0 → 1.
    static func filterOpacity(_ categoryId: Int64?, from: Int64??, to: Int64??, t: Double) -> Double {
        func op(_ h: Int64??) -> Double { h.map { $0 == categoryId ? 1 : 0.22 } ?? 1 }
        return op(from) * (1 - t) + op(to) * t
    }
}

/// The visible slice of the day: a start and a length, independent of pixel width.
struct DayWindow: Hashable, Sendable {
    static let minLengthMs: Int64 = 15 * 60_000

    var startMs: Int64
    var lengthMs: Int64

    /// First-to-last activity ±30 min, clamped to the day; the whole day when it's empty.
    static func fit(_ data: DayData) -> DayWindow {
        let b = data.bounds
        guard let first = data.spans.first?.span.startMs, let last = data.spans.map(\.span.endMs).max() else {
            let nine = b.lowerBound + 4 * 3_600_000   // 08:00–18:00 skeleton for an empty day
            return DayWindow(startMs: nine, lengthMs: 10 * 3_600_000).clamped(to: b)
        }
        let end = max(last, data.nowMs ?? last)
        let pad: Int64 = 30 * 60_000
        return DayWindow(startMs: first - pad, lengthMs: end - first + 2 * pad).clamped(to: b)
    }

    /// Click-to-zoom: `r` centred with a third of its length (≥ 2 min) either side, at least 15 min.
    static func focus(_ r: Range<Int64>, in b: Range<Int64>) -> DayWindow {
        let len = max(r.upperBound - r.lowerBound + 2 * max((r.upperBound - r.lowerBound) / 3, 2 * 60_000), minLengthMs)
        return DayWindow(startMs: (r.lowerBound + r.upperBound) / 2 - len / 2, lengthMs: len).clamped(to: b)
    }

    func clamped(to b: Range<Int64>) -> DayWindow {
        let total = b.upperBound - b.lowerBound
        let len = min(max(lengthMs, Self.minLengthMs), total)
        let start = min(max(startMs, b.lowerBound), b.upperBound - len)
        return DayWindow(startMs: start, lengthMs: len)
    }

    /// Zoom by `factor` (> 1 = in) keeping `anchorMs` under the same x.
    func zoomed(by factor: Double, anchorMs: Int64, in b: Range<Int64>) -> DayWindow {
        let newLen = Int64(Double(lengthMs) / factor)
        let frac = Double(anchorMs - startMs) / Double(lengthMs)
        return DayWindow(startMs: anchorMs - Int64(frac * Double(newLen)), lengthMs: newLen).clamped(to: b)
    }

    func panned(byMs d: Int64, in b: Range<Int64>) -> DayWindow {
        DayWindow(startMs: startMs + d, lengthMs: lengthMs).clamped(to: b)
    }
}

/// Window × pixel width: the ms ↔ x mapping every draw and hit-test goes through.
struct DayViewport {
    var window: DayWindow
    var width: CGFloat

    var msPerPoint: Double { Double(window.lengthMs) / Double(max(width, 1)) }
    var endMs: Int64 { window.startMs + window.lengthMs }

    func x(_ ms: Int64) -> CGFloat { CGFloat(Double(ms - window.startMs) / msPerPoint) }
    func ms(atX x: CGFloat) -> Int64 { window.startMs + Int64(Double(x) * msPerPoint) }

    /// The span under `x`, or nil (gap / outside activity).
    func spanIndex(atX x: CGFloat, in spans: [ClassifiedSpan]) -> Int? {
        DayTimeline.spanIndex(at: ms(atX: x), in: spans)
    }

    /// Hour-grid ticks: the smallest step that keeps labels ≥ `minSpacing` apart, aligned to local time.
    func ticks(tz: TimeZone, minSpacing: CGFloat = 64) -> (stepMs: Int64, ms: [Int64]) {
        let steps: [Int64] = [5, 10, 15, 30, 60, 120, 180, 240].map { $0 * 60_000 }
        let step = steps.first { CGFloat(Double($0) / msPerPoint) >= minSpacing } ?? steps.last!
        let off = Int64(tz.secondsFromGMT(for: Date(timeIntervalSince1970: Double(window.startMs) / 1000))) * 1000
        var t = ((window.startMs + off) / step) * step - off
        if t < window.startMs { t += step }
        var out: [Int64] = []
        while t <= endMs { out.append(t); t += step }
        return (step, out)
    }
}
