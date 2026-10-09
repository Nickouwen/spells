import SwiftUI
import HoursCore

/// How the Day view shows the day: the horizontal Canvas timeline or the vertical Blocks column.
/// Persisted per user in `UserDefaults` (`day.mode`).
enum DayMode: String, CaseIterable, Hashable {
    case timeline, blocks

    static let storageKey = "day.mode"
    var title: String { self == .timeline ? "Timeline" : "Blocks" }
}

/// `Timeline | Blocks` in the Day header: the nav pill's shape, the selected segment raised.
struct DayModeToggle: View {
    @Binding var mode: DayMode

    var body: some View {
        HStack(spacing: Theme.Space.xxs) {
            ForEach(DayMode.allCases, id: \.self) { m in
                Button { mode = m } label: {
                    Text(m.title)
                        .font(TextRole.label.font)
                        .foregroundStyle(mode == m ? Theme.ink : Theme.inkTertiary)
                        .padding(.horizontal, Theme.Space.s + 2)
                        .frame(height: 22)
                        .background(mode == m ? Theme.surfaceRaised : Theme.surface,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip - 1, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(m == .timeline ? "Horizontal timeline of every span" : "The day as continuous work blocks")
                .accessibilityAddTraits(mode == m ? .isSelected : [])
            }
        }
        .padding(Theme.Space.xxs)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Day layout")
    }
}

/// Render/preview knobs: pin the threshold, minimum block length, the selected block, the hover,
/// an in-flight drag and the detail panel's project picker.
struct BlocksPreview: Hashable {
    var thresholdMin: Int
    var minBlockMin: Int? = nil
    var selectedMs: Int64? = nil
    var hoverMs: Int64? = nil
    var drag: BlocksDrag? = nil
    var projectPickerOpen = false
}

extension EnvironmentValues {
    /// A block opened from the Week's Blocks mode: the Day view selects it (and scrolls to it) when it
    /// shows that day.
    @Entry var blocksOpenRequest: WeekBlockRoute? = nil
}

/// An edge drag in flight: which block (by its start when the drag began), which edge, where it is now.
struct BlocksDrag: Hashable {
    var blockStartMs: Int64
    var edge: EditGesture.Edge
    var ms: Int64
}

/// The column's time ↔ y mapping. The column holds the whole 04:00 day and scrolls inside a
/// viewport that shows `blocks_window_hours` (18) at zoom 1. The Day column's viewport fills the
/// window's free height (W25), so its scale follows the window; the Week's columns keep the fixed
/// default `viewportHeight`.
struct BlocksGeometry: Hashable {
    static let topPad: CGFloat = 8
    static let gutter: CGFloat = 46
    /// Default visible column height: the window's hours plus a top and bottom pad (18 h × 32 pt + 16).
    static let viewportHeight: CGFloat = 592
    /// The Day column never shrinks below this (short windows scroll the page instead).
    static let minViewportHeight: CGFloat = 320
    /// Zoom out stops once the whole day fits; zoom in at 6×.
    static let minZoom: CGFloat = 0.75, maxZoom: CGFloat = 6
    static let hourMs: Int64 = 3_600_000
    /// Space kept above the first block / below the last when scrolling to them.
    static let padMs: Int64 = 20 * 60_000

    var startMs: Int64
    var endMs: Int64
    var pxPerHour: CGFloat
    /// Visible height of the scroll viewport the column sits in.
    var viewport: CGFloat = Self.viewportHeight

    var height: CGFloat { y(endMs) + Self.topPad }
    func y(_ ms: Int64) -> CGFloat { Self.topPad + CGFloat(Double(ms - startMs) / 3_600_000) * pxPerHour }
    func ms(atY y: CGFloat) -> Int64 { startMs + Int64(Double((y - Self.topPad) / pxPerHour) * 3_600_000) }

    /// Visible height / window hours (pads aside), times `zoom`.
    static func pxPerHour(windowHours: Int, zoom: CGFloat, viewport: CGFloat = viewportHeight) -> CGFloat {
        (viewport - 2 * topPad) / CGFloat(max(windowHours, 1)) * zoom
    }

    /// The whole store day at the window scale.
    static func day(bounds: Range<Int64>, windowHours: Int, zoom: CGFloat = 1, viewport: CGFloat = viewportHeight) -> BlocksGeometry {
        BlocksGeometry(startMs: bounds.lowerBound, endMs: bounds.upperBound,
                       pxPerHour: pxPerHour(windowHours: windowHours, zoom: zoom, viewport: viewport), viewport: viewport)
    }

    /// Scroll offset that puts `ms`'s hour line just under the viewport's top pad, clamped to the content.
    func offset(top ms: Int64) -> CGFloat {
        min(max(y(ms) - Self.topPad, 0), max(0, height - viewport))
    }

    /// Scroll offset that centres `r` in the viewport, clamped to the content.
    func offset(centring r: Range<Int64>) -> CGFloat {
        offset(top: (r.lowerBound + r.upperBound) / 2 - Int64(Double((viewport - 2 * Self.topPad) / pxPerHour / 2) * Double(Self.hourMs)))
    }

    /// A zoom glide in flight. The real scroll offset jumps to `toY` with the content already at its
    /// final height (an animated scroll gets clamped to the old, shorter content and shakes), and the
    /// column shifts its drawing so the screen moves from `fromY` at `fromPx` to `toY` at `toPx`.
    struct Glide: Equatable {
        var fromPx: CGFloat, fromY: CGFloat, toPx: CGFloat, toY: CGFloat

        /// Drawing shift at scale `px`: the offset interpolated on the scale's progress, less the real one.
        func shift(at px: CGFloat) -> CGFloat {
            guard toPx != fromPx else { return 0 }
            return toY - (fromY + (px - fromPx) / (toPx - fromPx) * (toY - fromY))
        }
    }

    /// Click-to-zoom: the zoom at which `r` fills ~60 % of the viewport, within the zoom limits.
    static func focusZoom(_ r: Range<Int64>, windowHours: Int) -> CGFloat {
        let fit = CGFloat(Double(Int64(windowHours) * hourMs) / (Double(max(r.upperBound - r.lowerBound, 1)) * 1.6))
        return min(max(fit, minZoom), maxZoom)
    }

    /// `minutes` after local midnight on `date` (before the day start = the next morning).
    static func windowStart(_ date: LocalDate, timeZone: TimeZone, minutes: Int,
                            dayStartHour: Int = Hours.defaultDayStartHour) -> Int64 {
        let mins = minutes < dayStartHour * 60 ? minutes + 24 * 60 : minutes
        return date.dayInterval(in: timeZone, dayStartHour: 0).lowerBound + Int64(mins) * 60_000
    }

    /// The time at the viewport's top by default: `windowStart` (06:00), moved down until the last
    /// block shows, then up until the first block shows (it wins), then to `focus` (a block opened
    /// from the Week). Moves land on whole hours of `range` (the 04:00 day); clamped to it.
    /// Works on any time line: ms (the Day column) or offsets after day start (the Week's columns).
    static func defaultTop(range: Range<Int64>, windowStart: Int64, windowMs: Int64, first: Int64?, last: Int64?,
                           focus: Range<Int64>? = nil, padMs: Int64 = padMs) -> Int64 {
        func floorH(_ t: Int64) -> Int64 { range.lowerBound + Int64((Double(t - range.lowerBound) / Double(hourMs)).rounded(.down)) * hourMs }
        func ceilH(_ t: Int64) -> Int64 { range.lowerBound + Int64((Double(t - range.lowerBound) / Double(hourMs)).rounded(.up)) * hourMs }
        var top = windowStart
        if let last, last + padMs > top + windowMs { top = ceilH(last + padMs) - windowMs }
        if let first, first - padMs < top { top = floorH(first - padMs) }
        if let f = focus {
            if f.lowerBound - padMs < top { top = floorH(f.lowerBound - padMs) }
            else if f.upperBound + padMs > top + windowMs { top = min(floorH(f.lowerBound - padMs), ceilH(f.upperBound + padMs) - windowMs) }
        }
        return min(max(top, range.lowerBound), max(range.lowerBound, range.upperBound - windowMs))
    }

    static func hourFloor(_ ms: Int64, _ tz: TimeZone) -> Int64 {
        let off = Int64(tz.secondsFromGMT(for: Date(timeIntervalSince1970: Double(ms) / 1000))) * 1000
        let local = ms + off
        return local - ((local % 3_600_000) + 3_600_000) % 3_600_000 - off
    }

    /// Hour marks inside the column (local, so +05:30 zones get their own half-hour marks).
    func hours(_ tz: TimeZone) -> [Int64] {
        var out: [Int64] = []
        var t = Self.hourFloor(startMs, tz)
        if t < startMs { t += 3_600_000 }
        while t <= endMs { out.append(t); t += 3_600_000 }
        return out
    }
}
