import AppKit
import SpellsKit
import SpellsUI
import WardUI

/// Ward's two windows (Network, Settings) over one model, and its URL verbs. A menu-bar app: windows
/// are made on first show and kept.
@MainActor enum WardWindows {
    static let model = WardModel()
    private static let network = ModuleWindow(), settings = ModuleWindow()

    static func showNetwork() {
        network.show(title: "Network", size: NSSize(width: 900, height: 720), minSize: NSSize(width: 700, height: 480)) {
            WardView(model: model, openSettings: { showSettings() })
        }
    }

    static func showSettings() {
        settings.show(title: "Ward Settings", size: NSSize(width: 680, height: 600), minSize: NSSize(width: 560, height: 400)) {
            WardSettingsView(model: model)
        }
    }

    /// `ward://settings`, `ward://network` (`quit` and `login-item` are answered by ModuleURLs).
    static func handle(_ verb: String, _ query: [String: String]) {
        switch verb {
        case "settings": showSettings()
        case "network", "open": showNetwork()
        default: SupportLog.ward.info("unknown URL verb \(verb, privacy: .public)")
        }
    }
}
