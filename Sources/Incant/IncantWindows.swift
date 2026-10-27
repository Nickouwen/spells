import AppKit
import SpellsKit
import SpellsUI
import IncantUI

/// Incant's one window and its URL verbs (`incant://settings`; `quit` is answered by ModuleURLs).
@MainActor enum IncantWindows {
    private static let settings = ModuleWindow()

    static func showSettings() {
        settings.show(title: "Incant Settings", size: NSSize(width: 680, height: 720), minSize: NSSize(width: 560, height: 400)) {
            IncantSettingsView(permissions: .init(microphone: IncantPermissions.microphone == .authorized, accessibility: IncantPermissions.accessibility))
        }
    }

    static func handle(_ verb: String, _ query: [String: String]) {
        switch verb {
        case "settings": showSettings()
        default: SupportLog.incant.info("unknown URL verb \(verb, privacy: .public)")
        }
    }
}
