import SwiftUI
import HoursCore

/// Billable by project (the invoice lines), with `±` where edits moved a line, then the
/// unassigned-work line and tracker gaps. Gaps are never hidden: they are the proof caveat.
struct RangeBillableCard: View {
    let data: RangeData

    var body: some View {
        let lines = data.billableByProject
        let top = max(lines.first?.ms ?? 1, 1)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Billable by project").textRole(.heading)
                Spacer()
                Text("\(ExportPeriodData.hours(data.invoiceHundredths)) h").textRole(.bodyEmph)
                    .help("Invoice total; \(Fmt.duration(ms: data.metrics.billableMs)) exact")
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(lines.prefix(6).indices, id: \.self) { i in
                    let l = lines[i]
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        HStack(spacing: Theme.Space.s) {
                            Text(l.name).textRole(.body, i == 0 ? Theme.ink : Theme.inkSecondary).lineLimit(1)
                            if l.ms != l.rawMs { RangeEditedMark(deltaMs: l.ms - l.rawMs) }
                            Spacer(minLength: Theme.Space.s)
                            Text("\(ExportPeriodData.hours(data.invoiceHundredths(project: l.id))) h").textRole(.body)
                                .help("\(Fmt.duration(ms: l.ms)) exact")
                        }
                        RangeShareBar(fraction: Double(l.ms) / Double(top), fill: i == 0 ? Theme.ink : Theme.inkSecondary)
                    }
                }
                if lines.count > 6 {
                    Text("+ \(lines.count - 6) more in Project breakdown").textRole(.label, Theme.inkTertiary)
                }
                if lines.isEmpty {
                    Text("No project-tagged work in this period.").textRole(.body, Theme.inkSecondary)
                }
            }
            Divider().overlay(Theme.hairline)
            HStack {
                Text("Unassigned work").textRole(.body, Theme.inkSecondary)
                Spacer()
                Text(Fmt.duration(ms: data.metrics.unassignedWorkMs)).textRole(.body, Theme.inkSecondary)
            }
            gaps
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .hoursCard()
    }

    @ViewBuilder private var gaps: some View {
        let days = data.gapDays
        if days.isEmpty {
            HStack(spacing: Theme.Space.s) {
                Circle().fill(Theme.StateLayer.live).frame(width: 6, height: 6)
                Text("No tracker gaps in this period").textRole(.label, Theme.inkTertiary)
            }
        } else {
            let total = days.reduce(0) { $0 + $1.gapMs }
            let n = days.reduce(0) { $0 + $1.gaps.count }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.s) {
                    Circle().fill(Theme.StateLayer.warn).frame(width: 6, height: 6)
                    Text("\(n) tracker \(n == 1 ? "gap" : "gaps") · \(Fmt.duration(ms: total)) untracked")
                        .textRole(.bodyEmph)
                }
                ForEach(days.prefix(3), id: \.date) { d in
                    Text("\(d.date.rangeShortLabel)  " + d.gaps.map {
                        "\(Fmt.clock(ms: $0.lowerBound, timeZone: data.timeZone))–\(Fmt.clock(ms: $0.upperBound, timeZone: data.timeZone))"
                    }.joined(separator: ", "))
                    .textRole(.mono, Theme.inkSecondary)
                    .padding(.leading, Theme.Space.s + 6)
                }
                if days.count > 3 {
                    Text("+ \(days.count - 3) more days").textRole(.label, Theme.inkTertiary).padding(.leading, Theme.Space.s + 6)
                }
            }
        }
    }
}
