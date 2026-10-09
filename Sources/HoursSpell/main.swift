import AppKit
import HoursCore
import TrackerCore

// Helper: AppKit only (no SwiftUI). Tracking runs an accessory NSApplication for the menu-bar status
// item; --dry-run stays on a bare run loop. Either way the main run loop services all sources.
//
//   HoursSpell [--idle-threshold S]                           track → hours.db (SupportPaths)
//   HoursSpell --dry-run [--seconds N] [--idle-threshold S]   real adapters → JSON lines on stdout
//
// --idle-threshold is a debug knob (verify the adapters while nobody touches the Mac).

let args = CommandLine.arguments
func value(_ flag: String) -> Double? {
    args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil }
}

var config = TrackerConfig()
let idleOverride = value("--idle-threshold")
if let s = idleOverride { config.idleThresholdMs = Int64(s * 1000) }

if args.contains("--dry-run") {
    let runtime = TrackerRuntime(sink: PrintSink(), options: .init(config: config, promptForPermissions: false))
    runtime.installSignalHandlers()
    runtime.start()
    if let seconds = value("--seconds") {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { runtime.stop(); exit(0) }
        }
    }
    RunLoop.main.run()
}

TrackerSingleInstance.exitIfAlreadyRunning()
let paths = SupportPaths.current()
let db: HoursDB
do {
    try paths.createDirectories()
    db = try HoursDB.open(at: paths.db, role: .tracker)
} catch {
    // schemaTooNew included: exit and let the app's relaunch pick up the newer binary.
    SupportLog.tracker.fault("cannot open db: \(String(describing: error), privacy: .public)")
    exit(1)
}

let spans = SpanWriter(db)
do {
    if let seq = try spans.recoverLiveSpan() { SupportLog.tracker.info("recovered live span as seq \(seq)") }
} catch {
    SupportLog.tracker.error("live span recovery failed: \(String(describing: error), privacy: .public)")
}

@Sendable func backupIfDue() {
    do { try SupportBackup.runIfDue(dbURL: paths.db, backupsDir: paths.backups) } catch {
        SupportLog.backup.error("backup failed: \(String(describing: error), privacy: .public)")
    }
}
backupIfDue()

// A SPELLS_HOME run is dev/test: no TCC prompts (below) and no real DigiCert/FreeTSA requests.
let isDevRun = ProcessInfo.processInfo.environment["SPELLS_HOME"] != nil

@Sendable func anchorIfDue() {
    guard !isDevRun else { return }
    Task.detached(priority: .utility) {
        do {
            if case .done(let anchored, let failures) = try await Anchorer.runIfDue(db: db) {
                SupportLog.tracker.info("anchored via \(anchored.count) TSA(s), \(failures.count) failure(s)")
            }
        } catch {
            SupportLog.tracker.error("anchor failed: \(String(describing: error), privacy: .public)")
        }
    }
}
// Launch covers "asleep at midnight": the first launch/wake on a new day anchors yesterday's head.
anchorIfDue()

let sink = TrackerStoreSink(spans) {
    // Day rollover, or the first span after waking on a later day. Off the main thread:
    // VACUUM INTO is a WAL read, and blocking here would delay (and so skew) span boundaries.
    DispatchQueue.global(qos: .utility).async { backupIfDue() }
    anchorIfDue()
}
let runtime = TrackerRuntime(sink: sink, options: .init(config: config, promptForPermissions: !isDevRun))
runtime.installSignalHandlers()
// A pause survives restart: re-apply it before start() so no span opens in between.
do {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    if let until = try TrackerPauseSetting.load(SettingStore(db), nowMs: nowMs) { runtime.pause(untilMs: until) }
} catch {
    SupportLog.tracker.error("pause setting unreadable: \(String(describing: error), privacy: .public)")
}
runtime.start()
SupportLog.tracker.info("tracking started")
// NSApplication only for the status item; accessory = no Dock icon (LSUIElement says the same when bundled).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let statusItem = TrackerStatusItem(runtime: runtime, sink: sink, db: db)
// Live settings in, tracker_state out. Chained after the status item's icon refresh.
let stateSync = TrackerStateSync(db: db, runtime: runtime, lastWriteFailed: { sink.lastWriteFailed })
// The notch island (W18): `island_style` off|both|right, applied live from the change feed.
let island = TrackerIsland(db: db, runtime: runtime, actions: statusItem)
statusItem.island = island
// W20: the weekday EOD standup, off the same onChange (the 30 s tick fires it). Never on dev runs.
let standupAuto = isDevRun ? nil : TrackerStandupAuto(db: db, logs: paths.logs)
let refreshIcon = runtime.onChange
runtime.onChange = { refreshIcon?(); stateSync.report(); island.runtimeChanged(); standupAuto?.check() }
// --idle-threshold is a debug override that wins over the setting; pause still follows settings.
stateSync.idleOverrideMs = idleOverride.map { Int64($0 * 1000) }
stateSync.start()
stateSync.report()
island.start()
app.run()
