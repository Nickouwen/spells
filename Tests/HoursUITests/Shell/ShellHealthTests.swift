import Foundation
import Testing
import HoursCore
@testable import HoursUI

@Suite struct ShellHealthTests {
    let now: Int64 = 10_000_000

    func span(_ start: Int64, _ end: Int64, title: String? = "t", seq: Int64 = 1) -> RawSpan {
        RawSpan(seq: seq, startMs: start, endMs: end, tzId: "UTC", tzOffsetS: 0, kind: .active,
                bundleId: "b", appName: "A", title: title, url: nil)
    }

    @Test func noDataIsUnknown() {
        #expect(ShellHealth.health(live: nil, recent: [], state: nil, nowMs: now) == .unknown)
    }

    @Test func staleHeartbeatIsStoppedAtLastSeen() {
        let live = span(now - 600_000, now - 121_000, seq: 0)
        #expect(ShellHealth.health(live: live, recent: [], state: nil, nowMs: now) == .stopped(atMs: now - 121_000))
        // No live span: last closed span end.
        #expect(ShellHealth.health(live: nil, recent: [span(0, 5_000)], state: nil, nowMs: now) == .stopped(atMs: 5_000))
    }

    @Test func trackingSinceStartOfUnbrokenRun() {
        let live = span(now - 60_000, now - 10_000, seq: 0)
        let recent = [span(1_000_000, 2_000_000),                 // before a long gap
                      span(now - 900_000, now - 400_000),
                      span(now - 350_000, now - 60_000)]          // 50 s gap: same run
        #expect(ShellHealth.health(live: live, recent: recent, state: nil, nowMs: now) == .tracking(sinceMs: now - 900_000))
    }

    func state(ax: Bool = true, paused: Int64? = nil) -> TrackerState {
        TrackerState(version: "t", pid: 4242, axTrusted: ax, lastEventMs: nil, pausedUntilMs: paused, lastWriteFailed: false)
    }

    @Test func accessibilityComesFromTrackerStateNotTitles() {
        let live = span(now - 30_000, now - 5_000, title: nil, seq: 0)
        let recent: [RawSpan] = (0..<6).map { (i: Int64) -> RawSpan in
            let start: Int64 = now - 600_000 + i * 50_000
            return span(start, start + 40_000, title: nil)
        }
        // Untitled spans alone no longer mean "permission missing".
        #expect(ShellHealth.health(live: live, recent: recent, state: nil, nowMs: now) == .tracking(sinceMs: now - 30_000))
        #expect(ShellHealth.health(live: live, recent: recent, state: state(ax: false), nowMs: now,
                                   isAlive: { _ in true }) == .permissionMissing)
        // A dead helper's row is ignored.
        #expect(ShellHealth.health(live: live, recent: recent, state: state(ax: false), nowMs: now,
                                   isAlive: { _ in false }) == .tracking(sinceMs: now - 30_000))
    }

    @Test func pausedUntilFromTrackerState() {
        let until = now + 1_800_000
        #expect(ShellHealth.health(live: nil, recent: [span(0, now - 60_000)], state: state(paused: until), nowMs: now,
                                   isAlive: { _ in true }) == .paused(untilMs: until))
        // An expired pause is just idle.
        #expect(ShellHealth.health(live: nil, recent: [span(0, now - 60_000)], state: state(paused: now - 1), nowMs: now,
                                   isAlive: { _ in true }) == .idle(sinceMs: now - 60_000))
        #expect(HealthPill(.paused(untilMs: 0), timeZone: TimeZone(identifier: "UTC")!).text == "Paused until 00:00")
    }

    @Test func runningHelperWithoutLiveSpanIsIdleNotStopped() {
        // Locked / asleep / away: no live span, but the helper is alive.
        #expect(ShellHealth.health(live: nil, recent: [span(0, 5_000)], state: state(), nowMs: now,
                                   isAlive: { _ in true }) == .idle(sinceMs: 5_000))
        #expect(ShellHealth.health(live: nil, recent: [], state: state(), nowMs: now, isAlive: { _ in true }) == .idle(sinceMs: nil))
        #expect(ShellHealth.health(live: nil, recent: [span(0, 5_000)], state: state(), nowMs: now,
                                   isAlive: { _ in false }) == .stopped(atMs: 5_000))
    }

    @Test func trackerStateRoundTripsAsSnakeCaseJSON() throws {
        let s = TrackerState(version: "1.0", pid: 7, axTrusted: true, lastEventMs: 5, pausedUntilMs: nil, lastWriteFailed: false)
        #expect(s.json == #"{"ax_trusted":true,"last_event_ms":5,"last_write_failed":false,"pid":7,"version":"1.0"}"#)
        #expect(TrackerState.decode(s.json) == s)
        #expect(TrackerState.decode("nope") == nil)
        #expect(TrackerState(version: "", pid: getpid(), axTrusted: true, lastEventMs: nil, pausedUntilMs: nil,
                             lastWriteFailed: false).isAlive)
    }

    @Test func bannerPriorities() {
        let tz = TimeZone(identifier: "UTC")!
        #expect(ShellBanner.content(helper: .running, health: .tracking(sinceMs: 0), timeZone: tz) == nil)
        #expect(ShellBanner.content(helper: .notBundled, health: .tracking(sinceMs: 0), timeZone: tz) == nil)
        #expect(ShellBanner.content(helper: .needsApproval, health: .tracking(sinceMs: 0), timeZone: tz)?.action == "Open Login Items")
        #expect(ShellBanner.content(helper: .running, health: .stopped(atMs: 0), timeZone: tz)?.action == "Start Tracker")
        #expect(ShellBanner.content(helper: .running, health: .permissionMissing, timeZone: tz)?.action == "Open Accessibility")
        #expect(ShellBanner.content(helper: .helperMissing, health: .unknown, timeZone: tz)?.action == nil)
        #expect(ShellBanner.content(helper: .failed("x"), health: .unknown, timeZone: tz)?.action == "Try Again")
    }
}
