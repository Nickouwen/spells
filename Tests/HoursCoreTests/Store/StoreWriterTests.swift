import Foundation
import GRDB
import Testing
@testable import HoursCore

@Suite struct StoreWriterTests {
    @Test func liveSpanLifecycle() throws {
        let db = try storeTempDB()
        let w = SpanWriter(db)
        try w.open(live: storeRaw(0, 1000, 1000, app: "A"))
        try w.heartbeat(lastSeenMs: 31000)
        #expect(try w.liveSpan()?.endMs == 31000)
        try w.heartbeat(lastSeenMs: 20000) // never moves backwards
        #expect(try w.liveSpan()?.endMs == 31000)

        try w.open(live: storeRaw(0, 40000, 40000, app: "B")) // closes A at B's start
        let live = try #require(try w.liveSpan())
        #expect(live.appName == "B" && live.seq == 0)
        let seq = try w.close(at: 50000, next: nil)
        #expect(seq == 2)
        #expect(try w.liveSpan() == nil)

        let rows = try Store(db).rawSpans(from: 0, to: 100_000)
        #expect(rows.map { [$0.seq, $0.startMs, $0.endMs] } == [[1, 1000, 40000], [2, 40000, 50000]])
        #expect(rows.map(\.appName) == ["A", "B"])
        #expect(try ChainVerifier.verify(db).ok)
    }

    @Test func zeroLengthCloseIsDropped() throws {
        let db = try storeTempDB()
        let w = SpanWriter(db)
        try w.open(live: storeRaw(0, 1000, 1000))
        #expect(try w.close(at: 1000, next: storeRaw(0, 1000, 1000, app: "N")) == nil)
        #expect(try w.liveSpan()?.appName == "N")
        #expect(try db.head().seq == 0)
    }

    /// Review-1 #1: a live span starting before the last chained end is clamped to it (dropped if
    /// nothing is left) instead of aborting on the overlap trigger; the live row is always replaced.
    @Test func closeClampsALiveSpanThatStartsBeforeTheChainEnd() throws {
        let db = try storeTempDB()
        let w = SpanWriter(db)
        try w.append(storeRaw(0, 0, 60_000, app: "P"))
        try w.open(live: storeRaw(0, 10_000, 10_000, app: "A"))
        #expect(try w.close(at: 30_000, next: storeRaw(0, 30_000, 30_000, app: "B")) == nil)   // wholly behind: dropped
        #expect(try w.liveSpan()?.appName == "B")
        try w.heartbeat(lastSeenMs: 50_000)
        #expect(try w.recoverLiveSpan() == nil)                                               // recovery clamps too
        #expect(try w.liveSpan() == nil)
        try w.open(live: storeRaw(0, 40_000, 40_000, app: "C"))
        #expect(try w.close(at: 75_000, next: nil) == 2)
        #expect(try Store(db).rawSpans(from: 0, to: 100_000).map { [$0.startMs, $0.endMs] } == [[0, 60_000], [60_000, 75_000]])
        #expect(try ChainVerifier.verify(db).ok)
    }

    @Test func crashRecoveryClosesAtLastHeartbeat() throws {
        let url = storeTempURL()
        do {
            let db = try storeTempDB(url: url)
            try SpanWriter(db).open(live: storeRaw(0, 1000, 1000, app: "A"))
            try SpanWriter(db).heartbeat(lastSeenMs: 31000)
        } // "crash": the process goes away with the live row in place
        let db = try storeTempDB(url: url)
        let w = SpanWriter(db)
        #expect(try w.recoverLiveSpan() == 1)
        #expect(try w.liveSpan() == nil)
        #expect(try w.recoverLiveSpan() == nil)
        #expect(try Store(db).rawSpans(from: 0, to: 100_000).map { [$0.startMs, $0.endMs] } == [[1000, 31000]])
    }

    @Test func nulBytesRejected() throws {
        let db = try storeTempDB()
        #expect(throws: StoreError.nulByte) {
            try SpanWriter(db).append(RawSpan(seq: 0, startMs: 0, endMs: 1, tzId: "UTC", tzOffsetS: 0, kind: .active,
                                              bundleId: nil, appName: "a\u{0}b", title: nil, url: nil))
        }
    }

    @Test func editGroupsUndoNoteAndClamp() throws {
        let db = try storeTempDB()
        let w = SpanWriter(db), e = EditWriter(db), store = Store(db)
        try w.append(storeRaw(0, 0, 100, app: "X"))
        try w.append(storeRaw(0, 100, 200, app: "Y"))

        let g = try e.apply([.delete(150, 170), .assign(20, 60, categoryId: 5, projectId: nil)], tzId: "UTC")
        #expect(g == 3)
        let u = try e.apply([.undo(group: g)])
        try e.apply([.note(group: g, text: "client asked")])
        let all = try store.allEdits()
        #expect(all.map(\.grp) == [3, 3, 5, 6])
        #expect(all[2].op == .undo && all[2].target == 3 && all[2].loMs == 20 && all[2].hiMs == 170) // group hull
        #expect(all[3].payload == .note(text: "client asked") && all[3].loMs == 20 && all[3].hiMs == 170)
        #expect(all[1].payload == .assign(categoryId: 5, projectId: nil))
        #expect(try store.effectiveSpans(rangeFrom: 0, to: 200).map(\.storeShape) == [[0, 100, 1, nil], [100, 200, 2, nil]])

        try e.apply([.undo(group: u)]) // redo
        #expect(try store.effectiveSpans(rangeFrom: 0, to: 200).count == 5)

        // Live span starts at 300: an edit reaching past it is clamped to end there.
        try w.open(live: storeRaw(0, 300, 400, app: "L"))
        let c = try e.apply([.add(250, 500, label: "meeting")])
        let clamped = try #require(try store.allEdits().last)
        #expect(clamped.seq == c && clamped.loMs == 250 && clamped.hiMs == 300)
        #expect(throws: StoreError.emptyRange) { try e.apply([.delete(310, 390)]) }
        #expect(throws: StoreError.emptyGroup) { try e.apply([]) }

        let eff = try store.effectiveSpans(rangeFrom: 0, to: 1000)
        #expect(eff.last?.rawSeq == 0 && eff.last?.startMs == 300 && eff.last?.endMs == 400) // live, untouched
        #expect(eff.dropLast().last?.label == "meeting")
        #expect(try ChainVerifier.verify(db).ok)
    }

    @Test func configCRUD() throws {
        let db = try storeTempDB(role: .app)
        let c = ConfigStore(db)
        let cid = try c.insert(Category(id: 0, key: "coding", name: "Coding", level: .productive, isWork: true,
                                        behavior: .normal, colorSlot: 2, sort: 1))
        var cat = try #require(try c.categories().first)
        #expect(cat.id == cid && cat.key == "coding" && cat.level == .productive && cat.isWork && cat.colorSlot == 2)
        cat.name = "Code"; cat.archived = true; cat.key = "ignored"
        try c.update(cat)
        #expect(try c.categories(includeArchived: false).isEmpty)
        #expect(try c.categories().first.map { [$0.name, $0.key] } == ["Code", "coding"])

        let pid = try c.insert(Project(id: 0, name: "hours", client: "ExampleCo"))
        try c.update(Project(id: pid, name: "hours", client: nil, archived: true))
        #expect(try c.projects() == [Project(id: pid, name: "hours", client: nil, archived: true)])

        let rid = try c.insert(Rule(id: 0, origin: .seed, seedKey: "xcode", bundleId: "com.apple.dt.Xcode",
                                    categoryId: cid), nowMs: 10)
        #expect(try c.rules().first == Rule(id: rid, origin: .seed, seedKey: "xcode", bundleId: "com.apple.dt.Xcode",
                                             categoryId: cid))
        var r = try c.rules()[0]; r.priority = 5
        try c.update(r, nowMs: 20)
        #expect(try c.rules()[0].priority == 5 && c.rulesRevision() == 20)
        try c.deleteRule(id: rid, nowMs: 30)
        #expect(try c.rules().isEmpty && c.rules(includeDeleted: true).count == 1 && c.rulesRevision() == 30)

        // At least one predicate and one target.
        #expect(throws: DatabaseError.self) { try c.insert(Rule(id: 0, origin: .user, categoryId: cid)) }
        #expect(throws: DatabaseError.self) { try c.insert(Rule(id: 0, origin: .user, host: "x.com")) }
    }

    @Test func settings() throws {
        let db = try storeTempDB()
        let s = SettingStore(db)
        #expect(try s.get("install_id")?.count == 36)
        try s.set("idle_threshold_s", "300")
        try s.set("idle_threshold_s", "240")
        #expect(try s.get("idle_threshold_s") == "240")
        try s.set("idle_threshold_s", nil)
        #expect(try s.get("idle_threshold_s") == nil)
        #expect(try s.all().keys.sorted() == ["install_id"])
    }

    @Test func pragmasAndSchemaVersion() throws {
        let url = storeTempURL()
        let db = try storeTempDB(url: url)
        let (mode, version, fk) = try db.writer.read { db in
            (try String.fetchOne(db, sql: "PRAGMA journal_mode")!, try Int.fetchOne(db, sql: "PRAGMA user_version")!,
             try Int.fetchOne(db, sql: "PRAGMA foreign_keys")!)
        }
        #expect(mode == "wal" && version == StoreSchema.latestVersion && fk == 1)
        try db.writer.write { try $0.execute(sql: "PRAGMA user_version = 99") }
        #expect(throws: StoreError.schemaTooNew(found: 99, known: StoreSchema.latestVersion)) {
            _ = try storeTempDB(role: .app, url: url)
        }
    }

    @Test func changeFeedFiresOnWrite() async throws {
        let db = try storeTempDB()
        let stream = ChangeFeed.stream(name: db.notifyName)
        let got = Task {
            for await _ in stream { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(50)) // let the registration land
        try SpanWriter(db).append(storeRaw(0, 0, 10))
        let timeout = Task { try await Task.sleep(for: .seconds(1)); got.cancel() }
        #expect(await got.value)
        timeout.cancel()
    }
}
