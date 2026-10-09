import Foundation
import Testing
@testable import HoursCore

private typealias F = MetricsFixture

/// Best of 3 runs (first run absorbs one-time warm-up), in ms.
private func bestMs(_ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    var best = Duration.seconds(1_000)
    for _ in 0..<3 { best = Swift.min(best, clock.measure(body)) }
    return Double(best.components.attoseconds) / 1e15 + Double(best.components.seconds) * 1000
}

@Suite(.serialized) struct MetricsPerfTests {
    @Test func thousandSpanDayUnder20ms() {
        let spans = F.synthetic(n: 1000, day: 6)
        let ms = bestMs { _ = DayMetrics.compute(spans: spans, categories: F.categories) }
        print("MetricsPerf: 1000-span day \(String(format: "%.2f", ms)) ms")
        if perfEnforced { #expect(ms < 20) }
    }

    @Test func thirtyDayRangeUnder200ms() {
        var days: [LocalDate: [ClassifiedSpan]] = [:]
        for d in 1...30 { days[LocalDate(year: 2026, month: 9, day: d)] = F.synthetic(n: 1000, day: 6, seed: UInt64(d)) }
        let ms = bestMs { _ = RangeMetrics.compute(days: days, categories: F.categories) }
        print("MetricsPerf: 30-day range (30k spans) \(String(format: "%.2f", ms)) ms")
        if perfEnforced { #expect(ms < 200) }
    }

    @Test func pathologicalAlternationStaysBounded() {
        // 1000 one-minute spans alternating productive/neutral → the O(n²) split worst case (each split
        // peels one span), no sessions. Not a brief budget; looser bound so it guards against blow-ups only.
        let s0 = F.t(6, 6, 0)
        let spans = (0..<1000).map { i in
            let s = s0 + Int64(i) * 60_000
            return i % 2 == 0 ? F.span(s, s + 60_000, F.xcode, F.coding) : F.span(s, s + 60_000, F.slack, F.communication)
        }
        var m = DayMetrics()
        let ms = bestMs { m = DayMetrics.compute(spans: spans, categories: F.categories) }
        print("MetricsPerf: 1000-span alternation \(String(format: "%.2f", ms)) ms")
        #expect(m.focusSessions.isEmpty)
        if perfEnforced { #expect(ms < 50) }
    }
}
