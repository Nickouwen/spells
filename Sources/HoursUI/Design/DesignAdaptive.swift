import SwiftUI

// Reflowing layouts for the content views (W16). They pick an arrangement from the width they're
// offered, so a narrow window wraps tiles and panels instead of clipping them. No GeometryReader
// state, so there's no first-frame jump. Cells in a row share the row's height (cards line up).

/// Hero + stat tiles. In order of preference:
/// 1. one row: hero (`heroWidth`), then the tiles in equal columns;
/// 2. hero on the left (as narrow as its own ideal width), tiles in a grid of half as many columns;
/// 3. hero on its own row, tiles below in `n`, `n/2` or 1 columns.
/// The first subview is the hero; the rest are tiles.
struct HeadlineLayout: Layout {
    var heroWidth: CGFloat = 300
    var tileMinWidth: CGFloat = StatTile.minWidth
    var spacing: CGFloat = Theme.Space.gridGap

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (heroWidth + CGFloat(subviews.count) * (tileMinWidth + spacing))
        return CGSize(width: width, height: arrange(width, subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, f) in arrange(bounds.width, subviews).frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: f.width, height: i == 0 ? nil : f.height))
        }
    }

    /// Frames relative to the origin, plus the total height.
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        guard let hero = subviews.first else { return ([], 0) }
        let tiles = Array(subviews.dropFirst())
        let n = tiles.count, half = max(1, (n + 1) / 2)
        func need(_ cols: Int) -> CGFloat { CGFloat(cols) * tileMinWidth + CGFloat(max(cols - 1, 0)) * spacing }
        func beside(_ heroW: CGFloat, cols: Int) -> (frames: [CGRect], height: CGFloat) {
            let heroH = hero.sizeThatFits(ProposedViewSize(width: heroW, height: nil)).height
            let grid = GridMath.frames(tiles, x: heroW + spacing, y: 0, width: width - heroW - spacing, cols: cols, spacing: spacing)
            return ([CGRect(x: 0, y: 0, width: heroW, height: heroH)] + grid.frames, max(heroH, grid.height))
        }
        if width >= heroWidth + spacing + need(n) { return beside(heroWidth, cols: n) }
        let heroIdeal = min(heroWidth, hero.sizeThatFits(.unspecified).width)
        if n > 1, width >= heroIdeal + spacing + need(half) {
            return beside(min(heroWidth, width - spacing - need(half)), cols: half)
        }
        let cols = width >= need(n) ? n : (width >= need(half) ? half : 1)
        let heroH = hero.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let top = heroH + Theme.Space.l
        let grid = GridMath.frames(tiles, x: 0, y: top, width: width, cols: cols, spacing: spacing)
        return ([CGRect(x: 0, y: 0, width: width, height: heroH)] + grid.frames, top + grid.height)
    }
}

/// Equal-width columns: the first count in `counts` whose columns are all ≥ `minColumnWidth`
/// (e.g. `[4, 2, 1]`: four panels side by side, else 2 × 2, else stacked).
struct ColumnsLayout: Layout {
    var minColumnWidth: CGFloat
    var counts: [Int]
    var spacing: CGFloat = Theme.Space.gridGap

    func columns(for width: CGFloat) -> Int {
        counts.first { c in CGFloat(c) * minColumnWidth + CGFloat(c - 1) * spacing <= width } ?? (counts.last ?? 1)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat(counts.first ?? 1) * (minColumnWidth + spacing)
        return CGSize(width: width, height: GridMath.frames(Array(subviews), x: 0, y: 0, width: width,
                                                            cols: columns(for: width), spacing: spacing).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = GridMath.frames(Array(subviews), x: 0, y: 0, width: bounds.width, cols: columns(for: bounds.width), spacing: spacing)
        for (i, f) in grid.frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }
}

/// A flexible leading view beside a fixed-width trailing one; stacked (both full width) when the
/// leading view would get less than `leadingMinWidth`.
struct SplitLayout: Layout {
    var trailingWidth: CGFloat
    var leadingMinWidth: CGFloat
    var spacing: CGFloat = Theme.Space.gridGap

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (leadingMinWidth + spacing + trailingWidth)
        let f = frames(width, subviews)
        return CGSize(width: width, height: f.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, f) in frames(bounds.width, subviews).enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }

    private func frames(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        guard subviews.count == 2 else {
            return GridMath.frames(Array(subviews), x: 0, y: 0, width: width, cols: 1, spacing: spacing).frames
        }
        if width >= leadingMinWidth + spacing + trailingWidth {
            return GridMath.frames(Array(subviews), x: 0, y: 0, widths: [width - spacing - trailingWidth, trailingWidth],
                                   spacing: spacing).frames
        }
        return GridMath.frames(Array(subviews), x: 0, y: 0, width: width, cols: 1, spacing: spacing).frames
    }
}

enum GridMath {
    /// Row-major grid of `cols` equal columns; each row is as tall as its tallest cell.
    static func frames(_ views: [LayoutSubview], x: CGFloat, y: CGFloat, width: CGFloat, cols: Int,
                       spacing: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let cols = max(1, cols)
        let w = max(0, (width - CGFloat(cols - 1) * spacing) / CGFloat(cols))
        var out: [CGRect] = [], top = y
        for start in stride(from: 0, to: views.count, by: cols) {
            let row = views[start..<min(start + cols, views.count)]
            let h = row.map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
            for (j, _) in row.enumerated() {
                out.append(CGRect(x: x + CGFloat(j) * (w + spacing), y: top, width: w, height: h))
            }
            top += h + spacing
        }
        return (out, views.isEmpty ? 0 : top - spacing - y)
    }

    /// One row with explicit column widths.
    static func frames(_ views: [LayoutSubview], x: CGFloat, y: CGFloat, widths: [CGFloat],
                       spacing: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let h = zip(views, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        var cx = x
        let frames = widths.map { w in defer { cx += w + spacing }; return CGRect(x: cx, y: y, width: w, height: h) }
        return (frames, h)
    }
}

/// Left-to-right, wrapping onto new lines (legend chips). Each child keeps its ideal size.
struct FlowLayout: Layout {
    var spacing: CGFloat = Theme.Space.s
    var lineSpacing: CGFloat = Theme.Space.xs + Theme.Space.xxs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let r = frames(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? (r.map(\.maxX).max() ?? 0), height: r.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, f) in frames(bounds.width, subviews).enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(f.size))
        }
    }

    private func frames(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        var out: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            out.append(CGRect(x: x, y: y, width: min(s.width, width), height: s.height))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
        return out
    }
}
