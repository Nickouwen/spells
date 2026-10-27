import SwiftUI
import SpellsKit
import SpellsUI

/// Spells, the launcher: a window listing every module — installed ones (from ~/Applications/Spells)
/// with Open, Settings, Quit, Start-at-login and Remove; catalog ones with Install; both with Update
/// when the catalog is newer. It ships with nothing installed.
@main
struct SpellsApp: App {
    @State private var model = LauncherModel()

    var body: some Scene {
        Window("Spells", id: "main") {
            LauncherView(model: model)
                .onAppear { model.start() }
        }
        .defaultSize(width: 720, height: 560)
        .windowResizability(.contentMinSize)
    }
}

struct LauncherView: View {
    let model: LauncherModel

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
        .frame(minWidth: 620, minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .tint(Theme.ink)
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
                        Text(m.running ? "Running" : "Not running").textRole(.label, m.running ? Theme.inkSecondary : Theme.inkTertiary)
                    } else {
                        Text("Not installed").textRole(.label, Theme.inkTertiary)
                    }
                }
                Text(r.summary).textRole(.body, Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                if let e = model.errors[r.id] {
                    Text(e).textRole(.label, Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Theme.Space.s) {
                    if let m = r.installed, m.loginItem {
                        Toggle("Start at login", isOn: Binding(get: { m.atLogin }, set: { model.setLogin(m, $0) }))
                            .toggleStyle(.switch).textRole(.label)
                    }
                    Spacer()
                    if let m = r.installed {
                        Button("Remove") { model.remove(m) }.buttonStyle(RewindButtonStyle())
                        if let u = r.update { Button("Update") { model.install(u) }.buttonStyle(RewindButtonStyle()) }
                        if m.running {
                            Button("Quit") { model.quit(m) }.buttonStyle(RewindButtonStyle())
                        } else {
                            Button("Start") { model.open(m) }.buttonStyle(RewindButtonStyle())
                        }
                        Button(m.loginItem ? "Settings…" : "Open") { m.loginItem ? model.settings(m) : model.open(m) }
                            .buttonStyle(RewindButtonStyle())
                    } else if let a = r.available {
                        Button("Install") { model.install(a) }.buttonStyle(RewindButtonStyle())
                    }
                }
                .disabled(busy != nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
