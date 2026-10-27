import SwiftUI
import RewindCore

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case categories, rules, classification, projects, goals, tracking, blocks, standup, data
    public var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .categories: "square.grid.2x2"
        case .rules: "list.bullet.rectangle"
        case .classification: "sparkles"
        case .projects: "folder"
        case .goals: "target"
        case .tracking: "record.circle"
        case .blocks: "rectangle.split.1x2"
        case .standup: "text.bubble"
        case .data: "externaldrive"
        }
    }
}

/// The Settings window (⌘,). Each tab edits config through `AppModel`, which writes via
/// ConfigStore / SettingStore and refetches, so every view of the data updates.
public struct SettingsView: View {
    let model: AppModel
    @State private var tab: SettingsTab = .tracking

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases) { t in
                Self.page(t, model: model)
                    .tabItem { Label(t.title, systemImage: t.symbol) }
                    .tag(t)
            }
        }
        .frame(width: 680, height: 520)
        .tint(Theme.ink)
    }

    @ViewBuilder static func page(_ tab: SettingsTab, model: AppModel) -> some View {
        switch tab {
        case .categories: SettingsCategoriesTab(model: model)
        case .rules: SettingsRulesTab(model: model)
        case .classification: SettingsClassificationTab(model: model)
        case .projects: SettingsProjectsTab(model: model)
        case .goals: SettingsGoalsTab(model: model)
        case .tracking: SettingsTrackingTab(model: model)
        case .blocks: SettingsBlocksTab(model: model)
        case .standup: SettingsStandupTab(model: model)
        case .data: SettingsDataTab(model: model)
        }
    }
}

/// Colour slot picker: palette swatches + "None" (grey).
struct SettingsSlotPicker: View {
    let slot: Int?
    let onPick: (Int?) -> Void

    var body: some View {
        Menu {
            Button("None (grey)") { onPick(nil) }
            ForEach(Theme.Palette.slots.indices, id: \.self) { i in
                Button(Theme.Palette.slots[i].name) { onPick(i) }
            }
        } label: {
            Text(Theme.Palette.name(slot: slot)).textRole(.label)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // Outside the Menu: borderless menus drop non-text label content.
        .padding(.leading, 12 + Theme.Space.s)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.Palette.swatch(slot: slot)).frame(width: 12, height: 12)
        }
    }
}
