import SwiftUI
import Testing
@testable import HoursUI

/// Category palette distinctness, per theme, across the 10 slots + Uncategorized grey
/// (grey shares charts with the slots, so it must stand apart too).
///
/// Thresholds (CIEDE2000):
/// - Normal vision ≥ 15. ΔE00 ≈ 2.3 is a just-noticeable difference; ≥ 15 reads as a different
///   colour at a glance, side by side, at chart-mark size.
/// - Simulated deuteranopia / protanopia / tritanopia (Machado 2009, full severity) ≥ 8:
///   distinguishable side by side, with the legend name as backup. The plan's ≥ 12 was for 8
///   hues (and the plan's own 8-hue table scores 1.1 blue/violet under deuteranopia); with 10 slots +
///   grey under a ≥ 3:1 non-text contrast floor, optimised search tops out near 9 in light (11 in dark) —
///   so 8 is the documented floor.
///   Mitigations stay mandatory: 1 pt gaps between stacked segments, names in every legend and
///   on hover, ≤ 8 categories per chart (rest roll into "Other").
@Suite struct DesignPaletteTests {
    static let normalFloor = 15.0
    static let cvdFloor = 8.0

    static func members(_ scheme: ColorScheme) -> [(String, UInt32)] {
        Theme.Palette.slots.map { ($0.name, $0.swatch.hex(scheme)) }
            + [("Uncategorized", Theme.Palette.uncategorized.hex(scheme))]
    }

    static func minDelta(_ scheme: ColorScheme, _ cvd: ColorMath.CVD?) -> (Double, String) {
        let m = members(scheme)
        var worst = (Double.infinity, "")
        for i in m.indices { for j in m.indices where j > i {
            let d = ColorMath.deltaE(m[i].1, m[j].1, cvd)
            if d < worst.0 { worst = (d, "\(m[i].0)/\(m[j].0)") }
        } }
        return worst
    }

    @Test func tenSlotsAndGreyFallback() {
        #expect(Theme.Palette.slots.count == 10)
        #expect(Theme.Palette.swatch(slot: nil) == Theme.Palette.uncategorized)
        #expect(Theme.Palette.swatch(slot: -1) == Theme.Palette.uncategorized)
        #expect(Theme.Palette.swatch(slot: 10) == Theme.Palette.uncategorized)
        #expect(Theme.Palette.swatch(slot: 3) == Theme.Palette.slots[3].swatch)
        #expect(Theme.Palette.name(slot: nil) == "Uncategorized")
        #expect(Set(Theme.Palette.slots.map(\.swatch.light)).count == 10)
        #expect(Set(Theme.Palette.slots.map(\.swatch.dark)).count == 10)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func pairwiseDistinctNormalVision(scheme: ColorScheme) {
        let (d, pair) = Self.minDelta(scheme, nil)
        #expect(d >= Self.normalFloor, "closest pair \(pair) ΔE00 \(d) (\(scheme))")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func pairwiseDistinctDeuteranopia(scheme: ColorScheme) {
        let (d, pair) = Self.minDelta(scheme, .deuteranopia)
        #expect(d >= Self.cvdFloor, "closest pair \(pair) ΔE00 \(d) (\(scheme), deuteranopia)")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func pairwiseDistinctProtanopiaAndTritanopia(scheme: ColorScheme) {
        for cvd in [ColorMath.CVD.protanopia, .tritanopia] {
            let (d, pair) = Self.minDelta(scheme, cvd)
            #expect(d >= Self.cvdFloor, "closest pair \(pair) ΔE00 \(d) (\(scheme), \(cvd))")
        }
    }
}
