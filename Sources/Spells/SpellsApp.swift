import SwiftUI
import RewindUI
import SpellsKit
import SpellsUI

/// Spells, the hub: the module list and catalog (install, update, remove, start, stop, login) plus every
/// installed module's own views — Rewind's Day / Week / Range and settings, Scry's Meetings and settings,
/// Incant's settings — read straight from their data, whether or not the module runs. It ships with
/// nothing installed and, like every module, updates itself (`ModuleUpdater`).
@main
struct SpellsApp: App {
    @State private var hub = HubModel()

    var body: some Scene {
        Window("Spells", id: "main") {
            HubView(hub: hub)
                .onAppear { hub.start(); ModuleUpdater.start(settings: .launcher()) }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands { ShellCommands() }
    }
}

/// The Modules section: installed and catalog modules with their actions.
struct LauncherView: View {
    let model: LauncherModel
    /// The module a Remove… click asked about, until the dialog answers.
    @State private var removing: InstalledModule?

    var body: some View {
        VStack(spacing: 0) {
            if model.rows.isEmpty {
                EmptyState(symbol: "wand.and.stars", title: "No modules yet",
                           detail: model.catalogError ?? (model.loadingCatalog ? "Loading the catalog…" : "The catalog is empty."),
                           action: .init("Check Again") { Task { await model.loadCatalog() } })
                    .padding(Theme.Space.gutter)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(model.rows) { row($0) }
                    }
                    .padding(Theme.Space.gutter)
                }
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .tint(Theme.ink)
        .confirmationDialog("Remove \(removing?.name ?? "this module")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { m in
            Button("Remove", role: .destructive) { model.remove(m); removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { m in
            Text("\(m.name) is moved to the Trash. Its data and settings stay, so reinstalling picks up where it left off.")
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            if model.loadingCatalog {
                ProgressView().controlSize(.small)
                Text("Checking the catalog…").textRole(.label, Theme.inkTertiary)
            } else if let e = model.catalogError {
                Text(e).textRole(.label, Theme.inkTertiary).lineLimit(1).truncationMode(.middle)
            } else if let c = model.catalog {
                Text("\(c.modules.count) in the catalog").textRole(.label, Theme.inkTertiary)
            }
            Spacer()
            Button("Show Folder") { model.revealFolder() }.buttonStyle(RewindButtonStyle())
            Button("Check for Updates") { Task { await model.loadCatalog() } }.buttonStyle(RewindButtonStyle()).disabled(model.loadingCatalog)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.s)
    }

    private func row(_ r: LauncherRow) -> some View {
        let busy = model.busy[r.id]
        return HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: r.symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(Theme.ink)
                .frame(width: 36, height: 36)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(r.name).textRole(.heading)
                    if let m = r.installed {
                        Text(m.version).textRole(.label, Theme.inkTertiary)
                        if let u = r.update { Text("\(u.version) available").textRole(.label, Theme.ink) }
                    } else if let a = r.available {
                        Text(a.version).textRole(.label, Theme.inkTertiary)
                    }
                    Spacer()
                    if let busy {
                        ProgressView().controlSize(.small)
                        Text(busy).textRole(.label, Theme.inkSecondary)
                    } else if let m = r.installed {
                        if m.running {
                            HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
                                LiveDot()
                                Text("Running").textRole(.label, Theme.inkSecondary)
                            }
                        } else {
                            Text("Not running").textRole(.label, Theme.inkTertiary)
                        }
                    } else {
                        Text("Not installed").textRole(.label, Theme.inkTertiary)
                    }
                }
                Text(r.summary).textRole(.body, Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                if let e = model.errors[r.id] {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs + Theme.Space.xxs) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.StateLayer.warn)
                        Text(e).fixedSize(horizontal: false, vertical: true)
                    }
                    .textRole(.label, Theme.inkSecondary)
                }
                HStack(spacing: Theme.Space.s) {
                    if let m = r.installed, m.loginItem {
                        Toggle("Start at login", isOn: Binding(get: { m.atLogin }, set: { model.setLogin(m, $0) }))
                            .toggleStyle(.switch).textRole(.label)
                    }
                    Spacer()
                    // Filled only for what you can act on (Update, Install); Open/Settings… outlined, Quit and
                    // Remove quiet. A stopped app's Start and Open both launch it, so it shows just Open.
                    if let m = r.installed {
                        if m.running {
                            Button("Quit") { model.quit(m) }.buttonStyle(QuietButtonStyle())
                        } else if m.loginItem {
                            Button("Start") { model.open(m) }.buttonStyle(RewindButtonStyle())
                        }
                        Button(m.loginItem ? "Settings…" : "Open") { m.loginItem ? model.settings(m) : model.open(m) }
                            .buttonStyle(RewindButtonStyle())
                        if let u = r.update {
                            Button("Update") { model.install(u) }.buttonStyle(PrimaryButtonStyle())
                        }
                        Button("Remove…") { removing = m }.buttonStyle(QuietButtonStyle())   // uninstalls: confirm first
                    } else if let a = r.available {
                        Button("Install") { model.install(a) }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                .disabled(busy != nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// The 7 pt "running" dot, `live`. Static: nothing on the page ticks.
private struct LiveDot: View {
    var body: some View {
        Circle().fill(Theme.StateLayer.live).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}
