import Foundation
import Testing
import HoursCore
@testable import HoursUI

/// Selection, snapping, time parsing, undo/redo bookkeeping, history rows, rule handoff.
@Suite @MainActor struct EditingModelTests {
    typealias F = EditFixture

    @Test func selectionModes() {
        var s = EditSelection()
        s.select(10..<20, mode: .replace)
        s.select(40..<50, mode: .toggle)
        #expect(s.ranges == [10..<20, 40..<50])
        s.select(40..<50, mode: .toggle)
        #expect(s.ranges == [10..<20])
        s.select(30..<35, mode: .extend)
        #expect(s.ranges == [10..<35])
        s.select(30..<60, mode: .toggle)                     // overlapping adds merge
        #expect(s.ranges == [10..<60])
        #expect(EditSelection([50..<60, 10..<20, 15..<30]).ranges == [10..<30, 50..<60])
        #expect(s.split(at: 25)?.ranges == [25..<60])
        #expect(s.split(at: 10) == nil)
    }

    @Test func clickThroughTheDayHook() throws {
        let f = try F()
        f.session.click(F.at(10)...F.at(11), mode: .replace)
        f.session.click(F.at(11)...F.at(11, 30), mode: .toggle)
        #expect(f.session.selection.ranges == [F.at(10)..<F.at(11, 30)])   // touching ranges merge
        f.session.click(F.at(9)...F.at(10), mode: .extend)
        #expect(f.session.selection.ranges == [F.at(9)..<F.at(11, 30)])
        f.session.click(nil, mode: .extend)                                  // Shift-click on empty: no-op
        #expect(!f.session.selection.isEmpty)
        f.session.click(nil, mode: .replace)
        #expect(f.session.selection.isEmpty)
        f.session.selectDay()
        #expect(f.session.selection.ranges == [F.at(9)..<F.at(11, 30)])
    }

    @Test func snapping() {
        let utc = TimeZone(identifier: "UTC")!
        // 30 s/pt → 6 pt = 3 min tolerance; grid = 5 min (1 min is only 2 pt).
        #expect(EditSnap.gridMs(msPerPoint: 30_000) == 5 * 60_000)
        #expect(EditSnap.gridMs(msPerPoint: 5_000) == 60_000)
        #expect(EditSnap.gridMs(msPerPoint: 200_000) == 15 * 60_000)
        let base: Int64 = 1_790_000_000_000 - 1_790_000_000_000 % 3_600_000   // an exact UTC hour
        #expect(EditSnap.snap(base + 61_000, targets: [base + 2 * 60_000], msPerPoint: 30_000, timeZone: utc) == base + 2 * 60_000)
        #expect(EditSnap.snap(base + 7 * 60_000 + 40_000, targets: [base + 20 * 60_000], msPerPoint: 30_000, timeZone: utc)
                == base + 10 * 60_000)                                         // grid: 7:40 → 10:00 (nearest 5 min)
        #expect(EditSnap.snap(base + 7 * 60_000, targets: [], msPerPoint: 30_000, timeZone: utc) == base + 5 * 60_000)
        // Grid aligns to local time (+05:30): 10:02 local → 10:00 local.
        let ist = TimeZone(identifier: "Asia/Kolkata")!
        let localTen = base - 5 * 3_600_000 - 30 * 60_000 + 10 * 3_600_000   // any instant that is hh:00 in IST
        #expect(EditSnap.snap(localTen + 2 * 60_000, targets: [], msPerPoint: 30_000, timeZone: ist) == localTen)
    }

    @Test func timeFieldParsing() {
        #expect(EditTime.parse("10:40", bounds: F.bounds, timeZone: F.tz) == F.at(10, 40))
        #expect(EditTime.parse(" 04:00 ", bounds: F.bounds, timeZone: F.tz) == F.bounds.lowerBound)
        #expect(EditTime.parse("01:30", bounds: F.bounds, timeZone: F.tz) == F.at(25, 30))   // after midnight = same day
        #expect(EditTime.parse("25:00", bounds: F.bounds, timeZone: F.tz) == nil)
        #expect(EditTime.parse("10.40", bounds: F.bounds, timeZone: F.tz) == nil)
    }

    @Test func inspectorTimeFieldTrims() throws {
        let f = try F()
        f.select(F.at(10), F.at(11))
        #expect(f.session.setEdge(.upper, text: "10:40"))
        #expect(try f.edits().map(\.payload) == [.delete])
        #expect(!f.session.setEdge(.upper, text: "nope"))
    }

    /// Undo → redo → undo → redo: each step reverts the previous step's group; effective spans alternate exactly.
    @Test func undoRedoRoundTrip() throws {
        let f = try F()
        let original = try f.load()
        f.select(F.at(9), F.at(10, 30))
        f.session.perform(.markPersonal)
        let edited = try f.refresh()
        for _ in 0..<2 {
            f.undo.undo()
            #expect(try f.load() == original)
            f.undo.redo()
            #expect(try f.load() == edited)
        }
        let edits = try f.edits()
        #expect(edits.map(\.op) == [.assign, .undo, .undo, .undo, .undo])
        // Each undo targets the group right before it.
        #expect(zip(edits.dropFirst(), edits).allSatisfy { $0.target == $1.grp })
        #expect(try ChainVerifier.verify(f.db).ok)
    }

    /// Commit flashes the hull of what it edited; undo flashes the same range under a new id.
    @Test func editFlashOnCommitAndUndo() throws {
        let f = try F()
        #expect(f.session.flash == nil)
        f.session.selection.set([F.at(9, 30)..<F.at(9, 45), F.at(10, 15)..<F.at(10, 30)])
        f.session.perform(.markPersonal)
        let commit = try #require(f.session.flash)
        #expect(commit.range == F.at(9, 30)..<F.at(10, 30))   // hull of both drafts
        f.undo.undo()
        let undo = try #require(f.session.flash)
        #expect(undo.range == commit.range)
        #expect(undo.id != commit.id)
        f.undo.redo()                                          // redo = undo of the undo group: same range again
        #expect(f.session.flash?.range == commit.range)
        #expect(f.session.flash?.id != undo.id)
    }

    /// A new edit after an undo clears redo; the toast's Undo uses the stack.
    @Test func newEditClearsRedoAndToastUndo() throws {
        let f = try F()
        f.select(F.at(10), F.at(10, 20)); f.session.perform(.delete)
        f.undo.undo()
        #expect(f.undo.canRedo)
        _ = try f.refresh()
        f.select(F.at(11), F.at(11, 30)); f.session.perform(.markPersonal)
        #expect(!f.undo.canRedo)
        f.session.undoToast()
        #expect(f.session.toast == nil)
        #expect(try f.load().spans.last?.categoryId == ClassifySeed.communication)
    }

    @Test func historyRowsStatusAndDelta() throws {
        let f = try F()
        f.select(F.at(9), F.at(9, 30)); let g0 = try #require(f.session.perform(.recategorize(ClassifySeed.coding)))
        f.select(F.at(10), F.at(10, 20)); let g1 = try #require(f.session.perform(.delete))
        f.select(F.at(10), F.at(10, 30)); let g2 = try #require(f.session.perform(.delete))
        f.select(F.at(11, 30), F.at(12))
        let g3 = try #require(f.session.perform(.add(F.at(11, 30)..<F.at(12), label: "Call", categoryId: nil, projectId: 1)))
        f.undo.undo()   // reverts g3
        let rows = f.session.historyRows(allDays: false)
        let byGroup = Dictionary(uniqueKeysWithValues: rows.map { ($0.group, $0) })
        #expect(byGroup[g0]?.summary == "Recategorized 09:00–09:30 → Coding")
        #expect(byGroup[g0]?.status == .active && byGroup[g0]?.deltaMs == 0)
        #expect(byGroup[g1]?.status == .noEffect)           // fully covered by the later, wider delete
        #expect(byGroup[g2]?.status == .active && byGroup[g2]?.deltaMs == -10 * 60_000)
        #expect(byGroup[g3]?.status == .reverted && byGroup[g3]?.deltaMs == nil)
        #expect(byGroup[g3]?.summary == "Added “Call” 11:30–12:00")
        let undoRow = try #require(rows.first)              // newest first
        #expect(undoRow.target == g3 && undoRow.summary == "Undo: Added “Call” 11:30–12:00")
        #expect(undoRow.deltaMs == -30 * 60_000)
    }

    @Test func alwaysForCreatesRule() throws {
        let f = try F()
        // The rule's category FK needs a category row (this temp DB has no seed config).
        _ = try ConfigStore(f.db).insert(ClassifySeed.categories.first { $0.id == ClassifySeed.research }!)
        f.select(F.at(9), F.at(10))
        f.session.perform(.recategorize(ClassifySeed.research))
        #expect(f.session.toast?.ruleLabel == "docs.google.com")
        let rule = try #require(f.session.saveToastRule())
        #expect(rule.host == "docs.google.com" && rule.categoryId == ClassifySeed.research && rule.origin == .user)
        #expect(try ConfigStore(f.db).rules().contains { $0.id == rule.id })
        #expect(f.session.toast?.ruleSaved == true)
    }

    @Test func newEntryFlow() throws {
        let f = try F()
        f.select(F.at(11, 30), F.at(12))
        f.session.beginNewEntry()
        #expect(f.session.picker == .newEntry && f.session.inspectorVisible)
        f.session.newEntry?.label = "Standup"
        f.session.newEntry?.projectId = 2
        try #require(f.session.commitNewEntry() != nil)
        #expect(try f.edits().map(\.payload) == [.add(label: "Standup", categoryId: nil, projectId: 2)])
        #expect(f.session.newEntry == nil && f.session.picker == nil)
    }

    @Test func nudgeAndMergeWithNeighbour() throws {
        let f = try F()
        f.session.msPerPoint = 30_000   // 5 min snap unit
        f.select(F.at(10), F.at(11))
        f.session.nudge(forward: false, startEdge: false)
        #expect(try f.edits().last.map { [$0.loMs, $0.hiMs] } == [F.at(10, 55), F.at(11)])
        _ = try f.refresh()
        f.select(F.at(11), F.at(11, 30))
        let g = try #require(f.session.merge(withNext: false))   // earlier segment (Xcode, now ending 10:55) wins
        #expect(try f.edits().filter { $0.grp == g }.map { [$0.loMs, $0.hiMs] } == [[F.at(10, 55), F.at(11, 30)], [F.at(10, 55), F.at(11)]])
        #expect(try f.edits().filter { $0.grp == g }.map(\.payload) == [.assign(categoryId: ClassifySeed.coding, projectId: nil),
                                                                       .add(label: "Coding", categoryId: ClassifySeed.coding, projectId: nil)])
    }

    @Test func dragsCommitOnMouseUpOnly() throws {
        let f = try F()
        f.session.msPerPoint = 30_000
        f.session.laneDrag(from: F.at(9, 1), to: F.at(10, 29), snap: true, mode: .replace, ended: false)
        #expect(f.session.drag == .marquee(F.at(9)..<F.at(10, 30)) && f.session.selection.isEmpty)
        f.session.laneDrag(from: F.at(9, 1), to: F.at(10, 29), snap: true, mode: .replace, ended: true)
        #expect(f.session.drag == nil && f.session.selection.ranges == [F.at(9)..<F.at(10, 30)])

        f.select(F.at(10), F.at(11))
        f.session.edgeDrag(.upper, to: F.at(10, 41), snap: true, ended: false)
        #expect(try f.edits().isEmpty)                       // preview only
        f.session.edgeDrag(.upper, to: F.at(10, 41), snap: true, ended: true)
        #expect(try f.edits().map { [$0.loMs, $0.hiMs] } == [[F.at(10, 40), F.at(11)]])
    }
}
