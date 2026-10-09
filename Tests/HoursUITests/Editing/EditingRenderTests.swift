import Foundation
import SwiftUI
import Testing
import HoursCore
@testable import HoursUI

/// Runtime renders of the editing UI → `$TMPDIR/hours-edit-*.png`, from a real temp store
/// (DemoData day, edits written through the session):
/// - `selection-{light,dark}`: one range selected, inspector open, toast after the last edit
/// - `picker-{light,dark}`: two ranges (Cmd-click), the inspector's category picker open — the
///   context menu's Category ▸ list as inspector state
/// - `history-light`: the edit history sheet
@Suite(.serialized) @MainActor struct EditingRenderTests {
    static let day = LocalDate(year: 2026, month: 10, day: 1)
    static let tz = TimeZone(identifier: "America/Vancouver")!
    static let size = CGSize(width: 1600, height: 1000)

    static func at(_ h: Int, _ m: Int = 0) -> Int64 {
        day.dayInterval(in: tz).lowerBound + Int64((h - Hours.defaultDayStartHour) * 60 + m) * 60_000
    }

    /// Temp store with the demo day and a few edits; returns the session (fed with the edited day).
    static func scene() throws -> EditSession {
        let db = try HoursDB.open(at: FileManager.default.temporaryDirectory
            .appending(path: "hours-edit-render/\(UUID().uuidString)/hours.db"),
                                  role: .app, notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
        for s in DemoData.spans(from: day, through: day, tzId: tz.identifier) { _ = try SpanWriter(db).append(s) }
        let session = EditSession(db: db)
        let um = UndoManager(); um.groupsByEvent = false
        session.undoManager = um
        let load = {
            session.update(try DayData.load(store: Store(db), classifier: Classifier(categories: ClassifySeed.categories,
                rules: ClassifySeed.rules, projects: ClassifySeed.projects), categories: ClassifySeed.categories,
                projects: ClassifySeed.projects, day: day, goal: Goal(dailyWorkMs: 7 * 3_600_000),
                now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: tz))
        }
        try load()
        session.selection.set([at(12, 30)..<at(12, 55)]); session.perform(.markPersonal); try load()
        session.selection.set([at(17, 30)..<at(18, 15)])
        session.perform(.add(at(17, 30)..<at(18, 15), label: "Client call", categoryId: ClassifySeed.meetings, projectId: 2))
        try load()
        // Select a tracked span mid-morning and recategorize it (leaves the toast up).
        let data = try #require(session.data)
        let s = try #require(data.spans.first { $0.span.startMs >= at(10, 30) && $0.span.kind == .active && $0.span.durationMs >= 15 * 60_000 }).span
        session.selection.set([s.startMs..<s.endMs])
        session.perform(.assignProject(6))
        try load()
        session.inspectorVisible = true
        return session
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func selectionAndInspector(_ scheme: ColorScheme) throws {
        let session = try Self.scene()
        let data = try #require(session.data)
        let path = try EditRender.png(EditableDayView(data: data, session: session, scrollable: false),
                                      size: Self.size, scheme: scheme, name: "selection-\(scheme == .dark ? "dark" : "light")")
        print("EditRender: \(path)")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func categoryPickerState(_ scheme: ColorScheme) throws {
        let session = try Self.scene()
        let data = try #require(session.data)
        let a = try #require(data.spans.first { $0.span.startMs >= Self.at(9) && $0.span.kind == .active }).span
        let b = try #require(data.spans.first { $0.span.startMs >= Self.at(14) && $0.span.kind == .active }).span
        session.selection.set([a.startMs..<a.endMs, b.startMs..<b.endMs])
        session.toast = nil
        session.picker = .category
        let path = try EditRender.png(EditableDayView(data: data, session: session, scrollable: false),
                                      size: Self.size, scheme: scheme, name: "picker-\(scheme == .dark ? "dark" : "light")")
        print("EditRender: \(path)")
    }

    @Test func historySheet() throws {
        let session = try Self.scene()
        let path = try EditRender.png(EditHistoryView(session: session), size: CGSize(width: 760, height: 420),
                                      scheme: .light, name: "history-light")
        print("EditRender: \(path)")
    }
}
