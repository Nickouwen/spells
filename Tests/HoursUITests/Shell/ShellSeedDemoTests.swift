import Foundation
import Testing
import HoursCore
@testable import HoursUI

/// Dev helper, not a check: `HOURS_SEED_HOME=<dir> swift test --filter ShellSeedDemo` writes 20 days
/// of `DemoData` (up to now, local tz) into `<dir>/hours.db` so `SPELLS_HOME=<dir> swift run Hours`
/// has something to show. Refuses the real home. Skipped when the variable is unset.
@Suite struct ShellSeedDemoTests {
    static let home = ProcessInfo.processInfo.environment["HOURS_SEED_HOME"]

    @Test(.enabled(if: home != nil))
    func seedDemoIntoHome() throws {
        let home = URL(filePath: try #require(Self.home), directoryHint: .isDirectory)
        let paths = SupportPaths(home: home, logs: home.appending(path: "logs"))
        try #require(paths.db.standardizedFileURL != SupportPaths.current(environment: [:]).db.standardizedFileURL)
        try paths.createDirectories()
        let db = try HoursDB.open(at: paths.db, role: .app, notifyName: "dev.nic.spells.seed.\(UUID().uuidString)")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try shellSeedDemo(db, tz: .current, nowMs: now, daysBack: 0...19)
        let n = try Store(db).rawSpans(from: now - 21 * 86_400_000, to: now).count
        print("seeded \(n) spans into \(paths.db.path)")
        #expect(n > 0)
    }
}
