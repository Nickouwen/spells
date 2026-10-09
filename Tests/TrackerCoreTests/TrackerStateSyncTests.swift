import Foundation
import Testing
import notify
import HoursCore
@testable import TrackerCore

// W16: live settings into the running helper, tracker_state out. The runtime is never started
// (no OS observers); `apply()` / `report()` are driven directly.

private final class NullSink: TrackerSink {
    func open(live: RawSpan) {}
    func replace(live: RawSpan?) {}
    func close(at endMs: Int64, reason: EndReason, next: RawSpan?) {}
    func heartbeat(lastSeenMs: Int64) {}
}

@MainActor
private func fixture() throws -> (HoursDB, TrackerRuntime, TrackerStateSync) {
    let url = FileManager.default.temporaryDirectory.appending(path: "hours-sync-\(UUID().uuidString)/hours.db")
    let db = try HoursDB.open(at: url, role: .tracker, notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
    let runtime = TrackerRuntime(sink: NullSink(), options: .init(promptForPermissions: false))
    let sync = TrackerStateSync(db: db, runtime: runtime, lastWriteFailed: { false }, version: "t", pid: 4242)
    return (db, runtime, sync)
}

@MainActor @Test func appliesIdleThresholdAndPauseFromSettings() throws {
    let (db, runtime, sync) = try fixture()
    let settings = SettingStore(db)
    let now = TrackerStateSync.wallMs()
    sync.apply(nowMs: now)
    #expect(runtime.idleThresholdMs == 300_000)          // default
    #expect(runtime.pausedUntilMs == nil)

    try settings.set(TrackerIdleSetting.key, "120")
    try TrackerPauseSetting.save(settings, untilMs: now + 600_000)
    sync.apply(nowMs: now)
    #expect(runtime.idleThresholdMs == 120_000)
    #expect(runtime.pausedUntilMs == now + 600_000)

    try TrackerPauseSetting.save(settings, untilMs: nil)  // Resume from the app
    sync.apply(nowMs: now)
    #expect(runtime.pausedUntilMs == nil)
}

@MainActor @Test func idleOverrideWinsOverSetting() throws {
    let (db, runtime, sync) = try fixture()
    try SettingStore(db).set(TrackerIdleSetting.key, "120")
    sync.idleOverrideMs = 100_000_000
    sync.apply()
    #expect(runtime.idleThresholdMs == 100_000_000)
}

@MainActor @Test func reportWritesOnlyOnChangeAndPostsForStateChanges() async throws {
    let (db, runtime, sync) = try fixture()
    var token: Int32 = 0
    nonisolated(unsafe) var posts = 0
    notify_register_dispatch(db.notifyName, &token, .main) { _ in posts += 1 }
    defer { notify_cancel(token) }

    sync.report()
    let first = try #require(TrackerState.decode(try SettingStore(db).get(TrackerState.key)))
    #expect(first.pid == 4242 && first.version == "t" && first.pausedUntilMs == nil && !first.lastWriteFailed)
    try await Task.sleep(for: .milliseconds(100))
    #expect(posts == 1)

    sync.report()                                         // unchanged: no write, no post
    try await Task.sleep(for: .milliseconds(100))
    #expect(posts == 1)

    let until = TrackerStateSync.wallMs() + 600_000
    runtime.pause(untilMs: until)
    sync.report()
    try await Task.sleep(for: .milliseconds(100))
    #expect(posts == 2)
    #expect(TrackerState.decode(try SettingStore(db).get(TrackerState.key))?.pausedUntilMs == until)
}
