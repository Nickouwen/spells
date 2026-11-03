import AppKit
import SpellsKit
import SpellsUI
import WardCore
import WardUI

/// The shield in the menu bar (Resources/Ward/MenuBar*.png): painted while the capture daemon runs,
/// a dimmed template when it doesn't, so a glance says whether the Mac is being recorded. Polls the
/// daemon every 20 s (no root needed). The menu: the state, Network, Read Captures, Install / Remove,
/// login, Settings, Quit.
@MainActor final class WardStatusItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var status = WardStatus(daemon: .notInstalled, toolsInstalled: false)
    private var timer: Timer?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        Task { [weak self] in
            let s = await WardSystem.status()
            guard let self else { return }
            if s != status { status = s; refresh() }
        }
    }

    private func refresh() {
        let on = status.running
        let image = Bundle.main.image(forResource: on ? "MenuBarColor" : "MenuBar")
        image?.isTemplate = !on
        item.button?.image = image
        item.button?.alphaValue = on ? 1 : 0.5
        item.button?.toolTip = "Ward: \(status.title.lowercased())"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        poll()
        menu.removeAllItems()
        menu.addItem(info(status.running ? "● \(status.title)" : status.title))
        menu.addItem(action("Network…", #selector(openNetwork)))
        let read = action("Read Captures…", #selector(readCaptures))
        read.isEnabled = status.installed && status.toolsInstalled
        menu.addItem(read)
        menu.addItem(.separator())
        if status.installed {
            menu.addItem(action("Remove Capture Daemon…", #selector(remove)))
        } else {
            let install = action("Install Capture Daemon…", #selector(install))
            install.isEnabled = status.toolsInstalled
            menu.addItem(install)
        }
        let login = action("Start Ward at Login", #selector(toggleLogin))
        login.state = ModuleLoginItem.isOn ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings)))
        menu.addItem(action("Open Spells", #selector(openSpells)))
        menu.addItem(action("Quit Ward", #selector(quit)))
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func openNetwork() { WardWindows.showNetwork() }
    @objc private func openSettings() { WardWindows.showSettings() }
    @objc private func readCaptures() { WardWindows.showNetwork(); WardWindows.model.takeSnapshot() }
    @objc private func install() { WardWindows.model.install(); poll() }
    @objc private func remove() {
        let a = NSAlert()
        a.messageText = "Stop capturing and remove the daemon?"
        a.informativeText = "The capture files stay in \(Ward.captureDir) until you delete them yourself."
        a.addButton(withTitle: "Remove"); a.addButton(withTitle: "Cancel")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { WardWindows.model.uninstall(); poll() }
    }
    @objc private func toggleLogin() { ModuleLoginItem.set(!ModuleLoginItem.isOn, settings: .ward()) }
    @objc private func openSpells() {
        if let url = ModuleURLs.installed(Spells.launcherBundleID) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
