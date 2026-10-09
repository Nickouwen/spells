import Foundation
import HoursCore

/// `spellsctl standup [--date YYYY-MM-DD] [--regenerate] [--print]`. The default date is the calendar
/// day (the transcript dump's boundary), not the 04:00 store day.
@MainActor func standup() throws {
    let date: LocalDate
    if let s = options["--date"] {
        guard let d = LocalDate(iso: s) else { die("bad --date '\(s)' (YYYY-MM-DD)") }
        date = d
    } else {
        date = .standupDay(containing: Date(), in: tz)
    }
    let db = openDB()
    if flags.contains("--print") {
        guard let s = try StandupStore(db).get(date) else { die("no standup stored for \(date) — run `spellsctl standup --date \(date)`", 1) }
        say(s.body)
        return
    }
    switch try StandupGenerator.run(db: db, date: date, regenerate: flags.contains("--regenerate")) {
    case .exists(let s):
        say("already generated for \(date)\(s.editedMs != nil ? " (edited)" : "") — use --regenerate to replace it, --print to show it")
    case .generated(let s):
        say("generated standup for \(date): \(s.body.count) chars via \(s.model ?? "?"), inputs sha256 \(s.inputsSha256?.prefix(12) ?? "?")…")
    }
}
