import CryptoKit
import Foundation
import ScryCore

/// The EOD standup pipeline: transcript dump → redact → condense → time context + previous standup
/// → `claude -p --model sonnet` → `standup` row. Blocking (up to ~5 min); call it off the main actor.
public enum StandupGenerator {
    public enum Outcome: Sendable {
        case generated(Standup)
        /// A standup is already stored for the day and `regenerate` was false.
        case exists(Standup)
    }

    public enum Failure: Error, CustomStringConvertible {
        case dumpScriptMissing(String)
        case dumpFailed(Int32, String)
        case emptyDump(LocalDate)
        case claudeMissing(String)
        case claudeFailed(Int32, String)
        case badOutput(String)

        public var description: String {
            switch self {
            case .dumpScriptMissing(let p): "transcript dump script not found or not executable: \(p) (setting \(StandupSettings.dumpScriptKey))"
            case let .dumpFailed(code, err): "transcript dump failed (exit \(code)): \(err)"
            case .emptyDump(let d): "no Claude Code transcript activity found for \(d)"
            case .claudeMissing(let p): "claude CLI not found or not executable: \(p) (setting \(StandupSettings.claudePathKey))"
            case let .claudeFailed(code, err): "claude -p failed (exit \(code)): \(err)"
            case .badOutput(let s): "claude returned something that isn't a standup: \(s.prefix(300))"
            }
        }
    }

    public static let model = "sonnet"
    public static let claudeTimeout: TimeInterval = 300   // the full day's dump can take a while
    static let dumpTimeout: TimeInterval = 60

    /// The two process boundaries, swappable in tests.
    public struct Runner: Sendable {
        public var dump: @Sendable (_ script: String, _ date: LocalDate) throws -> String
        /// → (standup text, model id that answered)
        public var claude: @Sendable (_ path: String, _ prompt: String) throws -> (text: String, model: String)
        /// Excluded repo names → session ids (8-char prefixes) whose cwd is in one of them.
        public var excludedSessions: @Sendable (_ repos: Set<String>) -> Set<String>
        /// Setting rows → the Scry notes folder for the "Meetings (Scry)" section; nil = no meetings.
        /// Live: `ScrySettings.rootURL`. Test runners default to nil, so they never read the real folder.
        public var scryRoot: @Sendable (_ settings: [String: String]) -> URL?

        public init(dump: @escaping @Sendable (String, LocalDate) throws -> String,
                    claude: @escaping @Sendable (String, String) throws -> (text: String, model: String),
                    excludedSessions: @escaping @Sendable (Set<String>) -> Set<String> = { _ in [] },
                    scryRoot: @escaping @Sendable ([String: String]) -> URL? = { _ in nil }) {
            self.dump = dump; self.claude = claude; self.excludedSessions = excludedSessions; self.scryRoot = scryRoot
        }

        public static let live = Runner(dump: liveDump, claude: liveClaude, excludedSessions: { liveExcludedSessions($0) },
                                        scryRoot: { ScrySettings.load($0).rootURL })
    }

    /// Generates and stores the standup for `date` unless one exists (any stored row, edited or not)
    /// and `regenerate` is false.
    @discardableResult
    public static func run(db: HoursDB, date: LocalDate, regenerate: Bool = false,
                           nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000), runner: Runner = .live) throws -> Outcome {
        let store = StandupStore(db)
        if !regenerate, let existing = try store.get(date) { return .exists(existing) }
        let settings = StandupSettings.load(try SettingStore(db).all())
        let prompt = try prompt(db: db, date: date, settings: settings, runner: runner)
        let reply = try runner.claude(settings.claudePath, prompt)
        let body = try clean(reply.text, name: settings.name)
        let sha = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        try store.saveGenerated(date, body: body, generatedMs: nowMs, inputsSha256: sha, model: reply.model)
        return .generated(try store.get(date)!)
    }

    /// The full `claude -p` stdin for `date` (redacted, capped).
    public static func prompt(db: HoursDB, date: LocalDate, settings: StandupSettings, runner: Runner) throws -> String {
        let raw = try runner.dump(settings.dumpScript, date)
        let excludedSids = settings.excludeRepos.isEmpty ? [] : runner.excludedSessions(settings.excludeRepos)
        let dump = StandupPrompt.condense(StandupRedact.redact(raw, allowEmails: settings.allowEmails), excluding: excludedSids)
        if dump.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw Failure.emptyDump(date) }
        let config = try ExportConfig.load(db)
        let classifier = Classifier(categories: config.categories, rules: config.rules, projects: config.projects)
        // ponytail: Hours' 04:00 store day vs the dump's calendar day — a 00:00–04:00 stretch lands on
        // different days in the two inputs. Fine for effort weighting.
        let spans = classifier.classifyAll(try Store(db).effectiveSpans(day: date))
        let metrics = DayMetrics.compute(spans: spans, categories: config.categories)
        let day = date.dayInterval(in: .current)
        let meetings = (runner.scryRoot(try SettingStore(db).all()).map(scryNotes) ?? []).map(\.note)
            .filter { day.contains(Int64($0.meta.startedAt.timeIntervalSince1970 * 1000)) }
        return StandupPrompt.build(name: settings.name, date: date,
                                   timeContext: StandupPrompt.timeContext(metrics, projects: config.projects),
                                   previous: try StandupStore(db).previous(before: date), dump: dump,
                                   excluded: settings.excludeRepos, meetings: StandupRedact.redact(StandupPrompt.meetingsContext(meetings), allowEmails: settings.allowEmails))
    }

    /// Every Scry note under `root` (recursive `*.md` that parse as one), newest first. Also the Meetings
    /// view's loader. ponytail: reads every note each call; an index when there are thousands.
    public static func scryNotes(in root: URL) -> [(url: URL, markdown: String, note: ScryNote)] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "md" } ?? []
        return files.compactMap { url in
            guard let md = try? String(contentsOf: url, encoding: .utf8), let note = ScryNote.parse(md) else { return nil }
            return (url, md, note)
        }.sorted { $0.note.meta.startedAt > $1.note.meta.startedAt }
    }

    /// The dump carries no cwd (its USER lines, which would, are dropped by a jq error in the
    /// script), so sessions map to repos through Claude Code's own layout:
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

    @Sendable static func liveDump(_ script: String, _ date: LocalDate) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: script) else { throw Failure.dumpScriptMissing(script) }
        let r = try StandupProcess.run(URL(filePath: script), [date.description], timeout: dumpTimeout)
        guard r.status == 0 else { throw Failure.dumpFailed(r.status, r.stderrText) }
        return String(decoding: r.stdout, as: UTF8.self)
    }

    /// `claude -p` isolated from the user's setup: no tools, no MCP servers, no hooks/CLAUDE.md/plugins
    /// (`--safe-mode`), no transcript written (so tomorrow's dump doesn't contain today's prompt).
    @Sendable static func liveClaude(_ path: String, _ prompt: String) throws -> (text: String, model: String) {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw Failure.claudeMissing(path) }
        let args = ["-p", "--model", model, "--output-format", "json", "--safe-mode", "--no-session-persistence",
                    "--tools", "", "--strict-mcp-config", "--system-prompt", StandupPrompt.systemPrompt]
        let r = try StandupProcess.run(URL(filePath: path), args, stdin: Data(prompt.utf8), timeout: claudeTimeout)
        let json = (try? JSONSerialization.jsonObject(with: r.stdout)) as? [String: Any]
        guard r.status == 0, let json, json["is_error"] as? Bool != true, let text = json["result"] as? String else {
            let detail = (json?["result"] as? String).map { "\($0) " } ?? ""
            throw Failure.claudeFailed(r.status, detail + r.stderrText)
        }
        let used = (json["modelUsage"] as? [String: Any])?.keys.sorted().first ?? model
        return (text, used)
    }
}
