import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import HoursCore

/// Thin OS readings: clocks, HID idle, display-sleep assertions, Automation permission.
enum TrackerSystem {
    static func wallMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// Continuous monotonic clock (keeps counting through sleep), so wall−mono only moves on clock changes.
    static func monoMs() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000) }

    /// Since last HID input. No permission needed (no event tap).
    static func idleMs() -> Int64 {
        let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return Int64(s * 1000)
    }

    /// Does `pid` hold a display-sleep assertion (video, call)? System-sleep assertions don't count.
    static func holdsDisplayAssertion(pid: pid_t) -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let byPid = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]],
              let mine = byPid[NSNumber(value: pid)] else { return false }
        let types: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
        return mine.contains { ($0["AssertType"] as? String).map(types.contains) ?? false }
    }

    /// Lock / console state of this login session; nil if the window server gives no dictionary.
    /// `CGSSessionScreenIsLocked` is undocumented but long-stable (present only while locked).
    static func session() -> TrackerSession? {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return TrackerSession(locked: d["CGSSessionScreenIsLocked"] as? Bool ?? false,
                              onConsole: d[kCGSessionOnConsoleKey as String] as? Bool ?? true)
    }

    enum Automation { case granted, denied, undetermined }

    static func automation(_ bundleId: String, ask: Bool) -> Automation {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let desc = target.aeDesc else { return .undetermined }
        // A concrete event (core/getd, what "get URL of active tab" sends): with typeWildCard the
        // system can't prompt and returns -1744 forever, so the browser was never asked.
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), ask)
        SupportLog.tracker.info("automation \(bundleId, privacy: .public) ask=\(ask) → \(status)")
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .undetermined // -1744 needs consent, -600 not running
        }
    }
}
