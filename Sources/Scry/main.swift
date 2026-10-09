import AppKit
import Darwin
import HoursCore

// Scry, the meeting-notes spell: a menu-bar accessory (login item of Spells.app, only while switched on).
// Offers to record when a call app takes the mic; after the call, ScryPipeline writes the note.

// CLI test modes: no UI and no single-instance lock.
let args = CommandLine.arguments
if args.contains("--mic-users") { exit(ScryTestModes.micUsers()) }
if let i = args.firstIndex(of: "--test-capture") {
    let rest = Array(args.dropFirst(i + 1))
    guard rest.count >= 2, let seconds = Double(rest[0]) else { print("usage: Scry --test-capture <seconds> <dir>"); exit(64) }
    Task { exit(await ScryTestModes.testCapture(seconds: seconds, dir: rest[1])) }
    dispatchMain()
}

// Exit(0) if another Scry holds `<home>/scry.lock` (same flock pattern as Incant's).
let paths = SupportPaths.current()
try? FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
let lockFD = open(paths.home.appending(path: "scry.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
if lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) != 0 {   // no lock file: run unguarded rather than not at all
    SupportLog.scry.info("another Scry is running; exiting")
    exit(0)
}
// lockFD deliberately never closed: the lock lives exactly as long as this process.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let scry = ScryApp()
SupportLog.scry.info("Scry started")
app.run()
