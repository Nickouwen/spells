import Foundation
import AppKit
import SwiftUI
import HoursCore
@testable import HoursUI

/// 08's acceptance day: Safari (docs.google.com → Writing) 09:00–10:00, Xcode (Coding) 10:00–11:00,
/// Slack (Communication) 11:00–11:30, then a gap. UTC, 2026-10-01 (a past day: nothing is live).
@MainActor
struct EditFixture {
    static let day = LocalDate(year: 2026, month: 10, day: 1)
    static let tz = TimeZone(identifier: "UTC")!
    static let bounds = day.dayInterval(in: tz)
    /// Local clock time on the fixture day.
    static func at(_ h: Int, _ m: Int = 0) -> Int64 {
        bounds.lowerBound + Int64((h - Hours.defaultDayStartHour) * 60 + m) * 60_000
    }

    let db: HoursDB
    let session: EditSession
    let undo: UndoManager
    var now: Date

    /// `extra` raw spans are appended after the three acceptance spans.
    init(extra: [RawSpan] = [], now: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws {
        db = try HoursDB.open(at: FileManager.default.temporaryDirectory
            .appending(path: "hours-edit-tests/\(UUID().uuidString)/hours.db"),
                              role: .app, notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
        let w = SpanWriter(db)
        for s in Self.acceptanceRaw + extra { _ = try w.append(s) }
        undo = UndoManager()
        undo.groupsByEvent = false   // no run loop in tests; the session opens its own group per gesture
        session = EditSession(db: db)
        session.undoManager = undo
        self.now = now
        session.update(try load())
    }

    static var acceptanceRaw: [RawSpan] {
        [raw(at(9), at(10), "Safari", bundle: "com.apple.Safari", url: "https://docs.google.com/document/d/1"),
         raw(at(10), at(11), "Xcode", bundle: "com.apple.dt.Xcode"),
         raw(at(11), at(11, 30), "Slack", bundle: "com.tinyspeck.slackmacgap")]
    }

    static func raw(_ lo: Int64, _ hi: Int64, _ app: String, bundle: String, url: String? = nil,
                    kind: SpanKind = .active) -> RawSpan {
        RawSpan(seq: 0, startMs: lo, endMs: hi, tzId: "UTC", tzOffsetS: 0, kind: kind, bundleId: bundle,
                appName: app, title: nil, url: url)
    }

    func load(rules: [Rule] = ClassifySeed.rules) throws -> DayData {
        let classifier = Classifier(categories: ClassifySeed.categories, rules: rules, projects: ClassifySeed.projects)
        return try DayData.load(store: Store(db), classifier: classifier, categories: ClassifySeed.categories,
                                projects: ClassifySeed.projects, day: Self.day, goal: nil, now: now, timeZone: Self.tz)
    }

    /// Reload the day into the session (what the shell does on the change feed).
    @discardableResult
    func refresh() throws -> DayData {
        let d = try load()
        session.update(d)
        return d
    }

    func select(_ lo: Int64, _ hi: Int64) { session.selection.set([lo..<hi]) }

    func plan(_ g: EditGesture) -> EditPlan? {
        EditPlanner.plan(g, selection: session.selection.ranges, in: session.data!)
    }

    func edits() throws -> [Edit] { try Store(db).allEdits() }
}

/// (start, end, category, project) of every span — what the acceptance checks pin.
func editShape(_ d: DayData) -> [[Int64?]] {
    d.spans.map { [$0.span.startMs, $0.span.endMs, $0.categoryId, $0.projectId] }
}

func editTotal(_ d: DayData) -> Int64 { d.spans.reduce(0) { $0 + $1.span.durationMs } }

/// Renders through a real offscreen window so AppKit-backed controls (text fields, pickers) draw too.
@MainActor
enum EditRender {
    static func png<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, name: String) throws -> String {
        let root = view.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        win.contentView = nil
        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("hours-edit-\(name).png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url.path
    }
}
