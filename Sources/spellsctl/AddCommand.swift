import Foundation
import RewindCore

/// `spellsctl add --date YYYY-MM-DD --start HH:MM --hours H [--label L] [--category ID] [--note TEXT] [--dry-run]`.
/// Manual time for a stretch the tracker didn't see (e.g. before it was installed), written through the same
/// `EditWriter` as the app's add-time gesture, so it is chained and undoable. The note, if given, is its own group.
@MainActor func addTime() throws {
    guard let ds = options["--date"], let date = LocalDate(iso: ds) else { die("add needs --date YYYY-MM-DD") }
    let hm = (options["--start"] ?? "").split(separator: ":").compactMap { Int($0) }
    guard hm.count == 2, (0..<24).contains(hm[0]), (0..<60).contains(hm[1]) else { die("add needs --start HH:MM") }
    guard let hours = Double(options["--hours"] ?? ""), hours > 0, hours <= 24 else { die("add needs --hours in (0, 24]") }
    guard let categoryId = Int64(options["--category"] ?? "1") else { die("bad --category (a category id)") }

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let start = cal.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: hm[0], minute: hm[1]))!
    let lo = Int64((start.timeIntervalSince1970 * 1000).rounded())
    let hi = lo + Int64((hours * 3_600_000).rounded())
    let label = options["--label"] ?? "Manual time"
    let end = Date(timeIntervalSince1970: Double(hi) / 1000).formatted(date: .omitted, time: .shortened)
    let what = "\(hours) h on \(date) \(options["--start"]!)–\(end) \(tz.identifier), category \(categoryId), label \"\(label)\""

    if flags.contains("--dry-run") { say("dry run: would add \(what)"); return }
    let writer = EditWriter(openDB())
    let grp = try writer.apply([.add(lo, hi, label: label, categoryId: categoryId)], tzId: tz.identifier)
    if let note = options["--note"] { try writer.apply([.note(group: grp, text: note)], tzId: tz.identifier) }
    say("added \(what) (edit group \(grp))")
}
