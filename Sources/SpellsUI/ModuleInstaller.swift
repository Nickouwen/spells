import AppKit
import CoreServices
import CryptoKit
import Security
import SpellsKit

/// Install, update and remove apps from the catalog — modules from the launcher, and every app (the
/// launcher too) for itself. Download → SHA-256 → unzip (ditto keeps the signature intact) → the
/// signature must be Apple-issued for `Spells.teamID` → quit what runs from the old bundle (the app and
/// anything embedded in it, like Rewind's tracker) → the old copy to the Trash, the new one in its place
/// → relaunch. The download never gets a quarantine flag (no sandbox, no opt-in), so Gatekeeper never
/// sees it: the team check here is the gate. Data (settings, hours.db) is never touched.
public enum ModuleInstaller {
    public enum Failure: Error, CustomStringConvertible {
        case download(URL, String)
        case checksum
        case noApp
        case signature(String)
        case stillRunning(String)

        public var description: String {
            switch self {
            case let .download(url, why): "download failed: \(why) (\(url.lastPathComponent))"
            case .checksum: "the download doesn't match the catalog's checksum"
            case .noApp: "the archive holds no app"
            case .signature(let why): "not signed by Spells' team: \(why)"
            case .stillRunning(let name): "\(name) didn't quit; quit it and try again"
            }
        }
    }

    /// An installed app as the installer needs to know it.
    public struct Installed: Sendable {
        public var url: URL
        public var bundleID: String
        public var name: String
        public var scheme: String
        public var loginItem: Bool
        public var atLogin: Bool
        public init(url: URL, bundleID: String, name: String, scheme: String, loginItem: Bool, atLogin: Bool) {
            self.url = url; self.bundleID = bundleID; self.name = name; self.scheme = scheme; self.loginItem = loginItem; self.atLogin = atLogin
        }
    }

    public static func fetchCatalog(from url: URL) async throws -> ModuleCatalog {
        // Always fresh: GitHub's redirect to the asset carries cache headers that would hide a new release.
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.download(url, "HTTP \(http.statusCode)") }
        return try ModuleCatalog.decode(data)
    }

    /// Installs `entry` as a module (replacing `installed` when given) and returns the new app's URL.
    @MainActor
    public static func install(_ entry: ModuleCatalog.Entry, replacing installed: Installed?, status: (String) -> Void) async throws -> URL {
        let (work, app) = try await fetchAndVerify(entry, status: status)
        defer { try? FileManager.default.removeItem(at: work) }
        let wasRunning = installed.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty } ?? false
        if let installed {
            status("Quitting \(installed.name)…")
            try await quit(installed)
            try FileManager.default.trashItem(at: installed.url, resultingItemURL: nil)
        }
        status("Installing…")
        let dest = try place(app, at: Spells.modulesDirectory.appending(path: app.lastPathComponent))
        // A fresh menu-bar module starts at login (what install.sh does); an updated one comes back as it was.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = !entry.loginItem
        if installed == nil, entry.loginItem {
            NSWorkspace.shared.open([ModuleURLs.url(scheme: entry.scheme, verb: "login-item", query: ["on": "1"])], withApplicationAt: dest,
                                    configuration: config, completionHandler: nil)
        } else if installed == nil || wasRunning {
            NSWorkspace.shared.openApplication(at: dest, configuration: config, completionHandler: nil)
        }
        return dest
    }

    /// Replaces the running app's own bundle with `entry` and relaunches it. Returns only on failure
    /// (before anything was replaced); on success the process terminates.
    @MainActor
    public static func updateSelf(_ entry: ModuleCatalog.Entry, status: (String) -> Void) async throws {
        let (work, app) = try await fetchAndVerify(entry, status: status)
        defer { try? FileManager.default.removeItem(at: work) }
        let mine = Bundle.main.bundleURL
        status("Installing…")
        try await quitEmbedded(in: mine)
        try FileManager.default.trashItem(at: mine, resultingItemURL: nil)
        let dest: URL
        do { dest = try place(app, at: mine) } catch {
            // Put the old copy back so the app isn't left in the Trash.
            SupportLog.app.error("self-update: install failed, restoring: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        // A detached shell waits for this process to exit, then opens the new copy (in the background
        // for a menu-bar app). It outlives us: it is not our child once we're gone.
        let relaunch = Process()
        relaunch.executableURL = URL(filePath: "/bin/sh")
        relaunch.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; "
                              + "/usr/bin/open \(entry.loginItem ? "-g " : "")\"$0\"", dest.path]
        try relaunch.run()
        SupportLog.app.info("self-update to \(entry.version, privacy: .public): relaunching")
        NSApp.terminate(nil)
    }

    /// Quits the app, turns its login item off, and moves it to the Trash. Its data stays.
    @MainActor
    public static func remove(_ m: Installed, status: (String) -> Void) async throws {
        status("Removing…")
        if m.loginItem, m.atLogin {
            NSWorkspace.shared.open([ModuleURLs.url(scheme: m.scheme, verb: "login-item", query: ["on": "0"])], withApplicationAt: m.url,
                                    configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            try? await Task.sleep(for: .seconds(1))
        }
        try await quit(m)
        try FileManager.default.trashItem(at: m.url, resultingItemURL: nil)
    }

    // MARK: - Steps

    /// Download + checksum + unzip + signature → (work dir to delete, the app inside it).
    @MainActor
    private static func fetchAndVerify(_ entry: ModuleCatalog.Entry, status: (String) -> Void) async throws -> (URL, URL) {
        status("Downloading…")
        let work = FileManager.default.temporaryDirectory.appending(path: "spells-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appending(path: "module.zip")
        do {
            let (tmp, response) = try await URLSession.shared.download(from: entry.url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.download(entry.url, "HTTP \(http.statusCode)") }
            try FileManager.default.moveItem(at: tmp, to: zip)
        } catch let e as Failure { throw e } catch { throw Failure.download(entry.url, error.localizedDescription) }

        status("Verifying…")
        let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256.lowercased() else { throw Failure.checksum }
        let unpacked = work.appending(path: "unpacked", directoryHint: .isDirectory)
        let r = try SupportProcess.run(URL(filePath: "/usr/bin/ditto"), ["-x", "-k", zip.path, unpacked.path], timeout: 120)
        guard r.status == 0 else { throw Failure.download(entry.url, "unzip: \(r.stderrText)") }
        guard let app = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw Failure.noApp }
        try verify(app)
        return (work, app)
    }

    private static func place(_ app: URL, at dest: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.trashItem(at: dest, resultingItemURL: nil) }
        try FileManager.default.moveItem(at: app, to: dest)
        LSRegisterURL(dest as CFURL, true)
        return dest
    }

    /// `quit` verb first (the module saves and exits cleanly), then terminate(); then whatever is
    /// embedded in its bundle; up to ~8 s.
    @MainActor
    private static func quit(_ m: Installed) async throws {
        func running() -> [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: m.bundleID) }
        if !running().isEmpty {
            NSWorkspace.shared.open([ModuleURLs.url(scheme: m.scheme, verb: "quit")], withApplicationAt: m.url,
                                    configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            for i in 0..<32 {
                try? await Task.sleep(for: .milliseconds(250))
                if running().isEmpty { break }
                if i == 15 { running().forEach { $0.terminate() } }
            }
            guard running().isEmpty else { throw Failure.stillRunning(m.name) }
        }
        try await quitEmbedded(in: m.url)
    }

    /// Helpers living inside `bundle` (Rewind's tracker login item) would keep running from the Trash;
    /// the relaunched app starts fresh ones.
    @MainActor
    private static func quitEmbedded(in bundle: URL) async throws {
        func embedded() -> [NSRunningApplication] {
            NSWorkspace.shared.runningApplications.filter {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                    && ($0.bundleURL?.path.hasPrefix(bundle.path + "/") ?? false)
            }
        }
        let apps = embedded()
        guard !apps.isEmpty else { return }
        apps.forEach { $0.terminate() }
        for _ in 0..<32 {
            try? await Task.sleep(for: .milliseconds(250))
            if embedded().isEmpty { return }
        }
        throw Failure.stillRunning(apps[0].localizedName ?? "a helper")
    }

    /// Valid signature over every nested code, from an Apple-issued certificate for `Spells.teamID`.
    public static func verify(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw Failure.signature("unreadable") }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(Spells.teamID)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess else { throw Failure.signature("bad requirement") }
        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            let why = error?.takeRetainedValue().localizedDescription ?? SecCopyErrorMessageString(status, nil).map { String($0) } ?? "OSStatus \(status)"
            throw Failure.signature(why)
        }
    }
}
