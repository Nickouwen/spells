import SwiftUI
import IncantUI
import RewindCore
import RewindUI
import ScryUI
import SpellsKit
import SpellsUI
import TransmuteUI

/// Sidebar: Modules, then a group per installed module (Rewind: Day / Week / Range; Scry: Meetings), and
/// one Settings entry pinned at the bottom (with Rewind's health pill) that switches between the installed
/// modules' settings. Detail: that module's own view, the same one its app shows.
struct HubView: View {
    @Bindable var hub: HubModel
    @State private var rewindTab: SettingsTab = .tracking

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
            if hub.transmute != nil {
                Section("Transmute") {
                    Label("Invoices", systemImage: "flask").tag(HubSection.invoices)
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

    /// Settings: a tile per installed module across the top, then that module's own pages filling the
    /// pane (Rewind's with its tab strip under the tiles).
    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                ForEach(hub.settingsModules) { m in moduleTile(m) }
                Spacer()
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, Theme.Space.l)
            Rectangle().fill(Theme.hairline).frame(height: Theme.Stroke.hairline)
            if hub.settingsModule == .rewind, hub.rewind != nil {
                Picker("Section", selection: $rewindTab) {
                    ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, Theme.Space.l)
            }
            Group {
                switch hub.settingsModule {
                case .rewind: if let m = hub.rewind { SettingsView.page(rewindTab, model: m).id(rewindTab) }
                case .scry: ScrySettingsView(onSaved: { hub.scrySettingsSaved() })
                case .incant: IncantSettingsView(permissions: nil)
                case .transmute: TransmuteSettingsView(onSaved: { hub.transmute?.reloadSettings() })
                }
            }
            .frame(maxWidth: 960, maxHeight: .infinity, alignment: .topLeading)   // readable line length; left-aligned with the tiles
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("\(hub.settingsModule.rawValue) Settings")
    }

    private func moduleTile(_ m: SettingsModule) -> some View {
        let on = hub.settingsModule == m
        let (symbol, tagline): (String, String) = switch m {
            case .rewind: ("clock.arrow.circlepath", "Time tracking")
            case .scry: ("eye", "Meeting notes")
            case .incant: ("waveform", "Dictation")
            case .transmute: ("flask", "Invoices")
        }
        return Button { hub.settingsModule = m } label: {
            HStack(spacing: Theme.Space.s + 2) {
                Image(systemName: symbol).font(.system(size: 18, weight: .regular)).foregroundStyle(Theme.ink)
                    .frame(width: 34, height: 34)
                    .background(on ? Theme.surface : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.rawValue).textRole(.heading, on ? Theme.ink : Theme.inkSecondary)
                    Text(tagline).textRole(.label, Theme.inkTertiary)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s + 2)
            .frame(minWidth: 180, alignment: .leading)
            .background(on ? Theme.surfaceRaised : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(on ? Theme.ink : Theme.hairline, lineWidth: on ? 1 : Theme.Stroke.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(m.rawValue) settings")
        .accessibilityAddTraits(on ? .isSelected : [])
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
        case .invoices:
            if let t = hub.transmute {
                InvoicesView(model: t, openSettings: { hub.showSettings(.transmute) }).navigationTitle("Invoices")
            }
        case .settings:
            settings
        }
    }
}
