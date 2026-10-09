import Testing
@testable import ScryCore

@Suite struct ScryCoreSmoke {
    @Test func callAppsAndDefaults() {
        #expect(ScryCallApps.known["us.zoom.xos"] == "Zoom")
        let s = ScrySettings()
        #expect(s.autoOffer && s.live && s.root == "~/Documents/Scry")
    }
}
