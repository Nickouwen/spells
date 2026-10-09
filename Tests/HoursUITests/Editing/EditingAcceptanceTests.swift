import Foundation
import Testing
import GRDB
import HoursCore
@testable import HoursUI

/// 08's acceptance scenarios: each gesture → the exact drafts, then written through a temp store →
/// the expected effective spans. Raw: Safari (Writing) 09–10, Xcode (Coding) 10–11, Slack (Comms) 11–11:30.
@Suite @MainActor struct EditingAcceptanceTests {
    typealias F = EditFixture
    let writing = ClassifySeed.writing, coding = ClassifySeed.coding, comms = ClassifySeed.communication

    // 1. Trim Xcode's end to 10:40 → delete [10:40, 11:00); undo restores.
    @Test func trimEnd() throws {
        let f = try F()
        let before = try f.load()
        f.select(F.at(10), F.at(11))
        #expect(f.plan(.resize(.upper, to: F.at(10, 40)))?.drafts == [.delete(F.at(10, 40), F.at(11))])
        try #require(f.session.perform(.resize(.upper, to: F.at(10, 40))) != nil)
        let after = try f.refresh()
        #expect(editShape(after) == [[F.at(9), F.at(10), writing, nil], [F.at(10), F.at(10, 40), coding, nil],
                                     [F.at(11), F.at(11, 30), comms, nil]])
        #expect(editTotal(before) - editTotal(after) == 20 * 60_000)
        #expect(f.session.selection.ranges == [F.at(10)..<F.at(10, 40)])   // selection kept for chaining
        f.undo.undo()
        #expect(editShape(try f.refresh()) == editShape(before))
    }

    // 2. Drag the Safari|Xcode boundary to 10:10 → assign [10:00, 10:10) Safari's category; total unchanged.
    @Test func moveBoundary() throws {
        let f = try F()
        let before = try f.load()
        #expect(f.plan(.moveBoundary(from: F.at(10), to: F.at(10, 10)))?.drafts
                == [.assign(F.at(10), F.at(10, 10), categoryId: writing, projectId: nil)])
        f.session.perform(.moveBoundary(from: F.at(10), to: F.at(10, 10)))
        let after = try f.refresh()
        #expect(editShape(after) == [[F.at(9), F.at(10), writing, nil], [F.at(10), F.at(10, 10), writing, nil],
                                     [F.at(10, 10), F.at(11), coding, nil], [F.at(11), F.at(11, 30), comms, nil]])
        #expect(editTotal(after) == editTotal(before))
        // And the other way: back to 09:50 paints Xcode's category over Safari.
        #expect(EditPlanner.plan(.moveBoundary(from: F.at(10), to: F.at(9, 50)), selection: [], in: before)?.drafts
                == [.assign(F.at(9, 50), F.at(10), categoryId: coding, projectId: nil)])
    }

    // 3. Marquee 09:00–11:30, C = Coding → exactly one assign row; undo = one undo row; redo restores.
    @Test func bulkRecategorize() throws {
        let f = try F()
        let before = try f.load()
        f.select(F.at(9), F.at(11, 30))
        #expect(f.plan(.recategorize(coding))?.drafts == [.assign(F.at(9), F.at(11, 30), categoryId: coding, projectId: nil)])
        let g = try #require(f.session.perform(.recategorize(coding)))
        let edited = try f.refresh()
        #expect(try f.edits().map(\.op) == [.assign])
        #expect(edited.spans.allSatisfy { $0.categoryId == coding })
        #expect(f.undo.undoActionName == "Recategorize")

        f.undo.undo()
        let undone = try f.edits()
        #expect(undone.map(\.op) == [.assign, .undo] && undone.last?.target == g)
        #expect(editShape(try f.refresh()) == editShape(before))

        f.undo.redo()
        #expect(try f.edits().map(\.op) == [.assign, .undo, .undo])
        #expect(editShape(try f.refresh()) == editShape(edited))
    }

    // 4. Extend Slack's end to 11:45 over the gap → add [11:30, 11:45) with Slack's attributes.
    @Test func extendIntoGap() throws {
        let f = try F()
        f.select(F.at(11), F.at(11, 30))
        #expect(f.plan(.resize(.upper, to: F.at(11, 45)))?.drafts
                == [.add(F.at(11, 30), F.at(11, 45), label: "Communication (extended)", categoryId: comms, projectId: nil)])
        f.session.perform(.resize(.upper, to: F.at(11, 45)))
        let after = try f.refresh()
        #expect(editShape(after).suffix(2) == [[F.at(11), F.at(11, 30), comms, nil], [F.at(11, 30), F.at(11, 45), comms, nil]])
        #expect(after.spans.last?.span.source == .manual)
    }

    // 5. N over 11:30–12:00 "Call" / project 1, then 11:45–12:15 → later wins, no double counting.
    @Test func manualEntriesLaterWins() throws {
        let f = try F()
        let p: Int64 = 1
        #expect(f.plan(.add(F.at(11, 30)..<F.at(12), label: "Call", categoryId: nil, projectId: p))?.drafts
                == [.add(F.at(11, 30), F.at(12), label: "Call", categoryId: nil, projectId: p)])
        f.session.perform(.add(F.at(11, 30)..<F.at(12), label: "Call", categoryId: nil, projectId: p))
        var d = try f.refresh()
        #expect(d.spans.filter { $0.projectId == p }.reduce(0) { $0 + $1.span.durationMs } == 30 * 60_000)
        f.session.perform(.add(F.at(11, 45)..<F.at(12, 15), label: "Call 2", categoryId: nil, projectId: nil))
        d = try f.refresh()
        let manual = d.spans.filter { $0.span.source == .manual }
        #expect(manual.map { [$0.span.startMs, $0.span.endMs] } == [[F.at(11, 30), F.at(11, 45)], [F.at(11, 45), F.at(12, 15)]])
        #expect(manual.map(\.span.label) == ["Call", "Call 2"])
        #expect(manual.reduce(0) { $0 + $1.span.durationMs } == 45 * 60_000)
    }

    // 6. X on 09:00–09:30 → Personal; work drops 30 m; raw unchanged; chain verifies.
    @Test func markPersonal() throws {
        let f = try F()
        let before = try f.load()
        let rawBefore = try Store(f.db).rawSpans(from: F.bounds.lowerBound, to: F.bounds.upperBound)
        f.select(F.at(9), F.at(9, 30))
        #expect(f.plan(.markPersonal)?.drafts == [.assign(F.at(9), F.at(9, 30), categoryId: ClassifySeed.personal, projectId: nil)])
        f.session.perform(.markPersonal)
        let after = try f.refresh()
        #expect(before.metrics.workMs - after.metrics.workMs == 30 * 60_000)
        #expect(try Store(f.db).rawSpans(from: F.bounds.lowerBound, to: F.bounds.upperBound) == rawBefore)
        #expect(try ChainVerifier.verify(f.db).ok)
    }

    // 7. Backspace on 10:00–10:20 → delete; total −20 m; history "Deleted 10:00–10:20"; Revert restores.
    @Test func deleteAndRevertFromHistory() throws {
        let f = try F()
        let before = try f.load()
        f.select(F.at(10), F.at(10, 20))
        #expect(f.plan(.delete)?.drafts == [.delete(F.at(10), F.at(10, 20))])
        let g = try #require(f.session.perform(.delete))
        let after = try f.refresh()
        #expect(editTotal(before) - editTotal(after) == 20 * 60_000)
        let rows = f.session.historyRows(allDays: false)
        #expect(rows.map(\.summary) == ["Deleted 10:00–10:20"])
        #expect(rows.first?.deltaMs == -20 * 60_000 && rows.first?.status == .active)
        f.session.revert(group: g)
        #expect(editShape(try f.refresh()) == editShape(before))
        #expect(f.session.historyRows(allDays: false).first { $0.group == g }?.status == .reverted)
    }

    // 8. Cmd-Z after 3 edits undoes only the last; after "relaunch" the stack is empty but history Revert works.
    @Test func undoOnlyLastThenRelaunch() throws {
        let f = try F()
        f.select(F.at(9), F.at(9, 30));  let g1 = try #require(f.session.perform(.markPersonal))
        _ = try f.refresh()
        f.select(F.at(10), F.at(10, 20)); _ = try #require(f.session.perform(.delete))
        _ = try f.refresh()
        f.select(F.at(11), F.at(11, 30)); _ = try #require(f.session.perform(.recategorize(coding)))
        let three = try f.refresh()
        f.undo.undo()
        let afterUndo = try f.refresh()
        #expect(afterUndo.spans.last?.categoryId == comms)             // edit 3 gone
        #expect(editTotal(afterUndo) == editTotal(three))               // edit 2 (delete) still there
        #expect(afterUndo.spans.first?.categoryId == ClassifySeed.personal)

        let relaunched = EditSession(db: f.db)
        let um = UndoManager(); um.groupsByEvent = false
        relaunched.undoManager = um
        relaunched.update(afterUndo)
        #expect(!um.canUndo)
        relaunched.revert(group: g1)
        #expect(try f.load().spans.first?.categoryId == writing)
    }

    // 9. Live span: edits clamp to its start; nothing is written beyond the watermark.
    @Test func liveSpanClamp() throws {
        var f = try F()
        try SpanWriter(f.db).open(live: F.raw(F.at(11, 30), F.at(11, 30), "Xcode", bundle: "com.apple.dt.Xcode"))
        try SpanWriter(f.db).heartbeat(lastSeenMs: F.at(11, 50))
        f.now = Date(timeIntervalSince1970: Double(F.at(11, 55)) / 1000)
        let d = try f.refresh()
        #expect(EditPlanner.watermark(d) == F.at(11, 30))
        f.select(F.at(11), F.at(12))
        #expect(f.plan(.recategorize(coding))?.drafts == [.assign(F.at(11), F.at(11, 30), categoryId: coding, projectId: nil)])
        f.select(F.at(11), F.at(11, 30))
        #expect(f.plan(.resize(.upper, to: F.at(11, 45))) == nil)            // can't extend into the live span
        #expect(f.plan(.add(F.at(11, 40)..<F.at(11, 50), label: "x", categoryId: nil, projectId: nil)) == nil)
        #expect(f.plan(.moveBoundary(from: F.at(11, 30), to: F.at(11, 40))) == nil)
        f.select(F.at(11), F.at(12))
        f.session.perform(.delete)
        #expect(try f.edits().allSatisfy { $0.hiMs <= F.at(11, 30) })
    }

    // 10. A rule run after check 3 doesn't change the edited category (manual beats rules).
    @Test func rulesDontOverrideEdits() throws {
        let f = try F()
        f.select(F.at(9), F.at(11, 30))
        f.session.perform(.recategorize(coding))
        let rule = Rule(id: 9_999, origin: .user, priority: 100, bundleId: "com.apple.dt.Xcode",
                        categoryId: ClassifySeed.entertainment)
        #expect(try f.load(rules: ClassifySeed.rules + [rule]).spans.allSatisfy { $0.categoryId == coding })
    }

    // 11. Reason via the toast → note row on the group; durations and the edit's hash unchanged; chain verifies.
    @Test func noteNeverChangesDurations() throws {
        let f = try F()
        f.select(F.at(10), F.at(10, 20))
        let g = try #require(f.session.perform(.delete))
        let before = try f.refresh()
        let hash = try f.db.writer.read { try Data.fetchOne($0, sql: "SELECT hash FROM edit WHERE seq = ?", arguments: [g]) }
        #expect(f.session.toast?.group == g)
        f.session.toast?.reasonOpen = true
        let n = try #require(f.session.note(group: g, text: "tracker glitch"))
        let note = try #require(try f.edits().first { $0.seq == n })
        #expect(note.op == .note && note.target == g && note.payload == .note(text: "tracker glitch"))
        #expect(editShape(try f.refresh()) == editShape(before))
        #expect(try f.db.writer.read { try Data.fetchOne($0, sql: "SELECT hash FROM edit WHERE seq = ?", arguments: [g]) } == hash)
        #expect(f.session.toast?.reasonSaved == true)
        #expect(f.session.historyRows(allDays: false).first?.reasons == ["tracker glitch"])
        #expect(try ChainVerifier.verify(f.db).ok)
    }

    // Merge: earlier attrs over the later (one assign) + a manual fill over the ≤ 10 min gap.
    @Test func mergeFillsShortGap() throws {
        let f = try F(extra: [F.raw(F.at(11, 35), F.at(12), "Xcode", bundle: "com.apple.dt.Xcode")])
        f.select(F.at(11), F.at(12))
        #expect(f.plan(.merge)?.drafts == [.assign(F.at(11, 30), F.at(12), categoryId: comms, projectId: nil),
                                           .add(F.at(11, 30), F.at(11, 35), label: "Communication", categoryId: comms, projectId: nil)])
        f.session.perform(.merge)
        let d = try f.refresh()
        #expect(editShape(d).suffix(3) == [[F.at(11), F.at(11, 30), comms, nil], [F.at(11, 30), F.at(11, 35), comms, nil],
                                           [F.at(11, 35), F.at(12), comms, nil]])
        // A 20 min gap isn't filled.
        let g = try F(extra: [F.raw(F.at(11, 50), F.at(12), "Xcode", bundle: "com.apple.dt.Xcode")])
        g.select(F.at(11), F.at(12))
        #expect(g.plan(.merge)?.drafts == [.assign(F.at(11, 30), F.at(12), categoryId: comms, projectId: nil)])
    }

    // Project assign leaves the category alone (field-wise overlay).
    @Test func assignProjectKeepsCategory() throws {
        let f = try F()
        f.select(F.at(10), F.at(11))
        #expect(f.plan(.assignProject(6))?.drafts == [.assign(F.at(10), F.at(11), categoryId: nil, projectId: 6)])
        f.session.perform(.assignProject(6))
        let x = try #require(try f.refresh().spans.first { $0.span.appName == "Xcode" })
        #expect(x.categoryId == coding && x.projectId == 6)
        #expect(f.session.toast?.ruleLabel == "Xcode")
    }

    // Split writes nothing; it selects the right half.
    @Test func splitWritesNothing() throws {
        let f = try F()
        f.select(F.at(10), F.at(11))
        #expect(f.session.split(at: F.at(10, 30)))
        #expect(f.session.selection.ranges == [F.at(10, 30)..<F.at(11)])
        #expect(try f.edits().isEmpty)
        #expect(!f.session.split(at: F.at(9)))
    }

    // Trim on the start edge and the 1 s floor.
    @Test func trimStartAndMinimum() throws {
        let f = try F()
        f.select(F.at(10), F.at(11))
        #expect(f.plan(.resize(.lower, to: F.at(10, 15)))?.drafts == [.delete(F.at(10), F.at(10, 15))])
        #expect(f.plan(.resize(.upper, to: F.at(9)))?.drafts == [.delete(F.at(10) + 1_000, F.at(11))])
        // Dragging Xcode's start outward over Safari moves the shared boundary instead.
        #expect(f.plan(.resize(.lower, to: F.at(9, 45)))?.drafts == [.assign(F.at(9, 45), F.at(10), categoryId: coding, projectId: nil)])
    }
}
