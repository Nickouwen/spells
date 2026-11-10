import AppKit

/// Types text where the user is typing, as keystrokes: stream mode inserts a few words every second,
/// which the clipboard route (`IncantPaster`) would churn. Each event carries up to 20 UTF-16 units
/// (CGEvent's limit; surrogate pairs aren't split), a line break is Shift-Return (a plain Return
/// sends the message in most chat apps), and `delete` is that many Delete keys. Adapted from Hex's
/// keyboard module (MIT, see THIRD_PARTY_NOTICES.md).
@MainActor enum IncantTyper {
    /// Stamped on every event so the Fn tap doesn't take our keystrokes for a chord.
    static let marker: Int64 = 0x494E_4341   // "INCA"
    /// When the last keystroke was posted. A posted keyboard event overwrites the system's modifier
    /// and key state with its own flags (measured 2026-11-02: `flagsState` and `keyState`, every event
    /// source, and it stays that way until the next real modifier event), so after one of ours
    /// `CGEventSource` says Fn is up while it's held. The session polls neither once it has typed.
    static private(set) var lastPostMs: Int64 = 0

    static func type(_ text: String) {
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { press(36, flags: .maskShift) }   // 36 = Return
            var units = Array(line.utf16)
            while !units.isEmpty {
                var n = min(20, units.count)
                if n < units.count, UTF16.isLeadSurrogate(units[n - 1]) { n -= 1 }
                press(0, flags: [], unicode: Array(units[..<n]))
                units.removeFirst(n)
            }
        }
    }

    static func delete(_ count: Int) {
        for _ in 0..<max(0, count) { press(51, flags: []) }   // 51 = Delete
    }

    /// Past this many keystrokes an edit is pasted instead (a sentence's rewrite at its pause is typically
    /// 30–150 Deletes, which read as the text being eaten and retyped).
    static let pasteOver = 20

    /// An edit — delete `count` characters before the cursor, then `text` — as keystrokes when it's small;
    /// past `pasteOver` the old text is still deleted key by key, and the new text pasted in one step.
    /// ponytail: not selected with Shift+Left and pasted over — in T3 Code's composer (Electron) only the first
    /// of ~100 Shift+Lefts took (2026-11-04), so the paste landed beside the old sentence, duplicating it.
    static func replace(delete count: Int, with text: String) {
        let keys = count + (text.utf16.count + 19) / 20 + text.filter(\.isNewline).count
        delete(count)
        guard keys > pasteOver, !text.isEmpty else { type(text); return }
        IncantPaster.paste(text)
    }

    static func press(_ key: CGKeyCode, flags: CGEventFlags, unicode: [UInt16]? = nil) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags   // never the physical Fn that's being held
            if let unicode { e.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
        lastPostMs = incantNowMs()
    }
}
