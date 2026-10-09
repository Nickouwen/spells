import AppKit
import HoursCore
import TrackerCore

/// Menu-bar health dot (plan/07 "Menu-bar", Q10). Plain NSStatusItem + NSMenu, no SwiftUI.
/// Icon: filled = tracking, hollow = paused/idle, slashed = Accessibility missing or the last DB
/// write failed. It refreshes from `TrackerRuntime.onChange` (events + the 30 s tick) — no timer
/// of its own, no live title. The menu is built in `menuWillOpen`, so the today query runs only then.
@MainActor final class TrackerStatusItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let runtime: TrackerRuntime
    private let sink: TrackerStoreSink
    private let db: HoursDB
    private var shown = ""  // label of the icon on screen
    /// The notch island (W18), for the "Show Island" toggle.
    weak var island: TrackerIsland?

    init(runtime: TrackerRuntime, sink: TrackerStoreSink, db: HoursDB) {
        self.runtime = runtime; self.sink = sink; self.db = db
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        runtime.onChange = { [weak self] in self?.refreshIcon() }
        refreshIcon()
    }

    // MARK: - Icon

    private func refreshIcon() {
        let (name, label): (String, String) =
            if !runtime.isAccessibilityTrusted { ("circle.slash", "Hours: Accessibility permission missing") }
            else if sink.lastWriteFailed { ("circle.slash", "Hours: database write failing") }
            else if runtime.pausedUntilMs != nil { ("circle", "Hours: paused") }
            else if runtime.isTracking { ("circle.fill", "Hours: tracking") }
            else { ("circle", "Hours: idle") }
        guard label != shown else { return }
        shown = label
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = label
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if !runtime.isAccessibilityTrusted { menu.addItem(info("Accessibility permission missing")) }
        if sink.lastWriteFailed { menu.addItem(info("Last database write failed")) }
        let today: TrackerIslandToday?
        do { today = try TrackerIslandToday.load(db: db, nowMs: now) } catch {
            today = nil
            SupportLog.tracker.error("status menu query failed: \(String(describing: error), privacy: .public)")
        }
        if let today {
            menu.addItem(info("Today \(Self.hm(today.workMs)) work · \(Self.hm(today.trackedMs)) tracked"))
            menu.addItem(info(today.throughMs.map { "Tracked through \(Self.clock($0))" } ?? "Nothing tracked yet today"))
        } else {
            menu.addItem(info("Today's totals unavailable"))
        }
        menu.addItem(.separator())
        if let until = runtime.pausedUntilMs {
            menu.addItem(info("Paused until \(Self.clock(until))"))
            menu.addItem(action("Resume", #selector(resume)))
        }
        for (title, minutes) in [("Pause 15 min", 15), ("Pause 1 hour", 60)] {
            let i = action(title, #selector(pauseFor(_:)))
            i.tag = minutes
            menu.addItem(i)
        }
        menu.addItem(action("Pause until tomorrow", #selector(pauseUntilTomorrow)))
        menu.addItem(.separator())
        if let island {
            let show = action("Show Island", #selector(toggleIsland))
            show.state = island.style == .off ? .off : .on
            menu.addItem(show)
        }
        let open = action("Open Spells", #selector(openHours))
        open.isEnabled = Self.appURL() != nil
        menu.addItem(open)
        menu.addItem(action("Quit Tracker", #selector(quit)))
    }

    // MARK: - Actions

    @objc private func pauseFor(_ sender: NSMenuItem) { pause(minutes: sender.tag) }
    @objc private func pauseUntilTomorrow() { pauseUntilTomorrowNow() }
    @objc private func resume() { resumeTracking() }
    @objc private func openHours() { openHoursApp() }

    /// Last non-off style, so re-showing restores "right ear only".
    private var lastIslandStyle: TrackerIslandStyle = .both
    @objc private func toggleIsland() {
        guard let island else { return }
        if island.style == .off { island.setStyle(lastIslandStyle) } else { lastIslandStyle = island.style; island.setStyle(.off) }
    }

    // Shared with the island's buttons.

    func pause(minutes: Int) {
        setPause(Int64(Date().timeIntervalSince1970 * 1000) + Int64(minutes) * 60_000)
    }

    /// Next day start (04:00) — the app's day boundary, so "tomorrow" matches what the app calls a day.
    func pauseUntilTomorrowNow() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let day = LocalDate.containing(ms: now, in: .current, dayStartHour: Hours.defaultDayStartHour)
        setPause(day.dayInterval(in: .current, dayStartHour: Hours.defaultDayStartHour).upperBound)
    }

    func resumeTracking() { setPause(nil) }

    func openHoursApp() {
        guard let url = Self.appURL() else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func setPause(_ untilMs: Int64?) {
        do { try TrackerPauseSetting.save(SettingStore(db), untilMs: untilMs) } catch {
            // Still pause in memory: the user asked for it now; only restart-survival is lost.
            SupportLog.tracker.error("pause not persisted: \(String(describing: error), privacy: .public)")
        }
        runtime.pause(untilMs: untilMs)
        SupportLog.tracker.info("pause until \(untilMs.map { String($0) } ?? "resumed", privacy: .public)")
    }

    @objc private func quit() {
        runtime.stop()
        exit(0)
    }

    // MARK: - Helpers

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        i.target = self
        return i
    }

    /// The helper's containing Hours.app (…/Hours.app/Contents/Library/LoginItems/HoursSpell.app);
    /// an unbundled dev binary falls back to LaunchServices by bundle id.
    static func appURL(helper: URL = Bundle.main.bundleURL) -> URL? {
        var url = helper.deletingLastPathComponent()
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Hours.appBundleID)
    }

    static func hm(_ ms: Int64) -> String {
        let m = ms / 60_000
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    static func clock(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .omitted, time: .shortened)
    }
}
