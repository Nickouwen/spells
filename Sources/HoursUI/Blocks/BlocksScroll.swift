import SwiftUI
import AppKit

/// The column's handle on the scroll view it sits in, for auto-scroll during an edge drag. A
/// zero-size, click-through AppKit probe behind the Canvas finds the enclosing `NSScrollView`.
@MainActor
final class BlocksScrollBox {
    weak var view: NSView?
    var task: Task<Void, Never>?

    var scrollView: NSScrollView? { view?.enclosingScrollView }

    /// This tick's scroll step for the pointer's distance from the visible top/bottom (0 = none).
    func step() -> CGFloat {
        guard let sv = scrollView, let win = sv.window else { return 0 }
        let p = sv.convert(win.mouseLocationOutsideOfEventStream, from: nil)
        let h = sv.bounds.height
        let top = sv.isFlipped ? p.y : h - p.y
        return BlocksAutoScroll.delta(top: top, bottom: h - top)
    }

    /// Scrolls by `dy` points (positive = down / later), clamped to the document.
    func scroll(by dy: CGFloat) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        var o = clip.bounds.origin
        o.y = min(max(o.y + (clip.isFlipped ? dy : -dy), 0), maxY)
        clip.scroll(to: o)
        sv.reflectScrolledClipView(clip)
    }

    /// The pointer's y in the probe's (= the column's) coordinates.
    func pointerY() -> CGFloat? {
        guard let v = view, let win = v.window else { return nil }
        return v.convert(win.mouseLocationOutsideOfEventStream, from: nil).y
    }

    func stop() { task?.cancel(); task = nil }
}

struct BlocksScrollProbe: NSViewRepresentable {
    let box: BlocksScrollBox

    final class Probe: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        box.view = v
        return v
    }

    func updateNSView(_ nsView: Probe, context: Context) { box.view = nsView }
}
