import SwiftUI
import HoursCore

extension EnvironmentValues {
    /// Opens the EOD standup for a day; set by the shell, nil hides the button.
    @Entry var openStandup: ((LocalDate) -> Void)? = nil
}

/// Date line + day navigation.
struct DayHeader: View {
    let data: DayData
    let onNavigate: (LocalDate) -> Void
    var mode: Binding<DayMode>?
    @Environment(\.openStandup) private var openStandup

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(eyebrow).textRole(.micro)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(title).textRole(.title)
                    Text(String(data.date.year)).font(TextRole.title.font.weight(.regular)).foregroundStyle(Theme.inkTertiary)
                }
            }
            Spacer(minLength: Theme.Space.l)
            status
            if let mode { DayModeToggle(mode: mode) }
            if let openStandup { eod(openStandup) }
            nav
        }
    }

    @ViewBuilder private var status: some View {
        if data.isToday, let through = data.trackedThroughMs {
            HStack(spacing: Theme.Space.xs + 2) {
                Circle().fill(data.liveSpan != nil ? Theme.StateLayer.live : Theme.inkDisabled).frame(width: 7, height: 7)
                Text("Tracked through \(Fmt.clock(ms: through, timeZone: data.timeZone))")
                    .font(TextRole.label.font).foregroundStyle(Theme.inkSecondary)
            }
        } else if let a = data.metrics.firstActivityMs, let b = data.metrics.lastActivityMs {
            Text("\(Fmt.clock(ms: a, timeZone: data.timeZone)) – \(Fmt.clock(ms: b, timeZone: data.timeZone))")
                .font(TextRole.label.font).foregroundStyle(Theme.inkSecondary)
                .help("First to last activity")
        }
    }

    /// Same chip as `nav` so the header controls read as one row.
    private func eod(_ open: @escaping (LocalDate) -> Void) -> some View {
        Button { open(data.date) } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "text.bubble").imageScale(.small)
                Text("EOD").font(TextRole.label.font)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.s + 2)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("End-of-day standup for this day")
        .padding(.horizontal, Theme.Space.xxs)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
    }

    private var nav: some View {
        HStack(spacing: 0) {
            DayIconButton(symbol: "chevron.left", help: "Previous day") { onNavigate(data.date.dayShift(-1)) }
            Button { onNavigate(Self.today(data.timeZone)) } label: {
                Text("Today").font(TextRole.label.font)
                    .foregroundStyle(data.isToday ? Theme.inkTertiary : Theme.ink)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(data.isToday)
            DayIconButton(symbol: "chevron.right", help: "Next day", disabled: data.isToday) { onNavigate(data.date.dayShift(1)) }
        }
        .padding(.horizontal, Theme.Space.xxs)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
    }

    static func today(_ tz: TimeZone) -> LocalDate {
        LocalDate.containing(ms: Int64(Date().timeIntervalSince1970 * 1000), in: tz)
    }

    private var calendarDate: Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = data.timeZone
        return cal.date(from: DateComponents(year: data.date.year, month: data.date.month, day: data.date.day, hour: 12))!
    }

    private var eyebrow: String {
        data.isToday ? "Today" : calendarDate.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "en_GB")))
    }

    private var title: String {
        let f = Date.FormatStyle(locale: Locale(identifier: "en_GB"), timeZone: data.timeZone)
        return data.isToday
            ? calendarDate.formatted(f.weekday(.wide).day().month(.wide))
            : calendarDate.formatted(f.day().month(.wide))
    }
}

/// Hero (work time) + goal + four tiles; `compact` (Blocks mode): the hero beside one row of small stats.
struct DayHeadline: View {
    let data: DayData
    var compact = false
    @Environment(\.hoursNumericValue) private var numericValue

    var body: some View {
        if compact { compactBody } else { tiles }
    }

    private var tiles: some View {
        let m = data.metrics
        return HeadlineLayout {
            hero
            StatTile("Focus", ms: m.focusMs,
                     comparator: m.focusRatio.map { "\(Fmt.percent($0)) of work · \(count(m.focusSessions.count, "session"))" }
                        ?? "No focus sessions")
            StatTile("Meetings", ms: m.meetingMs, comparator: m.meetings.isEmpty ? "None" : count(m.meetings.count, "meeting"))
            StatTile("Breaks", ms: m.breakMs,
                     comparator: m.breaks.max(by: { $0.durationMs < $1.durationMs }).map {
                         "\(count(m.breaks.count, "break")) · longest \(Fmt.duration(ms: $0.durationMs))" } ?? "None")
            StatTile("Switches", value: m.switchesPerHour.map { String(format: "%.1f", $0) } ?? "–", unit: "/h",
                     comparator: "\(m.switches) context switches")
        }
    }

    private var hero: some View {
        let m = data.metrics
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .lastTextBaseline, spacing: Theme.Space.m) {
                HeroNumber(ms: m.workMs, caption: "Work")
                if let raw = data.rawWorkMs { editedPill(delta: m.workMs - raw) }
            }
            goalLine
            Text("Tracked \(Fmt.duration(ms: m.trackedMs)) · Billable \(Fmt.duration(ms: m.billableMs))")
                .font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
        }
        .padding(.top, Theme.Space.xs)
    }

    // MARK: Compact (Blocks mode)

    /// The hero with the goal beside the number, then the stats as aligned columns. Stacks (hero
    /// above the stats) when one row doesn't fit.
    private var compactBody: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                compactHero
                statStrip
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                compactHero
                statStrip
            }
        }
    }

    private var compactHero: some View {
        let m = data.metrics
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .bottom, spacing: Theme.Space.l) {
                HStack(alignment: .lastTextBaseline, spacing: Theme.Space.m) {
                    HeroNumber(ms: m.workMs, caption: "Work")
                    if let raw = data.rawWorkMs { editedPill(delta: m.workMs - raw).fixedSize() }
                }
                goalLine.padding(.bottom, Theme.Space.s)
            }
            Text("Tracked \(Fmt.duration(ms: m.trackedMs)) · Billable \(Fmt.duration(ms: m.billableMs))")
                .font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
        }
        .fixedSize()
    }

    @ViewBuilder private var goalLine: some View {
        let m = data.metrics
        if let goal = data.goal, let p = m.goalProgress {
            HStack(spacing: Theme.Space.s) {
                ProgressRing(progress: p, size: .small)
                VStack(alignment: .leading, spacing: 0) {
                    Text(p >= 1 ? "Goal met" : "\(Fmt.percent(p)) of \(Fmt.duration(ms: goal.dailyWorkMs)) goal")
                        .font(TextRole.bodyEmph.font).foregroundStyle(Theme.ink)
                    Text(p >= 1 ? "+\(Fmt.duration(ms: m.workMs - goal.dailyWorkMs)) over"
                                : "\(Fmt.duration(ms: goal.dailyWorkMs - m.workMs)) to go")
                        .font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
                }
            }
        }
    }

    /// Focus · Meetings · Breaks · Switches: micro label, value, one short detail line; hairlines between.
    private var statStrip: some View {
        let m = data.metrics
        let longest = m.breaks.max(by: { $0.durationMs < $1.durationMs })
        return HStack(alignment: .top, spacing: 0) {
            stat("Focus", Fmt.durationParts(ms: m.focusMs),
                 detail: m.focusRatio.map { "\(Fmt.percent($0)) · \(count(m.focusSessions.count, "session"))" } ?? "No sessions")
            stat("Meetings", Fmt.durationParts(ms: m.meetingMs), detail: m.meetings.isEmpty ? "None" : count(m.meetings.count, "meeting"))
            stat("Breaks", Fmt.durationParts(ms: m.breakMs), detail: longest.map { "longest \(Fmt.duration(ms: $0.durationMs))" } ?? "None")
            stat("Switches", [Fmt.Part(value: m.switchesPerHour.map { String(format: "%.1f", $0) } ?? "–", unit: "/h")],
                 detail: count(m.switches, "switch", plural: "switches"))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stat(_ label: String, _ parts: [Fmt.Part], detail: String) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(width: Theme.Stroke.hairline)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(label).textRole(.micro).lineLimit(1)
                HeroNumber.text(parts, value: .title, unit: .metricUnit)
                    .contentTransition(HeroNumber.roll(numericValue))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Text(detail).textRole(.label, Theme.inkTertiary).lineLimit(1)
            }
            .padding(.leading, Theme.Space.m)
            .frame(minWidth: Self.statMinWidth, maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(parts.map { $0.value + $0.unit }.joined(separator: " ")), \(detail)")
    }

    static let statMinWidth: CGFloat = 112

    /// Increases with the date, so on ← / → the numbers roll down / up (`hoursNumericValue`).
    nonisolated static func rollValue(_ d: LocalDate) -> Double { Double(d.year * 10_000 + d.month * 100 + d.day) }

    private func editedPill(delta: Int64) -> some View {
        let sign = delta > 0 ? "+" : (delta < 0 ? "−" : "±")
        return Text("± \(sign)\(Fmt.duration(ms: abs(delta)))")
            .font(TextRole.label.font).foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, Theme.Space.s - 2)
            .frame(height: 20)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .help("Adjusted \(sign)\(Fmt.duration(ms: abs(delta))) vs raw tracking (edits applied)")
            .accessibilityLabel("Adjusted by edits, \(Fmt.durationSpoken(ms: abs(delta))) vs raw")
    }

    private func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? noun : plural ?? noun + "s")"
    }
}
