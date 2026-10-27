import AppKit

/// What the timeline needs from a scroll-wheel event.
struct DayScrollEvent {
    var dx: CGFloat
    var dy: CGFloat
    var command: Bool
}

/// Trackpad/wheel events for the timeline while the pointer is over it. SwiftUI has no scroll-wheel
/// modifier for a custom (ScrollView-free) container, so this installs a local event monitor on
/// hover-in and removes it on hover-out. Unhandled events pass through (page scroll keeps working).
@MainActor
final class DayScrollMonitor {
    private var token: Any?

    func start(_ handler: @escaping @MainActor (DayScrollEvent) -> Bool) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let e = DayScrollEvent(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                                   command: event.modifierFlags.contains(.command))
            let handled = MainActor.assumeIsolated { handler(e) }
            return handled ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
