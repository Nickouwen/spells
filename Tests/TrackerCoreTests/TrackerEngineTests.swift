import Testing
import HoursCore
@testable import TrackerCore

// Hand-built event scripts → exact emitted outputs. Wall == mono unless a test jumps the clock.

private let NY = "America/New_York", nyOff = -14_400
private let T: Int64 = 300_000 // idle threshold

private func s(_ wall: Int64, idle: Int64 = 0, mono: Int64? = nil, held: Bool = false,
               tz: String = NY, off: Int = nyOff, session: TrackerSession? = nil) -> TrackerSample {
    var x = TrackerSample(wallMs: wall, monoMs: mono ?? wall, idleMs: idle, heldActive: held, tzId: tz, tzOffsetS: off)
    x.session = session
    return x
}

private func obs(_ app: String, _ title: String? = nil, url: String? = nil, priv: Bool = false) -> TrackerEvent {
    .observed(TrackerObservation(bundleId: "b.\(app)", appName: app, title: title, url: url, isPrivate: priv))
}

private func span(_ app: String, _ start: Int64, _ kind: SpanKind = .active, title: String? = nil,
                  url: String? = nil, tz: String = NY, off: Int = nyOff) -> RawSpan {
    RawSpan(seq: 0, startMs: start, endMs: start, tzId: tz, tzOffsetS: off, kind: kind,
            bundleId: "b.\(app)", appName: app, title: title, url: url)
}

/// Engine already showing app A since t=0.
private func engineOnA() -> TrackerEngine {
    var e = TrackerEngine(config: TrackerConfig(idleThresholdMs: T, excludedBundles: ["b.loginwindow"]))
    #expect(e.handle(obs("A"), s(0)) == [.open(span("A", 0))])
    return e
}

@Test func activationSwitchCommitsAtActivationTime() {
    var e = engineOnA()
    #expect(e.handle(obs("B"), s(5_000)) == [.armDebounce])
    #expect(e.handle(.debounceFired, s(6_000)) == [.close(atMs: 5_000, reason: .switch, next: span("B", 5_000))])
}

@Test func rapidSwitchingCreatesNoTransitSpans() {
    var e = engineOnA()
    #expect(e.handle(obs("B"), s(10_000)) == [.armDebounce])
    #expect(e.handle(obs("C"), s(10_200)) == [.armDebounce])
    #expect(e.handle(obs("D"), s(10_400)) == [.armDebounce])
    #expect(e.handle(.debounceFired, s(11_400)) == [.close(atMs: 10_400, reason: .switch, next: span("D", 10_400))])
}

@Test func titleFlickerIsDebouncedAway() {
    var e = TrackerEngine(config: TrackerConfig(idleThresholdMs: T))
    #expect(e.handle(obs("A", "Video"), s(0)) == [.open(span("A", 0, title: "Video"))])
    #expect(e.handle(obs("A", "(3) Video"), s(1_000)) == [.armDebounce])
    #expect(e.handle(obs("A", "Video"), s(1_400)) == [.cancelDebounce])
    #expect(e.handle(.debounceFired, s(2_000)) == []) // a late fire with nothing pending is a no-op
    // A real title change commits at the time it was first seen.
    #expect(e.handle(obs("A", "Docs"), s(3_000)) == [.armDebounce])
    #expect(e.handle(obs("A", "Docs"), s(3_500)) == []) // duplicate notification keeps the original timestamp
    #expect(e.handle(.debounceFired, s(4_000))
            == [.close(atMs: 3_000, reason: .switch, next: span("A", 3_000, title: "Docs"))])
}

@Test func idleIsBackDatedToLastInputAndReturnStartsAtReturnInput() {
    var e = engineOnA()
    #expect(e.handle(.tick, s(30_000)) == [.heartbeat(lastSeenMs: 30_000)])
    // Detected at 400 s with 350 s idle → last input was at 50 s.
    #expect(e.handle(.tick, s(400_000, idle: 350_000))
            == [.close(atMs: 50_000, reason: .afk, next: span("A", 50_000, .idle)), .heartbeat(lastSeenMs: 400_000)])
    // Back at 425 s (noticed at 430 s, idle 5 s).
    #expect(e.handle(.tick, s(430_000, idle: 5_000))
            == [.close(atMs: 425_000, reason: .resume, next: span("A", 425_000)), .heartbeat(lastSeenMs: 430_000)])
}

@Test func displayAssertionHoldsActiveThenClosesAtLastConfirmedHold() {
    var e = engineOnA()
    #expect(e.handle(.tick, s(400_000, idle: 350_000, held: true)) == [.heartbeat(lastSeenMs: 400_000)])
    // Video paused: still idle, no hold → AFK from the last held tick, not from the last input (50 s).
    #expect(e.handle(.tick, s(430_000, idle: 380_000))
            == [.close(atMs: 400_000, reason: .afk, next: span("A", 400_000, .idle)), .heartbeat(lastSeenMs: 430_000)])
}

@Test func sleepClosesAndWakeWithoutInputOpensNothing() {
    var e = engineOnA()
    #expect(e.handle(.willSleep, s(100_000, idle: 1_000)) == [.close(atMs: 100_000, reason: .sleep, next: nil)])
    // Dark wake: no input since before sleep.
    #expect(e.handle(.didWake, s(200_000, idle: 120_000 + T)) == [])
    #expect(e.handle(.tick, s(215_000, idle: 135_000 + T)) == [])
    // Touch at 228 s, noticed by the next tick: span starts at the touch.
    #expect(e.handle(.tick, s(230_000, idle: 2_000)) == [.open(span("A", 228_000)), .heartbeat(lastSeenMs: 230_000)])
}

@Test func sleepWhileAfkBackDatesFirst() {
    var e = engineOnA()
    #expect(e.handle(.willSleep, s(400_000, idle: 350_000)) == [
        .close(atMs: 50_000, reason: .afk, next: span("A", 50_000, .idle)),
        .close(atMs: 400_000, reason: .sleep, next: nil),
    ])
}

@Test func lockAndUnlockLeaveAGap() {
    var e = engineOnA()
    #expect(e.handle(.locked, s(60_000)) == [.close(atMs: 60_000, reason: .lock, next: nil)])
    #expect(e.handle(.tick, s(70_000)) == []) // no heartbeat without a live span
    // Unlock typing ended 0.5 s before the notification; never back-date past the gate opening.
    #expect(e.handle(.unlocked, s(90_000, idle: 500)) == [.open(span("A", 90_000))])
}

@Test func sessionResignClosesSpan() {
    var e = engineOnA()
    #expect(e.handle(.sessionResigned, s(60_000)) == [.close(atMs: 60_000, reason: .session, next: nil)])
    #expect(e.handle(.sessionActivated, s(120_000, idle: 100)) == [.open(span("A", 120_000))])
}

@Test func backwardsClockJumpNeverOverlaps() {
    let start: Int64 = 10_000_000
    var e = TrackerEngine(config: TrackerConfig(idleThresholdMs: T))
    #expect(e.handle(obs("A"), s(start, mono: 0)) == [.open(span("A", start))])
    // Wall goes back 1 h at mono 20 s: close at start + 20 s (old frame); reopen clamped to that end.
    let jumped = start + 20_000 - 3_600_000
    #expect(e.handle(.clockChanged, s(jumped, mono: 20_000))
            == [.close(atMs: start + 20_000, reason: .clock, next: span("A", start + 20_000))])
    // Until wall catches up, every boundary is clamped to the floor: heartbeat pinned, zero-length span dropped.
    #expect(e.handle(.tick, s(jumped + 30_000, mono: 50_000)) == [.heartbeat(lastSeenMs: start + 20_000)])
    #expect(e.handle(.locked, s(jumped + 40_000, mono: 60_000)) == [.replace(nil)])
}

@Test func forwardClockJumpLeavesGapWithExactDuration() {
    var e = TrackerEngine(config: TrackerConfig(idleThresholdMs: T))
    #expect(e.handle(obs("A"), s(0, mono: 0)) == [.open(span("A", 0))])
    #expect(e.handle(.tick, s(3_630_000, mono: 30_000))
            == [.close(atMs: 30_000, reason: .clock, next: span("A", 3_630_000)), .heartbeat(lastSeenMs: 3_630_000)])
}

@Test func timeZoneChangeClosesSpan() {
    var e = engineOnA()
    let la = "America/Los_Angeles", laOff = -25_200
    #expect(e.handle(.timeZoneChanged, s(60_000, tz: la, off: laOff))
            == [.close(atMs: 60_000, reason: .timezone, next: span("A", 60_000, tz: la, off: laOff))])
}

@Test func urlIsStrippedAndTitleTruncatedBeforeEmitting() {
    var e = TrackerEngine(config: TrackerConfig(idleThresholdMs: T))
    let long = String(repeating: "x", count: 300)
    #expect(e.handle(obs("Chrome", long, url: "https://a.com/p/q?token=s3cret#frag"), s(0))
            == [.open(span("Chrome", 0, title: String(repeating: "x", count: 256), url: "https://a.com/p/q"))])
}

@Test func privateWindowDropsTitleAndURL() {
    var e = engineOnA()
    #expect(e.handle(obs("Chrome", "Secret page", url: "https://bank.com/acct", priv: true), s(1_000)) == [.armDebounce])
    #expect(e.handle(.debounceFired, s(2_000)) == [.close(atMs: 1_000, reason: .switch, next: span("Chrome", 1_000))])
}

@Test func noAccessibilityStillRecordsAppNames() {
    var e = TrackerEngine(config: TrackerConfig(idleThresholdMs: T))
    #expect(e.handle(obs("A", nil), s(0)) == [.open(span("A", 0))])
    #expect(e.handle(obs("B", nil), s(5_000)) == [.armDebounce])
    #expect(e.handle(.debounceFired, s(6_000)) == [.close(atMs: 5_000, reason: .switch, next: span("B", 5_000))])
}

@Test func excludedFrontAppClosesAndReturnReopens() {
    var e = engineOnA()
    #expect(e.handle(obs("loginwindow"), s(10_000)) == [.armDebounce])
    #expect(e.handle(.debounceFired, s(11_000)) == [.close(atMs: 10_000, reason: .excluded, next: nil)])
    #expect(e.handle(obs("A"), s(50_000)) == [.armDebounce])
    // Switch input at 50 s (idle 1 s at fire time) → span starts at the switch.
    #expect(e.handle(.debounceFired, s(51_000, idle: 1_000)) == [.open(span("A", 50_000))])
}

@Test func launchingWhileAfkOpensNothingUntilInput() {
    var e = TrackerEngine(config: TrackerConfig(idleThresholdMs: T))
    #expect(e.handle(obs("A"), s(0, idle: 600_000)) == [])
    #expect(e.handle(.tick, s(30_000, idle: 4_000)) == [.open(span("A", 26_000)), .heartbeat(lastSeenMs: 30_000)])
}

@Test func terminateClosesAndStaysClosed() {
    var e = engineOnA()
    #expect(e.handle(.terminate, s(9_000)) == [.close(atMs: 9_000, reason: .terminate, next: nil)])
    #expect(e.handle(.tick, s(10_000)) == [])
}

/// Review-1 #2: willPowerOff closes the span but isn't sticky. A cancelled logout/shutdown resumes
/// on the first input after the event (not before it).
@Test func cancelledPowerOffResumesOnInput() {
    var e = engineOnA()
    #expect(e.handle(.powerOff, s(60_000)) == [.close(atMs: 60_000, reason: .powerOff, next: nil)])
    #expect(e.handle(.tick, s(90_000, idle: 40_000)) == [])   // last input at 50 s, before the event
    #expect(e.handle(.tick, s(120_000, idle: 2_000)) == [.open(span("A", 118_000)), .heartbeat(lastSeenMs: 120_000)])
}

/// Sticky gates self-heal: the tick re-derives lock / console state from the session dictionary, so a
/// missed unlock or session-activate notification can't stop tracking for good (and a missed lock
/// can't keep it running).
@Test func lockAndSessionGatesAreRederivedOnTheTick() {
    let unlocked = TrackerSession(locked: false, onConsole: true)
    var e = engineOnA()
    #expect(e.handle(.locked, s(60_000)) == [.close(atMs: 60_000, reason: .lock, next: nil)])
    #expect(e.handle(.tick, s(90_000, idle: 1_000, session: TrackerSession(locked: true, onConsole: true))) == [])
    // Password typed, no unlock notification: the tick notices, and the span starts at the tick.
    #expect(e.handle(.tick, s(120_000, idle: 1_000, session: unlocked))
            == [.open(span("A", 120_000)), .heartbeat(lastSeenMs: 120_000)])
    #expect(e.handle(.sessionResigned, s(150_000)) == [.close(atMs: 150_000, reason: .session, next: nil)])
    #expect(e.handle(.tick, s(180_000, idle: 500, session: unlocked))
            == [.open(span("A", 180_000)), .heartbeat(lastSeenMs: 180_000)])
    // A missed lock notification: the tick closes the span.
    #expect(e.handle(.tick, s(210_000, session: TrackerSession(locked: true, onConsole: true)))
            == [.close(atMs: 210_000, reason: .lock, next: nil)])
    // Non-tick events don't re-derive (their notification is the source of truth).
    #expect(e.handle(.unlocked, s(240_000, idle: 500)) == [.open(span("A", 240_000))])
}

/// A missed didWake / screensWoke heals on the first input after sleeping (no input = dark wake).
@Test func sleepGatesHealOnInputAfterSleeping() {
    var e = engineOnA()
    #expect(e.handle(.willSleep, s(100_000)) == [.close(atMs: 100_000, reason: .sleep, next: nil)])
    #expect(e.handle(.tick, s(200_000, idle: 150_000)) == [])   // last input at 50 s: still asleep as far as we know
    #expect(e.handle(.tick, s(230_000, idle: 2_000)) == [.open(span("A", 228_000)), .heartbeat(lastSeenMs: 230_000)])
    #expect(e.handle(.screensSlept, s(260_000)) == [.close(atMs: 260_000, reason: .sleep, next: nil)])
    #expect(e.handle(.tick, s(300_000, idle: 1_000)) == [.open(span("A", 299_000)), .heartbeat(lastSeenMs: 300_000)])
}
