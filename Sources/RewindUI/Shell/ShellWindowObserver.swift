import AppKit
import SwiftUI

/// Reports whether the hosting window is actually on screen (occlusion, minimise, app hide) and
/// app activation, so `AppModel` can pause its feed subscription and tick while hidden.
struct ShellWindowObserver: NSViewRepresentable {
    let onVisible: @MainActor (Bool) -> Void
    let onActivate: @MainActor () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.onVisible = onVisible
        v.onActivate = onActivate
        return v
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        var onVisible: (@MainActor (Bool) -> Void)?
        var onActivate: (@MainActor () -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { onVisible?(false); return }
            let nc = NotificationCenter.default
            let windowNames: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                                    NSWindow.didMiniaturizeNotification,
                                                    NSWindow.didDeminiaturizeNotification,
                                                    NSWindow.willCloseNotification]
            for name in windowNames {
                tokens.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.report(closing: closing) }
                })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            tokens.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onActivate?() }
            })
            report()
        }

        private func report(closing: Bool = false) {
            guard let window else { return }
            let visible = !closing && window.occlusionState.contains(.visible) && !window.isMiniaturized
                && !NSApplication.shared.isHidden
            onVisible?(visible)
        }

        isolated deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
