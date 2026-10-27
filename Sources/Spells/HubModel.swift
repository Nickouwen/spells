import AppKit
import Observation
import RewindCore
import RewindUI
import ScryCore
import ScryUI
import SpellsKit
import SpellsUI
import TransmuteUI

/// A place in the hub's sidebar.
enum HubSection: Hashable {
    case modules
    case rewind(ShellView)
    case meetings
    case invoices
    /// One Settings entry, pinned at the bottom; `HubModel.settingsModule` picks whose.
    case settings
}

/// Whose settings the Settings section shows.
enum SettingsModule: String, CaseIterable, Identifiable {
    case rewind = "Rewind", scry = "Scry", incant = "Incant", transmute = "Transmute"
    var id: String { rawValue }
}

/// The hub: the launcher plus each installed module's views, running or not — the data is on disk
/// (hours.db, the notes folder, the settings files), so the hub reads it directly. Sections appear when
/// the module is installed and go when it's removed.
@MainActor @Observable final class HubModel {
    let launcher = LauncherModel()
    var section: HubSection = .modules
    var settingsModule: SettingsModule = .rewind
    /// Rewind's model over hours.db; nil until Rewind is installed. `rewindError`: the DB wouldn't open.
    private(set) var rewind: AppModel?
    private(set) var rewindError: String?
    private(set) var meetings: ScryMeetingsModel?
    private(set) var incantInstalled = false
    /// Transmute's model over the same hours.db; nil until both Transmute and Rewind are installed.
    private(set) var transmute: TransmuteModel?
    private(set) var transmuteInstalled = false

    func start() {
        launcher.onChange = { [weak self] in self?.sync() }
        launcher.start()
    }

    private func sync() {
        let ids = Set(launcher.modules.map(\.bundleID))
        if ids.contains(Spells.rewindBundleID) {
            if rewind == nil, rewindError == nil { openRewind() }
        } else if rewind != nil || rewindError != nil {
            rewind?.setVisible(false)
            rewind = nil; rewindError = nil
            if case .rewind = section { section = .modules }
        }
        if ids.contains(Spells.scryBundleID) {
            if meetings == nil { meetings = ScryMeetingsModel(root: Self.scryRoot()) }
        } else if meetings != nil {
            meetings = nil
            if section == .meetings { section = .modules }
        }
        incantInstalled = ids.contains(Spells.incantBundleID)
        transmuteInstalled = ids.contains(Spells.transmuteBundleID)
        if transmuteInstalled, let rewind {
            if transmute == nil { transmute = TransmuteModel(db: rewind.db, timeZone: rewind.timeZone) }
        } else if transmute != nil {
            transmute = nil
            if section == .invoices { section = .modules }
        }
        if !settingsModules.contains(settingsModule), let first = settingsModules.first { settingsModule = first }
    }

    /// The modules with settings to show, in sidebar order.
    var settingsModules: [SettingsModule] {
        [rewind != nil ? SettingsModule.rewind : nil, meetings != nil ? .scry : nil, incantInstalled ? .incant : nil,
         transmuteInstalled ? .transmute : nil].compactMap { $0 }
    }

    func showSettings(_ m: SettingsModule) {
        settingsModule = m
        section = .settings
    }

    private func openRewind() {
        do {
            let m = try AppModel.live()
            m.ensureTracker = { [weak self] in await self?.ensureTracker() ?? .helperMissing }
            m.openMeeting = { [weak self] url in self?.showMeeting(url) }
            rewind = m
            Task { await m.checkTracker() }
        } catch {
            rewindError = String(describing: error)
            SupportLog.app.error("hub: Rewind's database didn't open: \(String(describing: error), privacy: .public)")
        }
    }

    /// Rewind's Blocks → the hub's Meetings section with that note selected.
    func showMeeting(_ url: URL) {
        meetings?.selection = url
        section = .meetings
    }

    /// After the hub's Scry settings save: the notes folder may have moved.
    func scrySettingsSaved() {
        meetings?.root = Self.scryRoot()
        rewind?.reloadSpellSettings()
    }

    static func scryRoot() -> URL { ScrySettings.load(SpellSettingsFile.scry().all()).rootURL }

    /// The tracker is Rewind's login item; from here we can only see whether it runs and start it from
    /// Rewind's bundle if not (Rewind itself registers it at login).
    private func ensureTracker() async -> TrackerHelperStatus {
        func running() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Spells.trackerBundleID).isEmpty }
        if running() { return .running }
        guard let rewind = launcher.modules.first(where: { $0.bundleID == Spells.rewindBundleID }) else { return .helperMissing }
        let helper = rewind.url.appending(path: "Contents/Library/LoginItems/RewindTracker.app")
        guard FileManager.default.fileExists(atPath: helper.path) else { return .helperMissing }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        do { _ = try await NSWorkspace.shared.openApplication(at: helper, configuration: config) } catch { return .failed(error.localizedDescription) }
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(250))
            if running() { return .running }
        }
        return .failed("the tracker didn't start")
    }
}
