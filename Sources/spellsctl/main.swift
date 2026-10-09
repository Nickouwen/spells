import Foundation
import HoursCore

// spellsctl — export, verify, anchor, witness, seed-demo (item 9). Hand-rolled argument parsing.

let usage = """
usage: spellsctl export  [--period current|previous|YYYY-MM-DD..YYYY-MM-DD] [--mode plain|audit]
                        [--disclosure L0|L1|L2] [--format csv|pdf] [--out DIR]   (pdf = CSV files + timesheet PDF)
       spellsctl verify  [--bundle DIR]
       spellsctl anchor  [--force]
       spellsctl witness [--period …]
       spellsctl seed-demo [--days N]        (requires SPELLS_HOME)
       spellsctl tracker [--pause MIN] [--idle SEC]   (set live settings, print tracker_state; --pause 0 = resume)
       spellsctl import-rize --source <snapshot.json|api> [--dry-run] [--since YYYY-MM-DD]
                        (api: needs RIZE_API_KEY; saves a snapshot under $SPELLS_HOME/imports, then imports it)
       spellsctl standup [--date YYYY-MM-DD] [--regenerate] [--print]
                        (EOD standup from that calendar day's Claude Code transcripts via claude -p;
                         --print shows the stored text without generating)
       spellsctl classify [--since YYYY-MM-DD] [--dry-run]
                        (Jev backfill for windows no rule matches; default since = 30 days ago;
                         --dry-run counts cache misses without network)
       spellsctl scry process <captureDir> [--root DIR] [--keep]
       spellsctl scry ask "<question>" [--root DIR] [--limit N]
       spellsctl scry list [--root DIR]
                        (Scry meeting notes: Scribe + claude -p → a Markdown note under --root, default
                         ~/Documents/Scry; --keep leaves the capture dir in place)
DB: $SPELLS_HOME/hours.db, else ~/Library/Application Support/Spells/hours.db

"""

func say(_ s: String) { print(s) }
func die(_ msg: String, _ code: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data((msg.hasSuffix("\n") ? msg : msg + "\n").utf8))
    exit(code)
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { die(usage) }
let (options, flags, positional) = { () -> ([String: String], Set<String>, [String]) in
    var options: [String: String] = [:], flags: Set<String> = [], positional: [String] = []   // positional: scry's subcommand + argument
    var i = 1
    while i < argv.count {
        let a = argv[i]
        guard a.hasPrefix("--") else {
            if argv[0] == "scry" { positional.append(a); i += 1; continue }
            die("unexpected argument '\(a)'\n\n\(usage)")
        }
        if ["--force", "--dry-run", "--regenerate", "--print", "--keep"].contains(a) { flags.insert(a); i += 1; continue }
        guard i + 1 < argv.count else { die("\(a) needs a value") }
        options[a] = argv[i + 1]
        i += 2
    }
    return (options, flags, positional)
}()
func allow(_ names: String...) {
    for k in Set(options.keys).union(flags) where !names.contains(k) { die("\(command): unknown option \(k)\n\n\(usage)") }
}

let paths = SupportPaths.current()
let tz = TimeZone.current
let today = LocalDate.containing(ms: Int64(Date().timeIntervalSince1970 * 1000), in: tz)

func openDB() -> HoursDB {
    do { return try HoursDB.open(at: paths.db, role: .app) } catch { die("cannot open \(paths.db.path): \(error)", 1) }
}
func period() -> ExportPeriod {
    let s = options["--period"] ?? "previous"
    guard let p = ExportPeriod.parse(s, today: today) else { die("bad --period '\(s)' (current, previous, YYYY-MM-DD..YYYY-MM-DD)") }
    return p
}

do {
    switch command {
    case "export":
        allow("--period", "--mode", "--disclosure", "--format", "--out")
        let p = period()
        guard let mode = ExportMode(rawValue: options["--mode"] ?? "plain") else { die("bad --mode (plain|audit)") }
        guard let disclosure = Disclosure(rawValue: options["--disclosure"] ?? "L0") else { die("bad --disclosure (L0|L1|L2)") }
        let format = options["--format"] ?? "csv"
        guard ["csv", "pdf"].contains(format) else { die("bad --format (csv|pdf)") }
        let out = options["--out"].map { URL(filePath: ($0 as NSString).expandingTildeInPath, directoryHint: .isDirectory) }
            ?? paths.exports.appending(path: "\(p.from)_\(p.through)\(mode == .audit ? "-audit" : "")", directoryHint: .isDirectory)
        let db = openDB()
        let r = try ExportBundle.write(db: db, period: p, mode: mode, disclosure: disclosure, to: out, tz: tz)
        say("\(p)  \(r.data.rows.count) day×project rows  \(ExportPeriodData.hours(r.data.totalHundredths)) h billable")
        for row in r.data.rows {
            say("  \(row.date)  \(row.project.padding(toLength: 24, withPad: " ", startingAt: 0)) \(ExportPeriodData.hours(row.hundredths)) h")
        }
        say("wrote \(out.path): \(r.files.joined(separator: ", "))")
        if format == "pdf" {
            let pdf = try ExportPDF.write(db: db, period: p, mode: mode, disclosure: disclosure, to: out, tz: tz)
            say("wrote \(pdf.url.path) (\(pdf.pages) page\(pdf.pages == 1 ? "" : "s"))")
        }
        if mode == .audit {
            if let seg = r.segment {
                say("chain rows #\(seg.lowerBound)–#\(seg.upperBound), \(r.anchors.count) anchor(s)"
                    + (r.unanchoredRows > 0 ? "; \(r.unanchoredRows) row(s) not yet anchored — run `spellsctl anchor --force`, then re-export" : ""))
            } else {
                say("no chain rows in this period")
            }
        }
        say(try ExportWitness.line(db: db, period: p))

    case "verify":
        allow("--bundle")
        if let dir = options["--bundle"] {
            let rep = try ExportBundleVerifier.verify(URL(filePath: (dir as NSString).expandingTildeInPath, directoryHint: .isDirectory))
            if let f = rep.failure { die("FAIL \(f)", 1) }
            say("bundle OK: \(rep.rows) chain rows, \(rep.anchors) anchor(s)")
            rep.notes.forEach { say("note: \($0)") }
        } else {
            let db = openDB()
            let res = try ChainVerifier.verify(db)
            if !res.ok { die("FAIL chain at seq \(res.firstBadSeq!): \(res.reason ?? "?") (\(res.rows) rows verified before it)", 1) }
            let head = try db.head()
            let anchors = try AnchorStore(db).list()
            for a in anchors {
                guard let token = a.token else { continue }
                let info = try RFC3161.parseToken(token)
                if info.imprint != a.headHash { die("FAIL anchor \(a.id): token imprint ≠ head_hash", 1) }
            }
            say("chain OK: \(res.rows) rows; head #\(head.seq) \(head.hash.map { String(format: "%02x", $0) }.joined())")
            let anchoredSeq = anchors.map(\.headSeq).max() ?? 0
            say("anchors: \(anchors.count) (tokens parse, imprints match); "
                + (anchoredSeq >= head.seq ? "head is anchored" : "\(head.seq - anchoredSeq) row(s) after the last anchor"))
        }

    case "anchor":
        allow("--force")
        let db = openDB()
        switch try await Anchorer.runIfDue(db: db, force: flags.contains("--force"), tz: tz,
                                           mirrorDir: paths.home.appending(path: "anchors", directoryHint: .isDirectory)) {
        case let .notDue(why):
            say("not due: \(why)")
        case let .done(anchored, failures):
            for a in anchored {
                say("anchored head #\(a.headSeq) via \(a.tsa ?? "?"): \(a.token?.count ?? 0)-byte token, genTime \(a.genTimeMs.map { Date(timeIntervalSince1970: Double($0) / 1000).ISO8601Format() } ?? "?")")
            }
            failures.forEach { say("failed: \($0)") }
            if anchored.isEmpty { exit(1) }
        }

    case "witness":
        allow("--period")
        say(try ExportWitness.line(db: openDB(), period: period()))

    case "seed-demo":
        allow("--days")
        guard let home = ProcessInfo.processInfo.environment["SPELLS_HOME"], !home.isEmpty else {
            die("seed-demo refuses to run without SPELLS_HOME (it must never touch the real database)", 1)
        }
        guard let days = Int(options["--days"] ?? "14"), days > 0 else { die("bad --days") }
        let r = try ExportDemoSeed.run(db: openDB(), days: days, today: today, tzId: tz.identifier)
        say("seeded \(r.spans) spans \(r.from)..\(r.through) into \(paths.db.path)")

    case "tracker":
        allow("--pause", "--idle")
        let settings = SettingStore(openDB())
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if let p = options["--pause"] {
            guard let min = Int(p), min >= 0 else { die("bad --pause (minutes, 0 = resume)") }
            try TrackerPauseSetting.save(settings, untilMs: min == 0 ? nil : now + Int64(min) * 60_000)
        }
        if let i = options["--idle"] {
            guard let s = Int(i), s > 0 else { die("bad --idle (seconds)") }
            try settings.set(TrackerIdleSetting.key, String(s))
        }
        say("pause_until_ms=\(try settings.get(TrackerPauseSetting.key) ?? "-") idle_threshold_s=\(try TrackerIdleSetting.load(settings))")
        say("tracker_state=\(try settings.get(TrackerState.key) ?? "-")")

    case "import-rize":
        allow("--source", "--dry-run", "--since")
        try await importRize()

    case "standup":
        allow("--date", "--regenerate", "--print")
        try standup()

    case "classify":
        allow("--since", "--dry-run")
        try await classify()

    case "scry":
        allow("--root", "--keep", "--limit")   // per subcommand would need `command` inside ScryCommand.swift
        try await scry()

    case "-h", "--help", "help":
        say(usage)

    default:
        die(usage)
    }
} catch {
    die("error: \(error)", 1)
}
