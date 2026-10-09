import CoreGraphics

/// `island_style` setting: which notch island the helper shows (W18). Default `both`.
public enum TrackerIslandStyle: String, Sendable, CaseIterable {
    case off, both, right

    public static let key = "island_style"

    /// Absent or unknown → `both`.
    public static func parse(_ raw: String?) -> TrackerIslandStyle {
        raw.flatMap { TrackerIslandStyle(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) } ?? .both
    }
}

/// The screen facts the island needs, copied out of `NSScreen` so the geometry is testable.
public struct TrackerIslandScreen: Sendable, Equatable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var safeAreaTop: CGFloat
    public var auxiliaryTopLeft: CGRect?
    public var auxiliaryTopRight: CGRect?

    public init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat = 0,
                auxiliaryTopLeft: CGRect? = nil, auxiliaryTopRight: CGRect? = nil) {
        self.frame = frame; self.visibleFrame = visibleFrame; self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft; self.auxiliaryTopRight = auxiliaryTopRight
    }

    /// The camera housing in global (bottom-left origin) coordinates; nil without a notch.
    public var notch: CGRect? {
        guard safeAreaTop > 0, let l = auxiliaryTopLeft, let r = auxiliaryTopRight, r.minX > l.maxX else { return nil }
        // The auxiliary areas have been seen both screen-local and global; local ones start at x 0.
        let dx = abs(l.minX - frame.minX) < 1 ? 0 : frame.minX - l.minX
        return CGRect(x: l.maxX + dx, y: frame.maxY - safeAreaTop, width: r.minX - l.maxX, height: safeAreaTop)
    }
}

/// Where the island's black shape goes, in global screen coordinates (bottom-left origin).
/// `collapsed` / `expanded` are the shape bodies; the top flares (notch mode) stick out `flare` pt
/// on each side at the very top, so the window frames are the bodies widened by `flare`.
public struct TrackerIslandGeometry: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case notch, pill }

    /// Default ear width; the helper passes `earWidth(forText:)` measured with its real font.
    public static let earWidth: CGFloat = 72
    /// Content inset from an ear's outer (rounded) edge — the same on both sides.
    public static let earOuterInset: CGFloat = 13
    /// Gap between the notch edge and the ear's content.
    public static let earInnerGap: CGFloat = 8
    public static let minEarWidth: CGFloat = 64
    public static let flare: CGFloat = 6
    public static let bottomRadius: CGFloat = 10
    public static let expandedRadius: CGFloat = 22
    /// Expanded card = collapsed (both ears) + this on each side, and the content band below the notch.
    public static let expandedGrow: CGFloat = 6
    public static let contentHeight: CGFloat = 98
    public static let pillHeight: CGFloat = 30
    public static let pillGap: CGFloat = 6

    public var mode: Mode
    /// The physical notch (notch mode) or the empty gap between the ears (pill, width 0).
    public var notch: CGRect
    public var collapsed: CGRect
    public var expanded: CGRect
    /// Ear bodies inside `collapsed`. Content sits `earOuterInset` in from the outer edge (left
    /// ear: left-aligned; right ear: right-aligned). `leftEar` is nil for style `right`.
    public var leftEar: CGRect?
    public var rightEar: CGRect

    public var flare: CGFloat { mode == .notch ? Self.flare : 0 }
    public var collapsedWindow: CGRect { collapsed.insetBy(dx: -flare, dy: 0) }
    public var expandedWindow: CGRect { expanded.insetBy(dx: -flare, dy: 0) }
    /// Bottom-corner radius of the collapsed body; a pill's is half its height (top corners too).
    public var collapsedRadius: CGFloat { mode == .notch ? Self.bottomRadius : collapsed.height / 2 }

    /// Ear wide enough for a label of `textWidth` (the widest one it must hold, e.g. "10h 59m") plus
    /// the inner gap and outer inset; fixed per font, so it doesn't jitter as the minutes change.
    public static func earWidth(forText textWidth: CGFloat) -> CGFloat {
        max(minEarWidth, (earInnerGap + textWidth + earOuterInset).rounded(.up))
    }

    /// The first screen with a notch, else a pill at the top of `screens[0]` (the menu-bar screen).
    /// nil for `off` or no screens.
    public static func make(screens: [TrackerIslandScreen], style: TrackerIslandStyle,
                            earWidth: CGFloat = earWidth) -> TrackerIslandGeometry? {
        guard style != .off else { return nil }
        if let s = screens.first(where: { $0.notch != nil }), let n = s.notch { return notch(n, style: style, ear: earWidth) }
        return screens.first.map { pill($0, style: style, ear: earWidth) }
    }

    static func notch(_ n: CGRect, style: TrackerIslandStyle, ear e: CGFloat) -> TrackerIslandGeometry {
        let left = style == .both ? CGRect(x: n.minX - e, y: n.minY, width: e, height: n.height) : nil
        let right = CGRect(x: n.maxX, y: n.minY, width: e, height: n.height)
        let collapsed = CGRect(x: n.minX - (left == nil ? 0 : e), y: n.minY,
                               width: n.width + e * (left == nil ? 1 : 2), height: n.height)
        let w = n.width + 2 * (e + expandedGrow), h = n.height + contentHeight
        let expanded = CGRect(x: n.midX - w / 2, y: n.maxY - h, width: w, height: h)
        return TrackerIslandGeometry(mode: .notch, notch: n, collapsed: collapsed, expanded: expanded,
                                     leftEar: left, rightEar: right)
    }

    /// No notch (external display, clamshell): a floating pill centred just below the menu bar.
    static func pill(_ s: TrackerIslandScreen, style: TrackerIslandStyle, ear pillEar: CGFloat) -> TrackerIslandGeometry {
        // visibleFrame stops under the menu bar (it equals frame.maxY when the bar auto-hides).
        let top = min(s.visibleFrame.maxY, s.frame.maxY) - pillGap
        let h = pillHeight, mid = s.frame.midX
        let gap = CGRect(x: mid, y: top - h, width: 0, height: h)
        let left = style == .both ? CGRect(x: mid - pillEar, y: top - h, width: pillEar, height: h) : nil
        let right = style == .both ? CGRect(x: mid, y: top - h, width: pillEar, height: h)
                                   : CGRect(x: mid - pillEar / 2, y: top - h, width: pillEar, height: h)
        let collapsed = left.map { $0.union(right) } ?? right
        // The same card as under a 220 pt notch (the MacBook's), so the content fits identically.
        let w = 220 + 2 * (pillEar + expandedGrow), eh = h + contentHeight
        let expanded = CGRect(x: mid - w / 2, y: top - eh, width: w, height: eh)
        return TrackerIslandGeometry(mode: .pill, notch: gap, collapsed: collapsed, expanded: expanded,
                                     leftEar: left, rightEar: right)
    }
}

public enum TrackerIslandFormat {
    /// "4h 17m", "17m", whole hours "6h"; under a minute "<1m"; 0 → "0m". Rounded to the nearest
    /// minute, like the app's `Fmt.duration`, so the island and the Day view agree.
    public static func duration(ms: Int64) -> String {
        let ms = max(0, ms)
        if ms == 0 { return "0m" }
        if ms < 60_000 { return "<1m" }
        let minutes = (ms + 30_000) / 60_000
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
