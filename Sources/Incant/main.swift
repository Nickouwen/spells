import AppKit
import SpellsKit
import SpellsUI

// Incant, the dictation spell: a menu-bar accessory module, started from the Spells launcher (and at login
// once it registered itself). Hold Fn to dictate; double-tap for hands-free.

// `Incant --selftest <file.wav>`: no UI, key tap or paste, and no single-instance lock.
if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
    let path = CommandLine.arguments.dropFirst(i + 1).first ?? ""
    Task { exit(await IncantSelftest.run(path)) }
    dispatchMain()
}

// `Incant --mic-test <seconds>`: records the mic as dictation does, then prints the device, the delay to the
// first audio and the level. No UI, key tap or lock.
if let i = CommandLine.arguments.firstIndex(of: "--mic-test") {
    let seconds = Double(CommandLine.arguments.dropFirst(i + 1).first ?? "") ?? 3
    let mic = IncantMic()
    mic.prepare()
    let t = Date()
    nonisolated(unsafe) var first: TimeInterval?, bytes = 0, peak = 0.0
    do { try mic.start { d in if first == nil { first = Date().timeIntervalSince(t) }; bytes += d.count } } catch { print("start failed: \(error)"); exit(1) }
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in peak = max(peak, mic.level) }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        bytes += mic.stop().count
        print("mic: \(mic.deviceName), first chunk after \(Int((first ?? -1) * 1000)) ms, \(String(format: "%.2f", Double(bytes) / 32000)) s of audio, peak level \(String(format: "%.2f", peak))")
        exit(0)
    }
    RunLoop.main.run()
}

// `Incant --type-test [gap ms]`: types a scripted dictation into real text fields and reads them back
// (`IncantTypeTest`). Takes the keyboard focus for a few seconds.
if let i = CommandLine.arguments.firstIndex(of: "--type-test") {
    let gap = Int(CommandLine.arguments.dropFirst(i + 1).first ?? "") ?? 200
    Task { @MainActor in exit(await IncantTypeTest.run(gapMs: gap)) }
    NSApplication.shared.run()
}

IncantSingleInstance.exitIfAlreadyRunning()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let statusItem = IncantStatusItem()
ModuleURLs.install(settings: .incant()) { verb, query in IncantWindows.handle(verb, query) }
ModuleLoginItem.sync(.incant())
let session = IncantSession()
session.onListening = { statusItem.listening = $0 }
ModuleUpdater.start(settings: .incant()) { session.isListening }
let keyTap = IncantKeyTap(onEvent: { session.handle($0) }, isListening: { session.isListening }, onUserInput: { session.userActed() })
// A click can move the cursor away from what Incant typed, like a key press (`IncantSession.userActed`).
NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
    MainActor.assumeIsolated { session.userActed() }
}
IncantPermissions.request {
    statusItem.refresh()
    session.prepare()
    keyTap.start()
}
SupportLog.incant.info("Incant started")
app.run()
