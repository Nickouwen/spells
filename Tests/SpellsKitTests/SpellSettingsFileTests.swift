import Foundation
import Testing
@testable import SpellsKit

@Suite struct SpellSettingsFileTests {
    private func temp() -> SupportPaths {
        let home = FileManager.default.temporaryDirectory.appending(path: "spellskit-\(UUID().uuidString)")
        return SupportPaths(home: home, logs: home)
    }

    @Test func missingFileReadsEmptyAndMergeCreatesIt() throws {
        let f = SpellSettingsFile.incant(temp())
        #expect(!f.exists)
        #expect(f.all() == [:])
        try f.merge(["incant_model": "m", "incant_cues": "no,\nscratch that"])
        #expect(f.exists)
        #expect(f.all() == ["incant_model": "m", "incant_cues": "no,\nscratch that"])
        #expect(f.url.lastPathComponent == "settings.json")
        #expect(f.url.deletingLastPathComponent().lastPathComponent == "incant")
    }

    @Test func mergeKeepsOtherKeysAndNilRemoves() throws {
        let f = SpellSettingsFile.scry(temp())
        try f.replace(["scry_root": "~/Documents/Scry", "scry_live": "1"])
        try f.merge(["scry_live": nil, "scry_user_name": "Nic"])
        #expect(f.all() == ["scry_root": "~/Documents/Scry", "scry_user_name": "Nic"])
        try f.set("scry_root", nil)
        #expect(f.all() == ["scry_user_name": "Nic"])
    }

    @Test func claudePath() {
        #expect(SpellsClaude.path([:]) == SpellsClaude.defaultPath)
        #expect(SpellsClaude.path([SpellsClaude.key: "  "]) == SpellsClaude.defaultPath)
        #expect(SpellsClaude.path([SpellsClaude.key: "~/bin/claude"]) == NSHomeDirectory() + "/bin/claude")
    }
}
