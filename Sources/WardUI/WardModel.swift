import AppKit
import Observation
import SpellsKit
import WardCore

/// Ward's state: the daemon's status (polled while the view shows), the last snapshot of the captures
/// (cached in Ward's folder so it shows without a password), and the audit table being looked at.
@MainActor @Observable public final class WardModel {
    public enum Table: String, CaseIterable, Identifiable, Sendable {
        case destinations, dns, sni
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .destinations: "Destinations"
            case .dns: "DNS names"
            case .sni: "TLS names"
            }
        }
    }

    public private(set) var status = WardStatus(daemon: .notInstalled, toolsInstalled: false)
    public private(set) var snapshot: WardSnapshot?
    public var window: WardWindow = .day
    public var table: Table = .destinations
    public var query = ""
    /// What's running as root right now, shown next to a spinner; nil when idle.
    public private(set) var busy: String?
    public private(set) var error: String?
    let cache: URL
    private var ticker: Task<Void, Never>?

    public init(paths: SupportPaths = .current()) {
        cache = paths.home.appending(path: "ward", directoryHint: .isDirectory).appending(path: "snapshot.tsv")
    }

    public func start() {
        loadCache()
        refreshStatus()
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.refreshStatus()
            }
        }
    }

    public func stop() { ticker?.cancel(); ticker = nil }

    /// The table's rows, narrowed by the search field.
    public var rows: [WardSnapshot.Hit] {
        guard let s = snapshot else { return [] }
        let all: [WardSnapshot.Hit] = switch table {
        case .destinations: s.destinations
        case .dns: s.dns
        case .sni: s.sni
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    public var scriptsDir: URL { WardSystem.scriptsDir }

    public func refreshStatus() {
        Task { [weak self] in
            let s = await WardSystem.status()
            self?.status = s
        }
    }

    /// Reads the captures as root (one password prompt) and keeps the report.
    public func takeSnapshot() {
        let (display, since) = window.filter()
        privileged("Reading the captures…", Ward.snapshotScript, [cache.path, String(getuid()), display, String(since)]) { [weak self] in
            self?.loadCache()
        }
    }

    public func install() { privileged("Installing the capture…", Ward.setupScript, []) { [weak self] in self?.refreshStatus() } }
    public func uninstall() { privileged("Removing the capture…", Ward.uninstallScript, []) { [weak self] in self?.refreshStatus() } }

    private func privileged(_ what: String, _ script: String, _ args: [String], then: @escaping @MainActor () -> Void) {
        guard busy == nil else { return }
        busy = what
        error = nil
        Task {
            do {
                _ = try await WardSystem.privileged(script, args)
                then()
                SupportLog.ward.info("\(script, privacy: .public) ran")
            } catch let f as WardSystem.Failure where f.cancelled {
                // The password dialog was dismissed: nothing to say.
            } catch {
                self.error = error.localizedDescription
                SupportLog.ward.error("\(script, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            busy = nil
        }
    }

    public func revealScripts() { NSWorkspace.shared.activateFileViewerSelecting([scriptsDir.appending(path: Ward.setupScript)]) }

    func loadCache() {
        guard let data = try? Data(contentsOf: cache) else { return }
        let taken = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
        snapshot = WardSnapshot.parse(String(decoding: data, as: UTF8.self), takenAt: taken)
    }
}
