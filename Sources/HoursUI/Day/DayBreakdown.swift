import SwiftUI
import Charts
import HoursCore

/// The four detail panels under the timeline.
struct DayBreakdown: View {
    let data: DayData

    var body: some View {
        // 4 across from ~1130 pt of content width, else 2 × 2, else stacked.
        ColumnsLayout(minColumnWidth: 270, counts: [4, 2, 1]) {
            ForEach(DayBreakdownSection.allCases, id: \.self) { s in
                DayPanel(title: s.title, trailing: s.trailing(data)) { DayBreakdownList(data: data, section: s) }
            }
        }
    }
}

/// The breakdown sections, shown as the timeline's cards and, compact, in the Blocks side panel.
enum DayBreakdownSection: CaseIterable, Hashable {
    case categories, projects, apps, sessions

    var title: String {
        switch self {
        case .categories: "Categories"
        case .projects: "Projects"
        case .apps: "Apps & sites"
        case .sessions: "Sessions"
        }
    }

    func trailing(_ data: DayData) -> String? {
        switch self {
        case .categories: Fmt.duration(ms: data.metrics.trackedMs)
        case .projects: "Billable \(Fmt.duration(ms: data.metrics.billableMs))"
        case .apps, .sessions: nil
        }
    }
}

/// One section's contents. Full: the cards' fixed row limits. `compact` (the Blocks side panel):
/// at most `compactRows` per list, the rest behind a "+ N more" disclosure.
struct DayBreakdownList: View {
    let data: DayData
    let section: DayBreakdownSection
    var compact = false
    @State private var expanded = false

    static let compactRows = 5

    var body: some View {
        switch section {
        case .categories:
            DayCategoryChart(data: data, legendLimit: compact ? Self.compactRows : nil, expanded: $expanded)
        case .projects:
            let rows = DayRows.projects(data)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                DayBarList(rows: Array(rows.prefix(limit(6))), empty: "No project time", dots: false)
                more(rows.count - Self.compactRows)
            }
        case .apps:
            let apps = DayRows.apps(data, limit: limit(4)), hosts = DayRows.hosts(data, limit: limit(3, compact: Self.hostRows))
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                DayBarList(rows: apps, empty: "No apps")
                if !hosts.isEmpty {
                    Text("Sites").textRole(.micro)
                    DayBarList(rows: hosts, empty: "", mono: true)
                }
                if compact {
                    more(max(0, data.metrics.byApp.count - Self.compactRows)
                         + max(0, DayRows.hosts(data, limit: .max).count - Self.hostRows))
                }
            }
        case .sessions:
            DaySessionList(data: data, expanded: compact ? $expanded : nil)
        }
    }

    static let hostRows = 3

    /// Rows to show: the card's fixed `full`, else `compact` (all once expanded).
    private func limit(_ full: Int, compact rows: Int = compactRows) -> Int {
        compact ? (expanded ? .max : rows) : full
    }

    @ViewBuilder private func more(_ hidden: Int) -> some View {
        if compact { DayMoreToggle(hidden: hidden, expanded: $expanded) }
    }
}

/// "+ 3 more" / "Show less" under a compact list; nothing when the list fits.
struct DayMoreToggle: View {
    let hidden: Int
    @Binding var expanded: Bool

    var body: some View {
        if hidden > 0 {
            Button { expanded.toggle() } label: {
                HStack(spacing: Theme.Space.xs) {
                    Text(expanded ? "Show less" : "+ \(hidden) more")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Show fewer rows" : "Show all rows")
        }
    }
}

/// Card with a heading row; contents top-aligned, cards in a row share their height.
struct DayPanel<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).textRole(.heading)
                Spacer(minLength: Theme.Space.s)
                if let trailing { Text(trailing).font(TextRole.label.font).foregroundStyle(Theme.inkTertiary) }
            }
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hoursCard(padding: Theme.Space.l, radius: Theme.Radius.panel)
    }
}

/// Category share: one stacked Swift Charts bar (category colours, 1 pt gaps), then the ranked
/// legend with ink numbers — colour on the marks, never on the figures.
struct DayCategoryChart: View {
    let data: DayData
    /// Compact: legend rows shown until `expanded` (the bar always has them all).
    var legendLimit: Int? = nil
    var expanded: Binding<Bool> = .constant(true)

    struct Segment: Identifiable {
        var id: String { name }
        var name: String, slot: Int?, lo: Double, hi: Double
    }

    var body: some View {
        let rows = Array(DayRows.categories(data).prefix(8))
        let total = Double(max(rows.reduce(0) { $0 + $1.ms }, 1))
        let gap = 0.004   // ≈ 1 pt at panel width
        var acc = 0.0
        let segments = rows.map { r -> Segment in
            let lo = acc
            acc += Double(r.ms) / total
            return Segment(name: r.name, slot: r.slot, lo: lo, hi: max(lo + 0.0015, acc - gap))
        }
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            Chart(segments) { s in
                BarMark(xStart: .value("Start", s.lo), xEnd: .value("End", s.hi), y: .value("Day", "day"), height: .fixed(12))
                    .foregroundStyle(by: .value("Category", s.name))
            }
            .categoryScale(rows.map { ($0.name, $0.slot) })
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: 0...1)
            .chartPlotStyle { $0.background(.clear) }
            .clipShape(RoundedRectangle(cornerRadius: ChartStyle.barRadius, style: .continuous))
            .frame(height: 12)
            .accessibilityLabel("Time by category")
            .accessibilityValue(rows.prefix(3).map { "\($0.name) \(Fmt.percent(Double($0.ms) / total))" }.joined(separator: ", "))

            let legend = legendLimit.map { expanded.wrappedValue ? rows : Array(rows.prefix($0)) } ?? rows
            VStack(alignment: .leading, spacing: Theme.Space.s - 1) {
                ForEach(Array(legend.enumerated()), id: \.element.id) { i, r in
                    HStack(spacing: Theme.Space.s - 2) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Theme.Palette.swatch(slot: r.slot)).frame(width: 6, height: 6)
                        Text(r.name).font(i == 0 ? TextRole.bodyEmph.font : TextRole.body.font)
                            .foregroundStyle(i == 0 ? Theme.ink : Theme.inkSecondary).lineLimit(1)
                        Spacer(minLength: Theme.Space.s)
                        Text(Fmt.percent(Double(r.ms) / total)).font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
                        Text(Fmt.duration(ms: r.ms)).font(TextRole.label.font).foregroundStyle(Theme.ink)
                            .frame(minWidth: 46, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let legendLimit { DayMoreToggle(hidden: rows.count - legendLimit, expanded: expanded) }
            }

            if let unc = data.metrics.byCategory.first(where: { $0.key == nil }), unc.trackedMs >= 60_000 {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.inkSecondary)
                    Text("\(Fmt.duration(ms: unc.trackedMs)) uncategorized — not work until a rule covers it.")
                        .foregroundStyle(Theme.inkTertiary)
                }
                .font(TextRole.label.font)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Monochrome ranked list: name, hairline bar, time. Top row full ink, the rest secondary.
struct DayBarList: View {
    let rows: [DayRow]
    let empty: String
    var mono = false
    /// Category-colour mark per row (apps/sites); off for projects, which aren't a colour layer.
    var dots = true

    var body: some View {
        if rows.isEmpty {
            Text(empty).font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
        } else {
            let maxMs = Double(rows.map(\.ms).max() ?? 1)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: Theme.Space.s - 2) {
                            if dots {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(Theme.Palette.swatch(slot: row.slot)).frame(width: 6, height: 6)
                            }
                            Text(row.name)
                                .font(mono ? TextRole.label.font : (i == 0 ? TextRole.bodyEmph.font : TextRole.body.font))
                                .foregroundStyle(row.muted ? Theme.inkTertiary : (i == 0 ? Theme.ink : Theme.inkSecondary))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: Theme.Space.s)
                            Text(Fmt.duration(ms: row.ms))
                                .font(TextRole.label.font)
                                .foregroundStyle(row.muted ? Theme.inkTertiary : Theme.ink)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.surfaceRaised)
                                Capsule().fill(row.muted ? Theme.inkDisabled : (i == 0 ? Theme.ink : Theme.inkTertiary))
                                    .frame(width: max(2, g.size.width * Double(row.ms) / maxMs))
                            }
                        }
                        .frame(height: 2)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Focus sessions, meetings and breaks, in time order within each group.
struct DaySessionList: View {
    let data: DayData
    /// Compact (the Blocks side panel): fewer rows per group, one "+ N more" for all of them.
    var expanded: Binding<Bool>? = nil
    static let maxFocus = 5, maxOther = 3
    static let compactFocus = 3, compactOther = 2

    private var maxF: Int { expanded.map { $0.wrappedValue ? .max : Self.compactFocus } ?? Self.maxFocus }
    private var maxO: Int { expanded.map { $0.wrappedValue ? .max : Self.compactOther } ?? Self.maxOther }

    var body: some View {
        let m = data.metrics
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            group("Focus", empty: "No session ≥ 15 min", isEmpty: m.focusSessions.isEmpty) {
                ForEach(m.focusSessions.prefix(maxF), id: \.startMs) { s in
                    row(s.startMs, s.endMs, ms: s.wallMs) { DayQualityMeter(share: Double(s.activeMs) / Double(max(s.wallMs, 1))) }
                }
                more(m.focusSessions.count - maxF, "session")
            }
            if !m.meetings.isEmpty {
                group("Meetings", empty: "", isEmpty: false) {
                    ForEach(m.meetings.prefix(maxO), id: \.startMs) { s in
                        row(s.startMs, s.endMs, ms: s.wallMs) { glyph("video") }
                    }
                    more(m.meetings.count - maxO, "meeting")
                }
            }
            group("Breaks", empty: "No breaks ≥ 5 min", isEmpty: m.breaks.isEmpty) {
                ForEach(m.breaks.prefix(maxO), id: \.startMs) { b in
                    let away = data.breakKind(b) == .away
                    row(b.startMs, b.endMs, ms: b.durationMs, label: away ? "Away" : "Not tracking") {
                        glyph(away ? "cup.and.saucer" : "pause.circle")
                    }
                }
                more(m.breaks.count - maxO, "break")
            }
            if let expanded {
                let hidden = max(0, m.focusSessions.count - Self.compactFocus) + max(0, m.meetings.count - Self.compactOther)
                    + max(0, m.breaks.count - Self.compactOther)
                DayMoreToggle(hidden: hidden, expanded: expanded)
            }
        }
    }

    private func group<C: View>(_ title: String, empty: String, isEmpty: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            Text(title).textRole(.micro)
            if isEmpty {
                Text(empty).font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
            } else {
                content()
            }
        }
    }

    @ViewBuilder private func more(_ n: Int, _ noun: String) -> some View {
        if n > 0, expanded == nil {
            Text("+ \(n) more \(noun)\(n == 1 ? "" : "s")").font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 10)).foregroundStyle(Theme.inkTertiary)
    }

    private func row<G: View>(_ a: Int64, _ b: Int64, ms: Int64, label: String? = nil, @ViewBuilder glyph: () -> G) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("\(Fmt.clock(ms: a, timeZone: data.timeZone))–\(Fmt.clock(ms: b, timeZone: data.timeZone))")
                .font(TextRole.mono.font).foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: Theme.Space.xs)
            if let label {
                Text(label).font(TextRole.label.font).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
            glyph()
            Text(Fmt.duration(ms: ms)).font(TextRole.label.font).foregroundStyle(Theme.ink)
                .frame(minWidth: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Five ink pips for a session's productive share (≥ 75 % by definition, so 4–5 lit is typical).
struct DayQualityMeter: View {
    let share: Double

    var body: some View {
        let lit = Int((share * 5).rounded())
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(i < lit ? Theme.ink : Theme.surfaceRaised).frame(width: 3, height: 8)
            }
        }
        .help("\(Fmt.percent(share)) productive")
        .accessibilityLabel("\(Fmt.percent(share)) productive")
    }
}
