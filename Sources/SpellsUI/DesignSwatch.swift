import SwiftUI

/// A colour token: one sRGB value per appearance. Raw hex stays inspectable so tests can
/// compute WCAG contrast and CVD distance from the exact values the UI draws.
///
/// Resolves from `EnvironmentValues.colorScheme`, so `ImageRenderer` and
/// `.environment(\.colorScheme, .dark)` pick the right branch without an NSAppearance.
// ponytail: no Increase Contrast branch yet — every text pair already clears AA in both themes.
public struct Swatch: ShapeStyle, Hashable, Sendable {
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    public func hex(_ scheme: ColorScheme) -> UInt32 { scheme == .dark ? dark : light }

    public func color(_ scheme: ColorScheme) -> Color {
        let h = hex(scheme)
        return Color(.sRGB,
                     red: Double((h >> 16) & 0xFF) / 255,
                     green: Double((h >> 8) & 0xFF) / 255,
                     blue: Double(h & 0xFF) / 255)
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        color(environment.colorScheme)
    }

    /// `self` composited at `alpha` over `background`, per appearance, as an opaque token.
    /// Content stays opaque (no live transparency), and the result is testable for contrast.
    public func over(_ background: Swatch, alpha: Double) -> Swatch {
        Swatch(light: Swatch.mix(light, background.light, alpha),
               dark: Swatch.mix(dark, background.dark, alpha))
    }

    static func mix(_ fg: UInt32, _ bg: UInt32, _ a: Double) -> UInt32 {
        var out: UInt32 = 0
        for shift in [16, 8, 0] as [UInt32] {
            let f = Double((fg >> shift) & 0xFF), b = Double((bg >> shift) & 0xFF)
            out |= UInt32((f * a + b * (1 - a)).rounded()) << shift
        }
        return out
    }
}
