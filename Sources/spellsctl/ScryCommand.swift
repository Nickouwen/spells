import Foundation
import RewindCore
import ScryCore
import ScryPipeline

/// `spellsctl scry process <captureDir> | resummarize <note.md> | ask "<question>" | list`, all with `--root DIR` overriding
/// `ScrySettings.rootURL` (so tests never write to ~/Documents/Scry).
@MainActor func scry() async throws {
    let rows = ScryPipeline.settingRows()
    var settings = ScrySettings.load(rows)
    if let r = options["--root"] { settings.root = r }
    let root = settings.rootURL
    switch positional.first {
    case "process":
        guard positional.count == 2 else { die(usage) }
        if flags.contains("--keep") { setenv("SCRY_KEEP_CAPTURE", "1", 1) }
        let dir = URL(filePath: (positional[1] as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        let r = try await ScryPipeline.process(captureDir: dir, settings: settings, keyterms: ScryPipeline.keyterms(rows))
        say(r.noteURL.path)
        say("\(r.summary.title) — \(r.summary.actionItems.count) action item(s)")
        say("scribe \(r.scribeMs) ms (\(r.diarized ? "diarized" : "far side silent, skipped")), claude \(r.claudeMs) ms")

    case "resummarize":
        guard positional.count == 2 else { die(usage) }
        let url = URL(filePath: (positional[1] as NSString).expandingTildeInPath)
        let s = try await ScryPipeline.resummarize(note: url, settings: settings, keyterms: ScryPipeline.keyterms(rows))
        say("\(url.path)\n\(s.title) — \(s.actionItems.count) action item(s)")

    case "ask":
        guard positional.count == 2 else { die(usage) }
        guard let limit = Int(options["--limit"] ?? "5"), limit > 0 else { die("bad --limit") }
        let (answer, sources) = try await ScryAsk.answer(positional[1], root: root, limit: limit)
        say(answer)
        if !sources.isEmpty { say("\nsources:"); sources.forEach { say("  \($0.path)") } }

    case "tidy":
        guard positional.count >= 2 else { die(usage) }
        for p in positional.dropFirst() {
            let url = URL(filePath: (p as NSString).expandingTildeInPath)
            let before = ScryNote.parse(try String(contentsOf: url, encoding: .utf8))?.segments.count ?? 0
            let changed = try ScryNotes.tidy(url)
            let after = ScryNote.parse(try String(contentsOf: url, encoding: .utf8))?.segments.count ?? 0
            say("\(url.lastPathComponent): \(changed ? "\(before) → \(after) lines" : "unchanged (\(after) lines)")")
        }

    case "meet":
        // Calibration: what the Meet tab in Chrome reports, twice a second. --dump prints every tile's classes once.
        guard let secs = Int(options["--seconds"] ?? "10"), secs > 0 else { die("bad --seconds") }
        let w = ScryMeetWatch(browser: options["--browser"] ?? "com.google.Chrome", dir: URL(filePath: NSTemporaryDirectory()), startedAt: Date())
        var dumped = !flags.contains("--dump")
        for _ in 0..<(secs * 2) {
            if let p = w.peek() {
                if !dumped {
                    dumped = true
                    for t in p.sample.tiles { say("tile \(t.id)  name=\(t.name ?? "-")  self=\(t.isSelf)\n  \(t.classes.sorted().joined(separator: " "))") }
                    say("selfName=\(p.sample.selfName ?? "-")")
                }
                say("\(p.speaking.map { "speaking: \($0.name ?? $0.id)\($0.isSelf ? " (you)" : "")" } ?? "speaking: -")  marker=\(p.marker ?? "-")  people: \(p.sample.participants.joined(separator: ", "))")
            } else {
                say("nothing from the browser (no Meet tab, or View ▸ Developer ▸ Allow JavaScript from Apple Events is off)")
            }
            try await Task.sleep(for: .milliseconds(500))
        }

    case "list":
        guard positional.count == 1 else { die(usage) }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        for n in ScryAsk.notes(root: root).sorted(by: { $0.note.meta.startedAt > $1.note.meta.startedAt }) {
            let open = ScryActions.items(in: n.markdown).filter { !$0.done }.count
            say("\(f.string(from: n.note.meta.startedAt))  \(n.note.summary.title)  (\(open) open)")
        }

    default:
        die(usage)
    }
}
