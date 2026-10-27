import SwiftUI

/// Section title + flat card, the Settings building block.
public struct SettingsSection<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    public init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).textRole(.heading)
            if let detail { Text(detail).textRole(.label, Theme.inkSecondary) }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: Theme.Space.m)
        }
    }
}

/// Hairline between rows inside a SettingsSection card.
public struct SettingsDivider: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: Theme.Stroke.hairline)
            .padding(.vertical, Theme.Space.s)
    }
}

/// Scrolling page scaffold shared by the tabs.
public struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.sectionGap) { content }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }
}


public extension View {
    /// `RewindButtonStyle` doesn't dim when disabled; apply inside `.disabled(_:)`.
    func settingsDimsWhenDisabled() -> some View { modifier(SettingsDisabledDim()) }
}

private struct SettingsDisabledDim: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View { content.opacity(isEnabled ? 1 : 0.4) }
}
