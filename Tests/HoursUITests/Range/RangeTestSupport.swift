import SwiftUI
import AppKit
import HoursCore
@testable import HoursUI

func rd(_ y: Int, _ m: Int, _ d: Int) -> LocalDate { LocalDate(year: y, month: m, day: d) }

/// Renders a view through a real (offscreen, borderless) window so AppKit-backed pieces —
/// `Table`, `Menu` — draw too; `ImageRenderer` leaves those blank.
@MainActor
enum RangeRender {
    /// `settle`: run the loop briefly so `Table` populates its rows before capture.
    static func bitmap<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, settle: TimeInterval = 0) -> NSBitmapImageRep {
        let root = view.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        if settle > 0 {
            RunLoop.main.run(until: Date().addingTimeInterval(settle))
            host.layoutSubtreeIfNeeded()
        }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        win.contentView = nil
        return rep
    }

    /// Writes `$TMPDIR/<name>.png` and returns its URL.
    static func write<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, name: String) throws -> (URL, NSBitmapImageRep) {
        let rep = bitmap(view, size: size, scheme: scheme, settle: 0.25)
        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return (url, rep)
    }
}
