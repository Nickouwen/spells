import SwiftUI

/// Goal ring. Ink on a `surfaceRaised` track — goals are meaning, but a tick carries "met"
/// without spending a colour. Starts at 12 o'clock, round cap; animates once on first appear.
public struct ProgressRing: View {
    public enum Size: CGFloat, CaseIterable, Sendable {
        case small = 28, medium = 64, large = 120
        var stroke: CGFloat { self == .small ? 4 : 8 }
    }

    let progress: Double
    let size: Size
    let label: String?
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `label` shows centred (medium/large only); met (≥ 1) shows a check instead.
    public init(progress: Double, size: Size = .medium, label: String? = nil) {
        self.progress = progress
        self.size = size
        self.label = label
    }

    var met: Bool { progress >= 1 }

    public var body: some View {
        let shown = appeared ? min(max(progress, 0), 1) : 0
        ZStack {
            Circle().stroke(Theme.surfaceRaised, lineWidth: size.stroke)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: size.stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if met {
                Image(systemName: "checkmark")
                    .font(.system(size: size.rawValue * 0.3, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            } else if let label, size != .small {
                Text(label).textRole(size == .large ? .metric : .label)
            }
        }
        .padding(size.stroke / 2)
        .frame(width: size.rawValue, height: size.rawValue)
        .onAppear {
            withAnimation(Theme.Motion.animation(Theme.Motion.firstAppear, reduceMotion: reduceMotion)) { appeared = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(met ? "Goal met" : "Goal \(Fmt.percent(progress))")
    }
}
