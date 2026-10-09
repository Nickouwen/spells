import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import Testing
import HoursCore
@testable import HoursUI

/// Runtime render of the EOD sheet → `$TMPDIR/hours-standup-{light,dark,empty}.png`.
/// `HOURS_STANDUP_HOME=<dir>` renders the standup stored in `<dir>/hours.db` for
/// `HOURS_STANDUP_DATE` (default 2026-10-05); otherwise a fixture body. Refuses the real home.
@MainActor
@Suite struct StandupRenderTests {
    static let env = ProcessInfo.processInfo.environment
    static let day = LocalDate(iso: env["HOURS_STANDUP_DATE"] ?? "2026-10-05")!

    @Test func renderSheet() async throws {
        let (db, stored) = try Self.source()
        #expect(!stored.body.isEmpty)
        for scheme in [ColorScheme.light, .dark] {
            try await render(StandupSheet(db: db, date: Self.day, preloaded: stored), scheme: scheme,
                             name: "hours-standup-\(scheme == .dark ? "dark" : "light")")
        }
        try await render(StandupSheet(db: db, date: Self.day.dayShift(1), preloaded: nil), scheme: .light, name: "hours-standup-empty")
    }

    static func source() throws -> (HoursDB, Standup) {
        if let home = env["HOURS_STANDUP_HOME"] {
            let url = URL(filePath: home, directoryHint: .isDirectory).appending(path: "hours.db")
            try #require(url.standardizedFileURL != SupportPaths.current(environment: [:]).db.standardizedFileURL)
            let db = try HoursDB.open(at: url, role: .app, notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
            return (db, try #require(try StandupStore(db).get(day)))
        }
        let db = try HoursDB.open(at: FileManager.default.temporaryDirectory.appending(path: "hours-standup-render/\(UUID().uuidString)/hours.db"),
                                  role: .app, notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
        let s = Standup(date: day, body: Self.sampleBody, generatedMs: 1_791_234_000_000, inputsSha256: String(repeating: "0", count: 64),
                        model: "claude-sonnet-5-5")
        return (db, s)
    }

    /// A representative standup body for the render (sections, a few lines each).
    static let sampleBody = """
    Example User - EOD October 5
    Worked On:
    Example data pipeline back online (new source for demo documents)
    Example API fixes: validation, pagination, duplicate detection
    Cut processing costs by skipping unchanged documents
    Still Work In Progress:
    Example dashboard parity with the prototype, close to sign-off
    Blockers:
    ExamplePortal still failing
    Carry-Forward:
    Document provenance for every data point
    Rescraper job scoping
    """

    /// Offscreen window + `cacheDisplay` (ImageRenderer draws TextEditor blank), as in SettingsRenderTests.
    func render(_ view: StandupSheet, scheme: ColorScheme, name: String) async throws {
        let size = NSSize(width: 640, height: 580)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try #require(rep.cgImage)
        #expect(image.width >= 640)
        let dir = Self.env["TMPDIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        print("Standup sheet (\(name)): \(url.path)")
    }
}
