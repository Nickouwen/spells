import SwiftUI

/// Secondary metric: eyebrow, 28 pt value with small units, at most one comparator, optional sparkline.
public struct StatTile: View {
    let eyebrow: String
    let parts: [Fmt.Part]
    let comparator: String?
    let spark: [Double]?
    /// VoiceOver value: "6 hours 42 minutes", "88%".
    let spokenValue: String
    /// Roll direction when no `hoursNumericValue` is set (e.g. paging back in time counts down).
    let countsDown: Bool
    @Environment(\.hoursNumericValue) private var numericValue

    public init(_ eyebrow: String, ms: Int64, comparator: String? = nil, spark: [Double]? = nil, countsDown: Bool = false) {
        self.init(eyebrow, parts: Fmt.durationParts(ms: ms), spoken: Fmt.durationSpoken(ms: ms), comparator: comparator, spark: spark,
                  countsDown: countsDown)
    }

    public init(_ eyebrow: String, value: String, unit: String? = nil, comparator: String? = nil, spark: [Double]? = nil,
                countsDown: Bool = false) {
        self.init(eyebrow, parts: [Fmt.Part(value: value, unit: unit ?? "")],
                  spoken: value == "–" ? "none" : value + (unit ?? ""), comparator: comparator, spark: spark, countsDown: countsDown)
    }

    init(_ eyebrow: String, parts: [Fmt.Part], spoken: String, comparator: String?, spark: [Double]?, countsDown: Bool = false) {
        self.eyebrow = eyebrow; self.parts = parts; self.spokenValue = spoken; self.comparator = comparator; self.spark = spark
        self.countsDown = countsDown
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(eyebrow).textRole(.micro).lineLimit(1)
            Spacer(minLength: 0)
            // The number never truncates: the sparkline shrinks, then drops, to make room.
            ViewThatFits(in: .horizontal) {
                valueRow(sparkWidth: 56)
                valueRow(sparkWidth: 32)
                valueRow(sparkWidth: nil)
            }
            if let comparator {
                Text(comparator).textRole(.label, Theme.inkTertiary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: Self.minWidth - 2 * Theme.Space.cardPadding, maxWidth: .infinity, minHeight: 92, maxHeight: .infinity, alignment: .topLeading)
        .hoursCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(eyebrow.capitalized)
        .accessibilityValue(([spokenValue] + [comparator].compactMap { $0 }).joined(separator: ", "))
    }

    /// Narrowest a tile (card incl. padding) gets in a reflowing headline. The number still fits.
    nonisolated static let minWidth: CGFloat = 168

    private func valueRow(sparkWidth: CGFloat?) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: Theme.Space.s) {
            HeroNumber.text(parts, value: .metric, unit: .metricUnit)
                .contentTransition(HeroNumber.roll(numericValue, countsDown: countsDown))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            if let sparkWidth, let spark, spark.count > 1 {
                Sparkline(values: spark).frame(width: sparkWidth, height: 24)
            }
        }
    }
}

/// 1.5 pt ink line with a terminal dot. Monochrome: a sparkline shows shape, not meaning.
public struct Sparkline: View {
    let values: [Double]
    public init(values: [Double]) { self.values = values }

    public var body: some View {
        Canvas { ctx, size in
            let pts = Sparkline.points(values, in: size, inset: 2)
            guard let last = pts.last else { return }
            var path = Path()
            path.addLines(pts)
            ctx.stroke(path, with: .style(Theme.ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)), with: .style(Theme.ink))
        }
        .accessibilityHidden(true)
    }

    static func points(_ v: [Double], in size: CGSize, inset: CGFloat) -> [CGPoint] {
        guard v.count > 1, let lo = v.min(), let hi = v.max() else { return [] }
        let span = hi - lo == 0 ? 1 : hi - lo
        let w = size.width - inset * 2, h = size.height - inset * 2
        return v.enumerated().map { i, x in
            CGPoint(x: inset + w * CGFloat(i) / CGFloat(v.count - 1), y: inset + h * (1 - CGFloat((x - lo) / span)))
        }
    }
}
