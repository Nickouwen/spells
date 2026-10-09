import Foundation
import HoursCore

/// Writes `ClassifySeed` into the config tables. Runs on every launch and only writes what's
/// missing or changed, so it is idempotent and new seed rules arrive with app updates.
/// User choices survive: category edits are never overwritten, seed rules keep their stored
/// `enabled`, and soft-deleted seed rules stay deleted.
enum ShellSeed {
    /// Returns the number of rows written (0 on a second run).
    @discardableResult
    static func run(_ config: ConfigStore) throws -> Int {
        var writes = 0

        // ponytail: categories/projects seed by key/id insert-if-missing; a seed id already taken by a
        // user row gets a fresh id, which would detach seed rules from it — impossible on a first run.
        let catKeys = Set(try config.categories().map(\.key))
        let catIds = Set(try config.categories().map(\.id))
        for var c in ClassifySeed.categories where !catKeys.contains(c.key) {
            if catIds.contains(c.id) { c.id = 0 }
            try config.insert(c)
            writes += 1
        }

        let projectIds = Set(try config.projects().map(\.id))
        for p in ClassifySeed.projects where !projectIds.contains(p.id) {
            try config.insert(p)
            writes += 1
        }

        // includeDeleted: a deleted seed rule must still be matched by seed_key (UNIQUE), not re-inserted.
        let existing = try config.rules(includeDeleted: true)
        let byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for rule in ClassifySeed.merge(into: existing) {
            if let old = byId[rule.id] {
                if old != rule { try config.update(rule); writes += 1 }
            } else {
                try config.insert(rule)
                writes += 1
            }
        }
        return writes
    }
}
