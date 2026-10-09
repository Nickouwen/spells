import Foundation
import Testing
@testable import HoursCore

/// Anchorer logic with an in-process fake TSA (no network). Real-token coverage: ExportBundleTests.signedTokenEndToEnd.
@Suite struct ExportAnchorerTests {
    let tsas = [TSA(name: "a", url: URL(string: "https://tsa.invalid/a")!), TSA(name: "b", url: URL(string: "https://tsa.invalid/b")!)]
    let fake: Anchorer.Transport = { _, req in try exportFakeResponse(for: req) }
    let day1 = Date(timeIntervalSince1970: Double(exportMs("2026-10-05 12:00")) / 1000)

    func run(_ db: HoursDB, at now: Date, force: Bool = false, mirror: URL? = nil,
             transport: Anchorer.Transport? = nil) async throws -> Anchorer.Outcome {
        try await Anchorer.runIfDue(db: db, now: now, force: force, tz: exportUTCZone, tsas: tsas, mirrorDir: mirror,
                                    transport: transport ?? fake)
    }

    @Test func emptyChainIsNotDue() async throws {
        let db = try storeTempDB()
        #expect(try await run(db, at: day1) == .notDue("chain is empty"))
    }

    @Test func anchorsHeadOncePerTSAAndMirrorsTokens() async throws {
        let db = try exportFixtureDB()
        let mirror = exportTempDir()
        guard case let .done(anchored, failures) = try await run(db, at: day1, mirror: mirror) else {
            Issue.record("expected an anchor"); return
        }
        let head = try db.head()
        #expect(failures.isEmpty)
        #expect(anchored.map(\.tsa) == ["a", "b"])
        let stored = try AnchorStore(db).list()
        #expect(stored == anchored)
        for a in stored {
            #expect(a.headSeq == head.seq && a.headHash == head.hash && a.method == "rfc3161")
            #expect(a.genTimeMs == exportMs("2026-10-06 12:00"))
            #expect(a.requestedMs == exportMs("2026-10-05 12:00"))
            #expect(try RFC3161.parseToken(a.token!).imprint == head.hash)
            #expect(try Data(contentsOf: mirror.appending(path: "\(a.id)-\(a.tsa!).tst")) == a.token)
        }
        #expect(try ChainVerifier.verify(db).ok)
    }

    @Test func idempotentPerDayUnlessHeadAdvancedAndForced() async throws {
        let db = try exportFixtureDB()
        _ = try await run(db, at: day1)
        #expect(try await run(db, at: day1, force: true) == .notDue("head #10 already anchored"))

        try SpanWriter(db).append(exportSpan("2026-10-05 13:00", "2026-10-05 13:10", bundle: nil, app: "X", title: nil))
        let later = day1.addingTimeInterval(3600)
        #expect(try await run(db, at: later) == .notDue("already anchored today (head advanced; use --force)"))
        guard case let .done(forced, _) = try await run(db, at: later, force: true) else { Issue.record("force"); return }
        #expect(forced.map(\.headSeq) == [11, 11])

        try SpanWriter(db).append(exportSpan("2026-10-05 14:00", "2026-10-05 14:10", bundle: nil, app: "X", title: nil))
        // Next store day (after 04:00 UTC on the 6th) anchors without --force.
        guard case let .done(next, _) = try await run(db, at: day1.addingTimeInterval(17 * 3600)) else {
            Issue.record("next day"); return
        }
        #expect(next.map(\.headSeq) == [12, 12])
        #expect(try AnchorStore(db).list().count == 6)
    }

    @Test func oneTSADownStillAnchors() async throws {
        let db = try exportFixtureDB()
        let halfDown: Anchorer.Transport = { url, req in
            if url.lastPathComponent == "a" { throw URLError(.timedOut) }
            return try exportFakeResponse(for: req)
        }
        guard case let .done(anchored, failures) = try await run(db, at: day1, transport: halfDown) else {
            Issue.record("expected done"); return
        }
        #expect(anchored.map(\.tsa) == ["b"])
        #expect(failures.count == 1 && failures[0].hasPrefix("a: "))
    }

    @Test func badResponsesStoreNothing() async throws {
        let db = try exportFixtureDB()
        let wrongNonce: Anchorer.Transport = { _, req in try exportFakeResponse(for: req, nonceOverride: [9, 9]) }
        let rejected: Anchorer.Transport = { _, req in try exportFakeResponse(for: req, status: 2) }
        let offline: Anchorer.Transport = { _, _ in throw URLError(.notConnectedToInternet) }
        for t in [wrongNonce, rejected, offline] {
            guard case let .done(anchored, failures) = try await run(db, at: day1, transport: t) else {
                Issue.record("expected done"); return
            }
            #expect(anchored.isEmpty && failures.count == 2)
        }
        #expect(try AnchorStore(db).list().isEmpty)
        // Back online: one anchor per TSA covers everything.
        guard case let .done(anchored, _) = try await run(db, at: day1) else { Issue.record("online"); return }
        #expect(anchored.count == 2)
    }
}
