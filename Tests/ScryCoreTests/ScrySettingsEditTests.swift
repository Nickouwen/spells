import Testing
@testable import ScryCore

@Suite struct ScrySettingsEditTests {
    /// The settings window's fields → `rows` → `load` round-trips; blanks fall back to the defaults.
    @Test func editsRoundTripThroughRows() {
        var base = ScrySettings()
        base.live = false
        let s = ScrySettings.edited(base, root: " ~/Notes/Scry ", name: "Test User", never: "us.zoom.xos\n\n com.hnc.Discord \n")
        #expect(!s.live && s.autoOffer)
        #expect(s.root == "~/Notes/Scry" && s.userName == "Test User")
        #expect(s.never == ["us.zoom.xos", "com.hnc.Discord"])
        #expect(ScrySettings.load(s.rows) == s)
        let d = ScrySettings.edited(base, root: " ", name: "", never: "")
        #expect(d.root == ScrySettings.defaultRoot && d.userName == ScrySettings().userName && d.never.isEmpty)
    }
}
