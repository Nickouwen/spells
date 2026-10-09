import SwiftUI
import HoursCore

/// Maps what the app can see — the helper's `tracker_state` row (pid, Accessibility, pause) and
/// its writes (live span heartbeat, recent spans) — onto `TrackerHealth`.
enum ShellHealth {
    /// Heartbeat is every 30 s; older than this = the tracker isn't writing.
    static let staleMs: Int64 = 120_000

    /// `live`: the open span (endMs = last heartbeat). `recent`: closed spans, ascending.
    /// `state`: the helper's status row; `isAlive` checks its pid (injected for tests).
    static func health(live: RawSpan?, recent: [RawSpan], state: TrackerState?, nowMs: Int64,
                       isAlive: (TrackerState) -> Bool = { $0.isAlive }) -> TrackerHealth {
        let running = state.map(isAlive) ?? false
        if running, let state {
            if !state.axTrusted { return .permissionMissing }
            if let until = state.pausedUntilMs, until > nowMs { return .paused(untilMs: until) }
        }
        let last = max(live?.endMs ?? .min, recent.last?.endMs ?? .min)
        guard let live, nowMs - live.endMs <= staleMs else {
            // A running helper with no open span is idle (locked, asleep, away, excluded app), not stopped.
            if running { return .idle(sinceMs: last == .min ? nil : last) }
            return last == .min ? .unknown : .stopped(atMs: last)
        }
        return .tracking(sinceMs: runStart(live: live, recent: recent))
    }

    /// Start of the unbroken run of spans ending at the live span.
    static func runStart(live: RawSpan, recent: [RawSpan]) -> Int64 {
        var start = live.startMs
        for s in recent.reversed() {
            guard s.endMs >= start - staleMs else { break }
            start = min(start, s.startMs)
        }
        return start
    }
}

/// One actionable line above the content when the tracker needs attention.
struct ShellBanner: View {
    struct Content: Equatable {
        var text: String
        var action: String?
    }

    let content: Content
    let perform: () -> Void

    /// nil = nothing to say.
    nonisolated static func content(helper: TrackerHelperStatus?, health: TrackerHealth, timeZone: TimeZone) -> Content? {
        switch helper {
        case .helperMissing:
            return Content(text: "The tracker helper is missing from the app bundle. Reinstall Hours.", action: nil)
        case .failed(let message):
            return Content(text: "Couldn't start the tracker: \(message)", action: "Try Again")
        default: break
        }
        if health == .permissionMissing {
            return Content(text: "Window titles aren't being recorded. Grant HoursSpell Accessibility access.",
                           action: "Open Accessibility")
        }
        if case .stopped(let ms) = health {
            let at = Fmt.clock(ms: ms, timeZone: timeZone)
            return helper == .notBundled
                ? Content(text: "Tracker stopped at \(at). Running outside the app bundle, so it isn't managed.", action: nil)
                : Content(text: "Tracker stopped at \(at). No time is being recorded.", action: "Start Tracker")
        }
        if helper == .needsApproval {
            return Content(text: "HoursSpell won't start at login until you approve it.", action: "Open Login Items")
        }
        return nil
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Circle().fill(Theme.StateLayer.warn).frame(width: 7, height: 7)
            Text(content.text).textRole(.body).lineLimit(2)
            Spacer(minLength: Theme.Space.s)
            if let action = content.action {
                Button(action, action: perform).buttonStyle(HoursButtonStyle())
            }
        }
        .hoursCard(padding: Theme.Space.m)
        .accessibilityElement(children: .contain)
    }
}
