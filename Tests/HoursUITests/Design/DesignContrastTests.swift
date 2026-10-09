import SwiftUI
import Testing
@testable import HoursUI

/// WCAG 2.x AA, computed from the token hex values: 4.5:1 for body text, 3:1 for large text
/// and non-text marks (1.4.11). Every text token clears 4.5 everywhere it may sit, so the
/// large-text roles (hero/metric units) are covered by the stricter bound.
@Suite struct DesignContrastTests {
    static let schemes: [ColorScheme] = [.light, .dark]

    @Test func colorMathMatchesReferences() {
        #expect(abs(ColorMath.contrast(0x000000, 0xFFFFFF) - 21) < 1e-9)
        #expect(abs(ColorMath.contrast(0x777777, 0xFFFFFF) - 4.48) < 0.01)
        // Sharma et al. 2005 test pairs 1 and 17.
        #expect(abs(ColorMath.ciede2000((50, 2.6772, -79.7751), (50, 0, -82.7485)) - 2.0425) < 1e-4)
        #expect(abs(ColorMath.ciede2000((50, 2.5, 0), (73, 25, -18)) - 27.1492) < 1e-4)
        // Achromatic colours are (nearly) unchanged by the CVD matrices.
        for cvd in ColorMath.CVD.allCases {
            #expect(ColorMath.deltaE(0x808080, 0x808080, cvd) < 1e-9)
            #expect(ColorMath.ciede2000(ColorMath.lab(ColorMath.simulate(0xFFFFFF, cvd)), ColorMath.lab(ColorMath.rgb(0xFFFFFF))) < 1.5)
        }
    }

    @Test func swatchBlendIsPerChannel() {
        #expect(Swatch.mix(0xFF0000, 0x0000FF, 0.5) == 0x800080)
        #expect(Swatch.mix(0x123456, 0xFFFFFF, 1) == 0x123456)
        #expect(Swatch.mix(0x123456, 0xFFFFFF, 0) == 0xFFFFFF)
    }

    @Test(arguments: schemes)
    func textTokensPassAAOnEveryBackground(scheme: ColorScheme) {
        for text in Theme.textTokens {
            for bg in Theme.backgrounds {
                let ratio = ColorMath.contrast(text.swatch.hex(scheme), bg.swatch.hex(scheme))
                #expect(ratio >= 4.5, "\(text.name) on \(bg.name) (\(scheme)) = \(ratio)")
            }
        }
    }

    @Test(arguments: schemes)
    func stateColorsPassAAAsText(scheme: ColorScheme) {
        for state in Theme.StateLayer.all {
            for bg in [("surface", Theme.surface), ("canvas", Theme.canvas)] {
                let ratio = ColorMath.contrast(state.swatch.hex(scheme), bg.1.hex(scheme))
                #expect(ratio >= 4.5, "\(state.name) on \(bg.0) (\(scheme)) = \(ratio)")
            }
        }
    }

    @Test(arguments: schemes)
    func healthDotsAndCategoryMarksPassNonText(scheme: ColorScheme) {
        let marks = [("live", Theme.StateLayer.live), ("warn", Theme.StateLayer.warn)]
            + Theme.Palette.slots.map { ($0.name, $0.swatch) } + [("uncategorized", Theme.Palette.uncategorized)]
        for mark in marks {
            for bg in [("canvas", Theme.canvas), ("surface", Theme.surface)] {
                let ratio = ColorMath.contrast(mark.1.hex(scheme), bg.1.hex(scheme))
                #expect(ratio >= 3, "\(mark.0) on \(bg.0) (\(scheme)) = \(ratio)")
            }
        }
    }

    /// Timeline block text is ink on the category tint — must stay AA for every slot.
    @Test(arguments: schemes)
    func inkOnEveryBlockTintPassesAA(scheme: ColorScheme) {
        for slot in Array(Theme.Palette.slots.indices).map(Optional.some) + [nil] {
            let style = TimelineBlockStyle(slot: slot)
            let ratio = ColorMath.contrast(style.text.hex(scheme), style.tint.hex(scheme))
            #expect(ratio >= 4.5, "ink on slot \(String(describing: slot)) tint (\(scheme)) = \(ratio)")
        }
    }
}
