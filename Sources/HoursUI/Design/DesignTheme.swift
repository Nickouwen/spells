import SwiftUI

/// The token layer. Views use these and nothing else: no literal colours, sizes or paddings.
/// Grey by default; colour only means something (category, state, tracker health).
public enum Theme {
    // MARK: Surfaces & ink (monochrome base)

    public static let canvas        = Swatch(light: 0xFAFAF9, dark: 0x0E0E0F)
    public static let surface       = Swatch(light: 0xFFFFFF, dark: 0x171719)
    public static let surfaceRaised = Swatch(light: 0xF2F2F0, dark: 0x232326)
    /// 0.5 pt borders and gridlines. Decorative, exempt from contrast.
    public static let hairline      = Swatch(light: 0xE2E2DE, dark: 0x2E2E32)
    public static let ink           = Swatch(light: 0x111113, dark: 0xF5F5F4)
    public static let inkSecondary  = Swatch(light: 0x5C5C61, dark: 0xA1A1A8)
    public static let inkTertiary   = Swatch(light: 0x6E6E73, dark: 0x92929A)
    /// Disabled controls and non-text marks only — never body text.
    public static let inkDisabled   = Swatch(light: 0xA8A8AD, dark: 0x5A5A60)

    /// Text tokens and the backgrounds they may sit on (tested for AA).
    public static let textTokens: [(name: String, swatch: Swatch)] = [
        ("ink", ink), ("inkSecondary", inkSecondary), ("inkTertiary", inkTertiary),
    ]
    public static let backgrounds: [(name: String, swatch: Swatch)] = [
        ("canvas", canvas), ("surface", surface), ("surfaceRaised", surfaceRaised),
    ]

    /// Monochrome heat ramp: ink at 6 → 90 % over `surface`, six opaque steps.
    public static let heat: [Swatch] = [0.06, 0.20, 0.36, 0.52, 0.70, 0.90].map { ink.over(surface, alpha: $0) }

    // MARK: State layer — how it went. Never in the same chart as category colours.

    public enum StateLayer {
        public static let focus       = Swatch(light: 0x1F5FE0, dark: 0x7AA2FF)
        public static let distraction = Swatch(light: 0xD1330F, dark: 0xFF6B4A)
        public static let meeting     = Swatch(light: 0x7A3FD1, dark: 0xB794FF)
        public static let breakTime   = Swatch(light: 0x0B7F5F, dark: 0x4FD1A5)
        /// Idle is a pattern, not a hue (CVD-proof): `inkTertiary` hatch, see `TimelineBlockStyle.drawIdle`.
        public static let idle        = Theme.inkTertiary
        /// Tracker health dot only.
        public static let live        = breakTime
        public static let warn        = Swatch(light: 0xB45309, dark: 0xF2B134)

        /// Usable as text on `surface`/`canvas` (tested for AA).
        public static let all: [(name: String, swatch: Swatch)] = [
            ("focus", focus), ("distraction", distraction), ("meeting", meeting), ("breakTime", breakTime),
        ]
    }

    // MARK: Category layer — what you did. Indexed by `Category.colorSlot`.

    public enum Palette {
        /// Hue-anchored, then lightness-staggered by search so neighbours stay apart for
        /// deutan/protan/tritan viewers (see `DesignPaletteTests` for thresholds). Dark values keep
        /// each slot's hue (±14°). Every fill is ≥ 3:1 against `canvas` and `surface`.
        public static let slots: [(name: String, swatch: Swatch)] = [
            ("Blue",     Swatch(light: 0x085ED9, dark: 0x475CD5)),
            ("Gold",     Swatch(light: 0x836500, dark: 0xF5C231)),
            ("Green",    Swatch(light: 0x036446, dark: 0x25A085)),
            ("Red",      Swatch(light: 0x95221F, dark: 0xC91D2E)),
            ("Magenta",  Swatch(light: 0xB5249F, dark: 0x9C478E)),
            ("Lavender", Swatch(light: 0xA76EED, dark: 0xAE83FF)),
            ("Cyan",     Swatch(light: 0x1A9AB0, dark: 0x0FE0F6)),
            ("Olive",    Swatch(light: 0x607846, dark: 0xAFCC87)),
            ("Rose",     Swatch(light: 0xE62B64, dark: 0xFF6597)),
            ("Tan",      Swatch(light: 0xB7843D, dark: 0x9D8752)),
        ]
        public static let uncategorized = Swatch(light: 0x8E8E93, dark: 0x6E6E73)

        /// nil or out-of-range → Uncategorized grey.
        public static func swatch(slot: Int?) -> Swatch {
            guard let slot, slots.indices.contains(slot) else { return uncategorized }
            return slots[slot].swatch
        }

        public static func name(slot: Int?) -> String {
            guard let slot, slots.indices.contains(slot) else { return "Uncategorized" }
            return slots[slot].name
        }
    }

    // MARK: Space / shape / motion

    /// 4-pt grid.
    public enum Space {
        public static let xxs: CGFloat = 2, xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12
        public static let l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32, huge: CGFloat = 48
        public static let cardPadding = l, gridGap = m, sectionGap = xl, gutter = xl
    }

    /// Rounded rects, never capsules. Concentric rule: inner = outer − padding.
    public enum Radius {
        public static let chip: CGFloat = 6, block: CGFloat = 6, tile: CGFloat = 10, panel: CGFloat = 14
    }

    public enum Stroke {
        public static let hairline: CGFloat = 0.5, selection: CGFloat = 1.5
    }

    /// Seconds. Callers pass 0 when `accessibilityReduceMotion` is on (see `Theme.Motion.animation`).
    public enum Motion {
        public static let hover = 0.12, swap = 0.2, firstAppear = 0.5

        public static func animation(_ duration: Double, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeOut(duration: duration)
        }

        /// Results of a direct gesture (zoom, click-to-zoom, snap): fast, no bounce, retargets mid-flight.
        public static func snap(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0)
        }

        /// Larger settles (a block fitting into view, a panel resizing): calmer, still no bounce.
        public static func settle(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .smooth(duration: 0.35, extraBounce: 0)
        }

        /// The edit-flash highlight: full ink, then fades out over this.
        public static let flash = 0.4
    }
}
