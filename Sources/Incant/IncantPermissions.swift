import AVFoundation
import ApplicationServices

/// What dictation needs: the microphone, and Accessibility (the hold-to-talk key tap and the ⌘V paste).
/// TCC keys each grant to this helper's own bundle ID and code signature (seen 2026-10-26: Incant trusted while
/// RewindTracker was not), so a differently signed build needs a fresh grant per helper, not per Spells.app.
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
