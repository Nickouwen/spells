import AppKit
import SpellsKit
import SpellsUI

/// Scry's two windows (Meetings, Settings) and its URL verbs. A menu-bar app: windows are made on first
/// show and kept.
@MainActor enum ScryWindows {
    static let meetingsModel = ScryMeetingsModel(root: ScryApp.loadSettings().settings.rootURL)
    private static let meetings = ModuleWindow(), settings = ModuleWindow()
    /// Set by ScryApp: re-reads what the detector caches (the never-offer list).
    static var onSettingsChanged: @MainActor () -> Void = {}

    static func showMeetings(_ note: URL? = nil) {
        meetingsModel.root = ScryApp.loadSettings().settings.rootURL
        if let note { meetingsModel.selection = note }
        meetings.show(title: "Meetings", size: NSSize(width: 1180, height: 760), minSize: NSSize(width: 900, height: 600)) {
            MeetingsView(model: meetingsModel)
        }
    }

    static func showSettings() {
        settings.show(title: "Scry Settings", size: NSSize(width: 680, height: 640), minSize: NSSize(width: 560, height: 400)) {
            ScrySettingsView()
        }
    }

    /// `scry://settings`, `scry://meetings`, `scry://meeting?path=<note.md>` (`quit` is answered by ModuleURLs).
    static func handle(_ verb: String, _ query: [String: String]) {
        switch verb {
        case "settings": showSettings()
        case "meetings": showMeetings()
        case "meeting": showMeetings(query["path"].map { URL(filePath: $0) })
        default: SupportLog.scry.info("unknown URL verb \(verb, privacy: .public)")
        }
    }

    /// After the settings window saves.
    static func settingsChanged() {
        meetingsModel.root = ScryApp.loadSettings().settings.rootURL
        onSettingsChanged()
    }
}
