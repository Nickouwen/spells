import AppKit
import HoursCore

/// The listening indicator: a small black shape flush with the top of the screen, docked just left of
/// the camera notch (or of HoursSpell's island, if its left ear is there), so it reads as part of the
/// notch. Monochrome: white level bars while listening, a dot for hands-free, pulsing dots while the
/// correction runs, "!" on an error. No text. A non-activating panel that never takes focus, so the
/// paste lands in the app you were typing in. Without a notch it sits at the top centre.
@MainActor final class IncantOverlay {
    private static let size = NSSize(width: 64, height: 32)
    private static let gap: CGFloat = 6             // from the notch / the island's left edge
    private let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let view = IncantIndicatorView(frame: NSRect(origin: .zero, size: size))
    private var generation = 0                       // bumped per show; a hide only acts on its own showing
    private var holdUntil = Date.distantPast         // keeps an error visible
    private var pulse: Timer?

    var level = 0.0 { didSet { view.push(level) } }
    /// Kept for the session's API; the indicator shows no text.
    var text = "" { didSet { view.setAccessibilityLabel(text.isEmpty ? "Incant: listening" : "Incant: \(text)") } }
    /// "Fixing…" → pulsing dots; the hands-free hint → the dot; anything else is ignored (no text shown).
    var hint: String? {
        didSet {
            view.handsFree = hint?.hasPrefix("Hands-free") ?? false
            setFixing(hint == "Fixing…")
        }
    }

    init() {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
    }

    /// Shows the indicator for a new dictation and cancels any pending fade-out of the previous one.
    /// Returns the token to pass to `hide`.
    @discardableResult func show() -> Int {
        generation += 1
        holdUntil = .distantPast
        view.reset()
        setFixing(false)
        let full = Self.frame()
        if !panel.isVisible {   // drop down out of the top edge (from where it would retract to)
            panel.alphaValue = 0
            panel.setFrame(Self.retracted(full), display: false)
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(full, display: true)
            panel.animator().alphaValue = 1
        }
        return generation
    }

    /// False once a newer dictation has taken the indicator.
    func isCurrent(_ token: Int) -> Bool { token == generation }

    func fail(_ message: String) {
        setFixing(false)
        view.mode = .error
        view.setAccessibilityLabel("Incant: \(message)")
        holdUntil = Date().addingTimeInterval(1.5)
    }

    /// Fades out the showing `token` after `delay` (longer if an error is showing); a no-op once a
    /// newer dictation has shown the indicator.
    func hide(_ token: Int, after delay: TimeInterval = 0.3) {
        guard token == generation else { return }
        let mine = token
        let wait = max(delay, holdUntil.timeIntervalSinceNow)
        Task {
            try? await Task.sleep(for: .seconds(wait))
            guard mine == generation else { return }
            // Retract up into the top edge, narrowing toward the notch, as it fades.
            let target = Self.retracted(panel.frame)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = reduceMotion ? 0 : 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 0
            }) {
                MainActor.assumeIsolated {
                    if mine == self.generation { self.panel.orderOut(nil); self.setFixing(false) }
                }
            }
        }
    }

    private func setFixing(_ on: Bool) {
        pulse?.invalidate(); pulse = nil
        guard on else { if view.mode == .fixing { view.mode = .listening }; return }
        view.mode = .fixing
        pulse = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak view] _ in
            MainActor.assumeIsolated { view?.phase += 1 / 30 }
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `full` collapsed into the top edge: a sliver at the top, a third as wide, kept against its
    /// right (notch-side) edge.
    static func retracted(_ full: NSRect) -> NSRect {
        let w = full.width / 3, h: CGFloat = 2
        return NSRect(x: full.maxX - w, y: full.maxY - h, width: w, height: h)
    }

    /// Flush with the top, right edge `gap` left of the notch (or of the island's leftmost window when
    /// HoursSpell shows a left ear there). No notch: top centre.
    static func frame() -> NSRect {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        let top = screen.frame.maxY
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX else {
            return NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        }
        // The auxiliary areas have been seen both screen-local and global (same handling as the island).
        let dx = abs(left.minX - screen.frame.minX) < 1 ? 0 : screen.frame.minX - left.minX
        let notchMinX = left.maxX + dx, notchMaxX = right.minX + dx
        let height = min(screen.safeAreaInsets.top, size.height)
        let anchor = min(notchMinX, islandMinX(near: notchMinX...notchMaxX) ?? notchMinX)
        return NSRect(x: anchor - gap - size.width, y: top - height, width: size.width, height: height)
    }

    /// Left edge of HoursSpell's island windows at the top around the notch (window bounds need no permission).
    private static func islandMinX(near notch: ClosedRange<CGFloat>) -> CGFloat? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Hours.trackerBundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let xs = list.compactMap { w -> CGFloat? in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], let x = b["X"], let y = b["Y"], let wd = b["Width"],
                  y < 4, x + wd > notch.lowerBound - 240, x < notch.upperBound else { return nil }   // top band, around the notch
            return x
        }
        return xs.min()
    }
}

/// White-on-black drawing: five level bars (the last five readings, newest on the right), a hands-free
/// dot, a pulsing three-dot "fixing" state, and "!" for errors.
final class IncantIndicatorView: NSView {
    enum Mode { case listening, fixing, error }
    var mode: Mode = .listening { didSet { needsDisplay = true } }
    var handsFree = false { didSet { if handsFree != oldValue { needsDisplay = true } } }
    var phase: Double = 0 { didSet { needsDisplay = true } }
    private var levels = [Double](repeating: 0, count: 5)

    override var isFlipped: Bool { true }

    func push(_ level: Double) {
        levels.removeFirst()
        levels.append(min(max(level, 0), 1))
        if mode == .listening { needsDisplay = true }
    }

    func reset() {
        levels = .init(repeating: 0, count: levels.count)
        mode = .listening; handsFree = false; phase = 0
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        // Black body, square at the top (flush with the screen edge), rounded at the bottom.
        let radius: CGFloat = 10
        let body = NSBezierPath()
        body.move(to: NSPoint(x: r.minX, y: r.minY))
        body.line(to: NSPoint(x: r.maxX, y: r.minY))
        body.line(to: NSPoint(x: r.maxX, y: r.maxY - radius))
        body.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: 0, endAngle: 90)
        body.line(to: NSPoint(x: r.minX + radius, y: r.maxY))
        body.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
        body.close()
        NSColor.black.setFill()
        body.fill()

        let midY = r.midY
        switch mode {
        case .listening:
            let barW: CGFloat = 3, spacing: CGFloat = 3
            let total = CGFloat(levels.count) * barW + CGFloat(levels.count - 1) * spacing
            var x = r.midX - total / 2 + (handsFree ? 4 : 0)
            NSColor.white.setFill()
            for l in levels {
                let h = min(r.height - 6, 3 + CGFloat(l) * max(r.height - 12, 0))   // scales down while retracting
                NSBezierPath(roundedRect: NSRect(x: x, y: midY - h / 2, width: barW, height: h), xRadius: 1.5, yRadius: 1.5).fill()
                x += barW + spacing
            }
            if handsFree {   // hands-free: a small dot to the left of the bars
                NSBezierPath(ovalIn: NSRect(x: r.midX - total / 2 - 6, y: midY - 2, width: 4, height: 4)).fill()
            }
        case .fixing:
            for i in 0..<3 {
                let a = 0.35 + 0.65 * (0.5 + 0.5 * sin(phase * 2 * .pi * 1.4 - Double(i) * 0.9))
                NSColor.white.withAlphaComponent(a).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.midX - 13 + CGFloat(i) * 10, y: midY - 2.5, width: 5, height: 5)).fill()
            }
        case .error:
            let s = NSAttributedString(string: "!", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold),
                                                                  .foregroundColor: NSColor.white])
            let sz = s.size()
            s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: midY - sz.height / 2))
        }
    }
}
