import SwiftUI
import Charts
import HoursCore

/// The invoice view: totals over a period, per-day stacked bars, billable by project, and a
/// sortable breakdown by category / project / app / site with a detail sheet per row.
/// Read-only over `RangeData`; the host reloads data when `period` changes.
public struct RangeView: View {
    let data: RangeData
    @Binding var period: RangePeriod
    let today: LocalDate
    @State private var group: RangeGroup
    @State private var detail: RangeRow?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(data: RangeData, period: Binding<RangePeriod>, today: LocalDate? = nil, group: RangeGroup = .category) {
        self.data = data
        self._period = period
        self.today = today ?? LocalDate.containing(ms: Int64(Date().timeIntervalSince1970 * 1000), in: .current)
        self._group = State(initialValue: group)
    }

    public var body: some View {
        Group {
            if data.metrics.trackedMs == 0 {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    RangePeriodBar(period: $period, today: today)
                    EmptyState(symbol: "calendar", title: "No tracked time in this period",
                               detail: "Nothing was recorded between \(RangePeriod.label(data.bounds)). Step back with ‹ to find earlier time.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .hoursCard()
                }
                .padding(Theme.Space.gutter)
            } else {
                // Scrolls vertically; the table sizes to its rows (see RangeTableCard.tableHeight).
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        RangePeriodBar(period: $period, today: today)
                        headline
                            // Totals roll when the loaded period changes, not on the minute refetch.
                            .animation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion), value: data.bounds)
                        SplitLayout(trailingWidth: 360, leadingMinWidth: 480) {
                            RangeDailyChart(data: data)
                            RangeBillableCard(data: data)
                        }
                        RangeTableCard(data: data, group: $group, detail: $detail)
                    }
                    .padding(Theme.Space.gutter)
                }
                .scrollEdgeEffectStyle(.hard, for: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        .sheet(item: $detail) { row in
            RangeDetailView(data: data, row: row) { detail = nil }
        }
    }

    // MARK: Headline: hero + ≤ 4 tiles

    private var headline: some View {
        let m = data.metrics
        let workdays = m.days.filter { $0.metrics.workMs > 0 }.count
        return HeadlineLayout {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                // The invoice figure (0.01 h per day × project row, summed), so it equals the export.
                HeroNumber(value: ExportPeriodData.hours(data.invoiceHundredths), unit: "h", caption: "Billable work · invoice")
                    .help("\(Fmt.duration(ms: m.billableMs)) exact; the invoice rounds each day × project row to 0.01 h")
                HStack(spacing: Theme.Space.s) {
                    if data.editCount > 0 { RangeEditedMark(deltaMs: data.billableDeltaMs) }
                    Text(provenance).textRole(.label, Theme.inkTertiary).lineLimit(1)
                }
            }

            StatTile("Work", ms: m.workMs, comparator: m.workMs > 0 ? "\(Fmt.percent(Double(m.billableMs) / Double(m.workMs))) billable" : nil,
                     spark: workdays > 1 ? m.days.compactMap { $0.metrics.workMs > 0 ? Double($0.metrics.workMs) : nil } : nil)
            StatTile("Tracked", ms: m.trackedMs, comparator: "\(Fmt.duration(ms: m.trackedMs - m.workMs)) not work")
            StatTile("Focus", value: m.focusRatio.map { "\(Int(($0 * 100).rounded()))" } ?? "–", unit: m.focusRatio == nil ? nil : "%",
                     comparator: "\(m.focusSessionCount) sessions · \(Fmt.duration(ms: m.focusMs))")
            StatTile("Avg / workday", ms: workdays > 0 ? m.workMs / Int64(workdays) : 0,
                     comparator: "\(workdays) of \(data.days.count) days worked")
        }
    }

    private var provenance: String {
        let exact = Fmt.duration(ms: data.metrics.billableMs)
        let raw = "raw \(Fmt.duration(ms: data.raw.billableMs))"
        guard data.editCount > 0 else { return "\(exact) · raw record, no edits" }
        let n = data.editCount == 1 ? "1 edit" : "\(data.editCount) edits"
        return "\(exact) · \(raw) · \(RangeEditedMark.signed(data.billableDeltaMs)) · \(n)"
    }
}

// MARK: - Per-day stacked bars

struct RangeDailyChart: View {
    let data: RangeData
    static let plotHeight: CGFloat = 176

    /// Y ceiling in whole hours, rounded up to an even number so the 3–4 gridlines land on integers.
    private var yMax: Double {
        let peak = Double(data.metrics.days.map(\.metrics.trackedMs).max() ?? 0) / 3_600_000
        return max(2, (peak / 2).rounded(.up) * 2)
    }

    /// One point in hours, for the stack gap (the plot area is pinned to `plotHeight`).
    private var gapHours: Double { yMax / Double(Self.plotHeight) }

    var body: some View {
        let legend = data.chartLegend
        let marks = data.chartMarks
        let gapDays = Set(data.gapDays.map(\.date))
        let byKey = Dictionary(uniqueKeysWithValues: data.days.map { ($0.date.description, $0.date) })
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tracked per day").textRole(.heading)
                Spacer()
                Text("by category").textRole(.label, Theme.inkTertiary)
            }
            Spacer(minLength: 0)
            Chart {
                ForEach(marks.indices, id: \.self) { i in
                    let mk = marks[i]
                    let lo = Double(mk.startMs) / 3_600_000, hi = Double(mk.startMs + mk.ms) / 3_600_000
                    // 1 pt canvas gap between stacked segments (design rule), drawn by trimming the segment top.
                    let top = mk.isTop ? hi : max(lo + gapHours * 0.25, hi - gapHours)
                    BarMark(x: .value("Day", mk.date.description), yStart: .value("Hours", lo), yEnd: .value("Hours", top),
                            width: .ratio(0.62))
                        .foregroundStyle(by: .value("Category", mk.name))
                        .cornerRadius(mk.isTop ? ChartStyle.barRadius : 0)
                        .accessibilityLabel("\(mk.date.rangeShortLabel), \(mk.name)")
                        .accessibilityValue(Fmt.durationSpoken(ms: mk.ms))
                }
            }
            .chartXScale(domain: data.days.map(\.date.description))
            .chartYScale(domain: 0...yMax)
            .chartXAxis {
                AxisMarks(values: data.days.map(\.date.description)) { v in
                    AxisValueLabel(centered: true) {
                        if let s = v.as(String.self), let d = byKey[s] {
                            VStack(spacing: 1) {
                                Text("\(d.day)").textRole(.label, d.isWeekend ? Theme.inkDisabled : Theme.inkTertiary)
                                if gapDays.contains(d) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(TextRole.micro.font)
                                        .imageScale(.small)
                                        .foregroundStyle(Theme.StateLayer.warn)
                                } else {
                                    Text(d.weekdayLetter).textRole(.micro, Theme.inkDisabled)
                                }
                            }
                        }
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

            RangeLegend(items: legend.map { ($0.name, $0.slot) })
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .hoursCard()
    }
}

/// Legend chips: mark + name, wrapping.
struct RangeLegend: View {
    let items: [(name: String, slot: Int?)]
    var body: some View {
        FlowLayout(spacing: Theme.Space.m) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
                    RangeMark(slot: items[i].slot, size: 7)
                    Text(items[i].name).textRole(.label, Theme.inkSecondary).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
