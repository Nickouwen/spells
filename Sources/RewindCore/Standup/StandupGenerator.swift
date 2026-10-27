import CryptoKit
import Foundation
import ScryCore

/// The EOD standup pipeline: transcript dump (`StandupDump`) → redact → condense → time context + previous standup
/// → `claude -p --model sonnet` → `standup` row. Blocking (up to ~5 min); call it off the main actor.
public enum StandupGenerator {
    public enum Outcome: Sendable {
        case generated(Standup)
        /// A standup is already stored for the day and `regenerate` was false.
        case exists(Standup)
    }

    public enum Failure: Error, CustomStringConvertible {
        case emptyDump(LocalDate)
        case claudeMissing(String)
        case claudeFailed(Int32, String)
        case badOutput(String)

        public var description: String {
            switch self {
            case .emptyDump(let d): "no Claude Code transcript activity found for \(d)"
            case .claudeMissing(let p): "claude CLI not found or not executable: \(p) (setting \(StandupSettings.claudePathKey))"
            case let .claudeFailed(code, err): "claude -p failed (exit \(code)): \(err)"
            case .badOutput(let s): "claude returned something that isn't a standup: \(s.prefix(300))"
            }
        }
    }

    public static let model = "sonnet"
    public static let claudeTimeout: TimeInterval = 300   // the full day's dump can take a while

    /// The two process boundaries, swappable in tests.
    public struct Runner: Sendable {
        /// The day's transcripts in `StandupDump` form.
        public var dump: @Sendable (_ date: LocalDate) throws -> String
        /// → (standup text, model id that answered)
        public var claude: @Sendable (_ path: String, _ prompt: String) throws -> (text: String, model: String)
        /// Excluded repo names → session ids (8-char prefixes) whose cwd is in one of them.
        public var excludedSessions: @Sendable (_ repos: Set<String>) -> Set<String>
        /// The Scry notes folder for the "Meetings (Scry)" section; nil = no meetings.
        /// Live: `scryRoot(paths:)`. Test runners default to nil, so they never read the real folder.
        public var scryRoot: @Sendable () -> URL?

        public init(dump: @escaping @Sendable (LocalDate) throws -> String,
                    claude: @escaping @Sendable (String, String) throws -> (text: String, model: String),
                    excludedSessions: @escaping @Sendable (Set<String>) -> Set<String> = { _ in [] },
                    scryRoot: @escaping @Sendable () -> URL? = { nil }) {
            self.dump = dump; self.claude = claude; self.excludedSessions = excludedSessions; self.scryRoot = scryRoot
        }

        public static let live = Runner(dump: { StandupDump.dump(date: $0) }, claude: liveClaude, excludedSessions: { liveExcludedSessions($0) },
                                        scryRoot: { StandupGenerator.scryRoot(paths: .current()) })
    }

    /// Scry's notes folder from its settings file (its default folder when Scry has never saved one).
    public static func scryRoot(paths: SupportPaths) -> URL { ScrySettings.load(SpellSettingsFile.scry(paths).all()).rootURL }

    /// What a regeneration does with the stored corrections.
    public enum Corrections: Sendable, Equatable {
        case keep
        /// Appends one and revises the current text with it (implies regenerate).
        case add(String)
        /// Starts over without them.
        case clear
    }

    /// Generates and stores the standup for `date` unless one exists (any stored row, edited or not)
    /// and `regenerate` is false. `from` before `date` makes a combined standup for the span, stored
    /// under `date`; nil reuses the stored span. Both span and corrections stick to the row, so the
    /// hourly refresh keeps them.
    @discardableResult
    public static func run(db: RewindDB, date: LocalDate, from: LocalDate? = nil, regenerate: Bool = false,
                           corrections: Corrections = .keep,
                           nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000), runner: Runner = .live) throws -> Outcome {
        let store = StandupStore(db)
        let existing = try store.get(date)
        if case .add = corrections {} else if !regenerate, let existing { return .exists(existing) }
        let start = min(from ?? existing?.fromDate ?? date, date)
        var fixes = corrections == .clear ? [] : existing?.corrections ?? []
        var draft: String?
        if case .add(let fix) = corrections {
            let line = fix.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { fixes.append(line) }
            draft = existing?.body
        }
        let settings = StandupSettings.load(try SettingStore(db).all())
        let prompt = try prompt(db: db, from: start, to: date, settings: settings, runner: runner, corrections: fixes, draft: draft)
        let reply = try runner.claude(settings.claudePath, prompt)
        let body = try clean(reply.text, name: settings.name)
        let sha = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        try store.saveGenerated(date, body: body, generatedMs: nowMs, inputsSha256: sha, model: reply.model,
                                fromDate: start < date ? start : nil, instructions: fixes.isEmpty ? nil : fixes.joined(separator: "\n"))
        return .generated(try store.get(date)!)
    }

    /// The full `claude -p` stdin for `date` (redacted, capped).
    public static func prompt(db: RewindDB, date: LocalDate, settings: StandupSettings, runner: Runner) throws -> String {
        try prompt(db: db, from: date, to: date, settings: settings, runner: runner)
    }

    /// The `claude -p` stdin for `from`...`to`: each day's dump, condensed to an equal share of the cap.
    /// Days with no log are left out; all empty throws `emptyDump`.
    // ponytail: one transcript scan per day; fine for a week or two.
    public static func prompt(db: RewindDB, from: LocalDate, to: LocalDate, settings: StandupSettings, runner: Runner,
                              corrections: [String] = [], draft: String? = nil) throws -> String {
        var dates = [from]
        while dates.last! < to { dates.append(dates.last!.storeNextDay()) }
        let excludedSids = settings.excludeRepos.isEmpty ? [] : runner.excludedSessions(settings.excludeRepos)
        let config = try ExportConfig.load(db)
        let classifier = Classifier(categories: config.categories, rules: config.rules, projects: config.projects)
        let notes = (runner.scryRoot().map(scryNotes) ?? []).map(\.note)
        var days: [StandupPrompt.Day] = []
        for date in dates {
            let raw = try runner.dump(date)
            let dump = StandupPrompt.condense(StandupRedact.redact(raw, allowEmails: settings.allowEmails), excluding: excludedSids,
                                              cap: StandupPrompt.dumpCap / dates.count)
            if dump.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            // ponytail: Rewind's 04:00 store day vs the dump's calendar day — a 00:00–04:00 stretch lands on
            // different days in the two inputs. Fine for effort weighting.
            let spans = classifier.classifyAll(try Store(db).effectiveSpans(day: date))
            let metrics = DayMetrics.compute(spans: spans, categories: config.categories)
            let day = date.dayInterval(in: .current)
            let meetings = notes.filter { day.contains(Int64($0.meta.startedAt.timeIntervalSince1970 * 1000)) }
            days.append(.init(date: date, timeContext: StandupPrompt.timeContext(metrics, projects: config.projects),
                              meetings: StandupRedact.redact(StandupPrompt.meetingsContext(meetings), allowEmails: settings.allowEmails),
                              dump: dump))
        }
        if days.isEmpty { throw Failure.emptyDump(to) }
        return StandupPrompt.build(name: settings.name, from: from, to: to, days: days, previous: try StandupStore(db).previous(before: from),
                                   excluded: settings.excludeRepos, corrections: corrections, draft: draft)
    }

    /// Every Scry note under `root`, newest first (`ScryNotes.load`).
    public static func scryNotes(in root: URL) -> [(url: URL, markdown: String, note: ScryNote)] {
        ScryNotes.load(root).map { ($0.url, $0.markdown, $0.note) }
    }

    /// Sessions map to repos through Claude Code's own layout (the dump's USER tags carry only the
    /// cwd's last component, which can't tell `foo/hours` from `bar/hours`):
    /// `~/.claude/projects/<cwd with / and . as ->/<session-id>.jsonl`. A project dir belongs to repo
    /// `r` when its name ends in `-r` or contains `-r-` (worktrees: `…-GitHub-hours--claude-worktrees-…`).
    // ponytail: matches the repo name anywhere in the path, so a dir called `hours` inside another
    // repo would also be excluded. Directory listings only; no transcript is read.
    static func liveExcludedSessions(_ repos: Set<String>,
                                     projects: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")) -> Set<String> {
        let fm = FileManager.default
        let encoded = repos.map { "-" + $0.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-") }
        var sids = Set<String>()
        for dir in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? []
        where encoded.contains(where: { dir.hasSuffix($0) || dir.contains($0 + "-") }) {
            for f in (try? fm.contentsOfDirectory(atPath: projects.appending(path: dir).path)) ?? [] where f.hasSuffix(".jsonl") {
                sids.insert(String(f.prefix(8)))
            }
        }
        return sids
    }

    /// Strips code fences / stray preamble; requires the section labels.
    static func clean(_ text: String, name: String) throws -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        if let first = lines.firstIndex(where: { $0.hasPrefix(name) || $0.contains(" - EOD ") }) { lines.removeFirst(first) }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.contains("Worked On:"), body.contains("Carry-Forward:") else { throw Failure.badOutput(body) }
        return body
    }

    // MARK: - Live processes

    /// `claude -p` isolated from the user's setup: no tools, no MCP servers, no hooks/CLAUDE.md/plugins
    /// (`--safe-mode`), no transcript written (so tomorrow's dump doesn't contain today's prompt).
    @Sendable static func liveClaude(_ path: String, _ prompt: String) throws -> (text: String, model: String) {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw Failure.claudeMissing(path) }
        let args = ["-p", "--model", model, "--output-format", "json", "--safe-mode", "--no-session-persistence",
                    "--tools", "", "--strict-mcp-config", "--system-prompt", StandupPrompt.systemPrompt]
        let r = try SupportProcess.run(URL(filePath: path), args, stdin: Data(prompt.utf8), timeout: claudeTimeout)
        let json = (try? JSONSerialization.jsonObject(with: r.stdout)) as? [String: Any]
        guard r.status == 0, let json, json["is_error"] as? Bool != true, let text = json["result"] as? String else {
            let detail = (json?["result"] as? String).map { "\($0) " } ?? ""
            throw Failure.claudeFailed(r.status, detail + r.stderrText)
        }
        let used = (json["modelUsage"] as? [String: Any])?.keys.sorted().first ?? model
        return (text, used)
    }
}
