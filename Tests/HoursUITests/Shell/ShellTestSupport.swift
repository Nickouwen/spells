import Foundation
import HoursCore
@testable import HoursUI

/// Temp home (never ~/Library) + `.app` DB with a unique notify name, so tests don't wake a real app.
@MainActor
func shellTempModel(clock: ShellTestClock? = nil, seedDemo: ClosedRange<Int>? = nil) throws -> AppModel {
    let home = FileManager.default.temporaryDirectory.appending(path: "hours-shell-tests/\(UUID().uuidString)")
    let paths = SupportPaths(home: home, logs: home.appending(path: "logs"))
    try paths.createDirectories()
    let db = try HoursDB.open(at: paths.db, role: .app, notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
    let tz = TimeZone(identifier: "America/Vancouver")!
    let clock = clock ?? ShellTestClock(shellMs(2026, 10, 5, 15, tz: tz))
    if let seedDemo { try shellSeedDemo(db, tz: tz, nowMs: clock.ms, daysBack: seedDemo) }
    return try AppModel(db: db, paths: paths, timeZone: tz, clock: { clock.ms })
}

/// Settable test clock (Unix ms).
final class ShellTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ ms: Int64) { value = ms }
    var ms: Int64 {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

func shellMs(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, tz: TimeZone) -> Int64 {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    return Int64(date.timeIntervalSince1970 * 1000)
}

/// Writes `DemoData` for [today − upper, today − lower] through `SpanWriter`, clipped at `nowMs`.
func shellSeedDemo(_ db: HoursDB, tz: TimeZone, nowMs: Int64, daysBack: ClosedRange<Int>) throws {
    let today = LocalDate.containing(ms: nowMs, in: tz)
    let spans = DemoData.spans(from: today.shellShifted(by: -daysBack.upperBound),
                               through: today.shellShifted(by: -daysBack.lowerBound), tzId: tz.identifier)
    let writer = SpanWriter(db)
    for s in spans where s.endMs <= nowMs { _ = try writer.append(s) }
}

/// Polls `cond` on the main actor every 20 ms until true or `timeout` passes.
@MainActor
// ponytail: 30 s ceiling — returns as soon as cond holds; the full suite runs suites in parallel and model loads stall under load.
func shellWait(_ timeout: Duration = .seconds(30), _ cond: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return cond()
}
