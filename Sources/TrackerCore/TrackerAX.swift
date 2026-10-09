import ApplicationServices

/// One AXObserver, on the frontmost app only: focused-window changes on the app element and title
/// changes on the current focused window. Never sets AXEnhancedUserInterface/AXManualAccessibility.
@MainActor final class TrackerAX {
    private var observer: AXObserver?
    private var app: AXUIElement?
    private var window: AXUIElement?
    var onChange: (() -> Void)?

    var isTrusted: Bool { AXIsProcessTrusted() }

    func bind(pid: pid_t) {
        unbind()
        guard isTrusted else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var obs: AXObserver?
        guard AXObserverCreate(pid, trackerAXCallback, &obs) == .success, let obs else { return }
        self.app = app; observer = obs
        // kAXErrorNotificationUnsupported → nothing to do; the 30 s tick re-reads the title.
        AXObserverAddNotification(obs, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        rebindWindow()
    }

    func unbind() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil; app = nil; window = nil
    }

    /// Focused window title of the bound app; nil without trust, without a window, or on timeout.
    func title() -> String? {
        guard let window = focusedWindow() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    fileprivate func handle(_ notification: String) {
        if notification == kAXFocusedWindowChangedNotification { rebindWindow() }
        onChange?()
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func focusedWindow() -> AXUIElement? {
        guard let app else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func rebindWindow() {
        guard let observer else { return }
        if let window { AXObserverRemoveNotification(observer, window, kAXTitleChangedNotification as CFString) }
        window = focusedWindow()
        if let window { AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, refcon) }
    }
}

private func trackerAXCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                               _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let ax = Unmanaged<TrackerAX>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    // The observer's run-loop source is on the main run loop.
    MainActor.assumeIsolated { ax.handle(name) }
}
