import SwiftUI
import HoursCore

/// The Day view's "Blocks" mode: the vertical column card (threshold + zoom in its header, legend
/// underneath) beside the side panel (the day's overview and breakdowns, or the selected block).
/// Replaces the timeline card and the breakdown cards; the card fills the height it's given
/// (`fillHeight`) and the column's scale follows. Settings come from the store (`BlocksStore`).
struct BlocksCard: View {
    let data: DayData
    /// Edits allowed (the editing layer is attached); false = read-only column.
    let editable: Bool
    var commit: (EditPlan) -> Void
    var preview: BlocksPreview?
    /// Height the card may fill (the page's free height below the headline); nil = the default viewport.
    var fillHeight: CGFloat?

    @Environment(\.blocksStore) private var store
    @Environment(\.blocksOpenRequest) private var openRequest
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoom: CGFloat = 1
    @State private var selectedMs: Int64?
    @State private var thresholdOpen = false
    @State private var scroll = ScrollPosition(edge: .top)
    /// The column's current scroll offset (for keeping the top time put across a zoom).
    @State private var scrollY: CGFloat = 0
    /// The time a zoom glide in flight pins to the top (nil = idle), and which glide set it.
    @State private var glideTop: Int64?
    @State private var glideN = 0
    @State private var glide: BlocksGeometry.Glide?
    /// The card has had its real `fillHeight` (the first one lands after `onAppear` in a fresh page).
    @State private var sized = false

    init(data: DayData, editable: Bool, commit: @escaping (EditPlan) -> Void, preview: BlocksPreview? = nil,
         fillHeight: CGFloat? = nil) {
        self.data = data
        self.editable = editable
        self.commit = commit
        self.preview = preview
        self.fillHeight = fillHeight
        _selectedMs = State(initialValue: preview?.selectedMs)
    }

    private var settings: [String: String] { store?.settings ?? [:] }
    private var thresholdMin: Int { max(1, preview?.thresholdMin ?? BlocksThreshold.minutes(for: data.date, settings: settings)) }
    private var minBlockMs: Int64 { Int64(preview?.minBlockMin ?? BlocksThreshold.minBlockMinutes(settings)) * 60_000 }
    private var windowHours: Int { BlocksThreshold.windowHours(settings) }
    private var thresholdMs: Int64 { Int64(thresholdMin) * 60_000 }
    private var viewport: CGFloat { Self.viewport(fillHeight: fillHeight) }
    private func geometry(zoom: CGFloat, viewport: CGFloat? = nil) -> BlocksGeometry {
        BlocksGeometry.day(bounds: data.bounds, windowHours: windowHours, zoom: zoom, viewport: viewport ?? self.viewport)
    }

    /// The column's visible height when the card fills `fillHeight` (card padding, header and legend aside).
    static func viewport(fillHeight: CGFloat?) -> CGFloat {
        guard let fillHeight, fillHeight > 0 else { return BlocksGeometry.viewportHeight }
        return max(BlocksGeometry.minViewportHeight, (fillHeight - chromeH).rounded(.down))
    }

    /// Everything in the column card but the viewport.
    static let chromeH: CGFloat = 2 * Theme.Space.l + headerH + 2 * Theme.Space.m + legendH

    /// The Week asked to open a block on this day: the instant to select.
    static func requestedSelection(_ request: WeekBlockRoute?, on date: LocalDate) -> Int64? {
        request.flatMap { $0.day == date ? $0.selectedMs : nil }
    }

    var body: some View {
        let thresholdMs = thresholdMs
        let day = MetricsBlocks.day(spans: data.spans, categories: data.categories, breakThresholdMs: thresholdMs)
        let geo = geometry(zoom: zoom)
        let selected = selectedMs.flatMap { ms in day.blocks.first { $0.contains(ms) } }
        SplitLayout(trailingWidth: 340, leadingMinWidth: 440) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header(day)
                // The whole day scrolls inside a fixed 18 h viewport (`blocks_window_hours`).
                ScrollView(.vertical) {
                    BlocksColumn(data: data, day: day, geo: geo, thresholdMs: thresholdMs, minBlockMs: minBlockMs,
                                 editable: editable, selectedMs: $selectedMs, commit: commit, saveRules: saveRules,
                                 preview: preview, onFocus: { focus($0.startMs..<$0.endMs) }, glide: glide)
                }
                .frame(height: viewport)
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in scrollY = y }
                legend
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .hoursCard(padding: Theme.Space.l, radius: Theme.Radius.panel)

            // As tall as the column card; longer details scroll inside it.
            ScrollView(.vertical) {
                BlocksDetail(data: data, day: day, minBlockMs: minBlockMs, selected: selected, editable: editable,
                             pickerOpen: preview?.projectPickerOpen ?? false,
                             onSelect: { selectedMs = $0 },
                             onAssign: { b, p, always in assign(b, p, always: always) },
                             canSaveRules: store != nil)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .frame(height: Self.headerH + Theme.Space.m + viewport + Theme.Space.m + Self.legendH)
            .hoursCard(padding: Theme.Space.l, radius: Theme.Radius.panel)
        }
        .onAppear {
            sized = fillHeight != nil
            if let ms = Self.requestedSelection(openRequest, on: data.date) { selectedMs = ms }
            scrollToDefault()
        }
        .onChange(of: data.date) {
            selectedMs = Self.requestedSelection(openRequest, on: data.date)
            zoom = 1
            scrollToDefault()
        }
        .onChange(of: openRequest) {
            guard let ms = Self.requestedSelection(openRequest, on: data.date) else { return }
            selectedMs = ms
            scrollToDefault()
        }
        .onChange(of: windowHours) { scrollToDefault() }
        // First real height: the default viewport at that scale. Later (the window grew or shrank):
        // new scale, same time at the top.
        .onChange(of: viewport) { old, new in
            guard sized else { sized = true; scrollToDefault(); return }
            keepTop(from: geometry(zoom: zoom, viewport: old), to: geometry(zoom: zoom, viewport: new))
        }
    }

    /// Click-to-zoom: scale so the block fills most of the viewport, centred.
    private func focus(_ r: Range<Int64>) {
        setZoom(BlocksGeometry.focusZoom(r, windowHours: windowHours)) { $0.offset(centring: r) }
    }

    /// ⌘+ / ⌘−: the time at the top of the viewport stays put. Mid-glide, `scrollY` is the animated
    /// offset while `zoom` is already the target, so use the glide's target top instead.
    private func zoomKeepingTop(_ z: CGFloat) {
        let top = glideTop ?? geometry(zoom: zoom).ms(atY: scrollY + BlocksGeometry.topPad)
        setZoom(z) { $0.offset(top: top) }
    }

    /// The scroll jumps to its target while the column glides its scale (`BlocksColumn` is
    /// `Animatable`) and draws shifted along the same progress (`BlocksGeometry.Glide`), so what it
    /// pins (the clicked block, the top time) moves smoothly. Same zoom: a plain animated scroll.
    private func setZoom(_ z: CGFloat, offset: (BlocksGeometry) -> CGFloat) {
        let from = geometry(zoom: zoom), to = geometry(zoom: z), y = offset(to)
        glideN += 1
        let n = glideN
        glideTop = to.ms(atY: y + BlocksGeometry.topPad)
        guard z != zoom, let settle = Theme.Motion.settle(reduceMotion: reduceMotion) else {
            withAnimation(z == zoom ? Theme.Motion.snap(reduceMotion: reduceMotion) : nil) { zoom = z; scroll.scrollTo(y: y) }
            glideTop = nil
            return
        }
        glide = BlocksGeometry.Glide(fromPx: from.pxPerHour, fromY: scrollY, toPx: to.pxPerHour, toY: y)
        scroll.scrollTo(y: y)
        withAnimation(settle) {
            zoom = z
        } completion: {
            if glideN == n { glideTop = nil; glide = nil }   // a later glide is still running
        }
    }

    /// Keeps the time at the top of the viewport where it is across a scale change.
    private func keepTop(from old: BlocksGeometry, to new: BlocksGeometry) {
        scroll.scrollTo(y: new.offset(top: old.ms(atY: scrollY + BlocksGeometry.topPad)))
    }

    /// The default viewport (06:00–24:00, moved for early / late activity and the selected block).
    private func scrollToDefault() { scroll.scrollTo(y: defaultY) }

    private var defaultY: CGFloat {
        Self.defaultOffset(data, settings: settings, thresholdMs: thresholdMs, selectedMs: selectedMs, viewport: viewport)
    }

    /// Scroll offset of the default viewport at zoom 1.
    static func defaultOffset(_ data: DayData, settings: [String: String], thresholdMs: Int64, selectedMs: Int64?,
                              viewport: CGFloat = BlocksGeometry.viewportHeight) -> CGFloat {
        let blocks = MetricsBlocks.compute(spans: data.spans, categories: data.categories, breakThresholdMs: thresholdMs)
        let hours = BlocksThreshold.windowHours(settings)
        let geo = BlocksGeometry.day(bounds: data.bounds, windowHours: hours, viewport: viewport)
        let start = BlocksGeometry.windowStart(data.date, timeZone: data.timeZone, minutes: BlocksThreshold.windowStartMinutes(settings))
        let focus = selectedMs.flatMap { ms in blocks.first { $0.contains(ms) } }.map { $0.startMs..<$0.endMs }
        let top = BlocksGeometry.defaultTop(range: data.bounds, windowStart: start, windowMs: Int64(hours) * BlocksGeometry.hourMs,
                                            first: blocks.first?.startMs, last: blocks.last?.endMs, focus: focus)
        return geo.offset(top: top)
    }

    private func assign(_ b: WorkBlock, _ projectId: Int64, always: Bool) {
        guard let plan = BlocksActions.assignProject(b, projectId, data: data) else { return }
        commit(plan)
        if always { saveRules(b, projectId) }
    }

    private func saveRules(_ b: WorkBlock, _ projectId: Int64) {
        store?.save(BlocksActions.rules(b, projectId: projectId, data: data).map(\.rule))
    }

    private func header(_ day: MetricsBlocks.Day) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Text("Blocks").textRole(.heading)
            Text(Self.summary(day, minBlockMs: minBlockMs)).font(TextRole.label.font).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            thresholdButton
            zoomControls
        }
        .frame(height: Self.headerH)
    }

    static let headerH: CGFloat = 26
    static let legendH: CGFloat = 16

    /// "4 blocks · 3 breaks", plus "· 2 micro" when a minimum length hides some (not counted as blocks).
    static func summary(_ day: MetricsBlocks.Day, minBlockMs: Int64) -> String {
        let micro = day.blocks.filter { $0.wallMs < minBlockMs }.count
        let n = day.blocks.count - micro, k = day.breaks.count
        var s = "\(n) block\(n == 1 ? "" : "s") · \(k) break\(k == 1 ? "" : "s")"
        if micro > 0 { s += " · \(micro) micro" }
        return s
    }

    /// Swatches for what the column draws: tracked time, hand-claimed time, micro blocks.
    private var legend: some View {
        HStack(spacing: Theme.Space.l) {
            legendItem("Tracked") { ctx, r in
                let style = TimelineBlockStyle(slot: 0)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .style(style.tint))
                ctx.fill(Path(CGRect(x: r.minX, y: r.minY, width: 3, height: r.height)), with: .style(style.edge))
            }
            legendItem("Claimed by hand") { ctx, r in
                let style = TimelineBlockStyle(slot: 0)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .style(style.tint))
                BlocksColumn.hatch(&ctx, r, style.edge)
            }
            if minBlockMs > 0 {
                legendItem("Under \(Fmt.duration(ms: minBlockMs)) (micro)") { ctx, r in
                    ctx.fill(Path(roundedRect: CGRect(x: r.minX, y: r.midY - 1.5, width: r.width, height: 3), cornerRadius: 1.5),
                             with: .style(TimelineBlockStyle(slot: 0).edge))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.legendH)
        .padding(.leading, BlocksGeometry.gutter + Theme.Space.s)
    }

    private func legendItem(_ title: String, _ draw: @escaping (inout GraphicsContext, CGRect) -> Void) -> some View {
        HStack(spacing: Theme.Space.xs + 2) {
            Canvas { ctx, size in draw(&ctx, CGRect(origin: .zero, size: size)) }
                .frame(width: 18, height: 10)
            Text(title).font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    /// "Breaks ≥ 10m": presets 5/10/15/30, a custom stepper, and "only on <weekday>", in a popover. Display-only.
    private var thresholdButton: some View {
        Button { thresholdOpen.toggle() } label: {
            HStack(spacing: Theme.Space.xs + 1) {
                Image(systemName: "cup.and.saucer").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                Text("Breaks ≥ \(thresholdMin)m").font(TextRole.label.font).foregroundStyle(Theme.ink)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, Theme.Space.s + 2)
            .frame(height: 26)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("A gap without input at least this long ends a block")
        .popover(isPresented: $thresholdOpen, arrowEdge: .bottom) {
            BlocksThresholdPicker(
                minutes: Binding(get: { thresholdMin }, set: { m in
                    store?.setThreshold(m, for: data.date, weekdayOnly: BlocksThreshold.overrides(settings)[BlocksThreshold.weekday(data.date)] != nil)
                }),
                weekdayOnly: Binding(get: { BlocksThreshold.overrides(settings)[BlocksThreshold.weekday(data.date)] != nil },
                                     set: { store?.setWeekdayOnly($0, for: data.date) }),
                weekdayName: Self.weekdayName(data.date))
        }
    }

    /// "Thursday".
    static func weekdayName(_ d: LocalDate) -> String {
        Calendar(identifier: .gregorian).weekdaySymbols[BlocksThreshold.weekday(d) - 1]
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            DayIconButton(symbol: "minus", help: "Zoom out (⌘−)") { zoomKeepingTop(max(zoom / 1.5, BlocksGeometry.minZoom)) }
                .keyboardShortcut("-", modifiers: .command)
            DayIconButton(symbol: "plus", help: "Zoom in (⌘+)") { zoomKeepingTop(min(zoom * 1.5, BlocksGeometry.maxZoom)) }
                .keyboardShortcut("=", modifiers: .command)
            Rectangle().fill(Theme.hairline).frame(width: Theme.Stroke.hairline, height: 16)
                .padding(.horizontal, Theme.Space.xs)
            DayIconButton(symbol: "arrow.up.and.down", help: "Reset to the \(windowHours) h view (⌘0)") {
                setZoom(1) { _ in defaultY }
            }
            .keyboardShortcut("0", modifiers: .command)
        }
        .padding(.horizontal, Theme.Space.xxs)
        .frame(height: 26)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous))
    }
}

/// Presets as a row of chips, a stepper for anything else, and "Only on <weekday>s" (writes that
/// weekday's override instead of the default).
struct BlocksThresholdPicker: View {
    @Binding var minutes: Int
    @Binding var weekdayOnly: Bool
    let weekdayName: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Break after").textRole(.micro)
            HStack(spacing: Theme.Space.xs) {
                ForEach(MetricsBlocks.presetsMin, id: \.self) { m in
                    Button { minutes = m } label: {
                        Text("\(m)m").font(TextRole.label.font)
                            .foregroundStyle(minutes == m ? Theme.surface : Theme.ink)
                            .frame(width: 44, height: 24)
                            .background(minutes == m ? Theme.ink : Theme.surfaceRaised,
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Stepper(value: $minutes, in: BlocksThreshold.range) {
                Text("Custom: \(minutes) min").font(TextRole.body.font).foregroundStyle(Theme.ink)
            }
            Toggle(isOn: $weekdayOnly) {
                Text("Only on \(weekdayName)s").font(TextRole.body.font).foregroundStyle(Theme.ink)
            }
            .toggleStyle(.checkbox)
            Text("Gaps and idle shorter than this stay inside a block. Per-weekday values and a minimum block length are in Settings → Blocks.")
                .font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.l)
        .frame(width: 260)
    }
}
