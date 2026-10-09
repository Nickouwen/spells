import os

/// os.Logger per category, subsystem `dev.nic.spells`.
/// Read: `log stream --predicate 'subsystem == "dev.nic.spells"' --level debug`.
/// Never log window titles or URLs; if unavoidable, interpolate with `privacy: .private`.
/// The CLI prints to stderr instead of using these.
public enum SupportLog {
    public static let subsystem = Hours.bundlePrefix

    public static let tracker = Logger(subsystem: subsystem, category: "tracker")
    public static let ax = Logger(subsystem: subsystem, category: "ax")
    public static let db = Logger(subsystem: subsystem, category: "db")
    public static let backup = Logger(subsystem: subsystem, category: "backup")
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let cli = Logger(subsystem: subsystem, category: "cli")
    public static let incant = Logger(subsystem: subsystem, category: "incant")
    public static let scry = Logger(subsystem: subsystem, category: "scry")
}
