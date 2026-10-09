import SwiftUI
import Charts
import HoursCore

/// Work per day, stacked by category, with a dashed goal rule over each scheduled day.
/// Future days are ghost columns. Hover highlights a day and shows its readout; click opens it.
struct WeekChart: View {
    let data: WeekData
    let onSelectDay: (LocalDate) -> Void
    @State private var hover: Int?
    /// 0 → 1 once on first appear: the bars grow from the baseline. A week change keeps it at 1.
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let plotHeight: CGFloat = 168
    static let half = 0.21

    private var yMax: Double {
        let peak = Double(max(data.metrics.days.map(\.metrics.workMs).max() ?? 0, data.goal?.dailyWorkMs ?? 0)) / 3_600_000
        return max(2, (peak / 2).rounded(.up) * 2)
    }

    var body: some View {
        let legend = data.legend
        let segs = data.segments
        let dates = data.dates
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Work per day").textRole(.heading)
                Spacer()
                Text(readout).textRole(.label, Theme.inkTertiary).lineLimit(1)
            }
            Chart {
                ForEach(dates.indices.filter { data.isFuture(dates[$0]) }, id: \.self) { i in
                    RectangleMark(xStart: .value("Day", Double(i) - Self.half), xEnd: .value("Day", Double(i) + Self.half),
                                  yStart: .value("Hours", 0), yEnd: .value("Hours", yMax))
                        .foregroundStyle(Theme.surfaceRaised.opacity(0.6))
                        .cornerRadius(ChartStyle.barRadius)
                }
                ForEach(segs, id: \.self) { s in
                    let lo = Double(s.loMs) / 3_600_000, hi = Double(s.hiMs) / 3_600_000
                    // 1 pt gap between stacked segments (design rule): trim each non-top segment's top.
                    let onePt = yMax / Double(Self.plotHeight)
                    let top = s.isTop ? hi : max(lo + onePt * 0.25, hi - onePt)
                    let g = grown ? 1.0 : 0
                    RectangleMark(xStart: .value("Day", Double(s.day) - Self.half), xEnd: .value("Day", Double(s.day) + Self.half),
                                  yStart: .value("Hours", lo * g), yEnd: .value("Hours", top * g))
                        .foregroundStyle(by: .value("Category", s.name))
                        .cornerRadius(s.isTop ? ChartStyle.barRadius : 0)
                        .accessibilityLabel("\(dates[s.day].rangeShortLabel), \(s.name)")
                        .accessibilityValue(Fmt.durationSpoken(ms: s.hiMs - s.loMs))
                }
                ForEach(dates.indices.filter { data.goalMs(dates[$0]) != nil }, id: \.self) { i in
                    RuleMark(xStart: .value("Day", Double(i) - 0.34), xEnd: .value("Day", Double(i) + 0.34),
                             y: .value("Goal", Double(data.goalMs(dates[i])!) / 3_600_000))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(Theme.inkSecondary)
                        .accessibilityHidden(true)
                }
            }
            .chartXScale(domain: -0.5...6.5)
            .chartYScale(domain: 0...yMax)
            .chartXAxis {
                AxisMarks(values: Array(0..<7).map(Double.init)) { v in
                    AxisValueLabel(centered: false, anchor: .top) {
                        if let x = v.as(Double.self) { dayLabel(Int(x.rounded())) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: Theme.Stroke.hairline))
                        .foregroundStyle(Theme.hairline)
                    AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))h").textRole(.label, Theme.inkTertiary) } }
                }
            }
            .chartPlotStyle { $0.frame(height: Self.plotHeight).background(.clear) }
            .categoryScale(legend.map { ($0.name, $0.slot) })
            .chartLegend(.hidden)
            // The hover column is a view, not a mark, so moving between days crossfades instead of sliding.
            .chartBackground { proxy in
                GeometryReader { geo in
                    if let h = hover, let frame = proxy.plotFrame.map({ geo[$0] }),
                       let x0 = proxy.position(forX: Double(h) - 0.46), let x1 = proxy.position(forX: Double(h) + 0.46) {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .fill(Theme.surfaceRaised)
                            .frame(width: x1 - x0, height: frame.height)
                            .offset(x: frame.minX + x0, y: frame.minY)
                            .id(h)
                            .transition(.opacity)
                    }
                }
                .animation(Theme.Motion.animation(Theme.Motion.hover, reduceMotion: reduceMotion), value: hover)
            }
            .onAppear { withAnimation(Theme.Motion.animation(Theme.Motion.firstAppear, reduceMotion: reduceMotion)) { grown = true } }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(p): hover = day(at: p, proxy: proxy, geo: geo)
                            case .ended: hover = nil
                            }
                        }
                        .onTapGesture { p in
                            if let i = day(at: p, proxy: proxy, geo: geo), !data.isFuture(dates[i]) { onSelectDay(dates[i]) }
                        }
                        .pointerStyle(hover.map { data.isFuture(dates[$0]) } == false ? .link : nil)
                }
            }

            HStack(spacing: Theme.Space.m) {
                RangeLegend(items: legend.map { ($0.name, $0.slot) })
                if data.goal != nil {
                    HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
                        Path { p in p.move(to: CGPoint(x: 0, y: 0.5)); p.addLine(to: CGPoint(x: 14, y: 0.5)) }
                            .stroke(Theme.inkSecondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(width: 14, height: 1)
                        Text("Daily goal \(Fmt.duration(ms: data.goal!.dailyWorkMs))").textRole(.label, Theme.inkSecondary)
                    }
                    .fixedSize()
                }
            }
        }
        .hoursCard()
    }

    /// Hovered day's numbers, else a hint.
    private var readout: String {
        guard let h = hover else { return "Click a day to open it" }
        let d = data.dates[h]
        if data.isFuture(d) { return "\(d.rangeShortLabel) · not yet" }
        var parts = ["\(d.rangeShortLabel)", "\(Fmt.duration(ms: data.workMs(d))) work"]
        if let g = data.goalMs(d) { parts.append(data.goalMet(d) ? "goal met" : "\(Fmt.duration(ms: g - data.workMs(d))) short") }
        if let m = data.dayMetrics(d), m.trackedMs > m.workMs { parts.append("\(Fmt.duration(ms: m.trackedMs - m.workMs)) not work") }
        return parts.joined(separator: " · ")
    }

    private func day(at p: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Int? {
        guard let frame = proxy.plotFrame.map({ geo[$0] }), let x = proxy.value(atX: p.x - frame.minX, as: Double.self) else { return nil }
        let i = Int(x.rounded())
        return (0..<7).contains(i) ? i : nil
    }

    /// `Mon 28` over the day's work (or a tracker-gap warning).
    @ViewBuilder private func dayLabel(_ i: Int) -> some View {
        if (0..<7).contains(i) {
            let d = data.dates[i]
            let future = data.isFuture(d)
            VStack(spacing: 1) {
                Text("\(d.rangeShortLabel.prefix(3)) \(d.day)")
                    .textRole(.label, future || d == data.today ? (future ? Theme.inkDisabled : Theme.ink) : Theme.inkTertiary)
                HStack(spacing: Theme.Space.xxs) {
                    if data.hasGap(d) {
                        Image(systemName: "exclamationmark.triangle.fill").font(TextRole.micro.font).imageScale(.small)
                            .foregroundStyle(Theme.StateLayer.warn)
                            .help("Tracker gap this day")
                    }
                    if data.goalMet(d) {
                        Image(systemName: "checkmark").font(TextRole.micro.font).imageScale(.small).foregroundStyle(Theme.inkSecondary)
                    }
                    Text(future ? "–" : Fmt.duration(ms: data.workMs(d)))
                        .font(TextRole.micro.font.monospacedDigit()).foregroundStyle(Theme.inkTertiary)
                }
            }
            .fixedSize()
        }
    }
}
