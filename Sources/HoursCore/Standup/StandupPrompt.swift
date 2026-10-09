import Foundation
import ScryCore

/// Prompt assembly for the EOD standup: condensed transcript dump + Hours time context + the previous
/// standup. No few-shot example: its detail level leaked into the output, so the rules carry the format.
public enum StandupPrompt {
    /// ~60k tokens: a heavy day's whole dump (Claude Code + Codex, SDK sessions skipped) fits uncut.
    public static let dumpCap = 250_000

    public static let systemPrompt = "You write terse, plain-text Slack end-of-day standups from a developer's work log. Output only the standup."

    // MARK: - Dump condensing

    struct Entry {
        enum Kind { case header, pr, user, claude, other }
        var kind: Kind
        var sid: String?
        var text: String
    }

    /// `cc-day-dump.sh` output → entries. A new entry starts at `## session <sid>:` or `[<sid>…]`;
    /// other lines are continuation lines of a multi-line prompt/reply.
    static func entries(_ dump: String) -> [Entry] {
        var out: [Entry] = []
        for raw in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("## session ") {
                let sid = String(line.dropFirst(11).prefix(while: { $0 != ":" }))
                out.append(Entry(kind: .header, sid: sid, text: line))
            } else if line.hasPrefix("["), let close = line.firstIndex(of: "]"), line.distance(from: line.startIndex, to: close) <= 80 {
                let tag = line[line.index(after: line.startIndex)..<close]
                let sid = String(tag.prefix(while: { $0 != " " }))
                let rest = line[line.index(after: close)...]
                let kind: Entry.Kind = rest.hasPrefix(" USER: ") ? .user : rest.hasPrefix(" CLAUDE: ") ? .claude
                    : rest.hasPrefix(" PR: ") ? .pr : .other
                out.append(Entry(kind: kind, sid: sid, text: line))
            } else if !out.isEmpty {
                out[out.count - 1].text += "\n" + line
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(Entry(kind: .other, sid: nil, text: line))
            }
        }
        for i in out.indices { out[i].text = out[i].text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return out
    }

    /// Cuts the dump to `cap` characters.
    ///
    /// 0. Sessions in `excludedSids` (personal side projects, `standup_exclude_repos`) go entirely.
    /// 1. Session titles and PR links whose session has no prompt/reply on the day are dropped (the
    ///    script doesn't date-filter those lines, so any session file touched since that day leaks in).
    /// 2. Prompts/replies under 15 characters of content ("ok", "go") are dropped.
    /// 3. If it still doesn't fit: titles and PR links always stay; prompts/replies are ranked by
    ///    kind (user prompts 1.5×, replies 1×) × substance (length up to 300 chars, floor 0.2) ×
    ///    recency (0.5 → 1.0 by position within its session — the dump has no timestamps and its
    ///    session order is `find`'s, so position is the only recency signal). The highest ranked fill
    ///    the budget; the survivors print in their original order.
    public static func condense(_ dump: String, excluding excludedSids: Set<String> = [], cap: Int = dumpCap) -> String {
        var es = entries(dump)
        es.removeAll { $0.sid.map(excludedSids.contains) ?? false }
        let active = Set(es.filter { $0.kind == .user || $0.kind == .claude }.compactMap(\.sid))
        es.removeAll { e in
            switch e.kind {
            case .header, .pr: return !active.contains(e.sid ?? "")
            case .user, .claude: return contentLength(e) < 15
            case .other: return false
            }
        }
        let total = es.reduce(0) { $0 + $1.text.count + 1 }
        if total <= cap { return es.map(\.text).joined(separator: "\n") }

        var keep = Set<Int>(), used = 0
        for (i, e) in es.enumerated() where e.kind == .header || e.kind == .pr {
            keep.insert(i); used += e.text.count + 1
        }
        var perSession: [String: [Int]] = [:]
        for (i, e) in es.enumerated() where e.kind == .user || e.kind == .claude || e.kind == .other {
            perSession[e.sid ?? "", default: []].append(i)
        }
        var ranked: [(i: Int, score: Double)] = []
        for idx in perSession.values {
            for (pos, i) in idx.enumerated() {
                let e = es[i]
                let recency = 0.5 + 0.5 * (idx.count > 1 ? Double(pos) / Double(idx.count - 1) : 1)
                let substance = max(0.2, min(1, Double(contentLength(e)) / 300))
                let kind = e.kind == .user ? 1.5 : 1.0
                ranked.append((i, kind * substance * recency))
            }
        }
        ranked.sort { $0.score != $1.score ? $0.score > $1.score : $0.i > $1.i }
        for r in ranked {
            let n = es[r.i].text.count + 1
            if used + n <= cap { keep.insert(r.i); used += n }
        }
        return es.indices.filter(keep.contains).map { es[$0].text }.joined(separator: "\n")
    }

    private static func contentLength(_ e: Entry) -> Int {
        for marker in ["] USER: ", "] CLAUDE: "] {
            if let r = e.text.range(of: marker) { return e.text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).count }
        }
        return e.text.count
    }

    // MARK: - Context

    /// "Hours tracked …" header: work / billable totals and work per project, largest first.
    public static func timeContext(_ m: DayMetrics, projects: [Project]) -> String {
        guard m.trackedMs > 0 else { return "Tracked time (Hours app): nothing tracked this day." }
        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        var lines = ["Tracked time (Hours app): work \(duration(m.workMs)), billable \(duration(m.billableMs)), tracked \(duration(m.trackedMs))."]
        let rows = m.byProject.filter { $0.workMs > 0 }.sorted { $0.workMs > $1.workMs }
        for r in rows {
            let name = r.key.map { names[$0] ?? "Project #\($0)" } ?? "No project"
            lines.append("- \(name): \(duration(r.workMs))")
        }
        return lines.joined(separator: "\n")
    }

    /// "Meetings (Scry):" — each note that started on the day, in order: title, length, decisions and
    /// action items, one line each. Empty when there are none.
    public static func meetingsContext(_ notes: [ScryNote]) -> String {
        guard !notes.isEmpty else { return "" }
        var lines = ["Meetings (Scry):"]
        for n in notes.sorted(by: { $0.meta.startedAt < $1.meta.startedAt }) {
            let ms = Int64(n.meta.endedAt.timeIntervalSince(n.meta.startedAt) * 1000)
            lines.append("- \(n.summary.title) (\(duration(ms))\(n.meta.app.map { ", \($0)" } ?? ""))")
            if !n.summary.decisions.isEmpty { lines.append("  Decisions: " + n.summary.decisions.joined(separator: "; ")) }
            if !n.summary.actionItems.isEmpty {
                lines.append("  Action items: " + n.summary.actionItems.map { "\($0.owner): \($0.task)" }.joined(separator: "; "))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func duration(_ ms: Int64) -> String {
        let min = Int((ms + 30_000) / 60_000)
        return min >= 60 ? (min % 60 == 0 ? "\(min / 60)h" : "\(min / 60)h \(min % 60)m") : "\(min)m"
    }

    static func heading(_ date: LocalDate) -> String {
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                      "October", "November", "December"]
        return "\(months[date.month - 1]) \(date.day)"
    }

    // MARK: - Prompt

    public static func build(name: String, date: LocalDate, timeContext: String, previous: Standup?, dump: String,
                             excluded: Set<String> = [], meetings: String = "") -> String {
        let prev = previous.map { "Previous standup (\($0.date)):\n\($0.body)" } ?? "Previous standup: none stored."
        return """
        Write \(name)'s end-of-day Slack standup for \(date) from his Claude Code session log below.

        Rules:
        - Plain text only, Slack-ready: no markdown, no headers with #, no bold, no bullets or dashes at line starts, no code.
        - First line exactly: \(name) - EOD \(heading(date))
        - Then these four section labels, each alone on its line, in this order: "Worked On:", "Still Work In Progress:", "Blockers:", "Carry-Forward:". One item per line under each. A section with nothing gets the single line "None".
        - Terse: each line at most ~20 words, outcome first, with at most one short parenthetical. Drop counts and numbers unless they matter.
        - Keep it high-level, for a lead who doesn't read code: say what moved forward and why it matters (which market, pipeline, customer-facing feature or business capability), not how it was done. Leave out implementation detail: no file, function, table, API, model or library names, no error messages, no mechanisms. "Fixed FL owner mailing addresses" beats "patched the tax-mailing join in the ExampleCRM sync".
        - 3–5 Worked On items; merge related work into one line, broader rather than more. Name products, counties, vendors and features, not repo paths, branches, session ids or PR numbers.\(excluded.isEmpty ? "" : "\n- Leave out personal side projects entirely, even if the previous standup lists them: \(excluded.sorted().joined(separator: ", ")).")
        - Work only: the log can include personal assistant chats (errands, household or hobby tasks); leave anything unrelated to the business out.
        - Weight items by the tracked time and by how much of the log they take. Skip small talk, tooling meta-work under ~15 minutes, and anything not done that day.
        - Continue the previous standup coherently: finished WIP moves to Worked On, still-open items stay in WIP or Carry-Forward, finished items are not repeated.\(meetings.isEmpty ? "" : "\n- Meetings (Scry): work discussed or decided there goes into Worked On, open action items owned by You go into Carry-Forward; never list a meeting itself as an item.")
        - Never output secrets, tokens, emails or the text "[redacted]".
        - Output only the standup, nothing before or after it.


        \(timeContext)\(meetings.isEmpty ? "" : "\n\n" + meetings)

        \(prev)

        Session log for \(date) (condensed; each "## session" line is a session title, lines within a session are in order; USER = \(name), CLAUDE = the assistant, Claude Code or Codex):
        <log>
        \(dump)
        </log>
        """
    }
}
