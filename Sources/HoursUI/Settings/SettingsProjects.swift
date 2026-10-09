import SwiftUI
import HoursCore

/// Add / archive projects, free-text client (PLAN Q12: no rates, no budgets).
struct SettingsProjectsTab: View {
    let model: AppModel
    @State private var name = ""
    @State private var client = ""
    @State private var autoRule = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsPage {
            SettingsSection("Add project") {
                HStack(spacing: Theme.Space.m) {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    TextField("Client (optional)", text: $client).textFieldStyle(.roundedBorder)
                    Button("Add", action: add)
                        .buttonStyle(HoursButtonStyle())
                        .settingsDimsWhenDisabled()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Toggle("Assign windows whose title contains the name", isOn: $autoRule)
                    .toggleStyle(.checkbox)
                    .textRole(.label, Theme.inkSecondary)
                    .padding(.top, Theme.Space.s)
            }
            SettingsSection("Projects") {
                ForEach(Array(model.projects.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { SettingsDivider() }
                    SettingsProjectRow(project: p) { updated in Task { await model.save(updated) } }
                }
            }
            .animation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion), value: model.projects.map(\.id))
        }
    }

    private func add() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let c = client.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        name = ""; client = ""
        Task { await model.addProject(name: n, client: c.isEmpty ? nil : c, autoRule: autoRule) }
    }
}

struct SettingsProjectRow: View {
    let project: Project
    let onSave: (Project) -> Void
    @State private var client: String

    init(project: Project, onSave: @escaping (Project) -> Void) {
        self.project = project
        self.onSave = onSave
        _client = State(initialValue: project.client ?? "")
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(project.name).textRole(.body, project.archived ? Theme.inkTertiary : Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("Client", text: $client, prompt: Text("Add client"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit {
                    var p = project
                    let c = client.trimmingCharacters(in: .whitespaces)
                    p.client = c.isEmpty ? nil : c
                    if p != project { onSave(p) }
                }
            Button(project.archived ? "Unarchive" : "Archive") {
                var p = project; p.archived.toggle(); onSave(p)
            }
            .buttonStyle(.borderless)
            .textRole(.label, Theme.inkSecondary)
        }
    }
}
