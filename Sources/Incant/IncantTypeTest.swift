import AppKit
import WebKit
import IncantCore

/// `Incant --type-test [gap ms]`: a scripted dictation typed into a real native text view and a real web
/// textarea, through the typer and paster a dictation uses, then each field read back and compared with
/// what Incant believes it typed. The unit tests cover the edits as values; this covers what the keystrokes
/// and pastes actually do to a text field (the layer the 2026-11-04 duplicated sentence came from).
/// It takes the keyboard focus for a few seconds, so it won't start while you're typing and stops if its
/// window loses focus. ponytail: WebKit stands in for web-rendered apps; Electron (Chromium) isn't covered.
@MainActor enum IncantTypeTest {
    /// The edits of a three-sentence dictation as the session makes them, and the text they should leave:
    /// partials appended, a long rewrite at the pause (deleted, then pasted), a short one (typed), a line
    /// break, non-ASCII, and a final pass that retypes the tail.
    static func script() -> (edits: [IncantGhost.Edit], expected: String) {
        var edits: [IncantGhost.Edit] = [], document = ""
        func sentence(_ lead: String, _ partials: [String], _ commit: String) {
            var g = IncantGhost(lead: lead)
            edits += partials.map { g.partial($0) }
            edits.append(g.commit(commit))
            document += g.typed
        }
        sentence("", ["so the same", "so the same way that the MacBook Air", "so the same way that the MacBook Air is now set up I want"],
                 "The same way that the MacBook Air is now set up, I want to set up the VPS as a worker")
        sentence(". ", ["then", "then run the tests"], "Then run the tests")
        sentence("\n", ["also copy", "also copy Priya on the"], "Also copy Priya on the naïve café plan 🙂")
        let final = document.replacing("café plan 🙂", with: "café plan, please 🙂")
        let common = zip(document, final).prefix { $0 == $1 }.count
        edits.append(IncantGhost.Edit(delete: document.count - common, text: String(final.dropFirst(common))))
        return (edits.filter { !$0.isEmpty }, final)
    }

    static func run(gapMs: Int) async -> Int32 {
        guard CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) > 3 else {
            print("not run: you were typing in the last 3 s")
            return 3
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // ⌘V reaches a text view through the Edit menu's key equivalent; without the menu a paste does nothing.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let bar = NSMenu(), item = NSMenuItem()
        item.submenu = edit; bar.addItem(item); app.mainMenu = bar

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Incant type test"
        window.center()
        let text = NSTextView(frame: window.contentLayoutRect)
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        let web = WKWebView(frame: window.contentLayoutRect)
        web.loadHTMLString("<textarea id=t autocorrect=off spellcheck=false style='width:95%;height:90%'></textarea>", baseURL: nil)

        let (edits, expected) = script()
        var failed = false
        for (name, view) in [("native text view", text as NSView), ("web textarea", web as NSView)] {
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            window.makeFirstResponder(view)
            try? await Task.sleep(for: .milliseconds(500))
            if view === web { _ = try? await web.evaluateJavaScript("document.getElementById('t').focus()") }
            for e in edits {
                guard app.isActive, window.isKeyWindow else {
                    print("\(name): stopped — the test window lost focus")
                    return 3
                }
                IncantTyper.replace(delete: e.delete, with: e.text)
                try? await Task.sleep(for: .milliseconds(gapMs))
            }
            try? await Task.sleep(for: .milliseconds(1500))   // the last keys land; the paster puts the clipboard back
            let got = view === web ? (try? await web.evaluateJavaScript("document.getElementById('t').value")) as? String ?? "" : text.string
            if got == expected { print("\(name): PASS (\(edits.count) edits, \(gapMs) ms apart)") } else {
                failed = true
                print("\(name): FAIL (\(edits.count) edits, \(gapMs) ms apart)\n  expected: \(expected.debugDescription)\n  got:      \(got.debugDescription)")
            }
        }
        return failed ? 1 : 0
    }
}
