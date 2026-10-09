import Foundation

enum MetricsFocus {
    /// Focus sessions over sorted productive spans: group by gaps <= tolerance, then accept a run if it
    /// has >= focusMin productive ms at >= focusShare of its wall time; otherwise split at its largest
    /// internal gap (earliest on tie) and retry each side. `activeMs` counts productive ms only.
    // ponytail: worst case O(n²) on pathological alternation (each split peels one span); a 5000-span
    // alternating day is ~12M gap comparisons. Add a recursion cap if real days ever get there.
    static func sessions(_ f: [MetricsSpan], _ c: MetricsConfig) -> [DayMetrics.Session] {
        guard !f.isEmpty else { return [] }
        // Plain Int64 arrays: the split loop below must not copy MetricsSpan (String fields → ARC).
        let starts = f.map(\.start), ends = f.map(\.end)
        var pre = [Int64](repeating: 0, count: f.count + 1)
        for i in f.indices { pre[i + 1] = pre[i] + ends[i] - starts[i] }
        let gaps = (0..<f.count - 1).map { starts[$0 + 1] - ends[$0] }   // gaps[i] = between i and i+1

        var stack: [(Int, Int)] = []   // inclusive index ranges still to validate
        var lo = 0
        for i in gaps.indices where gaps[i] > c.focusTolMs {
            stack.append((lo, i)); lo = i + 1
        }
        stack.append((lo, f.count - 1))

        var out: [DayMetrics.Session] = []
        while let (a, b) = stack.popLast() {
            let focus = pre[b + 1] - pre[a]
            if focus < c.focusMinMs { continue }
            let wall = ends[b] - starts[a]
            if Double(focus) >= c.focusShare * Double(wall) {
                out.append(DayMetrics.Session(startMs: starts[a], endMs: ends[b], activeMs: focus))
                continue
            }
            guard a < b else { continue }
            var cut = a, widest = Int64.min
            for i in a..<b where gaps[i] > widest { widest = gaps[i]; cut = i }
            stack.append((a, cut)); stack.append((cut + 1, b))
        }
        return out.sorted { $0.startMs < $1.startMs }
    }

    /// Meeting runs: meeting spans merged across gaps <= meetingMergeGap, kept if >= meetingMin active.
    static func meetings(_ m: [MetricsSpan], _ c: MetricsConfig) -> [DayMetrics.Session] {
        var runs: [DayMetrics.Session] = []
        for s in m {
            if let last = runs.last, s.start - last.endMs <= c.meetingMergeGapMs {
                runs[runs.count - 1].endMs = max(last.endMs, s.end)
                runs[runs.count - 1].activeMs += s.durationMs
            } else {
                runs.append(DayMetrics.Session(startMs: s.start, endMs: s.end, activeMs: s.durationMs))
            }
        }
        return runs.filter { $0.activeMs >= c.meetingMinMs }
    }
}
