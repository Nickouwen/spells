import Foundation
import Testing
import ScryCore
@testable import HoursCore

@Suite struct StandupRedactTests {
    static let p = StandupRedact.placeholder

    @Test func rizeKeyShapedEnvLine() {
        let key = ["aB3dE5fG7hJ9kL1", "mN2pQ4rS6tU8vW0", "xY2zA4bC6dE8f"].joined()
        #expect(key.count == 43)
        let out = StandupRedact.redact("ran it with RIZE_API_KEY=\(key) swift run spellsctl import-rize")
        #expect(out == "ran it with RIZE_API_KEY=\(Self.p) swift run spellsctl import-rize")
        // export form and quoted form
        #expect(StandupRedact.redact("export RIZE_API_KEY=\"\(key)\"") == "export RIZE_API_KEY=\(Self.p)")
        // the bare key on its own (no KEY= prefix) is still caught by the blob rule
        #expect(StandupRedact.redact("the key is \(key).") == "the key is \(Self.p).")
    }

    @Test func envStyleSecrets() {
        #expect(StandupRedact.redact("DATABASE_PASSWORD=hunter2 next") == "DATABASE_PASSWORD=\(Self.p) next")
        #expect(StandupRedact.redact("GITHUB_TOKEN = abc123def") == "GITHUB_TOKEN = \(Self.p)")
        #expect(StandupRedact.redact(#"{"api_key": "s3cr3t-value"}"#) == #"{"api_key": "\#(Self.p)"}"#)
        // non-secret env stays readable
        #expect(StandupRedact.redact("SPELLS_HOME=/tmp/x EXAMPLECRM_SKIPTRACE_ENABLED=true") == "SPELLS_HOME=/tmp/x EXAMPLECRM_SKIPTRACE_ENABLED=true")
    }

    @Test func bearerAndVendorTokens() {
        let anthropic = "sk-" + "ant-api03-" + "AbCdEfGhIjKlMnOpQrSt"
        let github = "ghp_" + "0123456789abcdefghijABCDEFGHIJ"
        let slack = "xoxb-" + "1234567890-abcdefghij"
        let aws = "AKIA" + "ABCDEFGHIJKLMNOP"
        #expect(StandupRedact.redact("Authorization: Bearer abc.DEF-123_xyz") == "Authorization: Bearer \(Self.p)")
        #expect(StandupRedact.redact("key \(anthropic) done") == "key \(Self.p) done")
        #expect(StandupRedact.redact(github) == Self.p)
        #expect(StandupRedact.redact("slack \(slack) ok") == "slack \(Self.p) ok")
        #expect(StandupRedact.redact(aws) == Self.p)
    }

    @Test func databaseURLWithPassword() {
        let s = "psql postgres://neondb_owner:npg_Xy12ab@ep-cool-lake.us-east-2.aws.neon.tech/neondb?sslmode=require now"
        #expect(StandupRedact.redact(s) == "psql \(Self.p) now")
        // no password → kept
        #expect(StandupRedact.redact("https://github.com/org/repo/pull/12") == "https://github.com/org/repo/pull/12")
    }

    @Test func emailsExceptNics() {
        #expect(StandupRedact.redact("mail client@example.com and dev@example.com")
                == "mail \(Self.p) and dev@example.com")
        #expect(StandupRedact.redact("me@example.dev", allowEmails: ["ME@example.dev"]) == "me@example.dev")
    }

    @Test func blobsButNotPathsOrSlugs() {
        let hex = String(repeating: "deadbeef", count: 5)   // 40 hex chars
        #expect(StandupRedact.redact("sha \(hex)") == "sha \(Self.p)")
        #expect(StandupRedact.redact("token Zx9Qw2Er7Ty1Ui5Op3As8Df4Gh6Jk0LzXcVbNm12345") == "token \(Self.p)")
        for keep in ["/Users/work/Documents/GitHub/hours/Sources/HoursCore/Store",
                     "branch fl-parity-sweep-marketing-workflows-2026-10-05",
                     "StandupGeneratorTestsRunsWithFakeRunner2026",
                     "PR: https://github.com/Example-Client-LLC/data-scrapers/pull/412",
                     "worktree-agent-a52ef46eabf5"] {
            #expect(StandupRedact.redact(keep) == keep)
        }
    }
}

@Suite struct StandupPromptTests {
    @Test func condenseKeepsEverythingUnderCapButDropsNoise() {
        let dump = """

        ## session aaaaaaaa: Example County pipeline
        [aaaaaaaa repo] USER: fix the Example County doc fetcher, it's returning 403s from the portal
        [aaaaaaaa] CLAUDE: Found the new case-management portal;
        switching the fetcher over.
        [aaaaaaaa] CLAUDE: ok
        [aaaaaaaa] PR: https://github.com/x/y/pull/1

        ## session bbbbbbbb: an old session from another day
        [bbbbbbbb] PR: https://github.com/x/y/pull/2
        """
        let out = StandupPrompt.condense(dump)
        #expect(out == """
        ## session aaaaaaaa: Example County pipeline
        [aaaaaaaa repo] USER: fix the Example County doc fetcher, it's returning 403s from the portal
        [aaaaaaaa] CLAUDE: Found the new case-management portal;
        switching the fetcher over.
        [aaaaaaaa] PR: https://github.com/x/y/pull/1
        """)
    }

    @Test func condenseCapsPreferringRecentSubstantiveLines() {
        // One session: 10 replies of 200 chars, then a user prompt. Cap fits header + prompt + ~3 replies.
        var lines = ["## session cccccccc: big"]
        for i in 0..<10 { lines.append("[cccccccc] CLAUDE: reply\(i) " + String(repeating: "x", count: 200)) }
        lines.append("[cccccccc r] USER: final " + String(repeating: "y", count: 200))
        let header = lines[0].count + 1, reply = lines[1].count + 1, user = lines[11].count + 1
        let cap = header + user + 3 * reply
        let out = StandupPrompt.condense(lines.joined(separator: "\n"), cap: cap)
        #expect(out.count <= cap)
        let kept = out.split(separator: "\n").map(String.init)
        // Header always; the user prompt (1.5× and newest); then the three newest replies, in order.
        #expect(kept == [lines[0], lines[8], lines[9], lines[10], lines[11]])
    }

    @Test func condenseDropsExcludedSessionsEntirely() {
        let dump = """
        ## session aaaaaaaa: Example County pipeline
        [aaaaaaaa] CLAUDE: Switched the Example County fetcher to the case portal.
        ## session hhhhhhhh: Hours notch island
        [hhhhhhhh] CLAUDE: Notch island shipped in the tracker helper.
        [hhhhhhhh] PR: https://github.com/nic/hours/pull/9
        """
        #expect(StandupPrompt.condense(dump, excluding: ["hhhhhhhh"]) == """
        ## session aaaaaaaa: Example County pipeline
        [aaaaaaaa] CLAUDE: Switched the Example County fetcher to the case portal.
        """)
    }

    @Test func excludedSessionsComeFromProjectDirNames() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hours-standup-projects/\(UUID().uuidString)")
        let layout = ["-Users-work-Documents-GitHub-hours": ["11111111-aaaa.jsonl", "notes.txt"],
                      "-Users-work-Documents-GitHub-hours--claude-worktrees-agent-a52ef46e": ["22222222-bbbb.jsonl"],
                      "-Users-work-Documents-GitHub-operations-dashboard": ["33333333-cccc.jsonl"],
                      "-Users-work-Documents-GitHub-hoursheet": ["44444444-dddd.jsonl"]]
        for (dir, files) in layout {
            try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
            for f in files { FileManager.default.createFile(atPath: root.appending(path: "\(dir)/\(f)").path, contents: Data()) }
        }
        #expect(StandupGenerator.liveExcludedSessions(["hours"], projects: root) == ["11111111", "22222222"])
        #expect(StandupGenerator.liveExcludedSessions(["operations-dashboard"], projects: root) == ["33333333"])
    }

    @Test func timeContextListsProjectsByWork() {
        var m = DayMetrics()
        m.trackedMs = 8 * 3_600_000; m.workMs = 7 * 3_600_000 + 30 * 60_000; m.billableMs = 5 * 3_600_000
        m.byProject = [.init(key: 2, trackedMs: 0, workMs: 3_600_000), .init(key: nil, trackedMs: 0, workMs: 2 * 3_600_000 + 30 * 60_000),
                       .init(key: 1, trackedMs: 0, workMs: 4 * 3_600_000), .init(key: 3, trackedMs: 600_000, workMs: 0)]
        let projects = [Project(id: 1, name: "ExampleCo"), Project(id: 2, name: "Hours")]
        #expect(StandupPrompt.timeContext(m, projects: projects) == """
        Tracked time (Hours app): work 7h 30m, billable 5h, tracked 8h.
        - ExampleCo: 4h
        - No project: 2h 30m
        - Hours: 1h
        """)
        #expect(StandupPrompt.timeContext(DayMetrics(), projects: []) == "Tracked time (Hours app): nothing tracked this day.")
    }

    @Test func promptCarriesFormatPreviousAndHeading() {
        let prev = Standup(date: LocalDate(year: 2026, month: 10, day: 2), body: "Carry-Forward:\nRescraper job scoping")
        let p = StandupPrompt.build(name: "Example User", date: LocalDate(year: 2026, month: 10, day: 5),
                                    timeContext: "Tracked time (Hours app): nothing tracked this day.", previous: prev, dump: "LOG")
        #expect(p.contains("First line exactly: Example User - EOD October 5"))
        #expect(!p.contains("<example>") && p.contains("Work only:"))
        #expect(p.contains("Previous standup (2026-10-02):\nCarry-Forward:\nRescraper job scoping"))
        #expect(p.contains("<log>\nLOG\n</log>"))
        #expect(p.contains("gets the single line \"None\""))
        #expect(p.contains("each line at most ~20 words") && p.contains("3–5 Worked On items"))
        #expect(!p.contains("personal side projects"))
        #expect(!p.contains("Meetings (Scry)"))
        let q = StandupPrompt.build(name: "N", date: LocalDate(year: 2026, month: 10, day: 5), timeContext: "", previous: nil,
                                    dump: "LOG", excluded: ["hours", "blog"])
        #expect(q.contains("\n- Leave out personal side projects entirely, even if the previous standup lists them: blog, hours.\n"))
    }
}

@Suite struct StandupSettingsTests {
    @Test func hourlyRefreshOnlyForFreshWorkAndNeverOverAnEdit() {
        let h = StandupSettings.refreshMs, gen: Int64 = 1_000_000_000
        let s = Standup(date: LocalDate(year: 2026, month: 10, day: 7), body: "b", generatedMs: gen)
        #expect(StandupSettings.refreshDue(s, nowMs: gen + h, lastAttemptMs: 0, newestTranscriptMs: gen + 1))
        #expect(!StandupSettings.refreshDue(s, nowMs: gen + h - 1, lastAttemptMs: 0, newestTranscriptMs: gen + 1))   // too soon
        #expect(!StandupSettings.refreshDue(s, nowMs: gen + h, lastAttemptMs: gen + 1, newestTranscriptMs: gen + 1))  // tried lately
        #expect(!StandupSettings.refreshDue(s, nowMs: gen + h, lastAttemptMs: 0, newestTranscriptMs: gen))            // nothing new
        var edited = s; edited.editedMs = gen + 5
        #expect(!StandupSettings.refreshDue(edited, nowMs: gen + 2 * h, lastAttemptMs: 0, newestTranscriptMs: gen + h))
    }

    @Test func newestTranscriptSkipsSubagentsAndOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "standup-roots-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "p/subagents"), withIntermediateDirectories: true)
        func touch(_ path: String, _ s: TimeInterval) throws {
            let u = root.appending(path: path)
            fm.createFile(atPath: u.path, contents: Data())
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: s)], ofItemAtPath: u.path)
        }
        try touch("p/a.jsonl", 100); try touch("p/subagents/b.jsonl", 300); try touch("p/c.txt", 400)
        #expect(StandupSettings.newestTranscriptMs(roots: [root, root.appending(path: "missing")]) == 100_000)
    }

    @Test func defaultsAndParsing() {
        let d = StandupSettings.load([:])
        #expect(!d.enabled && d.name == "Example User" && d.timeMinutes == 17 * 60 && d.weekdays == [2, 3, 4, 5, 6])
        #expect(d.claudePath == "/opt/homebrew/bin/claude")
        #expect(d.dumpScript.hasSuffix("/.claude/shared/scripts/cc-day-dump.sh") && !d.dumpScript.hasPrefix("~"))
        let s = StandupSettings.load(["standup_enabled": "0", "standup_time": "18:30", "standup_weekdays": "2,4,9", "standup_name": " "])
        #expect(!s.enabled && s.timeMinutes == 18 * 60 + 30 && s.weekdays == [2, 4] && s.name == "Example User")
        #expect(StandupSettings.load(["standup_time": "25:00"]).timeMinutes == 17 * 60)
        #expect(d.excludeRepos == ["spells", "hours"])
        #expect(StandupSettings.load(["standup_exclude_repos": "hours, blog ,"]).excludeRepos == ["hours", "blog"])
        #expect(StandupSettings.load(["standup_exclude_repos": ""]).excludeRepos.isEmpty)
        #expect(StandupSettings.formatTime(9 * 60 + 5) == "09:05")
    }

    @Test func isDueOnWeekdaysAtOrAfterTime() {
        let tz = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        func at(_ d: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))! }
        var s = StandupSettings(); s.enabled = true
        #expect(!s.isDue(at: at(5, 16, 59), in: tz))   // Mon 16:59
        #expect(s.isDue(at: at(5, 17, 0), in: tz))     // Mon 17:00
        #expect(s.isDue(at: at(9, 23, 30), in: tz))    // Fri late
        #expect(!s.isDue(at: at(10, 18, 0), in: tz))   // Sat
        var off = s; off.enabled = false
        #expect(!off.isDue(at: at(5, 18, 0), in: tz))
        #expect(LocalDate.standupDay(containing: at(6, 1, 30), in: tz) == LocalDate(year: 2026, month: 10, day: 6))  // calendar, not 04:00
    }
}

@Suite struct StandupStoreTests {
    let day = LocalDate(year: 2026, month: 10, day: 5)

    @Test func migrationAddsUnchainedTable() throws {
        let db = try storeTempDB()
        let head = try db.head()
        try StandupStore(db).saveGenerated(day, body: "a", generatedMs: 1, inputsSha256: "s", model: "m")
        let after = try db.head()
        #expect(after.seq == head.seq && after.hash == head.hash)   // not chained
        #expect(try ChainVerifier.verify(db).ok)
    }

    @Test func generatedThenEditedThenPrevious() throws {
        let db = try storeTempDB()
        let st = StandupStore(db)
        #expect(try st.get(day) == nil)
        try st.saveGenerated(day, body: "gen", generatedMs: 10, inputsSha256: "abc", model: "claude-sonnet")
        try st.saveEdit(day, body: "mine", editedMs: 20)
        #expect(try st.get(day) == Standup(date: day, body: "mine", generatedMs: 10, editedMs: 20, inputsSha256: "abc", model: "claude-sonnet"))
        try st.saveGenerated(day, body: "gen2", generatedMs: 30, inputsSha256: "def", model: "m2")
        #expect(try st.get(day) == Standup(date: day, body: "gen2", generatedMs: 30, editedMs: nil, inputsSha256: "def", model: "m2"))
        let oct2 = LocalDate(year: 2026, month: 10, day: 2), sep30 = LocalDate(year: 2026, month: 9, day: 30)
        try st.saveEdit(sep30, body: "old", editedMs: 1)
        try st.saveEdit(oct2, body: "fri", editedMs: 2)
        #expect(try st.previous(before: day)?.date == oct2)
        #expect(try st.previous(before: oct2)?.date == sep30)
        #expect(try st.previous(before: sep30) == nil)
    }
}

@Suite struct StandupGeneratorTests {
    let day = LocalDate(year: 2026, month: 10, day: 5)
    static let reply = """
    Here you go:
    ```
    Example User - EOD October 5
    Worked On:
    Example County lead pipeline (new portal)
    Still Work In Progress:
    None
    Blockers:
    None
    Carry-Forward:
    Rescraper job scoping
    ```
    """

    final class Captured: @unchecked Sendable { var prompt = ""; var calls = 0 }

    func runner(_ c: Captured, dump: String = "## session aaaaaaaa: t\n[aaaaaaaa r] USER: fix Example County with GITHUB_TOKEN=abc123secret and mail bob@corp.com please\n## session hhhhhhhh: tracker\n[hhhhhhhh] CLAUDE: Notch island shipped in the tracker helper.") -> StandupGenerator.Runner {
        StandupGenerator.Runner(dump: { _, _ in dump }, claude: { _, prompt in
            c.prompt = prompt; c.calls += 1
            return (Self.reply, "claude-sonnet-5-5")
        }, excludedSessions: { repos in repos.contains("hours") ? ["hhhhhhhh"] : [] })
    }

    @Test func generatesStoresAndSkipsUntilRegenerate() throws {
        let db = try storeTempDB(role: .app)
        let c = Captured()
        guard case .generated(let s) = try StandupGenerator.run(db: db, date: day, nowMs: 100, runner: runner(c)) else {
            Issue.record("expected generated"); return
        }
        #expect(s.body.hasPrefix("Example User - EOD October 5\nWorked On:"))
        #expect(s.body.hasSuffix("Rescraper job scoping"))
        #expect(s.model == "claude-sonnet-5-5" && s.generatedMs == 100 && s.editedMs == nil && s.inputsSha256?.count == 64)
        // redaction happened before the prompt left the process
        #expect(!c.prompt.contains("abc123secret") && !c.prompt.contains("bob@corp.com"))
        #expect(c.prompt.contains("GITHUB_TOKEN=[redacted]"))
        #expect(c.prompt.contains("nothing tracked this day"))
        // the default excluded repo (hours) drops its session before summarizing
        #expect(!c.prompt.contains("Notch island") && !c.prompt.contains("hhhhhhhh") && c.prompt.contains("personal side projects entirely"))

        // second run: no call, existing returned; an edit is kept
        try StandupStore(db).saveEdit(day, body: "my own words", editedMs: 200)
        guard case .exists(let e) = try StandupGenerator.run(db: db, date: day, runner: runner(c)) else {
            Issue.record("expected exists"); return
        }
        #expect(e.body == "my own words" && c.calls == 1)

        // --regenerate replaces it and clears edited_ms
        _ = try StandupGenerator.run(db: db, date: day, regenerate: true, nowMs: 300, runner: runner(c))
        let r = try #require(try StandupStore(db).get(day))
        #expect(r.editedMs == nil && r.generatedMs == 300 && c.calls == 2)
    }

    @Test func includesPreviousStandupAndRejectsNonStandup() throws {
        let db = try storeTempDB(role: .app)
        try StandupStore(db).saveEdit(LocalDate(year: 2026, month: 10, day: 2), body: "Carry-Forward:\nDocument provenance", editedMs: 1)
        let c = Captured()
        _ = try StandupGenerator.run(db: db, date: day, runner: runner(c))
        #expect(c.prompt.contains("Previous standup (2026-10-02):\nCarry-Forward:\nDocument provenance"))

        let bad = StandupGenerator.Runner(dump: { _, _ in "[aaaaaaaa] USER: something substantive happened" },
                                          claude: { _, _ in ("I can't help with that.", "m") })
        #expect(throws: StandupGenerator.Failure.self) {
            try StandupGenerator.run(db: db, date: LocalDate(year: 2026, month: 10, day: 6), runner: bad)
        }
        #expect(try StandupStore(db).get(LocalDate(year: 2026, month: 10, day: 6)) == nil)
        let empty = StandupGenerator.Runner(dump: { _, _ in "\n" }, claude: { _, _ in (Self.reply, "m") })
        #expect(throws: StandupGenerator.Failure.self) {
            try StandupGenerator.run(db: db, date: LocalDate(year: 2026, month: 10, day: 7), runner: empty)
        }
    }

    /// EOD: the day's Scry notes (and only that day's) land in a "Meetings (Scry)" section.
    @Test func meetingsSectionFromScryNotes() throws {
        let db = try storeTempDB(role: .app)
        let root = FileManager.default.temporaryDirectory.appending(path: "hours-standup-scry/\(UUID().uuidString)")
        func note(_ d: Int, _ title: String) throws {
            let start = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 10))!
            let n = ScryNote(meta: .init(startedAt: start, endedAt: start.addingTimeInterval(1_800), app: "Zoom",
                                         participants: ["Alex"], speakers: [:]),
                             summary: ScrySummary(title: title, decisions: ["Ship Example County Friday"],
                                                  actionItems: [.init(owner: "You", task: "Send the project list")]),
                             userNotes: "", segments: [])
            let url = ScryNote.fileURL(root: root, startedAt: start, title: title)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try n.markdown().write(to: url, atomically: true, encoding: .utf8)
        }
        try note(5, "Example County sync")
        try note(4, "Yesterday's call")
        let c = Captured()
        var r = runner(c)
        r.scryRoot = { _ in root }
        _ = try StandupGenerator.run(db: db, date: day, runner: r)
        #expect(c.prompt.contains("""
        Meetings (Scry):
        - Example County sync (30m, Zoom)
          Decisions: Ship Example County Friday
          Action items: You: Send the project list
        """))
        #expect(!c.prompt.contains("Yesterday's call"))
        #expect(c.prompt.contains("\n- Meetings (Scry): work discussed or decided there goes into Worked On"))
        #expect(StandupPrompt.meetingsContext([]) == "")
        // The live runner reads the folder from the `scry_root` row.
        #expect(StandupGenerator.Runner.live.scryRoot([ScrySettings.rootKey: root.path])?.path == root.path)
    }

    @Test func missingDumpScriptFailsClearly() {
        #expect {
            _ = try StandupGenerator.liveDump("/nonexistent/cc-day-dump.sh", LocalDate(year: 2026, month: 10, day: 5))
        } throws: { e in
            "\(e)".contains("transcript dump script not found") && "\(e)".contains("/nonexistent/cc-day-dump.sh")
        }
    }

    @Test func processRunnerCapturesAndTimesOut() throws {
        let r = try StandupProcess.run(URL(filePath: "/bin/sh"), ["-c", "cat; echo err >&2; exit 3"], stdin: Data("hi".utf8), timeout: 10)
        #expect(r.status == 3 && String(decoding: r.stdout, as: UTF8.self) == "hi" && r.stderrText == "err\n")
        #expect(throws: StandupProcess.TimedOut.self) {
            try StandupProcess.run(URL(filePath: "/bin/sleep"), ["5"], timeout: 0.3)
        }
    }
}
