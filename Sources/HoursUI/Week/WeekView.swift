import SwiftUI
import HoursCore

/// The week at a glance: work vs goal, per-day stacked bars with the daily goal rule, an
/// hour-of-day × weekday heatmap and top apps. Pure over `WeekData` — the shell loads the week
/// and owns the date. `onSelectDay` opens a day in the Day view; `onNavigate` (optional) asks the
/// shell to show the week containing a date — without it the header has no step buttons.
public struct WeekView: View {
    let data: WeekData
    let onSelectDay: (LocalDate) -> Void
    let onNavigate: ((LocalDate) -> Void)?
    /// Clicking a block in Blocks mode. nil = `route.apply`: set the Day view's mode, then `onSelectDay`.
    var onOpenBlock: ((WeekBlockRoute) -> Void)?
    /// Pins the mode (renders, previews); nil = the stored `week.mode`.
    var pinnedMode: WeekMode?

    @AppStorage(WeekMode.storageKey) private var storedMode: WeekMode = .bars
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(data: WeekData, onSelectDay: @escaping (LocalDate) -> Void, onNavigate: ((LocalDate) -> Void)? = nil) {
        self.data = data
        self.onSelectDay = onSelectDay
        self.onNavigate = onNavigate
    }

    init(data: WeekData, onSelectDay: @escaping (LocalDate) -> Void, onNavigate: ((LocalDate) -> Void)? = nil,
         onOpenBlock: ((WeekBlockRoute) -> Void)? = nil, pinnedMode: WeekMode?) {
        self.init(data: data, onSelectDay: onSelectDay, onNavigate: onNavigate)
        self.onOpenBlock = onOpenBlock
        self.pinnedMode = pinnedMode
    }

    private var mode: Binding<WeekMode> {
        Binding(get: { pinnedMode ?? storedMode }, set: { storedMode = $0 })
    }

    private func open(_ route: WeekBlockRoute) {
        if let onOpenBlock { onOpenBlock(route) } else { route.apply(onSelectDay: onSelectDay) }
    }

    public var body: some View {
        Group {
            if data.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    WeekHeader(data: data, onNavigate: onNavigate, mode: mode)
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .hoursCard(padding: Theme.Space.l, radius: Theme.Radius.panel)
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, Theme.Space.l)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        WeekHeader(data: data, onNavigate: onNavigate, mode: mode)
                        if mode.wrappedValue == .blocks {
                            WeekBlocksView(data: data, onOpen: open)
                        } else {
                            WeekHeadline(data: data)
                                // Totals roll on a week change only, not on the minute refetch; down when going back.
                                .environment(\.hoursNumericValue, DayHeadline.rollValue(data.monday))
                                .animation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion), value: data.monday)
                            WeekChart(data: data, onSelectDay: onSelectDay)
                            SplitLayout(trailingWidth: 380, leadingMinWidth: 520) {
                                WeekHeatmap(data: data)
                                WeekAppsPanel(data: data)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.vertical, Theme.Space.l)
                }
                .scrollEdgeEffectStyle(.hard, for: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
    }

    private var emptyState: EmptyState {
        if data.monday > data.today {
            return EmptyState(symbol: "calendar", title: "This week hasn't happened yet", detail: "Nothing to show for a future week.")
        }
        let back = onNavigate.map { nav in EmptyState.Action("Previous week") { nav(data.monday.adding(days: -7)) } }
        return EmptyState(symbol: "calendar", title: "No data this week",
                          detail: "Nothing was recorded in week \(data.weekNumber). If you worked, the tracker was off.", action: back)
    }
}

// MARK: - Header

/// `WEEK 40` / `28 Sep – 4 Oct 2026` + `‹ This week ›`.
struct WeekHeader: View {
    let data: WeekData
    let onNavigate: ((LocalDate) -> Void)?
    var mode: Binding<WeekMode>? = nil

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(data.isCurrentWeek ? "This week · Week \(data.weekNumber)" : "Week \(data.weekNumber)").textRole(.micro)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(title).textRole(.title)
                    Text(String(data.sunday.year)).font(TextRole.title.font.weight(.regular)).foregroundStyle(Theme.inkTertiary)
                }
            }
            Spacer(minLength: Theme.Space.l)
            if let mode { WeekModeToggle(mode: mode) }
            if let onNavigate { nav(onNavigate) }
        }
    }

    /// `28 Sep – 4 Oct`, `5–11 Oct`.
    private var title: String {
        let a = data.monday, z = data.sunday
        return a.month == z.month ? "\(a.day)–\(z.day) \(z.monthName)" : "\(a.day) \(a.monthName) – \(z.day) \(z.monthName)"
    }

    private func nav(_ go: @escaping (LocalDate) -> Void) -> some View {
        HStack(spacing: 0) {
            DayIconButton(symbol: "chevron.left", help: "Previous week") { go(data.monday.adding(days: -7)) }
            Button { go(data.today) } label: {
                Text("This week").font(TextRole.label.font)
                    .foregroundStyle(data.isCurrentWeek ? Theme.inkTertiary : Theme.ink)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(data.isCurrentWeek)
            DayIconButton(symbol: "chevron.right", help: "Next week", disabled: data.isCurrentWeek) {
                go(data.monday.adding(days: 7))
            }
        }
        .padding(.horizontal, Theme.Space.xxs)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
    }
}

/// `Bars | Blocks` in the Week header: the Day view's `Timeline | Blocks` segmented look.
struct WeekModeToggle: View {
    @Binding var mode: WeekMode

    var body: some View {
        HStack(spacing: Theme.Space.xxs) {
            ForEach(WeekMode.allCases, id: \.self) { m in
                Button { mode = m } label: {
                    Text(m.title)
                        .font(TextRole.label.font)
                        .foregroundStyle(mode == m ? Theme.ink : Theme.inkTertiary)
                        .padding(.horizontal, Theme.Space.s + 2)
                        .frame(height: 22)
                        .background(mode == m ? Theme.surfaceRaised : Theme.surface,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip - 1, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(m == .bars ? "Work per day, heatmap and top apps" : "Each day's continuous work blocks")
                .accessibilityAddTraits(mode == m ? .isSelected : [])
            }
        }
        .padding(Theme.Space.xxs)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Week layout")
    }
}

// MARK: - Headline: hero work vs goal + four tiles

struct WeekHeadline: View {
    let data: WeekData

    var body: some View {
        let m = data.metrics
        let past = data.dates.filter { !data.isFuture($0) }
        HeadlineLayout {
            hero
            StatTile("Focus", ms: m.focusMs,
                     comparator: m.focusRatio.map { "\(Fmt.percent($0)) of work · \(count(m.focusSessionCount, "session"))" }
                        ?? "No focus sessions",
                     spark: past.count > 1 ? past.map { Double(data.dayMetrics($0)?.focusMs ?? 0) } : nil)
            StatTile("Meetings", ms: m.meetingMs, comparator: m.meetingCount == 0 ? "None" : count(m.meetingCount, "meeting"))
            StatTile("Billable", ms: m.billableMs,
                     comparator: m.workMs > 0 ? "\(Fmt.percent(Double(m.billableMs) / Double(m.workMs))) of work" : "No work")
            streakTile
        }
    }

    @ViewBuilder private var streakTile: some View {
        if data.goal != nil {
            let g = data.goalDays
            StatTile("Streak", value: "\(data.streak)", unit: data.streak == 1 ? " day" : " days",
                     comparator: "Goal met \(g.met) of \(g.of) day\(g.of == 1 ? "" : "s")\(data.isCurrentWeek ? " so far" : "")")
        } else {
            StatTile("Streak", value: "–", comparator: "No daily goal set")
        }
    }

    private var hero: some View {
        let m = data.metrics
        let target = data.isCurrentWeek ? data.paceTargetMs : data.weeklyTargetMs
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .lastTextBaseline, spacing: Theme.Space.m) {
                HeroNumber(ms: m.workMs, caption: data.isCurrentWeek ? "Work so far" : "Work")
                if let delta = data.workDeltaMs {
                    Text("± \(RangeEditedMark.signed(delta))")
                        .font(TextRole.label.font).foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, Theme.Space.s - 2)
                        .frame(height: 20)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                        .help("Adjusted \(RangeEditedMark.signed(delta)) vs raw tracking (edits applied)")
                        .accessibilityLabel("Adjusted by edits, \(RangeEditedMark.signed(delta)) versus raw")
                }
            }
            if target > 0 {
                let p = Double(m.workMs) / Double(target)
                HStack(spacing: Theme.Space.s) {
                    ProgressRing(progress: p, size: .small)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(goalLine(p: p, target: target)).font(TextRole.bodyEmph.font).foregroundStyle(Theme.ink)
                        Text(p >= 1 ? "+\(Fmt.duration(ms: m.workMs - target)) over" : "\(Fmt.duration(ms: target - m.workMs)) to go")
                            .font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
                    }
                }
            }
            Text(footer).font(TextRole.label.font).foregroundStyle(Theme.inkTertiary).lineLimit(1)
        }
        .padding(.top, Theme.Space.xs)
    }

    private func goalLine(p: Double, target: Int64) -> String {
        if data.isCurrentWeek && target < data.weeklyTargetMs {
            return p >= 1 ? "Ahead of pace" : "\(Fmt.percent(p)) of \(Fmt.duration(ms: target)) pace"
        }
        return p >= 1 ? "Weekly goal met" : "\(Fmt.percent(p)) of \(Fmt.duration(ms: target)) goal"
    }

    private var footer: String {
        let worked = data.metrics.days.filter { $0.metrics.workMs > 0 }.count
        let avg = worked > 0 ? "Avg \(Fmt.duration(ms: data.metrics.workMs / Int64(worked)))/day" : "No workdays"
        let best = data.bestDay.map { " · Best \($0.rangeShortLabel.prefix(3))" } ?? ""
        return "\(avg)\(best) · Tracked \(Fmt.duration(ms: data.metrics.trackedMs))"
    }

    private func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

// MARK: - Top apps & sites

struct WeekAppsPanel: View {
    let data: WeekData

    var body: some View {
        let m = data.metrics
        DayPanel(title: "Top apps", trailing: Fmt.duration(ms: m.trackedMs)) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                DayBarList(rows: m.byApp.prefix(4).map { DayRow(id: "a" + $0.key.id, name: $0.key.name, ms: $0.trackedMs) },
                           empty: "No apps", dots: false)
                let hosts = m.byHost.compactMap { r in r.key.map { DayRow(id: "h" + $0, name: $0, ms: r.trackedMs) } }.prefix(3)
                if !hosts.isEmpty {
                    Text("Sites").textRole(.micro)
                    DayBarList(rows: Array(hosts), empty: "", mono: true, dots: false)
                }
            }
        }
    }
}

#Preview("Past week") { WeekView(data: .fixture(), onSelectDay: { _ in }, onNavigate: { _ in }).frame(width: 1280, height: 860) }
#Preview("Current week") {
    WeekView(data: .fixture(week: LocalDate(year: 2026, month: 10, day: 1), today: LocalDate(year: 2026, month: 10, day: 1)),
             onSelectDay: { _ in }, onNavigate: { _ in }).frame(width: 1280, height: 860)
}
#Preview("Blocks") {
    WeekView(data: .fixture(week: LocalDate(year: 2026, month: 10, day: 1), today: LocalDate(year: 2026, month: 10, day: 1), now: (15, 10)),
             onSelectDay: { _ in }, onNavigate: { _ in }, pinnedMode: .blocks).frame(width: 1280, height: 860)
}
#Preview("No goal") { WeekView(data: .fixture(goal: nil), onSelectDay: { _ in }).frame(width: 1280, height: 860) }
#Preview("Empty") { WeekView(data: .fixture(empty: true), onSelectDay: { _ in }, onNavigate: { _ in }).frame(width: 1280, height: 860) }
