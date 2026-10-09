import SwiftUI
import Charts

/// Swift Charts styling. No domain line, hairline gridlines, `label`/`inkTertiary` axis text,
/// transparent plot area. Colours only through `categoryScale` (one layer per chart).
public enum ChartStyle {
    public static let barRadius: CGFloat = 3
    /// Gap between stacked segments, drawn as a `canvas`-coloured stroke.
    public static let stackGap: CGFloat = 1
    public static let donutInner = 0.62
    public static let donutAngularInset: CGFloat = 1.5
    public static let gridOpacity = 0.6
}

public extension View {
    /// Axis + grid + plot styling for every Hours chart.
    func hoursChartStyle() -> some View {
        modifier(HoursChartStyleModifier())
    }

    /// Category colours by slot. `domain` order is the legend order; the range resolves for the
    /// current colour scheme.
    func categoryScale(_ items: [(name: String, slot: Int?)]) -> some View {
        modifier(CategoryScaleModifier(names: items.map(\.name), slots: items.map(\.slot)))
    }
}

struct HoursChartStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .chartXAxis { AxisMarks { _ in Self.marks() } }
            .chartYAxis { AxisMarks { _ in Self.marks() } }
            .chartPlotStyle { $0.background(.clear) }
    }

    @AxisMarkBuilder static func marks() -> some AxisMark {
        AxisGridLine(stroke: StrokeStyle(lineWidth: Theme.Stroke.hairline))
            .foregroundStyle(Theme.hairline.opacity(ChartStyle.gridOpacity))
        AxisValueLabel()
            .font(TextRole.label.font)
            .foregroundStyle(Theme.inkTertiary)
    }
}

struct CategoryScaleModifier: ViewModifier {
    let names: [String]
    let slots: [Int?]
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.chartForegroundStyleScale(domain: names, range: slots.map { Theme.Palette.swatch(slot: $0).color(scheme) })
    }
}
