import SwiftUI
import HoursCore

/// Group-by control + sortable breakdown table. Clicking a row (or Return / double-click, or
/// "Show details" in its context menu) opens the row's detail sheet; dismissing clears the selection.
// ponytail: no chevron/disclosure column — each Table cell is a hosting view and the 31-day
// render budget (< 100 ms, debug) has no room for a ninth; selection carries the affordance.
struct RangeTableCard: View {
    let data: RangeData
    @Binding var group: RangeGroup
    @Binding var detail: RangeRow?
    @State private var sortOrder = [KeyPathComparator(\RangeRow.trackedMs, order: .reverse)]
    @State private var selection: RangeKey?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = data.rows(group).sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text("Breakdown").textRole(.heading)
                RangeSegmented(options: RangeGroup.allCases, selection: $group) { $0.rawValue }
                Spacer()
                Text("\(rows.count) \(rows.count == 1 ? "row" : "rows") · Total \(Fmt.duration(ms: data.metrics.trackedMs)) tracked")
                    .textRole(.label, Theme.inkTertiary)
            }
            // Keyed by group in a ZStack: switching group-by crossfades the whole table rather than shuffling rows.
            ZStack {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn(group.rawValue, value: \.name) { r in
                        HStack(spacing: Theme.Space.s) {
                            if r.isCategory { RangeMark(slot: r.slot) }
                            Text(r.name).textRole(.body, r.id == rows.first?.id ? Theme.ink : Theme.inkSecondary).lineLimit(1)
                        }
                    }
                    .width(min: 180, ideal: 260)
                    TableColumn("Tracked", value: \.trackedMs) { r in
                        Text(Fmt.duration(ms: r.trackedMs)).textRole(.bodyEmph).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 72, ideal: 84)
                    TableColumn(group == .project ? "Billable" : "Work", value: \.workMs) { r in
                        Text(r.workMs > 0 ? Fmt.duration(ms: r.workMs) : "–")
                            .textRole(.body, r.workMs > 0 ? Theme.ink : Theme.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 72, ideal: 84)
                    TableColumn("Share", value: \.share) { r in
                        HStack(spacing: Theme.Space.s) {
                            RangeShareBar(fraction: r.share).frame(width: 56)
                            Text(Fmt.percent(r.share)).textRole(.label, Theme.inkSecondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    .width(min: 100, ideal: 104)
                    TableColumn("Days", value: \.activeDays) { r in
                        Text("\(r.activeDays)").textRole(.body, Theme.inkSecondary).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 40, ideal: 48)
                    TableColumn("Avg / day", value: \.avgPerActiveDayMs) { r in
                        Text(Fmt.duration(ms: r.avgPerActiveDayMs)).textRole(.body, Theme.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 70, ideal: 80)
                    TableColumn("Per day") { r in
                        RangeDayStrip(values: r.daily, maxValue: Double(r.daily.max() ?? 0), slot: r.isCategory ? r.slot : nil, monochrome: !r.isCategory)
                            .frame(height: 16)
                    }
                    .width(min: 120, ideal: 170)
                }
                .frame(height: Self.tableHeight(rows: rows.count))
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: RangeKey.self) { keys in
                    if let k = keys.first, let r = rows.first(where: { $0.id == k }) {
                        Button("Show details") { detail = r }
                    }
                } primaryAction: { keys in
                    if let k = keys.first { detail = rows.first { $0.id == k } }
                }
                .id(group)
                .transition(.opacity)
            }
            .animation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion), value: group)
            .onChange(of: selection) { _, key in
                if let key, let r = rows.first(where: { $0.id == key }) { detail = r }
            }
            .onChange(of: detail) { _, d in if d == nil { selection = nil } }
            .onChange(of: group) { selection = nil }
        }
        .hoursCard()
    }

    /// The table lives in the Range ScrollView, so it gets an explicit height: header + its rows,
    /// at least 3 rows tall.
    // ponytail: beyond 20 rows (long app/site lists) the table scrolls inside the page.
    static func tableHeight(rows: Int) -> CGFloat { 32 + CGFloat(min(max(rows, 3), 20)) * 26 }
}

/// Micro per-day columns for one row: bar height ∝ time, scaled to the row's own peak (shape, not size —
/// the Tracked column carries size).
/// Category rows use their mark colour; others are ink. Empty days show a hairline tick.
struct RangeDayStrip: View {
    let values: [Int64]
    let maxValue: Double
    var slot: Int?
    var monochrome = true

    var body: some View {
        Canvas { ctx, size in
            guard !values.isEmpty, maxValue > 0 else { return }
            let step = size.width / CGFloat(values.count)
            let w = max(1, step - 2)
            let fill: GraphicsContext.Shading = monochrome ? .style(Theme.inkSecondary) : .style(Theme.Palette.swatch(slot: slot))
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * step + (step - w) / 2
                if v <= 0 {
                    ctx.fill(Path(CGRect(x: x, y: size.height - 1, width: w, height: 1)), with: .style(Theme.hairline))
                    continue
                }
                let h = max(2, size.height * CGFloat(Double(v) / maxValue))
                ctx.fill(Path(roundedRect: CGRect(x: x, y: size.height - h, width: w, height: h), cornerRadius: 1), with: fill)
            }
        }
        .accessibilityHidden(true)
    }
}
