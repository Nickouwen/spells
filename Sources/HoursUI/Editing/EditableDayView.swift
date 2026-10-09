import SwiftUI
import HoursCore

/// The Day view with editing: selection overlay + handles on the timeline, inspector (I), toast,
/// context menu, single-key shortcuts (only while the timeline area has focus and no text field
/// does), edit history sheet. The shell supplies `DayData` and reloads it on the change feed;
/// the session writes through `EditWriter` and registers undo on the window's `UndoManager`.
public struct EditableDayView: View {
    let data: DayData
    @Bindable var session: EditSession
    let onNavigate: (LocalDate) -> Void
    var scrollable = true

    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    /// Blocks mode's settings + rules (W22), shared through the environment.
    @State private var blocksStore: BlocksStore

    public init(data: DayData, session: EditSession, onNavigate: @escaping (LocalDate) -> Void) {
        self.data = data
        self.session = session
        self.onNavigate = onNavigate
        _blocksStore = State(initialValue: BlocksStore(db: session.db))
    }

    /// Render-test entry point (no ScrollView).
    init(data: DayData, session: EditSession, scrollable: Bool) {
        self.init(data: data, session: session, onNavigate: { _ in })
        self.scrollable = scrollable
    }

    public var body: some View {
        HStack(spacing: 0) {
            DayView(data: data, onNavigate: onNavigate, selectedRange: selectionBinding, editHooks: hooks, scrollable: scrollable)
                .overlay(alignment: .bottom) {
                    EditToastView(session: session)
                        .padding(.bottom, Theme.Space.l)
                        .padding(.horizontal, Theme.Space.gutter)
                }
                .environment(\.hoursEditFlash, session.flash)
            if session.inspectorVisible {
                // Fades while the day narrows / widens to make room; no slide.
                Rectangle().fill(Theme.hairline).frame(width: Theme.Stroke.hairline)
                    .transition(.opacity)
                EditInspector(session: session, data: data)
                    .frame(width: 300)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.snap(reduceMotion: reduceMotion), value: session.inspectorVisible)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { handleKey($0) }
        .environment(\.blocksStore, blocksStore)
        .onAppear {
            session.update(data)
            session.undoManager = undoManager
            focused = true
            blocksStore.loadIfNeeded()
        }
        .task {
            for await _ in ChangeFeed.stream(name: blocksStore.db.notifyName) { await blocksStore.reload() }
        }
        .onChange(of: data) { session.update(data) }
        .onChange(of: undoManager) { session.undoManager = undoManager }
        .sheet(isPresented: $session.historyVisible) {
            EditHistoryView(session: session) { r in session.selection.set([r]) }
        }
        .focusedSceneValue(\.hoursEditSession, session)
    }

    /// The Day view's single-range hook. Shift / Cmd on the click extend / add (read at click time).
    private var selectionBinding: Binding<ClosedRange<Int64>?> {
        Binding(get: {
            let r = session.selection.ranges
            return r.count == 1 ? r[0].lowerBound...r[0].upperBound : nil
        }, set: {
            session.click($0, mode: EditOverlay.selectionMode)
            focused = true
        })
    }

    private var hooks: DayEditHooks {
        let session = session, data = data
        return DayEditHooks(
            overlay: { vp in AnyView(EditOverlay(session: session, data: data, vp: vp)) },
            laneDrag: { a, b, vp, ended in
                session.msPerPoint = vp.msPerPoint
                if case .edge = session.drag { return }
                if case .boundary = session.drag { return }
                guard !EditOverlay.isOnHandle(a, data: data, selection: session.selection, vp: vp) else { return }
                session.laneDrag(from: a, to: b, snap: !EditOverlay.optionHeld, mode: EditOverlay.selectionMode, ended: ended)
            },
            hover: { ms, vp in
                session.pointerMs = ms
                session.msPerPoint = vp.msPerPoint
            },
            contextMenu: { ms in AnyView(EditContextMenu(session: session, data: data, ms: ms)) },
            commit: { plan in session.commit(plan) })
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard focused else { return .ignored }
        let mods = press.modifiers
        switch press.key {
        case .escape:
            if session.picker != nil { session.picker = nil; session.newEntry = nil } else { session.selection.clear() }
            return .handled
        case .delete, .deleteForward:
            return session.perform(.delete) != nil ? .handled : .ignored
        case .leftArrow where mods.contains(.option), .rightArrow where mods.contains(.option):
            session.nudge(forward: press.key == .rightArrow, startEdge: mods.contains(.shift))
            return .handled
        default: break
        }
        let ch = press.characters.lowercased()
        if mods.contains(.command) {
            if ch == "a", !mods.contains(.shift) { session.selectDay(); return .handled }
            if ch == "h", mods.contains(.shift) { session.historyVisible = true; return .handled }
            return .ignored
        }
        guard mods.subtracting([.shift, .capsLock, .numericPad]).isEmpty else { return .ignored }
        switch ch {
        case "c", "p":
            guard !session.selection.isEmpty else { return .ignored }
            session.inspectorVisible = true
            session.picker = ch == "c" ? .category : .project
        case "x": session.perform(.markPersonal)
        case "n": session.beginNewEntry()
        case "s": session.split()
        case "m": session.perform(.merge)
        case "i": session.inspectorVisible.toggle()
        default: return .ignored
        }
        return .handled
    }
}

/// Right-click menu on the timeline. Acts on the selection, or on the span under the pointer
/// when the pointer is outside it.
struct EditContextMenu: View {
    let session: EditSession
    let data: DayData
    let ms: Int64?

    var body: some View {
        let recentsC = session.recentCategories.compactMap { id in data.categories.first { $0.id == id } }
        Menu("Category") {
            ForEach(recentsC) { c in Button(c.name) { act { session.perform(.recategorize(c.id)) } } }
            if !recentsC.isEmpty { Divider() }
            ForEach(data.categories.filter { !$0.archived && $0.key != "uncategorized" }) { c in
                Button(c.name) { act { session.perform(.recategorize(c.id)) } }
            }
        }
        Menu("Project") {
            ForEach(data.projects.filter { !$0.archived }) { p in
                Button(p.name) { act { session.perform(.assignProject(p.id)) } }
            }
        }
        Button("Mark Personal") { act { session.perform(.markPersonal) } }
        Divider()
        Button("Split Here") { act { session.split(at: ms) } }.disabled(ms == nil)
        Button("Merge with Previous") { act { session.merge(withNext: false) } }
        Button("Merge with Next") { act { session.merge(withNext: true) } }
        Button("Add Entry Here") { act { session.beginNewEntry() } }
        Divider()
        Button("Delete") { act { session.perform(.delete) } }
        Divider()
        Button("Always for \(session.selectionRuleLabel ?? "this")…") { act { session.saveSelectionRule() } }
        Button("Edit History for Range") { act { session.historyVisible = true } }
    }

    private func act(_ f: () -> Void) {
        session.target(ms)
        f()
    }
}

/// Non-modal toast after each edit: summary · Undo · Add reason · Always for … (6 s, no confirmation dialogs).
struct EditToastView: View {
    @Bindable var session: EditSession
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool

    var body: some View {
        Group {
            if let t = session.toast {
                HStack(spacing: Theme.Space.m) {
                    Text(t.summary).font(TextRole.bodyEmph.font).foregroundStyle(Theme.surface).lineLimit(1)
                    if t.reasonOpen {
                        TextField("Reason", text: $reason)
                            .textFieldStyle(.plain)
                            .font(TextRole.body.font).foregroundStyle(Theme.surface)
                            .frame(width: 220)
                            .focused($reasonFocused)
                            .onSubmit { session.note(group: t.group, text: reason); reason = "" }
                            .onAppear { reasonFocused = true }
                    } else {
                        sep
                        link("Undo") { session.undoToast() }
                        sep
                        link(t.reasonSaved ? "Reason saved" : "Add reason", disabled: t.reasonSaved) { session.toast?.reasonOpen = true }
                        if let label = t.ruleLabel {
                            sep
                            link(t.ruleSaved ? "Rule saved" : "Always for \(label)", disabled: t.ruleSaved) { session.saveToastRule() }
                        }
                    }
                    Button { session.toast = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.inkDisabled)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s + 2)
                .background(Theme.ink, in: Capsule())
                .fixedSize()
                .task(id: t.group) {
                    // One-shot dismissal (not a repeating timer); an open reason field keeps it up.
                    try? await Task.sleep(for: .seconds(6))
                    if session.toast?.group == t.group, session.toast?.reasonOpen == false { session.toast = nil }
                }
            } else if let m = session.message {
                Text(m).font(TextRole.bodyEmph.font).foregroundStyle(Theme.surface)
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s + 2)
                    .background(Theme.ink, in: Capsule())
                    .task(id: m) {
                        try? await Task.sleep(for: .seconds(4))
                        if session.message == m { session.message = nil }
                    }
            }
        }
    }

    private var sep: some View { Text("·").foregroundStyle(Theme.inkDisabled) }

    private func link(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(TextRole.bodyEmph.font)
            .foregroundStyle(disabled ? Theme.inkDisabled : Theme.surface)
            .underline(!disabled)
            .disabled(disabled)
    }
}

extension EditSession {
    /// Toast "Undo": the stack top when it is this edit, else a direct revert.
    public func undoToast() {
        guard let t = toast else { return }
        toast = nil
        if let um = undoManager, um.canUndo { um.undo() } else { revert(group: t.group, name: "Undo") }
    }
}

/// Shell entry point: keeps one `EditSession` per Day slot across `DayData` refreshes.
public struct EditingDayHost: View {
    let data: DayData
    let onNavigate: (LocalDate) -> Void
    @State private var session: EditSession

    public init(data: DayData, db: HoursDB, onNavigate: @escaping (LocalDate) -> Void) {
        self.data = data
        self.onNavigate = onNavigate
        _session = State(initialValue: EditSession(db: db))
    }

    public var body: some View {
        EditableDayView(data: data, session: session, onNavigate: onNavigate)
    }
}
