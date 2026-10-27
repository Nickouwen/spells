import Foundation
import GRDB

/// One day's EOD standup (W20). `editedMs` set = the user saved their own text over it.
public struct Standup: Sendable, Hashable {
    public var date: LocalDate
    public var body: String
    public var generatedMs: Int64?
    public var editedMs: Int64?
    public var inputsSha256: String?
    public var model: String?
    /// First day covered when it spans several (a combined EOD); nil = just `date`.
    public var fromDate: LocalDate?
    /// The user's corrections, one per line, reapplied on every regeneration; nil = none.
    public var instructions: String?

    public init(date: LocalDate, body: String, generatedMs: Int64? = nil, editedMs: Int64? = nil,
                inputsSha256: String? = nil, model: String? = nil, fromDate: LocalDate? = nil, instructions: String? = nil) {
        self.date = date; self.body = body; self.generatedMs = generatedMs; self.editedMs = editedMs
        self.inputsSha256 = inputsSha256; self.model = model; self.fromDate = fromDate; self.instructions = instructions
    }

    public var corrections: [String] { instructions?.split(separator: "\n").map(String.init) ?? [] }
}

/// The `standup` table: plain upserts, not chained (notes, not proof). Every write posts the change feed.
public struct StandupStore: Sendable {
    public let db: RewindDB
    public init(_ db: RewindDB) { self.db = db }

    public func get(_ date: LocalDate) throws -> Standup? {
        try db.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM standup WHERE date = ?", arguments: [date.description]).map(Self.standup)
        }
    }

    /// Most recent standup strictly before `date` (Carry-Forward / WIP continuity).
    public func previous(before date: LocalDate) throws -> Standup? {
        try db.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM standup WHERE date < ? ORDER BY date DESC LIMIT 1",
                             arguments: [date.description]).map(Self.standup)
        }
    }

    /// A fresh generation replaces the row, clearing `edited_ms`. Callers decide whether an edited
    /// standup may be overwritten (`spellsctl standup --regenerate`).
    public func saveGenerated(_ date: LocalDate, body: String, generatedMs: Int64, inputsSha256: String, model: String,
                              fromDate: LocalDate? = nil, instructions: String? = nil) throws {
        try storeCheckNul(body, model, instructions)
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO standup(date, body, generated_ms, edited_ms, inputs_sha256, model, from_date, instructions)
                VALUES (?, ?, ?, NULL, ?, ?, ?, ?)
                ON CONFLICT(date) DO UPDATE SET body = excluded.body, generated_ms = excluded.generated_ms,
                  edited_ms = NULL, inputs_sha256 = excluded.inputs_sha256, model = excluded.model,
                  from_date = excluded.from_date, instructions = excluded.instructions
                """, arguments: [date.description, body, generatedMs, inputsSha256, model, fromDate?.description, instructions])
        }
        db.didCommit()
    }

    /// The user's own text; keeps the generation provenance columns.
    public func saveEdit(_ date: LocalDate, body: String, editedMs: Int64) throws {
        try storeCheckNul(body)
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO standup(date, body, edited_ms) VALUES (?, ?, ?)
                ON CONFLICT(date) DO UPDATE SET body = excluded.body, edited_ms = excluded.edited_ms
                """, arguments: [date.description, body, editedMs])
        }
        db.didCommit()
    }

    private static func standup(_ r: Row) -> Standup {
        func day(_ s: String) -> LocalDate {
            let p = s.split(separator: "-").compactMap { Int($0) }
            return LocalDate(year: p[0], month: p[1], day: p[2])
        }
        return Standup(date: day(r["date"]), body: r["body"], generatedMs: r["generated_ms"], editedMs: r["edited_ms"],
                       inputsSha256: r["inputs_sha256"], model: r["model"], fromDate: (r["from_date"] as String?).map(day),
                       instructions: r["instructions"])
    }
}
