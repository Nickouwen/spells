import Foundation

// Settings the helper and the app share through the store's `setting` table (unchained, mutable).
// The app writes `pause_until_ms` / `idle_threshold_s`; the helper applies them live on the change
// feed and writes back `tracker_state`, which the app reads instead of guessing from the spans.

/// `pause_until_ms`: survives a helper restart; Pause/Resume from the app or the status item.
/// Unix ms as a decimal string; absent (or in the past) = not paused.
public enum TrackerPauseSetting {
    public static let key = "pause_until_ms"

    /// The stored pause end if it's still in the future.
    public static func load(_ settings: SettingStore, nowMs: Int64) throws -> Int64? {
        try settings.get(key).flatMap { Int64($0) }.flatMap { $0 > nowMs ? $0 : nil }
    }

    /// nil (resume) removes the key.
    public static func save(_ settings: SettingStore, untilMs: Int64?) throws {
        try settings.set(key, untilMs.map { String($0) })
    }
}

/// `idle_threshold_s`: no input for this long = idle. Settings → Tracking.
public enum TrackerIdleSetting {
    public static let key = "idle_threshold_s"
    public static let defaultSeconds = 300

    /// Seconds; the default when absent or unparsable.
    public static func seconds(_ settings: [String: String]) -> Int {
        settings[key].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? defaultSeconds
    }

    public static func load(_ settings: SettingStore) throws -> Int {
        seconds(try settings.get(key).map { [key: $0] } ?? [:])
    }
}

/// The helper's status row (`tracker_state`, JSON). Written on start, on every state change and on
/// its 30 s tick — only when the value changed. A dead `pid` means the row is stale.
public struct TrackerState: Codable, Sendable, Equatable {
    public static let key = "tracker_state"

    /// Helper build (CFBundleShortVersionString, "dev" unbundled).
    public var version: String
    public var pid: Int32
    /// Accessibility granted to the helper (window titles are readable).
    public var axTrusted: Bool
    /// Wall time of the last span boundary (open/close/switch); nil until the first one.
    public var lastEventMs: Int64?
    /// Pause in force, as the helper applied it.
    public var pausedUntilMs: Int64?
    /// The helper's most recent span/heartbeat write failed.
    public var lastWriteFailed: Bool

    enum CodingKeys: String, CodingKey {
        case version, pid
        case axTrusted = "ax_trusted"
        case lastEventMs = "last_event_ms"
        case pausedUntilMs = "paused_until_ms"
        case lastWriteFailed = "last_write_failed"
    }

    public init(version: String, pid: Int32, axTrusted: Bool, lastEventMs: Int64?, pausedUntilMs: Int64?,
                lastWriteFailed: Bool) {
        self.version = version; self.pid = pid; self.axTrusted = axTrusted
        self.lastEventMs = lastEventMs; self.pausedUntilMs = pausedUntilMs; self.lastWriteFailed = lastWriteFailed
    }

    /// Sorted-key JSON, so equal states encode to equal strings.
    public var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: (try? enc.encode(self)) ?? Data(), as: UTF8.self)
    }

    public static func decode(_ json: String?) -> TrackerState? {
        json.flatMap { try? JSONDecoder().decode(TrackerState.self, from: Data($0.utf8)) }
    }

    /// The process is still there (same uid, no signal sent). EPERM = exists but not ours.
    public var isAlive: Bool { kill(pid, 0) == 0 || errno == EPERM }
}
