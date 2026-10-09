import SwiftUI
import AppKit
import HoursCore

/// Editing overlay on the Day timeline, in the Canvas's coordinate space: extra selected ranges,
/// drag previews + a time readout, edge handles (trim / extend / move into the neighbour) and
/// boundary grips between touching segments. Only the handle zones take hits; everything else
/// passes through to the Canvas (hover tooltip, click-select, lane marquee).
struct EditOverlay: View {
    let session: EditSession
    let data: DayData
    var vp: DayViewport

    static let space = "hours.edit.lane"
    static let handleW: CGFloat = 12, gripW: CGFloat = 8
    /// Boundary grips only where both neighbours are at least this wide (no grip forest at day zoom).
    static let gripMinBlock: CGFloat = 24

    /// `vp` is the target window; the layer glides to it with the timeline (`DayTweenWindow`). The
    /// grip candidates don't depend on the window, so they're found once here, not on every frame.
    var body: some View {
        let candidates = Self.gripCandidates(data, selection: session.selection)
        DayTweenWindow(window: vp.window) { w in
            var o = self
            o.vp.window = w
            return o.layer(candidates)
        }
    }

    private func layer(_ candidates: [Int]) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas(rendersAsynchronously: false) { ctx, _ in draw(&ctx) }
                .allowsHitTesting(false)
            ForEach(Self.grips(data, candidates: candidates, vp: vp), id: \.self) { t in
                zone(width: Self.gripW, x: vp.x(t), showsGrip: true) { ms, ended in
                    session.boundaryDrag(from: t, to: ms, snap: !Self.optionHeld, ended: ended)
                }
            }
            if session.selection.ranges.count == 1, let r = session.selection.ranges.first {
                zone(width: Self.handleW, x: vp.x(r.lowerBound), showsGrip: false) { ms, ended in
                    session.edgeDrag(.lower, to: ms, snap: !Self.optionHeld, ended: ended)
                }
                zone(width: Self.handleW, x: vp.x(r.upperBound), showsGrip: false) { ms, ended in
                    session.edgeDrag(.upper, to: ms, snap: !Self.optionHeld, ended: ended)
                }
            }
            if let (x, text) = readout {
                Text(text)
                    .font(TextRole.label.font).foregroundStyle(Theme.surface)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .fixedSize()
                    .position(x: min(max(x, 44), vp.width - 44), y: DayLanes.focusY + DayLanes.focusH / 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: vp.width, height: DayLanes.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
    }

    /// A draggable hit zone centred on `x` over the lane.
    private func zone(width: CGFloat, x: CGFloat, showsGrip: Bool,
                      onDrag: @escaping (Int64, Bool) -> Void) -> some View {
        EditDragZone(width: width, showsGrip: showsGrip, vp: vp, onDrag: onDrag)
            .position(x: x, y: DayLanes.laneY + DayLanes.laneH / 2)
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext) {
        let lane = { (lo: Int64, hi: Int64) -> CGRect in
            let x0 = vp.x(lo), x1 = vp.x(hi)
            return CGRect(x: x0, y: DayLanes.laneY - 3, width: max(x1 - x0, 2), height: DayLanes.laneH + 6)
        }
        // The Canvas draws a single selection itself; several ranges are drawn here, same style.
        if session.selection.ranges.count > 1 {
            for r in session.selection.ranges {
                let p = Path(roundedRect: lane(r.lowerBound, r.upperBound), cornerRadius: Theme.Radius.block + 2, style: .continuous)
                ctx.fill(p, with: .style(Theme.ink.opacity(0.06)))
                ctx.stroke(p, with: .style(Theme.ink), lineWidth: Theme.Stroke.selection)
            }
        }
        if let wm = EditPlanner.watermark(data), session.drag != nil, wm >= vp.window.startMs, wm <= vp.endMs {
            // Where editing stops: the live span (or now).
            var line = Path()
            line.move(to: CGPoint(x: vp.x(wm), y: DayLanes.laneY - 6))
            line.addLine(to: CGPoint(x: vp.x(wm), y: DayLanes.laneY + DayLanes.laneH + 6))
            ctx.stroke(line, with: .style(Theme.inkSecondary), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
        guard let preview = previewRange else { return }
        let p = Path(roundedRect: lane(preview.lowerBound, preview.upperBound), cornerRadius: Theme.Radius.block + 2,
                     style: .continuous)
        ctx.fill(p, with: .style(Theme.ink.opacity(0.08)))
        ctx.stroke(p, with: .style(Theme.ink), style: StrokeStyle(lineWidth: Theme.Stroke.selection, dash: [4, 3]))
    }

    /// The range the in-flight drag would produce.
    private var previewRange: Range<Int64>? {
        switch session.drag {
        case .marquee(let r): return r
        case let .edge(edge, t):
            guard let r = session.selection.ranges.first else { return nil }
            let lo = edge == .lower ? t : r.lowerBound, hi = edge == .upper ? t : r.upperBound
            return hi > lo ? lo..<hi : nil
        case let .boundary(t0, t1): return min(t0, t1)..<max(t0, t1)
        case nil: return nil
        }
    }

    /// `HH:mm · duration` over the dragged edge.
    private var readout: (CGFloat, String)? {
        let tz = data.timeZone
        switch session.drag {
        case .marquee(let r):
            return (vp.x(r.upperBound), "\(Fmt.clock(ms: r.lowerBound, timeZone: tz))–\(Fmt.clock(ms: r.upperBound, timeZone: tz)) · \(Fmt.duration(ms: r.upperBound - r.lowerBound))")
        case let .edge(_, t):
            guard let r = previewRange else { return (vp.x(t), Fmt.clock(ms: t, timeZone: tz)) }
            return (vp.x(t), "\(Fmt.clock(ms: t, timeZone: tz)) · \(Fmt.duration(ms: r.upperBound - r.lowerBound))")
        case let .boundary(t0, t1):
            return (vp.x(t1), "\(Fmt.clock(ms: t1, timeZone: tz)) · \(t1 >= t0 ? "+" : "−")\(Fmt.duration(ms: abs(t1 - t0)))")
        case nil: return nil
        }
    }

    // MARK: Geometry shared with the lane-drag filter

    /// Boundaries between touching, editable, wide-enough segments in the visible window
    /// (minus the selection's own edges, which are handles).
    static func grips(_ data: DayData, selection: EditSelection, vp: DayViewport) -> [Int64] {
        grips(data, candidates: gripCandidates(data, selection: selection), vp: vp)
    }

    /// The window-independent part of `grips`: indices `i` in `data.spans` where span i−1 touches
    /// span i, i ends before the watermark, and the boundary isn't a selection edge.
    static func gripCandidates(_ data: DayData, selection: EditSelection) -> [Int] {
        let wm = EditPlanner.watermark(data) ?? .max
        let edges = Set(selection.ranges.count == 1 ? [selection.ranges[0].lowerBound, selection.ranges[0].upperBound] : [])
        let s = data.spans
        return s.indices.dropFirst().filter { i in
            let a = s[i - 1].span, b = s[i].span
            return abs(b.startMs - a.endMs) < EditPlanner.touchMs && b.endMs <= wm && !edges.contains(a.endMs)
        }
    }

    /// The per-frame part: candidates inside `vp` with both neighbours wide enough.
    static func grips(_ data: DayData, candidates: [Int], vp: DayViewport) -> [Int64] {
        var out: [Int64] = []
        let s = data.spans
        for i in candidates where out.count < 300 {
            let a = s[i - 1].span, b = s[i].span
            guard a.endMs > vp.window.startMs, a.endMs < vp.endMs,
                  vp.x(a.endMs) - vp.x(a.startMs) >= gripMinBlock, vp.x(b.endMs) - vp.x(b.startMs) >= gripMinBlock
            else { continue }
            out.append(a.endMs)
        }
        return out
    }

    /// True when `ms` lands on a handle or grip — the lane marquee leaves those drags alone.
    static func isOnHandle(_ ms: Int64, data: DayData, selection: EditSelection, vp: DayViewport) -> Bool {
        let x = vp.x(ms)
        var xs = grips(data, selection: selection, vp: vp).map { (vp.x($0), gripW) }
        if selection.ranges.count == 1, let r = selection.ranges.first {
            xs += [(vp.x(r.lowerBound), handleW), (vp.x(r.upperBound), handleW)]
        }
        return xs.contains { abs($0.0 - x) <= $0.1 / 2 }
    }

    static var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }

    /// Shift = extend to the hull, Cmd = add / remove a range.
    static var selectionMode: EditSelection.Mode {
        let f = NSEvent.modifierFlags
        return f.contains(.command) ? .toggle : f.contains(.shift) ? .extend : .replace
    }
}

/// A thin vertical hit zone: resize cursor, a grip line on hover, reports drag times.
private struct EditDragZone: View {
    let width: CGFloat
    let showsGrip: Bool
    let vp: DayViewport
    let onDrag: (Int64, Bool) -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            if showsGrip && hovering {
                Capsule().fill(Theme.ink).frame(width: 3, height: 18)
            }
        }
        .frame(width: width, height: DayLanes.laneH + 6)
        .contentShape(Rectangle())
        .pointerStyle(.columnResize)
        .onHover { hovering = $0 }
        .help(showsGrip ? "Drag to move this boundary · ⌥ to drag without snapping" : "Drag to trim or extend · ⌥ to drag without snapping")
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(EditOverlay.space))
            .onChanged { v in onDrag(vp.ms(atX: v.location.x), false) }
            .onEnded { v in onDrag(vp.ms(atX: v.location.x), true) })
    }
}
