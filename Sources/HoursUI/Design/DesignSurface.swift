import SwiftUI

public extension View {
    /// Flat, opaque content surface: `surface` fill, hairline border, no shadow, no glass.
    func hoursCard(padding: CGFloat = Theme.Space.cardPadding, radius: CGFloat = Theme.Radius.tile) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
    }
}

/// Ink-outlined text button for content (empty states, inline actions). Pure SwiftUI shapes, so
/// it renders identically in `ImageRenderer`; system bordered buttons don't.
public struct HoursButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textRole(.bodyEmph)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.xs + Theme.Space.xxs)
            .background(configuration.isPressed ? Theme.surfaceRaised : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(Theme.ink, lineWidth: 1))
            .contentShape(Rectangle())
    }
}
