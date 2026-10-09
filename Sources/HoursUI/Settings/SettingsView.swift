import SwiftUI
import HoursCore

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case spells, categories, rules, classification, projects, goals, tracking, blocks, standup, data
    public var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .spells: "wand.and.stars"
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
    @State private var tab: SettingsTab = .spells

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
        case .spells: SettingsSpellsTab(model: model)
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

/// Section title + flat card, the Settings building block.
struct SettingsSection<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).textRole(.heading)
            if let detail { Text(detail).textRole(.label, Theme.inkSecondary) }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .hoursCard(padding: Theme.Space.m)
        }
    }
}

/// Hairline between rows inside a SettingsSection card.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: Theme.Stroke.hairline)
            .padding(.vertical, Theme.Space.s)
    }
}

/// Scrolling page scaffold shared by the tabs.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.sectionGap) { content }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
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

extension View {
    /// `HoursButtonStyle` doesn't dim when disabled; apply inside `.disabled(_:)`.
    func settingsDimsWhenDisabled() -> some View { modifier(SettingsDisabledDim()) }
}

private struct SettingsDisabledDim: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View { content.opacity(isEnabled ? 1 : 0.4) }
}
