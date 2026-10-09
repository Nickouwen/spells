import Foundation
import HoursCore

/// W20 auto-run: on weekdays at/after `standup_time`, spawn `~/.local/bin/spellsctl standup` once a
/// day if no standup is stored for today, then `--regenerate` hourly while transcripts keep changing
/// (never over a hand edit; `StandupSettings.refreshDue`). Driven by `runtime.onChange` (which the
/// 30 s tick fires), throttled to one settings read per 30 s — no timer of its own. The child is
/// detached and runs at background QoS; its output goes to `<logs>/standup.log`.
@MainActor final class TrackerStandupAuto {
    private let db: HoursDB
    private let spellsctl: URL
    private let log: URL
    private var lastCheckMs: Int64 = 0
    /// The calendar day whose first run was spawned (or found stored) — a failed first run isn't retried.
    private var handledDay: LocalDate?
    /// Last spawn, so a failing refresh waits an hour like a successful one.
    private var lastSpawnMs: Int64 = 0
    private var child: Process?

    init(db: HoursDB, logs: URL,
         spellsctl: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/spellsctl")) {
        self.db = db; self.spellsctl = spellsctl; self.log = logs.appending(path: "standup.log")
    }

    func check(now: Date = Date()) {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        guard nowMs - lastCheckMs >= 30_000 else { return }
        lastCheckMs = nowMs
        let tz = TimeZone.current
        let today = LocalDate.standupDay(containing: now, in: tz)
        guard child == nil else { return }
        do {
            guard StandupSettings.load(try SettingStore(db).all()).isDue(at: now, in: tz) else { return }
            if let stored = try StandupStore(db).get(today) {
                handledDay = today
                guard StandupSettings.refreshDue(stored, nowMs: nowMs, lastAttemptMs: lastSpawnMs,
                                                 newestTranscriptMs: StandupSettings.newestTranscriptMs()) else { return }
                try spawn(["standup", "--regenerate"], nowMs: nowMs)
            } else if handledDay != today {
                handledDay = today
                try spawn(["standup"], nowMs: nowMs)
            }
        } catch {
            SupportLog.tracker.error("standup auto-run failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func spawn(_ args: [String], nowMs: Int64) throws {
        guard FileManager.default.isExecutableFile(atPath: spellsctl.path) else {
            SupportLog.tracker.error("standup auto-run: \(self.spellsctl.path, privacy: .public) missing")
            return
        }
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let out = try FileHandle(forWritingTo: log)
        out.seekToEndOfFile()
        out.write(Data("\n--- \(Date().ISO8601Format()) spellsctl \(args.joined(separator: " "))\n".utf8))
        let p = Process()
        p.executableURL = spellsctl
        p.arguments = args
        p.qualityOfService = .background
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = out
        p.terminationHandler = { [weak self] proc in
            try? out.close()
            let status = proc.terminationStatus
            SupportLog.tracker.info("standup auto-run exited \(status)")
            Task { @MainActor in self?.child = nil }
        }
        try p.run()
        child = p
        lastSpawnMs = nowMs
        SupportLog.tracker.info("standup auto-run spawned pid \(p.processIdentifier)")
    }
}
