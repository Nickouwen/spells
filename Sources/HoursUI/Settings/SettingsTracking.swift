import SwiftUI
import HoursCore

/// Idle threshold + tracker / permission status with buttons into System Settings.
struct SettingsTrackingTab: View {
    let model: AppModel
    @Environment(\.openURL) private var openURL
    /// The pick shown until `model.settings` catches up (it only refetches while the main window is visible).
    @State private var islandChoice: String?

    var body: some View {
        let idle = model.idleThresholdS
        SettingsPage {
            SettingsSection("Idle", detail: "After this long without keyboard or mouse input, time counts as idle. The tracker applies changes immediately.") {
                HStack {
                    Text("Idle after").textRole(.body)
                    Spacer()
                    Text(Fmt.duration(ms: Int64(idle) * 1000)).textRole(.bodyEmph)
                        .accessibilityHidden(true)
                    Stepper("Idle after", value: Binding(get: { idle }, set: { s in Task { await model.setIdleThreshold(seconds: s) } }),
                            in: 60...1800, step: 60)
                        .labelsHidden()
                        .accessibilityValue(Fmt.durationSpoken(ms: Int64(idle) * 1000))
                }
            }
            SettingsSection("Pause", detail: "Nothing is recorded while paused. Also in the menu bar and Tracker menu.") {
                HStack(spacing: Theme.Space.m) {
                    Text(pauseText).textRole(.body)
                    Spacer()
                    if model.pausedUntilMs != nil {
                        Button("Resume") { Task { await model.setPause(untilMs: nil) } }.buttonStyle(HoursButtonStyle())
                    }
                    Menu("Pause") {
                        Button("15 minutes") { Task { await model.pause(minutes: 15) } }
                        Button("1 hour") { Task { await model.pause(minutes: 60) } }
                        Button("Until tomorrow") { Task { await model.pauseUntilTomorrow() } }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .accessibilityLabel("Pause tracking")
                }
            }
            SettingsSection("Notch island", detail: "Today's work time beside the camera notch; hover it for details. Without a notch it floats under the menu bar.") {
                HStack {
                    Text("Notch island").textRole(.body)
                    Spacer()
                    Picker("Notch island", selection: Binding(get: { islandStyle }, set: { setIslandStyle($0) })) {
                        Text("Off").tag("off")
                        Text("Both ears").tag("both")
                        Text("Right ear only").tag("right")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            SettingsSection("Tracker") {
                statusRow("Status", HealthPill(model.health, timeZone: model.timeZone))
                SettingsDivider()
                statusRow("Login item", Text(Self.helperText(model.helperStatus)).textRole(.body, Theme.inkSecondary))
                SettingsDivider()
                HStack {
                    Text("Start at login").textRole(.body)
                    Spacer()
                    Button("Open Login Items") { model.openLoginItems?() }
                        .buttonStyle(HoursButtonStyle())
                        .settingsDimsWhenDisabled()
                        .disabled(model.openLoginItems == nil)
                }
            }
            SettingsSection("Permissions", detail: "Granted to HoursSpell, the background helper — not to this window.") {
                permissionRow("Accessibility", detail: Self.accessibilityText(model.health), pane: ShellSystemPane.accessibility)
                SettingsDivider()
                permissionRow("Automation", detail: "Lets the tracker read the current tab's URL from browsers.",
                              pane: ShellSystemPane.automation)
            }
        }
    }

    private var pauseText: String {
        if case .paused(let until) = model.health { return "Paused until \(Fmt.clock(ms: until, timeZone: model.timeZone))" }
        if let until = model.pausedUntilMs { return "Pausing until \(Fmt.clock(ms: until, timeZone: model.timeZone))…" }
        return "Tracking is on"
    }

    /// Same key and default as the helper's `TrackerIslandStyle` (TrackerCore isn't linked here).
    nonisolated static let islandStyleKey = "island_style"

    private var islandStyle: String {
        let s = islandChoice ?? model.settings[Self.islandStyleKey] ?? "both"
        return ["off", "right"].contains(s) ? s : "both"
    }

    /// The helper applies it live from the change feed.
    private func setIslandStyle(_ style: String) {
        islandChoice = style
        let db = model.db
        Task.detached(priority: .userInitiated) {
            do { try SettingStore(db).set(Self.islandStyleKey, style) } catch {
                SupportLog.app.error("island_style not saved: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func statusRow(_ title: String, _ value: some View) -> some View {
        HStack { Text(title).textRole(.body); Spacer(); value }
    }

    private func permissionRow(_ title: String, detail: String, pane: URL) -> some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title).textRole(.body)
                Text(detail).textRole(.label, Theme.inkSecondary)
            }
            Spacer()
            Button("Open Settings") { openURL(pane) }.buttonStyle(HoursButtonStyle())
        }
    }

    static func helperText(_ s: TrackerHelperStatus?) -> String {
        switch s {
        case .running: "Registered and running"
        case .needsApproval: "Waiting for approval in Login Items"
        case .helperMissing: "Helper missing from the app bundle"
        case .notBundled: "Not managed (running outside the app bundle)"
        case .failed(let m): "Failed: \(m)"
        case nil: "Checking…"
        }
    }

    static func accessibilityText(_ h: TrackerHealth) -> String {
        switch h {
        case .permissionMissing: "Not granted — window titles aren't recorded."
        case .tracking, .idle, .paused: "Granted — window titles are recorded."
        case .stopped, .unknown: "Status shows once the tracker is running."
        }
    }
}
