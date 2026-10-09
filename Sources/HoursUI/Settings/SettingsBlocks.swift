import SwiftUI
import HoursCore

/// The Day/Week Blocks view (W22): default break threshold, per-weekday overrides, minimum block
/// length and the visible window. All display-only (`BlocksThreshold` keys): they regroup, never edit.
/// Values are held locally once loaded, like the Standup tab.
struct SettingsBlocksTab: View {
    let model: AppModel
    @State private var values: [String: String]?

    private static let weekdays: [(day: Int, label: String)] =
        [(2, "Monday"), (3, "Tuesday"), (4, "Wednesday"), (5, "Thursday"), (6, "Friday"), (7, "Saturday"), (1, "Sunday")]

    var body: some View {
        let s = values ?? model.settings
        let def = BlocksThreshold.defaultMinutes(s)
        let overrides = BlocksThreshold.overrides(s)
        SettingsPage {
            SettingsSection("Breaks", detail: "A gap without input at least this long ends a block. Shorter gaps and idle stay inside it. Changing these regroups the view; it never edits your time.") {
                HStack(spacing: Theme.Space.s) {
                    Text("Break after").textRole(.body)
                    Spacer()
                    ForEach(MetricsBlocks.presetsMin, id: \.self) { m in chip("\(m)m", on: def == m) { set(BlocksThreshold.defaultKey, String(m)) } }
                    Stepper(value: Binding(get: { def }, set: { set(BlocksThreshold.defaultKey, String($0)) }), in: BlocksThreshold.range) {
                        Text("\(def) min").textRole(.body).monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                    .fixedSize()
                }
                SettingsDivider()
                Text("Per weekday").textRole(.label, Theme.inkSecondary)
                    .padding(.bottom, Theme.Space.xs)
                ForEach(Self.weekdays, id: \.day) { w in
                    let value = overrides[w.day]
                    HStack {
                        Toggle(w.label, isOn: Binding(get: { value != nil }, set: { on in
                            var o = overrides
                            o[w.day] = on ? def : nil
                            set(BlocksThreshold.weekdayKey, BlocksThreshold.encode(o))
                        }))
                        .toggleStyle(.checkbox)
                        .textRole(.body)
                        Spacer()
                        if let value {
                            Stepper(value: Binding(get: { value }, set: { m in
                                var o = overrides
                                o[w.day] = m
                                set(BlocksThreshold.weekdayKey, BlocksThreshold.encode(o))
                            }), in: BlocksThreshold.range) {
                                Text("\(value) min").textRole(.body).monospacedDigit()
                            }
                            .fixedSize()
                        } else {
                            Text("Default (\(def) min)").textRole(.label, Theme.inkTertiary)
                        }
                    }
                    .frame(height: 24)
                }
            }
            SettingsSection("Display", detail: "The column shows a fixed number of hours at its default zoom, so a block's height means the same duration on every day. It scrolls across the whole day.") {
                HStack(spacing: Theme.Space.s) {
                    Text("Minimum block length").textRole(.body)
                    Spacer()
                    let min = BlocksThreshold.minBlockMinutes(s)
                    ForEach(BlocksThreshold.minBlockPresets, id: \.self) { m in
                        chip(m == 0 ? "Show all" : "\(m)m", on: min == m) { set(BlocksThreshold.minBlockKey, m == 0 ? nil : String(m)) }
                    }
                }
                Text("Shorter blocks draw as thin ticks and aren't counted.").textRole(.label, Theme.inkTertiary)
                SettingsDivider()
                HStack {
                    Text("Visible hours").textRole(.body)
                    Spacer()
                    let h = BlocksThreshold.windowHours(s)
                    Stepper(value: Binding(get: { h }, set: { set(BlocksThreshold.windowHoursKey, String($0)) }),
                            in: BlocksThreshold.windowHoursRange) {
                        Text("\(h) h").textRole(.body).monospacedDigit()
                    }
                    .fixedSize()
                }
                SettingsDivider()
                HStack {
                    Text("Starting at").textRole(.body)
                    Spacer()
                    DatePicker("Starting at", selection: Binding(get: { Self.date(minutes: BlocksThreshold.windowStartMinutes(s)) }, set: { d in
                        set(BlocksThreshold.windowStartKey, StandupSettings.formatTime(Self.minutes(d)))
                    }), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
                }
                Text("Days with earlier or later activity scroll to show it.").textRole(.label, Theme.inkTertiary)
            }
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).textRole(.label, on ? Theme.ink : Theme.inkTertiary)
                .padding(.horizontal, Theme.Space.s)
                .frame(minWidth: 40, minHeight: 22)
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

    /// Optimistic local update + an off-main write (nil removes the key → default). The change feed
    /// regroups the Day and Week views.
    private func set(_ key: String, _ value: String?) {
        var v = values ?? model.settings
        v[key] = value
        values = v
        let db = model.db
        Task.detached(priority: .userInitiated) {
            do { try SettingStore(db).set(key, value) } catch {
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
