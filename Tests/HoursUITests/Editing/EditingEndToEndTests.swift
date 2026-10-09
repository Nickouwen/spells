import Foundation
import Testing
import HoursCore
@testable import HoursUI

/// Runtime check: a `seed-demo` store (the same `ExportDemoSeed` path `spellsctl seed-demo` runs), one
/// gesture of each kind through `EditSession`, undo + redo, a note — then the chain still verifies.
/// `HOURS_EDIT_E2E_DB=<path>/hours.db` points it at a DB seeded by `spellsctl seed-demo` instead of
/// seeding its own temp copy. It never opens the real Application Support database.
@Suite @MainActor struct EditingEndToEndTests {
    @Test func everyGestureKeepsTheChainValid() throws {
        let tz = TimeZone.current
        let url: URL
        if let p = ProcessInfo.processInfo.environment["HOURS_EDIT_E2E_DB"], !p.isEmpty {
            url = URL(fileURLWithPath: p)
            #expect(!url.path.hasPrefix(HoursDB.defaultURL.deletingLastPathComponent().path))
        } else {
            url = FileManager.default.temporaryDirectory.appending(path: "hours-edit-e2e/\(UUID().uuidString)/hours.db")
        }
        let db = try HoursDB.open(at: url, role: .app, notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
        let today = LocalDate.containing(ms: Int64(Date().timeIntervalSince1970 * 1000), in: tz)
        if ProcessInfo.processInfo.environment["HOURS_EDIT_E2E_DB"] == nil {
            _ = try ExportDemoSeed.run(db: db, days: 5, today: today, tzId: tz.identifier)
        }
        let config = ConfigStore(db)
        let categories = try config.categories(), projects = try config.projects()
        let classifier = Classifier(categories: categories, rules: try config.rules(), projects: projects)
        let load = { (day: LocalDate) in
            try DayData.load(store: Store(db), classifier: classifier, categories: categories, projects: projects,
                             day: day, goal: nil, timeZone: tz)
        }
        // The most recent seeded (past) day with activity.
        var day = today.dayShift(-1)
        while try load(day).isEmpty, day > today.dayShift(-6) { day = day.dayShift(-1) }
        var data = try load(day)
        try #require(!data.isEmpty)

        let session = EditSession(db: db)
        let um = UndoManager(); um.groupsByEvent = false
        session.undoManager = um
        session.update(data)
        let refresh = { data = try load(day); session.update(data) }
        let active = { data.spans.filter { $0.span.kind == .active && $0.span.source == .tracked } }
        let select = { (s: EffectiveSpan) in session.selection.set([s.startMs..<s.endMs]) }
        var groups: [Int64] = []
        func did(_ g: Int64?, _ what: String) throws {
            groups.append(try #require(g, "\(what) wrote nothing"))
            try refresh()
        }

        let spans = active()
        try #require(spans.count >= 12)
        select(spans[0].span); try did(session.perform(.recategorize(ClassifySeed.research)), "recategorize")
        select(spans[1].span); try did(session.perform(.assignProject(projects[0].id)), "assign project")
        select(spans[2].span); try did(session.perform(.markPersonal), "mark personal")
        select(spans[3].span); try did(session.perform(.delete), "delete")
        // Trim: pull the end of a long span in by a third.
        let long = try #require(active().first { $0.span.durationMs >= 6 * 60_000 }).span
        select(long); try did(session.perform(.resize(.upper, to: long.endMs - long.durationMs / 3)), "trim")
        // Move a boundary between touching segments with different categories.
        let pair = try #require(zip(active(), active().dropFirst()).first {
            $0.span.endMs == $1.span.startMs && $0.categoryId != $1.categoryId && $0.categoryId != nil
                && $1.span.durationMs > 2 * 60_000
        })
        try did(session.perform(.moveBoundary(from: pair.0.span.endMs, to: pair.0.span.endMs + 60_000)), "move boundary")
        // Merge two touching segments with different attributes.
        let m = try #require(zip(active(), active().dropFirst()).first {
            $0.span.endMs == $1.span.startMs && $0.categoryId != nil && $0.categoryId != $1.categoryId
        })
        session.selection.set([m.0.span.startMs..<m.1.span.endMs]); try did(session.perform(.merge), "merge")
        // Extend the day's last span into the empty evening.
        let last = try #require(active().last).span
        select(last); try did(session.perform(.resize(.upper, to: last.endMs + 10 * 60_000)), "extend")
        // Manual entry (replaces what's beneath).
        try did(session.perform(.add(last.endMs + 20 * 60_000..<last.endMs + 50 * 60_000, label: "Call",
                                     categoryId: ClassifySeed.meetings, projectId: nil)), "add")
        // Split writes nothing; a recategorize of the right half does.
        let s = active()[6].span
        select(s)
        #expect(session.split(at: s.startMs + s.durationMs / 2))
        try did(session.perform(.recategorize(ClassifySeed.writing)), "recategorize right half")
        // Bulk: two disjoint ranges in one group.
        session.selection.set([active()[8].span.startMs..<active()[8].span.endMs, active()[10].span.startMs..<active()[10].span.endMs])
        try did(session.perform(.markPersonal), "bulk")
        #expect(try Store(db).allEdits().filter { $0.grp == groups.last }.count == 2)

        let beforeUndo = data
        um.undo(); try refresh()
        #expect(data != beforeUndo)
        um.redo(); try refresh()
        #expect(data.spans == beforeUndo.spans)
        session.note(group: groups[3], text: "tracker glitch")

        let result = try ChainVerifier.verify(db)
        #expect(result.ok, "chain broke at \(result.firstBadSeq ?? -1): \(result.reason ?? "")")
        let edits = try Store(db).allEdits()
        #expect(Set(edits.map(\.op)) == [.assign, .delete, .add, .undo, .note])
        print("EditEndToEnd: \(day) · \(edits.count) edit rows in \(Set(edits.map(\.grp)).count) groups · chain ok (\(result.rows) rows) · \(url.path)")
    }
}
