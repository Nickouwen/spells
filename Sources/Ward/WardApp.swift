import SwiftUI
import SpellsKit
import SpellsUI
import WardCore
import WardUI

/// Ward: network watch. Shows whether the rolling packet capture runs, what it keeps, and the audit
/// of what this Mac connected to. A windowed module like Transmute: the launcher opens it, it updates itself.
@main
struct WardApp: App {
    @State private var model = WardModel()
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        Window("Ward", id: "main") {
            WardView(model: model, openSettings: { openSettings() })
                .navigationTitle("Network")
                .task { ModuleUpdater.start(settings: .ward()) }
        }
        .defaultSize(width: 900, height: 720)
        .windowResizability(.contentMinSize)

        Settings { WardSettingsView(model: model) }
    }
}
