import Foundation
import GRDB

/// The `jev_class` table (W24): Jev answers and failed-request markers, keyed by `JevKey.id`.
/// Derived data, not proof: plain upserts, clearable. Every write posts the change feed so the
/// app rebuilds its classifier.
public struct JevCacheStore: Sendable {
    public let db: HoursDB
    public init(_ db: HoursDB) { self.db = db }

    public func all() throws -> [JevEntry] {
        try db.writer.read { db in try Row.fetchAll(db, sql: "SELECT * FROM jev_class").map(Self.entry) }
    }

    /// The classifier's view: the cache plus the stored settings. Disabled → no entries (the
    /// Browsing fallback still applies, since a snapshot is present).
    public func snapshot(nowMs: Int64? = nil) throws -> JevSnapshot {
        let settings = JevSettings(try SettingStore(db).all())
        return JevSnapshot(entries: settings.enabled ? try all() : [], settings: settings, nowMs: nowMs ?? storeNowMs())
    }

    /// One transaction, one change-feed post.
    public func upsert(_ entries: [JevEntry]) throws {
        guard !entries.isEmpty else { return }
        try db.writer.write { db in
            for e in entries {
                let probs = e.categoryProbs.isEmpty ? nil
                    : String(decoding: try JSONSerialization.data(withJSONObject: e.categoryProbs, options: [.sortedKeys]), as: UTF8.self)
                try db.execute(sql: """
                    INSERT INTO jev_class(key, app, host, path_tpl, title_norm, category_key, category_conf, category_probs,
                                          project_name, project_conf, model, created_ms, input_tokens, retry_after_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET category_key = excluded.category_key,
                      category_conf = excluded.category_conf, category_probs = excluded.category_probs,
                      project_name = excluded.project_name, project_conf = excluded.project_conf, model = excluded.model,
                      created_ms = excluded.created_ms, input_tokens = excluded.input_tokens,
                      retry_after_ms = excluded.retry_after_ms
                    """, arguments: [e.key.id, e.key.app, e.key.host, e.key.pathTpl, e.key.titleNorm, e.categoryKey,
                                     e.categoryKey == nil ? nil : e.categoryConf, probs, e.projectName,
                                     e.categoryKey == nil ? nil : e.projectConf, e.model, e.createdMs,
                                     e.inputTokens, e.retryAfterMs])
            }
        }
        db.didCommit()
    }

    /// Answered entries (failed markers excluded).
    public func count() throws -> Int {
        try db.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jev_class WHERE category_key IS NOT NULL") ?? 0 }
    }

    /// Input tokens spent on requests stored at or after `sinceMs`.
    public func inputTokens(sinceMs: Int64) throws -> Int {
        try db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT IFNULL(SUM(input_tokens), 0) FROM jev_class WHERE created_ms >= ?",
                             arguments: [sinceMs]) ?? 0
        }
    }

    /// Changes whenever the cache does: classifier-rebuild stamp.
    public func revision() throws -> String {
        try db.writer.read { db in
            let r = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, IFNULL(MAX(created_ms), 0) AS m FROM jev_class")!
            return "\(r["n"] as Int64):\(r["m"] as Int64)"
        }
    }

    public func clear() throws {
        try db.writer.write { db in try db.execute(sql: "DELETE FROM jev_class") }
        db.didCommit()
    }

    static func entry(_ r: Row) -> JevEntry {
        let probs = (r["category_probs"] as String?).flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Double]
        } ?? [:]
        return JevEntry(key: JevKey(app: r["app"], host: r["host"], pathTpl: r["path_tpl"], titleNorm: r["title_norm"]),
                        categoryKey: r["category_key"], categoryConf: r["category_conf"] ?? 0, categoryProbs: probs,
                        projectName: r["project_name"], projectConf: r["project_conf"] ?? 0, model: r["model"],
                        createdMs: r["created_ms"], inputTokens: r["input_tokens"] ?? 0, retryAfterMs: r["retry_after_ms"])
    }
}
