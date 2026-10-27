import SwiftUI
import IncantUI
import RewindCore
import RewindUI
import ScryUI
import SpellsKit
import SpellsUI

/// Sidebar: Modules, then a group per installed module (Rewind: Day / Week / Range / Settings; Scry:
/// Meetings / Settings; Incant: Settings). Detail: that module's own view, the same one its app shows.
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
            if let rewind = hub.rewind {
                Section("Rewind") {
                    ForEach(ShellView.allCases) { v in
                        Label(v.title, systemImage: v.symbol).tag(HubSection.rewind(v))
                    }
                    Label("Settings", systemImage: "gearshape").tag(HubSection.rewindSettings)
                    HealthPill(rewind.health, timeZone: rewind.timeZone).selectionDisabled()
                }
            } else if hub.rewindError != nil {
                Section("Rewind") {
                    Label("Couldn't open", systemImage: "exclamationmark.triangle").tag(HubSection.rewind(.day))
                }
            }
            if hub.meetings != nil {
                Section("Scry") {
                    Label("Meetings", systemImage: "person.2.wave.2").tag(HubSection.meetings)
                    Label("Settings", systemImage: "gearshape").tag(HubSection.scrySettings)
                }
            }
            if hub.incantInstalled {
                Section("Incant") {
                    Label("Settings", systemImage: "gearshape").tag(HubSection.incantSettings)
                }
            }
        }
        .symbolRenderingMode(.monochrome)
        .navigationSplitViewColumnWidth(min: 190, ideal: 208, max: 260)
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
        case .rewindSettings:
            if let m = hub.rewind { SettingsView(model: m).navigationTitle("Rewind Settings") }
        case .meetings:
            if let meetings = hub.meetings {
                MeetingsView(model: meetings, openSettings: { hub.section = .scrySettings }).navigationTitle("Meetings")
            }
        case .scrySettings:
            ScrySettingsView(onSaved: { hub.scrySettingsSaved() }).navigationTitle("Scry Settings")
        case .incantSettings:
            IncantSettingsView(permissions: nil).navigationTitle("Incant Settings")
        }
    }
}
