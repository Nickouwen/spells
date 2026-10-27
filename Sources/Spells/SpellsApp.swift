import SwiftUI
import SpellsKit
import SpellsUI

/// Spells, the launcher: a window listing the module apps found in ~/Applications/Spells, with Open,
/// Settings, Quit and Start-at-login for each. It installs nothing itself (a catalog is the next step).
@main
struct SpellsApp: App {
    @State private var model = LauncherModel()

    var body: some Scene {
        Window("Spells", id: "main") {
            LauncherView(model: model)
                .onAppear { model.start() }
        }
        .defaultSize(width: 720, height: 520)
        .windowResizability(.contentMinSize)
    }
}

struct LauncherView: View {
    let model: LauncherModel

    var body: some View {
        Group {
            if model.modules.isEmpty {
                EmptyState(symbol: "wand.and.stars", title: "No modules installed",
                           detail: "Put a module app (Rewind, Incant, Scry…) in \((Spells.modulesDirectory.path as NSString).abbreviatingWithTildeInPath) and it appears here.",
                           action: .init("Show Folder") { model.revealFolder() })
                    .padding(Theme.Space.gutter)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(model.modules) { m in row(m) }
                    }
                    .padding(Theme.Space.gutter)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .tint(Theme.ink)
    }

    private func row(_ m: InstalledModule) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: m.symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(Theme.ink)
                .frame(width: 36, height: 36)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(m.name).textRole(.heading)
                    Text(m.version).textRole(.label, Theme.inkTertiary)
                    Spacer()
                    Text(m.running ? "Running" : "Not running").textRole(.label, m.running ? Theme.inkSecondary : Theme.inkTertiary)
                }
                Text(m.summary).textRole(.body, Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.s) {
                    if m.loginItem {
                        Toggle("Start at login", isOn: Binding(get: { m.atLogin }, set: { model.setLogin(m, $0) }))
                            .toggleStyle(.switch).textRole(.label)
                    }
                    Spacer()
                    if m.running {
                        Button("Quit") { model.quit(m) }.buttonStyle(RewindButtonStyle())
                    } else {
                        Button("Start") { model.open(m) }.buttonStyle(RewindButtonStyle())
                    }
                    Button(m.loginItem ? "Settings…" : "Open") { m.loginItem ? model.settings(m) : model.open(m) }
                        .buttonStyle(RewindButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoursCard()
    }
}
