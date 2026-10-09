import Foundation
import GRDB

/// Daily `VACUUM INTO` snapshot of the live DB. Protects against loss/corruption, not tampering
/// (item 9's anchor does that). Needs no schema knowledge. Run at helper launch and on day rollover.
public enum SupportBackup {
    public enum Outcome: Sendable, Equatable {
        case created(URL)
        /// Today's backup already exists.
        case notDue
        /// No database file yet (first launch before the store created it).
        case noDatabase
    }

    public enum Failure: Error, Equatable {
        case quickCheckFailed(String)
    }

    static let keepDailies = 14
    static let keepMonths = 12

    /// Writes `backups/hours-YYYY-MM-DD.db` unless one for today (in `calendar`) exists:
    /// `VACUUM INTO` a temp file → `PRAGMA quick_check` → rename, then prunes.
    // ponytail: "due" = no file named for today's date, not mtime > 24 h. One backup per calendar day.
    @discardableResult
    public static func runIfDue(dbURL: URL, backupsDir: URL, now: Date = Date(),
                                calendar: Calendar = .current) throws -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbURL.path) else { return .noDatabase }
        let today = localDate(now, calendar)
        let final = backupsDir.appending(path: fileName(today))
        if fm.fileExists(atPath: final.path) { return .notDue }

        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let tmp = backupsDir.appending(path: ".hours-\(today).tmp")
        try? fm.removeItem(at: tmp)  // leftover from a crash mid-backup; VACUUM INTO needs a fresh target
        do {
            try snapshot(dbURL, into: tmp)
            let check = try quickCheck(tmp)
            guard check == "ok" else { throw Failure.quickCheckFailed(check) }
            try fm.moveItem(at: tmp, to: final)
        } catch {
            try? fm.removeItem(at: tmp)
            SupportLog.backup.error("backup failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        let pruned = try prune(backupsDir: backupsDir, now: now, calendar: calendar)
        SupportLog.backup.info("backup \(final.lastPathComponent, privacy: .public) ok, pruned \(pruned.count)")
        return .created(final)
    }

    /// Keeps the newest 14 backups plus the earliest backup of each of the last 12 calendar months
    /// (current month included). Deletes the rest; returns what it deleted. Ignores unrelated files.
    @discardableResult
    static func prune(backupsDir: URL, now: Date, calendar: Calendar) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)
        let dated = names.compactMap { name in parse(name).map { (date: $0, name: name) } }
        let keep = keptDates(dated.map(\.date), today: localDate(now, calendar))
        var deleted: [URL] = []
        for entry in dated where !keep.contains(entry.date) {
            let url = backupsDir.appending(path: entry.name)
            try FileManager.default.removeItem(at: url)
            deleted.append(url)
        }
        return deleted
    }

    static func keptDates(_ dates: [LocalDate], today: LocalDate) -> Set<LocalDate> {
        let sorted = dates.sorted()
        var keep = Set(sorted.suffix(keepDailies))
        let todayMonth = today.year * 12 + today.month - 1
        var seenMonths = Set<Int>()
        for date in sorted {  // ascending, so the first hit per month is its earliest backup
            let month = date.year * 12 + date.month - 1
            guard todayMonth - month < keepMonths, seenMonths.insert(month).inserted else { continue }
            keep.insert(date)
        }
        return keep
    }

    // MARK: - Internals

    private static func snapshot(_ db: URL, into target: URL) throws {
        let queue = try DatabaseQueue(path: db.path)
        // VACUUM can't run inside a transaction. Under WAL this is a read; writers aren't blocked.
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [target.path])
        }
        try queue.close()
    }

    private static func quickCheck(_ file: URL) throws -> String {
        let queue = try DatabaseQueue(path: file.path)
        let result = try queue.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check") }
        try queue.close()
        return result.joined(separator: "\n")
    }

    static func fileName(_ date: LocalDate) -> String { "hours-\(date).db" }

    /// `hours-YYYY-MM-DD.db` → date; anything else → nil.
    static func parse(_ name: String) -> LocalDate? {
        guard name.hasPrefix("hours-"), name.hasSuffix(".db") else { return nil }
        let parts = name.dropFirst(6).dropLast(3).split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return LocalDate(year: y, month: m, day: d)
    }

    static func localDate(_ date: Date, _ calendar: Calendar) -> LocalDate {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return LocalDate(year: c.year!, month: c.month!, day: c.day!)
    }
}
