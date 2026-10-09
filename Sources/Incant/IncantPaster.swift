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

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        // ponytail: every type read as raw data — resolves lazy promises (a big copied image) up front.
        let saved = (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
        // Marked transient + concealed so clipboard managers keep dictated text out of their history.
        let markers = [NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
                       NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]
        pb.declareTypes([.string] + markers, owner: nil)
        pb.setString(text, forType: .string)
        for m in markers { pb.setString("", forType: m) }   // some managers check for data, not just the type
        let ours = pb.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)   // 9 = V
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }

        Task {
            // Apps read the pasteboard asynchronously; Electron/remote-desktop ones can take well over 300 ms.
            try? await Task.sleep(for: .seconds(1))
            let pb = NSPasteboard.general
            guard pb.changeCount == ours else { return }
            pb.clearContents()
            pb.writeObjects(saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            })
        }
    }
}
