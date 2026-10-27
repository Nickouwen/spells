import AppKit
import RewindCore
import RewindUI
import ServiceManagement

/// App side of the helper's lifecycle: keep RewindTracker registered as a login item and running.
/// Call on launch (and when the window reopens); render the returned status as the banner.
@MainActor
enum AppHelperLifecycle {
    static var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Library/LoginItems/RewindTracker.app")
    }

    static func ensureTrackerRunning() async -> TrackerHelperStatus {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .notBundled }
        guard FileManager.default.fileExists(atPath: helperURL.path) else { return .helperMissing }

        let service = SMAppService.loginItem(identifier: RewindModule.trackerBundleID)
        switch service.status {
        case .notRegistered, .notFound:
            do {
                try service.register()
            } catch where service.status == .requiresApproval {
                // register() throws when the user must approve; the status below covers it.
            } catch {
                SupportLog.app.error("login item register failed: \(error.localizedDescription, privacy: .public)")
                return .failed(error.localizedDescription)
            }
        case .enabled:
            // Re-register even when enabled: the record keeps the code requirement from when it was made, and a
            // build signed differently (ad-hoc → Apple Development, 2026-10-26) fails launchd's launch constraint
            // until the record is refreshed. Idempotent otherwise.
            try? service.register()
        case .requiresApproval:
            break
        @unknown default:
            break
        }
        let needsApproval = service.status == .requiresApproval
        if needsApproval { SMAppService.openSystemSettingsLoginItems() }

        // .enabled doesn't mean running (crash, killed by a rebuild). Launch it either way so this
        // session is tracked even while approval is pending. The helper's lock makes a duplicate exit.
        if NSRunningApplication.runningApplications(withBundleIdentifier: RewindModule.trackerBundleID).isEmpty {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            do {
                try await NSWorkspace.shared.openApplication(at: helperURL, configuration: config)
            } catch {
                SupportLog.app.error("helper launch failed: \(error.localizedDescription, privacy: .public)")
                return .failed(error.localizedDescription)
            }
        }
        return needsApproval ? .needsApproval : .running
    }

    /// For the banner's button.
    static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

extension AppHelperLifecycle {
    /// Until the module split (2026-10) Incant and Scry were login items *of this bundle*. Their records would
    /// keep pointing at the deleted copies, so drop them once; the modules register themselves now.
    static func dropLegacySpellLoginItems() async {
        for id in [Spells.incantBundleID, Spells.scryBundleID] {
            let s = SMAppService.loginItem(identifier: id)
            guard s.status != .notFound, s.status != .notRegistered else { continue }
            do { try await s.unregister(); SupportLog.app.info("dropped legacy login item \(id, privacy: .public)") }
            catch { SupportLog.app.error("legacy login item \(id, privacy: .public) not dropped: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
