import SwiftUI
import HoursCore

/// Hour of day × weekday, work minutes per hour on the monochrome `heat` ramp (intensity is not
/// meaning, so never category colour). Rows Mon…Sun, columns start at the day-start hour.
/// Hover a cell for its value; cells are plain shapes (168 of them), no chart machinery.
struct WeekHeatmap: View {
    let data: WeekData
    static let cellHeight: CGFloat = 24
    static let labelWidth: CGFloat = 52

    var body: some View {
        let heat = data.heat
        let dates = data.dates
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Hours of day").textRole(.heading)
                Spacer()
                legend
            }
            VStack(spacing: Theme.Space.xxs + 1) {
                ForEach(dates.indices, id: \.self) { r in
                    let d = dates[r]
                    HStack(spacing: Theme.Space.xxs + 1) {
                        Text("\(d.rangeShortLabel.prefix(3)) \(d.day)")
                            .textRole(.label, data.isFuture(d) ? Theme.inkDisabled : Theme.inkTertiary)
                            .frame(width: Self.labelWidth, alignment: .leading)
                        ForEach(0..<24, id: \.self) { c in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Theme.heat[WeekData.heatLevel(heat[r][c])])
                                .opacity(data.isFuture(d) ? 0.5 : 1)
                                .frame(maxWidth: .infinity)
                                .frame(height: Self.cellHeight)
                                .help(tip(d, c, heat[r][c]))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(rowSummary(d, heat[r]))
                }
                hourAxis
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .hoursCard()
    }

    /// Clock-hour labels every 4 h, under their columns.
    private var hourAxis: some View {
        HStack(spacing: Theme.Space.xxs + 1) {
            Color.clear.frame(width: Self.labelWidth, height: 1)
            ForEach(0..<24, id: \.self) { c in
                Text(c % 4 == 0 ? String(format: "%02d", hour(c)) : " ")
                    .font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    /// `0 ▢▢▢▢▢▢ 60m per hour`.
    private var legend: some View {
        HStack(spacing: Theme.Space.xs) {
            Text("0").textRole(.label, Theme.inkTertiary)
            ForEach(Theme.heat.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Theme.heat[i]).frame(width: 12, height: 10)
            }
            Text("60m work / hour").textRole(.label, Theme.inkTertiary)
        }
        .accessibilityHidden(true)
    }

    private func hour(_ c: Int) -> Int { (data.dayStartHour + c) % 24 }

    private func tip(_ d: LocalDate, _ c: Int, _ ms: Int64) -> String {
        let span = String(format: "%02d:00–%02d:00", hour(c), (hour(c) + 1) % 24)
        return "\(d.rangeShortLabel) \(span) · \(ms > 0 ? Fmt.duration(ms: ms) : "no") work"
    }

    private func rowSummary(_ d: LocalDate, _ row: [Int64]) -> String {
        let active = row.filter { $0 > 0 }.count
        guard active > 0, let peak = row.indices.max(by: { row[$0] < row[$1] }) else { return "\(d.rangeShortLabel): no work" }
        return "\(d.rangeShortLabel): work in \(active) hours, busiest \(String(format: "%02d:00", hour(peak)))"
    }
}
