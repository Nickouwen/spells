import AppKit
import SpellsKit

/// Every app checks for its own update, like any other Mac app: 30 s after launch and every six hours,
/// it reads the catalog, finds its own entry, and when that is newer asks "Update / Later". Later snoozes
/// a day (`update_snoozed_until` in the app's settings file). A busy app (a Scry recording, an Incant
/// dictation) is asked again ten minutes later. Update runs `ModuleInstaller.updateSelf`.
@MainActor public enum ModuleUpdater {
    public static let snoozeKey = "update_snoozed_until"
    public static let firstDelay: TimeInterval = 30
    public static let interval: TimeInterval = 6 * 3600
    public static let busyRetry: TimeInterval = 600
    public static let snooze: TimeInterval = 24 * 3600

    public static func start(settings: SpellSettingsFile, busy: @escaping @MainActor () -> Bool = { false }) {
        Task {
            try? await Task.sleep(for: .seconds(firstDelay))
            while true {
                let again = await check(settings: settings, busy: busy)
                try? await Task.sleep(for: .seconds(again))
            }
        }
    }

    /// One check; returns how long to wait before the next.
    static func check(settings: SpellSettingsFile, busy: @MainActor () -> Bool) async -> TimeInterval {
        guard let id = Bundle.main.bundleIdentifier, let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return interval }
        let url = ModuleCatalog.url(SpellSettingsFile.launcher().all())
        let entry: ModuleCatalog.Entry
        do {
            guard let e = try await ModuleInstaller.fetchCatalog(from: url).entry(for: id) else { return interval }
            entry = e
        } catch {
            SupportLog.app.error("update check: \(String(describing: error), privacy: .public)")
            return interval
        }
        guard ModuleCatalog.isNewer(entry.version, than: mine) else { return interval }
        let now = Date().timeIntervalSince1970
        if let s = settings.all()[snoozeKey].flatMap(Double.init), s > now { return min(interval, s - now) }
        if busy() { return busyRetry }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(entry.name) \(entry.version) is available"
        alert.informativeText = "You have \(mine). Updating downloads the new version, checks its signature, and relaunches \(entry.name)."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else {
            try? settings.set(snoozeKey, String(Int(now + snooze)))
            return snooze
        }
        do {
            try await ModuleInstaller.updateSelf(entry) { SupportLog.app.info("update: \($0, privacy: .public)") }
        } catch {
            let failed = NSAlert()
            failed.messageText = "Couldn't update \(entry.name)"
            failed.informativeText = "\(error)"
            failed.runModal()
        }
        return interval
    }
}
