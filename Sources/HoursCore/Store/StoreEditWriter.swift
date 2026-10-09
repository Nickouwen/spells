import Foundation
import GRDB

/// One edit of a user gesture, before it gets a seq. `undo`/`note` take their range from the
/// target group's hull at write time.
public struct EditDraft: Sendable, Hashable {
    public var loMs: Int64
    public var hiMs: Int64
    public var payload: EditPayload
    public var target: Int64?

    public init(loMs: Int64, hiMs: Int64, payload: EditPayload, target: Int64? = nil) {
        self.loMs = loMs; self.hiMs = hiMs; self.payload = payload; self.target = target
    }

    public static func delete(_ lo: Int64, _ hi: Int64) -> EditDraft { .init(loMs: lo, hiMs: hi, payload: .delete) }
    /// nil = leave that dimension untouched.
    public static func assign(_ lo: Int64, _ hi: Int64, categoryId: Int64?, projectId: Int64?) -> EditDraft {
        .init(loMs: lo, hiMs: hi, payload: .assign(categoryId: categoryId, projectId: projectId))
    }
    public static func add(_ lo: Int64, _ hi: Int64, label: String, categoryId: Int64? = nil,
                           projectId: Int64? = nil) -> EditDraft {
        .init(loMs: lo, hiMs: hi, payload: .add(label: label, categoryId: categoryId, projectId: projectId))
    }
    /// Reverts every edit in `group`. Undoing an undo group = redo.
    public static func undo(group: Int64) -> EditDraft { .init(loMs: 0, hiMs: 0, payload: .undo, target: group) }
    public static func note(group: Int64, text: String) -> EditDraft {
        .init(loMs: 0, hiMs: 0, payload: .note(text: text), target: group)
    }

    public var op: EditOp { payload.op }
}

extension EditPayload {
    public var op: EditOp {
        switch self {
        case .delete: .delete
        case .assign: .assign
        case .add: .add
        case .undo: .undo
        case .note: .note
        }
    }

    /// Stored (and hashed) JSON text. Keys sorted; absent key = nil.
    var storedJSON: String {
        var d: [String: Any] = [:]
        switch self {
        case .delete, .undo: break
        case let .assign(c, p): d["category_id"] = c; d["project_id"] = p
        case let .add(l, c, p): d["label"] = l; d["category_id"] = c; d["project_id"] = p
        case let .note(t): d["text"] = t
        }
        let data = try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    init(op: EditOp, json: String) {
        let d = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let c = (d["category_id"] as? NSNumber)?.int64Value
        let p = (d["project_id"] as? NSNumber)?.int64Value
        switch op {
        case .delete: self = .delete
        case .assign: self = .assign(categoryId: c, projectId: p)
        case .add: self = .add(label: d["label"] as? String ?? "", categoryId: c, projectId: p)
        case .undo: self = .undo
        case .note: self = .note(text: d["text"] as? String ?? "")
        }
    }
}

/// App-side writes. One gesture = one `apply` = one IMMEDIATE transaction = one group = one undo step.
public struct EditWriter: Sendable {
    public let db: HoursDB
    public init(_ db: HoursDB) { self.db = db }

    /// Writes `drafts` as one group; returns the group id (seq of its first edit).
    /// Ranged edits are clamped to end at the live span's start (the live span isn't editable);
    /// a range that clamps to empty throws `.emptyRange`.
    @discardableResult
    public func apply(_ drafts: [EditDraft], createdMs: Int64? = nil,
                      tzId: String = TimeZone.current.identifier) throws -> Int64 {
        guard !drafts.isEmpty else { throw StoreError.emptyGroup }
        let createdMs = createdMs ?? storeNowMs()
        try storeCheckNul(tzId)
        for d in drafts {
            switch d.payload {
            case let .add(label, _, _): try storeCheckNul(label)
            case let .note(text): try storeCheckNul(text)
            default: break
            }
        }
        let grp = try db.writer.write { db -> Int64 in
            let liveStart = try Int64.fetchOne(db, sql: "SELECT start_ms FROM live_span WHERE id = 1")
            var grp: Int64?
            for d in drafts {
                var lo = d.loMs, hi = d.hiMs
                if let target = d.target {
                    let hull = try Row.fetchOne(db, sql: "SELECT MIN(lo_ms) lo, MAX(hi_ms) hi FROM edit WHERE grp = ?",
                                                arguments: [target])
                    guard let l: Int64 = hull?["lo"], let h: Int64 = hull?["hi"] else {
                        throw StoreError.unknownGroup(target)
                    }
                    lo = l; hi = h
                } else if let liveStart {
                    hi = min(hi, liveStart)
                }
                guard hi > lo else { throw StoreError.emptyRange }
                let seq = try Self.insert(db, grp: grp, createdMs: createdMs, tzId: tzId, op: d.op,
                                          lo: lo, hi: hi, target: d.target, payload: d.payload.storedJSON)
                if grp == nil { grp = seq }
            }
            return grp!
        }
        db.didCommit()
        return grp
    }

    static func insert(_ db: Database, grp: Int64?, createdMs: Int64, tzId: String, op: EditOp,
                       lo: Int64, hi: Int64, target: Int64?, payload: String) throws -> Int64 {
        let head = try Row.fetchOne(db, sql: "SELECT seq, hash FROM chain_head WHERE id = 1")!
        let seq: Int64 = head["seq"] + 1
        let prev: Data = head["hash"]
        let grp = grp ?? seq
        let blind = ChainCodec.newBlind()
        let content = ChainCodec.editContent(createdMs: createdMs, tzId: tzId, op: op.rawValue, loMs: lo, hiMs: hi,
                                             target: target, payload: payload, grp: grp, blind: blind)
        let hash = ChainCodec.rowHash(seq: seq, prev: prev, content: content)
        try db.execute(sql: """
            INSERT INTO edit(seq, grp, created_ms, tz_id, op, lo_ms, hi_ms, target, payload,
                             blind, content_hash, prev_hash, hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [seq, grp, createdMs, tzId, op.rawValue, lo, hi, target, payload, blind, content, prev, hash])
        return seq
    }
}
