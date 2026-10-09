import Foundation
import GRDB
import Testing
@testable import HoursCore

/// 365 days × 1000 spans + 20 edits/day → `effectiveSpans(day:)` p95 < 50 ms.
/// Seeding takes a while; skip with `HOURS_SKIP_PERF=1`.
@Suite struct StorePerfTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HOURS_SKIP_PERF"] == nil))
    func dayQueryP95() throws {
        let url = storeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // ~100 MB
        let db = try storeTempDB(role: .app, url: url)
        let tz = "America/New_York"
        let day0 = LocalDate(year: 2025, month: 1, day: 1)
        let t0 = day0.dayInterval(in: TimeZone(identifier: tz)!).lowerBound
        let dayMs: Int64 = 86_400_000, spanMs = dayMs / 1000
        let days = 365
        var rng = SystemRandomNumberGenerator()

        let seedStart = Date()
        try db.writer.write { db in
            for d in 0..<days {
                let base = t0 + Int64(d) * dayMs
                for k in 0..<1000 {
                    let s = base + Int64(k) * spanMs
                    _ = try SpanWriter.insert(db, RawSpan(seq: 0, startMs: s, endMs: s + spanMs, tzId: tz, tzOffsetS: -18000,
                                                          kind: k % 10 == 0 ? .idle : .active, bundleId: "app.\(k % 37)",
                                                          appName: "App \(k % 37)", title: "Window \(k)", url: nil),
                                              blind: ChainCodec.newBlind())
                }
                var lastGrp: Int64?
                for k in 0..<20 {
                    let lo = base + Int64.random(in: 0..<(dayMs - 3_600_000), using: &rng)
                    let hi = lo + Int64.random(in: 60_000..<3_600_000, using: &rng)
                    let (op, payload): (EditOp, String) = switch k % 4 {
                    case 0: (.delete, "{}")
                    case 1: (.assign, #"{"category_id":3}"#)
                    case 2: (.add, #"{"label":"call"}"#)
                    default: (.undo, "{}")
                    }
                    let target = op == .undo ? lastGrp : nil
                    let (l, h) = op == .undo
                        ? try { let r = try Row.fetchOne(db, sql: "SELECT MIN(lo_ms) l, MAX(hi_ms) h FROM edit WHERE grp = ?",
                                                         arguments: [target])!; return (r["l"] as Int64, r["h"] as Int64) }()
                        : (lo, hi)
                    lastGrp = try EditWriter.insert(db, grp: nil, createdMs: base + dayMs, tzId: tz, op: op, lo: l, hi: h,
                                                    target: target, payload: payload)
                }
            }
        }
        let seedS = Date().timeIntervalSince(seedStart)

        let store = Store(db)
        var timings: [Double] = []
        var spansSeen = 0
        for d in stride(from: 1, to: days - 1, by: 2) { // 182 days spread over the year
            var date = day0
            for _ in 0..<d { date = date.storeNextDay() }
            let t = ContinuousClock.now
            let out = try store.effectiveSpans(day: date)
            let c = (ContinuousClock.now - t).components
            timings.append(Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
            spansSeen += out.count
            #expect(!out.isEmpty)
        }
        timings.sort()
        let p50 = timings[timings.count / 2], p95 = timings[Int(Double(timings.count) * 0.95)]
        print("StorePerf: seeded \(days * 1000) spans + \(days * 20) edits in \(String(format: "%.1f", seedS)) s; "
              + "effectiveSpans(day:) p50 \(String(format: "%.2f", p50)) ms, p95 \(String(format: "%.2f", p95)) ms "
              + "(\(timings.count) days, avg \(spansSeen / timings.count) spans/day)")
        #expect(p95 < 50)
    }
}
