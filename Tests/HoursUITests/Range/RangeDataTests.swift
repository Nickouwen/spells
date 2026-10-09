import Foundation
import Testing
import HoursCore
@testable import HoursUI

@Suite struct RangeDataTests {
    static let today = rd(2026, 10, 5)
    static let tz = TimeZone(identifier: "America/Vancouver")!
    static let min: Int64 = 60_000

    /// DemoData spans with chain seqs 1…n, as the store would assign (seq 0 means "live span").
    static func demoRaw(_ b: ClosedRange<LocalDate>) -> [RawSpan] {
        var raw = DemoData.spans(from: b.lowerBound, through: b.upperBound, tzId: tz.identifier)
        for i in raw.indices { raw[i].seq = Int64(i + 1) }
        return raw
    }

    /// Range totals are exactly Σ of per-day `DayMetrics`, each computed independently from that
    /// day's classified spans (the export's unit), and every group's rows sum to the total.
    @Test func totalsEqualSumOfIndependentDayMetrics() {
        let bounds = RangePeriod.previousBilling.bounds(today: Self.today)
        let raw = Self.demoRaw(bounds)
        let classifier = Classifier(categories: ClassifySeed.categories, rules: ClassifySeed.rules, projects: ClassifySeed.projects)
        let days = RangeData.bucket(effectiveSpans(raw: raw, edits: []), into: bounds)
        let data = RangeData.build(period: .previousBilling, bounds: bounds, edited: days, raw: days, classifier: classifier,
                                   categories: ClassifySeed.categories, projects: ClassifySeed.projects, timeZone: Self.tz)

        var tracked: Int64 = 0, work: Int64 = 0, billable: Int64 = 0, focus: Int64 = 0
        for (_, spans) in days {
            let m = DayMetrics.compute(spans: classifier.classifyAll(spans), categories: ClassifySeed.categories)
            tracked += m.trackedMs; work += m.workMs; billable += m.billableMs; focus += m.focusMs
        }
        #expect(tracked > 0)
        #expect(data.metrics.trackedMs == tracked)
        #expect(data.metrics.workMs == work)
        #expect(data.metrics.billableMs == billable)
        #expect(data.metrics.focusMs == focus)
        #expect(data.metrics.billable.reduce(0) { $0 + $1.ms } == billable)
        #expect(data.days.count == 15)
        for g in RangeGroup.allCases {
            let rows = data.rows(g)
            #expect(rows.reduce(0) { $0 + $1.trackedMs } == tracked, "\(g)")
            #expect(rows.reduce(0) { $0 + $1.daily.reduce(0, +) } == tracked, "\(g) daily")
        }
        #expect(data.billableByProject.reduce(0) { $0 + $1.ms } == billable)
        #expect(data.editCount == 0)
        #expect(data.gapDays.isEmpty)   // DemoData is gap-free
    }

    @Test func fixtureEditsAndGapsShowUp() {
        let data = RangeData.fixture(period: .previousBilling, today: Self.today)
        let weekdays = data.days.map(\.date).filter { !$0.isWeekend }
        #expect(data.editCount == 3)
        func day(_ m: RangeMetrics, _ d: LocalDate) -> DayMetrics { m.days.first { $0.date == d }!.metrics }

        // Manual add on weekday 5: 18:00–18:45, after the demo day ends, project 2, Meetings (work).
        let addDay = weekdays[5]
        let proj2 = { (m: DayMetrics) in m.byProject.first { $0.key == 2 }?.workMs ?? 0 }
        #expect(proj2(day(data.metrics, addDay)) - proj2(day(data.raw, addDay)) == 45 * Self.min)
        // Delete on weekday 4: 16:00–16:25, inside continuous active time.
        let delDay = weekdays[4]
        #expect(day(data.raw, delDay).trackedMs - day(data.metrics, delDay).trackedMs == 25 * Self.min)
        // Assign on weekday 1: 14:00–15:30 → Coding + project 6, so all 90 min there are billable to it.
        let asgDay = weekdays[1]
        #expect(day(data.metrics, asgDay).byProject.first { $0.key == 6 }!.workMs
                >= day(data.raw, asgDay).byProject.first { $0.key == 6 }?.workMs ?? 0)

        // Tracker gaps on weekdays 2 and 7 only, one each, inside the dropped windows.
        #expect(data.gapDays.map(\.date) == [weekdays[2], weekdays[7]])
        let g = data.gapDays[0].gaps
        #expect(g.count == 1)
        let lo = weekdays[2].dayInterval(in: Self.tz, dayStartHour: 0).lowerBound + 14 * 60 * Self.min
        #expect(g[0].lowerBound <= lo + 30 * Self.min && g[0].upperBound >= lo + 80 * Self.min)
        // Gaps never count as time.
        #expect(data.metrics.trackedMs == data.metrics.days.reduce(0) { $0 + $1.metrics.trackedMs })
    }

    @Test func gapsAreHolesOfFiveMinutesOrMore() {
        func s(_ a: Int64, _ b: Int64, _ k: SpanKind = .active) -> EffectiveSpan {
            EffectiveSpan(startMs: a * Self.min, endMs: b * Self.min, tzId: "UTC", kind: k, bundleId: nil, appName: "X",
                          title: nil, url: nil, rawSeq: 1)
        }
        // 2-min hole ignored; idle spans count as tracked coverage; 10-min hole is a gap; overlap-safe.
        let gaps = RangeData.gaps([s(0, 10), s(12, 20, .idle), s(30, 40), s(35, 38), s(42, 50)])
        #expect(gaps == [20 * Self.min..<30 * Self.min])
        #expect(RangeData.gaps([s(0, 10), s(15, 20)]) == [10 * Self.min..<15 * Self.min])   // exactly 5 min counts
    }

    @Test func bucketSplitsAtDayStartInEachSpansOwnZone() {
        let tz = TimeZone(identifier: "America/New_York")!
        let d = rd(2026, 10, 6)
        let start4 = d.dayInterval(in: tz).lowerBound   // 6 Oct 04:00 local
        let span = EffectiveSpan(startMs: start4 - 30 * Self.min, endMs: start4 + 30 * Self.min, tzId: tz.identifier,
                                 kind: .active, bundleId: nil, appName: "X", title: nil, url: nil, rawSeq: 1)
        let b = RangeData.bucket([span], into: rd(2026, 10, 5)...rd(2026, 10, 6))
        #expect(b[rd(2026, 10, 5)]?.map(\.durationMs) == [30 * Self.min])
        #expect(b[rd(2026, 10, 6)]?.map(\.durationMs) == [30 * Self.min])
        // Outside the bounds → dropped.
        #expect(RangeData.bucket([span], into: d...d)[rd(2026, 10, 5)] == nil)
    }

    /// `load` through a real store equals the pure build over the same spans — so the view's numbers
    /// come from the store's own day clipping, as export's do.
    @Test func loadFromStoreMatchesPureBuild() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hours-range-tests/\(UUID().uuidString)/hours.db")
        let db = try HoursDB.open(at: url, role: .tracker, notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bounds = RangePeriod.previousBilling.bounds(today: Self.today)
        let raw = Self.demoRaw(bounds)
        let writer = SpanWriter(db)
        for s in raw { _ = try writer.append(s) }

        let classifier = Classifier(categories: ClassifySeed.categories, rules: ClassifySeed.rules, projects: ClassifySeed.projects)
        let loaded = try RangeData.load(store: Store(db), classifier: classifier, categories: ClassifySeed.categories,
                                        projects: ClassifySeed.projects, period: .previousBilling, today: Self.today, timeZone: Self.tz)
        let days = RangeData.bucket(effectiveSpans(raw: raw, edits: []), into: bounds)
        let pure = RangeData.build(period: .previousBilling, bounds: bounds, edited: days, raw: days, classifier: classifier,
                                   categories: ClassifySeed.categories, projects: ClassifySeed.projects, timeZone: Self.tz)
        #expect(loaded.metrics.trackedMs > 0)
        #expect(loaded.metrics == pure.metrics)
        #expect(loaded.raw == loaded.metrics)
        #expect(loaded.editCount == 0)
        #expect(loaded.days.map(\.gaps) == pure.days.map(\.gaps))
        // Range shows the invoice figure: Σ of per-(day, project) rows rounded to 0.01 h = the export total.
        let export = try ExportPeriodData.load(db, period: ExportPeriod(from: bounds.lowerBound, through: bounds.upperBound))
        #expect(loaded.invoiceHundredths > 0)
        #expect(loaded.invoiceHundredths == export.totalHundredths)
        #expect(ExportPeriodData.hundredths(ms: 3_618_000) == 101)   // 1.005 h → 1.01 (half up)
        #expect(ExportPeriodData.hundredths(ms: 3_617_999) == 100)
    }
}
