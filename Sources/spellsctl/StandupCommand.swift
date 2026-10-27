import Foundation
import RewindCore

/// `spellsctl standup [--date YYYY-MM-DD] [--from YYYY-MM-DD] [--fix TEXT] [--clear-fixes] [--regenerate] [--print]`. The default date is the calendar
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
    var from: LocalDate?
    if let s = options["--from"] {
        guard let d = LocalDate(iso: s), d <= date else { die("bad --from '\(s)' (YYYY-MM-DD, not after --date)") }
        from = d
    }
    let corrections: StandupGenerator.Corrections = options["--fix"].map { .add($0) } ?? (flags.contains("--clear-fixes") ? .clear : .keep)
    switch try StandupGenerator.run(db: db, date: date, from: from,
                                    regenerate: flags.contains("--regenerate") || from != nil || corrections == .clear,
                                    corrections: corrections) {
    case .exists(let s):
        say("already generated for \(date)\(s.editedMs != nil ? " (edited)" : "") — use --regenerate to replace it, --print to show it")
    case .generated(let s):
        say("generated standup for \(date): \(s.body.count) chars via \(s.model ?? "?"), inputs sha256 \(s.inputsSha256?.prefix(12) ?? "?")…")
    }
}
