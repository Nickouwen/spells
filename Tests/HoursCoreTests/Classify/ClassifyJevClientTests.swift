import Foundation
import Testing
@testable import HoursCore

private let S = ClassifySeed.self

/// Scripted fake transport: pops one response per call, records request bodies and peak concurrency.
final class JevFakeTransport: @unchecked Sendable {
    enum Reply { case status(Int), answer(String, Double), fail(any Error) }
    private let lock = NSLock()
    private var script: [Reply]
    private let fallback: Reply
    private(set) var bodies: [String] = []
    private(set) var authHeaders: [String] = []
    private var inFlight = 0
    private(set) var peak = 0
    let delay: Duration

    init(_ script: [Reply] = [], fallback: Reply = .answer("research", 0.9), delay: Duration = .zero) {
        self.script = script; self.fallback = fallback; self.delay = delay
    }

    var calls: Int { lock.withLock { bodies.count } }

    var transport: JevTransport {
        { [self] req in
            let reply: Reply = lock.withLock {
                bodies.append(String(decoding: req.httpBody ?? Data(), as: UTF8.self))
                authHeaders.append(req.value(forHTTPHeaderField: "Authorization") ?? "")
                inFlight += 1; peak = max(peak, inFlight)
                return script.isEmpty ? fallback : script.removeFirst()
            }
            if delay > .zero { try? await Task.sleep(for: delay) }
            lock.withLock { inFlight -= 1 }
            switch reply {
            case .status(let s): return (s, Data())
            case .fail(let e): throw e
            case .answer(let cat, let conf):
                let json = """
                {"model":"jev-1.13.0","answers":{"category":{"type":"choice","choice":"\(cat)","probabilities":{"\(cat)":\(conf),"other":\(1 - conf)},"confidence":\(conf)},
                 "project":{"type":"choice","choice":"none","probabilities":{"none":1},"confidence":1}},"usage":{"input_tokens":433,"output_tokens":20}}
                """
                return (200, Data(json.utf8))
            }
        }
    }
}

final class JevBackoffLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Int] = []
    var all: [Int] { lock.withLock { calls } }
    var fn: @Sendable (Int) async -> Void { { [self] n in lock.withLock { calls.append(n) } } }
}

private let key = JevKey(app: "com.google.Chrome", host: "example.org", pathTpl: "/a", titleNorm: "t")

@Suite struct ClassifyJevClientTests {
    func client(_ fake: JevFakeTransport, _ log: JevBackoffLog = JevBackoffLog()) -> JevClient {
        JevClient(apiKey: "test-key", transport: fake.transport, backoff: log.fn)
    }

    @Test func parsesAnswer() async {
        let fake = JevFakeTransport([.answer("research", 0.93)])
        guard case .answered(let e) = await client(fake).classify(key, body: Data("{}".utf8), nowMs: 5) else {
            Issue.record("expected an answer"); return
        }
        #expect(e.categoryKey == "research" && e.categoryConf == 0.93 && e.inputTokens == 433 && e.model == "jev-1.13.0")
        #expect(e.projectName == nil && e.createdMs == 5 && e.retryAfterMs == nil)
        #expect(fake.authHeaders == ["Bearer test-key"])
    }

    @Test func retries429And529WithBackoff() async {
        let fake = JevFakeTransport([.status(429), .status(529), .answer("coding", 0.8)])
        let log = JevBackoffLog()
        guard case .answered(let e) = await client(fake, log).classify(key, body: Data(), nowMs: 0) else {
            Issue.record("expected an answer after retries"); return
        }
        #expect(e.categoryKey == "coding")
        #expect(fake.calls == 3 && log.all == [1, 2])
    }

    @Test func givesUpAfterMaxAttemptsWithRetryAfter() async {
        let fake = JevFakeTransport(fallback: .status(429))
        let log = JevBackoffLog()
        guard case .failed(let e) = await client(fake, log).classify(key, body: Data(), nowMs: 1_000) else {
            Issue.record("expected a failure"); return
        }
        #expect(fake.calls == 4 && log.all == [1, 2, 3])
        #expect(e.categoryKey == nil && e.retryAfterMs == 1_000 + JevClient.transientRetryMs)
    }

    @Test func otherFailures() async {
        // Timeout / network: no retry, transient retry-after.
        let timeout = JevFakeTransport([.fail(URLError(.timedOut))])
        guard case .failed(let t) = await client(timeout).classify(key, body: Data(), nowMs: 0) else { Issue.record("timeout"); return }
        #expect(timeout.calls == 1 && t.retryAfterMs == JevClient.transientRetryMs)
        // 400: permanent-ish (24 h). 500: transient.
        guard case .failed(let bad) = await client(JevFakeTransport([.status(400)])).classify(key, body: Data(), nowMs: 0) else { Issue.record("400"); return }
        #expect(bad.retryAfterMs == JevClient.permanentRetryMs)
        guard case .failed(let s5) = await client(JevFakeTransport([.status(500)])).classify(key, body: Data(), nowMs: 0) else { Issue.record("500"); return }
        #expect(s5.retryAfterMs == JevClient.transientRetryMs)
        // 401 → unauthorized, no retry.
        let auth = JevFakeTransport([.status(401)])
        guard case .unauthorized = await client(auth).classify(key, body: Data(), nowMs: 0) else { Issue.record("401"); return }
        #expect(auth.calls == 1)
    }

    @Test func liveClientPrefersEnvironmentKey() {
        #expect(JevClient.live(environment: ["TYPESAFE_API_KEY": "from-env"]) != nil)
    }
}

@Suite struct ClassifyJevRunnerTests {
    /// A temp DB with the seed config and these spans chained (1 min each, back to back).
    func db(_ spans: [(bundle: String?, app: String, title: String?, url: String?)]) throws -> HoursDB {
        let db = try storeTempDB(role: .app)
        let cfg = ConfigStore(db)
        for c in S.categories { try cfg.insert(c) }
        for p in S.projects { try cfg.insert(p) }
        for r in S.rules { try cfg.insert(r) }
        let w = SpanWriter(db)
        for (i, s) in spans.enumerated() {
            try w.append(RawSpan(seq: 0, startMs: Int64(i) * 60_000, endMs: Int64(i + 1) * 60_000, tzId: "UTC", tzOffsetS: 0,
                                 kind: .active, bundleId: s.bundle, appName: s.app, title: s.title, url: s.url))
        }
        return db
    }

    func classifier(_ db: HoursDB) throws -> Classifier {
        Classifier(categories: try ConfigStore(db).categories(), rules: try ConfigStore(db).rules(),
                   projects: try ConfigStore(db).projects(), jev: try JevCacheStore(db).snapshot(nowMs: 10_000_000))
    }

    func spans(_ db: HoursDB) throws -> [EffectiveSpan] { try Store(db).effectiveSpans(rangeFrom: 0, to: 100_000_000) }

    @Test func privacyExclusionsNeverProduceARequest() async throws {
        let chrome = "com.google.Chrome"
        let d = try db([
            ("com.apple.loginwindow", "loginwindow", "Login", nil),                       // rule → exclude category
            (chrome, "Google Chrome", nil, nil),                                          // incognito: no title/URL
            ("com.apple.Safari", "Safari", nil, nil),                                     // opaque browser
            (chrome, "Google Chrome", "GitHub", "https://github.com/acme"),               // rule-matched
            (chrome, "Google Chrome", "Edited away", "https://private.example/x"),       // edited below
            (chrome, "Google Chrome", "Listing", "https://example.org/a/b?token=secret"), // the one miss
            (chrome, "Google Chrome", "Listing", "https://example.org/a/b?token=other"),  // same key
        ])
        // Mark span 5 personal via an edit (category override).
        try EditWriter(d).apply([.assign(4 * 60_000, 5 * 60_000, categoryId: S.personal, projectId: nil)])
        let misses = ClassifyJevRunner.misses(try spans(d), classifier: try classifier(d))
        #expect(misses.map(\.key.host) == ["example.org"])
        #expect(misses.first?.totalMs == 120_000)

        let fake = JevFakeTransport()
        let r = try await ClassifyJevRunner.run(misses, db: d, client: JevClient(apiKey: "k", transport: fake.transport),
                                                categories: S.categories, projects: S.projects, nowMs: 1)
        #expect(r.requests == 1 && r.answered == 1 && r.inputTokens == 433 && r.histogram == ["research": 1])
        #expect(fake.calls == 1)
        let body = fake.bodies[0]
        #expect(!body.contains("secret") && !body.contains("token"))
        #expect(!body.contains("Login") && !body.contains("Edited away") && !body.contains("loginwindow"))
        #expect(body.contains("\"path\":\"/a/b\"") && body.contains("\"title\":\"Listing\""))

        // Cached → the second pass finds nothing; the new answer classifies the span.
        let c2 = try classifier(d)
        #expect(ClassifyJevRunner.misses(try spans(d), classifier: c2).isEmpty)
        let listing = try spans(d).first { $0.title == "Listing" }!
        #expect(c2.category(listing) == S.research && c2.source(listing) == .jev(confidence: 0.9))
    }

    @Test func titlesOffSendsHostAndPathOnly() async throws {
        let d = try db([("com.google.Chrome", "Google Chrome", "Private Title", "https://example.org/a")])
        try SettingStore(d).set(JevSettings.sendTitlesKey, "0")
        let misses = ClassifyJevRunner.misses(try spans(d), classifier: try classifier(d))
        let fake = JevFakeTransport()
        _ = try await ClassifyJevRunner.run(misses, db: d, client: JevClient(apiKey: "k", transport: fake.transport),
                                            categories: S.categories, projects: S.projects, nowMs: 1)
        #expect(fake.calls == 1 && !fake.bodies[0].contains("Private Title") && !fake.bodies[0].contains("\"title\""))
    }

    @Test func disabledMeansNoMisses() throws {
        let d = try db([("com.google.Chrome", "Google Chrome", "Listing", "https://example.org/a")])
        try SettingStore(d).set(JevSettings.enabledKey, "0")
        #expect(ClassifyJevRunner.misses(try spans(d), classifier: try classifier(d)).isEmpty)
        #expect(ClassifyJevRunner.misses(try spans(d), classifier: Classifier(categories: S.categories, rules: S.rules,
                                                                              projects: S.projects)).isEmpty)
    }

    @Test func failuresAreStoredAndNotReaskedUntilDue() async throws {
        let d = try db([("com.google.Chrome", "Google Chrome", "Listing", "https://example.org/a")])
        let misses = ClassifyJevRunner.misses(try spans(d), classifier: try classifier(d))
        let fake = JevFakeTransport([.status(500)])
        let r = try await ClassifyJevRunner.run(misses, db: d, client: JevClient(apiKey: "k", transport: fake.transport),
                                                categories: S.categories, projects: S.projects, nowMs: 1_000)
        #expect(r.failed == 1 && r.answered == 0)
        let stored = try JevCacheStore(d).all()
        #expect(stored.count == 1 && stored[0].categoryKey == nil && stored[0].retryAfterMs == 1_000 + JevClient.transientRetryMs)
        #expect(try JevCacheStore(d).count() == 0)
        // Before the retry-after: covered. After: a miss again.
        let early = Classifier(categories: S.categories, rules: S.rules, projects: S.projects,
                               jev: try JevCacheStore(d).snapshot(nowMs: 2_000))
        #expect(ClassifyJevRunner.misses(try spans(d), classifier: early).isEmpty)
        let late = Classifier(categories: S.categories, rules: S.rules, projects: S.projects,
                              jev: try JevCacheStore(d).snapshot(nowMs: 1_000 + JevClient.transientRetryMs))
        #expect(ClassifyJevRunner.misses(try spans(d), classifier: late).count == 1)
    }

    @Test func fourInFlightAndUnauthorizedStops() async throws {
        let d = try db((0..<10).map { ("com.google.Chrome", "Google Chrome", "Page \($0)", "https://site\($0).example/") })
        let misses = ClassifyJevRunner.misses(try spans(d), classifier: try classifier(d))
        #expect(misses.count == 10)
        let fake = JevFakeTransport(delay: .milliseconds(30))
        let r = try await ClassifyJevRunner.run(misses, db: d, client: JevClient(apiKey: "k", transport: fake.transport),
                                                categories: S.categories, projects: S.projects, nowMs: 1)
        #expect(r.requests == 10 && r.answered == 10 && fake.peak == 4)
        #expect(try JevCacheStore(d).count() == 10)

        let d2 = try db((0..<10).map { ("com.google.Chrome", "Google Chrome", "Page \($0)", "https://site\($0).example/") })
        let bad = JevFakeTransport(fallback: .status(401))
        let r2 = try await ClassifyJevRunner.run(ClassifyJevRunner.misses(try spans(d2), classifier: try classifier(d2)), db: d2,
                                                 client: JevClient(apiKey: "k", transport: bad.transport),
                                                 categories: S.categories, projects: S.projects, nowMs: 1, concurrency: 1)
        #expect(r2.unauthorized && r2.requests == 1 && bad.calls == 1)
        #expect(try JevCacheStore(d2).all().isEmpty)
    }
}

@Suite struct StoreJevCacheTests {
    @Test func roundTripCountTokensRevisionClear() throws {
        let db = try storeTempDB(role: .app)
        let store = JevCacheStore(db)
        let r0 = try store.revision()
        let a = JevEntry(key: JevKey(app: "com.google.Chrome", host: "example.org", pathTpl: "/a", titleNorm: "t"),
                         categoryKey: "research", categoryConf: 0.9, categoryProbs: ["research": 0.9, "other": 0.1],
                         projectName: "hours", projectConf: 0.8, model: "jev-1.13.0", createdMs: 2_000, inputTokens: 433)
        let f = JevEntry.failure(JevKey(app: "com.figma.Desktop", titleNorm: "x"), nowMs: 500, retryAfterMs: 9_000)
        try store.upsert([a, f])
        #expect(Set(try store.all()) == [a, f])
        #expect(try store.count() == 1)
        #expect(try store.inputTokens(sinceMs: 1_000) == 433)
        #expect(try store.revision() != r0)
        // Upsert replaces by key (a retried failure becomes an answer).
        var answered = a; answered.key = f.key; answered.createdMs = 3_000
        try store.upsert([answered])
        #expect(try store.count() == 2)
        #expect(try store.all().count == 2)
        try store.clear()
        #expect(try store.all().isEmpty)
    }

    @Test func snapshotFollowsSettings() throws {
        let db = try storeTempDB(role: .app)
        try JevCacheStore(db).upsert([jevEntry("example.org", "/a", "t", "research")])
        #expect(try JevCacheStore(db).snapshot().count == 1)
        try SettingStore(db).set(JevSettings.minConfidenceKey, "0.75")
        try SettingStore(db).set(JevSettings.sendTitlesKey, "0")
        let s = try JevCacheStore(db).snapshot()
        #expect(s.settings == JevSettings(enabled: true, minConfidence: 0.75, sendTitles: false))
        try SettingStore(db).set(JevSettings.enabledKey, "0")
        #expect(try JevCacheStore(db).snapshot().isEmpty)
    }
}
