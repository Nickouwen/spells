import HoursCore

// Pure engine vocabulary. No AppKit/AX/IOKit here — adapters translate the OS into these.

/// What the adapters saw in the frontmost app. Raw: the engine sanitizes it.
public struct TrackerObservation: Equatable, Sendable {
    public var bundleId: String?
    public var appName: String
    /// nil when Accessibility isn't granted or the app exposes no window title.
    public var title: String?
    public var url: String?
    /// Private/incognito window (or a browser whose privacy can't be proven) → title + url dropped.
    public var isPrivate: Bool

    public init(bundleId: String?, appName: String, title: String? = nil, url: String? = nil, isPrivate: Bool = false) {
        self.bundleId = bundleId; self.appName = appName; self.title = title; self.url = url; self.isPrivate = isPrivate
    }
}

/// Readings taken by the adapter at the moment of every event. Wall = Unix ms UTC (placement);
/// mono = continuous monotonic ms (clock-jump detection only).
public struct TrackerSample: Equatable, Sendable {
    public var wallMs: Int64
    public var monoMs: Int64
    /// Milliseconds since the last HID input.
    public var idleMs: Int64
    /// Frontmost app holds a display-sleep assertion (video, call). Only meaningful when idle ≥ threshold.
    public var heldActive: Bool
    public var tzId: String
    public var tzOffsetS: Int
    /// Console session state, read on the 30 s tick so a missed lock/unlock/session notification
    /// self-heals; nil = unknown (no re-derive).
    public var session: TrackerSession?

    public init(wallMs: Int64, monoMs: Int64, idleMs: Int64 = 0, heldActive: Bool = false,
                tzId: String, tzOffsetS: Int) {
        self.wallMs = wallMs; self.monoMs = monoMs; self.idleMs = idleMs; self.heldActive = heldActive
        self.tzId = tzId; self.tzOffsetS = tzOffsetS
    }
}

/// `CGSessionCopyCurrentDictionary` reduced to the two gates it can re-derive.
public struct TrackerSession: Equatable, Sendable {
    public var locked: Bool
    /// false while another user is switched in (fast user switching).
    public var onConsole: Bool
    public init(locked: Bool, onConsole: Bool) { self.locked = locked; self.onConsole = onConsole }
}

public enum TrackerEvent: Equatable, Sendable {
    /// Front app activated or its focused window/title/url changed (AX notification or tick backstop).
    case observed(TrackerObservation)
    case debounceFired
    case tick
    case willSleep, didWake
    case screensSlept, screensWoke
    case locked, unlocked
    case sessionResigned, sessionActivated
    /// Detection is sample-based (wall−mono offset, tz in sample); these just force a step.
    case clockChanged, timeZoneChanged
    /// User pause: close the live span, open nothing until `untilMs` (nil = resume now).
    case pause(untilMs: Int64?)
    /// Logout/restart/shutdown requested. Not sticky: it can be cancelled, so tracking resumes on
    /// the next input after it. A real shutdown ends with SIGTERM → `terminate`.
    case powerOff
    case terminate
}

/// Why a span closed. Not in `RawSpan` (contract has no column for it); sinks may log or persist it.
public enum EndReason: String, Codable, Sendable {
    case `switch`, afk, resume, sleep, lock, session, excluded, clock, timezone, pause, powerOff, terminate
}

public enum TrackerOutput: Equatable, Sendable {
    /// No live span existed; start this one (seq 0, endMs == startMs).
    case open(RawSpan)
    /// Swap the live span without chaining it (it would have been zero-length). nil = drop it.
    case replace(RawSpan?)
    /// Chain the live span ending at `atMs`; optionally start `next`.
    case close(atMs: Int64, reason: EndReason, next: RawSpan?)
    case heartbeat(lastSeenMs: Int64)
    /// (Re)arm the one-shot 1 s debounce timer; adapter sends `.debounceFired` when it fires.
    case armDebounce
    case cancelDebounce
}

public struct TrackerConfig: Sendable {
    public var idleThresholdMs: Int64
    public var excludedBundles: Set<String>
    /// Wall−mono offset change that counts as a clock jump.
    public var clockJumpToleranceMs: Int64

    public init(idleThresholdMs: Int64 = 300_000,
                excludedBundles: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"],
                clockJumpToleranceMs: Int64 = 2_000) {
        self.idleThresholdMs = idleThresholdMs; self.excludedBundles = excludedBundles
        self.clockJumpToleranceMs = clockJumpToleranceMs
    }
}
