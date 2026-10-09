import SwiftUI
import HoursCore

/// Side panel of the Blocks mode. With a block selected: its categories, projects, apps & sites and
/// spans, reusing the Day panels' components over the block's slice of the day, plus a project chip
/// that relabels the whole block and links to Scry notes taken during it. Otherwise: the day's blocks as a list (click to select; micro
/// blocks left out), the Day's breakdowns (categories, projects, apps & sites, sessions) condensed,
/// and how editing works.
struct BlocksDetail: View {
    let data: DayData
    let day: MetricsBlocks.Day
    let minBlockMs: Int64
    let selected: WorkBlock?
    let editable: Bool
    let onSelect: (Int64?) -> Void
    /// Project chip pick: (block, project, also save "Always for these apps" rules).
    let onAssign: (WorkBlock, Int64, Bool) -> Void
    let canSaveRules: Bool

    @State private var pickerOpen: Bool
    @State private var alwaysForApps = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scryRoot) private var scryRoot
    @Environment(\.openMeeting) private var openMeeting
    /// Scry notes overlapping the selected block.
    @State private var meetings: [MeetingsNote] = []

    init(data: DayData, day: MetricsBlocks.Day, minBlockMs: Int64, selected: WorkBlock?, editable: Bool,
         pickerOpen: Bool = false, onSelect: @escaping (Int64?) -> Void,
         onAssign: @escaping (WorkBlock, Int64, Bool) -> Void, canSaveRules: Bool) {
        self.data = data; self.day = day; self.minBlockMs = minBlockMs; self.selected = selected
        self.editable = editable; self.onSelect = onSelect; self.onAssign = onAssign; self.canSaveRules = canSaveRules
        _pickerOpen = State(initialValue: pickerOpen)
    }

    static let maxSpans = 7, maxBlocks = 9

    var body: some View {
        // Another block (or overview ↔ block) crossfades: the old content fades out over the new.
        ZStack(alignment: .topLeading) {
            Group {
                if let b = selected { detail(b) } else { overview }
            }
            .id(selected?.startMs)
            .transition(.opacity)
        }
        .animation(Theme.Motion.animation(Theme.Motion.hover, reduceMotion: reduceMotion), value: selected?.startMs)
        .onChange(of: selected?.startMs) { pickerOpen = false; alwaysForApps = false }
        .task(id: selected.map { [$0.startMs, $0.endMs] }) {
            guard let b = selected, let root = scryRoot, openMeeting != nil else { meetings = []; return }
            let r = b.startMs..<b.endMs
            meetings = await Task.detached(priority: .utility) { MeetingsData.overlapping(MeetingsData.load(root), r) }.value
        }
    }

    // MARK: Selected block

    private func detail(_ b: WorkBlock) -> some View {
        let slice = Self.slice(data, b.startMs..<b.endMs)
        let tz = data.timeZone
        let live = BlocksResize.isLive(b, data)
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.Palette.swatch(slot: data.slot(b.dominantCategoryId)))
                    .frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(BlocksResize.label(b, data)).textRole(.heading).lineLimit(1)
                    Text("\(Fmt.clock(ms: b.startMs, timeZone: tz))–\(live ? "now" : Fmt.clock(ms: b.endMs, timeZone: tz))"
                         + (b.dominantProjectId != nil ? " · \(data.categoryName(b.dominantCategoryId))" : ""))
                        .font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
                }
                Spacer(minLength: 0)
                DayIconButton(symbol: "xmark", help: "Show all blocks") { onSelect(nil) }
            }
            projectChip(b)
            HStack(alignment: .top, spacing: Theme.Space.l) {
                figure("Length", Fmt.duration(ms: b.wallMs))
                figure("Active", Fmt.duration(ms: b.activeMs))
                figure("Idle inside", b.idleInsideMs > 0 ? Fmt.duration(ms: b.idleInsideMs) : "–")
                if b.hasEdits { figure("Edited", "±") }
            }
            if let openMeeting, !meetings.isEmpty {
                section("Meetings") {
                    ForEach(meetings) { m in
                        Button { openMeeting(m.url) } label: {
                            HStack(spacing: Theme.Space.s - 2) {
                                Image(systemName: "person.2.wave.2").font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
                                Text(m.note.summary.title).font(TextRole.body.font).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer(minLength: Theme.Space.s)
                                Text(Fmt.clock(ms: m.startMs, timeZone: tz)).font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open the meeting note")
                    }
                }
            }
            section("Categories") { DayCategoryChart(data: slice) }
            section("Projects") {
                DayBarList(rows: Array(DayRows.projects(slice).prefix(3)), empty: "No project time", dots: false)
            }
            section("Apps & sites") {
                DayBarList(rows: DayRows.apps(slice, limit: 3), empty: "No apps")
                let hosts = DayRows.hosts(slice, limit: 2)
                if !hosts.isEmpty { DayBarList(rows: hosts, empty: "", mono: true).padding(.top, Theme.Space.xs) }
            }
            section("Spans") { spans(slice) }
        }
    }

    // MARK: Project chip

    /// The block's project as a chip; clicking opens the picker (one `assign` over the block).
    @ViewBuilder private func projectChip(_ b: WorkBlock) -> some View {
        let name = data.projectName(b.dominantProjectId)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button { pickerOpen.toggle() } label: {
                HStack(spacing: Theme.Space.xs + 2) {
                    Image(systemName: "folder").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    Text(name ?? "No project").font(TextRole.label.font).foregroundStyle(name == nil ? Theme.inkTertiary : Theme.ink)
                        .lineLimit(1)
                    if editable {
                        Image(systemName: pickerOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                .padding(.horizontal, Theme.Space.s + 2)
                .frame(height: 24)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .overlay {
                    if pickerOpen {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .strokeBorder(Theme.ink, lineWidth: Theme.Stroke.selection)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!editable)
            .help("Set the project for the whole block")
            .accessibilityLabel("Project: \(name ?? "none")")
            if pickerOpen, editable { projectPicker(b) }
        }
    }

    private func projectPicker(_ b: WorkBlock) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(data.projects.filter { !$0.archived }) { p in
                Button {
                    onAssign(b, p.id, alwaysForApps && canSaveRules)
                    pickerOpen = false
                    alwaysForApps = false
                } label: {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.ink).opacity(p.id == b.dominantProjectId ? 1 : 0)
                        Text(p.name).font(TextRole.body.font).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Theme.Space.xs + 1)
                    .padding(.horizontal, Theme.Space.s)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if canSaveRules, let label = BlocksActions.ruleLabel(b, data: data) {
                Rectangle().fill(Theme.hairline).frame(height: Theme.Stroke.hairline).padding(.vertical, Theme.Space.xs)
                Toggle(isOn: $alwaysForApps) {
                    Text("Always for \(label)").font(TextRole.label.font).foregroundStyle(Theme.inkSecondary).lineLimit(2)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.xs)
                .help("Also save a rule per app, so future time in them goes to the chosen project")
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip + 2, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
    }

    private func figure(_ eyebrow: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(eyebrow).textRole(.micro)
            Text(value).font(TextRole.bodyEmph.font).foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).textRole(.micro)
            content()
        }
    }

    /// Longest spans of the block, in time order.
    private func spans(_ slice: DayData) -> some View {
        let active = slice.spans.filter { $0.span.kind == .active }
        let shown = Set(active.sorted { $0.span.durationMs > $1.span.durationMs }.prefix(Self.maxSpans).map(\.span.startMs))
        let rows = active.filter { shown.contains($0.span.startMs) }
        return VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            ForEach(rows, id: \.span.startMs) { c in
                let s = c.span
                HStack(spacing: Theme.Space.s - 2) {
                    Text(Fmt.clock(ms: s.startMs, timeZone: data.timeZone)).font(TextRole.mono.font).foregroundStyle(Theme.inkTertiary)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Theme.Palette.swatch(slot: data.slot(c.categoryId))).frame(width: 6, height: 6)
                    Text(spanTitle(s)).font(TextRole.body.font).foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1).truncationMode(.tail)
                    if !s.editSeqs.isEmpty { Text("±").font(TextRole.label.font).foregroundStyle(Theme.inkTertiary) }
                    Spacer(minLength: Theme.Space.s)
                    Text(Fmt.duration(ms: s.durationMs)).font(TextRole.label.font).foregroundStyle(Theme.ink)
                }
                .help(s.title ?? s.appName)
                .accessibilityElement(children: .combine)
            }
            if active.count > rows.count {
                Text("+ \(active.count - rows.count) shorter span\(active.count - rows.count == 1 ? "" : "s")")
                    .font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    private func spanTitle(_ s: EffectiveSpan) -> String {
        if s.source == .manual { return s.label ?? "Manual entry" }
        if let host = DayRows.host(s.url) { return "\(s.appName) · \(host)" }
        if let t = s.title, !t.isEmpty { return "\(s.appName) · \(t)" }
        return s.appName
    }

    // MARK: Nothing selected

    private var overview: some View {
        let blocks = day.blocks.filter { $0.wallMs >= minBlockMs }
        let longest = blocks.map(\.wallMs).max() ?? 0
        let avg = blocks.isEmpty ? 0 : blocks.reduce(Int64(0)) { $0 + $1.wallMs } / Int64(blocks.count)
        let breakMs = day.breaks.reduce(Int64(0)) { $0 + $1.durationMs }
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Work blocks").textRole(.heading)
                Text("Continuous stretches at the computer").font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
            }
            HStack(alignment: .top, spacing: Theme.Space.l) {
                figure("Average", blocks.isEmpty ? "–" : Fmt.duration(ms: avg))
                figure("Longest", blocks.isEmpty ? "–" : Fmt.duration(ms: longest))
                figure("Breaks", day.breaks.isEmpty ? "–" : Fmt.duration(ms: breakMs))
            }
            section("Blocks") {
                if blocks.isEmpty {
                    Text("Nothing tracked").font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(blocks.prefix(Self.maxBlocks), id: \.startMs) { b in
                        Button { onSelect(b.startMs + b.wallMs / 2) } label: { blockRow(b) }
                            .buttonStyle(.plain)
                    }
                }
                if blocks.count > Self.maxBlocks {
                    Text("+ \(blocks.count - Self.maxBlocks) more").font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
                }
            }
            // The Day's breakdown cards, condensed into the panel (W25).
            Rectangle().fill(Theme.hairline).frame(height: Theme.Stroke.hairline)
            ForEach(DayBreakdownSection.allCases, id: \.self) { s in
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.title).textRole(.micro)
                        Spacer(minLength: Theme.Space.s)
                        if let t = s.trailing(data) { Text(t).font(TextRole.label.font).foregroundStyle(Theme.inkTertiary) }
                    }
                    DayBreakdownList(data: data, section: s, compact: true)
                }
            }
            if editable, !blocks.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs + 2) {
                    Image(systemName: "arrow.up.and.down").foregroundStyle(Theme.inkTertiary)
                    Text("Drag a block's top or bottom edge to claim a break or trim time, or select it and press ⌘⌥↑/↓ (top) or ⌘⌥⇧↑/↓ (bottom). S splits at the pointer. Snaps to nearby edges, hours and 5 min; hold ⌥ to drag freely.")
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(TextRole.label.font)
            }
        }
    }

    private func blockRow(_ b: WorkBlock) -> some View {
        let tz = data.timeZone
        return HStack(spacing: Theme.Space.s) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Theme.Palette.swatch(slot: data.slot(b.dominantCategoryId))).frame(width: 4, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(BlocksResize.label(b, data)).font(TextRole.bodyEmph.font).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(Fmt.clock(ms: b.startMs, timeZone: tz))–\(BlocksResize.isLive(b, data) ? "now" : Fmt.clock(ms: b.endMs, timeZone: tz))")
                    .font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            Text(Fmt.duration(ms: b.wallMs)).font(TextRole.label.font).foregroundStyle(Theme.ink)
        }
        .padding(.vertical, Theme.Space.xs + 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The day restricted to `r` (spans clipped), with its own metrics — what the Day panels draw.
    static func slice(_ data: DayData, _ r: Range<Int64>) -> DayData {
        let spans = data.spans.compactMap { c -> ClassifiedSpan? in
            var c = c
            c.span.startMs = max(c.span.startMs, r.lowerBound)
            c.span.endMs = min(c.span.endMs, r.upperBound)
            return c.span.endMs > c.span.startMs ? c : nil
        }
        return DayData.assemble(date: data.date, timeZone: data.timeZone, bounds: data.bounds, spans: spans,
                                categories: data.categories, projects: data.projects, goal: nil, nowMs: data.nowMs,
                                rawWorkMs: nil, tracker: data.tracker)
    }
}
