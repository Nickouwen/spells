import SwiftUI
import HoursCore

/// EOD standup (W20): auto-run toggle, time, weekdays, name and the claude CLI path.
/// Values are held locally once loaded: `model.settings` only refetches while the main window is visible.
struct SettingsStandupTab: View {
    let model: AppModel
    @State private var values: StandupSettings?
    @State private var name = ""
    @State private var claudePath = ""

    private static let weekdays: [(day: Int, label: String)] =
        [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")]

    var body: some View {
        let v = values ?? StandupSettings.load(model.settings)
        SettingsPage {
            SettingsSection("EOD standup", detail: "Written by claude -p from the day's Claude Code sessions and tracked time. Open it from the EOD button in the Day view. On scheduled days, the tracker generates it once at the time below if none exists yet.") {
                Toggle("Generate automatically", isOn: Binding(get: { v.enabled }, set: { on in
                    update(StandupSettings.enabledKey, on ? "1" : "0") { $0.enabled = on }
                }))
                .toggleStyle(.switch)
                .textRole(.body)
                SettingsDivider()
                HStack {
                    Text("At").textRole(.body)
                    Spacer()
                    DatePicker("At", selection: Binding(get: { Self.date(minutes: v.timeMinutes) }, set: { d in
                        let m = Self.minutes(d)
                        update(StandupSettings.timeKey, StandupSettings.formatTime(m)) { $0.timeMinutes = m }
                    }), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsDivider()
                HStack(spacing: Theme.Space.s) {
                    Text("On").textRole(.body)
                    Spacer()
                    ForEach(Self.weekdays, id: \.day) { w in
                        let on = v.weekdays.contains(w.day)
                        Button {
                            var days = v.weekdays
                            if on { days.remove(w.day) } else { days.insert(w.day) }
                            update(StandupSettings.weekdaysKey, days.sorted().map(String.init).joined(separator: ",")) { $0.weekdays = days }
                        } label: {
                            Text(w.label).textRole(.label, on ? Theme.ink : Theme.inkTertiary)
                                .frame(width: 40, height: 22)
                                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                                .overlay {
                                    if on {
                                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                            .strokeBorder(Theme.ink, lineWidth: Theme.Stroke.selection)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            SettingsSection("Details", detail: "The name heads the standup. The claude path must be absolute: the tracker runs without your shell's PATH.") {
                field("Name", text: $name, prompt: StandupSettings.defaultName) {
                    update(StandupSettings.nameKey, name) { $0.name = name.isEmpty ? StandupSettings.defaultName : name }
                }
                SettingsDivider()
                field("claude CLI", text: $claudePath, prompt: StandupSettings.defaultClaudePath) {
                    update(StandupSettings.claudePathKey, claudePath) { $0.claudePath = claudePath.isEmpty ? StandupSettings.defaultClaudePath : claudePath }
                }
            }
        }
        .onAppear {
            let s = model.settings
            name = s[StandupSettings.nameKey] ?? ""
            claudePath = s[StandupSettings.claudePathKey] ?? ""
        }
        .onDisappear {
            let s = model.settings
            if name != (s[StandupSettings.nameKey] ?? "") { update(StandupSettings.nameKey, name) { _ in } }
            if claudePath != (s[StandupSettings.claudePathKey] ?? "") { update(StandupSettings.claudePathKey, claudePath) { _ in } }
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, submit: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(title).textRole(.body)
            Spacer()
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(submit)
        }
    }

    /// Optimistic local update + an off-main write (blank text removes the key → default).
    private func update(_ key: String, _ value: String, _ apply: (inout StandupSettings) -> Void) {
        var v = values ?? StandupSettings.load(model.settings)
        apply(&v)
        values = v
        let db = model.db
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Task.detached(priority: .userInitiated) {
            do { try SettingStore(db).set(key, trimmed.isEmpty ? nil : trimmed) } catch {
                SupportLog.app.error("\(key, privacy: .public) not saved: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func date(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date(timeIntervalSince1970: 1_791_000_000))!
    }

    private static func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return c.hour! * 60 + c.minute!
    }
}
