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
            if let detail {
                Text(detail).textRole(.detail).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.Space.readable, alignment: .leading)
            }
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

/// Label (and optional explanation) on the left, the switch in the trailing column: every settings switch
/// lines up, whatever its label's length.
public struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    public init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title; self.detail = detail; _isOn = isOn
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title).textRole(.body)
                if let detail { Text(detail).textRole(.detail).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Theme.Space.m)
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

/// A section's Save: its own footer row under a hairline, saying when there's something to save, so it
/// doesn't read as part of the last field. One style everywhere.
public struct SettingsSaveRow: View {
    let dirty: Bool
    let action: () -> Void

    public init(dirty: Bool, action: @escaping () -> Void) { self.dirty = dirty; self.action = action }

    public var body: some View {
        VStack(spacing: 0) {
            SettingsDivider()
            HStack(spacing: Theme.Space.s) {
                if dirty { Text("Unsaved changes").textRole(.detail) }
                Spacer()
                Button("Save", action: action).buttonStyle(PrimaryButtonStyle()).disabled(!dirty)
            }
        }
    }
}
