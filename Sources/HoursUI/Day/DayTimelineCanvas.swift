import SwiftUI
import HoursCore

/// Row geometry of the timeline Canvas (top to bottom): hour labels, focus brackets, the activity
/// lane, the project lane.
enum DayLanes {
    static let axisH: CGFloat = 18
    static let focusY: CGFloat = 22, focusH: CGFloat = 16
    static let laneY: CGFloat = 42, laneH: CGFloat = 50
    static let projectY: CGFloat = laneY + laneH + 6, projectH: CGFloat = 18
    static let height: CGFloat = projectY + projectH + 2
}

/// The day timeline: one `Canvas`, no per-span views. Draws only the visible window, merges
/// sub-3-pt blocks (LOD), hit-tests by binary search. Pan = horizontal trackpad scroll or the
/// mini-strip; zoom = pinch, ⌘-scroll, ⌘+/⌘− (buttons in the card header).
///
/// Editing hooks (item 8 / W12): `selectedRange` is the selection model. Click selects a span's
/// range; W12 attaches drag-to-select, handles and actions on top of this view and maps x ↔ ms
/// through `DayViewport` — the Canvas already renders whatever range the binding holds.
struct DayTimelineCanvas: View {
    let data: DayData
    let items: [DayTimelineItem]
    let projectRuns: [(projectId: Int64, startMs: Int64, endMs: Int64)]
    @Binding var window: DayWindow
    @Binding var selectedRange: ClosedRange<Int64>?
    /// Category filter from the legend: `.some(id)` dims every other category (`.some(nil)` = Uncategorized).
    let highlight: Int64??
    var previewHoverMs: Int64? = nil
    var editHooks: DayEditHooks? = nil

    @State private var hoverX: CGFloat?
    @State private var magnifyBase: DayWindow?
    @State private var scroll = DayScrollMonitor()
    /// Legend crossfade: the filter before the last change, and a counter stepped once per change.
    @State private var filterFrom: Int64?? = nil
    @State private var filterSeq: Double = 0
    @State private var flashSeq: Double = 0
    @Environment(\.hoursEditFlash) private var editFlash
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            // Hover, tooltip and hit-testing use the target window; only the drawing glides.
            let vp = DayViewport(window: window, width: geo.size.width)
            let hx = hoverX ?? previewHoverMs.map { vp.x($0) }
            DayTweenCanvas(window: window, filterStep: filterSeq, filterTarget: filterSeq,
                           flashStep: flashSeq, flashTarget: flashSeq) { ctx, size, tween in
                draw(&ctx, vp: DayViewport(window: tween.window, width: size.width), hoverX: hx, tween: tween)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(DayTimeline.accessibilitySummary(data, items: items))
            .accessibilityChildren { accessibilityRows }
            .help(hx == nil ? "Pinch or ⌘-scroll to zoom · swipe sideways to pan" : "")
            // The hover card is drawn by the enclosing card (`dayTooltipOverlay`) so it can sit above
            // the card border and the panels below.
            .anchorPreference(key: DayTipKey.self, value: .bounds) { bounds in
                guard let hx, let tip = tooltip(atX: hx, vp: vp) else { return nil }
                return DayTipValue(content: tip, x: hx, bounds: bounds)
            }
            // Target vp: the edit overlay glides to it itself (`EditOverlay` wraps its layer in `DayTweenWindow`).
            .overlay { editHooks?.overlay(vp) }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    hoverX = p.x
                    editHooks?.hover(vp.ms(atX: p.x), vp)
                    scroll.start { event in handleScroll(event, width: geo.size.width) }
                case .ended:
                    hoverX = nil
                    editHooks?.hover(nil, vp)
                    scroll.stop()
                }
            }
            .gesture(SpatialTapGesture().onEnded { v in
                let vp = DayViewport(window: window, width: geo.size.width)
                if let i = vp.spanIndex(atX: v.location.x, in: data.spans) {
                    let s = data.spans[i].span
                    let r = s.startMs...s.endMs
                    let deselect = selectedRange == r
                    selectedRange = deselect ? nil : r
                    // A plain click zooms to the span (edges easy to grab); ⇧/⌘ clicks leave the view put.
                    if !deselect, NSEvent.modifierFlags.isDisjoint(with: [.shift, .command]) {
                        withAnimation(Theme.Motion.snap(reduceMotion: reduceMotion)) {
                            window = DayWindow.focus(s.startMs..<s.endMs, in: data.bounds)
                        }
                    }
                } else {
                    selectedRange = nil
                }
            })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    let base = magnifyBase ?? window
                    if magnifyBase == nil { magnifyBase = window }
                    let anchor = DayViewport(window: base, width: geo.size.width).ms(atX: v.startLocation.x)
                    window = base.zoomed(by: v.magnification, anchorMs: anchor, in: data.bounds)
                }
                .onEnded { _ in magnifyBase = nil })
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { v in editHooks?.laneDrag(vp.ms(atX: v.startLocation.x), vp.ms(atX: v.location.x), vp, false) }
                .onEnded { v in editHooks?.laneDrag(vp.ms(atX: v.startLocation.x), vp.ms(atX: v.location.x), vp, true) },
                including: editHooks == nil ? .none : .all)
            .contextMenu { if let editHooks { editHooks.contextMenu(hx.map { vp.ms(atX: $0) }) } }
            .onDisappear { scroll.stop() }
            .onChange(of: highlight) { old, _ in
                filterFrom = old
                withAnimation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion)) { filterSeq += 1 }
            }
            .onChange(of: editFlash?.id) { _, id in
                guard id != nil else { return }
                withAnimation(Theme.Motion.animation(Theme.Motion.flash, reduceMotion: reduceMotion)) { flashSeq += 1 }
            }
        }
        .frame(height: DayLanes.height)
    }

    /// Horizontal swipe pans; ⌘-scroll zooms around the pointer. Vertical scroll passes through to the page.
    private func handleScroll(_ e: DayScrollEvent, width: CGFloat) -> Bool {
        let vp = DayViewport(window: window, width: width)
        if e.command {
            let anchor = vp.ms(atX: hoverX ?? width / 2)
            window = window.zoomed(by: exp(Double(e.dy) * 0.01), anchorMs: anchor, in: data.bounds)
            return true
        }
        guard abs(e.dx) > abs(e.dy) else { return false }
        window = window.panned(byMs: Int64(-Double(e.dx) * vp.msPerPoint), in: data.bounds)
        return true
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, vp: DayViewport, hoverX: CGFloat?, tween: DayTweenCanvas) {
        let w = vp.width
        let bottom = DayLanes.height
        let laneRect = CGRect(x: 0, y: DayLanes.laneY, width: w, height: DayLanes.laneH)

        // Lane rail.
        let rail = Path(roundedRect: laneRect, cornerRadius: Theme.Radius.block, style: .continuous)
        ctx.fill(rail, with: .style(Theme.canvas))

        // "Now" pill geometry first, so tick labels can make room for it.
        var nowPill: CGRect?
        var nowText: GraphicsContext.ResolvedText?
        if let now = data.nowMs, now >= vp.window.startMs, now <= vp.endMs {
            let text = ctx.resolve(Text(Fmt.clock(ms: now, timeZone: data.timeZone))
                .font(TextRole.micro.font).foregroundStyle(Theme.surface))
            let sz = text.measure(in: CGSize(width: 100, height: 20))
            let x = vp.x(now).rounded() + 0.5
            nowPill = CGRect(x: min(max(x - sz.width / 2 - 5, 0), w - sz.width - 10), y: 1,
                             width: sz.width + 10, height: DayLanes.axisH - 3)
            nowText = text
        }

        // Hour grid + labels.
        let (step, ticks) = vp.ticks(tz: data.timeZone)
        for t in ticks {
            let x = vp.x(t).rounded() + 0.25
            let major = step < 3_600_000 ? isHour(t) : true
            var line = Path()
            line.move(to: CGPoint(x: x, y: DayLanes.axisH))
            line.addLine(to: CGPoint(x: x, y: bottom))
            ctx.stroke(line, with: .style(major ? Theme.hairline : Theme.hairline.over(Theme.surface, alpha: 0.5)),
                       lineWidth: Theme.Stroke.hairline)
            let label = ctx.resolve(Text(Fmt.clock(ms: t, timeZone: data.timeZone))
                .font(TextRole.label.font).foregroundStyle(major ? Theme.inkSecondary : Theme.inkTertiary))
            let lw = label.measure(in: CGSize(width: 200, height: 30)).width
            let span = (x + 4)...(x + 4 + lw)
            // Skip labels that would run off the right edge or under the "now" pill.
            if span.upperBound > w || nowPill.map({ span.overlaps(($0.minX - 4)...($0.maxX + 4)) }) == true { continue }
            ctx.draw(label, at: CGPoint(x: x + 4, y: DayLanes.axisH - 3), anchor: .bottomLeading)
        }

        drawFocus(&ctx, vp: vp)

        // Activity lane (LOD over the visible window only).
        let visible = visibleItems(vp)
        var hoveredRect: CGRect?
        let hoverMs = hoverX.map { vp.ms(atX: $0) }
        for item in visible {
            let rect = blockRect(item, vp: vp)
            var c = ctx
            if item.kind == .active {
                c.opacity = DayTimeline.filterOpacity(item.categoryId, from: filterFrom, to: highlight, t: tween.filterProgress)
            }
            drawBlock(&c, item, rect: rect)
            if let hoverMs, item.startMs <= hoverMs, hoverMs < item.endMs { hoveredRect = rect }
        }
        ctx.stroke(rail, with: .style(Theme.hairline), lineWidth: Theme.Stroke.hairline)

        // Edit flash: an ink wash + outline over the edited range, fading out (clipped to the window).
        if let f = editFlash, tween.flashAlpha > 0 {
            let x0 = max(vp.x(f.range.lowerBound), 0), x1 = min(vp.x(f.range.upperBound), w)
            if x1 > x0 {
                let p = Path(roundedRect: CGRect(x: x0, y: DayLanes.laneY, width: max(x1 - x0, 2), height: DayLanes.laneH),
                             cornerRadius: Theme.Radius.block, style: .continuous)
                var c = ctx
                c.opacity = tween.flashAlpha
                c.fill(p, with: .style(Theme.ink.opacity(0.12)))
                c.stroke(p, with: .style(Theme.ink), lineWidth: Theme.Stroke.selection)
            }
        }

        drawProjects(&ctx, vp: vp)

        // Selection (the binding W12 drives).
        if let sel = selectedRange {
            let x0 = vp.x(sel.lowerBound), x1 = vp.x(sel.upperBound)
            let r = CGRect(x: x0, y: DayLanes.laneY - 3, width: max(x1 - x0, 2), height: DayLanes.laneH + 6)
            let p = Path(roundedRect: r, cornerRadius: Theme.Radius.block + 2, style: .continuous)
            ctx.fill(p, with: .style(Theme.ink.opacity(0.06)))
            ctx.stroke(p, with: .style(Theme.ink), lineWidth: Theme.Stroke.selection)
            for hx in [r.minX, r.maxX] {
                ctx.fill(Path(roundedRect: CGRect(x: hx - 2, y: r.midY - 8, width: 4, height: 16), cornerRadius: 2),
                         with: .style(Theme.ink))
            }
        }

        // Now marker (today).
        if let now = data.nowMs, let pill = nowPill, let text = nowText {
            let x = vp.x(now).rounded() + 0.5
            var line = Path()
            line.move(to: CGPoint(x: x, y: pill.maxY))
            line.addLine(to: CGPoint(x: x, y: bottom))
            ctx.stroke(line, with: .style(Theme.ink), lineWidth: 1)
            ctx.fill(Path(roundedRect: pill, cornerRadius: 4, style: .continuous), with: .style(Theme.ink))
            ctx.draw(text, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
        }

        // Hover: crosshair + block outline.
        if let hoverX {
            var line = Path()
            line.move(to: CGPoint(x: hoverX.rounded() + 0.5, y: DayLanes.axisH))
            line.addLine(to: CGPoint(x: hoverX.rounded() + 0.5, y: bottom))
            ctx.stroke(line, with: .style(Theme.ink.opacity(0.35)), lineWidth: 1)
            if let hoveredRect {
                ctx.stroke(Path(roundedRect: hoveredRect.insetBy(dx: -1, dy: -1), cornerRadius: Theme.Radius.block + 1,
                                style: .continuous), with: .style(Theme.ink), lineWidth: 1)
            }
        }
    }

    private func visibleItems(_ vp: DayViewport) -> [DayTimelineItem] {
        let lo = vp.window.startMs, hi = vp.endMs
        let first = DayTimeline.itemIndex(at: lo, in: items) ?? (items.firstIndex { $0.endMs > lo } ?? items.endIndex)
        var slice: [DayTimelineItem] = []
        var i = first
        while i < items.count, items[i].startMs < hi { slice.append(items[i]); i += 1 }
        return DayTimeline.lod(slice, msPerPoint: vp.msPerPoint)
    }

    private func blockRect(_ item: DayTimelineItem, vp: DayViewport) -> CGRect {
        let x0 = vp.x(item.startMs), x1 = vp.x(item.endMs)
        let w = x1 - x0
        let gap: CGFloat = w > 4 ? 1 : 0
        return CGRect(x: x0, y: DayLanes.laneY, width: max(w - gap, 1), height: DayLanes.laneH)
    }

    private func drawBlock(_ ctx: inout GraphicsContext, _ item: DayTimelineItem, rect: CGRect) {
        switch item.kind {
        case .gap:
            let r = rect.insetBy(dx: 1, dy: 3)
            guard r.width > 2 else { return }
            let p = Path(roundedRect: r, cornerRadius: Theme.Radius.block, style: .continuous)
            ctx.fill(p, with: .style(Theme.surface))
            ctx.stroke(p, with: .style(Theme.StateLayer.distraction),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            drawLabels(&ctx, rect: r, title: "Not tracking", detail: Fmt.duration(ms: item.durationMs),
                       titleStyle: Theme.inkSecondary, inset: Theme.Space.s)
        case .idle:
            TimelineBlockStyle.drawIdle(in: &ctx, rect: rect)
            drawLabels(&ctx, rect: rect, title: "Idle", detail: Fmt.duration(ms: item.durationMs),
                       titleStyle: Theme.inkSecondary, inset: Theme.Space.s)
        case .active:
            let style = TimelineBlockStyle(slot: item.slot)
            if rect.width < 6 {
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(1.5, rect.width / 2)), with: .style(style.edge))
                return
            }
            style.draw(in: &ctx, rect: rect)
            if item.isMeeting { drawStipple(&ctx, rect: rect, swatch: style.edge) }
            if item.edited, rect.width >= 12 {
                let s = TimelineBlockStyle.editedMarkSize + 2
                var tri = Path()
                tri.move(to: CGPoint(x: rect.maxX - s, y: rect.minY))
                tri.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                tri.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + s))
                tri.closeSubpath()
                var c = ctx
                c.clip(to: Path(roundedRect: rect, cornerRadius: TimelineBlockStyle.radius, style: .continuous))
                c.fill(tri, with: .style(Theme.ink))
            }
            drawLabels(&ctx, rect: rect, title: title(item), detail: Fmt.duration(ms: item.durationMs),
                       titleStyle: Theme.ink, inset: TimelineBlockStyle.edgeWidth + Theme.Space.s,
                       symbol: item.isMeeting ? "video.fill" : (item.isManual ? "hand.draw" : nil))
        }
    }

    private func title(_ item: DayTimelineItem) -> String {
        if item.count > 1 { return data.categoryName(item.categoryId) }
        guard let i = item.spanIndex else { return "" }
        let s = data.spans[i].span
        if let label = s.label, s.source == .manual { return label }
        if let host = DayRows.host(s.url) { return "\(s.appName) · \(host)" }
        return s.appName
    }

    /// Two lines (name, duration) when the block is wide enough; names truncate with an ellipsis.
    private func drawLabels(_ ctx: inout GraphicsContext, rect: CGRect, title: String, detail: String,
                            titleStyle: Swatch, inset: CGFloat, symbol: String? = nil) {
        let avail = rect.width - inset - Theme.Space.s
        guard avail >= 34 else { return }
        var x = rect.minX + inset
        let y = rect.minY + Theme.Space.s
        if let symbol, avail >= 60 {
            var img = ctx.resolve(Image(systemName: symbol))
            img.shading = .style(Theme.inkSecondary)
            ctx.draw(img, in: CGRect(x: x, y: y + 1.5, width: 12, height: 10))
            x += 16
        }
        if let t = fitted(ctx, title, font: TextRole.label.font, style: titleStyle, width: rect.maxX - Theme.Space.s - x) {
            ctx.draw(t, at: CGPoint(x: x, y: y), anchor: .topLeading)
        }
        if rect.height >= 40,
           let d = fitted(ctx, detail, font: .system(size: 11).monospacedDigit(), style: Theme.inkSecondary,
                          width: rect.maxX - Theme.Space.s - (rect.minX + inset), truncate: false) {
            ctx.draw(d, at: CGPoint(x: rect.minX + inset, y: rect.maxY - Theme.Space.s), anchor: .bottomLeading)
        }
    }

    private func fitted(_ ctx: GraphicsContext, _ s: String, font: Font, style: Swatch, width: CGFloat,
                        truncate: Bool = true) -> GraphicsContext.ResolvedText? {
        let probe = CGSize(width: 10_000, height: 40)
        func resolve(_ str: String) -> GraphicsContext.ResolvedText { ctx.resolve(Text(str).font(font).foregroundStyle(style)) }
        let full = resolve(s)
        if full.measure(in: probe).width <= width { return full }
        guard truncate else { return nil }
        let chars = Array(s)
        var lo = 0, hi = chars.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if resolve(String(chars[..<mid]).trimmingCharacters(in: .whitespaces) + "…").measure(in: probe).width <= width { lo = mid } else { hi = mid - 1 }
        }
        return lo >= 3 ? resolve(String(chars[..<lo]).trimmingCharacters(in: .whitespaces) + "…") : nil
    }

    /// Meeting marker: a stipple in the block's own hue — pattern, not a new colour.
    private func drawStipple(_ ctx: inout GraphicsContext, rect: CGRect, swatch: Swatch) {
        var c = ctx
        c.clip(to: Path(roundedRect: rect.insetBy(dx: TimelineBlockStyle.edgeWidth, dy: 0), cornerRadius: TimelineBlockStyle.radius))
        var dots = Path()
        let pitch: CGFloat = 5
        var row = 0
        var y = rect.minY + 2.5
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 2.5 : 5)
            while x < rect.maxX { dots.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)); x += pitch }
            y += pitch; row += 1
        }
        c.opacity = 0.35
        c.fill(dots, with: .style(swatch))
    }

    /// Focus sessions: an ink bracket over the lane (state as a non-hue mark), labelled when wide.
    private func drawFocus(_ ctx: inout GraphicsContext, vp: DayViewport) {
        let y = DayLanes.focusY + DayLanes.focusH - 4
        for s in data.metrics.focusSessions where s.endMs > vp.window.startMs && s.startMs < vp.endMs {
            let x0 = vp.x(s.startMs), x1 = vp.x(s.endMs)
            var p = Path()
            p.move(to: CGPoint(x: x0 + 0.75, y: y + 5))
            p.addLine(to: CGPoint(x: x0 + 0.75, y: y))
            p.addLine(to: CGPoint(x: x1 - 0.75, y: y))
            p.addLine(to: CGPoint(x: x1 - 0.75, y: y + 5))
            ctx.stroke(p, with: .style(Theme.ink), style: StrokeStyle(lineWidth: TimelineBlockStyle.focusBracketWidth / 1.33,
                                                                       lineCap: .round, lineJoin: .round))
            let label = "Focus · " + Fmt.duration(ms: s.wallMs)
            if let t = fitted(ctx, label, font: TextRole.micro.font, style: Theme.inkSecondary, width: x1 - x0 - 12, truncate: false) {
                let sz = t.measure(in: CGSize(width: 400, height: 20))
                let bg = CGRect(x: x0 + 6 - 3, y: y - sz.height / 2 - 1, width: sz.width + 6, height: sz.height + 2)
                ctx.fill(Path(bg), with: .style(Theme.surface))
                ctx.draw(t, at: CGPoint(x: x0 + 6, y: y), anchor: .leading)
            }
        }
    }

    /// Project lane: a thin monochrome track per project run, name above it when there's room
    /// (projects aren't a colour layer).
    private func drawProjects(_ ctx: inout GraphicsContext, vp: DayViewport) {
        let barY = DayLanes.projectY + DayLanes.projectH - 4
        for run in projectRuns where run.endMs > vp.window.startMs && run.startMs < vp.endMs {
            let x0 = vp.x(run.startMs), x1 = vp.x(run.endMs)
            let r = CGRect(x: x0, y: barY, width: max(x1 - x0 - 1, 1), height: 3)
            ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .style(Theme.inkDisabled))
            if r.width >= 36, let name = data.projectName(run.projectId),
               let t = fitted(ctx, name, font: .system(size: 10, weight: .medium), style: Theme.inkTertiary, width: r.width - 2) {
                ctx.draw(t, at: CGPoint(x: r.minX + 1, y: barY - 2), anchor: .bottomLeading)
            }
        }
    }

    private func isHour(_ ms: Int64) -> Bool {
        let off = Int64(data.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(ms) / 1000))) * 1000
        return (ms + off) % 3_600_000 == 0
    }

    // MARK: Hover + accessibility

    private func tooltip(atX x: CGFloat, vp: DayViewport) -> DayTooltip.Content? {
        guard x >= 0, x <= vp.width else { return nil }
        let ms = vp.ms(atX: x)
        if let i = DayTimeline.spanIndex(at: ms, in: data.spans) {
            let c = data.spans[i]
            let s = c.span
            let idle = s.kind == .idle
            return .init(range: "\(Fmt.clock(ms: s.startMs, timeZone: data.timeZone))–\(Fmt.clock(ms: s.endMs, timeZone: data.timeZone))",
                         duration: Fmt.duration(ms: s.durationMs),
                         title: idle ? "Idle" : (s.source == .manual ? (s.label ?? "Manual entry") : s.appName),
                         detail: idle ? "Away from keyboard" : s.title, host: DayRows.host(s.url),
                         category: idle ? nil : data.categoryName(c.categoryId), slot: idle ? nil : data.slot(c.categoryId),
                         project: data.projectName(c.projectId), edited: !s.editSeqs.isEmpty,
                         live: s.rawSeq == 0 && data.isToday, source: idle ? nil : data.sourceLabel(c))
        }
        if let j = DayTimeline.itemIndex(at: ms, in: items), items[j].kind == .gap {
            let g = items[j]
            return .init(range: "\(Fmt.clock(ms: g.startMs, timeZone: data.timeZone))–\(Fmt.clock(ms: g.endMs, timeZone: data.timeZone))",
                         duration: Fmt.duration(ms: g.durationMs), title: "Not tracking",
                         detail: "The tracker wasn't running — this isn't idle time.", host: nil,
                         category: nil, slot: nil, project: nil, edited: false, live: false)
        }
        return nil
    }

    @ViewBuilder private var accessibilityRows: some View {
        ForEach(Array(DayTimeline.lod(items, msPerPoint: 60_000).enumerated()), id: \.offset) { _, item in
            Text("\(Fmt.clock(ms: item.startMs, timeZone: data.timeZone)) to \(Fmt.clock(ms: item.endMs, timeZone: data.timeZone)), "
                 + "\(item.kind == .gap ? "not tracking" : item.kind == .idle ? "idle" : title(item)), \(Fmt.durationSpoken(ms: item.durationMs))")
        }
    }
}

/// `Canvas` doesn't animate by itself: this carries the tweened values into its draw closure.
/// `window` glides (click-to-zoom, ⌘+/⌘−, fit, mini-strip click). The legend filter and the edit
/// flash are counters that step by 1 per change: callers pass the same value as `…Step` (tweened)
/// and `…Target` (not), and the gap between them is the fade still to run.
struct DayTweenCanvas: View, Animatable {
    var window: DayWindow
    var filterStep: Double = 0, filterTarget: Double = 0
    var flashStep: Double = 0, flashTarget: Double = 0
    let draw: (inout GraphicsContext, CGSize, DayTweenCanvas) -> Void

    nonisolated var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { .init(window.animatableData, .init(filterStep, flashStep)) }
        set {
            window.animatableData = newValue.first
            filterStep = newValue.second.first
            flashStep = newValue.second.second
        }
    }

    /// Legend crossfade, 0 (previous filter) → 1 (current).
    var filterProgress: Double { DayTimeline.tweenProgress(filterStep, to: filterTarget) }
    /// Edit-flash alpha, 1 → 0.
    var flashAlpha: Double { 1 - DayTimeline.tweenProgress(flashStep, to: flashTarget) }

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in draw(&ctx, size, self) }
    }
}

/// The same window tween for SwiftUI content laid over the Canvas (`EditOverlay`).
struct DayTweenWindow<Content: View>: View, Animatable {
    var window: DayWindow
    let content: (DayWindow) -> Content

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { window.animatableData }
        set { window.animatableData = newValue }
    }

    var body: some View { content(window) }
}

extension DayWindow {
    /// (startMs, lengthMs) as Doubles, for the tween wrappers above.
    var animatableData: AnimatablePair<Double, Double> {
        get { .init(Double(startMs), Double(lengthMs)) }
        set { startMs = Int64(newValue.first.rounded()); lengthMs = Int64(newValue.second.rounded()) }
    }
}

struct DayTipValue {
    var content: DayTooltip.Content
    var x: CGFloat
    var bounds: Anchor<CGRect>
}

struct DayTipKey: PreferenceKey {
    static let defaultValue: DayTipValue? = nil
    static func reduce(value: inout DayTipValue?, nextValue: () -> DayTipValue?) { value = value ?? nextValue() }
}

extension View {
    /// Draws the timeline's hover card above this view (apply after the card background/border).
    func dayTooltipOverlay() -> some View {
        overlayPreferenceValue(DayTipKey.self, alignment: .topLeading) { tip in
            GeometryReader { proxy in
                if let tip {
                    let r = proxy[tip.bounds]
                    let left = tip.x + 14 + DayTooltip.width > r.width
                    DayTooltip(content: tip.content)
                        .frame(width: DayTooltip.width, alignment: .leading)
                        .offset(x: r.minX + (left ? tip.x - 14 - DayTooltip.width : tip.x + 14),
                                y: r.minY + DayLanes.laneY + DayLanes.laneH + 10)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Inverted (ink) hover card: time, app, window title, site, category · project.
struct DayTooltip: View {
    static let width: CGFloat = 280

    struct Content: Hashable {
        var range: String, duration: String, title: String
        var detail: String?, host: String?
        var category: String?, slot: Int?, project: String?
        var edited: Bool, live: Bool
        /// Category source: "Rule", "Jev 92 %", "Edited", "Fallback".
        var source: String? = nil
    }

    let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text(content.range).font(TextRole.label.font).foregroundStyle(Theme.inkDisabled)
                Spacer(minLength: 0)
                Text(content.duration).font(TextRole.bodyEmph.font).foregroundStyle(Theme.surface)
            }
            Text(content.title).font(TextRole.bodyEmph.font).foregroundStyle(Theme.surface).lineLimit(1)
            if let d = content.detail, !d.isEmpty {
                Text(d).font(TextRole.label.font).foregroundStyle(Theme.inkDisabled).lineLimit(2)
            }
            if let h = content.host {
                Text(h).font(TextRole.mono.font).foregroundStyle(Theme.inkDisabled).lineLimit(1)
            }
            if content.category != nil || content.project != nil || content.edited || content.live {
                HStack(spacing: Theme.Space.s) {
                    if let c = content.category {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 1.5).fill(Theme.Palette.swatch(slot: content.slot)).frame(width: 7, height: 7)
                            Text(c)
                        }
                    }
                    if let p = content.project { Text("· \(p)") }
                    if let s = content.source { Text("· \(s)").foregroundStyle(Theme.inkDisabled) }
                    Spacer(minLength: 0)
                    if content.edited { Text("± edited").foregroundStyle(Theme.inkDisabled) }
                    if content.live { Text("Live · editable once it closes").foregroundStyle(Theme.inkDisabled) }
                }
                .font(TextRole.label.font).foregroundStyle(Theme.surface)
                .padding(.top, Theme.Space.xxs)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: Theme.Radius.tile - 2, style: .continuous))
    }
}
