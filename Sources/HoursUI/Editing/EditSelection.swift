import Foundation
import HoursCore

/// Selection = sorted, non-overlapping half-open ranges. Any gesture applies to all of them in one group.
public struct EditSelection: Sendable, Hashable {
    public enum Mode: Sendable { case replace, extend, toggle }
    public private(set) var ranges: [Range<Int64>] = []

    public init(_ ranges: [Range<Int64>] = []) { self.ranges = Self.normalized(ranges) }

    public var isEmpty: Bool { ranges.isEmpty }
    public var hull: Range<Int64>? {
        guard let lo = ranges.first?.lowerBound, let hi = ranges.last?.upperBound else { return nil }
        return lo..<hi
    }

    /// Click / marquee: replace; Shift extends to the hull; Cmd adds a disjoint range (or removes an equal one).
    public mutating func select(_ r: Range<Int64>, mode: Mode) {
        switch mode {
        case .replace: ranges = [r]
        case .extend:
            let h = hull.map { min($0.lowerBound, r.lowerBound)..<max($0.upperBound, r.upperBound) } ?? r
            ranges = [h]
        case .toggle:
            if let i = ranges.firstIndex(of: r) { ranges.remove(at: i) } else { ranges = Self.normalized(ranges + [r]) }
        }
    }

    public mutating func set(_ rs: [Range<Int64>]) { ranges = Self.normalized(rs) }
    public mutating func clear() { ranges = [] }

    /// Split at `t`: the range containing `t` is cut and its right half `[t, end)` becomes the selection.
    /// Writes nothing (08 decision 3). nil when `t` isn't strictly inside a selected range.
    public func split(at t: Int64) -> EditSelection? {
        guard let r = ranges.first(where: { $0.lowerBound < t && t < $0.upperBound }) else { return nil }
        return EditSelection([t..<r.upperBound])
    }

    static func normalized(_ rs: [Range<Int64>]) -> [Range<Int64>] {
        var out: [Range<Int64>] = []
        for r in rs.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}

/// Edge snapping: neighbouring segment edges (which include edit boundaries) and now/watermark
/// within 6 pt win; otherwise a zoom-adaptive local-time grid (1 / 5 / 15 min). Option disables it.
public enum EditSnap {
    static let tolerancePt: Double = 6

    /// Grid step for the zoom: the smallest of 1/5/15 min that's ≥ 6 pt wide.
    public static func gridMs(msPerPoint: Double) -> Int64 {
        [1, 5, 15].map { Int64($0) * 60_000 }.first { Double($0) / msPerPoint >= tolerancePt } ?? 15 * 60_000
    }

    public static func snap(_ ms: Int64, targets: [Int64], msPerPoint: Double, timeZone: TimeZone) -> Int64 {
        let tol = Int64(tolerancePt * msPerPoint)
        if let best = targets.min(by: { abs($0 - ms) < abs($1 - ms) }), abs(best - ms) <= tol { return best }
        let step = gridMs(msPerPoint: msPerPoint)
        let off = Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(ms) / 1000))) * 1000
        let local = ms + off
        let down = local - ((local % step) + step) % step
        return (local - down < step - (local - down) ? down : down + step) - off
    }

    /// Every segment edge of the day plus now / the watermark.
    static func targets(_ data: DayData) -> [Int64] {
        var t = data.spans.flatMap { [$0.span.startMs, $0.span.endMs] }
        if let n = data.nowMs { t.append(n) }
        if let w = EditPlanner.watermark(data) { t.append(w) }
        return t
    }
}

/// `HH:mm` ⇄ ms within a day whose bounds start at the day-start hour: times before it belong to
/// the next calendar day ("01:30" on a 04:00 day = 01:30 the morning after).
public enum EditTime {
    public static func parse(_ s: String, bounds: Range<Int64>, timeZone: TimeZone) -> Int64? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...24).contains(h), (0..<60).contains(m), h * 60 + m <= 24 * 60 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = Date(timeIntervalSince1970: Double(bounds.lowerBound) / 1000)
        var c = cal.dateComponents([.year, .month, .day, .hour], from: start)
        let startHour = c.hour ?? Hours.defaultDayStartHour
        c.hour = h; c.minute = m; c.second = 0
        guard var d = cal.date(from: c) else { return nil }
        if h < startHour { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
        let ms = Int64((d.timeIntervalSince1970 * 1000).rounded())
        return ms >= bounds.lowerBound && ms <= bounds.upperBound ? ms : nil
    }
}
