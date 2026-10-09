import Foundation
@testable import HoursCore

/// Fixture helpers: item 4's seed categories (subset) and a span builder in a fixed tz.
enum MetricsFixture {
    static let tzId = "America/New_York"
    static let minute: Int64 = 60_000

    static let coding = HoursCore.Category(id: 1, key: "coding", name: "Coding", level: .productive, isWork: true,
                                 behavior: .normal, colorSlot: 0, sort: 1)
    static let communication = HoursCore.Category(id: 5, key: "communication", name: "Communication", level: .neutral,
                                        isWork: true, behavior: .normal, colorSlot: nil, sort: 5)
    static let meetings = HoursCore.Category(id: 6, key: "meetings", name: "Meetings", level: .neutral, isWork: true,
                                   behavior: .meeting, colorSlot: nil, sort: 6)
    static let system = HoursCore.Category(id: 7, key: "system", name: "System & Admin", level: .neutral, isWork: true,
                                 behavior: .normal, colorSlot: nil, sort: 7)
    static let entertainment = HoursCore.Category(id: 10, key: "entertainment", name: "Entertainment", level: .distracting,
                                        isWork: false, behavior: .normal, colorSlot: nil, sort: 10)
    static let excluded = HoursCore.Category(id: 12, key: "excluded", name: "Excluded", level: .neutral, isWork: false,
                                   behavior: .exclude, colorSlot: nil, sort: 12)
    static let categories = [coding, communication, meetings, system, entertainment, excluded]

    static let projA: Int64 = 100, projB: Int64 = 200

    /// Epoch ms for 2026-10-`day` h:m:s in New York (Oct 6 2026 = Tuesday).
    static func t(_ day: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tzId)!
        let d = cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m, second: s))!
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    static func span(_ start: Int64, _ end: Int64, _ bundle: String, _ cat: HoursCore.Category?, project: Int64? = nil,
                     url: String? = nil, kind: SpanKind = .active) -> ClassifiedSpan {
        ClassifiedSpan(
            span: EffectiveSpan(startMs: start, endMs: end, tzId: tzId, kind: kind, bundleId: bundle,
                                appName: bundle.components(separatedBy: ".").last!, title: nil, url: url,
                                rawSeq: 1),
            categoryId: cat?.id, projectId: project)
    }

    static func idle(_ start: Int64, _ end: Int64) -> ClassifiedSpan {
        span(start, end, "idle", nil, kind: .idle)
    }

    static let xcode = "com.apple.dt.Xcode", slack = "com.tinyspeck.slackmacgap", safari = "com.apple.Safari"
    static let zoom = "us.zoom.xos", mail = "com.apple.mail", finder = "com.apple.finder"

    /// Plan 05 acceptance A — mixed day, Tue Oct 6.
    static var dayA: [ClassifiedSpan] {
        let d = 6
        return [
            span(t(d, 9, 0), t(d, 10, 0), xcode, coding, project: projA),
            span(t(d, 10, 0), t(d, 10, 1), slack, communication),
            span(t(d, 10, 1), t(d, 10, 31), xcode, coding, project: projA),
            idle(t(d, 10, 31), t(d, 10, 41)),
            span(t(d, 10, 41), t(d, 11, 0), safari, entertainment, url: "https://www.youtube.com/watch"),
            span(t(d, 11, 0), t(d, 12, 0), zoom, meetings, project: projA),
            idle(t(d, 12, 0), t(d, 13, 0)),
            span(t(d, 13, 0), t(d, 13, 20), xcode, coding, project: projA),
            span(t(d, 13, 20), t(d, 13, 30), mail, communication),
        ]
    }

    /// Plan 05 acceptance C — Rize's alternation: 14:00–15:00, 1 min Xcode / 1 min Slack.
    static var dayC: [ClassifiedSpan] {
        (0..<60).map { i in
            let s = t(6, 14, 0) + Int64(i) * minute
            return i % 2 == 0 ? span(s, s + minute, xcode, coding) : span(s, s + minute, slack, communication)
        }
    }

    /// Deterministic synthetic day: `n` spans of 1–120 s from 08:00, occasional gaps, mixed apps/sites.
    static func synthetic(n: Int, day: Int, seed: UInt64 = 42) -> [ClassifiedSpan] {
        var rng = seed
        func next(_ bound: Int64) -> Int64 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int64((rng >> 33) % UInt64(bound))
        }
        let apps: [(String, HoursCore.Category?, String?)] = [
            (xcode, coding, nil), (slack, communication, nil), (safari, coding, "https://github.com/x/y"),
            (safari, entertainment, "https://www.youtube.com/watch"), (zoom, meetings, nil), (mail, communication, nil),
            ("com.example.unknown", nil, nil), ("com.apple.loginwindow", excluded, nil),
        ]
        var t0 = t(day, 8, 0)
        var out: [ClassifiedSpan] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            let a = apps[Int(next(Int64(apps.count)))]
            let dur = 1_000 + next(119_000)
            let project: Int64? = next(3) == 0 ? nil : projA + next(2) * 100
            out.append(span(t0, t0 + dur, a.0, a.1, project: project, url: a.2))
            t0 += dur + (next(10) == 0 ? next(400_000) : 0)
        }
        return out
    }
}
