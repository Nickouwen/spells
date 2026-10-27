import Foundation
import SpellsKit

extension SettingStore {
    /// One-time move of each spell's rows out of the `setting` table into its own file (module split, 2026-10).
    /// Keys are routed by prefix so this needs no spell module; the rows are left in place (harmless) and a
    /// spell whose file already exists is skipped, so a later edit in the file never gets overwritten.
    /// Returns the spells migrated.
    @discardableResult
    public func migrateSpellFiles(paths: SupportPaths) throws -> [String] {
        let rows = try all()
        var done: [String] = []
        for (spell, keep) in [("incant", { (k: String) in k.hasPrefix("incant_") }),
                              ("scry", { (k: String) in k.hasPrefix("scry_") || k == SpellsClaude.key })] {
            let file = SpellSettingsFile(spell: spell, paths: paths)
            let mine = rows.filter { keep($0.key) }
            guard !file.exists, !mine.isEmpty else { continue }
            try file.replace(mine)
            done.append(spell)
        }
        return done
    }
}
