import AppKit
import Darwin
import SpellsKit
import SpellsUI

// Ward, the network-watch spell: a menu-bar accessory module, started from the Spells launcher (and at
// login once it registered itself). The shield in the menu bar says whether the capture daemon runs;
// its menu opens the Network window and Settings.

// Exit(0) if another Ward holds `<home>/ward.lock` (the flock pattern Incant and Scry use).
let paths = SupportPaths.current()
try? FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
let lockFD = open(paths.home.appending(path: "ward.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
if lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) != 0 {   // no lock file: run unguarded rather than not at all
    SupportLog.ward.info("another Ward is running; exiting")
    exit(0)
}
// lockFD deliberately never closed: the lock lives exactly as long as this process.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let status = WardStatusItem()
ModuleURLs.install(settings: .ward()) { verb, query in WardWindows.handle(verb, query) }
ModuleLoginItem.sync(.ward())
ModuleUpdater.start(settings: .ward()) { WardWindows.model.busy != nil }
SupportLog.ward.info("Ward started")
app.run()
