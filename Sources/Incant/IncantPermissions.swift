import AVFoundation
import ApplicationServices

/// What dictation needs: the microphone, and Accessibility (the hold-to-talk key tap and the ⌘V paste).
/// TCC attributes these to the enclosing Spells.app, which carries the matching entitlement and usage text.
enum IncantPermissions {
    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var ready: Bool { microphone == .authorized && accessibility }

    /// Prompts for whatever is still undetermined, then calls `done` on the main actor.
    @MainActor static func request(_ done: @escaping @MainActor () -> Void) {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        guard microphone == .notDetermined else { done(); return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in done() } }
    }
}
