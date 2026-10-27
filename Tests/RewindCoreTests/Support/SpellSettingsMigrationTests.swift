import Foundation
import Testing
@testable import RewindCore

@Suite struct SpellSettingsMigrationTests {
    @Test func routesRowsByPrefixOnceAndLeavesTheTableAlone() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "spells-migrate-\(UUID().uuidString)")
        let paths = SupportPaths(home: home, logs: home)
        try paths.createDirectories()
        let db = try RewindDB.open(at: paths.db, role: .app)
        let store = SettingStore(db)
        try store.set("incant_model", "m")
        try store.set("scry_root", "/notes")
        try store.set("claude_path", "/x/claude")
        try store.set("idle_threshold_s", "300")

        #expect(try store.migrateSpellFiles(paths: paths) == ["incant", "scry"])
        #expect(SpellSettingsFile.incant(paths).all() == ["incant_model": "m"])
        #expect(SpellSettingsFile.scry(paths).all() == ["scry_root": "/notes", "claude_path": "/x/claude"])
        #expect(try store.get("incant_model") == "m")

        // A later edit in the file wins over the stale rows: the second run is a no-op.
        try SpellSettingsFile.scry(paths).set("scry_root", "/elsewhere")
        #expect(try store.migrateSpellFiles(paths: paths) == [])
        #expect(SpellSettingsFile.scry(paths).all()["scry_root"] == "/elsewhere")
    }
}
