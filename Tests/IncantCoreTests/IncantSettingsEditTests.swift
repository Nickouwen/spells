import Testing
@testable import IncantCore

@Suite struct IncantSettingsEditTests {
    /// The settings window's edits → `rows` (what it writes) → `load` (what the key tap reads) gives the same settings back.
    @Test func editsRoundTripThroughRows() {
        var base = IncantSettings()
        base.mode = .always
        let s = IncantSettings.edited(base, prompt: "  Fix it.\n", cues: "no,\n\n  actually \n", keyterms: "Alex\nClaude Code\n", model: " ")
        #expect(s.mode == .always)
        #expect(s.prompt == "Fix it.")
        #expect(s.cues == ["no,", "actually"])
        #expect(s.keyterms == ["Alex", "Claude Code"])
        #expect(s.model == IncantSettings.defaultModel)
        #expect(IncantSettings.load(s.rows) == s)
    }
}
