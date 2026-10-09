import Foundation
import Testing
import HoursCore
@testable import HoursUI

@Suite struct DayDataTests {
    /// The headline's roll value orders like the date (across month / year ends), so ← rolls down, → up.
    @Test func rollValueFollowsTheDate() {
        let days = [LocalDate(year: 2025, month: 12, day: 31), LocalDate(year: 2026, month: 1, day: 1),
                    LocalDate(year: 2026, month: 1, day: 31), LocalDate(year: 2026, month: 2, day: 1)]
        let v = days.map(DayHeadline.rollValue)
        #expect(zip(v, v.dropFirst()).allSatisfy { $0 < $1 })
        // The env value wins; without it, the caller's `countsDown` (default: today's plain roll).
        #expect(HeroNumber.roll(v[0], countsDown: true) == .numericText(value: v[0]))
        #expect(HeroNumber.roll(nil, countsDown: true) == .numericText(countsDown: true))
        #expect(HeroNumber.roll(nil) == .numericText())
    }

    @Test func fixtureBuilds() throws {
        let d = DayData.fixture()
        #expect(!d.spans.isEmpty)
        #expect(!d.isEmpty)
        #expect(!d.isToday && d.nowMs == nil && d.liveSpan == nil)
        #expect(d.metrics.workMs > 4 * 3_600_000)
        #expect(zip(d.spans, d.spans.dropFirst()).allSatisfy { $0.span.endMs <= $1.span.startMs })
        #expect(d.spans.allSatisfy { d.bounds.contains($0.span.startMs) })
        // The assign edit shows up as provenance and as a raw-vs-adjusted delta.
        #expect(d.spans.contains { !$0.span.editSeqs.isEmpty })
        let raw = try #require(d.rawWorkMs)
        #expect(raw != d.metrics.workMs)
        // Tracker gap 15:10–15:35 local becomes a gap block, not idle.
        let gap = try #require(DayTimeline.items(d).first { $0.kind == .gap })
        #expect(Fmt.clock(ms: gap.startMs, timeZone: d.timeZone) == "15:10")
        #expect(Fmt.clock(ms: gap.endMs, timeZone: d.timeZone) == "15:35")
        // Lunch idle (DemoData) is recorded idle, drawn hatched.
        #expect(DayTimeline.items(d).contains { $0.kind == .idle })
    }

    @Test func breaksSplitIntoAwayAndNotTracking() throws {
        let d = DayData.fixture()
        let at = { (h: Int, m: Int) in d.bounds.lowerBound + Int64((h - 4) * 3600 + m * 60) * 1000 }
        // The fixture's tracker gap (15:10–15:35) has no spans at all → not tracking.
        #expect(d.breakKind(DayMetrics.Break(startMs: at(15, 10), endMs: at(15, 35))) == .notTracking)
        // A gap the tracker recorded as idle → away.
        let idle = try #require(d.spans.first { $0.span.kind == .idle }?.span)
        #expect(d.breakKind(DayMetrics.Break(startMs: idle.startMs, endMs: idle.endMs)) == .away)
        // Exactly half idle still counts as away (idle ≥ half).
        #expect(d.breakKind(DayMetrics.Break(startMs: idle.endMs - 60_000, endMs: idle.endMs + 60_000)) == .away)
    }

    @Test func timelineAccessibilitySummary() {
        let d = DayData.fixture()
        let label = DayTimeline.accessibilitySummary(d, items: DayTimeline.items(d))
        let first = Fmt.clock(ms: d.metrics.firstActivityMs!, timeZone: d.timeZone)
        #expect(label.hasPrefix("Timeline, \(first) to "))
        #expect(label.contains("\(Fmt.durationSpoken(ms: d.metrics.trackedMs)) tracked"))
        #expect(label.hasSuffix(", 1 tracker gap"))   // the fixture's 15:10–15:35 cut
        #expect(DayTimeline.accessibilitySummary(.fixture(empty: true), items: []) == "Timeline, nothing tracked")
    }

    @Test func todayFixtureStopsAtNowWithLiveSpan() throws {
        let d = DayData.fixture(date: LocalDate(year: 2026, month: 10, day: 5), now: (14, 32))
        let now = try #require(d.nowMs)
        #expect(d.isToday)
        #expect(d.spans.allSatisfy { $0.span.endMs <= now })
        let live = try #require(d.liveSpan)
        #expect(live.span.rawSeq == 0 && live.span.endMs == now)
        #expect(DayTimeline.items(d).last?.isLive == true)
    }

    @Test func emptyFixture() {
        let d = DayData.fixture(empty: true)
        #expect(d.isEmpty)
        #expect(d.metrics.workMs == 0)
        #expect(DayWindow.fit(d).lengthMs == 10 * 3_600_000)
    }

    @Test func dayShiftCrossesMonthAndYear() {
        #expect(LocalDate(year: 2026, month: 10, day: 31).dayShift(1) == LocalDate(year: 2026, month: 11, day: 1))
        #expect(LocalDate(year: 2027, month: 1, day: 1).dayShift(-1) == LocalDate(year: 2026, month: 12, day: 31))
        #expect(LocalDate(year: 2028, month: 2, day: 28).dayShift(1) == LocalDate(year: 2028, month: 2, day: 29))
    }

    @Test func loadReadsTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hours-day-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try HoursDB.open(at: dir.appendingPathComponent("hours.db"), role: .app,
                                  notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
        let day = LocalDate(year: 2026, month: 10, day: 1)
        let tz = TimeZone(identifier: "America/Vancouver")!
        for s in DemoData.spans(from: day, through: day, tzId: tz.identifier) { _ = try SpanWriter(db).append(s) }
        let classifier = Classifier(categories: ClassifySeed.categories, rules: ClassifySeed.rules, projects: ClassifySeed.projects)
        let loaded = try DayData.load(store: Store(db), classifier: classifier, categories: ClassifySeed.categories,
                                      projects: ClassifySeed.projects, day: day, goal: nil,
                                      now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: tz)
        let fixture = DayData.fixture(date: day, trackerGap: false, edited: false, goal: nil)
        #expect(!loaded.isToday && loaded.rawWorkMs == nil)
        #expect(loaded.spans.count == fixture.spans.count)
        #expect(loaded.metrics.workMs == fixture.metrics.workMs)
    }
}
