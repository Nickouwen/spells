import Foundation
import HoursCore
import ScryCore
import ScryPipeline

/// `spellsctl scry process <captureDir> | ask "<question>" | list`, all with `--root DIR` overriding
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

    case "ask":
        guard positional.count == 2 else { die(usage) }
        guard let limit = Int(options["--limit"] ?? "5"), limit > 0 else { die("bad --limit") }
        let (answer, sources) = try await ScryAsk.answer(positional[1], root: root, limit: limit)
        say(answer)
        if !sources.isEmpty { say("\nsources:"); sources.forEach { say("  \($0.path)") } }

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
