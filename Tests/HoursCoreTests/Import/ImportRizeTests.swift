import CryptoKit
import Foundation
import Testing
@testable import HoursCore

/// Fixture in Rize's real API shapes (field names from the live GraphQL schema), fake values.
/// 2026-09-15, America/New_York (EDT, −04:00):
///   09:00–09:30, 09:30–10:00 Code                       → one 60 min block (project "spells" via time entry)
///   10:00–10:20 Google Chrome app + 10:00–10:10 github.com + 10:10–10:20 www.youtube.com
///                                                        → sites win, Chrome app event vanishes
///   10:20–10:30 Idle (Rize idle category)                → dropped
///   11:00–11:15 Slack (time entry → new project)
///   11:15–11:30 Finder (miscellaneous → Uncategorized, mapped)
///   11:30–11:40 Weird (sales → unmapped)
///   12:00–12:05 NoCat (absent from appsAndWebsites → no category)
/// Imported total 60+10+10+15+15+10+5 = 125 min; Rize trackedTime 7500 s.
let rizeFixture = """
{
  "format": "hours-rize-snapshot/1",
  "fetchedAt": "2026-10-05T22:00:00Z",
  "timezone": "America/New_York",
  "events": [
    {"appName": "Code", "title": "main.swift — spells", "url": null, "urlHost": null, "source": "macos", "startTime": "2026-09-15T09:00:00-04:00", "endTime": "2026-09-15T09:30:00-04:00"},
    {"appName": "Code", "title": "Model.swift — spells", "url": null, "urlHost": null, "source": "macos", "startTime": "2026-09-15T09:30:00-04:00", "endTime": "2026-09-15T10:00:00-04:00"},
    {"appName": "Google Chrome", "title": "GitHub", "url": null, "urlHost": null, "source": "macos", "startTime": "2026-09-15T10:00:00-04:00", "endTime": "2026-09-15T10:20:00-04:00"},
    {"appName": "Google Chrome", "title": "PR #1", "url": "https://github.com/x/y/pull/1", "urlHost": "github.com", "source": "chrome", "startTime": "2026-09-15T14:00:00Z", "endTime": "2026-09-15T14:10:00Z"},
    {"appName": "Google Chrome", "title": "video", "url": "https://www.youtube.com/watch?v=1", "urlHost": "www.youtube.com", "source": "chrome", "startTime": "2026-09-15T14:10:00.000Z", "endTime": "2026-09-15T14:20:00.000Z"},
    {"appName": "Idle", "title": null, "url": null, "urlHost": null, "source": "macos", "startTime": "2026-09-15T10:20:00-04:00", "endTime": "2026-09-15T10:30:00-04:00"},
    {"appName": "Slack", "title": "general", "url": null, "urlHost": null, "source": "macos", "startTime": "2026-09-15T11:00:00-04:00", "endTime": "2026-09-15T11:15:00-04:00"},
    {"appName": "Finder", "title": "Downloads", "url": null, "urlHost": null, "source": "macos", "startTime": "2026-09-15T11:15:00-04:00", "endTime": "2026-09-15T11:30:00-04:00"},
    {"appName": "Weird", "title": "x", "url": null, "urlHost": null, "source": "macos", "startTime": "2026-09-15T11:30:00-04:00", "endTime": "2026-09-15T11:40:00-04:00"},
    {"appName": "NoCat", "title": "x", "url": null, "urlHost": null, "source": "macos", "startTime": "2026-09-15T12:00:00-04:00", "endTime": "2026-09-15T12:05:00-04:00"},
    {"appName": "Code", "title": "zero", "url": null, "urlHost": null, "source": "macos", "startTime": "2026-09-15T13:00:00-04:00", "endTime": "2026-09-15T13:00:00-04:00"}
  ],
  "appsAndWebsites": {
    "2026-09-15": [
      {"appName": "Code", "url": null, "urlHost": null, "title": "Code", "type": "app", "timeSpent": 3600, "timeCategory": {"key": "code", "name": "Code", "idle": false, "work": true}},
      {"appName": "Google Chrome", "url": null, "urlHost": null, "title": "Google Chrome", "type": "app", "timeSpent": 60, "timeCategory": {"key": "browsing", "name": "Browsing", "idle": false, "work": false}},
      {"appName": null, "url": "https://github.com", "urlHost": "github.com", "title": "github.com", "type": "website", "timeSpent": 600, "timeCategory": {"key": "code", "name": "Code", "idle": false, "work": true}},
      {"appName": null, "url": "https://www.youtube.com", "urlHost": "youtube.com", "title": "youtube.com", "type": "website", "timeSpent": 600, "timeCategory": {"key": "entertainment", "name": "Entertainment", "idle": false, "work": false}},
      {"appName": "Idle", "url": null, "urlHost": null, "title": "Idle", "type": "app", "timeSpent": 600, "timeCategory": {"key": "idle", "name": "Idle", "idle": true, "work": false}},
      {"appName": "Slack", "url": null, "urlHost": null, "title": "Slack", "type": "app", "timeSpent": 900, "timeCategory": {"key": "messaging", "name": "Messaging", "idle": false, "work": true}},
      {"appName": "Finder", "url": null, "urlHost": null, "title": "Finder", "type": "app", "timeSpent": 900, "timeCategory": {"key": "miscellaneous", "name": "Miscellaneous", "idle": false, "work": false}},
      {"appName": "Weird", "url": null, "urlHost": null, "title": "Weird", "type": "app", "timeSpent": 600, "timeCategory": {"key": "sales", "name": "Sales", "idle": false, "work": true}}
    ]
  },
  "summaryBuckets": [
    {"date": "2026-09-15", "startTime": "2026-09-15T00:00:00-04:00", "endTime": "2026-09-16T00:00:00-04:00", "trackedTime": 7500}
  ],
  "timeEntries": [
    {"startTime": "2026-09-15T09:00:00-04:00", "endTime": "2026-09-15T10:00:00-04:00", "title": "build", "project": {"name": "spells"}, "client": null},
    {"startTime": "2026-09-15T11:00:00-04:00", "endTime": "2026-09-15T11:15:00-04:00", "title": "chat", "project": {"name": "Rize Only Project"}, "client": {"name": "Acme"}},
    {"startTime": "2026-09-15T12:00:00-04:00", "endTime": "2026-09-15T12:05:00-04:00", "title": "no project", "project": null, "client": null}
  ]
}
"""

private let min: Int64 = 60_000
/// 2026-09-15 09:00 EDT.
private let t9: Int64 = 1_789_477_200_000
private func at(_ minutesAfter9: Int64) -> Int64 { t9 + minutesAfter9 * min }

private func fixture() throws -> RizeSnapshot {
    try JSONDecoder().decode(RizeSnapshot.self, from: Data(rizeFixture.utf8))
}

private func writeFixture(_ json: String = rizeFixture) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "hours-import-tests/\(UUID().uuidString).json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: url)
    return url
}

/// Temp DB with the seed categories and projects, as the app seeds them on launch.
private func seededDB() throws -> HoursDB {
    let db = try storeTempDB(role: .app)
    let cfg = ConfigStore(db)
    for c in ClassifySeed.categories { try cfg.insert(c) }
    for p in ClassifySeed.projects { try cfg.insert(p) }
    return db
}

private func ev(_ app: String, _ start: String, _ end: String) -> RizeEvent {
    RizeEvent(appName: app, title: nil, url: nil, urlHost: nil, source: "macos", startTime: start, endTime: end)
}

@Suite struct ImportRizeTests {
    @Test func parsesRealShapesAndDigestsTheFileBytes() throws {
        let url = try writeFixture()
        let (snap, sha) = try RizeSnapshot.load(url)
        #expect(snap.events.count == 11)
        #expect(snap.appsAndWebsites["2026-09-15"]?.count == 8)
        #expect(snap.summaryBuckets.first?.trackedTime == 7500)
        #expect(snap.timeEntries[1].project?.name == "Rize Only Project")
        #expect(snap.tz.identifier == "America/New_York")
        #expect(sha == SHA256.hash(data: Data(rizeFixture.utf8)).map { String(format: "%02x", $0) }.joined())
        #expect(sha.count == 64)
        // Offsets, Z and fractional seconds all land on the same instant scale.
        #expect(try rizeMs("2026-09-15T09:00:00-04:00") == t9)
        #expect(try rizeMs("2026-09-15T13:00:00Z") == t9)
        #expect(try rizeMs("2026-09-15T13:00:00.500Z") == t9 + 500)
        #expect(try rizeMs("2026-09-15T18:30:00.25+05:30") == t9 + 250)
        #expect(try rizeMs("2024-02-29T00:00:00Z") == 1_709_164_800_000)     // leap day
        #expect(try rizeMs("1969-12-31T23:59:59Z") == -1000)
        #expect(throws: RizeImportError.self) { try rizeMs("15/09/2026") }
        // Wrong format id is refused.
        #expect(throws: RizeImportError.self) {
            try RizeSnapshot.load(try writeFixture(rizeFixture.replacingOccurrences(of: "hours-rize-snapshot/1", with: "other")))
        }
    }

    @Test func categoryMappingTable() {
        #expect(RizeCategoryMap.map("code") == (ClassifySeed.coding, true))
        #expect(RizeCategoryMap.map("video_conferencing") == (ClassifySeed.meetings, true))
        #expect(RizeCategoryMap.map("messaging") == (ClassifySeed.communication, true))
        #expect(RizeCategoryMap.map("social_media") == (ClassifySeed.social, true))
        #expect(RizeCategoryMap.map("browsing") == (nil, true))      // deliberately Uncategorized
        #expect(RizeCategoryMap.map("sales") == (nil, false))        // not in the table → unmapped
        // Every mapped target is a real seed category, never the Uncategorized/Excluded rows.
        let seedIds = Set(ClassifySeed.categories.map(\.id))
        for case let id? in RizeCategoryMap.table.values {
            #expect(seedIds.contains(id) && id != ClassifySeed.uncategorized && id != ClassifySeed.excluded)
        }
    }

    @Test func plansBlocksFromEvents() throws {
        let plan = try RizeImportPlanner.plan(try fixture())
        let shape = plan.blocks.map { [String($0.loMs), String($0.hiMs), $0.label, $0.categoryId.map(String.init) ?? "-",
                                       $0.rizeCategory ?? "-", $0.project ?? "-"] }
        let expected: [[String]] = [
            [String(at(0)), String(at(60)), "Rize · Code", "1", "code", "spells"],
            [String(at(60)), String(at(70)), "Rize · github.com", "1", "code", "-"],
            [String(at(70)), String(at(80)), "Rize · youtube.com", "10", "entertainment", "-"],
            [String(at(120)), String(at(135)), "Rize · Slack", "5", "messaging", "Rize Only Project"],
            [String(at(135)), String(at(150)), "Rize · Finder", "-", "miscellaneous", "-"],
            [String(at(150)), String(at(160)), "Rize · Weird", "-", "sales", "-"],
            [String(at(180)), String(at(185)), "Rize · NoCat", "-", "-", "-"],
        ]
        #expect(shape == expected)
        #expect(plan.events == 11)
        #expect(plan.sourceBlocks == 7)
        #expect(plan.totalMs == 125 * min)
        #expect(plan.idleMs == 10 * min)
        #expect(plan.rizeCategoryNames["sales"] == "Sales")
        #expect(plan.daily.count == 1)
        #expect(plan.daily[0].eventsMs == 125 * min && plan.daily[0].rizeMs == 7_500_000)
    }

    @Test func overlapWithTrackedTimeIsClippedNeverReplaced() throws {
        // A tracked span 09:20–09:40 splits the Code block; the live span from 11:10 caps everything after.
        let plan = try RizeImportPlanner.plan(try fixture(), tracked: [at(20)..<at(40), at(130)..<Int64.max])
        let code = plan.blocks.filter { $0.label == "Rize · Code" }.map { [$0.loMs, $0.hiMs] }
        #expect(code == [[at(0), at(20)], [at(40), at(60)]])
        #expect(plan.blocks.last.map { [$0.label, String($0.hiMs)] } == ["Rize · Slack", String(at(130))])
        let overlap: Int64 = (20 + 5 + 15 + 10 + 5) * min   // Code, Slack tail, Finder, Weird, NoCat
        #expect(plan.overlapMs == overlap)
        #expect(plan.overlapBlocks == 3)
        #expect(plan.clippedBlocks == 2)
        #expect(plan.totalMs == 125 * min - plan.overlapMs)
    }

    @Test func importIsIdempotentAndWritesManualAddsWithNotes() throws {
        let db = try seededDB()
        let url = try writeFixture()
        let (snap, sha) = try RizeSnapshot.load(url)
        // Hours already tracked 09:20–09:40.
        _ = try SpanWriter(db).append(RawSpan(seq: 0, startMs: at(20), endMs: at(40), tzId: "America/New_York", tzOffsetS: -14_400,
                                          kind: .active, bundleId: "com.microsoft.VSCode", appName: "Code", title: nil, url: nil))
        let importer = RizeImporter(db)
        let plan = try importer.plan(snap)
        #expect(plan.blocks.count == 8 && plan.overlapMs == 20 * min)
        #expect(try importer.missingProjects(plan) == ["Rize Only Project"])

        let r = try importer.apply(plan, snap: snap, sourceName: url.lastPathComponent, sha256: sha, nowMs: at(60 * 24 * 20))
        #expect(r.groups.count == 1 && r.blocks == 8 && r.ms == 105 * min)
        #expect(r.createdProjects == ["Rize Only Project"])
        #expect(try ChainVerifier.verify(db).ok)

        let edits = try Store(db).allEdits()
        #expect(edits.filter { $0.op == .add }.count == 8)
        #expect(Set(edits.filter { $0.op == .add }.map(\.grp)) == [r.groups[0]])
        let note = try #require(edits.last)
        #expect(note.target == r.groups[0])
        #expect(note.payload == .note(text: "Imported from Rize \(url.lastPathComponent) sha256:\(sha) on 2026-10-05"))
        #expect(note.tzId == "America/New_York")

        // The day reads back as manual Rize spans around the tracked one; nothing is a raw span.
        let spans = try Store(db).effectiveSpans(day: LocalDate(year: 2026, month: 9, day: 15))
        let manual = spans.filter { $0.source == .manual }
        #expect(manual.allSatisfy { $0.label!.hasPrefix("Rize · ") })
        #expect(manual.reduce(0) { $0 + $1.durationMs } == 105 * min)
        #expect(spans.filter { $0.source == .tracked }.map(\.durationMs) == [20 * min])
        let projects = try ConfigStore(db).projects()
        let hoursId = projects.first { $0.name == "spells" }?.id
        #expect(manual.first?.projectOverride == hoursId && hoursId != nil)
        #expect(manual.first?.categoryOverride == ClassifySeed.coding)
        #expect(manual.first { $0.label == "Rize · Slack" }?.projectOverride == projects.first { $0.name == "Rize Only Project" }?.id)

        // Second run: nothing new; the earlier import is recognised, the tracked overlap still reported.
        let again = try importer.plan(snap)
        #expect(again.blocks.isEmpty)
        #expect(again.alreadyImportedMs == 105 * min && again.overlapMs == 20 * min)
        #expect(again.alreadyImportedBlocks == 6 && again.overlapBlocks == 1)   // Code: part imported, part tracked
        #expect(try importer.apply(again, snap: snap, sourceName: "x", sha256: sha).groups.isEmpty)
        #expect(try Store(db).allEdits().count == edits.count)

        // Undoing the import makes it importable again (the store, not a side manifest, is the record).
        try EditWriter(db).apply([.undo(group: r.groups[0])])
        #expect(try importer.plan(snap).totalMs == 105 * min)
    }

    @Test func dstDaysAndMonthGroupsUseTheFourAmBoundary() throws {
        // 2026-11-01 02:00 falls back in New York, so the 04:00-bounded Oct 31 is the 25 h day; 03:30 EST still belongs to it.
        // Block 03:30–04:30 EST = 08:30–09:30Z; Hours day boundary 04:00 EST = 09:00Z.
        var snap = try fixture()
        snap.events = [ev("Code", "2026-11-01T08:30:00Z", "2026-11-01T09:30:00Z")]
        snap.timeEntries = []
        snap.summaryBuckets = []
        let db = try storeTempDB(role: .app)
        let r = try RizeImporter(db).apply(try RizeImporter(db).plan(snap), snap: snap, sourceName: "t", sha256: "0")
        // One block, one group (October: it starts on Oct 31's Hours day)…
        #expect(r.groups.count == 1 && r.blocks == 1)
        let oct31 = try Store(db).effectiveSpans(day: LocalDate(year: 2026, month: 10, day: 31))
        let nov1 = try Store(db).effectiveSpans(day: LocalDate(year: 2026, month: 11, day: 1))
        #expect(oct31.map(\.durationMs) == [30 * min])
        #expect(nov1.map(\.durationMs) == [30 * min])
        #expect(LocalDate(year: 2026, month: 10, day: 31).dayInterval(in: snap.tz).count == 25 * 3_600_000)

        // …and --since 2026-11-01 starts at 04:00 EST, cutting the block there.
        let since = try RizeImportPlanner.plan(snap, since: LocalDate(year: 2026, month: 11, day: 1))
        #expect(since.blocks.map { [$0.loMs, $0.hiMs] } == [[1_793_523_600_000, 1_793_525_400_000]])

        // Spring forward 2026-03-08 02:00: --since floor is 04:00 EDT = 08:00Z; the 23 h day is Mar 7.
        snap.events = [ev("Code", "2026-03-08T07:30:00Z", "2026-03-08T08:30:00Z")]
        let spring = try RizeImportPlanner.plan(snap, since: LocalDate(year: 2026, month: 3, day: 8))
        #expect(spring.blocks.map(\.loMs) == [1_772_956_800_000])
        #expect(LocalDate(year: 2026, month: 3, day: 7).dayInterval(in: snap.tz).count == 23 * 3_600_000)

        // Blocks on either side of a month's Hours boundary go to separate groups.
        snap.events = [ev("Code", "2026-11-01T08:00:00Z", "2026-11-01T08:30:00Z"), ev("Slack", "2026-11-01T09:00:00Z", "2026-11-01T09:30:00Z")]
        let db2 = try storeTempDB(role: .app)
        #expect(try RizeImporter(db2).apply(try RizeImporter(db2).plan(snap), snap: snap, sourceName: "t", sha256: "0").groups.count == 2)
        #expect(try ChainVerifier.verify(db2).ok)
    }

    @Test func sixMonthsOfEventsPlanQuickly() throws {
        // ~6 months × 500 switches/day; alternating apps so nothing coalesces.
        var snap = try fixture()
        let f = ISO8601DateFormatter()
        snap.events = (0..<90_000).map { i in
            let lo = Date(timeIntervalSince1970: Double(t9 / 1000) + Double(i) * 60)
            return ev(i % 2 == 0 ? "Code" : "Slack", f.string(from: lo), f.string(from: lo.addingTimeInterval(60)))
        }
        let clock = ContinuousClock()
        var plan: RizeImportPlan?
        let took = try clock.measure { plan = try RizeImportPlanner.plan(snap) }
        #expect(plan?.blocks.count == 90_000)
        if perfEnforced { #expect(took < .seconds(5), "planned 90k events in \(took)") }
    }

    @Test func intervalHelpers() {
        #expect(importMerge([5..<7, 1..<3, 2..<4, 7..<8, 9..<9]) == [1..<4, 5..<8])
        #expect(importSubtract(0..<10, [1..<2, 4..<6, 9..<12]) == [0..<1, 2..<4, 6..<9])
        #expect(importSubtract(3..<5, [0..<10]) == [])
        #expect(importOverlap(0..<10, [1..<2, 4..<6, 9..<12]) == 4)
    }
}
