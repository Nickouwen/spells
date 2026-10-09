import SwiftUI
import HoursCore

/// Timeline card: 24 h overview strip + zoom controls, the Canvas timeline, then legend chips
/// (click = dim the other categories) and the key for the non-colour marks.
struct DayTimelineCard: View {
    let data: DayData
    @Binding var window: DayWindow
    @Binding var selectedRange: ClosedRange<Int64>?
    @Binding var highlight: Int64??
    var previewHoverMs: Int64?
    var editHooks: DayEditHooks?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let items = DayTimeline.items(data)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                Text("Timeline").textRole(.heading).padding(.top, 3)
                Spacer(minLength: Theme.Space.l)
                DayMiniStrip(data: data, items: items, window: $window)
                    .frame(maxWidth: 520)
                zoomControls
            }
            DayTimelineCanvas(data: data, items: items, projectRuns: DayTimeline.projectRuns(data.spans),
                              window: $window, selectedRange: $selectedRange, highlight: highlight,
                              previewHoverMs: previewHoverMs, editHooks: editHooks)
            // Narrow windows: the mark key drops under the chips instead of squeezing them.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Theme.Space.l) {
                    legend.fixedSize()
                    Spacer(minLength: Theme.Space.l)
                    keys.fixedSize()
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    legend
                    keys
                }
            }
        }
        .hoursCard(padding: Theme.Space.l, radius: Theme.Radius.panel)
        .dayTooltipOverlay()
    }

    /// Top categories of the day, as filter chips.
    private var legend: some View {
        FlowLayout(spacing: Theme.Space.xs + Theme.Space.xxs) {
            ForEach(DayRows.categories(data).prefix(6)) { row in
                let id = data.metrics.byCategory.first { "c\($0.key ?? -1)" == row.id }?.key
                Button {
                    highlight = highlight == .some(id) ? nil : .some(id)
                } label: {
                    CategoryChip(name: row.name, slot: row.slot, isOn: highlight == .some(id))
                        .opacity(highlight == nil || highlight == .some(id) ? 1 : 0.55)
                        .animation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion), value: highlight)
                }
                .buttonStyle(.plain)
                .help("Show only \(row.name)")
            }
        }
        .lineLimit(1)
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            DayIconButton(symbol: "minus", help: "Zoom out (⌘−)") { zoom(1 / 1.5) }
                .keyboardShortcut("-", modifiers: .command)
            Text(Fmt.duration(ms: window.lengthMs))
                .font(TextRole.label.font).foregroundStyle(Theme.inkSecondary)
                .frame(minWidth: 58)
            DayIconButton(symbol: "plus", help: "Zoom in (⌘+)") { zoom(1.5) }
                .keyboardShortcut("=", modifiers: .command)
            Rectangle().fill(Theme.hairline).frame(width: Theme.Stroke.hairline, height: 16)
                .padding(.horizontal, Theme.Space.xs)
            DayIconButton(symbol: "arrow.left.and.right", help: "Fit the day (⌘0)") {
                withAnimation(Theme.Motion.snap(reduceMotion: reduceMotion)) { window = DayWindow.fit(data) }
            }
                .keyboardShortcut("0", modifiers: .command)
        }
        .padding(.horizontal, Theme.Space.xxs)
        .frame(height: 26)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous))
    }

    private func zoom(_ f: Double) {
        withAnimation(Theme.Motion.snap(reduceMotion: reduceMotion)) {
            window = window.zoomed(by: f, anchorMs: window.startMs + window.lengthMs / 2, in: data.bounds)
        }
    }

    /// Key for the marks that aren't category colours.
    private var keys: some View {
        HStack(spacing: Theme.Space.m) {
            key("Focus") { DayFocusGlyph() }
            key("Meeting") {
                RoundedRectangle(cornerRadius: 2).fill(Theme.surfaceRaised)
                    .overlay(DayStippleGlyph())
                    .frame(width: 14, height: 9)
            }
            key("Idle") {
                Canvas { ctx, size in TimelineBlockStyle.drawIdle(in: &ctx, rect: CGRect(origin: .zero, size: size)) }
                    .frame(width: 14, height: 9)
            }
            key("Not tracking") {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Theme.StateLayer.distraction, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 14, height: 9)
            }
            key("Edited") {
                DayEditedGlyph().frame(width: 8, height: 8)
            }
        }
    }

    private func key<G: View>(_ name: String, @ViewBuilder glyph: () -> G) -> some View {
        HStack(spacing: Theme.Space.xs + 1) {
            glyph()
            Text(name).font(TextRole.label.font).foregroundStyle(Theme.inkSecondary)
        }
    }
}

struct DayFocusGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 0.75, y: size.height))
            p.addLine(to: CGPoint(x: 0.75, y: 1))
            p.addLine(to: CGPoint(x: size.width - 0.75, y: 1))
            p.addLine(to: CGPoint(x: size.width - 0.75, y: size.height))
            ctx.stroke(p, with: .style(Theme.ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 14, height: 6)
    }
}

struct DayStippleGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            var dots = Path()
            var y: CGFloat = 2
            while y < size.height { var x: CGFloat = 2; while x < size.width { dots.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)); x += 4 }; y += 3.5 }
            ctx.fill(dots, with: .style(Theme.inkSecondary))
        }
    }
}

struct DayEditedGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            var tri = Path()
            tri.move(to: .zero); tri.addLine(to: CGPoint(x: size.width, y: 0)); tri.addLine(to: CGPoint(x: size.width, y: size.height))
            tri.closeSubpath()
            ctx.fill(tri, with: .style(Theme.ink))
        }
    }
}

/// 26 pt borderless icon button, ink glyph.
struct DayIconButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(disabled ? Theme.inkDisabled : Theme.ink)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

/// The whole day (04:00 → 04:00) as a thin strip, with the visible window boxed. Click or drag moves the window.
struct DayMiniStrip: View {
    let data: DayData
    let items: [DayTimelineItem]
    @Binding var window: DayWindow
    static let stripH: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            // Whole-day mapping and blocks are fixed across a glide: computed here, not per frame.
            let full = DayViewport(window: DayWindow(startMs: data.bounds.lowerBound,
                                                     lengthMs: data.bounds.upperBound - data.bounds.lowerBound), width: w)
            let blocks = DayTimeline.lod(items, msPerPoint: full.msPerPoint, minWidth: 1.5)
            // The window box glides with the timeline (same tween).
            DayTweenCanvas(window: window) { ctx, size, tween in
                let window = tween.window
                let strip = CGRect(x: 0, y: 0, width: size.width, height: Self.stripH)
                let rail = Path(roundedRect: strip, cornerRadius: 3, style: .continuous)
                ctx.fill(rail, with: .style(Theme.canvas))
                var inner = ctx
                inner.clip(to: rail)
                for item in blocks where item.kind != .gap {
                    let x0 = full.x(item.startMs), x1 = full.x(item.endMs)
                    let r = CGRect(x: x0, y: 0, width: max(x1 - x0, 0.75), height: Self.stripH)
                    inner.fill(Path(r), with: .style(item.kind == .idle ? Theme.inkDisabled.over(Theme.canvas, alpha: 0.5)
                                                                         : Theme.Palette.swatch(slot: item.slot)))
                }
                // Dim outside the window; box the window.
                let vx0 = full.x(window.startMs), vx1 = full.x(window.startMs + window.lengthMs)
                inner.fill(Path(CGRect(x: 0, y: 0, width: vx0, height: Self.stripH)), with: .style(Theme.surface.opacity(0.6)))
                inner.fill(Path(CGRect(x: vx1, y: 0, width: size.width - vx1, height: Self.stripH)), with: .style(Theme.surface.opacity(0.6)))
                ctx.stroke(rail, with: .style(Theme.hairline), lineWidth: Theme.Stroke.hairline)
                let box = CGRect(x: vx0, y: -2, width: max(vx1 - vx0, 4), height: Self.stripH + 4)
                ctx.stroke(Path(roundedRect: box, cornerRadius: 4, style: .continuous), with: .style(Theme.ink), lineWidth: 1.25)
                // 6-hourly labels.
                for h in stride(from: 0, through: 24, by: 4) {
                    let t = data.bounds.lowerBound + Int64(h) * 3_600_000
                    let x = full.x(t)
                    let label = ctx.resolve(Text(Fmt.clock(ms: t, timeZone: data.timeZone))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.inkTertiary))
                    let anchor: UnitPoint = h == 0 ? .topLeading : (h == 24 ? .topTrailing : .top)
                    ctx.draw(label, at: CGPoint(x: x, y: Self.stripH + 5), anchor: anchor)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let total = data.bounds.upperBound - data.bounds.lowerBound
                let center = data.bounds.lowerBound + Int64(Double(v.location.x / max(w, 1)) * Double(total))
                // The press (a click) glides; the drag that may follow is direct.
                withAnimation(v.translation == .zero ? Theme.Motion.snap(reduceMotion: reduceMotion) : nil) {
                    window = DayWindow(startMs: center - window.lengthMs / 2, lengthMs: window.lengthMs).clamped(to: data.bounds)
                }
            })
            .accessibilityHidden(true)
        }
        .frame(height: Self.stripH + 18)
    }
}
