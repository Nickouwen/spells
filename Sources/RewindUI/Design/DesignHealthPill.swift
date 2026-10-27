import SwiftUI

/// Tracker status as the UI sees it. The shell maps the tracker's heartbeat/status row into this.
public enum TrackerHealth: Hashable, Sendable {
    case tracking(sinceMs: Int64)
    /// Helper running, nothing being recorded (locked, asleep, away, an excluded app in front).
    /// `sinceMs` = end of the last recorded span, if any.
    case idle(sinceMs: Int64?)
    /// Paused by the user (status item or Settings) until `untilMs`.
    case paused(untilMs: Int64)
    case stopped(atMs: Int64)
    case permissionMissing
    case unknown
}

/// Sidebar-footer status: health dot + one line. The only place the shell spends colour
/// constantly — for a proof tool, a visible tracking gap matters.
public struct HealthPill: View {
    let health: TrackerHealth
    let timeZone: TimeZone

    public init(_ health: TrackerHealth, timeZone: TimeZone = .current) {
        self.health = health
        self.timeZone = timeZone
    }

    var dot: Swatch {
        switch health {
        case .tracking: Theme.StateLayer.live
        case .stopped, .permissionMissing: Theme.StateLayer.warn
        case .idle, .paused: Theme.inkTertiary
        case .unknown: Theme.inkDisabled
        }
    }

    var text: String {
        switch health {
        case .tracking(let ms): "Tracking since \(Fmt.clock(ms: ms, timeZone: timeZone))"
        case .idle(let ms?): "Idle since \(Fmt.clock(ms: ms, timeZone: timeZone))"
        case .idle(nil): "Tracker idle"
        case .paused(let ms): "Paused until \(Fmt.clock(ms: ms, timeZone: timeZone))"
        case .stopped(let ms): "Tracker stopped \(Fmt.clock(ms: ms, timeZone: timeZone))"
        case .permissionMissing: "Accessibility access needed"
        case .unknown: "Tracker status unknown"
        }
    }

    public var body: some View {
        HStack(spacing: Theme.Space.s) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text).textRole(.label).lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.s + Theme.Space.xxs)
        .frame(height: 24)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tracker status")
        .accessibilityValue(text)
    }
}
