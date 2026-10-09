import Foundation
import Testing
import HoursCore
@testable import HoursUI

/// Review-1 fixes in the editing layer: history verify off the main actor, sub-second neighbours.
@Suite @MainActor struct EditingReview1Tests {
    typealias F = EditFixture

    /// Written by the verifier closure before the awaited task completes; read after.
    final class Seen: @unchecked Sendable { var onMain: Bool? }

    /// #4: the history sheet's chain verify (1.35 s at 365k rows) must not run on the main thread.
    @Test func historyVerifyRunsOffTheMainThread() async throws {
        let f = try F()
        let seen = Seen()
        let r = await EditHistory.verify(f.db) { db in
            seen.onMain = Thread.isMainThread
            return try ChainVerifier.verify(db)
        }
        #expect(r?.ok == true && r?.rows == 3)
        #expect(seen.onMain == false)
        #expect(await EditHistory.verify(f.db)?.ok == true)   // the default verifier
    }

    /// Follow-up: a 500 ms neighbour made moveBoundary build an inverted range (`lo..<hi`, hi < lo) and trap.
    @Test func moveBoundaryNextToASubSecondSpanDoesNotTrap() throws {
        let t = F.at(11, 30)
        let f = try F(extra: [F.raw(t, t + 500, "Mail", bundle: "com.apple.mail"),
                              F.raw(t + 500, F.at(11, 45), "Xcode", bundle: "com.apple.dt.Xcode")])
        let d = try #require(f.session.data)
        // Slack | Mail(500 ms): pushing the boundary later would shrink Mail below 1 s → nothing to do.
        #expect(EditPlanner.plan(.moveBoundary(from: t, to: F.at(11, 35)), selection: [], in: d) == nil)
        // Mail(500 ms) | Xcode: pulling the boundary earlier would shrink Mail below 1 s → nothing to do.
        #expect(EditPlanner.plan(.moveBoundary(from: t + 500, to: F.at(11, 25)), selection: [], in: d) == nil)
        // A normal-sized pair still moves: Slack | Mail boundary pulled earlier into Slack.
        let back = try #require(EditPlanner.plan(.moveBoundary(from: t, to: F.at(11, 20)), selection: [], in: d))
        #expect(back.drafts.count == 1)
    }
}
