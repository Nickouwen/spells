import Foundation
import GRDB

/// Plain CRUD over category / project / rule. Item 4 owns semantics and seeding.
/// Categories and projects are referenced by id from chained edit payloads: archive, never delete.
/// Rules soft-delete (`deleted_ms`); `updated_ms` doubles as a cache-invalidation stamp.
/// Ids ≤ 0 on insert mean "assign one".
public struct ConfigStore: Sendable {
    public let db: HoursDB
    public init(_ db: HoursDB) { self.db = db }

    // MARK: category

    public func categories(includeArchived: Bool = true) throws -> [Category] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM category \(includeArchived ? "" : "WHERE archived = 0") ORDER BY sort, id")
                .map(Self.category)
        }
    }

    @discardableResult
    public func insert(_ c: Category) throws -> Int64 {
        try write { db in
            try db.execute(sql: """
                INSERT INTO category(id, key, name, level, is_work, behavior, color_slot, sort, archived)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [c.id > 0 ? c.id : nil, c.key, c.name, c.level.rawValue, c.isWork,
                                 c.behavior.rawValue, c.colorSlot, c.sort, c.archived])
            return db.lastInsertedRowID
        }
    }

    /// Updates everything but `key` (immutable slug).
    public func update(_ c: Category) throws {
        try write { db in
            try db.execute(sql: """
                UPDATE category SET name = ?, level = ?, is_work = ?, behavior = ?, color_slot = ?, sort = ?, archived = ?
                WHERE id = ?
                """, arguments: [c.name, c.level.rawValue, c.isWork, c.behavior.rawValue, c.colorSlot, c.sort,
                                 c.archived, c.id])
        }
    }

    // MARK: project

    public func projects(includeArchived: Bool = true) throws -> [Project] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM project \(includeArchived ? "" : "WHERE archived = 0") ORDER BY id")
                .map { Project(id: $0["id"], name: $0["name"], client: $0["client"], archived: $0["archived"]) }
        }
    }

    @discardableResult
    public func insert(_ p: Project) throws -> Int64 {
        try write { db in
            try db.execute(sql: "INSERT INTO project(id, name, client, archived) VALUES (?, ?, ?, ?)",
                           arguments: [p.id > 0 ? p.id : nil, p.name, p.client, p.archived])
            return db.lastInsertedRowID
        }
    }

    public func update(_ p: Project) throws {
        try write { db in
            try db.execute(sql: "UPDATE project SET name = ?, client = ?, archived = ? WHERE id = ?",
                           arguments: [p.name, p.client, p.archived, p.id])
        }
    }

    // MARK: rule

    public func rules(includeDeleted: Bool = false) throws -> [Rule] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM rule \(includeDeleted ? "" : "WHERE deleted_ms IS NULL") ORDER BY id")
                .map(Self.rule)
        }
    }

    /// Latest rule change (insert/update/delete), ms; 0 if none. Classification cache key.
    public func rulesRevision() throws -> Int64 {
        try db.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(MAX(updated_ms, IFNULL(deleted_ms, 0))) FROM rule") ?? 0
        }
    }

    @discardableResult
    public func insert(_ r: Rule, nowMs: Int64? = nil) throws -> Int64 {
        let now = nowMs ?? storeNowMs()
        return try write { db in
            try db.execute(sql: """
                INSERT INTO rule(id, origin, seed_key, enabled, priority, bundle_id, app_name, host, path_prefix,
                                 title_regex, category_id, project_id, created_ms, updated_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [r.id > 0 ? r.id : nil, r.origin.rawValue, r.seedKey, r.enabled, r.priority,
                                 r.bundleId, r.appName, r.host, r.pathPrefix, r.titleRegex, r.categoryId,
                                 r.projectId, now, now])
            return db.lastInsertedRowID
        }
    }

    public func update(_ r: Rule, nowMs: Int64? = nil) throws {
        let now = nowMs ?? storeNowMs()
        try write { db in
            try db.execute(sql: """
                UPDATE rule SET origin = ?, seed_key = ?, enabled = ?, priority = ?, bundle_id = ?, app_name = ?,
                                host = ?, path_prefix = ?, title_regex = ?, category_id = ?, project_id = ?, updated_ms = ?
                WHERE id = ?
                """, arguments: [r.origin.rawValue, r.seedKey, r.enabled, r.priority, r.bundleId, r.appName, r.host,
                                 r.pathPrefix, r.titleRegex, r.categoryId, r.projectId, now, r.id])
        }
    }

    /// Soft delete.
    public func deleteRule(id: Int64, nowMs: Int64? = nil) throws {
        let now = nowMs ?? storeNowMs()
        try write { db in
            try db.execute(sql: "UPDATE rule SET deleted_ms = ? WHERE id = ? AND deleted_ms IS NULL", arguments: [now, id])
        }
    }

    // MARK: -

    private func write<T: Sendable>(_ body: @Sendable (Database) throws -> T) throws -> T {
        let v = try db.writer.write(body)
        db.didCommit()
        return v
    }

    static func category(_ r: Row) -> Category {
        Category(id: r["id"], key: r["key"], name: r["name"], level: Productivity(rawValue: r["level"]) ?? .neutral,
                 isWork: r["is_work"], behavior: CategoryBehavior(rawValue: r["behavior"]) ?? .normal,
                 colorSlot: r["color_slot"], sort: r["sort"], archived: r["archived"])
    }

    static func rule(_ r: Row) -> Rule {
        Rule(id: r["id"], origin: Rule.Origin(rawValue: r["origin"]) ?? .user, seedKey: r["seed_key"],
             enabled: r["enabled"], priority: r["priority"], bundleId: r["bundle_id"], appName: r["app_name"],
             host: r["host"], pathPrefix: r["path_prefix"], titleRegex: r["title_regex"],
             categoryId: r["category_id"], projectId: r["project_id"])
    }
}
