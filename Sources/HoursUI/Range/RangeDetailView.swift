import SwiftUI
import Charts
import HoursCore

/// Detail sheet for one breakdown row: its per-day series, then where the time went
/// (top window titles and sites/apps).
public struct RangeDetailView: View {
    let data: RangeData
    let row: RangeRow
    let close: () -> Void
    /// Fits four `StatTile`s (200 pt minimum each, card padding included) plus gutters.
    public static let width: CGFloat = 900
    public static let height: CGFloat = 720

    public init(data: RangeData, row: RangeRow, close: @escaping () -> Void) {
        self.data = data
        self.row = row
        self.close = close
    }

    public var body: some View {
        let d = data.detail(row.id)
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.l)
            Divider().overlay(Theme.hairline)
            ScrollView {
                content(d)
                    .padding(Theme.Space.xl)
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
        }
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(Theme.canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                if row.isCategory { RangeMark(slot: row.slot, size: 10) }
                Text(row.name).textRole(.title).lineLimit(1)
                Text(kindLabel).textRole(.label, Theme.inkTertiary)
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(HoursButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            Text(RangePeriod.label(data.bounds)).textRole(.label, Theme.inkSecondary)
        }
    }

    private func content(_ d: RangeDetail) -> some View {
        let days = Dictionary(uniqueKeysWithValues: data.days.map { ($0.date.description, $0.date) })
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .top, spacing: Theme.Space.gridGap) {
                StatTile("Tracked", ms: row.trackedMs)
                StatTile(row.id.isProject ? "Billable" : "Work", ms: row.workMs)
                StatTile("Share", value: "\(Int((row.share * 100).rounded()))", unit: "%", comparator: "of tracked time")
                StatTile("Avg / active day", ms: row.avgPerActiveDayMs, comparator: "\(row.activeDays) of \(data.days.count) days")
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Per day").textRole(.heading)
                Chart {
                    ForEach(data.days.indices, id: \.self) { i in
                        BarMark(x: .value("Day", data.days[i].date.description),
                                y: .value("Hours", Double(row.daily[i]) / 3_600_000), width: .ratio(0.62))
                            .foregroundStyle(row.isCategory ? Theme.Palette.swatch(slot: row.slot) : Theme.inkSecondary)
                            .cornerRadius(ChartStyle.barRadius)
                    }
                }
                .chartXScale(domain: data.days.map(\.date.description))
                .chartXAxis {
                    AxisMarks(values: data.days.map(\.date.description)) { v in
                        AxisValueLabel(centered: true) {
                            if let s = v.as(String.self), let day = days[s] {
                                Text("\(day.day)").textRole(.label, day.isWeekend ? Theme.inkDisabled : Theme.inkTertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: Theme.Stroke.hairline)).foregroundStyle(Theme.hairline)
                        AxisValueLabel { if let h = v.as(Double.self) { Text(String(format: h < 1 && h > 0 ? "%.1fh" : "%.0fh", h)).textRole(.label, Theme.inkTertiary) } }
                    }
                }
                .chartPlotStyle { $0.background(.clear) }
                .frame(height: 110)
            }
            .hoursCard()

            HStack(alignment: .top, spacing: Theme.Space.gridGap) {
                list("Top titles", d.titles, limit: 20)
                if !d.contexts.isEmpty { list(contextTitle, d.contexts, limit: 10).frame(width: 280) }
            }
        }
    }

    private var kindLabel: String {
        switch row.id {
        case .category: "Category"
        case .project: "Project"
        case .app: "App"
        case .site: "Site"
        }
    }

    private var contextTitle: String {
        switch row.id {
        case .site: "Apps"
        case .app: "Sites"
        default: "Sites & apps"
        }
    }

    private func list(_ title: String, _ items: [RangeDetail.Item], limit: Int) -> some View {
        let top = max(items.first?.ms ?? 1, 1)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).textRole(.heading).padding(.bottom, Theme.Space.xs)
            if items.isEmpty {
                Text("Nothing to show").textRole(.body, Theme.inkTertiary)
            }
            ForEach(items.prefix(limit).indices, id: \.self) { i in
                let it = items[i]
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.s) {
                        Text(it.name).textRole(.body, i == 0 ? Theme.ink : Theme.inkSecondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Theme.Space.s)
                        Text(Fmt.duration(ms: it.ms)).textRole(.body, i == 0 ? Theme.ink : Theme.inkSecondary)
                    }
                    RangeShareBar(fraction: Double(it.ms) / Double(top), fill: i == 0 ? Theme.ink : Theme.inkDisabled)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hoursCard()
    }
}

extension RangeKey {
    var isProject: Bool { if case .project = self { true } else { false } }
}
