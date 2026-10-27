import AppKit
import SpellsKit

/// Menu-bar waveform glyph (Resources/Incant/MenuBar*.png): template = ready, painted green = listening,
/// dimmed = a permission is missing. The menu lists both
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
        let ready = IncantPermissions.ready
        let tip = listening ? "Incant: listening" : ready ? "Incant: ready" : "Incant: permissions needed"
        let image = Bundle.main.image(forResource: listening ? "MenuBarColor" : "MenuBar")
        image?.isTemplate = !listening
        item.button?.image = image
        item.button?.alphaValue = listening || ready ? 1 : 0.45
        item.button?.toolTip = tip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        menu.addItem(info("Incant — dictation"))
        menu.addItem(permission("Microphone", ok: IncantPermissions.microphone == .authorized, pane: "Privacy_Microphone"))
        menu.addItem(permission("Accessibility", ok: IncantPermissions.accessibility, pane: "Privacy_Accessibility"))
        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings)))
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
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Spells.launcherBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openSettings() { IncantWindows.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
