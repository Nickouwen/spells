import Foundation
import GRDB
import Testing
@testable import HoursCore

@Suite struct StoreChainTests {
    // Same rows as scripts/chain_ref.py ROWS; hex pinned there too.
    static let installId = "00000000-0000-4000-8000-000000000000"
    static let pinned = (
        genesis: "a332ef1cf7cba74977129b36364744d46aeb4740da62a0170de019a042cc9efa",
        content: ["7bb235b1068286d7139193a8fe13c648a6380094e7aa35f8ecedbff63836e93a",
                  "a27e16fa1b78693ecad93222221cc00e42a9c396577246879bc58efd8d540897",
                  "a99a57abf99e17ff45d83284e99372a84a9e3de2a212a4d644e63277a3165f98",
                  "241dd57495af270acb9a987f561bbf7e16339afbb2d7f2dce4b878b42a40ef7b"],
        hash: ["6a17e1292d92f6bbd5c02317effe811f0922b4ad53094ab97f717fa8378c44d2",
               "1a07147fd7b5f5471721240553e0f49ccbb5fb65dec7e4a2c122d3cbaf114f43",
               "4a36797d87885458afec1d741a8643537ea1ce6eaed2a89409405ffb584dda11",
               "161cc362a25116a3a1da66981c459fbf222bd63da15f6e9911751326a7c411c5"])

    /// Fixed nonces of the vector rows (same as chain_ref.py ROWS "blind").
    static let blinds = ["000102030405060708090a0b0c0d0e0f", "101112131415161718191a1b1c1d1e1f",
                         "202122232425262728292a2b2c2d2e2f", "303132333435363738393a3b3c3d3e3f"].map { exportUnhex($0)! }

    /// pub_hash / priv_hash of the same rows, built from the split API (cross-checked against chain_ref.py).
    static func swiftPubPriv() -> (pub: [String], priv: [String]) {
        let pubs = [
            ChainCodec.spanPublic(startMs: 1772944200000, endMs: 1772944260000, tzId: "America/New_York",
                                  tzOffsetS: -18000, kind: "active", bundleId: "com.apple.dt.Xcode", appName: "Xcode"),
            ChainCodec.spanPublic(startMs: 1772944260000, endMs: 1772944320000, tzId: "Europe/Amsterdam",
                                  tzOffsetS: 3600, kind: "idle", bundleId: nil, appName: "Safari"),
            ChainCodec.editPublic(createdMs: 1772944400000, tzId: "America/New_York", op: "assign",
                                  loMs: 1772944200000, hiMs: 1772944320000, target: nil, grp: 3),
            ChainCodec.editPublic(createdMs: 1772944500000, tzId: "America/New_York", op: "note",
                                  loMs: 1772944200000, hiMs: 1772944320000, target: 3, grp: 4),
        ]
        let privs = [
            ChainCodec.spanPrivate(pub: pubs[0], blind: blinds[0], title: "Store.swift — hours ✓", url: nil),
            ChainCodec.spanPrivate(pub: pubs[1], blind: blinds[1], title: nil, url: "https://example.com/a"),
            ChainCodec.editPrivate(pub: pubs[2], blind: blinds[2], payload: #"{"category_id":5}"#),
            ChainCodec.editPrivate(pub: pubs[3], blind: blinds[3], payload: #"{"text":"client call"}"#),
        ]
        return (pubs.map(\.storeHex), privs.map(\.storeHex))
    }

    static func swiftVector() -> (genesis: String, content: [String], hash: [String]) {
        let contents = [
            ChainCodec.spanContent(startMs: 1772944200000, endMs: 1772944260000, tzId: "America/New_York",
                                   tzOffsetS: -18000, kind: "active", bundleId: "com.apple.dt.Xcode", appName: "Xcode",
                                   title: "Store.swift — hours ✓", url: nil, blind: blinds[0]),
            ChainCodec.spanContent(startMs: 1772944260000, endMs: 1772944320000, tzId: "Europe/Amsterdam",
                                   tzOffsetS: 3600, kind: "idle", bundleId: nil, appName: "Safari", title: nil,
                                   url: "https://example.com/a", blind: blinds[1]),
            ChainCodec.editContent(createdMs: 1772944400000, tzId: "America/New_York", op: "assign",
                                   loMs: 1772944200000, hiMs: 1772944320000, target: nil,
                                   payload: #"{"category_id":5}"#, grp: 3, blind: blinds[2]),
            ChainCodec.editContent(createdMs: 1772944500000, tzId: "America/New_York", op: "note",
                                   loMs: 1772944200000, hiMs: 1772944320000, target: 3,
                                   payload: #"{"text":"client call"}"#, grp: 4, blind: blinds[3]),
        ]
        let genesis = ChainCodec.genesis(installId: installId)
        var prev = genesis
        var hashes: [String] = []
        for (i, c) in contents.enumerated() {
            prev = ChainCodec.rowHash(seq: Int64(i + 1), prev: prev, content: c)
            hashes.append(prev.storeHex)
        }
        return (genesis.storeHex, contents.map(\.storeHex), hashes)
    }

    @Test func goldenVectorMatchesPinned() {
        let v = Self.swiftVector()
        #expect(v.genesis == Self.pinned.genesis)
        #expect(v.content == Self.pinned.content)
        #expect(v.hash == Self.pinned.hash)
    }

    @Test func goldenVectorMatchesPythonReference() throws {
        let script = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../scripts/chain_ref.py").standardizedFileURL
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/env")
        p.arguments = ["python3", script.path, "--vector"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let py = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let v = Self.swiftVector()
        #expect(py["genesis"] as? String == v.genesis)
        #expect(py["content"] as? [String] == v.content)
        #expect(py["hash"] as? [String] == v.hash)
        let pp = Self.swiftPubPriv()
        #expect(py["pub"] as? [String] == pp.pub)
        #expect(py["priv"] as? [String] == pp.priv)
        // The split API composes to the same content hashes as the one-shot API.
        let tags = [ChainCodec.spanTag, ChainCodec.spanTag, ChainCodec.editTag, ChainCodec.editTag]
        #expect((0..<4).map { ChainCodec.content(tag: tags[$0], pub: exportUnhex(pp.pub[$0])!, priv: exportUnhex(pp.priv[$0])!).storeHex }
                == v.content)
    }

    /// 3 spans + 3 edits interleaved: seq 1,2 spans · 3 edit · 4 span · 5 (2-edit group).
    func seeded() throws -> HoursDB {
        let db = try storeTempDB()
        let w = SpanWriter(db), e = EditWriter(db)
        try w.append(storeRaw(0, 0, 100))
        try w.append(storeRaw(0, 100, 200, app: "Y"))
        try e.apply([.assign(0, 150, categoryId: 1, projectId: nil)], createdMs: 1000)
        try w.append(storeRaw(0, 200, 300, app: "Z"))
        try e.apply([.delete(10, 20), .note(group: 3, text: "fix")], createdMs: 2000)
        return db
    }

    @Test func writeAndVerify() throws {
        let db = try seeded()
        let r = try ChainVerifier.verify(db)
        #expect(r.ok && r.rows == 6)
        #expect(try db.head().seq == 6)
        let grps = try db.writer.read { try Int64.fetchAll($0, sql: "SELECT grp FROM edit ORDER BY seq") }
        #expect(grps == [3, 5, 5])
    }

    @Test(arguments: [
        ("UPDATE span SET title = 'x' WHERE seq = 2", "span_ro_u", Int64(2), "content_hash mismatch"),
        ("UPDATE edit SET payload = '{\"category_id\":2}' WHERE seq = 3", "edit_ro_u", 3, "content_hash mismatch"),
        ("UPDATE span SET hash = zeroblob(32) WHERE seq = 4", "span_ro_u", 4, "hash mismatch"),
        ("DELETE FROM span WHERE seq = 2", "span_ro_d", 2, "missing row"),
        ("DELETE FROM edit WHERE seq = 6", "edit_ro_d", 6, "chain_head mismatch"),
    ])
    func tamperFailsAtThatSeq(sql: String, trigger: String, seq: Int64, reason: String) throws {
        let db = try seeded()
        try db.writer.write { db in
            try db.execute(sql: "DROP TRIGGER \(trigger)")
            try db.execute(sql: sql)
        }
        let r = try ChainVerifier.verify(db)
        #expect(r.firstBadSeq == seq)
        #expect(r.reason == reason)
    }

    /// Blinding: identical titles never share a priv_hash, and it can't be confirmed by hashing a guess.
    @Test func identicalTitlesGetDifferentPrivHash() throws {
        // Codec level: same public fields, same title — only the nonce differs.
        let pub = ChainCodec.spanPublic(startMs: 0, endMs: 60_000, tzId: "UTC", tzOffsetS: 0, kind: "active",
                                        bundleId: "com.google.Chrome", appName: "Google Chrome")
        let a = ChainCodec.newBlind(), b = ChainCodec.newBlind()
        #expect(a.count == 16 && a != b)
        let pa = ChainCodec.spanPrivate(pub: pub, blind: a, title: "YouTube", url: "https://www.youtube.com/watch")
        let pb = ChainCodec.spanPrivate(pub: pub, blind: b, title: "YouTube", url: "https://www.youtube.com/watch")
        #expect(pa != pb)
        // A guess without the nonce (e.g. an all-zero one) doesn't reproduce the digest.
        #expect(ChainCodec.spanPrivate(pub: pub, blind: Data(count: 16), title: "YouTube",
                                       url: "https://www.youtube.com/watch") != pa)

        // Store level: two chained rows with the same title get distinct nonces, and the live span keeps its own.
        let db = try storeTempDB()
        let w = SpanWriter(db)
        let yt = { (s: Int64, e: Int64) in RawSpan(seq: 0, startMs: s, endMs: e, tzId: "UTC", tzOffsetS: 0, kind: .active,
                                                  bundleId: "com.google.Chrome", appName: "Google Chrome",
                                                  title: "YouTube", url: "https://www.youtube.com/watch") }
        try w.append(yt(0, 100))
        try w.append(yt(100, 200))
        try w.open(live: yt(200, 200))
        let liveBlind = try db.writer.read { try Data.fetchOne($0, sql: "SELECT blind FROM live_span")! }
        try w.close(at: 300, next: nil)
        let rows = try db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT start_ms, end_ms, blind FROM span ORDER BY seq")
        }
        let blinds = rows.map { $0["blind"] as Data }
        #expect(Set(blinds).count == 3 && blinds.allSatisfy { $0.count == 16 })
        #expect(blinds[2] == liveBlind)   // the live span's nonce carries over when it's chained
        let privs = rows.map { r -> Data in
            let p = ChainCodec.spanPublic(startMs: r["start_ms"], endMs: r["end_ms"], tzId: "UTC", tzOffsetS: 0,
                                          kind: "active", bundleId: "com.google.Chrome", appName: "Google Chrome")
            return ChainCodec.spanPrivate(pub: p, blind: r["blind"], title: "YouTube", url: "https://www.youtube.com/watch")
        }
        #expect(Set(privs).count == 3)
        #expect(try ChainVerifier.verify(db).ok)
    }

    @Test func consistentRewriteStillBreaksNextLink() throws {
        // Rewrite row 2 with a self-consistent content+hash: row 3's prev_hash no longer matches.
        let db = try seeded()
        try db.writer.write { db in
            try db.execute(sql: "DROP TRIGGER span_ro_u")
            let prev = try Data.fetchOne(db, sql: "SELECT prev_hash FROM span WHERE seq = 2")!
            let blind = try Data.fetchOne(db, sql: "SELECT blind FROM span WHERE seq = 2")!
            let c = ChainCodec.spanContent(startMs: 100, endMs: 200, tzId: "UTC", tzOffsetS: 0, kind: "active",
                                           bundleId: "b.Y", appName: "Y", title: "forged", url: nil, blind: blind)
            try db.execute(sql: "UPDATE span SET title = 'forged', content_hash = ?, hash = ? WHERE seq = 2",
                           arguments: [c, ChainCodec.rowHash(seq: 2, prev: prev, content: c)])
        }
        let r = try ChainVerifier.verify(db)
        #expect(r.firstBadSeq == 3 && r.reason == "prev_hash mismatch")
    }

    @Test func anchors() throws {
        let db = try seeded()
        let a = AnchorStore(db)
        let head = try db.head()
        try a.insert(ChainAnchor(headSeq: head.seq, headHash: head.hash, method: "rfc3161", tsa: "digicert",
                                 requestedMs: 5, token: Data([1, 2])))
        #expect(try ChainVerifier.verify(db).ok)
        #expect(try a.list().map(\.headSeq) == [6])
        try a.insert(ChainAnchor(headSeq: 4, headHash: Data(count: 32), method: "rfc3161", requestedMs: 6))
        #expect(try ChainVerifier.verify(db) == VerifyResult(rows: 3, firstBadSeq: 4, reason: "anchor contradicts chain"))
    }

    @Test func anchorBeyondHeadIsTruncation() throws {
        let db = try seeded()
        try AnchorStore(db).insert(ChainAnchor(headSeq: 9, headHash: Data(count: 32), method: "m", requestedMs: 1))
        let r = try ChainVerifier.verify(db)
        #expect(r.firstBadSeq == 9 && r.reason == "anchor beyond head (truncated chain)")
    }

    @Test(arguments: [
        "UPDATE span SET title = 'x' WHERE seq = 1",
        "DELETE FROM span WHERE seq = 1",
        "UPDATE edit SET lo_ms = 1 WHERE seq = 3",
        "DELETE FROM edit WHERE seq = 3",
        "UPDATE anchor SET method = 'x'",
        "DELETE FROM anchor",
    ])
    func triggersAbortMutation(sql: String) throws {
        let db = try seeded()
        try AnchorStore(db).insert(ChainAnchor(headSeq: 6, headHash: try db.head().hash, method: "m", requestedMs: 1))
        #expect(throws: DatabaseError.self) { try db.writer.write { try $0.execute(sql: sql) } }
    }

    @Test func triggerAbortsStalePrevHash() throws {
        let db = try seeded()
        let err = #expect(throws: DatabaseError.self) {
            try db.writer.write { db in
                let stale = try Data.fetchOne(db, sql: "SELECT hash FROM span WHERE seq = 4")!
                try db.execute(sql: """
                    INSERT INTO span(seq, start_ms, end_ms, tz_id, tz_offset_s, kind, app_name, blind, content_hash, prev_hash, hash)
                    VALUES (7, 300, 400, 'UTC', 0, 'active', 'X', zeroblob(16), zeroblob(32), ?, zeroblob(32))
                    """, arguments: [stale])
            }
        }
        #expect(err?.message == "chain fork")
    }

    @Test func triggerAbortsOverlap() throws {
        let db = try seeded()
        let err = #expect(throws: DatabaseError.self) { try SpanWriter(db).append(storeRaw(0, 250, 350)) }
        #expect(err?.message == "overlap")
        #expect(try ChainVerifier.verify(db).ok)
    }

    @Test func triggerAbortsBadTargetAndGroup() throws {
        let db = try seeded()
        // Target 4 is a span seq, not an edit group.
        let bad = #expect(throws: DatabaseError.self) {
            try db.writer.write { db in
                _ = try EditWriter.insert(db, grp: nil, createdMs: 1, tzId: "UTC", op: .undo, lo: 0, hi: 10,
                                          target: 4, payload: "{}")
            }
        }
        #expect(bad?.message == "bad target")
        // Group id that isn't this seq and doesn't continue the previous edit's group.
        let grp = #expect(throws: DatabaseError.self) {
            try db.writer.write { db in
                _ = try EditWriter.insert(db, grp: 3, createdMs: 1, tzId: "UTC", op: .delete, lo: 0, hi: 10,
                                          target: nil, payload: "{}")
            }
        }
        #expect(grp?.message == "bad group")
        #expect(throws: StoreError.unknownGroup(99)) { try EditWriter(db).apply([.undo(group: 99)]) }
    }

    @Test func twoWritersInterleaveIntoOneChain() throws {
        let url = storeTempURL()
        let n = 5000
        // Two connections racing the very first open: the migration must run exactly once.
        let opened = StoreLockBox<[HoursDB]>([])
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            let db = try! storeTempDB(role: .tracker, url: url)
            opened.withLock { $0.append(db) }
        }
        let dbs = opened.withLock { $0 }
        let errors = StoreLockBox<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            do {
                if i == 0 {
                    let w = SpanWriter(dbs[0])
                    for k in 0..<n { try w.append(storeRaw(0, Int64(k) * 10, Int64(k) * 10 + 10)) }
                } else {
                    let e = EditWriter(dbs[1])
                    for k in 0..<n { try e.apply([.delete(Int64(k), Int64(k) + 1)], createdMs: Int64(k)) }
                }
            } catch { errors.withLock { $0.append("\(error)") } }
        }
        #expect(errors.withLock { $0 }.isEmpty)
        let (count, maxSeq) = try dbs[0].writer.read { db in
            (try Int64.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM span) + (SELECT COUNT(*) FROM edit)")!,
             try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM (SELECT seq FROM span UNION ALL SELECT seq FROM edit)")!)
        }
        #expect(count == Int64(2 * n) && maxSeq == Int64(2 * n))
        let r = try ChainVerifier.verify(dbs[0])
        #expect(r.ok && r.rows == Int64(2 * n))
        // ponytail: no interleaving assertion — it tests the scheduler, not the store (flaked 1 in 4).
    }
}

/// Minimal lock box for test bookkeeping across concurrentPerform iterations.
final class StoreLockBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
