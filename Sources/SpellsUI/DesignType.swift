import SwiftUI

/// Type scale. SF Pro + SF Mono only; distinctiveness comes from size contrast and unit
/// styling (a Light hero with small secondary units), not a custom face. All numerals tabular.
public enum TextRole: CaseIterable, Sendable {
    case hero, heroUnit, metric, metricUnit, title, heading, body, bodyEmph, label, micro, mono

    public var font: Font {
        switch self {
        case .hero:       .system(size: 52, weight: .light).monospacedDigit()
        case .heroUnit:   .system(size: 21, weight: .regular)
        case .metric:     .system(size: 28, weight: .semibold).monospacedDigit()
        case .metricUnit: .system(size: 16, weight: .regular)
        case .title:      .system(size: 20, weight: .semibold)
        case .heading:    .system(size: 15, weight: .semibold)
        // body/label map to text styles so the macOS text-size setting still applies.
        case .body:       .body.monospacedDigit()                       // 13 pt
        case .bodyEmph:   .body.weight(.medium).monospacedDigit()
        case .label:      .subheadline.weight(.medium).monospacedDigit() // 11 pt (.caption is 10 on macOS)
        case .micro:      .system(size: 10, weight: .semibold)
        case .mono:       .system(size: 12, design: .monospaced)
        }
    }

    public var tracking: CGFloat {
        switch self {
        case .hero: -1.5
        case .micro: 0.6
        default: 0
        }
    }

    /// Default ink for the role. Units and eyebrows recede; everything else is full ink.
    public var swatch: Swatch {
        switch self {
        case .heroUnit, .metricUnit, .micro: Theme.inkSecondary
        default: Theme.ink
        }
    }

    public var uppercased: Bool { self == .micro }

    public var name: String { String(describing: self) }
}

public extension Text {
    /// Text-returning variant, for concatenation (`HeroNumber`). Case is the caller's job.
    func role(_ role: TextRole, _ swatch: Swatch? = nil) -> Text {
        font(role.font).tracking(role.tracking).foregroundStyle(swatch ?? role.swatch)
    }
}

public extension View {
    /// Font + tracking + case + ink for a role. `swatch` overrides the role's default ink.
    func textRole(_ role: TextRole, _ swatch: Swatch? = nil) -> some View {
        font(role.font)
            .tracking(role.tracking)
            .textCase(role.uppercased ? .uppercase : nil)
            .foregroundStyle(swatch ?? role.swatch)
    }
}
