import Darwin
import Foundation
import HoursCore

/// Exits(0) if another Incant holds `<home>/incant.lock` (same flock pattern as HoursSpell's).
enum IncantSingleInstance {
    static func exitIfAlreadyRunning(paths: SupportPaths = .current()) {
        try? FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let fd = open(paths.home.appending(path: "incant.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }   // no lock file: run unguarded rather than not at all
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            SupportLog.incant.info("another Incant is running; exiting")
            exit(0)
        }
        // fd deliberately never closed: the lock lives exactly as long as this process.
    }
}
