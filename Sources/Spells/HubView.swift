import SwiftUI
import IncantUI
import RewindCore
import RewindUI
import ScryUI
import SpellsKit
import SpellsUI

/// Sidebar: Modules, then a group per installed module (Rewind: Day / Week / Range; Scry: Meetings), and
/// one Settings entry pinned at the bottom (with Rewind's health pill) that switches between the installed
/// modules' settings. Detail: that module's own view, the same one its app shows.
struct HubView: View {
    @Bindable var hub: HubModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        }
        .frame(minWidth: 900, minHeight: 548)
        .tint(Theme.ink)
        .onChange(of: hub.section) { _, s in
            if case .rewind(let v) = s { hub.rewind?.view = v }
        }
    }

    private var sidebar: some View {
        List(selection: $hub.section) {
            Section("Spells") {
                Label("Modules", systemImage: "square.grid.2x2").tag(HubSection.modules)
            }
            if hub.rewind != nil {
                Section("Rewind") {
                    ForEach(ShellView.allCases) { v in
                        Label(v.title, systemImage: v.symbol).tag(HubSection.rewind(v))
                    }
                }
            } else if hub.rewindError != nil {
                Section("Rewind") {
                    Label("Couldn't open", systemImage: "exclamationmark.triangle").tag(HubSection.rewind(.day))
                }
            }
            if hub.meetings != nil {
                Section("Scry") {
                    Label("Meetings", systemImage: "person.2.wave.2").tag(HubSection.meetings)
                }
            }
        }
        .symbolRenderingMode(.monochrome)
        .navigationSplitViewColumnWidth(min: 190, ideal: 208, max: 260)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if !hub.settingsModules.isEmpty {
                    let on = hub.section == .settings
                    Button { hub.section = .settings } label: {
                        Label("Settings", systemImage: "gearshape")
                            .textRole(.body, on ? Theme.ink : Theme.inkSecondary)
                            .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs + 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surfaceRaised.opacity(on ? 1 : 0), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let rewind = hub.rewind { HealthPill(rewind.health, timeZone: rewind.timeZone) }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Settings: a picker across the installed modules, then that module's own settings view.
    private var settings: some View {
        VStack(spacing: 0) {
            if hub.settingsModules.count > 1 {
                Picker("Module", selection: $hub.settingsModule) {
                    ForEach(hub.settingsModules) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .padding(.top, Theme.Space.m)
            }
            Group {
                switch hub.settingsModule {
                case .rewind: if let m = hub.rewind { SettingsView(model: m) }
                case .scry: ScrySettingsView(onSaved: { hub.scrySettingsSaved() })
                case .incant: IncantSettingsView(permissions: nil)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle("\(hub.settingsModule.rawValue) Settings")
    }

    @ViewBuilder private var detail: some View {
        switch hub.section {
        case .modules:
            LauncherView(model: hub.launcher).navigationTitle("Modules")
        case .rewind:
            if let m = hub.rewind {
                ShellDetailView(model: m)
            } else {
                EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't open Rewind's database",
                           detail: hub.rewindError ?? "")
                    .padding(Theme.Space.gutter)
            }
        case .meetings:
            if let meetings = hub.meetings {
                MeetingsView(model: meetings, openSettings: { hub.showSettings(.scry) }).navigationTitle("Meetings")
            }
        case .settings:
            settings
        }
    }
}
