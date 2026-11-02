import AppKit

/// Types text where the user is typing, as keystrokes: stream mode inserts a few words every second,
/// which the clipboard route (`IncantPaster`) would churn. Each event carries up to 20 UTF-16 units
/// (CGEvent's limit; surrogate pairs aren't split), a line break is Shift-Return (a plain Return
/// sends the message in most chat apps), and `delete` is that many Delete keys. Adapted from Hex's
/// keyboard module (MIT, see THIRD_PARTY_NOTICES.md).
@MainActor enum IncantTyper {
    /// Stamped on every event so the Fn tap doesn't take our keystrokes for a chord.
    static let marker: Int64 = 0x494E_4341   // "INCA"

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

    private static func press(_ key: CGKeyCode, flags: CGEventFlags, unicode: [UInt16]? = nil) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags   // never the physical Fn that's being held
            if let unicode { e.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
    }
}
