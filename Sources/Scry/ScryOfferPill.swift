import AppKit
import HoursCore

/// The "● Record <App>  ×" offer: a small black pill flush with the top of the screen, docked just right
/// of the camera notch (or of HoursSpell's island, if its right ear is there) — Incant's indicator takes
/// the left. Clickable without taking focus (a non-activating panel). Right-click → "Never for <App>".
/// Drops down out of the top edge on show and retracts into it on hide. Without a notch: top centre.
@MainActor final class ScryOfferPill {
    private static let height: CGFloat = 32, gap: CGFloat = 6
    var onRecord: () -> Void = {}
    var onNever: () -> Void = {}
    /// Recording mode: the time label opens the live panel; ■ stops and makes notes.
    var onOpenLive: () -> Void = {}
    var onStop: () -> Void = {}
    private var recordingLabel: NSButton?
    private var bars: ScryBarsView?
    private var readyURL: URL?
    var onOpenNote: (URL) -> Void = { _ in }
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var generation = 0

    init() {
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    /// While recording: "● mm:ss" (or "Ending · 12s") + ■, kept up for the whole recording. Called every
    /// second; once up it only updates the label (no re-animation).
    func showRecording(_ text: String, tooltip: String? = nil) {
        let title = attributed(text, size: 12, dot: true)
        if let label = recordingLabel, panel.isVisible {
            label.attributedTitle = title
            label.toolTip = tooltip
            let full = layoutRecording(label: label)
            if full.width != panel.frame.width { panel.setFrame(full, display: true) }
            return
        }
        generation += 1
        let label = button(text, size: 12, #selector(openLive))
        label.attributedTitle = title
        label.toolTip = tooltip
        let stop = button("■", size: 11, #selector(stopRecording))
        stop.toolTip = "Stop and make notes"
        let levels = ScryBarsView(frame: .zero)
        bars = levels
        let body = ScryPillView(frame: .zero)
        body.addSubview(levels); body.addSubview(label); body.addSubview(stop)
        body.setAccessibilityLabel("Scry: recording")
        panel.contentView = body
        recordingLabel = label
        present(layoutRecording(label: label))
    }

    private func layoutRecording(label: NSButton) -> NSRect {
        guard let body = panel.contentView, let stop = body.subviews.last as? NSButton else { return panel.frame }
        let lw = label.intrinsicContentSize.width, sw = stop.intrinsicContentSize.width, bw: CGFloat = 27
        let width = 10 + bw + 6 + lw + sw + 20
        let full = Self.frame(width: width)
        body.frame = NSRect(origin: .zero, size: full.size)
        bars?.frame = NSRect(x: 10, y: 0, width: bw, height: full.height)
        label.frame = NSRect(x: 10 + bw + 6, y: 0, width: lw, height: full.height)
        stop.frame = NSRect(x: width - 10 - sw, y: 0, width: sw, height: full.height)
        label.autoresizingMask = [.height]; stop.autoresizingMask = [.height, .minXMargin]
        return full
    }

    /// Pushes the current level (0…1) into the recording pill's bars, so it visibly listens (~12×/s).
    func pushLevel(_ level: Double) { bars?.push(level) }

    /// "✓ Meeting notes ready · <title>" after the pipeline: clicking opens the note in Spells. Hides after 10 s
    /// unless a recording has taken the pill since.
    func showReady(title: String, note: URL) {
        recordingLabel = nil; bars = nil; readyURL = note
        generation += 1
        let mine = generation
        let short = title.count > 34 ? String(title.prefix(33)) + "…" : title
        let open = button("✓ Meeting notes ready · \(short)", size: 12, #selector(openReady))
        let close = button("×", size: 14, #selector(dismiss))
        let width = open.intrinsicContentSize.width + close.intrinsicContentSize.width + 26
        let full = Self.frame(width: width)
        let body = ScryPillView(frame: NSRect(origin: .zero, size: full.size))
        open.frame = NSRect(x: 10, y: 0, width: open.intrinsicContentSize.width, height: full.height)
        close.frame = NSRect(x: width - 8 - close.intrinsicContentSize.width, y: 0, width: close.intrinsicContentSize.width, height: full.height)
        body.addSubview(open); body.addSubview(close)
        body.setAccessibilityLabel("Scry: meeting notes ready, \(title)")
        panel.contentView = body
        present(full)
        Task { try? await Task.sleep(for: .seconds(10)); if self.generation == mine { self.hide() } }
    }

    @objc private func openReady() { if let u = readyURL { hide(); onOpenNote(u) } }

    @objc private func openLive() { onOpenLive() }
    @objc private func stopRecording() { onStop() }

    private func attributed(_ text: String, size: CGFloat, dot: Bool) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white])
        if dot, text.hasPrefix("●") { s.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: 1)) }
        return s
    }

    private func present(_ full: NSRect) {
        if !panel.isVisible {   // drop down out of the top edge
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
    }

    func show(appName: String) {
        recordingLabel = nil
        generation += 1
        let record = button("● Record \(appName)", size: 12, #selector(record))
        let close = button("×", size: 14, #selector(dismiss))
        let width = record.intrinsicContentSize.width + close.intrinsicContentSize.width + 26
        let full = Self.frame(width: width)
        let body = ScryPillView(frame: NSRect(origin: .zero, size: full.size))
        record.frame = NSRect(x: 10, y: 0, width: record.intrinsicContentSize.width, height: full.height)
        close.frame = NSRect(x: width - 8 - close.intrinsicContentSize.width, y: 0, width: close.intrinsicContentSize.width, height: full.height)
        record.autoresizingMask = [.height]; close.autoresizingMask = [.height, .minXMargin]
        let menu = NSMenu()
        let never = NSMenuItem(title: "Never for \(appName)", action: #selector(neverFor), keyEquivalent: "")
        never.target = self
        menu.addItem(never)
        for v in [body, record, close] { v.menu = menu }
        body.addSubview(record); body.addSubview(close)
        body.setAccessibilityLabel("Scry: record \(appName)?")
        panel.contentView = body
        if !panel.isVisible {   // drop down out of the top edge
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
    }

    func hide() {
        recordingLabel = nil; bars = nil
        guard panel.isVisible else { return }
        let mine = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(Self.retracted(panel.frame), display: true)
            panel.animator().alphaValue = 0
        }) {
            MainActor.assumeIsolated { if mine == self.generation { self.panel.orderOut(nil) } }
        }
    }

    @objc private func record() { hide(); onRecord() }
    @objc private func dismiss() { hide() }
    @objc private func neverFor() { hide(); onNever() }

    private func button(_ title: String, size: CGFloat, _ sel: Selector) -> NSButton {
        let b = ScryFirstMouseButton(title: title, target: self, action: sel)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white])
        return b
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `full` collapsed into the top edge: a sliver a third as wide, kept against its left (notch-side) edge.
    static func retracted(_ full: NSRect) -> NSRect {
        NSRect(x: full.minX, y: full.maxY - 2, width: full.width / 3, height: 2)
    }

    /// Flush with the top, left edge `gap` right of the notch (or of the island's rightmost window when
    /// HoursSpell shows a right ear there). No notch: top centre.
    static func frame(width: CGFloat) -> NSRect {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
            return NSRect(x: 0, y: 0, width: width, height: height)
        }
        let top = screen.frame.maxY
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX else {
            return NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        }
        // The auxiliary areas have been seen both screen-local and global (same handling as Incant's overlay).
        let dx = abs(left.minX - screen.frame.minX) < 1 ? 0 : screen.frame.minX - left.minX
        let notchMinX = left.maxX + dx, notchMaxX = right.minX + dx
        let h = min(screen.safeAreaInsets.top, height)
        let anchor = max(notchMaxX, islandMaxX(near: notchMinX...notchMaxX) ?? notchMaxX)
        return NSRect(x: anchor + gap, y: top - h, width: width, height: h)
    }

    /// Right edge of HoursSpell's island windows at the top around the notch (window bounds need no permission).
    private static func islandMaxX(near notch: ClosedRange<CGFloat>) -> CGFloat? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Hours.trackerBundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let xs = list.compactMap { w -> CGFloat? in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], let x = b["X"], let y = b["Y"], let wd = b["Width"],
                  y < 4, x < notch.upperBound + 240, x + wd > notch.lowerBound else { return nil }   // top band, around the notch
            return x + wd
        }
        return xs.max()
    }
}

/// Clicks land on the first try even though the panel is never key.
private final class ScryFirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Black body, square at the top (flush with the screen edge), rounded at the bottom — Incant's shape.
private final class ScryPillView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds, radius: CGFloat = min(10, r.height / 2)
        let body = NSBezierPath()
        body.move(to: NSPoint(x: r.minX, y: r.maxY))
        body.line(to: NSPoint(x: r.maxX, y: r.maxY))
        body.line(to: NSPoint(x: r.maxX, y: r.minY + radius))
        body.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: 0, endAngle: -90, clockwise: true)
        body.line(to: NSPoint(x: r.minX + radius, y: r.minY))
        body.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: 270, endAngle: 180, clockwise: true)
        body.close()
        NSColor.black.setFill()
        body.fill()
    }
}

/// Five white level bars (the last five readings, newest on the right) — Incant's listening look.
final class ScryBarsView: NSView {
    private var levels = [Double](repeating: 0, count: 5)
    override var isFlipped: Bool { true }
    func push(_ level: Double) {
        levels.removeFirst(); levels.append(min(max(level, 0), 1)); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds, barW: CGFloat = 3, gap: CGFloat = 3
        var x = r.minX
        NSColor.white.setFill()
        for l in levels {
            let h = min(r.height - 10, 3 + CGFloat(l) * max(r.height - 12, 0))
            NSBezierPath(roundedRect: NSRect(x: x, y: r.midY - h / 2, width: barW, height: h), xRadius: 1.5, yRadius: 1.5).fill()
            x += barW + gap
        }
    }
}
