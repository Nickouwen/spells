import Testing
@testable import IncantCore

@Suite struct IncantCoreSmoke {
    @Test func defaultsAreSane() {
        let s = IncantSettings()
        #expect(s.mode == .whenNeeded && s.model == "qwen-3.8-27b" && !s.cues.isEmpty && !s.keyterms.isEmpty)
    }
}
