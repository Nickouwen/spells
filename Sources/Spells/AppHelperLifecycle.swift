import AppKit
import HoursCore
import HoursUI
import ServiceManagement

/// App side of the helper's lifecycle: keep HoursSpell registered as a login item and running.
/// Call on launch (and when the window reopens); render the returned status as the banner.
@MainActor
enum AppHelperLifecycle {
    static var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Library/LoginItems/HoursSpell.app")
    }

    static func ensureTrackerRunning() async -> TrackerHelperStatus {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .notBundled }
        guard FileManager.default.fileExists(atPath: helperURL.path) else { return .helperMissing }

        let service = SMAppService.loginItem(identifier: Hours.trackerBundleID)
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
        case .requiresApproval, .enabled:
            break
        @unknown default:
            break
        }
        let needsApproval = service.status == .requiresApproval
        if needsApproval { SMAppService.openSystemSettingsLoginItems() }

        // .enabled doesn't mean running (crash, killed by a rebuild). Launch it either way so this
        // session is tracked even while approval is pending. The helper's lock makes a duplicate exit.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Hours.trackerBundleID).isEmpty {
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

/// Incant's login item: registered only while switched on in Settings → Spells.
@MainActor
enum IncantLifecycle {
    static var helperURL: URL { Bundle.main.bundleURL.appending(path: "Contents/Library/LoginItems/Incant.app") }
    static var service: SMAppService { SMAppService.loginItem(identifier: Hours.incantBundleID) }
    static var running: [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: Hours.incantBundleID) }

    static func state() -> SpellSwitch.State {
        switch service.status {
        case .enabled: .on(running: !running.isEmpty)
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    static func set(_ on: Bool) async -> String? {
        do {
            if on {
                do { try service.register() } catch where service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
                try await launchIfNeeded()
            } else {
                try await service.unregister()
                running.forEach { $0.terminate() }
            }
            return nil
        } catch {
            SupportLog.app.error("incant switch failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    /// On launch (and after a reinstall killed it): start it again if it's switched on.
    static func launchIfNeeded() async throws {
        guard Bundle.main.bundleURL.pathExtension == "app", service.status != .notRegistered,
              service.status != .notFound, running.isEmpty else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: helperURL, configuration: config)
    }

    static var spellSwitch: SpellSwitch { SpellSwitch(state: { state() }, set: { await set($0) }) }
}

/// Scry's login item: registered only while switched on in Settings → Spells (same shape as Incant's).
@MainActor
enum ScryLifecycle {
    static var helperURL: URL { Bundle.main.bundleURL.appending(path: "Contents/Library/LoginItems/Scry.app") }
    static var service: SMAppService { SMAppService.loginItem(identifier: Hours.scryBundleID) }
    static var running: [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: Hours.scryBundleID) }

    static func state() -> SpellSwitch.State {
        switch service.status {
        case .enabled: .on(running: !running.isEmpty)
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    static func set(_ on: Bool) async -> String? {
        do {
            if on {
                do { try service.register() } catch where service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
                try await launchIfNeeded()
            } else {
                try await service.unregister()
                running.forEach { $0.terminate() }
            }
            return nil
        } catch {
            SupportLog.app.error("scry switch failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    static func launchIfNeeded() async throws {
        guard Bundle.main.bundleURL.pathExtension == "app", service.status != .notRegistered,
              service.status != .notFound, running.isEmpty else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: helperURL, configuration: config)
    }

    static var spellSwitch: SpellSwitch { SpellSwitch(state: { state() }, set: { await set($0) }) }
}
