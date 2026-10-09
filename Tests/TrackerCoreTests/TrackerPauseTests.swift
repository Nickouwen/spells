import Foundation
import Testing
import HoursCore
@testable import TrackerCore

// Pause (W15): the engine gate, plus `pause_until_ms` persistence across a simulated helper restart.

private let NY = "America/New_York", nyOff = -14_400
private let T: Int64 = 300_000 // idle threshold

private func s(_ wall: Int64, idle: Int64 = 0) -> TrackerSample {
    TrackerSample(wallMs: wall, monoMs: wall, idleMs: idle, tzId: NY, tzOffsetS: nyOff)
}

private func obs(_ app: String) -> TrackerEvent {
    .observed(TrackerObservation(bundleId: "b.\(app)", appName: app))
}

private func span(_ app: String, _ start: Int64) -> RawSpan {
    RawSpan(seq: 0, startMs: start, endMs: start, tzId: NY, tzOffsetS: nyOff, kind: .active,
            bundleId: "b.\(app)", appName: app, title: nil, url: nil)
}

private func engineOnA() -> TrackerEngine {
    var e = TrackerEngine(config: TrackerConfig(idleThresholdMs: T))
    #expect(e.handle(obs("A"), s(0)) == [.open(span("A", 0))])
    return e
}

@Test func pauseClosesLiveSpanAndSuppressesOpensUntilPauseEnd() {
    var e = engineOnA()
    #expect(e.handle(.pause(untilMs: 900_000), s(60_000)) == [.close(atMs: 60_000, reason: .pause, next: nil)])
    #expect(e.live == nil && e.pausedUntilMs == 900_000)
    // Activity while paused opens nothing; the front app still follows switches.
    #expect(e.handle(.tick, s(90_000)) == [])
    #expect(e.handle(obs("B"), s(100_000)) == [.armDebounce])
    #expect(e.handle(.debounceFired, s(101_000)) == [])
    #expect(e.handle(.tick, s(899_999)) == [])
    // First tick after the pause end: opens on B, back-dated to the pause end (last input 880 000 is earlier).
    #expect(e.handle(.tick, s(930_000, idle: 50_000)) == [.open(span("B", 900_000)), .heartbeat(lastSeenMs: 930_000)])
    #expect(e.pausedUntilMs == nil)
}

@Test func resumeReopensImmediately() {
    var e = engineOnA()
    _ = e.handle(.pause(untilMs: 10_000_000), s(60_000))
    #expect(e.handle(.pause(untilMs: nil), s(120_000)) == [.open(span("A", 120_000))])
    #expect(e.pausedUntilMs == nil)
}

@Test func resumeWhileAwayWaitsForInput() {
    var e = engineOnA()
    _ = e.handle(.pause(untilMs: 10_000_000), s(60_000))
    // Resumed with no input for 6 min: AFK, so nothing opens until the user is back.
    #expect(e.handle(.pause(untilMs: nil), s(400_000, idle: 360_000)) == [])
    #expect(e.handle(.tick, s(430_000, idle: 5_000)) == [.open(span("A", 425_000)), .heartbeat(lastSeenMs: 430_000)])
}

@Test func pauseInThePastIsANoOp() {
    var e = engineOnA()
    #expect(e.handle(.pause(untilMs: 50_000), s(60_000)) == [])
    #expect(e.live != nil && e.pausedUntilMs == nil)
}

@Test func pausePersistsAcrossSimulatedRestart() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "hours-pause-tests/\(UUID().uuidString)/hours.db")
    let notify = "dev.nic.spells.test.\(UUID().uuidString)"

    // Run 1: tracking A, then pause until 900 000 (what the status item does: persist, then pause).
    do {
        let db = try HoursDB.open(at: url, role: .tracker, notifyName: notify)
        let sink = TrackerStoreSink(SpanWriter(db), nowMs: 0, timeZone: .gmt)
        var e = TrackerEngine(config: TrackerConfig(idleThresholdMs: T))
        sink.apply(e.handle(obs("A"), s(0)))
        try TrackerPauseSetting.save(SettingStore(db), untilMs: 900_000)
        sink.apply(e.handle(.pause(untilMs: 900_000), s(60_000)))
        #expect(try SpanWriter(db).liveSpan() == nil)
        #expect(try Store(db).rawSpans(from: .min, to: .max).map { [$0.startMs, $0.endMs] } == [[0, 60_000]])
    }

    // Run 2: a fresh process — reopen, load the setting, re-apply it before the first observation.
    let db = try HoursDB.open(at: url, role: .tracker, notifyName: notify)
    let settings = SettingStore(db)
    #expect(try settings.get(TrackerPauseSetting.key) == "900000")
    let until = try #require(try TrackerPauseSetting.load(settings, nowMs: 120_000))
    let sink = TrackerStoreSink(SpanWriter(db), nowMs: 120_000, timeZone: .gmt)
    var e = TrackerEngine(config: TrackerConfig(idleThresholdMs: T))
    sink.apply(e.handle(.pause(untilMs: until), s(120_000)))
    sink.apply(e.handle(obs("A"), s(121_000)))
    sink.apply(e.handle(.tick, s(600_000)))
    #expect(try SpanWriter(db).liveSpan() == nil)
    sink.apply(e.handle(.tick, s(930_000, idle: 50_000)))
    #expect(try SpanWriter(db).liveSpan()?.startMs == 900_000)

    // Expired values read as "not paused"; resume removes the key.
    #expect(try TrackerPauseSetting.load(settings, nowMs: 900_000) == nil)
    try TrackerPauseSetting.save(settings, untilMs: nil)
    #expect(try settings.get(TrackerPauseSetting.key) == nil)
}
