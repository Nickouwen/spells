import Foundation
import GRDB
import Testing
@testable import HoursCore

@Suite struct SupportBackupTests {
    let dir: URL
    let backups: URL
    let utc: Calendar

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "hours-backup-\(UUID().uuidString)")
        backups = dir.appending(path: "backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        utc = cal
    }

    func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    func touch(_ y: Int, _ m: Int, _ d: Int) {
        let name = SupportBackup.fileName(LocalDate(year: y, month: m, day: d))
        FileManager.default.createFile(atPath: backups.appending(path: name).path, contents: Data())
    }

    func listing() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: backups.path))
    }

    func makeDB(rows: Int) throws -> URL {
        let url = dir.appending(path: "hours.db")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
            for i in 0..<rows { try db.execute(sql: "INSERT INTO t (v) VALUES (?)", arguments: ["row \(i)"]) }
        }
        try queue.close()
        return url
    }

    @Test func parsesOnlyBackupNames() {
        #expect(SupportBackup.parse("hours-2026-10-05.db") == LocalDate(year: 2026, month: 10, day: 5))
        #expect(SupportBackup.parse(".hours-2026-10-05.tmp") == nil)
        #expect(SupportBackup.parse("hours-2026-13-05.db") == nil)
        #expect(SupportBackup.parse("hours.db") == nil)
        #expect(SupportBackup.parse("notes.txt") == nil)
    }

    @Test func retentionKeeps14DailiesPlusFirstOfMonthFor12Months() throws {
        // A daily backup every day from 2025-01-01 through 2026-10-05.
        var d = date(2025, 1, 1)
        while d <= date(2026, 10, 5) {
            let c = utc.dateComponents([.year, .month, .day], from: d)
            touch(c.year!, c.month!, c.day!)
            d = utc.date(byAdding: .day, value: 1, to: d)!
        }
        FileManager.default.createFile(atPath: backups.appending(path: "README").path, contents: Data())

        try SupportBackup.prune(backupsDir: backups, now: date(2026, 10, 5), calendar: utc)

        // Newest 14: 2026-09-22 … 2026-10-05 (covers Oct 1).
        // Monthly: the 1st of Nov 2025 … Sep 2026 (Oct 2026 already kept); Oct 2025 is 12 months back → gone.
        var expected: Set<String> = ["README"]
        for day in 22...30 { expected.insert("hours-2026-09-\(day).db") }
        for day in 1...5 { expected.insert("hours-2026-10-0\(day).db") }
        expected.insert("hours-2025-11-01.db")
        expected.insert("hours-2025-12-01.db")
        for month in 1...9 { expected.insert("hours-2026-0\(month)-01.db") }
        #expect(try listing() == expected)
        #expect(expected.count == 1 + 14 + 11)
    }

    @Test func monthlyKeeperIsEarliestBackupWhenTheFirstIsMissing() {
        let dates = [LocalDate(year: 2026, month: 3, day: 3), LocalDate(year: 2026, month: 3, day: 9),
                     LocalDate(year: 2026, month: 3, day: 20)]
        let recent = (1...14).map { LocalDate(year: 2026, month: 9, day: $0) }
        let kept = SupportBackup.keptDates(dates + recent, today: LocalDate(year: 2026, month: 9, day: 14))
        #expect(kept == Set(recent + [LocalDate(year: 2026, month: 3, day: 3)]))
    }

    @Test func runIfDueSnapshotsPassesQuickCheckAndPrunesThe15thDaily() throws {
        let db = try makeDB(rows: 50)
        for day in 21...30 { touch(2026, 9, day) }   // 14 prior dailies: 09-21 … 10-04
        for day in 1...4 { touch(2026, 10, day) }

        let outcome = try SupportBackup.runIfDue(dbURL: db, backupsDir: backups, now: date(2026, 10, 5), calendar: utc)

        let made = backups.appending(path: "hours-2026-10-05.db")
        #expect(outcome == .created(made))
        // Real VACUUM INTO copy: passes quick_check and holds the data.
        let copy = try DatabaseQueue(path: made.path)
        let (check, count) = try copy.read { db in
            (try String.fetchOne(db, sql: "PRAGMA quick_check"), try Int.fetchOne(db, sql: "SELECT count(*) FROM t"))
        }
        try copy.close()
        #expect(check == "ok")
        #expect(count == 50)
        // 15 dailies now, but 09-21 is September's earliest backup, so the monthly rule keeps it.
        let names = try listing()
        #expect(names.contains("hours-2026-09-21.db"))
        #expect(!names.contains { $0.hasSuffix(".tmp") })
        #expect(names.count == 15)
    }

    @Test func runIfDuePrunesOldest15thDailyWhenNotAMonthlyKeeper() throws {
        let db = try makeDB(rows: 1)
        touch(2026, 9, 1)                              // September's monthly keeper
        for day in 20...30 { touch(2026, 9, day) }     // 11 dailies
        for day in 1...3 { touch(2026, 10, day) }      // +3 = 14 dailies 09-20 … 10-03 (+ 09-01)

        try SupportBackup.runIfDue(dbURL: db, backupsDir: backups, now: date(2026, 10, 4), calendar: utc)

        let names = try listing()
        #expect(names.contains("hours-2026-10-04.db"))
        #expect(names.contains("hours-2026-09-01.db"))
        #expect(!names.contains("hours-2026-09-20.db"))  // the 15th daily
        #expect(names.count == 15)
    }

    @Test func runIfDueIsIdempotentPerDayAndSkipsMissingDB() throws {
        let missing = dir.appending(path: "nope.db")
        #expect(try SupportBackup.runIfDue(dbURL: missing, backupsDir: backups, now: date(2026, 10, 5), calendar: utc) == .noDatabase)
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        let db = try makeDB(rows: 3)
        let morning = date(2026, 10, 5, hour: 1)
        #expect(try SupportBackup.runIfDue(dbURL: db, backupsDir: backups, now: morning, calendar: utc) != .notDue)
        #expect(try SupportBackup.runIfDue(dbURL: db, backupsDir: backups, now: date(2026, 10, 5, hour: 23), calendar: utc) == .notDue)
        #expect(try SupportBackup.runIfDue(dbURL: db, backupsDir: backups, now: date(2026, 10, 6, hour: 0), calendar: utc)
                == .created(backups.appending(path: "hours-2026-10-06.db")))
    }

    @Test func runIfDueReplacesStaleTempFromACrash() throws {
        let db = try makeDB(rows: 2)
        let stale = backups.appending(path: ".hours-2026-10-05.tmp")
        FileManager.default.createFile(atPath: stale.path, contents: Data("garbage".utf8))
        try SupportBackup.runIfDue(dbURL: db, backupsDir: backups, now: date(2026, 10, 5), calendar: utc)
        #expect(try listing() == ["hours-2026-10-05.db"])
    }
}
