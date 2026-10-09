import AppKit
import HoursCore
import IncantCore

/// The Fn key tap: a session-level CGEventTap on flagsChanged + keyDown, reporting `IncantKeyEvent`s.
/// Fn edges come from `.maskSecondaryFn` flipping on flagsChanged; Escape is swallowed only while
/// listening; any other key while Fn is held is a chord. Adapted from FreeFlow's
/// GlobalShortcutBackend / ModifierKeyEventState (MIT, see THIRD_PARTY_NOTICES.md).
@MainActor final class IncantKeyTap {
    private let onEvent: (IncantKeyEvent) -> Void
    private let isListening: () -> Bool
    private var tap: CFMachPort?
    private var fnDown = false

    init(onEvent: @escaping (IncantKeyEvent) -> Void, isListening: @escaping () -> Bool) {
        self.onEvent = onEvent; self.isListening = isListening
    }

    /// Installs the tap; until Accessibility is granted that fails, so it retries every 2 s.
    func start() {
        guard tap == nil else { return }
        let mask = [CGEventType.flagsChanged, .keyDown].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            let me = Unmanaged<IncantKeyTap>.fromOpaque(info!).takeUnretainedValue()
            // The tap's run-loop source is on the main run loop.
            let swallow = MainActor.assumeIsolated { me.handle(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            // ponytail: poll until Accessibility is granted (no TCC change notification to listen to).
            Task { try? await Task.sleep(for: .seconds(2)); self.start() }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        fnDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        SupportLog.incant.info("key tap installed")
    }

    /// True = swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Report an Fn edge missed while the tap was off.
            setFn(CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn))
            return false
        case .flagsChanged:
            setFn(event.flags.contains(.maskSecondaryFn))
            return false
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                guard isListening() else { return false }
                onEvent(.escape)
                return true
            }
            if fnDown { onEvent(.otherKeyDown) }
            return false
        default:
            return false
        }
    }

    private func setFn(_ down: Bool) {
        guard down != fnDown else { return }
        fnDown = down
        onEvent(down ? .fnDown : .fnUp)
    }
}
