import AppKit
import HoursCore

// Incant, the dictation spell: a menu-bar accessory that runs only while switched on in
// Settings → Spells (a login item of Spells.app). Hold Fn to dictate; double-tap for hands-free.

// `Incant --selftest <file.wav>`: no UI, key tap or paste, and no single-instance lock.
if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
    let path = CommandLine.arguments.dropFirst(i + 1).first ?? ""
    Task { exit(await IncantSelftest.run(path)) }
    dispatchMain()
}

IncantSingleInstance.exitIfAlreadyRunning()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let statusItem = IncantStatusItem()
let session = IncantSession()
session.onListening = { statusItem.listening = $0 }
let keyTap = IncantKeyTap(onEvent: { session.handle($0) }, isListening: { session.isListening })
IncantPermissions.request {
    statusItem.refresh()
    session.prepare()
    keyTap.start()
}
SupportLog.incant.info("Incant started")
app.run()
