/// Browser policy: which bundles get a URL via Apple events, and how privacy is decided. Pure.
public enum TrackerBrowser: Equatable, Sendable {
    /// Chrome-family: URL + tab title + incognito `mode` via AppleScript.
    case chromium
    /// Title from AX only (no scriptable URL); private windows are recognisable by title suffix.
    case firefox
    /// Safari, Arc: private-window detection unproven → title and URL always dropped.
    // ponytail: Safari/Arc expose no private-window property in their dictionaries; revisit only
    // with a proven detection method (spike #4). Until then they record app name only.
    case opaque

    public static func kind(_ bundleId: String?) -> TrackerBrowser? {
        switch bundleId {
        case "com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser",
             "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "org.chromium.Chromium": .chromium
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition": .firefox
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview", "company.thebrowser.Browser": .opaque
        default: nil
        }
    }

    public static func chromiumScript(_ bundleId: String) -> String {
        """
        with timeout of 2 seconds
          tell application id "\(bundleId)"
            if (count of windows) = 0 then return "NOWIN"
            if mode of front window is "incognito" then return "PRIVATE"
            return (URL of active tab of front window) & linefeed & (title of active tab of front window)
          end tell
        end timeout
        """
    }

    /// Builds the observation for a frontmost app. `scriptReply` is nil when the script couldn't
    /// run (Automation denied/undetermined, error, timeout).
    public static func observation(bundleId: String?, appName: String, axTitle: String?,
                                   scriptReply: String?) -> TrackerObservation {
        switch kind(bundleId) {
        case nil:
            return TrackerObservation(bundleId: bundleId, appName: appName, title: axTitle)
        case .opaque?:
            return TrackerObservation(bundleId: bundleId, appName: appName, isPrivate: true)
        case .firefox?:
            let isPrivate = axTitle?.contains("Private Browsing") ?? false
            return TrackerObservation(bundleId: bundleId, appName: appName, title: axTitle, isPrivate: isPrivate)
        case .chromium?:
            // No reply = incognito can't be ruled out, so the AX window title isn't trusted either.
            guard let reply = scriptReply, reply != "PRIVATE" else {
                return TrackerObservation(bundleId: bundleId, appName: appName, isPrivate: true)
            }
            if reply == "NOWIN" { return TrackerObservation(bundleId: bundleId, appName: appName) }
            let parts = reply.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return TrackerObservation(bundleId: bundleId, appName: appName,
                                      title: parts.count > 1 ? String(parts[1]) : nil,
                                      url: parts.first.map(String.init))
        }
    }
}
