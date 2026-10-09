import Foundation
import Testing
import HoursCore
@testable import HoursUI

/// Counts factory calls and requests; answers every request with Research at 0.9. No network.
final class ShellJevFake: @unchecked Sendable {
    private let lock = NSLock()
    private var factory = 0, requests = 0
    var factoryCalls: Int { lock.withLock { factory } }
    var requestCount: Int { lock.withLock { requests } }

    var makeClient: @Sendable () -> JevClient? {
        { [self] in
            lock.withLock { factory += 1 }
            return JevClient(apiKey: "test", transport: { [self] _ in
                lock.withLock { requests += 1 }
                let json = #"{"model":"jev-test","answers":{"category":{"type":"choice","choice":"research","probabilities":{"research":0.9,"other":0.1},"confidence":0.9},"project":{"type":"choice","choice":"none","probabilities":{"none":1},"confidence":1}},"usage":{"input_tokens":400}}"#
                return (200, Data(json.utf8))
            }, backoff: { _ in })
        }
    }
}

@MainActor
@Suite struct ShellJevTests {
    /// Today, 14:30–14:40: a browser page no rule matches.
    func modelWithUnmatchedPage() throws -> AppModel {
        let model = try shellTempModel()
        let start = model.nowMs - 30 * 60_000
        _ = try SpanWriter(model.db).append(RawSpan(seq: 0, startMs: start, endMs: start + 10 * 60_000,
                                                    tzId: model.timeZone.identifier, tzOffsetS: 0, kind: .active,
                                                    bundleId: "com.google.Chrome", appName: "Google Chrome",
                                                    title: "Listing", url: "https://example.org/a"))
        return model
    }

    @Test func backgroundRunClassifiesThenSettles() async throws {
        let model = try modelWithUnmatchedPage()
        let fake = ShellJevFake()
        model.jevClient = fake.makeClient
        model.setVisible(true)
        // Before Jev: the Browsing fallback.
        #expect(await shellWait(.seconds(30)) { model.dayData?.spans.contains { $0.categoryId == ClassifySeed.browsing } == true })
        // Debounced 2 s → one request → cache write → change feed → classifier rebuilt.
        #expect(await shellWait(.seconds(30)) { model.dayData?.spans.contains { $0.categoryId == ClassifySeed.research } == true })
        #expect(fake.requestCount == 1)
        let span = try #require(model.dayData?.spans.first { $0.span.url != nil })
        #expect(model.dayData?.sourceLabel(span) == "Jev 90 %")
        // The follow-up refetch finds no misses: no second request, no second keychain read.
        try await Task.sleep(for: .seconds(3))
        #expect(fake.requestCount == 1 && fake.factoryCalls == 1)
        model.setVisible(false)
    }

    @Test func zeroWorkWhenOff() async throws {
        let model = try modelWithUnmatchedPage()
        try SettingStore(model.db).set(JevSettings.enabledKey, "0")
        let fake = ShellJevFake()
        model.jevClient = fake.makeClient
        await model.refetch()
        try await Task.sleep(for: .milliseconds(2_600))
        #expect(fake.factoryCalls == 0 && fake.requestCount == 0)
        // Still the Browsing fallback (a snapshot is present, just empty).
        #expect(model.classifier.jev?.isEmpty == true)
    }
}
