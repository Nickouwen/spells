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
    var forInstaller: ModuleInstaller.Installed {
        .init(url: url, bundleID: bundleID, name: name, scheme: scheme, loginItem: loginItem, atLogin: atLogin)
    }

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

/// A row in the launcher: a module that is installed, in the catalog, or both.
struct LauncherRow: Identifiable, Equatable {
    var installed: InstalledModule?
    var available: ModuleCatalog.Entry?
    var id: String { installed?.bundleID ?? available!.bundleID }
    var name: String { installed?.name ?? available!.name }
    var summary: String { installed?.summary ?? available!.summary }
    var symbol: String { installed?.symbol ?? available!.symbol }
    /// The catalog has a newer version than the installed one.
    var update: ModuleCatalog.Entry? {
        guard let installed, let available, ModuleCatalog.isNewer(available.version, than: installed.version) else { return nil }
        return available
    }
}

/// Scans the modules folder, tracks which modules run (app launch/quit notifications), loads the
/// catalog, and runs installs/updates/removals one at a time per module.
@MainActor @Observable final class LauncherModel {
    private(set) var modules: [InstalledModule] = []
    private(set) var catalog: ModuleCatalog?
    private(set) var catalogError: String?
    private(set) var loadingCatalog = false
    /// Module bundle id → what's happening to it ("Downloading…"); absent = idle.
    private(set) var busy: [String: String] = [:]
    /// Module bundle id → the last failure, until the next attempt.
    private(set) var errors: [String: String] = [:]
    private var observers: [any NSObjectProtocol] = []

    var rows: [LauncherRow] {
        var byID: [String: LauncherRow] = [:]
        for m in modules { byID[m.bundleID] = LauncherRow(installed: m) }
        for e in catalog?.modules ?? [] { byID[e.bundleID, default: LauncherRow()].available = e }
        return byID.values.sorted { $0.name < $1.name }
    }

    func start() {
        guard observers.isEmpty else { refresh(); return }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
        Task { await loadCatalog() }
    }

    func refresh() {
        let dir = Spells.modulesDirectory
        let apps = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        modules = apps.filter { $0.pathExtension == "app" }.compactMap(InstalledModule.init).sorted { $0.name < $1.name }
    }

    func loadCatalog() async {
        loadingCatalog = true
        defer { loadingCatalog = false }
        let url = ModuleCatalog.url(SpellSettingsFile.launcher().all())
        do {
            catalog = try await ModuleInstaller.fetchCatalog(from: url)
            catalogError = nil
            SupportLog.app.info("catalog: \(self.catalog?.modules.count ?? 0) modules from \(url.absoluteString, privacy: .public)")
        } catch {
            catalogError = "Couldn't load the catalog: \(error.localizedDescription)"
            SupportLog.app.error("catalog \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func install(_ entry: ModuleCatalog.Entry) {
        run(entry.bundleID) { status in
            let installed = self.modules.first { $0.bundleID == entry.bundleID }
            _ = try await ModuleInstaller.install(entry, replacing: installed?.forInstaller, status: status)
            SupportLog.app.info("installed \(entry.name, privacy: .public) \(entry.version, privacy: .public)")
        }
    }

    func remove(_ m: InstalledModule) {
        run(m.bundleID) { status in
            try await ModuleInstaller.remove(m.forInstaller, status: status)
            SupportLog.app.info("removed \(m.name, privacy: .public)")
        }
    }

    private func run(_ id: String, _ work: @escaping @MainActor (_ status: (String) -> Void) async throws -> Void) {
        guard busy[id] == nil else { return }
        busy[id] = "Working…"
        errors[id] = nil
        Task {
            do { try await work { self.busy[id] = $0 } }
            catch { errors[id] = "\(error)"; SupportLog.app.error("module \(id, privacy: .public): \(String(describing: error), privacy: .public)") }
            busy[id] = nil
            refresh()
        }
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
