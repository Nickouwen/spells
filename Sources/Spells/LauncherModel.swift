import AppKit
import Observation
import SpellsKit
import SpellsUI

/// One module app found in the modules folder, read from its Info.plist `SpellsModule` manifest.
struct InstalledModule: Identifiable, Equatable {
    let url: URL
    let bundleID: String
    let name: String
    let summary: String
    let symbol: String
    let scheme: String
    /// A menu-bar module that can start at login (Incant, Scry); false for a windowed app like Rewind.
    let loginItem: Bool
    let version: String
    var running: Bool
    /// The module's own `login_item` row (it mirrors its registration there).
    var atLogin: Bool
    var id: String { bundleID }

    init?(url: URL) {
        guard let b = Bundle(url: url), let id = b.bundleIdentifier,
              let m = b.infoDictionary?[Spells.manifestKey] as? [String: Any],
              let name = m["Name"] as? String, let scheme = m["Scheme"] as? String else { return nil }
        self.url = url; bundleID = id; self.name = name; self.scheme = scheme
        summary = m["Summary"] as? String ?? ""
        symbol = m["Symbol"] as? String ?? "app"
        loginItem = m["LoginItem"] as? Bool ?? false
        version = b.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        running = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        atLogin = SpellSettingsFile(spell: scheme).all()[Spells.loginItemKey] == "1"
    }
}

/// Scans the modules folder and tracks which modules run; refreshes on app launch/quit notifications.
@MainActor @Observable final class LauncherModel {
    private(set) var modules: [InstalledModule] = []
    private var observers: [any NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { refresh(); return }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let dir = Spells.modulesDirectory
        let apps = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        modules = apps.filter { $0.pathExtension == "app" }.compactMap(InstalledModule.init).sorted { $0.name < $1.name }
    }

    func open(_ m: InstalledModule) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = !m.loginItem
        NSWorkspace.shared.openApplication(at: m.url, configuration: config) { _, error in
            if let error { SupportLog.app.error("launch \(m.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
        }
        refreshSoon()
    }

    func settings(_ m: InstalledModule) { send(m, "settings") }
    func quit(_ m: InstalledModule) { send(m, "quit") }

    func setLogin(_ m: InstalledModule, _ on: Bool) {
        send(m, "login-item", ["on": on ? "1" : "0"])
        if let i = modules.firstIndex(of: m) { modules[i].atLogin = on }   // optimistic; refresh re-reads the file
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: Spells.modulesDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Spells.modulesDirectory])
    }

    private func send(_ m: InstalledModule, _ verb: String, _ query: [String: String] = [:]) {
        NSWorkspace.shared.open([ModuleURLs.url(scheme: m.scheme, verb: verb, query: query)], withApplicationAt: m.url,
                                configuration: NSWorkspace.OpenConfiguration())
        refreshSoon()
    }

    private func refreshSoon() {
        Task { try? await Task.sleep(for: .seconds(1.5)); refresh() }
    }
}
