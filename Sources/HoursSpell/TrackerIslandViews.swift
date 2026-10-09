import AppKit
import QuartzCore

/// Colours for the island. It is always black, so these are the design system's dark values,
/// copied from `HoursUI/Design/DesignTheme.swift` (the helper doesn't link HoursUI).
enum TrackerIslandPalette {
    /// `Theme.Palette.slots[i].dark`.
    static let slots: [UInt32] = [0x475CD5, 0xF5C231, 0x25A085, 0xC91D2E, 0x9C478E,
                                  0xAE83FF, 0x0FE0F6, 0xAFCC87, 0xFF6597, 0x9D8752]
    static let uncategorized: UInt32 = 0x6E6E73
    static let warn: UInt32 = 0xF2B134

    static func color(slot: Int?) -> NSColor {
        guard let slot, slots.indices.contains(slot) else { return rgb(uncategorized) }
        return rgb(slots[slot])
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let ink = NSColor.white
    static let inkSecondary = NSColor(white: 1, alpha: 0.62)
    static let inkDim = NSColor(white: 1, alpha: 0.42)
    static let track = NSColor(white: 1, alpha: 0.2)
    static let buttonFill = NSColor(white: 1, alpha: 0.14)
}

/// Borderless, non-activating, above the menu bar, on every Space. Never key: the island takes
/// clicks (acceptsFirstMouse) without stealing focus from the app you're in.
final class TrackerIslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Status items (Control Center on macOS 26) share .statusBar; one above is the lowest level
        // that covers them too. Not isFloatingPanel: that would reset the level to .floating.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
    }

    // Borderless windows may sit over the menu bar / notch: never nudge the frame down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The black shape: a CAShapeLayer-backed view whose path the island animates.
final class TrackerIslandShapeView: NSView {
    var shape: CAShapeLayer { layer as! CAShapeLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.fillColor = NSColor.black.cgColor
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowRadius = 14
        shape.shadowOffset = CGSize(width: 0, height: -6)
        shape.shadowOpacity = 0
        shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "shadowOpacity": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// One path shape for collapsed and expanded, so the spring interpolates point for point.
    /// `body` in local (y-up) coordinates. Notch mode: top corners are concave flares of radius
    /// `flare` outside the body, flush with the top edge. Pill mode (`flare` 0): convex corners `top`.
    static func path(body b: CGRect, bottom r: CGFloat, top: CGFloat, flare f: CGFloat) -> CGPath {
        let p = CGMutablePath()
        // Quarter-circle as one cubic (k = 0.5523) from the current point to `to` via corner `c`.
        func quarter(to: CGPoint, corner c: CGPoint) {
            let k: CGFloat = 0.5523, from = p.currentPoint
            p.addCurve(to: to, control1: CGPoint(x: from.x + (c.x - from.x) * k, y: from.y + (c.y - from.y) * k),
                       control2: CGPoint(x: to.x + (c.x - to.x) * k, y: to.y + (c.y - to.y) * k))
        }
        let rr = min(r, b.width / 2, b.height / 2)
        if f > 0 {
            p.move(to: CGPoint(x: b.minX - f, y: b.maxY))
            quarter(to: CGPoint(x: b.minX, y: b.maxY - f), corner: CGPoint(x: b.minX, y: b.maxY))
        } else {
            let t = min(top, b.width / 2, b.height / 2)
            p.move(to: CGPoint(x: b.minX + t, y: b.maxY))
            quarter(to: CGPoint(x: b.minX, y: b.maxY - t), corner: CGPoint(x: b.minX, y: b.maxY))
        }
        p.addLine(to: CGPoint(x: b.minX, y: b.minY + rr))
        quarter(to: CGPoint(x: b.minX + rr, y: b.minY), corner: CGPoint(x: b.minX, y: b.minY))
        p.addLine(to: CGPoint(x: b.maxX - rr, y: b.minY))
        quarter(to: CGPoint(x: b.maxX, y: b.minY + rr), corner: CGPoint(x: b.maxX, y: b.minY))
        if f > 0 {
            p.addLine(to: CGPoint(x: b.maxX, y: b.maxY - f))
            quarter(to: CGPoint(x: b.maxX + f, y: b.maxY), corner: CGPoint(x: b.maxX, y: b.maxY))
        } else {
            let t = min(top, b.width / 2, b.height / 2)
            p.addLine(to: CGPoint(x: b.maxX, y: b.maxY - t))
            quarter(to: CGPoint(x: b.maxX - t, y: b.maxY), corner: CGPoint(x: b.maxX, y: b.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// Goal ring: white arc on a dark grey track, starting at 12 o'clock, clockwise. Clamped to 1.
final class TrackerIslandRingView: NSView {
    private let track = CAShapeLayer(), arc = CAShapeLayer()
    private let lineWidth: CGFloat

    init(lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        wantsLayer = true
        for l in [track, arc] {
            l.fillColor = nil
            l.lineWidth = lineWidth
            l.actions = ["strokeEnd": NSNull(), "hidden": NSNull(), "path": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(l)
        }
        track.strokeColor = TrackerIslandPalette.track.cgColor
        arc.strokeColor = TrackerIslandPalette.ink.cgColor
        arc.lineCap = .round
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 0 hides the arc (a zero-length round cap would still draw a dot).
    var progress: Double = 0 {
        didSet {
            arc.strokeEnd = CGFloat(min(max(progress, 0), 1))
            arc.isHidden = progress <= 0.005
        }
    }

    override func layout() {
        super.layout()
        let r = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let p = CGMutablePath()
        // From 12 o'clock clockwise (y-up: start at π/2, decreasing angle).
        p.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                 startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for l in [track, arc] { l.frame = bounds; l.path = p }
    }
}

/// Category dot; hollow (outline only) while paused.
final class TrackerIslandDotView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.actions = ["backgroundColor": NSNull(), "borderWidth": NSNull(), "borderColor": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(color: NSColor, hollow: Bool) {
        layer?.backgroundColor = hollow ? NSColor.clear.cgColor : color.cgColor
        layer?.borderColor = (hollow ? TrackerIslandPalette.inkSecondary : color).cgColor
        layer?.borderWidth = hollow ? 1.25 : 0
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

/// Non-editable label; optional click action (the hero opens Hours).
final class TrackerIslandLabel: NSTextField {
    var onClick: (() -> Void)?

    convenience init(font: NSFont, color: NSColor) {
        self.init(labelWithString: "")
        self.font = font
        textColor = color
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onClick != nil }
    override func hitTest(_ point: NSPoint) -> NSView? { onClick == nil ? nil : super.hitTest(point) }
    override func mouseDown(with event: NSEvent) { if let onClick { onClick() } else { super.mouseDown(with: event) } }

    /// Only touches the field when the text or colour actually changed.
    func update(_ text: String, color: NSColor? = nil) {
        if stringValue != text { stringValue = text }
        if let color, textColor != color { textColor = color }
    }
}

/// Small pill-ish button for the black card (rounded rect, translucent white fill, white title).
final class TrackerIslandButton: NSButton {
    convenience init(title: String, symbol: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = TrackerIslandPalette.buttonFill.cgColor
        layer?.cornerRadius = 8
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        imagePosition = .imageLeading
        imageHugsTitle = true
        contentTintColor = TrackerIslandPalette.ink
        setTitle(title)
    }

    func setTitle(_ t: String) {
        attributedTitle = NSAttributedString(string: " " + t, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: TrackerIslandPalette.ink,
        ])
        setAccessibilityLabel(t)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Root view: tracks hover over the black shape (`hoverRect`, local) and takes first clicks.
final class TrackerIslandRootView: NSView {
    var onHover: ((Bool) -> Void)?
    var hoverRect: CGRect = .zero {
        didSet { if hoverRect != oldValue { updateTrackingAreas() } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: hoverRect, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
