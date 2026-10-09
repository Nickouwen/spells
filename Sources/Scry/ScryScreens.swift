import Foundation
import HoursCore
import ScreenCaptureKit
import Vision

/// Who's on the call, from the screen: the call app's largest on-screen window via ScreenCaptureKit,
/// OCR'd with Vision (accurate). Only the text lines are kept — images are never saved. Without the
/// Screen Recording grant it returns nil and logs once.
enum ScryScreens {
    nonisolated(unsafe) private static var loggedDenied = false   // ponytail: a racy "log once" flag; worst case two log lines

    static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
                                        "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac"]
    /// A browser window counts only when its title (the active tab) looks like a call; ordinary browsing is
    /// never captured.
    static func isMeetingTitle(_ title: String) -> Bool {
        title.range(of: #"(?i)\b(meet|zoom|teams|huddle|webex|whereby|jitsi)\b|meet\.google\.com"#, options: .regularExpression) != nil
    }

    /// Whether the browser has an on-screen window titled like a call (needs Screen Recording; false without it).
    static func meetingWindowOpen(app bundleID: String) async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return false }
        return content.windows.contains { $0.owningApplication?.bundleIdentifier == bundleID && ($0.title.map(isMeetingTitle) ?? false) }
    }

    static func lines(app bundleID: String) async -> [String]? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let browser = browsers.contains(bundleID)
            guard let w = content.windows.filter({ w in
                w.owningApplication?.bundleIdentifier == bundleID && w.frame.width > 200
                    && (!browser || (w.title.map(isMeetingTitle) ?? false))
            }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                if browser { SupportLog.scry.info("no meeting-titled browser window; screenshot skipped") }
                return nil
            }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(w.frame.width * 2); cfg.height = Int(w.frame.height * 2)
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
            let t = Date()
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
            // Browsers: drop the top strip (tabs, toolbar, bookmarks bar — Vision boxes are bottom-up, 0…1),
            // which otherwise turns bookmark names into "participants".
            let lines = (req.results ?? []).filter { !browser || $0.boundingBox.midY < 0.85 }
                .compactMap { $0.topCandidates(1).first?.string }
            SupportLog.scry.info("screenshot OCR: \(lines.count, privacy: .public) lines in \(Int(Date().timeIntervalSince(t) * 1000), privacy: .public) ms")
            return lines
        } catch {
            if !loggedDenied {
                loggedDenied = true
                SupportLog.scry.error("call-window screenshot skipped: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }
}
