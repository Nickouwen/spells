import Foundation
import Observation
import HoursCore

/// The editing model for one Day view: selection, gesture → one edit group, undo/redo, toast,
/// reason notes, "Always for …" rules. Writes only through `EditWriter` (verbs assign/delete/add/undo/note).
///
/// Undo: each group registers one `UndoManager` step whose handler appends `undo(group)` and
/// registers the inverse — so redo = undo of that undo group (08 decision 6). The stack is
/// in-memory; after relaunch the history view is the way back.
@MainActor @Observable
public final class EditSession {
    public enum Picker: Sendable, Hashable { case category, project, newEntry }

    public struct Toast: Sendable, Hashable {
        public var group: Int64
        public var summary: String
        /// "github.com" / "Xcode" when the gesture was a category/project assign.
        public var ruleLabel: String?
        var ruleSource: EffectiveSpan?
        var ruleCategoryId: Int64?
        var ruleProjectId: Int64?
        public var reasonOpen = false
        public var reasonSaved = false
        public var ruleSaved = false
    }

    public struct NewEntry: Sendable, Hashable {
        public var range: Range<Int64>
        public var label = ""
        public var categoryId: Int64?
        public var projectId: Int64?
    }

    /// In-flight drag preview, drawn by the overlay; nothing is written until mouse-up.
    enum Drag: Hashable {
        case marquee(Range<Int64>)
        case edge(EditGesture.Edge, Int64)
        case boundary(from: Int64, to: Int64)
    }

    public let db: HoursDB
    public private(set) var data: DayData?
    public var selection = EditSelection()
    public var inspectorVisible = false
    public var picker: Picker?
    public var newEntry: NewEntry?
    public var toast: Toast?
    public var historyVisible = false
    public private(set) var recentCategories: [Int64] = []
    public private(set) var recentProjects: [Int64] = []
    /// Last failure (e.g. a range that clamped to nothing at write time); shown in the toast slot.
    public var message: String?
    /// The range the last commit / undo / redo / revert touched, for the flash (`\.hoursEditFlash`).
    public private(set) var flash: EditFlash?
    var drag: Drag?
    /// Each group's hull, so undoing / reverting it flashes the same range.
    @ObservationIgnored private var groupRanges: [Int64: Range<Int64>] = [:]
    @ObservationIgnored private var flashCount = 0

    @ObservationIgnored public weak var undoManager: UndoManager?
    /// Called after every committed write (the shell reloads `DayData` on the change feed anyway;
    /// tests use this to reload synchronously).
    @ObservationIgnored public var onCommit: (() -> Void)?
    /// Pointer position over the lane (for S / N) and the current zoom (for nudge + snap units).
    @ObservationIgnored var pointerMs: Int64?
    @ObservationIgnored var msPerPoint: Double = 30_000

    public init(db: HoursDB) { self.db = db }

    /// Feed the latest day. A different date clears the selection and any drag.
    public func update(_ new: DayData) {
        if data?.date != new.date { selection.clear(); drag = nil; newEntry = nil; picker = nil; flash = nil }
        data = new
    }

    // MARK: Gestures

    /// Plans and writes `g` against the selection as one group. Returns the group id, nil if nothing applied.
    @discardableResult
    public func perform(_ g: EditGesture) -> Int64? {
        guard let data, let plan = EditPlanner.plan(g, selection: selection.ranges, in: data) else { return nil }
        return commit(plan)
    }

    @discardableResult
    func commit(_ plan: EditPlan) -> Int64? {
        guard let data else { return nil }
        let grp: Int64
        do {
            grp = try EditWriter(db).apply(plan.drafts, tzId: data.timeZone.identifier)
        } catch {
            message = error as? StoreError == .emptyRange ? "The live span isn't editable until it closes." : "\(error)"
            return nil
        }
        message = nil
        register(group: grp, name: plan.actionName)
        setFlash(grp, Self.hull(plan))
        selection.set(plan.selection)
        for d in plan.drafts {
            if case let .assign(c, p) = d.payload { remember(c, p) }
            if case let .add(_, c, p) = d.payload { remember(c, p) }
        }
        let label: String? = plan.ruleSource.flatMap { s in
            guard plan.ruleCategoryId != nil || plan.ruleProjectId != nil else { return nil }
            return ClassifyURL.host(s.url) ?? s.appName
        }
        toast = Toast(group: grp, summary: plan.summary, ruleLabel: label, ruleSource: plan.ruleSource,
                      ruleCategoryId: plan.ruleCategoryId, ruleProjectId: plan.ruleProjectId)
        onCommit?()
        return grp
    }

    /// Reverts any group (history "Revert", toast "Undo" when it isn't the stack top). Undoable itself.
    @discardableResult
    public func revert(group: Int64, name: String = "Revert") -> Int64? {
        do {
            let u = try EditWriter(db).apply([.undo(group: group)], tzId: data?.timeZone.identifier ?? TimeZone.current.identifier)
            register(group: u, name: name)
            setFlash(u, groupRanges[group])
            toast = nil   // the toast's Undo would now target the wrong stack entry
            onCommit?()
            return u
        } catch {
            message = "\(error)"
            return nil
        }
    }

    /// Post-hoc reason. Never changes time; not an undo step (the reason is history, not state).
    @discardableResult
    public func note(group: Int64, text: String) -> Int64? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let n = try? EditWriter(db).apply([.note(group: group, text: text)], tzId: data?.timeZone.identifier ?? TimeZone.current.identifier)
        if n != nil, toast?.group == group { toast?.reasonOpen = false; toast?.reasonSaved = true }
        onCommit?()
        return n
    }

    /// Hull of the drafts' ranges (undo / note drafts carry none), else of the resulting selection.
    static func hull(_ plan: EditPlan) -> Range<Int64>? {
        EditSelection(plan.drafts.filter { $0.hiMs > $0.loMs }.map { $0.loMs..<$0.hiMs }).hull ?? EditSelection(plan.selection).hull
    }

    /// nil `r`: a group from before this session (history revert after relaunch); nothing to flash.
    private func setFlash(_ group: Int64, _ r: Range<Int64>?) {
        guard let r else { return }
        groupRanges[group] = r
        flashCount += 1
        flash = EditFlash(range: r, id: flashCount)
    }

    private func register(group g: Int64, name: String) {
        guard let um = undoManager else { return }
        let nested = um.isUndoing || um.isRedoing
        if !nested { um.beginUndoGrouping() }
        um.registerUndo(withTarget: self) { s in s.revert(group: g, name: name) }
        um.setActionName(name)
        if !nested { um.endUndoGrouping() }
    }

    // MARK: "Always for …" (item 4 owns rules; we only persist the suggester's draft)

    /// Saves a rule from the toast's assign. Not an edit: rules aren't in the chain and aren't undone here.
    @discardableResult
    public func saveToastRule() -> Rule? {
        guard let t = toast, let s = t.ruleSource else { return nil }
        let r = saveRule(from: s, categoryId: t.ruleCategoryId, projectId: t.ruleProjectId)
        if r != nil { toast?.ruleSaved = true }
        return r
    }

    /// Rule from the selection's dominant span to its current category/project (context menu "Always for …").
    @discardableResult
    public func saveSelectionRule() -> Rule? {
        guard let data, let s = EditPlanner.dominant(selection.ranges, data),
              let c = data.spans.first(where: { $0.span.startMs <= s.startMs && s.startMs < $0.span.endMs }) else { return nil }
        return saveRule(from: s, categoryId: c.categoryId, projectId: c.projectId)
    }

    func saveRule(from s: EffectiveSpan, categoryId: Int64?, projectId: Int64?) -> Rule? {
        let field: ClassifyRuleSuggester.Field = ClassifyURL.host(s.url) != nil ? .host : .app
        guard var rule = ClassifyRuleSuggester.rule(from: s, field: field, categoryId: categoryId, projectId: projectId),
              let id = try? ConfigStore(db).insert(rule) else { return nil }
        rule.id = id
        onCommit?()
        return rule
    }

    /// Label for "Always for …" on the current selection.
    var selectionRuleLabel: String? {
        guard let data, let s = EditPlanner.dominant(selection.ranges, data) else { return nil }
        return ClassifyURL.host(s.url) ?? s.appName
    }

    // MARK: Selection

    /// Canvas click (through the Day view's `selectedRange` hook). nil = clicked empty space / the same span.
    func click(_ r: ClosedRange<Int64>?, mode: EditSelection.Mode) {
        guard let r else {
            if mode == .replace { selection.clear() } else if mode == .toggle, selection.ranges.count == 1 { selection.clear() }
            return
        }
        selection.select(r.lowerBound..<r.upperBound, mode: mode)
    }

    /// Selects the span under `ms` unless `ms` is already inside the selection (right-click target).
    public func target(_ ms: Int64?) {
        guard let ms, let data, !selection.ranges.contains(where: { $0.contains(ms) }),
              let i = DayTimeline.spanIndex(at: ms, in: data.spans) else { return }
        let s = data.spans[i].span
        selection.select(s.startMs..<s.endMs, mode: .replace)
    }

    /// Cmd-A: everything editable on the day.
    public func selectDay() {
        guard let data, let lo = data.spans.first?.span.startMs, let hi = data.spans.map(\.span.endMs).max(),
              let r = EditPlanner.clamp(lo..<hi, data) else { return }
        selection.set([r])
    }

    /// S / "Split here": cut the selection at `ms` (default: the pointer) and select the right half.
    @discardableResult
    public func split(at ms: Int64? = nil) -> Bool {
        guard let t = ms ?? pointerMs, let s = selection.split(at: t) else { return false }
        selection = s
        return true
    }

    /// Merge with the previous / next segment (context menu): the earlier one's attributes win.
    @discardableResult
    public func merge(withNext next: Bool) -> Int64? {
        guard let data, let hull = selection.hull else { return nil }
        let other = next ? data.spans.first { $0.span.startMs >= hull.upperBound && $0.span.kind == .active }
                         : data.spans.last { $0.span.endMs <= hull.lowerBound && $0.span.kind == .active }
        guard let o = other?.span else { return nil }
        let r = next ? hull.lowerBound..<o.endMs : o.startMs..<hull.upperBound
        guard let plan = EditPlanner.plan(.merge, selection: [r], in: data) else { return nil }
        return commit(plan)
    }

    /// ⌥←/→ nudges the end edge by one snap unit; with Shift, the start edge.
    @discardableResult
    public func nudge(forward: Bool, startEdge: Bool) -> Int64? {
        guard let r = selection.ranges.first, selection.ranges.count == 1 else { return nil }
        let step = EditSnap.gridMs(msPerPoint: msPerPoint) * (forward ? 1 : -1)
        let edge: EditGesture.Edge = startEdge ? .lower : .upper
        return resizeOrReselect(edge, to: (startEdge ? r.lowerBound : r.upperBound) + step)
    }

    /// Edge drag / time field: resize when the edge sits on a segment edge, else just move the selection edge.
    @discardableResult
    func resizeOrReselect(_ edge: EditGesture.Edge, to t: Int64) -> Int64? {
        if let g = perform(.resize(edge, to: t)) { return g }
        guard let r = selection.ranges.first, selection.ranges.count == 1, let data else { return nil }
        let nr = edge == .upper ? r.lowerBound..<t : t..<r.upperBound
        if let c = EditPlanner.clamp(nr, data), c.upperBound - c.lowerBound >= EditPlanner.minSegmentMs { selection.set([c]) }
        return nil
    }

    /// Inspector start/end fields (`HH:mm`). Returns false when the text doesn't parse.
    @discardableResult
    public func setEdge(_ edge: EditGesture.Edge, text: String) -> Bool {
        guard let data, let t = EditTime.parse(text, bounds: data.bounds, timeZone: data.timeZone) else { return false }
        resizeOrReselect(edge, to: t)
        return true
    }

    // MARK: Manual entry

    /// N: an entry over the selection hull, else the 30 min before the watermark (today) / after the last span.
    public func beginNewEntry() {
        guard let data else { return }
        let r: Range<Int64>?
        if let h = selection.hull {
            r = EditPlanner.clamp(h, data)
        } else if let w = EditPlanner.watermark(data) {
            r = EditPlanner.clamp((w - 30 * 60_000)..<w, data)
        } else {
            let end = data.spans.map(\.span.endMs).max() ?? (data.bounds.lowerBound + 5 * 3_600_000)
            r = EditPlanner.clamp(end..<(end + 30 * 60_000), data)
        }
        guard let r else { message = "Nothing editable here."; return }
        newEntry = NewEntry(range: r, categoryId: recentCategories.first)
        selection.set([r])
        inspectorVisible = true
        picker = .newEntry
    }

    @discardableResult
    public func commitNewEntry() -> Int64? {
        guard let e = newEntry else { return nil }
        let g = perform(.add(e.range, label: e.label, categoryId: e.categoryId, projectId: e.projectId))
        if g != nil { newEntry = nil; picker = nil }
        return g
    }

    // MARK: Drags (overlay)

    /// Marquee over the lane. `snap` false while Option is held.
    func laneDrag(from a: Int64, to b: Int64, snap: Bool, mode: EditSelection.Mode, ended: Bool) {
        guard let data else { return }
        let lo = snapped(min(a, b), snap), hi = snapped(max(a, b), snap)
        guard let r = EditPlanner.clamp(lo..<hi, data) ?? (ended ? nil : lo..<max(hi, lo + 1)) else { drag = nil; return }
        if ended {
            drag = nil
            if r.upperBound - r.lowerBound >= EditPlanner.minSegmentMs { selection.select(r, mode: mode) }
        } else {
            drag = .marquee(r)
        }
    }

    func edgeDrag(_ edge: EditGesture.Edge, to ms: Int64, snap: Bool, ended: Bool) {
        let t = snapped(ms, snap)
        if ended { drag = nil; resizeOrReselect(edge, to: t) } else { drag = .edge(edge, t) }
    }

    func boundaryDrag(from t0: Int64, to ms: Int64, snap: Bool, ended: Bool) {
        let t = snapped(ms, snap)
        if ended { drag = nil; perform(.moveBoundary(from: t0, to: t)) } else { drag = .boundary(from: t0, to: t) }
    }

    func snapped(_ ms: Int64, _ on: Bool) -> Int64 {
        guard on, let data else { return ms }
        return EditSnap.snap(ms, targets: EditSnap.targets(data), msPerPoint: msPerPoint, timeZone: data.timeZone)
    }

    // MARK: Reads for the inspector / history

    /// Active raw (pre-edit) time in `r`, for the inspector's "Original" line.
    func originalMs(_ r: Range<Int64>) -> Int64 {
        let raw = (try? Store(db).rawSpans(from: r.lowerBound, to: r.upperBound)) ?? []
        return raw.filter { $0.kind == .active }.reduce(0) { $0 + max(0, min($1.endMs, r.upperBound) - max($1.startMs, r.lowerBound)) }
    }

    private func remember(_ c: Int64?, _ p: Int64?) {
        if let c { recentCategories = Array(([c] + recentCategories.filter { $0 != c }).prefix(5)) }
        if let p { recentProjects = Array(([p] + recentProjects.filter { $0 != p }).prefix(5)) }
    }
}
