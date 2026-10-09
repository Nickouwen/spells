import Testing
@testable import HoursCore

/// 02's acceptance cases. Units are ms; A=[0,100) app X (seq 1), B=[100,200) app Y (seq 2).
@Suite struct StoreEffectiveTests {
    let raw = [storeRaw(1, 0, 100, app: "X"), storeRaw(2, 100, 200, app: "Y")]

    @Test func case1_deleteMiddle() {
        let out = effectiveSpans(raw: raw, edits: [storeEdit(10, .delete, 150, 170)])
        #expect(out.map(\.storeShape) == [[0, 100, 1, nil], [100, 150, 2, nil], [170, 200, 2, nil]])
        #expect(out.reduce(0) { $0 + $1.durationMs } == 180)
        #expect(out[1].editSeqs == [10] && out[2].editSeqs == [10] && out[0].editSeqs.isEmpty)
    }

    @Test func case2_assignAcrossBoundary() {
        let out = effectiveSpans(raw: raw, edits: [storeEdit(10, .assign(categoryId: 5, projectId: nil), 50, 120)])
        #expect(out.map(\.storeShape) == [[0, 50, 1, nil], [50, 100, 1, 5], [100, 120, 2, 5], [120, 200, 2, nil]])
        #expect(out.allSatisfy { $0.projectOverride == nil })
    }

    @Test func case3_addManual() {
        let out = effectiveSpans(raw: raw, edits: [storeEdit(10, .add(label: "L", categoryId: nil, projectId: 7), 90, 110)])
        #expect(out.map(\.storeShape) == [[0, 90, 1, nil], [90, 110, nil, nil], [110, 200, 2, nil]])
        #expect(out[1].source == .manual && out[1].label == "L" && out[1].projectOverride == 7 && out[1].kind == .active)
    }

    @Test func case4_undoThenRedo() {
        let del = storeEdit(10, .delete, 150, 170)
        let undo = storeEdit(11, .undo, 150, 170, target: 10)
        let redo = storeEdit(12, .undo, 150, 170, target: 11)
        let undone = effectiveSpans(raw: raw, edits: [del, undo])
        #expect(undone.map(\.storeShape) == [[0, 100, 1, nil], [100, 200, 2, nil]])
        #expect(undone.allSatisfy { $0.editSeqs.isEmpty })
        let redone = effectiveSpans(raw: raw, edits: [del, undo, redo])
        #expect(redone.map(\.storeShape) == [[0, 100, 1, nil], [100, 150, 2, nil], [170, 200, 2, nil]])
    }

    @Test func case5_deleteAllThenAdd() {
        let out = effectiveSpans(raw: raw, edits: [storeEdit(10, .delete, 0, 200),
                                                   storeEdit(11, .add(label: "M", categoryId: 3, projectId: nil), 50, 60)])
        #expect(out.count == 1)
        #expect(out[0].startMs == 50 && out[0].endMs == 60 && out[0].source == .manual && out[0].categoryOverride == 3)
    }

    @Test func case6_outsideRangeIsNoOp_andSeqOrderWins() {
        let plain = effectiveSpans(raw: raw, edits: [])
        let outside = effectiveSpans(raw: raw, edits: [storeEdit(10, .delete, 500, 600),
                                                       storeEdit(11, .assign(categoryId: 1, projectId: nil), -50, 0)])
        #expect(outside == plain)
        #expect(plain.map(\.storeShape) == [[0, 100, 1, nil], [100, 200, 2, nil]])

        // Same two edits, array order reversed: seq decides. add(20) then delete(21) → nothing left.
        let add = storeEdit(20, .add(label: "M", categoryId: nil, projectId: nil), 50, 60)
        let del = storeEdit(21, .delete, 0, 200)
        #expect(effectiveSpans(raw: raw, edits: [del, add]).isEmpty)
        #expect(effectiveSpans(raw: raw, edits: [add, del]).isEmpty)
        // Swap the seqs: delete(20) then add(21) → the manual segment survives, whatever the array order.
        let del2 = storeEdit(20, .delete, 0, 200)
        let add2 = storeEdit(21, .add(label: "M", categoryId: nil, projectId: nil), 50, 60)
        #expect(effectiveSpans(raw: raw, edits: [add2, del2]).map(\.storeShape) == [[50, 60, nil, nil]])
        #expect(effectiveSpans(raw: raw, edits: [del2, add2]).map(\.storeShape) == [[50, 60, nil, nil]])
    }

    @Test func undoRevertsWholeGroup() {
        // One gesture: trim B + recategorize A (group 10). Undo group 10 → raw untouched.
        let g = [storeEdit(10, grp: 10, .delete, 150, 200),
                 storeEdit(11, grp: 10, .assign(categoryId: 4, projectId: nil), 0, 100)]
        #expect(effectiveSpans(raw: raw, edits: g).map(\.storeShape) == [[0, 100, 1, 4], [100, 150, 2, nil]])
        let u = storeEdit(12, .undo, 0, 200, target: 10)
        #expect(effectiveSpans(raw: raw, edits: g + [u]) == effectiveSpans(raw: raw, edits: []))
    }

    @Test func noteNeverChangesTime() {
        let a = storeEdit(10, .assign(categoryId: 2, projectId: nil), 0, 100)
        let n = storeEdit(11, .note(text: "why"), 0, 100, target: 10)
        #expect(effectiveSpans(raw: raw, edits: [a, n]) == effectiveSpans(raw: raw, edits: [a]))
    }

    @Test func assignKeepsUntouchedDimension() {
        let out = effectiveSpans(raw: raw, edits: [storeEdit(10, .assign(categoryId: nil, projectId: 9), 0, 100),
                                                   storeEdit(11, .assign(categoryId: 3, projectId: nil), 0, 100)])
        #expect(out[0].categoryOverride == 3 && out[0].projectOverride == 9 && out[0].editSeqs == [10, 11])
    }
}
