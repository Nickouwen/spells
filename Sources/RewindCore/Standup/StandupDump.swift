import Foundation

/// The day's Claude Code transcripts as the text `StandupPrompt` condenses. Built in since 2026-10-26;
/// until then an external `cc-day-dump.sh` (never shipped with the repo) produced the same shape.
///
/// Output, one session after another, in the order they first spoke that day:
///
///     ## session <sid>: <repo> — <title>
///     [<sid> <repo>] USER: <prompt>
///     [<sid>] CLAUDE: <reply text>
///     [<sid>] PR: <github pull request url>
///
/// `sid` is the first 8 characters of the session id, the key `StandupGenerator.liveExcludedSessions`
/// returns. A session is in the dump when it has a prompt or reply stamped inside the calendar day
/// (local midnight to midnight, the standup's boundary, not the 04:00 store day). Skipped: sessions
/// whose `entrypoint` starts with `sdk-` (automated reviewers), subagent sidechains, meta/slash-command
/// lines, thinking, tool calls and tool results — except that PR links are picked out of replies and
/// tool results. Consecutive replies of one turn merge; an entry is cut at `entryCap`.
public enum StandupDump {
    public static let entryCap = 1_500

    public static func dump(date: LocalDate, projects: URL = StandupSettings.transcriptRoots[0], tz: TimeZone = .current) -> String {
        let day = date.dayInterval(in: tz, dayStartHour: 0)
        let since = Date(timeIntervalSince1970: Double(day.lowerBound) / 1000)
        var sessions: [Session] = []
        guard let e = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return "" }
        for case let url as URL in e {
            if url.lastPathComponent == "subagents" { e.skipDescendants(); continue }
            guard url.pathExtension == "jsonl",
                  let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mod >= since,
                  let data = try? Data(contentsOf: url), let s = Session.read(data, day: day), !s.entries.isEmpty else { continue }
            sessions.append(s)
        }
        sessions.sort { $0.entries[0].ms < $1.entries[0].ms }
        return sessions.map(\.text).joined(separator: "\n")
    }

    struct Entry { var ms: Int64; var kind: String; var text: String }

    struct Session {
        var sid = "", repo = "", title = "", sdk = false
        var entries: [Entry] = []
        var prs: [String] = []

        /// One transcript file → its in-day entries; nil for an `sdk-*` session.
        static func read(_ data: Data, day: Range<Int64>) -> Session? {
            var s = Session()
            for line in data.split(separator: UInt8(ascii: "\n")) {
                // Cheap gate before JSON: most lines (api-request blobs, attachments, …) aren't ours.
                guard line.range(of: typeUser) != nil || line.range(of: typeAssistant) != nil || line.range(of: typeTitle) != nil else { continue }
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                if type == "ai-title" { s.title = obj["aiTitle"] as? String ?? s.title; continue }
                if let ep = obj["entrypoint"] as? String, ep.hasPrefix("sdk-") { return nil }
                if s.sid.isEmpty, let id = obj["sessionId"] as? String { s.sid = String(id.prefix(8)) }
                if s.repo.isEmpty, let cwd = obj["cwd"] as? String { s.repo = URL(filePath: cwd).lastPathComponent }
                guard obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true,
                      let stamp = obj["timestamp"] as? String, let ms = Self.ms(stamp), day.contains(ms),
                      let message = obj["message"] as? [String: Any] else { continue }
                let content = message["content"]
                if type == "user" {
                    let (prompt, results) = Self.userText(content)
                    s.addPRs(in: results)
                    let text = Self.clean(prompt)
                    if !text.isEmpty, !text.hasPrefix("<") { s.entries.append(Entry(ms: ms, kind: "USER", text: text)) }
                } else if type == "assistant" {
                    let text = Self.clean(Self.assistantText(content))
                    s.addPRs(in: text)
                    guard !text.isEmpty else { continue }
                    if let last = s.entries.indices.last, s.entries[last].kind == "CLAUDE" { s.entries[last].text += "\n" + text }
                    else { s.entries.append(Entry(ms: ms, kind: "CLAUDE", text: text)) }
                }
            }
            return s
        }

        var text: String {
            var out = ["## session \(sid): \(repo) — \(title.isEmpty ? (entries.first { $0.kind == "USER" }?.text.prefix(80)).map(String.init) ?? "untitled" : title)"]
            for e in entries {
                let tag = e.kind == "USER" ? "[\(sid) \(repo)]" : "[\(sid)]"
                var body = e.text
                if body.count > StandupDump.entryCap { body = String(body.prefix(StandupDump.entryCap)) + "…" }
                // A continuation line that looks like an entry tag or a session header would split the entry.
                body = body.replacingOccurrences(of: "\n[", with: "\n [").replacingOccurrences(of: "\n## ", with: "\n ## ")
                out.append("\(tag) \(e.kind): \(body)")
            }
            out += prs.map { "[\(sid)] PR: \($0)" }
            return out.joined(separator: "\n")
        }

        mutating func addPRs(in text: String) {
            for m in Self.pr.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let url = String(text[Range(m.range, in: text)!])
                if !prs.contains(url) { prs.append(url) }
            }
        }

        static let typeUser = Data("\"type\":\"user\"".utf8), typeAssistant = Data("\"type\":\"assistant\"".utf8), typeTitle = Data("\"type\":\"ai-title\"".utf8)
        static let pr = try! NSRegularExpression(pattern: #"https://github\.com/[^\s"'<>)]+/pull/\d+"#)
        static let reminder = try! NSRegularExpression(pattern: #"<system-reminder>[\s\S]*?</system-reminder>"#)
        nonisolated(unsafe) static let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
        nonisolated(unsafe) static let whole = ISO8601DateFormatter()   // ISO8601DateFormatter is documented thread-safe

        static func ms(_ stamp: String) -> Int64? {
            (fractional.date(from: stamp) ?? whole.date(from: stamp)).map { Int64($0.timeIntervalSince1970 * 1000) }
        }

        /// A user line is a prompt (string, or `text` parts) and/or tool results (`tool_result` parts).
        static func userText(_ content: Any?) -> (prompt: String, results: String) {
            if let s = content as? String { return (s, "") }
            var prompt: [String] = [], results: [String] = []
            for part in content as? [[String: Any]] ?? [] {
                switch part["type"] as? String {
                case "text": prompt.append(part["text"] as? String ?? "")
                case "tool_result":
                    if let s = part["content"] as? String { results.append(s) }
                    for p in part["content"] as? [[String: Any]] ?? [] { results.append(p["text"] as? String ?? "") }
                default: break
                }
            }
            return (prompt.joined(separator: "\n"), results.joined(separator: "\n"))
        }

        static func assistantText(_ content: Any?) -> String {
            (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }

        static func clean(_ s: String) -> String {
            reminder.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
