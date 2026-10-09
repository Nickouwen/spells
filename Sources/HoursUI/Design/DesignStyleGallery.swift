import SwiftUI
import Charts

/// Every token and component with fixture data. Renders in whichever colour scheme the
/// environment carries — the render test writes it in light and dark. No ScrollView inside, so
/// `ImageRenderer` sees the whole thing; wrap it in one to browse.
public struct StyleGallery: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            header
            section("Surfaces & ink") { swatchRow(Theme.backgrounds + [("hairline", Theme.hairline)] + Theme.textTokens + [("inkDisabled", Theme.inkDisabled)]) }
            section("State layer") { swatchRow(Theme.StateLayer.all + [("warn", Theme.StateLayer.warn)]) }
            section("Category layer — slot 0…9 + Uncategorized") {
                swatchRow(Theme.Palette.slots.enumerated().map { ("\($0.offset) \($0.element.name)", $0.element.swatch) }
                          + [("– Uncategorized", Theme.Palette.uncategorized)])
            }
            section("Heat ramp") { heatRamp }
            section("Type scale") { typeScale }
            section("Space · radius") { spaceAndRadius }
            section("Hero + tiles") { heroAndTiles }
            section("Rings · chips · health") { ringsChipsHealth }
            section("Timeline blocks") { timeline }
            section("Charts") { charts }
            section("Empty states") { emptyStates }
        }
        .padding(Theme.Space.gutter)
        .frame(width: 1180, alignment: .leading)
        .background(Theme.canvas)
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Hours — Style Gallery").textRole(.title)
            Text("Monochrome base. Colour only means something: category, state, tracker health.")
                .textRole(.body, Theme.inkSecondary)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title).textRole(.micro)
            content()
        }
    }

    @Environment(\.colorScheme) private var scheme

    private func swatchRow(_ items: [(name: String, swatch: Swatch)]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.m, alignment: .leading), count: 6),
                  alignment: .leading, spacing: Theme.Space.m) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: Theme.Space.s) {
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(items[i].swatch)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(items[i].name).textRole(.label).lineLimit(1)
                        Text(String(format: "#%06X", items[i].swatch.hex(scheme))).textRole(.mono, Theme.inkTertiary)
                    }
                }
            }
        }
    }

    private var heatRamp: some View {
        HStack(spacing: Theme.Space.xxs) {
            ForEach(Theme.heat.indices, id: \.self) { i in
                Rectangle().fill(Theme.heat[i]).frame(width: 40, height: 16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }

    private var typeScale: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(TextRole.allCases, id: \.self) { role in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l) {
                    Text(role.name).textRole(.mono, Theme.inkTertiary).frame(width: 96, alignment: .leading)
                    Text(role == .mono ? "08:12–09:40  a3f9c2e1" : "Deep work 6h 42m").textRole(role)
                }
            }
        }
        .hoursCard()
    }

    private var spaceAndRadius: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.xl) {
            ForEach([Theme.Space.xxs, Theme.Space.xs, Theme.Space.s, Theme.Space.m, Theme.Space.l,
                     Theme.Space.xl, Theme.Space.xxl, Theme.Space.huge], id: \.self) { v in
                VStack(spacing: Theme.Space.xs) {
                    Rectangle().fill(Theme.ink).frame(width: v, height: v)
                    Text("\(Int(v))").textRole(.mono, Theme.inkTertiary)
                }
            }
            Spacer(minLength: Theme.Space.xl)
            ForEach([("chip", Theme.Radius.chip), ("tile", Theme.Radius.tile), ("panel", Theme.Radius.panel)], id: \.0) { name, r in
                VStack(spacing: Theme.Space.xs) {
                    RoundedRectangle(cornerRadius: r, style: .continuous)
                        .strokeBorder(Theme.ink, lineWidth: Theme.Stroke.selection)
                        .frame(width: 48, height: 48)
                    Text("\(name) \(Int(r))").textRole(.mono, Theme.inkTertiary)
                }
            }
        }
    }

    private var heroAndTiles: some View {
        HStack(alignment: .top, spacing: Theme.Space.gridGap) {
            HeroNumber(ms: 24_120_000, caption: "Work today")
                .frame(width: 240, alignment: .leading)
            StatTile("Focus", ms: 13_380_000, comparator: "↑ 24m vs 7-day avg",
                     spark: [2.1, 3.4, 2.8, 4.0, 3.1, 3.9, 3.7])
            StatTile("Focus share", value: "62", unit: "%", comparator: "↓ 4 pts vs 7-day avg")
            StatTile("Meetings", ms: 2_700_000)
            StatTile("Switches", value: "11", unit: "/h", comparator: "↑ 2 vs 7-day avg")
        }
    }

    private var ringsChipsHealth: some View {
        HStack(alignment: .center, spacing: Theme.Space.xl) {
            ProgressRing(progress: 0.34, size: .small)
            ProgressRing(progress: 0.72, size: .medium, label: "72%")
            ProgressRing(progress: 0.84, size: .large, label: "84%")
            ProgressRing(progress: 1.0, size: .medium)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    CategoryChip(name: "Coding", slot: 0, isOn: true)
                    CategoryChip(name: "Communication", slot: 1)
                    CategoryChip(name: "Meetings", slot: 5)
                    CategoryChip(name: "Uncategorized", slot: nil)
                }
                HStack(spacing: Theme.Space.s) {
                    HealthPill(.tracking(sinceMs: 1_759_666_320_000), timeZone: Self.tz)
                    HealthPill(.stopped(atMs: 1_759_687_500_000), timeZone: Self.tz)
                    HealthPill(.permissionMissing)
                    HealthPill(.unknown)
                }
            }
        }
    }

    static let tz = TimeZone(identifier: "America/New_York")!

    /// Fixture lane: (slot, start, end) in minutes after 08:00; nil slot = idle.
    static let lane: [(slot: Int?, lo: CGFloat, hi: CGFloat, label: String)] = [
        (0, 0, 52, "Xcode — hours"), (6, 52, 58, ""), (0, 58, 130, "Cursor — operations-dashboard"),
        (nil, 130, 150, "Idle"), (5, 150, 180, "Zoom — standup"), (1, 180, 210, "Slack"),
        (3, 210, 214, ""), (2, 214, 260, "Obsidian"), (8, 260, 290, "YouTube"),
        (4, 290, 320, "Figma"), (7, 320, 345, "Notion"), (9, 345, 380, "Mail"), (nil, 380, 400, "Uncategorized"),
    ]

    private var timeline: some View {
        Canvas { ctx, size in
            let laneX: CGFloat = 16, laneY: CGFloat = 8, laneH: CGFloat = 44
            let scale = (size.width - laneX - 8) / 400
            for b in Self.lane {
                let rect = CGRect(x: laneX + b.lo * scale, y: laneY, width: (b.hi - b.lo) * scale - 1, height: laneH)
                if b.label == "Idle" {
                    TimelineBlockStyle.drawIdle(in: &ctx, rect: rect)
                } else {
                    let style = TimelineBlockStyle(slot: b.slot)
                    style.draw(in: &ctx, rect: rect)
                    if !b.label.isEmpty, rect.width > 40 {
                        ctx.draw(Text(b.label).role(.label, style.text),
                                 in: rect.insetBy(dx: TimelineBlockStyle.edgeWidth + 5, dy: 6))
                    }
                }
            }
            // A collapsed (< 14 pt) row: solid fills, no text.
            for (i, b) in Self.lane.enumerated() where i % 2 == 0 && b.label != "Idle" {
                TimelineBlockStyle(slot: b.slot).draw(in: &ctx, rect: CGRect(x: laneX + b.lo * scale, y: 64, width: (b.hi - b.lo) * scale - 1, height: 10))
            }
            // Focus-session bracket: rows 0…130 min drawn as a vertical lane sample.
            let v = CGRect(x: laneX + 8, y: 84, width: 240, height: 40)
            TimelineBlockStyle.drawFocusBracket(in: &ctx, rect: v)
            TimelineBlockStyle(slot: 0).draw(in: &ctx, rect: v)
            ctx.draw(Text("Focus session · 1h 52m").role(.label), in: v.insetBy(dx: 8, dy: 6))
            let notch = CGRect(x: v.maxX - TimelineBlockStyle.editedMarkSize - 4, y: v.minY + 4,
                               width: TimelineBlockStyle.editedMarkSize, height: TimelineBlockStyle.editedMarkSize)
            ctx.stroke(Path(ellipseIn: notch), with: .style(Theme.inkSecondary), lineWidth: 1)
        }
        .frame(height: 132)
        .hoursCard()
    }

    static let week: [(day: String, category: String, slot: Int, hours: Double)] = {
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri"]
        let mix: [(String, Int, [Double])] = [
            ("Coding", 0, [3.2, 4.1, 2.6, 4.8, 3.0]),
            ("Communication", 1, [1.1, 0.8, 1.4, 0.6, 1.2]),
            ("Meetings", 5, [0.5, 1.5, 1.0, 0.5, 2.0]),
            ("Writing", 2, [0.4, 0.2, 1.1, 0.3, 0.6]),
            ("Uncategorized", -1, [0.2, 0.3, 0.1, 0.4, 0.2]),
        ]
        return mix.flatMap { name, slot, hrs in days.indices.map { (days[$0], name, slot, hrs[$0]) } }
    }()

    static var legend: [(name: String, slot: Int?)] {
        [("Coding", 0), ("Communication", 1), ("Meetings", 5), ("Writing", 2), ("Uncategorized", nil)]
    }

    private var charts: some View {
        HStack(alignment: .top, spacing: Theme.Space.gridGap) {
            Chart(Self.week.indices, id: \.self) { i in
                let r = Self.week[i]
                BarMark(x: .value("Day", r.day), y: .value("Hours", r.hours))
                    .foregroundStyle(by: .value("Category", r.category))
                    .cornerRadius(ChartStyle.barRadius)
            }
            .hoursChartStyle()
            .categoryScale(Self.legend)
            .chartLegend(.hidden)
            .frame(height: 180)
            .hoursCard()

            Chart(Self.legend.indices, id: \.self) { i in
                let total = Self.week.filter { $0.category == Self.legend[i].name }.reduce(0) { $0 + $1.hours }
                SectorMark(angle: .value("Hours", total), innerRadius: .ratio(ChartStyle.donutInner),
                           angularInset: ChartStyle.donutAngularInset)
                    .foregroundStyle(by: .value("Category", Self.legend[i].name))
            }
            .categoryScale(Self.legend)
            .chartLegend(.hidden)
            .chartBackground { _ in
                HeroNumber.text(Fmt.durationParts(ms: Int64(Self.week.reduce(0) { $0 + $1.hours } * 3_600_000)), value: .metric, unit: .metricUnit)
            }
            .frame(width: 180, height: 180)
            .hoursCard()

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Self.legend.indices, id: \.self) { i in
                    let total = Self.week.filter { $0.category == Self.legend[i].name }.reduce(0) { $0 + $1.hours }
                    HStack(spacing: Theme.Space.s) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Theme.Palette.swatch(slot: Self.legend[i].slot)).frame(width: 8, height: 8)
                        Text(Self.legend[i].name).textRole(.body, i == 0 ? Theme.ink : Theme.inkSecondary)
                        Spacer()
                        Text(Fmt.duration(ms: Int64(total * 3_600_000))).textRole(.body)
                    }
                }
            }
            .frame(width: 260)
            .hoursCard()
        }
    }

    private var emptyStates: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.gridGap), count: 2),
                  spacing: Theme.Space.gridGap) {
            EmptyState.trackerNotRunning(start: .init("Start tracker") {}).hoursCard()
            EmptyState.permissionMissing(openSettings: .init("Open System Settings") {}).hoursCard()
            EmptyState.noData().hoursCard()
            EmptyState.filteredToNothing(clear: .init("Clear filters") {}).hoursCard()
        }
    }
}

#Preview("Gallery — light") {
    ScrollView { StyleGallery() }.environment(\.colorScheme, .light)
}

#Preview("Gallery — dark") {
    ScrollView { StyleGallery() }.environment(\.colorScheme, .dark)
}
