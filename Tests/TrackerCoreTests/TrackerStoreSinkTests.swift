import Foundation
import SQLite3
import Testing
import HoursCore
@testable import TrackerCore

// TrackerSink → SpanWriter against a real temp DB (never ~/Library), unique notify name.

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "hours-sink-tests/\(UUID().uuidString)/hours.db")
}

private func openDB(_ url: URL) throws -> HoursDB {
    try HoursDB.open(at: url, role: .tracker, notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
}

private func live(_ app: String, _ start: Int64, title: String? = nil) -> RawSpan {
    RawSpan(seq: 0, startMs: start, endMs: start, tzId: "UTC", tzOffsetS: 0, kind: .active,
            bundleId: "b.\(app)", appName: app, title: title, url: nil)
}

/// (seq, start, end, app) of every chained span.
private func chained(_ db: HoursDB) throws -> [[String]] {
    try Store(db).rawSpans(from: .min, to: .max).map { ["\($0.seq)", "\($0.startMs)", "\($0.endMs)", $0.appName] }
}

private let oct5noon: Int64 = 1_791_201_600_000   // 2026-10-05T12:00:00Z

@Test func openAndCloseChainContiguousSpans() throws {
    let db = try openDB(tempURL())
    let sink = TrackerStoreSink(SpanWriter(db), nowMs: 1000, timeZone: .gmt)
    sink.open(live: live("A", 1000))
    sink.close(at: 5000, reason: .switch, next: live("B", 5000))
    sink.close(at: 9000, reason: .terminate, next: nil)
    #expect(try chained(db) == [["1", "1000", "5000", "A"], ["2", "5000", "9000", "B"]])
    #expect(try SpanWriter(db).liveSpan() == nil)
    #expect(try ChainVerifier.verify(db).ok)
    #expect(sink.pendingCount == 0)
}

@Test func replaceSwapsTheLiveSpanWithoutChaining() throws {
    let db = try openDB(tempURL())
    let sink = TrackerStoreSink(SpanWriter(db), nowMs: 1000, timeZone: .gmt)
    sink.open(live: live("A", 1000))
    sink.replace(live: live("B", 1000))
    #expect(try SpanWriter(db).liveSpan()?.appName == "B")
    sink.replace(live: nil)
    #expect(try SpanWriter(db).liveSpan() == nil)
    #expect(try db.head().seq == 0)
}

@Test func heartbeatSetsTheRecoveryPointAfterACrash() throws {
    let url = tempURL()
    let db = try openDB(url)
    let sink = TrackerStoreSink(SpanWriter(db), nowMs: 1000, timeZone: .gmt)
    sink.open(live: live("A", 1000))
    sink.heartbeat(lastSeenMs: 31_000)
    sink.heartbeat(lastSeenMs: 20_000)   // never moves back
    // "kill -9": no close. A fresh process recovers the live row at its last heartbeat.
    let relaunched = try openDB(url)
    #expect(try SpanWriter(relaunched).recoverLiveSpan() == 1)
    #expect(try chained(relaunched) == [["1", "1000", "31000", "A"]])
    #expect(try SpanWriter(relaunched).liveSpan() == nil)
}

@Test func dayRolloverFiresOncePerNewLocalDay() throws {
    let db = try openDB(tempURL())
    var fired: [Int64] = []
    var last: Int64 = 0
    let sink = TrackerStoreSink(SpanWriter(db), nowMs: oct5noon, timeZone: .gmt) { fired.append(last) }
    func at(_ ms: Int64, _ f: () -> Void) { last = ms; f() }
    let h: Int64 = 3_600_000
    at(oct5noon + 11 * h) { sink.open(live: live("A", oct5noon + 11 * h)) }          // 23:00, same day
    at(oct5noon + 12 * h - 30_000) { sink.heartbeat(lastSeenMs: oct5noon + 12 * h - 30_000) }
    at(oct5noon + 12 * h + 10_000) { sink.heartbeat(lastSeenMs: oct5noon + 12 * h + 10_000) }  // 00:00:10 → fire
    at(oct5noon + 12 * h + 40_000) { sink.heartbeat(lastSeenMs: oct5noon + 12 * h + 40_000) }
    at(oct5noon + 13 * h) { sink.close(at: oct5noon + 13 * h, reason: .sleep, next: nil) }
    // Slept through the next midnight; the first span after wake fires it.
    at(oct5noon + 60 * h) { sink.open(live: live("B", oct5noon + 60 * h)) }
    #expect(fired == [oct5noon + 12 * h + 10_000, oct5noon + 60 * h])
}

@Test func nulBytesAreStrippedRatherThanDroppingTheSpan() throws {
    let db = try openDB(tempURL())
    let sink = TrackerStoreSink(SpanWriter(db), nowMs: 1000, timeZone: .gmt)
    sink.open(live: live("A", 1000, title: "a\0b"))
    #expect(try SpanWriter(db).liveSpan()?.title == "ab")
}

/// The app holding the write lock past busy_timeout (5 s): the write is queued, not lost,
/// and replayed in order at the next call.
@Test func busyWritesAreQueuedAndReplayed() throws {
    let url = tempURL()
    let db = try openDB(url)
    let sink = TrackerStoreSink(SpanWriter(db), nowMs: 1000, timeZone: .gmt)

    var other: OpaquePointer?
    #expect(sqlite3_open(url.path, &other) == SQLITE_OK)
    defer { sqlite3_close(other) }
    #expect(sqlite3_exec(other, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
    sink.open(live: live("A", 1000))
    #expect(sink.pendingCount == 1)
    #expect(sqlite3_exec(other, "COMMIT", nil, nil, nil) == SQLITE_OK)

    sink.heartbeat(lastSeenMs: 2000)  // the retry clock
    #expect(sink.pendingCount == 0)
    #expect(try SpanWriter(db).liveSpan()?.endMs == 2000)
    sink.close(at: 3000, reason: .switch, next: nil)
    #expect(try chained(db) == [["1", "1000", "3000", "A"]])
}

/// Review-1 #1 (the reviewer's probe): the wall clock comes back *behind* the chain's last end
/// (a heartbeat taken before a restart with a backwards clock). The overlap trigger used to abort
/// every close, so the stale live row could never chain and tracking was wedged for good.
@Test func clockBehindTheChainClampsInsteadOfWedging() throws {
    let db = try openDB(tempURL())
    let w = SpanWriter(db)
    try w.append(RawSpan(seq: 0, startMs: 0, endMs: 60_000, tzId: "UTC", tzOffsetS: 0, kind: .active,
                         bundleId: "b.Prev", appName: "Prev", title: nil, url: nil))
    let sink = TrackerStoreSink(w, nowMs: 10_000, timeZone: .gmt)
    sink.open(live: live("A", 10_000))                                  // 50 s behind the chain end
    sink.close(at: 30_000, reason: .switch, next: live("B", 30_000))   // A lies wholly before it: dropped
    sink.close(at: 90_000, reason: .switch, next: live("C", 90_000))   // B clamped to [60 s, 90 s)
    sink.close(at: 120_000, reason: .terminate, next: nil)
    #expect(try chained(db) == [["1", "0", "60000", "Prev"], ["2", "60000", "90000", "B"], ["3", "90000", "120000", "C"]])
    #expect(try w.liveSpan() == nil)
    #expect(try ChainVerifier.verify(db).ok)
    #expect(!sink.lastWriteFailed)
}

/// Any other non-busy failure (here a NUL in `next`'s tz id, which `clean` doesn't strip) must not
/// leave the old live row behind: it would later chain with the wrong end. The sink resyncs —
/// chains the old span at the intended end and skips the unstorable one.
@Test func nonBusyFailureResyncsTheLiveRow() throws {
    let db = try openDB(tempURL())
    let sink = TrackerStoreSink(SpanWriter(db), nowMs: 1000, timeZone: .gmt)
    sink.open(live: live("A", 1000))
    var bad = live("B", 5000)
    bad.tzId = "U\0TC"
    sink.close(at: 5000, reason: .switch, next: bad)
    #expect(sink.lastWriteFailed)
    #expect(try SpanWriter(db).liveSpan() == nil)
    sink.close(at: 9000, reason: .switch, next: live("C", 9000))
    #expect(try SpanWriter(db).liveSpan()?.appName == "C")
    sink.close(at: 12_000, reason: .terminate, next: nil)
    #expect(try chained(db) == [["1", "1000", "5000", "A"], ["2", "9000", "12000", "C"]])
    #expect(try ChainVerifier.verify(db).ok)
    #expect(sink.pendingCount == 0 && !sink.lastWriteFailed)
}

/// Two-process check, run by hand while HoursSpell writes the same file:
/// `HOURS_LIVE_DB=$SPELLS_HOME/hours.db [HOURS_LIVE_EDITS=200 HOURS_LIVE_PACE_MS=0] swift test --filter TrackerStoreSinkLiveDB`.
/// Interleaves edits (the app's writes) into the helper's chain, then verifies it.
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOURS_LIVE_DB"] != nil))
func TrackerStoreSinkLiveDB() throws {
    let env = ProcessInfo.processInfo.environment
    let db = try HoursDB.open(at: URL(filePath: env["HOURS_LIVE_DB"]!), role: .app,
                              notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
    let n = Int64(env["HOURS_LIVE_EDITS"] ?? "") ?? 200
    let paceMs = UInt32(env["HOURS_LIVE_PACE_MS"] ?? "") ?? 0  // spread edits across the helper's writes
    let before = try db.head().seq
    for i in 0..<n {  // 1970 ranges: never clamped by the live span, never touch real spans
        _ = try EditWriter(db).apply([.add(i * 1000, i * 1000 + 500, label: "probe")], tzId: "UTC")
        if paceMs > 0 { usleep(paceMs * 1000) }
    }
    let result = try ChainVerifier.verify(db)
    #expect(result.ok, "\(result)")
    #expect(try db.head().seq >= before + n)
    print("live db: head \(try db.head().seq), verify \(result)")
}

/// Wedge-repro seed (review-1 #1), run by hand on a temp home before starting HoursSpell on it:
/// `HOURS_SEED_FUTURE_DB=$SPELLS_HOME/hours.db [HOURS_SEED_AHEAD_S=90] swift test --filter TrackerStoreSinkSeedFuture`.
/// Chains a span ending N s in the future, as if the clock went back after the last heartbeat.
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOURS_SEED_FUTURE_DB"] != nil))
func TrackerStoreSinkSeedFuture() throws {
    let env = ProcessInfo.processInfo.environment
    let db = try HoursDB.open(at: URL(filePath: env["HOURS_SEED_FUTURE_DB"]!), role: .app,
                              notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let end = now + (Int64(env["HOURS_SEED_AHEAD_S"] ?? "") ?? 90) * 1000
    try SpanWriter(db).append(RawSpan(seq: 0, startMs: now - 600_000, endMs: end, tzId: "UTC", tzOffsetS: 0, kind: .active,
                                      bundleId: "seed.future", appName: "SeedFuture", title: nil, url: nil))
    print("seeded future span: chain end \(end) (now \(now))")
}
