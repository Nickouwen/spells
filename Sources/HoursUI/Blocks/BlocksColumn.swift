import SwiftUI
import AppKit
import HoursCore

/// The day as a vertical calendar column: hours down the left, one rounded block per continuous
/// stretch at the computer (tint + a category-mix strip on its left edge, hand-claimed time hatched),
/// labelled breaks in the gaps, the "now" line on today. Blocks under the minimum length are thin
/// micro ticks. One `Canvas`; hit-testing by y.
/// - Hover a block's top or bottom edge for a resize handle; dragging it previews the regrouped
///   extent and commits one edit group on release. Near the page's top/bottom edge it auto-scrolls.
/// - Selected block: ⌘⌥↑/↓ moves its top edge, ⌘⌥⇧↑/↓ its bottom edge, 5 min per press.
/// - S over a block (or right-click → Split Here) splits it at the pointer.
/// Snapping: neighbouring blocks' edges, now, hour/half-hour marks (6 px), else 5 min; ⌥ = free.
struct BlocksColumn: View {
    let data: DayData
    let day: MetricsBlocks.Day
    /// `var`: the zoom glide interpolates its scale (see the `Animatable` conformance below).
    var geo: BlocksGeometry
    let thresholdMs: Int64
    /// Blocks shorter than this draw as micro ticks (0 = none).
    var minBlockMs: Int64 = 0
    let editable: Bool
    @Binding var selectedMs: Int64?
    var commit: (EditPlan) -> Void
    /// "Always for these apps" (context menu): rules for the block's apps → project.
    var saveRules: ((WorkBlock, Int64) -> Void)?
    var preview: BlocksPreview?
    /// A click selected this block (zoom to it).
    var onFocus: ((WorkBlock) -> Void)?
    /// A zoom glide in flight: lay out at its final height, draw shifted (`BlocksGeometry.Glide`).
    var glide: BlocksGeometry.Glide?

    @State private var hover: CGPoint?
    @State private var drag: BlocksDrag?
    /// Pointer offset from the grabbed edge, so the edge doesn't jump to the pointer.
    @State private var grabOffsetMs: Int64 = 0
    @State private var scroll = BlocksScrollBox()
    /// A released edge gliding to where the regrouped block puts it.
    @State private var settle: Settle?
    @FocusState private var focused: Bool
    @Environment(\.hoursEditFlash) private var flash
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The block holding `anchorMs` (its undragged edge) draws its `edge` at the settling time.
    struct Settle: Hashable { var anchorMs: Int64; var edge: EditGesture.Edge; var ms: Int64 }

    static let stripW: CGFloat = 5
    static let edgeZone: CGFloat = 6
    static let snapPx: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let shift = glide?.shift(at: geo.pxPerHour) ?? 0
            let hoverPt = hover ?? preview?.hoverMs.map { CGPoint(x: width / 2, y: geo.y($0)) }
            let liveDrag = drag ?? preview?.drag
            let hotEdge = liveDrag.map { ($0.blockStartMs, $0.edge) } ?? hoverPt.flatMap { edgeHit($0, width: width) }
                .map { ($0.0.startMs, $0.1) }
            let proposal = liveDrag.flatMap(proposal)
            // The edge time animates from the grip (mid-drag, direct) to the settle target on release.
            BlocksCanvas(edgeMs: Double(settle?.ms ?? liveDrag.map { BlocksResize.grip(proposal, drag: $0) } ?? 0)) { ctx, size, edgeMs in
                ctx.translateBy(x: 0, y: shift)
                draw(&ctx, width: size.width, hover: hoverPt, drag: liveDrag, proposal: proposal,
                     hotEdge: hotEdge.map { HotEdge(blockStartMs: $0.0, edge: $0.1) }, settleMs: edgeMs)
            }
            .overlay(alignment: .topLeading) { flashMark(width: width).offset(y: shift) }
            .background(BlocksScrollProbe(box: scroll))
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase {
                    if hover == nil, editable, !(NSApp.keyWindow?.firstResponder is NSTextView) { focused = true }
                    hover = CGPoint(x: p.x, y: p.y - shift)
                } else {
                    hover = nil
                }
            }
            .pointerStyle(editable && hotEdge != nil ? .rowResize : nil)
            .gesture(SpatialTapGesture().onEnded { v in
                let at = CGPoint(x: v.location.x, y: v.location.y - shift)
                let ms = geo.ms(atY: at.y)
                let hit = day.blocks.first { $0.contains(ms) && blockRect($0, width: width).contains(at) }
                selectedMs = hit.flatMap { $0.contains(selectedMs ?? .min) ? nil : ms }
                if let hit, selectedMs != nil { onFocus?(hit) }
                if editable { focused = true }
            })
            .simultaneousGesture(DragGesture(minimumDistance: 2, coordinateSpace: .local)
                .onChanged { v in dragChanged(v, width: width) }
                .onEnded { v in dragEnded(v, width: width) },
                including: editable ? .all : .none)
            .contextMenu { contextMenu }
            .focusable(editable)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { handleKey($0) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityChildren { accessibilityRows }
        }
        .frame(height: glide.map { var g = geo; g.pxPerHour = $0.toPx; return g.height } ?? geo.height)
    }

    // MARK: Interaction

    func isMicro(_ b: WorkBlock) -> Bool { b.wallMs < minBlockMs }

    private func edgeHit(_ p: CGPoint, width: CGFloat) -> (WorkBlock, EditGesture.Edge)? {
        guard editable else { return nil }
        var best: (WorkBlock, EditGesture.Edge, CGFloat)?
        for b in day.blocks where !isMicro(b) {
            let r = blockRect(b, width: width)
            guard p.x >= r.minX, p.x <= r.maxX else { continue }
            let zone = min(Self.edgeZone, max(r.height / 3, 2))
            for (edge, y) in [(EditGesture.Edge.lower, r.minY), (.upper, r.maxY)] where BlocksResize.canDrag(b, edge, data) {
                let d = abs(p.y - y)
                if d <= zone, d < (best?.2 ?? .infinity) { best = (b, edge, d) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// `ms` snapped for `b` (⌥ held = as is).
    private func snapped(_ ms: Int64, for b: WorkBlock) -> Int64 {
        NSEvent.modifierFlags.contains(.option) ? ms
            : BlocksResize.snap(ms, targets: BlocksResize.targets(b, blocks: day.blocks, data: data),
                                toleranceMs: Int64(Self.snapPx / geo.pxPerHour * 3_600_000), timeZone: data.timeZone)
    }

    private func dragChanged(_ v: DragGesture.Value, width: CGFloat) {
        if drag == nil {
            guard let (b, edge) = edgeHit(v.startLocation, width: width) else { return }
            let edgeMs = edge == .lower ? b.startMs : b.endMs
            grabOffsetMs = edgeMs - geo.ms(atY: v.startLocation.y)
            settle = nil
            drag = BlocksDrag(blockStartMs: b.startMs, edge: edge, ms: edgeMs)
            focused = true
        }
        moveDrag(toY: v.location.y)
        startAutoScroll()
    }

    private func moveDrag(toY y: CGFloat) {
        guard var d = drag, let b = day.blocks.first(where: { $0.startMs == d.blockStartMs }) else { return }
        d.ms = snapped(geo.ms(atY: y) + grabOffsetMs, for: b)
        drag = d
    }

    private func dragEnded(_ v: DragGesture.Value, width: CGFloat) {
        dragChanged(v, width: width)
        scroll.stop()
        guard let d = drag, let b = day.blocks.first(where: { $0.startMs == d.blockStartMs }),
              let plan = BlocksResize.plan(b, edge: d.edge, to: d.ms, blocks: day.blocks, data: data, thresholdMs: thresholdMs) else {
            drag = nil
            return
        }
        let p = proposal(d)
        selectedMs = BlocksResize.selection(after: p, block: b)
        // The edge glides from the grip to the regrouped edge (snap) instead of jumping when the data reloads.
        let mine = p.map { Settle(anchorMs: d.edge == .lower ? b.endMs - 1 : b.startMs, edge: d.edge,
                                  ms: d.edge == .lower ? $0.extent.lowerBound : $0.extent.upperBound) }
        withAnimation(Theme.Motion.snap(reduceMotion: reduceMotion)) {
            drag = nil
            settle = mine
        } completion: {
            if settle == mine { settle = nil }   // a later release's settle runs on
        }
        commit(plan)
    }

    private func proposal(_ d: BlocksDrag) -> BlocksResize.Proposal? {
        day.blocks.first { $0.startMs == d.blockStartMs }
            .flatMap { BlocksResize.proposal($0, edge: d.edge, to: d.ms, blocks: day.blocks, data: data, thresholdMs: thresholdMs) }
    }

    /// While the pointer sits near the page's top/bottom edge mid-drag: scroll a step per frame and
    /// re-aim the drag at the pointer (the content moved under it). Ends with the drag.
    private func startAutoScroll() {
        guard scroll.task == nil, scroll.step() != 0 else { return }
        scroll.task = Task { @MainActor in
            while !Task.isCancelled, drag != nil {
                let step = scroll.step()
                if step == 0 { break }
                scroll.scroll(by: step)
                if let y = scroll.pointerY() { moveDrag(toY: y) }
                try? await Task.sleep(for: .milliseconds(16))
            }
            scroll.task = nil
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard editable, drag == nil else { return .ignored }
        // Arrow keys also carry numeric-pad / function flags, so test the ones that matter.
        let mods = press.modifiers
        if press.key == .upArrow || press.key == .downArrow, mods.contains(.command), mods.contains(.option), !mods.contains(.control) {
            guard let ms = selectedMs, let b = day.blocks.first(where: { $0.contains(ms) }) else { return .ignored }
            nudge(b, mods.contains(.shift) ? .upper : .lower, earlier: press.key == .upArrow)
            return .handled
        }
        if press.characters.lowercased() == "s", mods.isDisjoint(with: [.command, .option, .control]), let p = hover {
            let ms = geo.ms(atY: p.y)
            guard let b = day.blocks.first(where: { $0.contains(ms) }) else { return .ignored }
            split(b, at: snapped(ms, for: b))
            return .handled
        }
        return .ignored
    }

    /// One 5-minute edge step, its own undo group; the block stays selected.
    func nudge(_ b: WorkBlock, _ edge: EditGesture.Edge, earlier: Bool) {
        guard let plan = BlocksActions.nudge(b, edge: edge, earlier: earlier, blocks: day.blocks, data: data,
                                             thresholdMs: thresholdMs) else { return }
        let to = (edge == .lower ? b.startMs : b.endMs) + (earlier ? -BlocksActions.nudgeMs : BlocksActions.nudgeMs)
        selectedMs = BlocksResize.selection(after: BlocksResize.proposal(b, edge: edge, to: to, blocks: day.blocks, data: data,
                                                                         thresholdMs: thresholdMs), block: b)
        commit(plan)
    }

    private func split(_ b: WorkBlock, at ms: Int64) {
        guard let plan = BlocksActions.split(b, at: ms, data: data, thresholdMs: thresholdMs) else { return }
        selectedMs = nil
        commit(plan)
    }

    /// Right-click on a block: split at the pointer, project, project + rules for its apps.
    @ViewBuilder private var contextMenu: some View {
        if editable, let p = hover, let b = day.blocks.first(where: { $0.contains(geo.ms(atY: p.y)) }) {
            let at = snapped(geo.ms(atY: p.y), for: b)
            Button("Split Here (\(Fmt.clock(ms: at, timeZone: data.timeZone)))") { split(b, at: at) }
                .disabled(BlocksActions.split(b, at: at, data: data, thresholdMs: thresholdMs) == nil)
            let projects = data.projects.filter { !$0.archived }
            Menu("Project") {
                ForEach(projects) { pr in
                    Button(pr.name) { if let plan = BlocksActions.assignProject(b, pr.id, data: data) { commit(plan) } }
                }
            }
            if let saveRules, let label = BlocksActions.ruleLabel(b, data: data) {
                Menu("Project, Always for \(label)") {
                    ForEach(projects) { pr in
                        Button(pr.name) {
                            guard let plan = BlocksActions.assignProject(b, pr.id, data: data) else { return }
                            commit(plan)
                            saveRules(b, pr.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: Geometry

    func blockRect(_ b: WorkBlock, width: CGFloat) -> CGRect { blockRect(b.startMs..<b.endMs, width: width) }

    func blockRect(_ r: Range<Int64>, width: CGFloat) -> CGRect {
        let y0 = geo.y(r.lowerBound), y1 = geo.y(r.upperBound)
        let x0 = BlocksGeometry.gutter + Theme.Space.s
        return CGRect(x: x0, y: y0 + 0.5, width: width - x0 - Theme.Space.xxs, height: max(y1 - y0 - 1, 2))
    }

    /// A micro block: a short 3 pt bar at its time, in its category colour.
    func microRect(_ b: WorkBlock, rect r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: r.midY - 1.5, width: min(36, r.width), height: 3)
    }

    struct HotEdge: Hashable { var blockStartMs: Int64; var edge: EditGesture.Edge }

    /// Hand-claimed time inside `b` (manual spans, clipped to it), drawn hatched.
    static func claimed(_ b: WorkBlock, _ data: DayData) -> [Range<Int64>] {
        data.spans.compactMap { c in
            let s = c.span
            guard s.source == .manual, s.kind == .active, s.endMs > b.startMs, s.startMs < b.endMs,
                  data.category(c.categoryId)?.behavior != .exclude else { return nil }
            return max(s.startMs, b.startMs)..<min(s.endMs, b.endMs)
        }
    }

    /// 45° lines in `color`, 6 pt pitch, clipped to `r`: hand-claimed time (and the claim ghost).
    static func hatch(_ ctx: inout GraphicsContext, _ r: CGRect, _ color: Swatch, alpha: Double = 0.4) {
        guard r.height > 0, r.width > 0 else { return }
        var c = ctx
        c.clip(to: Path(r))
        var lines = Path()
        var x = r.minX - r.height
        while x < r.maxX {
            lines.move(to: CGPoint(x: x, y: r.maxY))
            lines.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += TimelineBlockStyle.hatchPitch
        }
        c.stroke(lines, with: .style(color.opacity(alpha)), lineWidth: 1)
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, width: CGFloat, hover: CGPoint?, drag: BlocksDrag?,
                      proposal: BlocksResize.Proposal?, hotEdge: HotEdge?, settleMs: Int64) {
        let tz = data.timeZone
        let x0 = BlocksGeometry.gutter + Theme.Space.s
        let nowY = data.nowMs.flatMap { $0 >= geo.startMs && $0 <= geo.endMs ? geo.y($0) : nil }
        // The pointer's time, read off the gutter (not while dragging: the ghost shows its own times).
        let pointerY = drag == nil ? hover.map { min(max($0.y, geo.y(geo.startMs)), geo.y(geo.endMs)) } : nil

        // Hour grid: a hairline per hour, a fainter one per half hour when there's room; labels in the gutter.
        for t in geo.hours(tz) {
            let y = geo.y(t).rounded() + 0.25
            var line = Path()
            line.move(to: CGPoint(x: BlocksGeometry.gutter - 2, y: y))
            line.addLine(to: CGPoint(x: width, y: y))
            ctx.stroke(line, with: .style(Theme.hairline), lineWidth: Theme.Stroke.hairline)
            if geo.pxPerHour >= 64, t + 1_800_000 < geo.endMs {
                let hy = geo.y(t + 1_800_000).rounded() + 0.25
                var half = Path()
                half.move(to: CGPoint(x: x0, y: hy))
                half.addLine(to: CGPoint(x: width, y: hy))
                ctx.stroke(half, with: .style(Theme.hairline.over(Theme.surface, alpha: 0.5)),
                           style: StrokeStyle(lineWidth: Theme.Stroke.hairline, dash: [2, 3]))
            }
            if let nowY, abs(nowY - y) < 11 { continue }
            if let pointerY, abs(pointerY - y) < 11 { continue }
            let label = ctx.resolve(Text(Fmt.clock(ms: t, timeZone: tz))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.inkTertiary))
            ctx.draw(label, at: CGPoint(x: BlocksGeometry.gutter - 8, y: y), anchor: .trailing)
        }

        // Pointer guide under the blocks (shows in the gaps); its time pill is drawn last.
        if let pointerY {
            let y = pointerY.rounded() + 0.5
            var line = Path()
            line.move(to: CGPoint(x: BlocksGeometry.gutter - 2, y: y))
            line.addLine(to: CGPoint(x: width, y: y))
            ctx.stroke(line, with: .style(Theme.ink.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        // A break the drag is claiming loses its label under the ghost.
        for br in day.breaks {
            let covered = proposal.map { $0.kind != .trim && $0.changed.overlaps(br.startMs..<br.endMs) } ?? false
            drawBreak(&ctx, br, x0: x0, width: width, label: !covered)
        }

        let hoverMs = hover.map { geo.ms(atY: $0.y) }
        let hovered = hover.flatMap { p in day.blocks.first { blockRect($0, width: width).insetBy(dx: 0, dy: -Self.edgeZone).contains(p) } }
        for b in day.blocks {
            var r = blockRect(b, width: width)
            if let settle, b.contains(settle.anchorMs) {
                r = blockRect(BlocksResize.moving(b.startMs..<b.endMs, settle.edge, to: settleMs), width: width)
            }
            let selected = selectedMs.map { b.contains($0) } ?? false
            if isMicro(b) {
                let tick = microRect(b, rect: r)
                ctx.fill(Path(roundedRect: tick, cornerRadius: tick.height / 2),
                         with: .style(Theme.Palette.swatch(slot: data.slot(b.dominantCategoryId))))
                if selected || (hovered == b && drag == nil) {
                    ctx.stroke(Path(roundedRect: tick.insetBy(dx: -2, dy: -2), cornerRadius: tick.height / 2 + 2),
                               with: selected ? .style(Theme.ink) : .style(Theme.ink.opacity(0.6)), lineWidth: selected ? Theme.Stroke.selection : 1)
                }
                continue
            }
            var c = ctx
            if let drag, drag.blockStartMs == b.startMs { c.opacity = 0.75 }
            drawBlock(&c, b, rect: r)
            if selected {
                ctx.stroke(Path(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), cornerRadius: Theme.Radius.block + 1.5, style: .continuous),
                           with: .style(Theme.ink), lineWidth: Theme.Stroke.selection)
            } else if hovered == b, drag == nil, hoverMs != nil {
                ctx.stroke(Path(roundedRect: r.insetBy(dx: -1, dy: -1), cornerRadius: Theme.Radius.block + 1, style: .continuous),
                           with: .style(Theme.ink.opacity(0.6)), lineWidth: 1)
            }
            if editable, drag == nil, hovered == b || selected {
                drawHandles(&ctx, b, rect: r, hot: hotEdge?.blockStartMs == b.startMs ? hotEdge?.edge : nil)
            }
        }

        if let drag, let b = day.blocks.first(where: { $0.startMs == drag.blockStartMs }) {
            drawGhost(&ctx, b, drag: drag, proposal: proposal, width: width)
        }

        if let now = data.nowMs, let nowY {
            let y = nowY.rounded() + 0.5
            var line = Path()
            line.move(to: CGPoint(x: BlocksGeometry.gutter - 2, y: y))
            line.addLine(to: CGPoint(x: width, y: y))
            ctx.stroke(line, with: .style(Theme.ink), lineWidth: 1)
            let text = ctx.resolve(Text(Fmt.clock(ms: now, timeZone: tz)).font(TextRole.micro.font).foregroundStyle(Theme.surface))
            let sz = text.measure(in: CGSize(width: 100, height: 20))
            let pill = CGRect(x: BlocksGeometry.gutter - sz.width - 12, y: y - 8, width: sz.width + 10, height: 16)
            ctx.fill(Path(roundedRect: pill, cornerRadius: 4, style: .continuous), with: .style(Theme.ink))
            ctx.draw(text, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
        }

        // Pointer time: the "now" pill's shape, quiet (raised surface, ink text), drawn over it when they meet.
        if let pointerY {
            let y = pointerY.rounded() + 0.5
            let text = ctx.resolve(Text(Fmt.clock(ms: geo.ms(atY: pointerY), timeZone: tz)).font(TextRole.micro.font).foregroundStyle(Theme.ink))
            let sz = text.measure(in: CGSize(width: 100, height: 20))
            let pill = Path(roundedRect: CGRect(x: BlocksGeometry.gutter - sz.width - 12, y: y - 8, width: sz.width + 10, height: 16),
                            cornerRadius: 4, style: .continuous)
            ctx.fill(pill, with: .style(Theme.surfaceRaised))
            ctx.stroke(pill, with: .style(Theme.hairline), lineWidth: Theme.Stroke.hairline)
            ctx.draw(text, at: CGPoint(x: BlocksGeometry.gutter - sz.width / 2 - 7, y: y), anchor: .center)
        }
    }

    private func drawBlock(_ ctx: inout GraphicsContext, _ b: WorkBlock, rect r: CGRect) {
        let style = TimelineBlockStyle(slot: data.slot(b.dominantCategoryId))
        let shape = Path(roundedRect: r, cornerRadius: min(Theme.Radius.block, r.height / 2), style: .continuous)
        if TimelineBlockStyle.isCollapsed(height: r.height) {
            ctx.fill(shape, with: .style(style.edge))
            return
        }
        ctx.fill(shape, with: .style(style.tint))
        var inner = ctx
        inner.clip(to: shape)
        // Category-mix strip: each active span at its own height, in its category colour; idle and
        // short gaps inside the block show as notches. Hand-claimed (manual) spans are hatched.
        let strip = CGRect(x: r.minX, y: r.minY, width: Self.stripW, height: r.height)
        inner.fill(Path(strip), with: .style(Theme.surface))
        var lastEnd = b.startMs
        for c in data.spans where c.span.kind == .active && c.span.endMs > b.startMs && c.span.startMs < b.endMs {
            guard data.category(c.categoryId)?.behavior != .exclude else { continue }
            let y0 = geo.y(max(c.span.startMs, b.startMs)), y1 = geo.y(min(c.span.endMs, b.endMs))
            inner.fill(Path(CGRect(x: r.minX, y: y0, width: Self.stripW, height: max(y1 - y0, 0.75))),
                       with: .style(Theme.Palette.swatch(slot: data.slot(c.categoryId))))
            // Short idle / untracked stretches that didn't break the block: a faint band across it.
            let gy = geo.y(lastEnd)
            if y0 - gy >= 4 {
                inner.fill(Path(CGRect(x: r.minX + Self.stripW, y: gy, width: r.width, height: y0 - gy)),
                           with: .style(Theme.surface.opacity(0.5)))
            }
            lastEnd = max(lastEnd, c.span.endMs)
        }
        for cl in Self.claimed(b, data) {
            let y0 = geo.y(cl.lowerBound), y1 = geo.y(cl.upperBound)
            Self.hatch(&inner, CGRect(x: r.minX + Self.stripW, y: y0, width: r.width - Self.stripW, height: y1 - y0), style.edge)
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
        drawLabels(&ctx, b, rect: r)
    }

    /// Title (project, else category), then `duration · range`; on tall blocks the top apps on the
    /// right and the category mix underneath. Short blocks get one line, tiny ones none.
    private func drawLabels(_ ctx: inout GraphicsContext, _ b: WorkBlock, rect r: CGRect) {
        let tz = data.timeZone
        let live = BlocksResize.isLive(b, data)
        let x = r.minX + Self.stripW + Theme.Space.s
        let right = r.maxX - Theme.Space.s - (b.hasEdits ? TimelineBlockStyle.editedMarkSize : 0)
        guard right - x >= 40, r.height >= 18 else { return }
        let title = BlocksResize.label(b, data)
        let range = "\(Fmt.clock(ms: b.startMs, timeZone: tz))–\(live ? "now" : Fmt.clock(ms: b.endMs, timeZone: tz))"
        let duration = Fmt.duration(ms: b.wallMs)
        let titleFont = Font.system(size: 12.5, weight: .semibold)
        let detailFont = TextRole.label.font

        if r.height < 38 {
            // One line: title, then the duration in secondary ink.
            let y = r.minY + min(r.height / 2, 11)
            let d = ctx.resolve(Text("\(duration) · \(range)").font(detailFont).foregroundStyle(Theme.inkSecondary))
            let dw = d.measure(in: CGSize(width: 400, height: 20)).width
            let tWidth = right - x - (dw + Theme.Space.s <= (right - x) * 0.6 ? dw + Theme.Space.s : 0)
            guard let t = BlocksText.fitted(ctx, title, font: titleFont, style: Theme.ink, width: tWidth) else { return }
            ctx.draw(t, at: CGPoint(x: x, y: y), anchor: .leading)
            if tWidth < right - x {
                let tw = t.measure(in: CGSize(width: 400, height: 20)).width
                ctx.draw(d, at: CGPoint(x: x + tw + Theme.Space.s, y: y), anchor: .leading)
            }
            return
        }

        // Top-right: the block's top apps / sites, when there's room beside the title.
        var titleWidth = right - x
        if r.width >= 380, !b.topContexts.isEmpty {
            let names = b.topContexts.map(\.name).joined(separator: " · ")
            if let apps = BlocksText.fitted(ctx, names, font: detailFont, style: Theme.inkTertiary, width: (right - x) * 0.45) {
                let w = apps.measure(in: CGSize(width: 1000, height: 20)).width
                ctx.draw(apps, at: CGPoint(x: right, y: r.minY + 7.5), anchor: .topTrailing)
                titleWidth -= w + Theme.Space.m
            }
        }
        if let t = BlocksText.fitted(ctx, title, font: titleFont, style: Theme.ink, width: titleWidth) {
            ctx.draw(t, at: CGPoint(x: x, y: r.minY + 6), anchor: .topLeading)
        }
        let detail = Text(duration).font(detailFont.weight(.semibold)).foregroundStyle(Theme.ink)
            + Text("  \(range)").font(detailFont).foregroundStyle(Theme.inkSecondary)
        ctx.draw(ctx.resolve(detail), at: CGPoint(x: x, y: r.minY + 23), anchor: .topLeading)

        // Category mix, as swatch + name + share, while the block is tall enough.
        guard r.height >= 66, b.activeMs > 0 else { return }
        var cx = x
        let cy = r.minY + 44
        for share in b.byCategory.prefix(3) {
            let pct = Fmt.percent(Double(share.ms) / Double(b.activeMs))
            let t = ctx.resolve(Text("\(data.categoryName(share.key)) \(pct)").font(detailFont).foregroundStyle(Theme.inkSecondary))
            let w = t.measure(in: CGSize(width: 400, height: 20)).width
            guard cx + 10 + w <= right else { break }
            ctx.fill(Path(roundedRect: CGRect(x: cx, y: cy + 3.5, width: 6, height: 6), cornerRadius: 1.5),
                     with: .style(Theme.Palette.swatch(slot: data.slot(share.key))))
            ctx.draw(t, at: CGPoint(x: cx + 10, y: cy), anchor: .topLeading)
            cx += 10 + w + Theme.Space.m
        }
    }

    /// "Break · 45m" (idle: the tracker saw no input) or a dashed "Not tracking · 1h 10m" box.
    private func drawBreak(_ ctx: inout GraphicsContext, _ br: BlockBreak, x0: CGFloat, width: CGFloat, label: Bool) {
        let y0 = geo.y(br.startMs), y1 = geo.y(br.endMs)
        let box = CGRect(x: x0, y: y0 + 3, width: width - x0 - Theme.Space.xxs, height: y1 - y0 - 6)
        let away = br.kind == .away
        if !away, box.height >= 6 {
            let p = Path(roundedRect: box, cornerRadius: min(Theme.Radius.block, box.height / 2), style: .continuous)
            ctx.fill(p, with: .style(Theme.surface))
            ctx.stroke(p, with: .style(Theme.StateLayer.distraction), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        guard label, y1 - y0 >= 16 else { return }
        let text = Text(away ? "Break" : "Not tracking").font(TextRole.label.font).foregroundStyle(Theme.inkSecondary)
            + Text(" · \(Fmt.duration(ms: br.durationMs))").font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
        let resolved = ctx.resolve(text)
        let sz = resolved.measure(in: CGSize(width: 400, height: 20))
        let midY = (y0 + y1) / 2
        let lx = x0 + Self.stripW + Theme.Space.s
        var icon = ctx.resolve(Image(systemName: away ? "cup.and.saucer" : "pause.circle"))
        icon.shading = .style(Theme.inkTertiary)
        if away {
            // A hairline rule through the gap, broken by the label.
            var rule = Path()
            rule.move(to: CGPoint(x: lx + 18 + sz.width + Theme.Space.s, y: midY.rounded() + 0.25))
            rule.addLine(to: CGPoint(x: width - Theme.Space.xxs, y: midY.rounded() + 0.25))
            ctx.stroke(rule, with: .style(Theme.hairline), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        }
        ctx.draw(icon, in: CGRect(x: lx, y: midY - 6, width: 13, height: 12))
        ctx.draw(resolved, at: CGPoint(x: lx + 18, y: midY), anchor: .leading)
    }

    /// Resize grips centred on the top and bottom edges; ink when hot. None on the live block's bottom.
    private func drawHandles(_ ctx: inout GraphicsContext, _ b: WorkBlock, rect r: CGRect, hot: EditGesture.Edge?) {
        guard r.height >= 12 else { return }
        for (edge, y) in [(EditGesture.Edge.lower, r.minY), (.upper, r.maxY)] where BlocksResize.canDrag(b, edge, data) {
            let isHot = hot == edge
            let w: CGFloat = isHot ? 36 : 28
            let grip = CGRect(x: r.midX - w / 2, y: y - 2.5, width: w, height: 5)
            ctx.fill(Path(roundedRect: grip.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4), with: .style(Theme.surface))
            ctx.fill(Path(roundedRect: grip, cornerRadius: 2.5), with: .style(isHot ? Theme.ink : Theme.inkDisabled))
        }
    }

    /// The extent the drag would leave (regrouped: a merge spans the neighbour): claimed time tinted
    /// and hatched, trimmed time faded, a dashed outline, plus the readout on the edge.
    private func drawGhost(_ ctx: inout GraphicsContext, _ b: WorkBlock, drag: BlocksDrag, proposal p: BlocksResize.Proposal?,
                           width: CGFloat) {
        let r = blockRect(b, width: width)
        if let p {
            let ext = CGRect(x: r.minX, y: geo.y(p.extent.lowerBound) + 0.5, width: r.width,
                             height: max(geo.y(p.extent.upperBound) - geo.y(p.extent.lowerBound) - 1, 2))
            let style = TimelineBlockStyle(slot: data.slot(b.dominantCategoryId))
            var c = ctx
            c.clip(to: Path(roundedRect: p.kind == .trim ? r : ext, cornerRadius: Theme.Radius.block, style: .continuous))
            if p.kind == .trim {
                let changed = CGRect(x: r.minX, y: geo.y(p.changed.lowerBound), width: r.width,
                                     height: geo.y(p.changed.upperBound) - geo.y(p.changed.lowerBound))
                c.fill(Path(changed), with: .style(Theme.surface.opacity(0.75)))
            } else {
                for f in p.fills {
                    let fr = CGRect(x: r.minX, y: geo.y(f.lowerBound), width: r.width, height: geo.y(f.upperBound) - geo.y(f.lowerBound))
                    c.fill(Path(fr), with: .style(style.tint))
                    c.fill(Path(CGRect(x: fr.minX, y: fr.minY, width: Self.stripW, height: fr.height)), with: .style(style.edge))
                    Self.hatch(&c, fr, style.edge, alpha: 0.3)
                }
            }
            ctx.stroke(Path(roundedRect: ext.insetBy(dx: -1.5, dy: -1.5), cornerRadius: Theme.Radius.block + 1.5, style: .continuous),
                       with: .style(Theme.ink), style: StrokeStyle(lineWidth: Theme.Stroke.selection, dash: [5, 3]))
        }
        // The grip, at the drag's real edge: the regrouped edge for a trim, the dragged-to time for a claim.
        let gy = geo.y(BlocksResize.grip(p, drag: drag))
        let grip = CGRect(x: r.midX - 18, y: gy - 2.5, width: 36, height: 5)
        ctx.fill(Path(roundedRect: grip.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4), with: .style(Theme.surface))
        ctx.fill(Path(roundedRect: grip, cornerRadius: 2.5), with: .style(Theme.ink))

        let t = ctx.resolve(Text(BlocksResize.readout(p, edge: drag.edge, block: b, data: data))
            .font(TextRole.label.font).foregroundStyle(Theme.surface))
        let sz = t.measure(in: CGSize(width: 400, height: 20))
        let pill = CGRect(x: r.maxX - sz.width - 12 - Theme.Space.s, y: gy - sz.height / 2 - 3, width: sz.width + 12, height: sz.height + 6)
        ctx.fill(Path(roundedRect: pill, cornerRadius: 5, style: .continuous), with: .style(Theme.ink))
        ctx.draw(t, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
    }

    // MARK: Edit flash

    /// The last edit's range: an ink wash and outline over the column, fading out (none with Reduce Motion).
    private func flashMark(width: CGFloat) -> some View {
        let r = flash.map { blockRect($0.range, width: width) } ?? .zero
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.block, style: .continuous)
        return shape.fill(Theme.ink.opacity(0.08))
            .overlay(shape.strokeBorder(Theme.ink.opacity(0.5), lineWidth: 1))
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
            .keyframeAnimator(initialValue: 0.0, trigger: flash?.id) { mark, alpha in
                mark.opacity(reduceMotion ? 0 : alpha)
            } keyframes: { _ in
                Self.flashFade
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Full ink, then an ease-out fade over `Theme.Motion.flash`.
    static var flashFade: KeyframeTrack<Double, Double, some KeyframeTrackContent<Double>> {
        KeyframeTrack {
            MoveKeyframe(1.0)
            LinearKeyframe(0.0, duration: Theme.Motion.flash, timingCurve: .easeOut)
        }
    }

    // MARK: Accessibility

    private var accessibilitySummary: String {
        let n = day.blocks.filter { !isMicro($0) }.count
        return "Blocks, \(n) block\(n == 1 ? "" : "s"), \(day.breaks.count) break\(day.breaks.count == 1 ? "" : "s")"
    }

    /// One row per block; with editing, custom actions move its edges 5 min (as ⌘⌥↑/↓, ⌘⌥⇧↑/↓ do).
    @ViewBuilder private var accessibilityRows: some View {
        ForEach(day.blocks, id: \.startMs) { b in
            Text("\(BlocksResize.label(b, data)), \(Fmt.clock(ms: b.startMs, timeZone: data.timeZone)) to "
                 + "\(Fmt.clock(ms: b.endMs, timeZone: data.timeZone)), \(Fmt.durationSpoken(ms: b.wallMs))")
                .accessibilityActions {
                    if editable {
                        Button("Start 5 minutes earlier") { nudge(b, .lower, earlier: true) }
                        Button("Start 5 minutes later") { nudge(b, .lower, earlier: false) }
                        if BlocksResize.canDrag(b, .upper, data) {
                            Button("End 5 minutes earlier") { nudge(b, .upper, earlier: true) }
                            Button("End 5 minutes later") { nudge(b, .upper, earlier: false) }
                        }
                    }
                }
        }
    }
}

/// Zoom glide: SwiftUI interpolates the scale, so the frame height (the scroll content), the drawing
/// and hit-testing all follow it frame by frame.
extension BlocksColumn: Animatable {
    nonisolated var animatableData: CGFloat {
        get { geo.pxPerHour }
        set { geo.pxPerHour = newValue }
    }
}

/// The column's Canvas, `Animatable` over a released edge's time so it glides (a Canvas doesn't
/// animate by itself). `edgeMs` is a Double so it interpolates.
struct BlocksCanvas: View, Animatable {
    var edgeMs: Double
    let draw: (inout GraphicsContext, CGSize, Int64) -> Void

    nonisolated var animatableData: Double {
        get { edgeMs }
        set { edgeMs = newValue }
    }

    /// The time the edge draws at.
    var edge: Int64 { Int64(edgeMs.rounded()) }

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in draw(&ctx, size, edge) }
    }
}

enum BlocksText {
    /// `s` in `font`, ellipsised to `width`; nil when not even three characters fit.
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
