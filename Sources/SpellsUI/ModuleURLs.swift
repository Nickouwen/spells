import AppKit
import ServiceManagement
import SwiftUI
import SpellsKit

/// `<scheme>://<verb>?k=v` from the launcher (or `open`): the verbs every module answers are `settings`,
/// `quit` and, later, `login-item?on=1|0`; a module adds its own (Scry: `meeting?path=`). Install before
/// `NSApplication.run()`; a URL the app was launched with arrives once launching finishes.
@MainActor public final class ModuleURLs: NSObject {
    private let handle: @MainActor (URL) -> Void
    private static var installed: ModuleURLs?

    private init(_ handle: @escaping @MainActor (URL) -> Void) { self.handle = handle }

    /// `quit` and `login-item?on=1|0` (with `settings`, the module's own file) are answered here; everything else
    /// goes to `handle` as (verb, query).
    public static func install(settings: SpellSettingsFile? = nil,
                               _ handle: @escaping @MainActor (_ verb: String, _ query: [String: String]) -> Void) {
        let h = ModuleURLs { url in
            let (verb, query) = parse(url)
            switch verb {
            case "quit": NSApp.terminate(nil)
            case "login-item" where settings != nil: ModuleLoginItem.set(query["on"] == "1", settings: settings!)
            default: handle(verb, query)
            }
        }
        installed = h
        NSAppleEventManager.shared().setEventHandler(h, andSelector: #selector(handleEvent(_:with:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// `scry://meeting?path=/x` → ("meeting", ["path": "/x"]). The verb is the host (or the first path piece).
    public static func parse(_ url: URL) -> (verb: String, query: [String: String]) {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let verb = c?.host ?? url.path.split(separator: "/").first.map(String.init) ?? ""
        let query = Dictionary((c?.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { _, b in b })
        return (verb, query)
    }

    /// `scheme://verb?k=v`, percent-encoding the values.
    public static func url(scheme: String, verb: String, query: [String: String] = [:]) -> URL {
        var c = URLComponents(); c.scheme = scheme; c.host = verb
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    /// The installed module app with that bundle ID (LaunchServices), or nil.
    public static func installed(_ bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// Delivers `scheme://verb?…` to the module with that bundle ID (launching it if needed), without relying on
    /// its scheme being registered. False when it isn't installed.
    @discardableResult
    public static func send(_ bundleID: String, scheme: String, verb: String, query: [String: String] = [:]) -> Bool {
        guard let app = installed(bundleID) else { return false }
        NSWorkspace.shared.open([url(scheme: scheme, verb: verb, query: query)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    @objc private func handleEvent(_ event: NSAppleEventDescriptor, with reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let url = URL(string: s) else { return }
        handle(url)
    }
}

/// One SwiftUI window of a menu-bar (accessory) module: created on first show, reused after close.
@MainActor public final class ModuleWindow {
    private var window: NSWindow?
    public init() {}

    public func show<V: View>(title: String, size: NSSize, minSize: NSSize? = nil, @ViewBuilder _ content: () -> V) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = title
            w.isReleasedWhenClosed = false
            if let minSize { w.contentMinSize = minSize }
            let host = NSHostingController(rootView: content())
            host.sizingOptions = []          // keep `size`; the view's minimums don't shrink the window
            w.contentViewController = host
            w.setContentSize(size)
            w.center()
            w.setFrameAutosaveName(title)
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A module's own launch-at-login registration (`SMAppService.mainApp`), mirrored into its settings file so the
/// launcher, which can't query another app's registration, can show it.
@MainActor public enum ModuleLoginItem {
    public static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    public static func set(_ on: Bool, settings: SpellSettingsFile) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            SupportLog.app.error("login item \(on ? "on" : "off") failed: \(error.localizedDescription, privacy: .public)")
        }
        sync(settings)
    }

    /// Call at launch too: the user may have changed it in System Settings → Login Items.
    public static func sync(_ settings: SpellSettingsFile) {
        try? settings.set(Spells.loginItemKey, isOn ? "1" : "0")
    }
}
