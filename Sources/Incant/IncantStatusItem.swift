import AppKit
import HoursCore

/// Menu-bar mic: waveform = ready, waveform.circle.fill = listening, waveform.slash = a permission is missing. The menu lists both
/// permissions (click a missing one to open its Settings pane). Switching Incant off is in Spells.
@MainActor final class IncantStatusItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var listening = false { didSet { refresh() } }

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    func refresh() {
        let (symbol, tip) = listening ? ("waveform.circle.fill", "Incant: listening")
            : IncantPermissions.ready ? ("waveform", "Incant: ready") : ("waveform.slash", "Incant: permissions needed")
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        item.button?.toolTip = tip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        menu.addItem(info("Incant — dictation"))
        menu.addItem(permission("Microphone", ok: IncantPermissions.microphone == .authorized, pane: "Privacy_Microphone"))
        menu.addItem(permission("Accessibility", ok: IncantPermissions.accessibility, pane: "Privacy_Accessibility"))
        menu.addItem(.separator())
        menu.addItem(action("Open Spells", #selector(openSpells)))
        menu.addItem(action("Quit Incant", #selector(quit)))
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func permission(_ name: String, ok: Bool, pane: String) -> NSMenuItem {
        let i = action(ok ? "\(name): allowed" : "\(name): not allowed — open Settings", #selector(openPane(_:)))
        i.representedObject = pane
        i.isEnabled = !ok
        return i
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func openPane(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? String,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSpells() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Hours.bundlePrefix) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
