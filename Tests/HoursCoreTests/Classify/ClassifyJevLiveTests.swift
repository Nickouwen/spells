import Foundation
import Testing
@testable import HoursCore

private let env = ProcessInfo.processInfo.environment

/// Real TypeSafe calls. Runs only with `TYPESAFE_API_KEY` in the environment (never the Keychain),
/// so a plain `swift test` stays offline.
@Suite(.enabled(if: !(env["TYPESAFE_API_KEY"] ?? "").isEmpty, "needs TYPESAFE_API_KEY"))
struct ClassifyJevLiveTests {
    @Test func classifiesTwoPages() async throws {
        let client = try #require(JevClient.live())
        let pages = [
            ClassifyKey(bundleId: "com.google.Chrome", appName: "Google Chrome",
                        title: "asyncio — Asynchronous I/O — Python 3.13 documentation", url: "https://docs.python.org/3/library/asyncio.html"),
            ClassifyKey(bundleId: "com.google.Chrome", appName: "Google Chrome",
                        title: "Your Orders - Amazon.com", url: "https://www.amazon.com/gp/css/order-history"),
        ]
        for p in pages {
            let key = try #require(ClassifyJevKey.make(p))
            let body = ClassifyJevPrompt.body(key: key, sample: p, categories: ClassifySeed.categories, projects: ClassifySeed.projects)
            guard case .answered(let e) = await client.classify(key, body: body, nowMs: 0) else {
                Issue.record("no answer for \(key.host)"); continue
            }
            #expect(ClassifyJevPrompt.categoryCriteria(ClassifySeed.categories)[e.categoryKey ?? ""] != nil)
            #expect(e.inputTokens > 0 && (0...1).contains(e.categoryConf))
        }
    }
}

/// Dev helper, not a test: with `HOURS_JEV_SEED_HOME=<dir>`, appends rule-unmatched pages after the
/// last span in `<dir>/hours.db` so `spellsctl classify` has real misses (seed-demo's data is all
/// rule-matched). Never runs otherwise.
@Suite(.enabled(if: !(env["HOURS_JEV_SEED_HOME"] ?? "").isEmpty, "dev helper: set HOURS_JEV_SEED_HOME"))
struct ClassifyJevSeedUnmatched {
    @Test func appendUnmatchedPages() throws {
        let home = URL(filePath: env["HOURS_JEV_SEED_HOME"]!, directoryHint: .isDirectory)
        let db = try HoursDB.open(at: home.appending(path: "hours.db"), role: .app, notifyName: storeTestNotifyName())
        let last = try db.writer.read { try Int64.fetchOne($0, sql: "SELECT MAX(end_ms) FROM span") } ?? 0
        let chrome = ("com.google.Chrome", "Google Chrome")
        let pages: [(String, String, String?, String?)] = [
            (chrome.0, chrome.1, "Example Metrics Dashboard", "https://example.com/metrics/dashboard"),
            (chrome.0, chrome.1, "Pipeline Run 123", "https://example.com/pipelines/runs/123"),
            (chrome.0, chrome.1, "Workflow Backlog", "https://example.com/workflows/backlog"),
            (chrome.0, chrome.1, "Data Source Reference", "https://example.com/docs/data-source"),
            (chrome.0, chrome.1, "Public API Index", "https://example.com/api/index"),
            (chrome.0, chrome.1, "Your Orders - Amazon.com", "https://www.amazon.com/gp/css/order-history"),
            (chrome.0, chrome.1, "Columbia, SC 10-Day Weather Forecast", "https://weather.com/weather/tenday/l/Columbia+SC"),
            (chrome.0, chrome.1, "Understanding Swift Concurrency | by Jane Dev | Medium", "https://medium.com/@janedev/understanding-swift-concurrency-1a2b3c4d5e6f"),
            (chrome.0, chrome.1, "NFL Scores, 2026 Season - ESPN", "https://www.espn.com/nfl/scoreboard"),
            (chrome.0, chrome.1, "Accounts Overview | Bank of America", "https://secure.bankofamerica.com/myaccounts/brain/redirect.go"),
            (chrome.0, chrome.1, "Q4 Roadmap", "https://www.notion.so/exampleco/Q4-Roadmap-8f3e2a1b9c"),
            (chrome.0, chrome.1, nil, nil),                                   // incognito: never sent
            ("com.apple.Preview", "Preview", "Purchase_Agreement_Lot_14.pdf", nil),
            ("com.figma.Desktop", "Figma", "Dashboard v2 – Figma", nil),
        ]
        let w = SpanWriter(db)
        for (i, p) in pages.enumerated() {
            let start = last + 60_000 + Int64(i) * 180_000
            try w.append(RawSpan(seq: 0, startMs: start, endMs: start + 180_000, tzId: TimeZone.current.identifier,
                                 tzOffsetS: TimeZone.current.secondsFromGMT(), kind: .active,
                                 bundleId: p.0, appName: p.1, title: p.2, url: p.3))
        }
        print("appended \(pages.count) unmatched spans to \(home.path)/hours.db")
    }
}
