import SwiftUI
import HoursCore
import HoursUI

@main
struct SpellsApp: App {
    /// The DB can fail to open (e.g. `schemaTooNew` after a downgrade); show that instead of crashing.
    @State private var launch: Result<AppModel, any Error> = Result {
        let model = try AppModel.live()
        model.ensureTracker = { await AppHelperLifecycle.ensureTrackerRunning() }
        model.openLoginItems = { AppHelperLifecycle.openLoginItemsSettings() }
        model.incant = IncantLifecycle.spellSwitch
        model.scry = ScryLifecycle.spellSwitch
        return model
    }

    var body: some Scene {
        Window("Spells", id: "main") {
            switch launch {
            case .success(let model):
                ShellRootView(model: model)
                    // spells://meeting?path=<note.md> (Scry's "Meeting notes ready" pill) → Meetings on that note.
                    .onOpenURL { url in
                        guard url.scheme == "spells", url.host == "meeting",
                              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                                .first(where: { $0.name == "path" })?.value else { return }
                        model.openMeeting(URL(filePath: path))
                    }
                    .task {
                        Self.applyDebugEnvironment(model)
                        await model.checkTracker()
                        try? await IncantLifecycle.launchIfNeeded()
                        try? await ScryLifecycle.launchIfNeeded()
                    }
            case .failure(let error):
                EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't open the database",
                           detail: String(describing: error))
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        // ponytail: 06 says 1180×760; 1440×900 shows Day/Week/Range in their widest arrangement.
        // Narrower windows (down to 900×600) reflow: tiles wrap, panel grids drop to 2 columns.
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands { ShellCommands() }

        Settings {
            if case .success(let model) = launch { SettingsView(model: model) }
        }
    }

    /// Dev/screenshot knobs, ignored when unset:
    /// `HOURS_APPEARANCE=light|dark` overrides the system appearance;
    /// `HOURS_DEBUG_VIEW=day|week|range` and `HOURS_DEBUG_DAY_OFFSET=-3` pick the starting view/day
    /// (the same as pressing ⌘1–⌘3 / ← after launch).
    @MainActor private static func applyDebugEnvironment(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        switch env["HOURS_APPEARANCE"] {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let v = env["HOURS_DEBUG_VIEW"].flatMap(ShellView.init(rawValue:)) { model.view = v }
        if let n = env["HOURS_DEBUG_DAY_OFFSET"].flatMap(Int.init) { model.step(days: n) }
    }
}
