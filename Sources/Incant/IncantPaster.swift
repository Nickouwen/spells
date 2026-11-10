import AppKit

/// Pastes text where the user is typing: snapshot the pasteboard, set the text, post ⌘V, then put the
/// snapshot back ~1 s later unless someone copied in between. Adapted from FreeFlow's pasteboard
/// snapshot (MIT, see THIRD_PARTY_NOTICES.md).
@MainActor enum IncantPaster {
    /// Puts the text on the pasteboard for a manual ⌘V (no restore), still kept out of clipboard history.
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        let markers = [NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
                       NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]
        pb.declareTypes([.string] + markers, owner: nil)
        pb.setString(text, forType: .string)
        for m in markers { pb.setString("", forType: m) }
    }

    /// The user's clipboard while ours is on the board, and the paste it belongs to. Stream mode pastes
    /// sentence after sentence: the snapshot is taken before the first and put back a second after the
    /// last, so a later paste never snapshots our own text and the earlier restores stand down.
    private static var snapshot: [[(NSPasteboard.PasteboardType, Data)]]?
    private static var ours = -1, generation = 0

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        if snapshot == nil || pb.changeCount != ours {   // nothing held, or someone copied since: theirs is the clipboard to keep
            // ponytail: every type read as raw data — resolves lazy promises (a big copied image) up front.
            snapshot = (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
        }
        // Marked transient + concealed so clipboard managers keep dictated text out of their history.
        let markers = [NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
                       NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]
        pb.declareTypes([.string] + markers, owner: nil)
        pb.setString(text, forType: .string)
        for m in markers { pb.setString("", forType: m) }   // some managers check for data, not just the type
        ours = pb.changeCount
        generation += 1
        let gen = generation

        // Marked like the typer's keys: mid-dictation, with Fn held, an unmarked ⌘V is a chord to the Fn tap.
        IncantTyper.press(9, flags: .maskCommand)   // 9 = V

        Task {
            // Apps read the pasteboard asynchronously; Electron/remote-desktop ones can take well over 300 ms.
            try? await Task.sleep(for: .seconds(1))
            let pb = NSPasteboard.general
            guard gen == generation, pb.changeCount == ours, let saved = snapshot else { return }
            snapshot = nil
            pb.clearContents()
            pb.writeObjects(saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            })
        }
    }
}
