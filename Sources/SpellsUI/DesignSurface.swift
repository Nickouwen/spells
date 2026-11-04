import SwiftUI

public extension View {
    /// Flat, opaque content surface: `surface` fill, hairline border, no shadow, no glass.
    func card(padding: CGFloat = Theme.Space.cardPadding, radius: CGFloat = Theme.Radius.tile) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
    }
}

/// Ink-outlined text button for content (empty states, inline actions). Pure SwiftUI shapes, so
/// it renders identically in `ImageRenderer`; system bordered buttons don't. Dims itself when disabled.
public struct RewindButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: .outlined)
    }
}

/// The one primary action in a group: filled ink, canvas text.
public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: .filled)
    }
}

/// A rare or destructive action that shouldn't compete (Remove, Quit): text only, secondary ink.
public struct QuietButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: .quiet)
    }
}

private struct StyledButton: View {
    enum Kind { case outlined, filled, quiet }
    let configuration: ButtonStyleConfiguration
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        let pressed = configuration.isPressed
        // A disabled primary is an outline: a dimmed filled slab reads as an enabled grey button.
        let kind = self.kind == .filled && !isEnabled ? .outlined : self.kind
        configuration.label
            .textRole(kind == .quiet ? .body : .bodyEmph,   // same size as its neighbours; quiet by colour alone
                      kind == .filled ? Theme.canvas : kind == .quiet ? Theme.inkSecondary : Theme.ink)
            .padding(.horizontal, kind == .quiet ? Theme.Space.s : Theme.Space.m)
            .padding(.vertical, Theme.Space.xs + Theme.Space.xxs)
            .background {
                switch kind {
                case .filled: shape.fill(Theme.ink.opacity(pressed ? 0.8 : 1))
                case .outlined: shape.fill(pressed ? Theme.surfaceRaised : Theme.surface)
                case .quiet: shape.fill(Theme.surfaceRaised.opacity(pressed ? 1 : 0))
                }
            }
            .overlay { if kind == .outlined { shape.strokeBorder(Theme.controlEdge, lineWidth: 1) } }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}
