import Foundation

/// Ward: a rolling packet capture of what this Mac connects to, kept for forensic audits. A root
/// LaunchDaemon runs dumpcap on the egress interface into a ring of files (the oldest dropped as new
/// ones fill), with a snaplen that keeps IP/TCP headers, whole DNS and TLS SNI and little payload.
/// First set up on 2026-11-02 after a macOS infostealer; the shell scripts under Resources/Ward/scripts
/// are that setup, audit and uninstall, plus a snapshot the app reads. Everything here is pure: the
/// daemon's facts, and parsing of what the scripts and the system report.
public enum Ward {
    public static let label = "com.bluepeak.netcap"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    public static let captureDir = "/var/log/netcap"
    public static let dumpcap = "/opt/homebrew/bin/dumpcap"
    public static let tshark = "/opt/homebrew/bin/tshark"
    public static let interface = "en0"
    /// Bytes kept per packet: enough for IP/TCP headers, a whole DNS message and a TLS ClientHello's SNI.
    public static let snaplen = 256
    public static let fileKiB = 51_200, files = 20
    public static var ringBytes: Int64 { Int64(fileKiB) * 1024 * Int64(files) }
    public static let setupScript = "netcap-setup.sh", auditScript = "netcap-audit.sh",
                      uninstallScript = "netcap-uninstall.sh", iocScript = "netcap-ioc-check.sh", snapshotScript = "netcap-snapshot.sh"

    public static let whatItKeeps = """
    Every packet leaving or entering \(interface) is written to a ring of \(files) files of \(fileKiB / 1024) MiB; when the ring is full the oldest file is deleted, so the capture holds roughly the last day to week of traffic depending on how busy the Mac is. Only the first \(snaplen) bytes of each packet are kept: that is the IP and TCP headers (who was talked to, when, how much), whole DNS lookups (which names were resolved) and the server name in TLS handshakes (which sites were opened), and almost none of the content. Traffic inside a VPN tunnel shows as the tunnel's endpoint, not the sites behind it. The files are owned by root, so reading them asks for your password.
    """
}

/// Whether the daemon is installed and capturing, from what the system says without root.
public struct WardStatus: Equatable, Sendable {
    public enum Daemon: Equatable, Sendable {
        case notInstalled
        /// Loaded in launchd; `pid` while dumpcap runs.
        case loaded(pid: Int?)
        /// The plist is there but launchd doesn't have it.
        case stopped
    }
    public var daemon: Daemon
    public var toolsInstalled: Bool
    public init(daemon: Daemon, toolsInstalled: Bool) { self.daemon = daemon; self.toolsInstalled = toolsInstalled }

    public var running: Bool { if case .loaded(let pid) = daemon, pid != nil { return true } else { return false } }
    public var installed: Bool { daemon != .notInstalled }

    /// `launchctl print system/<label>` (nil when the command failed: not loaded), whether the plist
    /// exists, and whether dumpcap and tshark are present.
    public static func parse(launchctl: String?, plistExists: Bool, tools: Bool) -> WardStatus {
        let daemon: Daemon
        if let out = launchctl {
            let pid = out.firstMatch(of: /pid = (\d+)/).flatMap { Int($0.1) }
            daemon = .loaded(pid: pid)
        } else {
            daemon = plistExists ? .stopped : .notInstalled
        }
        return WardStatus(daemon: daemon, toolsInstalled: tools)
    }

    public var title: String {
        switch daemon {
        case .loaded(let pid?): "Capturing (pid \(pid))"
        case .loaded(nil): "Loaded, dumpcap not running"
        case .stopped: "Installed, not loaded"
        case .notInstalled: "Not installed"
        }
    }
}

/// One privileged read of the captures (`netcap-snapshot.sh`): the ring's facts, then the audit
/// tables and the IOC scan. Cached on disk by the app so the last one shows without a password.
public struct WardSnapshot: Equatable, Sendable, Codable {
    public struct Hit: Equatable, Sendable, Codable, Identifiable {
        public var count: Int, name: String
        public var id: String { name }
        public init(count: Int, name: String) { self.count = count; self.name = name }
    }
    public var takenAt: Date
    /// The tshark display filter the tables were made with; "" = everything retained.
    public var window = ""
    public var files = 0
    public var bytes: Int64 = 0
    public var first: Date?, last: Date?
    public var destinations: [Hit] = [], dns: [Hit] = [], sni: [Hit] = []
    /// Lines of traffic matching the known-bad indicators (empty = clean).
    public var iocHits: [String] = []
    public var errors: [String] = []
    public init(takenAt: Date) { self.takenAt = takenAt }

    /// The script's report: `key<TAB>value` facts, then `section<TAB>name` headers with `count<TAB>name`
    /// rows (IOC rows are raw lines). Unknown keys are ignored.
    public static func parse(_ text: String, takenAt: Date = .now) -> WardSnapshot {
        var s = WardSnapshot(takenAt: takenAt)
        var section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if section.isEmpty || parts.first == "section" {
                switch (parts.first ?? "", parts.count > 1 ? parts[1] : "") {
                case ("section", let name): section = name
                case ("files", let v): s.files = Int(v) ?? 0
                case ("bytes", let v): s.bytes = Int64(v) ?? 0
                case ("first", let v): s.first = epoch(v)
                case ("last", let v): s.last = epoch(v)
                case ("window", let v): s.window = v
                case ("error", let v): s.errors.append(v)
                default: break
                }
                continue
            }
            switch section {
            case "dst": if let h = hit(parts) { s.destinations.append(h) }
            case "dns": if let h = hit(parts) { s.dns.append(h) }
            case "sni": if let h = hit(parts) { s.sni.append(h) }
            case "ioc": if !line.trimmingCharacters(in: .whitespaces).isEmpty { s.iocHits.append(line) }
            default: break
            }
        }
        return s
    }

    static func hit(_ parts: [String]) -> Hit? {
        guard parts.count == 2, let n = Int(parts[0].trimmingCharacters(in: .whitespaces)), !parts[1].isEmpty else { return nil }
        return Hit(count: n, name: parts[1])
    }

    /// `1762102800.123456` (capinfos -S) or `2026-11-02 09:00:00…` (capinfos without it).
    static func epoch(_ v: String) -> Date? {
        let t = v.trimmingCharacters(in: .whitespaces)
        if let secs = Double(t) { return Date(timeIntervalSince1970: secs) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: String(t.prefix(19)))
    }

    /// `first…last` as a length, nil without both.
    public var coverage: TimeInterval? {
        guard let first, let last, last > first else { return nil }
        return last.timeIntervalSince(first)
    }
}

/// The windows a snapshot can be narrowed to: a tshark `frame.time` filter from `now`.
public enum WardWindow: String, CaseIterable, Identifiable, Sendable {
    case hour, day, all
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .hour: "Last hour"
        case .day: "Last 24 h"
        case .all: "Everything kept"
        }
    }
    /// The display filter, "" for all. Also the epoch seconds a capture file must have been written
    /// after to matter (the script skips older files).
    public func filter(now: Date = .now) -> (display: String, sinceEpoch: Int) {
        let since: Date
        switch self {
        case .hour: since = now.addingTimeInterval(-3600)
        case .day: since = now.addingTimeInterval(-86_400)
        case .all: return ("", 0)
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return ("frame.time >= \"\(f.string(from: since))\"", Int(since.timeIntervalSince1970))
    }
}
