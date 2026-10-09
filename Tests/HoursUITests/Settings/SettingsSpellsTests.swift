import Testing
import IncantCore
import ScryCore
@testable import HoursUI

@MainActor
@Suite struct SettingsSpellsTests {
    /// The tab's edits → `rows` (what it writes) → `load` (what Incant reads) gives the same settings back.
    @Test func editsRoundTripThroughRows() {
        var base = IncantSettings()
        base.mode = .always
        let s = SettingsSpellsTab.edited(base, prompt: "  Fix it.\n", cues: "no,\n\n  actually \n", keyterms: "Alex\nClaude Code\n",
                                         model: " ")
        #expect(s.mode == .always)
        #expect(s.prompt == "Fix it.")
        #expect(s.cues == ["no,", "actually"])
        #expect(s.keyterms == ["Alex", "Claude Code"])
        #expect(s.model == IncantSettings.defaultModel)
        #expect(IncantSettings.load(s.rows) == s)
    }

    /// Scry's fields → `rows` → `load` round-trips; blanks fall back to the defaults.
    @Test func scryEditsRoundTripThroughRows() {
        var base = ScrySettings()
        base.live = false
        let s = SettingsSpellsTab.scryEdited(base, root: " ~/Notes/Scry ", name: "Test User", never: "us.zoom.xos\n\n com.hnc.Discord \n")
        #expect(!s.live && s.autoOffer)
        #expect(s.root == "~/Notes/Scry" && s.userName == "Test User")
        #expect(s.never == ["us.zoom.xos", "com.hnc.Discord"])
        #expect(ScrySettings.load(s.rows) == s)
        let d = SettingsSpellsTab.scryEdited(base, root: " ", name: "", never: "")
        #expect(d.root == ScrySettings.defaultRoot && d.userName == ScrySettings().userName && d.never.isEmpty)
    }
}
