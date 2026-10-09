import SwiftUI
import HoursCore

/// Daily work target + the weekdays it applies to (PLAN Q13).
struct SettingsGoalsTab: View {
    let model: AppModel

    private static let weekdays: [(day: Int, label: String)] =
        [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")]

    var body: some View {
        let goal = model.goal
        SettingsPage {
            SettingsSection("Daily work goal", detail: "Counts work time (work categories), not everything tracked.") {
                Toggle("Track a daily goal", isOn: Binding(
                    get: { goal != nil },
                    set: { on in Task { await model.setGoal(on ? Goal(dailyWorkMs: 6 * 3_600_000) : nil) } }))
                    .toggleStyle(.switch)
                    .textRole(.body)
                if let goal {
                    SettingsDivider()
                    HStack {
                        Text("Target").textRole(.body)
                        Spacer()
                        Text(Fmt.duration(ms: goal.dailyWorkMs)).textRole(.bodyEmph)
                        Stepper("", value: Binding(
                            get: { Double(goal.dailyWorkMs) / 3_600_000 },
                            set: { h in var g = goal; g.dailyWorkMs = Int64(h * 3_600_000); Task { await model.setGoal(g) } }),
                                in: 0.5...16, step: 0.5)
                            .labelsHidden()
                    }
                    SettingsDivider()
                    HStack(spacing: Theme.Space.s) {
                        Text("Applies on").textRole(.body)
                        Spacer()
                        ForEach(Self.weekdays, id: \.day) { w in
                            let on = goal.weekdays.contains(w.day)
                            Button {
                                var g = goal
                                if on { g.weekdays.remove(w.day) } else { g.weekdays.insert(w.day) }
                                Task { await model.setGoal(g) }
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
            }
        }
    }
}
