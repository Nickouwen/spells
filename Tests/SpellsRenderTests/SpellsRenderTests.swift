import AppKit
import SwiftUI
import Testing
import RewindCore
import ScryCore
import SpellsKit
import SpellsUI
import IncantUI
import ScryUI
import TransmuteUI
import WardUI
@testable import Incant
@testable import RewindUI
@testable import Scry
@testable import Spells

/// Screenshots of each module's main view and settings page (as the hub shows them) and the two overlays, light and dark, against
/// demo data in a throwaway `SPELLS_HOME`. For design review, not assertions:
///
///     SPELLS_RENDER_DIR=/tmp/spells-ui swift test --filter SpellsRenderTests
///
/// Never touches the real support folder: `SPELLS_HOME` is set before anything reads it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SPELLS_RENDER_DIR"] != nil), .serialized)
@MainActor struct SpellsRenderTests {
    static let out = URL(filePath: ProcessInfo.processInfo.environment["SPELLS_RENDER_DIR"] ?? NSTemporaryDirectory(),
                         directoryHint: .isDirectory)

    @Test func renderEverything() throws {
        let home = try Fixture.make()
        setenv("SPELLS_HOME", home.path, 1)
        // Fake keys via the environment (read before the Keychain): a Keychain read from this test binary
        // pops an access prompt and the run waits on it.
        setenv("ELEVENLABS_API_KEY", "render-fixture", 1)
        setenv("CEREBRAS_API_KEY", "render-fixture", 1)
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)

        let hub = HubModel()
        hub.start()
        settle(2)
        hub.rewind?.setVisible(true)
        hub.ward?.start()
        hub.transmute?.start()
        settle(1.5)

        // Each module's own view, as the hub's detail pane shows it (the split view's sidebar is a
        // window-server material that no offscreen capture draws; Rewind's views come from RewindUITests).
        let size = CGSize(width: 1060, height: 820)
        let notes = ScryNotes.load(Self.scryRoot(home))
        var shots: [(String, AnyView)] = [("modules", AnyView(LauncherView(model: hub.launcher)))]
        if let m = hub.meetings { shots.append(("scry-meetings", AnyView(MeetingsView(model: m, notes: notes, openSettings: {})))) }
        if let t = hub.transmute { shots.append(("transmute-invoices", AnyView(InvoicesView(model: t, openSettings: {})))) }
        if let w = hub.ward { shots.append(("ward-network", AnyView(WardView(model: w, openSettings: {})))) }
        shots.append(("settings-incant", AnyView(IncantSettingsView(permissions: nil))))
        shots.append(("settings-scry", AnyView(ScrySettingsView(onSaved: {}))))
        if let t = hub.transmute { shots.append(("settings-transmute", AnyView(TransmuteSettingsView(onSaved: { t.reloadSettings() })))) }
        if let w = hub.ward { shots.append(("settings-ward", AnyView(WardSettingsView(model: w)))) }

        let only = ProcessInfo.processInfo.environment["SPELLS_RENDER_ONLY"]
        for scheme in [ColorScheme.light, .dark] {
            for (name, view) in shots where only == nil || name.hasPrefix(only!) {
                try write(view.background(Theme.canvas), size: size, scheme: scheme, name: name)
            }
            try write(scryLive(), size: CGSize(width: 380, height: 560), scheme: scheme, name: "overlay-scry-live")
        }
        try incantIndicator()
        print("renders: \(Self.out.path)")
    }

    static func scryRoot(_ home: URL) -> URL { home.appending(path: "notes", directoryHint: .isDirectory) }

    // MARK: Overlays

    private func scryLive() -> some View {
        let m = ScryLiveModel(app: "Google Meet", startedAt: Date().addingTimeInterval(-14 * 60))
        m.liveSince = Date().addingTimeInterval(-14 * 60)
        m.level = 0.55
        m.segments = Fixture.segments
        m.partial = ["Alex": "and the second batch can go out once the"]
        m.notes = "Ask about the return address"
        return ScryLiveView(model: m, onCatchUp: {}, onNotesChanged: {}, onStop: {}, onDiscard: {})
    }

    /// The listening indicator in each state, on a menu-bar-grey strip like the top of the screen.
    private func incantIndicator() throws {
        let states: [(String, (IncantIndicatorView) -> Void)] = [
            ("listening", { v in for l in [0.2, 0.6, 0.9, 0.4, 0.7] { v.push(l) } }),
            ("handsfree", { v in v.handsFree = true; for l in [0.3, 0.5, 0.2, 0.8, 0.5] { v.push(l) } }),
            ("fixing", { v in v.mode = .fixing; v.phase = 0.3 }),
            ("error", { v in v.mode = .error }),
        ]
        for (name, setUp) in states {
            let strip = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 48))
            strip.wantsLayer = true
            strip.layer?.backgroundColor = NSColor(white: 0.82, alpha: 1).cgColor
            let v = IncantIndicatorView(frame: NSRect(x: 68, y: 16, width: 64, height: 32))
            v.reset()
            setUp(v)
            strip.addSubview(v)
            let win = NSWindow(contentRect: strip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.contentView = strip
            let rep = strip.bitmapImageRepForCachingDisplay(in: strip.bounds)!
            strip.cacheDisplay(in: strip.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: Self.out.appending(path: "overlay-incant-\(name).png"))
        }
    }

    // MARK: Plumbing

    private func settle(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// Through a real window, ordered in but placed off every screen so lists and text fields lay out and draw;
    /// captured from its layer tree (no Screen Recording permission needed).
    private func write<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, name: String) throws {
        // No display link fires off-screen, so a fade-in would stay at 0 opacity: render with animations off.
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        win.backgroundColor = scheme == .dark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.98, alpha: 1)
        win.contentView = host
        win.orderFrontRegardless()
        settle(name.hasPrefix("transmute") ? 4 : 1.0)   // Transmute prices the period asynchronously
        host.layoutSubtreeIfNeeded()
        host.display()
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(win.backgroundColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        if let layer = win.contentView?.superview?.layer ?? host.layer {
            layer.render(in: ctx)
        }
        win.orderOut(nil)
        win.contentView = nil
        let suffix = scheme == .dark ? "dark" : "light"
        try rep.representation(using: .png, properties: [:])!.write(to: Self.out.appending(path: "\(name)-\(suffix).png"))
    }
}

/// Demo data only: invented people, hours from `ExportDemoSeed`, a made-up network snapshot.
enum Fixture {
    static let segments = [
        ScrySegment(speaker: "Alex", start: 2, end: 8, text: "Thanks for jumping on. Can we go over the project launch?"),
        ScrySegment(speaker: "Sam", start: 9, end: 16, text: "Sure. The mail is built, but it stays off until we have a return address."),
        ScrySegment(speaker: "Alex", start: 17, end: 22, text: "Okay. I will send you the return address by Friday."),
        ScrySegment(speaker: "Jordan", start: 23, end: 29, text: "And I can review the first batch of letters before they print."),
    ]

    static func make() throws -> URL {
        let home = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "spells-render-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let paths = SupportPaths(home: home, logs: home.appending(path: "logs", directoryHint: .isDirectory))
        try paths.createDirectories()

        let tz = TimeZone.current
        let today = LocalDate.containing(ms: Int64(Date().timeIntervalSince1970 * 1000), in: tz)
        let db = try RewindDB.open(at: paths.db, role: .app)
        _ = try ExportDemoSeed.run(db: db, days: 21, today: today, tzId: tz.identifier)
        try SettingStore(db).set("standup_name", "Sam Rivera")

        let notes = home.appending(path: "notes", directoryHint: .isDirectory)
        try SpellSettingsFile(spell: "scry", paths: paths).replace(["scry_root": notes.path, "scry_auto_record": "1"])
        try SpellSettingsFile(spell: "incant", paths: paths).replace(["incant_keyterms": "Example\nRewind\nScry", "incant_stream": "1"])
        try SpellSettingsFile(spell: "transmute", paths: paths).replace([
            "from_name": "Sam Rivera", "from_email": "sam@example.com", "client_name": "Example Co",
            "rate": "85.00", "next_number": "12", "folder": home.appending(path: "invoices").path])
        try meetings(notes)

        let ward = home.appending(path: "ward", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ward, withIntermediateDirectories: true)
        let now = Int(Date().timeIntervalSince1970)
        try """
            files\t42
            bytes\t912000000
            first\t\(now - 6 * 86400)
            last\t\(now - 120)
            window\t
            section\tdst
            1840\t17.253.144.10
            960\t140.82.112.4
            412\t104.18.32.7
            section\tdns
            512\tapi.example.com
            300\tgithub.com
            122\tcdn.example.net
            section\tsni
            480\tapi.example.com
            240\tgithub.com
            section\tioc
            """.write(to: ward.appending(path: "snapshot.tsv"), atomically: true, encoding: .utf8)
        return home
    }

    private static func meetings(_ root: URL) throws {
        let specs: [(Double, Double, String, String?, [String])] = [
            (-26, 0.75, "Project launch review", "Google Meet", ["Sam", "Alex", "Jordan"]),
            (-50, 0.5, "Weekly planning", "Zoom", ["Sam", "Alex"]),
        ]
        for (hoursAgo, length, title, app, people) in specs {
            let start = Date().addingTimeInterval(hoursAgo * 3600)
            let summary = ScrySummary(
                title: title,
                overview: "Went through the launch checklist, agreed the mail stays off until the return address arrives, and set the review of the first letters.",
                decisions: ["Mail stays off until the return address is in"],
                keyDates: ["Friday: return address due"],
                actionItems: [.init(owner: "Alex", task: "Send the return address", due: "Friday"),
                              .init(owner: "Sam", task: "Turn mail on once the address is in"),
                              .init(owner: "Jordan", task: "Review the first ten letters")],
                openQuestions: ["Who signs off the second batch?"])
            let note = ScryNote(meta: .init(startedAt: start, endedAt: start.addingTimeInterval(length * 3600), app: app,
                                            participants: people, speakers: [:]),
                                summary: summary, userNotes: "Ask about the return address", segments: segments)
            let url = ScryNote.fileURL(root: root, startedAt: start, title: title)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try note.markdown().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
