import Darwin
import Foundation
import HoursCore

/// Called first thing by the helper's main. Exits(0) if another tracker already holds the lock.
// ponytail: an exclusive flock on `<home>/tracker.lock` instead of scanning NSRunningApplication —
// race-free when two copies start at once (both would see each other and both exit), released by
// the kernel on crash, needs no AppKit, and also guards a headless helper LaunchServices may not list.
// Keyed by SPELLS_HOME, so a dev instance with its own home can run beside the installed one.
enum TrackerSingleInstance {
    static func exitIfAlreadyRunning(paths: SupportPaths = .current()) {
        try? FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let lock = paths.home.appending(path: "tracker.lock").path
        let fd = open(lock, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            // Can't create the lock: run unguarded rather than never track.
            SupportLog.tracker.error("single-instance lock unavailable (errno \(errno)); continuing")
            return
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            SupportLog.tracker.info("another HoursSpell is running; exiting")
            exit(0)
        }
        // fd deliberately never closed: the lock lives exactly as long as this process.
    }
}
