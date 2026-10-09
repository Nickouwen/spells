import Foundation
import HoursCore
import notify

/// Two-way link between the running helper and the store's `setting` table (W16):
/// - **in:** on every `Hours.dbChangedNotification` (notify_register_dispatch, no polling) re-read
///   `idle_threshold_s` and `pause_until_ms` and apply them to the runtime live;
/// - **out:** `report()` writes `tracker_state` when its value changed. Call it on start and from
///   `TrackerRuntime.onChange` (every event, incl. the 30 s tick).
/// A change of `last_event_ms` alone is written without a change-feed post: it only moves next to a
/// span write, which already posted. Everything else (AX, pause, write failure) posts, so the app
/// refreshes its health without polling.
@MainActor public final class TrackerStateSync {
    private let settings: SettingStore
    private let notifyName: String
    private let runtime: TrackerRuntime
    private let lastWriteFailed: () -> Bool
    private let version: String
    private let pid: Int32
    private var token: Int32 = NOTIFY_TOKEN_INVALID
    private var written: TrackerState?
    private var seenLive = false
    private var lastLiveStart: Int64?
    private var lastEventMs: Int64?

    public init(db: HoursDB, runtime: TrackerRuntime, lastWriteFailed: @escaping () -> Bool,
                version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.settings = SettingStore(db); self.notifyName = db.notifyName; self.runtime = runtime
        self.lastWriteFailed = lastWriteFailed; self.version = version; self.pid = pid
    }

    /// Debug `--idle-threshold`: wins over `idle_threshold_s`.
    public var idleOverrideMs: Int64?

    public static func wallMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// Subscribes to the change feed (main queue) and applies the stored settings once.
    public func start() {
        notify_register_dispatch(notifyName, &token, DispatchQueue.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        apply()
    }

    public func stop() {
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token); token = NOTIFY_TOKEN_INVALID }
    }

    /// Re-reads the two live settings; touches the runtime only when a value differs.
    public func apply(nowMs: Int64 = wallMs()) {
        do {
            let idleMs = try idleOverrideMs ?? Int64(TrackerIdleSetting.load(settings)) * 1000
            if idleMs != runtime.idleThresholdMs {
                runtime.idleThresholdMs = idleMs
                SupportLog.tracker.info("idle threshold \(idleMs / 1000)s")
            }
            let pause = try TrackerPauseSetting.load(settings, nowMs: nowMs)
            if pause != runtime.pausedUntilMs {
                runtime.pause(untilMs: pause)   // onChange → report()
                SupportLog.tracker.info("pause until \(pause.map { String($0) } ?? "resumed", privacy: .public) (from settings)")
            }
        } catch {
            SupportLog.tracker.error("settings reload failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The status row as of now.
    public func state(nowMs: Int64 = wallMs()) -> TrackerState {
        let live = runtime.liveStartMs
        if !seenLive {
            seenLive = true
            lastLiveStart = live
            lastEventMs = live   // the span open at launch (nil if none)
        } else if live != lastLiveStart {
            lastLiveStart = live
            lastEventMs = nowMs
        }
        return TrackerState(version: version, pid: pid, axTrusted: runtime.isAccessibilityTrusted,
                            lastEventMs: lastEventMs, pausedUntilMs: runtime.pausedUntilMs,
                            lastWriteFailed: lastWriteFailed())
    }

    /// Writes `tracker_state` if it changed since the last write.
    public func report(nowMs: Int64 = wallMs()) {
        let s = state(nowMs: nowMs)
        guard s != written else { return }
        var quiet = s
        quiet.lastEventMs = written?.lastEventMs
        do {
            try settings.set(TrackerState.key, s.json, notify: written == nil || quiet != written)
            written = s
        } catch {
            SupportLog.tracker.error("tracker_state write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
