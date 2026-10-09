import SwiftUI

/// The one big number per screen: SF Pro Light 52 with 21 pt secondary units — `6h 42m`.
public struct HeroNumber: View {
    let parts: [Fmt.Part]
    let caption: String?
    let spoken: String
    /// Roll direction when no `hoursNumericValue` is set (e.g. paging back in time counts down).
    let countsDown: Bool
    @Environment(\.hoursNumericValue) private var numericValue

    public init(ms: Int64, caption: String? = nil, countsDown: Bool = false) {
        self.parts = Fmt.durationParts(ms: ms)
        self.caption = caption
        self.spoken = Fmt.durationSpoken(ms: ms)
        self.countsDown = countsDown
    }

    /// Non-duration hero (e.g. `value: "86", unit: "%"`).
    public init(value: String, unit: String? = nil, caption: String? = nil, countsDown: Bool = false) {
        self.parts = [Fmt.Part(value: value, unit: unit ?? "")]
        self.caption = caption
        self.spoken = value + (unit ?? "")
        self.countsDown = countsDown
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let caption { Text(caption).textRole(.micro) }
            HeroNumber.text(parts, value: .hero, unit: .heroUnit)
                .contentTransition(HeroNumber.roll(numericValue, countsDown: countsDown))
                .lineLimit(1)
                .fixedSize()   // never truncates; layouts give the hero ≥ 300 pt
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.map { "\($0), \(spoken)" } ?? spoken)
    }

    /// `6` `h` ` 42` `m` as one concatenated Text, so the baseline is shared and units sit small.
    static func text(_ parts: [Fmt.Part], value: TextRole, unit: TextRole) -> Text {
        var out = Text(verbatim: "")
        for (i, p) in parts.enumerated() {
            let v = Text(verbatim: (i > 0 ? " " : "") + p.value).role(value)
            out = Text("\(out)\(v)")
            if !p.unit.isEmpty {
                let u = Text(verbatim: p.unit).role(unit)
                out = Text("\(out)\(u)")
            }
        }
        return out
    }

    /// `.numericText(value:)` when the screen says what the numbers stand for (it picks the roll
    /// direction), else `.numericText(countsDown:)`.
    nonisolated static func roll(_ value: Double?, countsDown: Bool = false) -> ContentTransition {
        value.map { .numericText(value: $0) } ?? .numericText(countsDown: countsDown)
    }
}

extension EnvironmentValues {
    /// What the headline numbers stand for, so they roll up or down with it. The Day view sets the
    /// date, so the numbers count the way you travel. nil: the default roll.
    @Entry var hoursNumericValue: Double? = nil
}
