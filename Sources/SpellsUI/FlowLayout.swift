import SwiftUI

/// Left-to-right, wrapping onto new lines (legend chips). Each child keeps its ideal size.
public struct FlowLayout: Layout {
    public init(spacing: CGFloat = Theme.Space.s, lineSpacing: CGFloat = Theme.Space.xs + Theme.Space.xxs) {
        self.spacing = spacing; self.lineSpacing = lineSpacing
    }
    var spacing: CGFloat = Theme.Space.s
    var lineSpacing: CGFloat = Theme.Space.xs + Theme.Space.xxs

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let r = frames(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? (r.map(\.maxX).max() ?? 0), height: r.map(\.maxY).max() ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
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
