import Foundation

/// The contract every module shares with the Spells launcher: bundle IDs and the log subsystem.
/// Modules are standalone apps; this is the only place that knows all of their identifiers.
public enum Spells {
    public static let bundlePrefix = "dev.nic.spells"
    /// The launcher: installs nothing itself, lists and starts the modules.
    public static let launcherBundleID = "dev.nic.spells.launcher"
    /// Rewind (time tracking): the former hub, so it keeps the hub's ID and with it the grants TCC attributed to it.
    public static let rewindBundleID = "dev.nic.spells"
    /// Rewind's tracker helper (its login item). Kept as `hours` so Accessibility/Automation grants survive the rename.
    public static let trackerBundleID = "dev.nic.spells.hours"
    /// Where the launcher looks for module apps (`<name>.app` with a `SpellsModule` dictionary in its Info.plist).
    public static let modulesDirectory = URL.homeDirectory.appending(path: "Applications/Spells", directoryHint: .isDirectory)
    /// Info.plist key of a module's manifest: Name, Summary, Symbol, Scheme, LoginItem (bool).
    public static let manifestKey = "SpellsModule"
    /// Settings row a module keeps in step with its own login-item registration ("1"/"0").
    public static let loginItemKey = "login_item"
    /// Apple team that signs every module; the launcher installs nothing signed by anyone else.
    public static let teamID = "P9FVNJVGRB"
    public static let incantBundleID = "dev.nic.spells.incant"
    public static let scryBundleID = "dev.nic.spells.scry"
}

/// The `claude` CLI path, a setting any module may store under the same key.
public enum SpellsClaude {
    public static let key = "claude_path"
    /// Where the installers put it: the native installer's `~/.local/bin`, Homebrew, npm's /usr/local.
    public static let candidates = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude"]
        .map { ($0 as NSString).expandingTildeInPath }
    /// The first candidate that exists and is executable (the first candidate when none is), so a fresh
    /// install works without a setting on any of the usual layouts.
    public static let defaultPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    /// Tilde-expanded; blank or missing → the default.
    public static func path(_ rows: [String: String]) -> String {
        let v = rows[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? defaultPath : (v as NSString).expandingTildeInPath
    }
}
