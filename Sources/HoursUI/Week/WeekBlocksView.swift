import SwiftUI
import HoursCore

/// The Week's Blocks mode: block totals as tiles, then the week as seven day columns of work blocks
/// on one clock axis. Read-only; clicking a block opens that day in the Day view's Blocks mode.
struct WeekBlocksView: View {
    let data: WeekData
    let onOpen: (WeekBlockRoute) -> Void

    var body: some View {
        let wb = WeekBlocks.build(data)
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            ColumnsLayout(minColumnWidth: StatTile.minWidth, counts: [4, 2, 1]) {
                StatTile("Blocks", value: "\(wb.count)", comparator: blocksLine(wb))
                if let avg = wb.averageMs {
                    StatTile("Average block", ms: avg, comparator: "\(Fmt.duration(ms: wb.days.reduce(0) { $0 + $1.totalMs })) in blocks")
                } else {
                    StatTile("Average block", value: "–", comparator: "No blocks")
                }
                if let longest = wb.longestMs {
                    StatTile("Longest block", ms: longest, comparator: longestLine(wb))
                } else {
                    StatTile("Longest block", value: "–", comparator: "No blocks")
                }
                let breaks = wb.days.reduce(0) { $0 + $1.breaks.count }
                StatTile("Break time", ms: wb.breakMs, comparator: breaks == 0 ? "No breaks" : "\(breaks) break\(breaks == 1 ? "" : "s")")
            }
            WeekBlocksGrid(data: data, wb: wb, onOpen: onOpen)
        }
    }

    private func blocksLine(_ wb: WeekBlocks) -> String {
        let worked = wb.days.filter { $0.count > 0 }.count
        let thresholds = Set(wb.days.map(\.thresholdMin))
        let rule = thresholds.count == 1 ? "Breaks ≥ \(thresholds.first!)m" : "Per-day break rules"
        return "\(rule) · \(worked) day\(worked == 1 ? "" : "s")"
    }

    /// `Tue 29 · 09:05–11:40`.
    private func longestLine(_ wb: WeekBlocks) -> String {
        var best: (WeekBlocks.Day, WorkBlock)?
        for d in wb.days { for b in d.blocks where b.wallMs > (best?.1.wallMs ?? -1) { best = (d, b) } }
        guard let (d, b) = best else { return "" }
        let tz = wb.timeZone
        return "\(d.date.rangeShortLabel.prefix(3)) \(d.date.day) · \(Fmt.clock(ms: b.startMs, timeZone: tz))–\(Fmt.clock(ms: b.endMs, timeZone: tz))"
    }
}

/// Seven day columns on one clock axis, one Canvas. Column headers carry each day's block count and
/// average; today's column is raised and carries the now line. Hit-testing by column and y.
struct WeekBlocksGrid: View {
    let data: WeekData
    let wb: WeekBlocks
    let onOpen: (WeekBlockRoute) -> Void

    @State private var hovered: Hit?
    @State private var scroll = ScrollPosition(edge: .top)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let gutter: CGFloat = 46
    static let gap: CGFloat = 6
    static let headerH: CGFloat = 40
    static let topPad: CGFloat = BlocksGeometry.topPad
    /// The columns scroll inside the Day column's viewport, at its scale.
    static let viewportHeight: CGFloat = BlocksGeometry.viewportHeight

    /// The Day column's scale: visible height / `blocks_window_hours` (18 h).
    static func pxPerHour(_ wb: WeekBlocks) -> CGFloat {
        BlocksGeometry.pxPerHour(windowHours: Int(wb.windowMs / WeekBlocks.hour), zoom: 1)
    }
    private var pxPerHour: CGFloat { Self.pxPerHour(wb) }
    private var plotHeight: CGFloat {
        CGFloat(wb.axis.upperBound - wb.axis.lowerBound) / CGFloat(WeekBlocks.hour) * pxPerHour + 2 * Self.topPad
    }
    /// Scroll offset of the default viewport (`wb.top`'s hour line just under the top pad).
    private var defaultOffset: CGFloat {
        min(max(y(wb.top) - Self.topPad, 0), max(0, plotHeight - Self.viewportHeight))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Work blocks").textRole(.heading)
                Spacer(minLength: Theme.Space.m)
                Text(readout).textRole(.label, Theme.inkTertiary).lineLimit(1)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                let colW = Self.columnWidth(width)
                ZStack(alignment: .topLeading) {
                    // Today's column, raised behind its header and plot.
                    if let t = wb.days.firstIndex(where: { $0.date == data.today }) {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .fill(Theme.surfaceRaised)
                            .frame(width: colW, height: Self.headerH + Self.viewportHeight)
                            .offset(x: Self.columnX(t, width: width))
                    }
                    ForEach(wb.days.indices, id: \.self) { i in
                        header(wb.days[i], compact: colW < 140)
                            .frame(width: colW, height: Self.headerH)
                            .offset(x: Self.columnX(i, width: width))
                    }
                    ScrollView(.vertical) {
                        plot(width: width)
                            .frame(width: width, height: plotHeight)
                    }
                    .scrollPosition($scroll)
                    .frame(width: width, height: Self.viewportHeight)
                    .offset(y: Self.headerH)
                }
            }
            .frame(height: Self.headerH + Self.viewportHeight)
            .frame(minWidth: Self.gutter + 7 * 64 + 6 * Self.gap)
        }
        .hoursCard()
        .onAppear { scroll.scrollTo(y: defaultOffset) }
        .onChange(of: data.monday) { scroll.scrollTo(y: defaultOffset) }
        .onChange(of: wb.windowMs) { scroll.scrollTo(y: defaultOffset) }
    }

    static func columnWidth(_ width: CGFloat) -> CGFloat { max((width - gutter - 6 * gap) / 7, 1) }
    static func columnX(_ i: Int, width: CGFloat) -> CGFloat { gutter + CGFloat(i) * (columnWidth(width) + gap) }

    private func y(_ off: Int64) -> CGFloat {
        Self.topPad + CGFloat(Double(off - wb.axis.lowerBound) / Double(WeekBlocks.hour)) * pxPerHour
    }

    // MARK: Header

    /// `Mon 28` over `4 blocks · avg 1h 12m`; every column switches to two lines together when narrow.
    private func header(_ day: WeekBlocks.Day, compact: Bool) -> some View {
        let d = day.date
        let future = data.isFuture(d)
        let ink = future ? Theme.inkDisabled : (d == data.today ? Theme.ink : Theme.inkTertiary)
        let count = day.count == 0 ? (future ? "–" : "No blocks") : "\(day.count) block\(day.count == 1 ? "" : "s")"
        let avg = day.averageMs.map { "avg \(Fmt.duration(ms: $0))" }
        return VStack(spacing: 1) {
            Text("\(d.rangeShortLabel.prefix(3)) \(d.day)").textRole(.label, ink)
            Group {
                if compact {
                    Text(count)
                    if let avg { Text(avg) }
                } else {
                    Text([count, avg].compactMap { $0 }.joined(separator: " · "))
                }
            }
            .font(TextRole.micro.font.monospacedDigit())
            .foregroundStyle(Theme.inkTertiary)
            .lineLimit(1)
        }
        .padding(.top, Theme.Space.xs)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    // MARK: Plot

    private func plot(width: CGFloat) -> some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            draw(&ctx, width: size.width)
        }
        .overlay(alignment: .topLeading) { hoverRing(width: width) }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let p) = phase { hovered = hit(p, width: width) } else { hovered = nil }
        }
        .pointerStyle(hovered != nil ? .link : nil)
        .gesture(SpatialTapGesture().onEnded { v in
            if let h = hit(v.location, width: width) { onOpen(.open(h.block, on: wb.days[h.day].date)) }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Work blocks, \(wb.count) block\(wb.count == 1 ? "" : "s") this week")
        .accessibilityChildren {
            ForEach(wb.days.indices, id: \.self) { i in
                ForEach(wb.days[i].blocks, id: \.startMs) { b in
                    Button(spoken(b, wb.days[i])) { onOpen(.open(b, on: wb.days[i].date)) }
                }
            }
        }
    }

    struct Hit: Equatable { var day: Int; var block: WorkBlock }

    private func hit(_ p: CGPoint, width: CGFloat) -> Hit? {
        let colW = Self.columnWidth(width)
        let i = Int(((p.x - Self.gutter) / (colW + Self.gap)).rounded(.down))
        guard wb.days.indices.contains(i), p.x - Self.columnX(i, width: width) <= colW else { return nil }
        let day = wb.days[i]
        // Short blocks are hard to hit: accept a few points either side.
        let slop: CGFloat = 3
        return day.blocks.first { b in
            p.y >= y(wb.offset(b.startMs, day)) - slop && p.y <= y(wb.offset(b.endMs, day)) + slop
        }.map { Hit(day: i, block: $0) }
    }

    private func blockRect(_ b: WorkBlock, _ day: WeekBlocks.Day, x: CGFloat, colW: CGFloat) -> CGRect {
        let y0 = y(wb.offset(b.startMs, day)), y1 = y(wb.offset(b.endMs, day))
        return CGRect(x: x + 3, y: y0 + 0.5, width: colW - 6, height: max(y1 - y0 - 1, 2))
    }

    /// The hovered block's outline: a view over the Canvas (keyed by the hit) so it fades in and out.
    @ViewBuilder private func hoverRing(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let h = hovered, wb.days.indices.contains(h.day) {
                let r = blockRect(h.block, wb.days[h.day], x: Self.columnX(h.day, width: width), colW: Self.columnWidth(width))
                    .insetBy(dx: -1, dy: -1)
                RoundedRectangle(cornerRadius: Theme.Radius.block + 1, style: .continuous)
                    .stroke(Theme.ink.opacity(0.6), lineWidth: 1)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    // Keyed by the block's start, not the whole Hit: the live block's end grows each minute.
                    .id([Int64(h.day), h.block.startMs])
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.animation(Theme.Motion.hover, reduceMotion: reduceMotion), value: hovered)
        .allowsHitTesting(false)
    }

    private func draw(_ ctx: inout GraphicsContext, width: CGFloat) {
        let colW = Self.columnWidth(width)

        // Hour grid across the columns; labels in the gutter.
        var h = (wb.axis.lowerBound + WeekBlocks.hour - 1) / WeekBlocks.hour * WeekBlocks.hour
        while h <= wb.axis.upperBound {
            let yy = y(h).rounded() + 0.25
            var line = Path()
            line.move(to: CGPoint(x: Self.gutter - 2, y: yy))
            line.addLine(to: CGPoint(x: width, y: yy))
            ctx.stroke(line, with: .style(Theme.hairline), lineWidth: Theme.Stroke.hairline)
            let label = ctx.resolve(Text(wb.hourLabel(h))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.inkTertiary))
            ctx.draw(label, at: CGPoint(x: Self.gutter - 8, y: yy), anchor: .trailing)
            h += WeekBlocks.hour
        }

        for (i, day) in wb.days.enumerated() {
            let x = Self.columnX(i, width: width)
            for b in day.blocks {
                let r = blockRect(b, day, x: x, colW: colW)
                drawBlock(&ctx, b, day, rect: r)
            }
            // Now: a line across today's column with a dot at its left edge.
            if let now = data.nowMs, now >= day.startMs, now < day.startMs + 24 * WeekBlocks.hour {
                let ny = y(wb.offset(now, day)).rounded() + 0.5
                var line = Path()
                line.move(to: CGPoint(x: x, y: ny))
                line.addLine(to: CGPoint(x: x + colW, y: ny))
                ctx.stroke(line, with: .style(Theme.ink), lineWidth: 1)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: ny - 3, width: 6, height: 6)), with: .style(Theme.ink))
            }
        }
    }

    /// The Day view's block look: category tint + solid edge (solid fill when short), edited notch,
    /// the dominant project (else category) when the block is tall enough, the duration under it.
    private func drawBlock(_ ctx: inout GraphicsContext, _ b: WorkBlock, _ day: WeekBlocks.Day, rect r: CGRect) {
        let label = data.range.label(.category(b.dominantCategoryId))
        TimelineBlockStyle(slot: label.slot).draw(in: &ctx, rect: r)
        guard !TimelineBlockStyle.isCollapsed(height: r.height) else { return }
        var inner = ctx
        inner.clip(to: Path(roundedRect: r, cornerRadius: min(Theme.Radius.block, r.height / 2), style: .continuous))
        // Category-mix edge, as in the Day view: each active span at its height in its category colour.
        let edgeW = TimelineBlockStyle.edgeWidth
        inner.fill(Path(CGRect(x: r.minX, y: r.minY, width: edgeW, height: r.height)), with: .style(Theme.surface))
        for c in data.daySpans[day.date] ?? [] where c.span.kind == .active && c.span.endMs > b.startMs && c.span.startMs < b.endMs {
            let cat = data.range.categories.first { $0.id == c.categoryId }
            guard cat?.behavior != .exclude else { continue }
            let y0 = y(wb.offset(max(c.span.startMs, b.startMs), day)), y1 = y(wb.offset(min(c.span.endMs, b.endMs), day))
            inner.fill(Path(CGRect(x: r.minX, y: y0, width: edgeW, height: max(y1 - y0, 0.75))),
                       with: .style(Theme.Palette.swatch(slot: cat?.colorSlot)))
        }
        if b.hasEdits, r.height >= 16 {
            let s = TimelineBlockStyle.editedMarkSize + 2
            var tri = Path()
            tri.move(to: CGPoint(x: r.maxX - s, y: r.minY))
            tri.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            tri.addLine(to: CGPoint(x: r.maxX, y: r.minY + s))
            tri.closeSubpath()
            inner.fill(tri, with: .style(Theme.ink))
        }
        let x = r.minX + TimelineBlockStyle.edgeWidth + Theme.Space.xs + 1
        let w = r.maxX - x - Theme.Space.xs - (b.hasEdits ? TimelineBlockStyle.editedMarkSize : 0)
        guard r.height >= 22, w >= 30 else { return }
        let title = b.dominantProjectId.map { data.range.label(.project($0)).name } ?? label.name
        guard let t = WeekBlocksText.fitted(ctx, title, font: .system(size: 11.5, weight: .semibold), style: Theme.ink, width: w) else { return }
        ctx.draw(t, at: CGPoint(x: x, y: r.minY + 4), anchor: .topLeading)
        guard r.height >= 38 else { return }
        let tz = wb.timeZone
        let range = "\(Fmt.clock(ms: b.startMs, timeZone: tz))–\(Fmt.clock(ms: b.endMs, timeZone: tz))"
        let full = Text(Fmt.duration(ms: b.wallMs)).font(TextRole.label.font.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
            + Text("  \(range)").font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
        let detail = ctx.resolve(full)
        // Every block in the week shows the range or none does: measured on the widest case, not this block's.
        let widest = ctx.resolve(Text("8h 88m").font(TextRole.label.font.weight(.semibold)) + Text("  88:88–88:88").font(TextRole.label.font))
        let fits = widest.measure(in: CGSize(width: 1000, height: 20)).width <= w
        ctx.draw(fits ? detail : ctx.resolve(Text(Fmt.duration(ms: b.wallMs)).font(TextRole.label.font.weight(.semibold))
                    .foregroundStyle(Theme.inkSecondary)),
                 at: CGPoint(x: x, y: r.minY + 19), anchor: .topLeading)
    }

    // MARK: Text

    private var readout: String {
        guard let h = hovered, wb.days.indices.contains(h.day) else { return "Click a block to open its day" }
        return spoken(h.block, wb.days[h.day], short: true)
    }

    private func spoken(_ b: WorkBlock, _ day: WeekBlocks.Day, short: Bool = false) -> String {
        let tz = wb.timeZone
        let name = b.dominantProjectId.map { data.range.label(.project($0)).name } ?? data.range.label(.category(b.dominantCategoryId)).name
        let when = "\(Fmt.clock(ms: b.startMs, timeZone: tz))–\(Fmt.clock(ms: b.endMs, timeZone: tz))"
        let dur = short ? Fmt.duration(ms: b.wallMs) : Fmt.durationSpoken(ms: b.wallMs)
        return "\(day.date.rangeShortLabel.prefix(3)) \(day.date.day) · \(name) · \(when) · \(dur)"
    }
}

enum WeekBlocksText {
    /// `s` in `font`, ellipsised to `width`; nil when not even three characters fit. (A copy of the Blocks
    /// day view's helper, which W22 owns.)
    static func fitted(_ ctx: GraphicsContext, _ s: String, font: Font, style: Swatch, width: CGFloat) -> GraphicsContext.ResolvedText? {
        let probe = CGSize(width: 10_000, height: 40)
        func resolve(_ str: String) -> GraphicsContext.ResolvedText { ctx.resolve(Text(str).font(font).foregroundStyle(style)) }
        let full = resolve(s)
        if full.measure(in: probe).width <= width { return full }
        let chars = Array(s)
        var lo = 0, hi = chars.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if resolve(String(chars[..<mid]).trimmingCharacters(in: .whitespaces) + "…").measure(in: probe).width <= width { lo = mid } else { hi = mid - 1 }
        }
        return lo >= 3 ? resolve(String(chars[..<lo]).trimmingCharacters(in: .whitespaces) + "…") : nil
    }
}
