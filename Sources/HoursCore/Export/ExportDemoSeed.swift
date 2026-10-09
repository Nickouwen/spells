import Foundation
import GRDB

/// `spellsctl seed-demo`: writes `DemoData` spans for the `days` days before `today` through the real
/// SpanWriter (so they're chained), plus the seed classification config if the DB has none.
/// Re-runnable: spans that would overlap what's already chained are skipped.
public enum ExportDemoSeed {
    public static func run(db: HoursDB, days: Int, today: LocalDate, tzId: String) throws
        -> (spans: Int, from: LocalDate, through: LocalDate) {
        let through = today.storePrevDay()
        var from = today
        for _ in 0..<days { from = from.storePrevDay() }

        let cfg = ConfigStore(db)
        if try cfg.categories().isEmpty {
            for c in ClassifySeed.categories { try cfg.insert(c) }
            for p in ClassifySeed.projects { try cfg.insert(p) }
            for r in ClassifySeed.rules { try cfg.insert(r) }
        }

        let lastEnd = try db.writer.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(end_ms) FROM span") } ?? .min
        let writer = SpanWriter(db)
        var n = 0
        for s in DemoData.spans(from: from, through: through, tzId: tzId) where s.startMs >= lastEnd {
            try writer.append(s)
            n += 1
        }
        return (n, from, through)
    }
}
