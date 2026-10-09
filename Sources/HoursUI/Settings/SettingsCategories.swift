import SwiftUI
import HoursCore

/// Rename, productivity level, counts-as-work, colour slot. Keys are immutable; nothing deletes.
struct SettingsCategoriesTab: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let visible = model.categories.filter { !$0.archived && $0.behavior != .exclude && $0.key != "uncategorized" }
        SettingsPage {
            SettingsSection("Categories", detail: "Level drives focus time; “Work” decides what counts toward work hours.") {
                // Uncategorized (= no category) and Excluded (behavior .exclude) have no level/work meaning.
                ForEach(Array(visible.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { SettingsDivider() }
                    SettingsCategoryRow(category: c) { updated in Task { await model.save(updated) } }
                }
            }
            .animation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion), value: visible.map(\.id))
        }
    }
}

struct SettingsCategoryRow: View {
    let category: HoursCore.Category
    let onSave: (HoursCore.Category) -> Void
    @State private var name: String

    init(category: HoursCore.Category, onSave: @escaping (HoursCore.Category) -> Void) {
        self.category = category
        self.onSave = onSave
        _name = State(initialValue: category.name)
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            SettingsSlotPicker(slot: category.colorSlot) { slot in var c = category; c.colorSlot = slot; onSave(c) }
                .frame(width: 104, alignment: .leading)
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .textRole(.body)
                .onSubmit(commitName)
                .frame(maxWidth: .infinity)
            Picker("Level", selection: Binding(get: { category.level },
                                               set: { var c = category; c.level = $0; onSave(c) })) {
                Text("Productive").tag(Productivity.productive)
                Text("Neutral").tag(Productivity.neutral)
                Text("Distracting").tag(Productivity.distracting)
            }
            .labelsHidden()
            .fixedSize()
            Toggle("Work", isOn: Binding(get: { category.isWork }, set: { var c = category; c.isWork = $0; onSave(c) }))
                .toggleStyle(.checkbox)
                .textRole(.label)
        }
        .onChange(of: category.name) { _, new in name = new }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != category.name else { name = category.name; return }
        var c = category
        c.name = trimmed
        onSave(c)
    }
}
