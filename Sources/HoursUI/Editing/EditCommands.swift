import SwiftUI

extension FocusedValues {
    /// The editing session of the focused window's Day view (menu commands act on it).
    @Entry public var hoursEditSession: EditSession?
}

/// Edit-menu items for timeline editing. Undo / Redo need no wiring: the session registers on the
/// window's `UndoManager`, which the standard Edit menu already drives ("Undo Recategorize").
/// Single-key shortcuts (C P X N S M I ⌫) are handled by the view so they never fire while typing;
/// the menu only carries ⇧⌘H.
public struct EditCommands: Commands {
    @FocusedValue(\.hoursEditSession) private var session

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            let none = session?.selection.isEmpty ?? true
            Button("Recategorize…") { open(.category) }.disabled(none)
            Button("Assign Project…") { open(.project) }.disabled(none)
            Button("Mark Personal") { session?.perform(.markPersonal) }.disabled(none)
            Button("Delete Time") { session?.perform(.delete) }.disabled(none)
            Button("Merge Selected") { session?.perform(.merge) }.disabled(none)
            Button("New Entry…") { session?.beginNewEntry() }.disabled(session == nil)
            Button("Select Day") { session?.selectDay() }.disabled(session == nil)
            Divider()
            Button(session?.inspectorVisible == true ? "Hide Inspector" : "Show Inspector") {
                session?.inspectorVisible.toggle()
            }
            .disabled(session == nil)
            Button("Edit History…") { session?.historyVisible = true }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(session == nil)
        }
    }

    private func open(_ p: EditSession.Picker) {
        session?.inspectorVisible = true
        session?.picker = p
    }
}
