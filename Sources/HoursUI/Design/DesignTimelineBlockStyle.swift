import SwiftUI

/// How one timeline block looks: 3 pt solid category edge + light category tint + ink text.
/// Ink on tint keeps text contrast guaranteed for every slot; solid fill with white text fails
/// AA on amber/lime/cyan. Blocks shorter than `minTextHeight` collapse to a solid fill, no text.
/// Style only — the Canvas timeline (layout, hit-testing, text) is the Day view's job.
public struct TimelineBlockStyle: Hashable, Sendable {
    public static let edgeWidth: CGFloat = 3
    public static let tintAlpha = 0.18
    public static let minTextHeight: CGFloat = 14
    public static let radius = Theme.Radius.block
    /// Reserved top-right notch for item 8's "edited" glyph.
    public static let editedMarkSize: CGFloat = 6
    /// Focus sessions are drawn as a 2 pt ink bracket left of the lane — a non-hue mark, so the
    /// state layer never mixes with category colour.
    public static let focusBracketWidth: CGFloat = 2
    /// Idle hatch: 45°, 1 pt lines, 6 pt pitch, ink at 12 % over `surface`.
    public static let hatchPitch: CGFloat = 6
    public static let hatchAlpha = 0.12

    public let edge: Swatch
    /// Opaque: the category composited at `tintAlpha` over `surface`.
    public let tint: Swatch
    public let text: Swatch

    public init(slot: Int?) {
        edge = Theme.Palette.swatch(slot: slot)
        tint = edge.over(Theme.surface, alpha: Self.tintAlpha)
        text = Theme.ink
    }

    public static func isCollapsed(height: CGFloat) -> Bool { height < minTextHeight }

    /// Fill + edge for one block. Text is drawn by the caller in `text` (`TextRole.label`).
    public func draw(in ctx: inout GraphicsContext, rect: CGRect) {
        let shape = Path(roundedRect: rect, cornerRadius: min(Self.radius, rect.height / 2), style: .continuous)
        if Self.isCollapsed(height: rect.height) {
            ctx.fill(shape, with: .style(edge))
            return
        }
        ctx.fill(shape, with: .style(tint))
        var inner = ctx
        inner.clip(to: shape)
        inner.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: Self.edgeWidth, height: rect.height)), with: .style(edge))
    }

    /// Idle/AFK: faint ink hatch on `surface`, hairline-bounded. A pattern, not a hue, so it survives CVD.
    public static func drawIdle(in ctx: inout GraphicsContext, rect: CGRect) {
        let shape = Path(roundedRect: rect, cornerRadius: min(radius, rect.height / 2), style: .continuous)
        ctx.fill(shape, with: .style(Theme.surface))
        var inner = ctx
        inner.clip(to: shape)
        var lines = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            lines.move(to: CGPoint(x: x, y: rect.maxY))
            lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += hatchPitch
        }
        inner.stroke(lines, with: .style(Theme.ink.over(Theme.surface, alpha: hatchAlpha)), lineWidth: 1)
        ctx.stroke(shape, with: .style(Theme.hairline), lineWidth: Theme.Stroke.hairline)
    }

    /// Ink bracket marking a focus session spanning `rect` vertically, drawn left of the lane.
    public static func drawFocusBracket(in ctx: inout GraphicsContext, rect: CGRect, gap: CGFloat = Theme.Space.xs) {
        let x = rect.minX - gap - focusBracketWidth
        ctx.fill(Path(roundedRect: CGRect(x: x, y: rect.minY, width: focusBracketWidth, height: rect.height),
                      cornerRadius: focusBracketWidth / 2), with: .style(Theme.ink))
    }
}
