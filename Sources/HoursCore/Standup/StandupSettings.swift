import Foundation

/// Standup settings (all in `setting`), shared by spells, the app and the helper.
public struct StandupSettings: Sendable, Equatable {
    public static let enabledKey = "standup_enabled"
    public static let nameKey = "standup_name"
    public static let timeKey = "standup_time"
    public static let weekdaysKey = "standup_weekdays"
    public static let claudePathKey = "claude_path"
    public static let dumpScriptKey = "standup_dump_script"
    public static let allowEmailsKey = "standup_allow_emails"
    /// CSV of repo directory names whose Claude sessions are personal side projects, not work.
    public static let excludeReposKey = "standup_exclude_repos"

    public static let defaultName = "Example User"
    public static let defaultClaudePath = "/opt/homebrew/bin/claude"
    public static let defaultDumpScript = "~/.claude/shared/scripts/cc-day-dump.sh"
    /// Example addresses survive redaction; every other email is redacted.
    public static let defaultAllowEmails = "dev@example.com"

    public var enabled = false
    public var name = defaultName
    /// Minutes after local midnight; default 17:00.
    public var timeMinutes = 17 * 60
    /// Calendar weekdays (1 = Sunday), same convention as `goal.weekdays`; default Mon–Fri.
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    public var claudePath = defaultClaudePath
    /// Tilde-expanded.
    public var dumpScript = (defaultDumpScript as NSString).expandingTildeInPath
    public var allowEmails: Set<String> = [defaultAllowEmails]
    /// Default: the Hours tracker itself.
    public var excludeRepos: Set<String> = ["spells", "hours"]   // "hours": transcripts from before the rename

    public init() {}

    public static func load(_ s: [String: String]) -> StandupSettings {
        var v = StandupSettings()
        func nonEmpty(_ k: String) -> String? {
            s[k].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let e = s[enabledKey] { v.enabled = e != "0" && e != "false" }
        if let n = nonEmpty(nameKey) { v.name = n }
        if let t = nonEmpty(timeKey).flatMap(parseTime) { v.timeMinutes = t }
        if let w = s[weekdaysKey] { v.weekdays = Set(w.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { (1...7).contains($0) }) }
        if let c = nonEmpty(claudePathKey) { v.claudePath = (c as NSString).expandingTildeInPath }
        if let d = nonEmpty(dumpScriptKey) { v.dumpScript = (d as NSString).expandingTildeInPath }
        if let a = s[allowEmailsKey] {
            v.allowEmails = Set(a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        }
        if let r = s[excludeReposKey] {
            v.excludeRepos = Set(r.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        return v
    }

    /// "HH:MM" (24 h) → minutes after midnight.
    public static func parseTime(_ s: String) -> Int? {
        let p = s.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    public static func formatTime(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    /// The helper's auto-run gate: enabled, a scheduled weekday, and at/after `standup_time` (local).
    public func isDue(at date: Date, in tz: TimeZone) -> Bool {
        guard enabled else { return false }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let c = cal.dateComponents([.weekday, .hour, .minute], from: date)
        return weekdays.contains(c.weekday!) && c.hour! * 60 + c.minute! >= timeMinutes
    }

    /// After the first run, the helper regenerates hourly while the day's work goes on.
    public static let refreshMs: Int64 = 3_600_000

    /// Regenerate the stored standup: nobody edited it, it and the last attempt are over an hour old,
    /// and a transcript changed since it was made.
    public static func refreshDue(_ s: Standup, nowMs: Int64, lastAttemptMs: Int64, newestTranscriptMs: Int64) -> Bool {
        guard s.editedMs == nil, let gen = s.generatedMs else { return false }
        return nowMs - gen >= refreshMs && nowMs - lastAttemptMs >= refreshMs && newestTranscriptMs > gen
    }

    /// Newest `.jsonl` modification under the transcript roots (Claude Code projects minus subagents,
    /// Codex sessions), in ms; 0 when there are none.
    public static func newestTranscriptMs(roots: [URL] = transcriptRoots) -> Int64 {
        var newest: Int64 = 0
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in e {
                if url.lastPathComponent == "subagents" { e.skipDescendants(); continue }
                guard url.pathExtension == "jsonl",
                      let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                newest = max(newest, Int64(d.timeIntervalSince1970 * 1000))
            }
        }
        return newest
    }

    public static let transcriptRoots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appending(path: ".claude/projects"), home.appending(path: ".codex/sessions")]
    }()
}

extension LocalDate {
    /// Standup days are calendar days (the transcript dump script's boundary), not the 04:00 store day.
    public static func standupDay(containing date: Date, in tz: TimeZone) -> LocalDate {
        containing(ms: Int64((date.timeIntervalSince1970 * 1000).rounded(.down)), in: tz, dayStartHour: 0)
    }

    /// Strict `YYYY-MM-DD`.
    public init?(iso s: String) {
        guard let d = ExportPeriod.date(s) else { return nil }
        self = d
    }
}
