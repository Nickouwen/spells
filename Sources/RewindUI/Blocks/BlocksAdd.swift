import Foundation
import RewindCore

/// Dragging across empty time in the Blocks column (a break, a "not tracking" gap, the stretch
/// before the first block or after the last) adds a manual entry over that range. The drag is
/// confined to the gap it started in (the neighbouring blocks' edges, the day, the watermark) and
/// snapped like an edge drag; releasing opens the New entry form in the side panel with the range
/// filled in, and "Add entry" writes one `add`. Manual time replaces whatever is beneath it, which
/// in a gap is only idle, nothing, or a micro block.
enum BlocksAdd {
    /// "Add Entry Here" from the context menu: this long, from the pointer forward.
    static let defaultMs: Int64 = 30 * 60_000
    /// A shorter release is a slip, not an entry.
    static let minMs: Int64 = 60_000

    /// The empty stretch holding `ms`: between the blocks either side of it (micro blocks don't
    /// count: they sit in empty space as ticks), inside the day and up to the watermark. nil inside
    /// a block or past the watermark.
    static func gap(at ms: Int64, blocks: [WorkBlock], data: DayData, minBlockMs: Int64) -> Range<Int64>? {
        let real = blocks.filter { $0.wallMs >= minBlockMs }
        guard !real.contains(where: { $0.contains(ms) }) else { return nil }
        let lo = real.last { $0.endMs <= ms }?.endMs ?? data.bounds.lowerBound
        let hi = real.first { $0.startMs > ms }?.startMs ?? data.bounds.upperBound
        guard let r = EditPlanner.clamp(lo..<hi, data), r.contains(ms) else { return nil }
        return r
    }

    /// The drag's range: anchor to pointer in either direction, clamped to `gap`; nil under `minMs`.
    static func range(from anchor: Int64, to ms: Int64, in gap: Range<Int64>) -> Range<Int64>? {
        let lo = max(min(anchor, ms), gap.lowerBound), hi = min(max(anchor, ms), gap.upperBound)
        return hi - lo >= minMs ? lo..<hi : nil
    }

    /// Snap targets inside a gap: its edges (the neighbouring blocks), now, and the local hour and
    /// half-hour marks.
    static func targets(_ gap: Range<Int64>, data: DayData) -> [Int64] {
        var t = [gap.lowerBound, gap.upperBound]
        if let n = data.nowMs { t.append(n) }
        var h = BlocksGeometry.hourFloor(data.bounds.lowerBound, data.timeZone)
        while h <= data.bounds.upperBound { t += [h, h + 1_800_000]; h += 3_600_000 }
        return t
    }

    /// `defaultMs` from `ms` forward, fitted into `gap`: moved back when it would run past the end,
    /// shortened when the gap is shorter; nil when even `minMs` doesn't fit.
    static func suggested(at ms: Int64, in gap: Range<Int64>) -> Range<Int64>? {
        let len = min(defaultMs, gap.upperBound - gap.lowerBound)
        guard len >= minMs else { return nil }
        let lo = min(max(ms, gap.lowerBound), gap.upperBound - len)
        return lo..<(lo + len)
    }

    /// The category a new entry starts with: the nearest block's dominant one (the block before the
    /// gap, else the one after), so a gap in a coding day defaults to Coding rather than Uncategorized
    /// (which isn't work). nil with no blocks.
    static func defaultCategory(for r: Range<Int64>, blocks: [WorkBlock]) -> Int64? {
        (blocks.last { $0.endMs <= r.lowerBound } ?? blocks.first { $0.startMs >= r.upperBound })?.dominantCategoryId
    }

    /// The entry as one edit group (undo "Add Entry"). No selection afterwards: that is the
    /// timeline's, and the Blocks column selects the new block itself.
    static func plan(_ e: EditSession.NewEntry, data: DayData) -> EditPlan? {
        guard var p = EditPlanner.plan(.add(e.range, label: e.label, categoryId: e.categoryId, projectId: e.projectId),
                                       selection: [], in: data) else { return nil }
        p.selection = []
        return p
    }

    /// The ghost's readout: `09:40–10:05 · 25m`.
    static func readout(_ r: Range<Int64>, data: DayData) -> String {
        "\(Fmt.clock(ms: r.lowerBound, timeZone: data.timeZone))–\(Fmt.clock(ms: r.upperBound, timeZone: data.timeZone))"
            + " · \(Fmt.duration(ms: r.upperBound - r.lowerBound))"
    }
}
