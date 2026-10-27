import AppKit
import CoreServices
import CryptoKit
import Security
import SpellsKit
import SpellsUI

/// Install, update and remove module apps from the catalog. Download → SHA-256 → unzip (ditto keeps
/// the signature intact) → the signature must be Apple-issued for `Spells.teamID` → quit the module
/// if it runs → the old copy to the Trash, the new one into ~/Applications/Spells → relaunch.
/// The download never gets a quarantine flag (the launcher isn't sandboxed and doesn't opt in), so
/// Gatekeeper never sees it: the team check here is the gate. Data (settings, hours.db) is never touched.
enum ModuleInstaller {
    enum Failure: Error, CustomStringConvertible {
        case download(URL, String)
        case checksum
        case noApp
        case signature(String)
        case stillRunning(String)

        var description: String {
            switch self {
            case let .download(url, why): "download failed: \(why) (\(url.lastPathComponent))"
            case .checksum: "the download doesn't match the catalog's checksum"
            case .noApp: "the archive holds no app"
            case .signature(let why): "not signed by Spells' team: \(why)"
            case .stillRunning(let name): "\(name) didn't quit; quit it and try again"
            }
        }
    }

    static func fetchCatalog(from url: URL) async throws -> ModuleCatalog {
        // Always fresh: GitHub's redirect to the asset carries cache headers that would hide a new release.
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.download(url, "HTTP \(http.statusCode)") }
        return try ModuleCatalog.decode(data)
    }

    /// Installs `entry` (replacing `installed` when given) and returns the new app's URL.
    @MainActor
    static func install(_ entry: ModuleCatalog.Entry, replacing installed: InstalledModule?, status: (String) -> Void) async throws -> URL {
        status("Downloading…")
        let work = FileManager.default.temporaryDirectory.appending(path: "spells-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
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

        let wasRunning = installed?.running ?? false
        if let installed {
            status("Quitting \(installed.name)…")
            try await quit(installed)
            try FileManager.default.trashItem(at: installed.url, resultingItemURL: nil)
        }
        status("Installing…")
        try FileManager.default.createDirectory(at: Spells.modulesDirectory, withIntermediateDirectories: true)
        let dest = Spells.modulesDirectory.appending(path: app.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.trashItem(at: dest, resultingItemURL: nil) }
        try FileManager.default.moveItem(at: app, to: dest)
        LSRegisterURL(dest as CFURL, true)

        // A fresh menu-bar module starts at login (what install.sh does); an updated one comes back as it was.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = !entry.loginItem
        if installed == nil, entry.loginItem {
            NSWorkspace.shared.open([ModuleURLs.url(scheme: entry.scheme, verb: "login-item", query: ["on": "1"])], withApplicationAt: dest, configuration: config, completionHandler: nil)
        } else if installed == nil || wasRunning {
            NSWorkspace.shared.openApplication(at: dest, configuration: config, completionHandler: nil)
        }
        return dest
    }

    /// Quits the module, turns its login item off, and moves the app to the Trash. Its data stays.
    @MainActor
    static func remove(_ m: InstalledModule, status: (String) -> Void) async throws {
        status("Removing…")
        if m.loginItem, m.atLogin {
            NSWorkspace.shared.open([ModuleURLs.url(scheme: m.scheme, verb: "login-item", query: ["on": "0"])], withApplicationAt: m.url,
                                    configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            try? await Task.sleep(for: .seconds(1))
        }
        try await quit(m)
        try FileManager.default.trashItem(at: m.url, resultingItemURL: nil)
    }

    /// `quit` verb first (the module saves and exits cleanly), then terminate(); up to ~8 s.
    @MainActor
    private static func quit(_ m: InstalledModule) async throws {
        func running() -> [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: m.bundleID) }
        guard !running().isEmpty else { return }
        NSWorkspace.shared.open([ModuleURLs.url(scheme: m.scheme, verb: "quit")], withApplicationAt: m.url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        for i in 0..<32 {
            try? await Task.sleep(for: .milliseconds(250))
            if running().isEmpty { return }
            if i == 15 { running().forEach { $0.terminate() } }
        }
        throw Failure.stillRunning(m.name)
    }

    /// Valid signature over every nested code, from an Apple-issued certificate for `Spells.teamID`.
    static func verify(_ app: URL) throws {
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
