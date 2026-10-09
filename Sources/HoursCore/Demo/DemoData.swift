import Foundation

/// Deterministic, realistic fake activity for previews, view tests and `spellsctl seed-demo`.
/// Pure: returns raw spans; callers decide whether to write them through the store.
public enum DemoData {
    struct Activity { let bundle: String?; let app: String; let titles: [String]; let urls: [String?] }

    static let coding = Activity(bundle: "com.microsoft.VSCode", app: "Code", titles: [
        "SpanWriter.swift — spells", "DayView.swift — spells", "route.ts — operations-dashboard",
        "ingest.py — client-monitoring", "scraper.py — data-scrapers"], urls: [nil])
    static let terminal = Activity(bundle: "com.cmuxterm.app", app: "cmux", titles: [
        "~/Documents/GitHub/spells", "claude — spells", "~/Documents/GitHub/outreach-systems"], urls: [nil])
    static let browserWork = Activity(bundle: "com.google.Chrome", app: "Google Chrome", titles: [
        "Pull requests · ExampleOrg/spells", "Neon Console", "Vercel – Deployments", "SwiftUI | Apple Developer Documentation"],
        urls: ["https://github.com/ExampleOrg/spells/pulls", "https://console.neon.tech/app/projects",
               "https://vercel.com/dashboard", "https://developer.apple.com/documentation/swiftui"])
    static let slack = Activity(bundle: "com.tinyspeck.slackmacgap", app: "Slack", titles: [
        "general (Channel) - ExampleCo - Slack", "Alex Client (DM) - ExampleCo - Slack"], urls: [nil])
    static let clickup = Activity(bundle: "com.google.Chrome", app: "Google Chrome", titles: ["SC Scraper Monitor | ClickUp"],
        urls: ["https://app.clickup.com/9011/v/l/6-901"])
    static let distraction = Activity(bundle: "com.google.Chrome", app: "Google Chrome", titles: [
        "YouTube", "Hacker News", "Reddit - Dive into anything"],
        urls: ["https://www.youtube.com/watch", "https://news.ycombinator.com/", "https://www.reddit.com/"])
    static let zoom = Activity(bundle: "us.zoom.xos", app: "zoom.us", titles: ["Zoom Meeting"], urls: [nil])

    /// Spans for each day in `days` (inclusive), weekdays only, in `tzId`. Deterministic per date.
    public static func spans(from start: LocalDate, through end: LocalDate, tzId: String = "America/Vancouver") -> [RawSpan] {
        let tz = TimeZone(identifier: tzId) ?? .current
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        guard var date = cal.date(from: DateComponents(year: start.year, month: start.month, day: start.day)),
              let last = cal.date(from: DateComponents(year: end.year, month: end.month, day: end.day)) else { return [] }
        var out: [RawSpan] = []
        while date <= last {
            let wd = cal.component(.weekday, from: date)
            if wd != 1 && wd != 7 { out += day(date, cal: cal, tzId: tzId) }
            date = cal.date(byAdding: .day, value: 1, to: date)!
        }
        return out
    }

    static func day(_ midnight: Date, cal: Calendar, tzId: String) -> [RawSpan] {
        let c = cal.dateComponents([.year, .month, .day], from: midnight)
        var rng = LCG(seed: UInt64(c.year! * 10_000 + c.month! * 100 + c.day!))
        func at(_ h: Int, _ m: Int) -> Int64 { Int64(midnight.addingTimeInterval(Double(h * 3600 + m * 60)).timeIntervalSince1970 * 1000) }
        let offset = cal.timeZone.secondsFromGMT(for: midnight.addingTimeInterval(12 * 3600))
        var spans: [RawSpan] = []
        var t = at(8, 50 + Int(rng.next() % 20))
        func push(_ a: Activity, _ kind: SpanKind = .active, minutes: Int64) {
            let i = Int(rng.next() % UInt64(a.titles.count))
            let end = t + minutes * 60_000
            spans.append(RawSpan(seq: 0, startMs: t, endMs: end, tzId: tzId, tzOffsetS: offset, kind: kind,
                                 bundleId: a.bundle, appName: a.app, title: a.titles[i], url: a.urls[min(i, a.urls.count - 1)]))
            t = end
        }
        let meeting = at(11, 0), lunch = at(12, 30), stop = at(17, 15 + Int(rng.next() % 40))
        while t < stop {
            if t >= meeting && t < meeting + 30 * 60_000 { push(zoom, minutes: 30); continue }
            if t >= lunch && t < lunch + 45 * 60_000 { push(slack, .idle, minutes: 45); continue }
            switch rng.next() % 10 {
            case 0...3: push(coding, minutes: Int64(5 + rng.next() % 25))
            case 4, 5: push(terminal, minutes: Int64(2 + rng.next() % 12))
            case 6: push(browserWork, minutes: Int64(2 + rng.next() % 10))
            case 7: push(slack, minutes: Int64(1 + rng.next() % 6))
            case 8: push(clickup, minutes: Int64(1 + rng.next() % 5))
            default: push(distraction, minutes: Int64(1 + rng.next() % 8))
            }
        }
        return spans
    }

    // ponytail: tiny LCG, deterministic across runs; not for anything random-quality-sensitive.
    struct LCG { var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
    }
}
