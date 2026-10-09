import Foundation
import Testing
@testable import HoursCore

private typealias F = MetricsFixture
private let minute = F.minute

@Suite struct MetricsRangeTests {
    @Test func rangeIsSumOfDays() {
        let tue = LocalDate(year: 2026, month: 10, day: 6), wed = LocalDate(year: 2026, month: 10, day: 7)
        let wedSpans = [
            F.span(F.t(7, 9, 0), F.t(7, 9, 20), F.xcode, F.coding, project: F.projB),
            F.span(F.t(7, 9, 20), F.t(7, 9, 30), F.xcode, F.coding, project: F.projA),
        ]
        let r = RangeMetrics.compute(days: [wed: wedSpans, tue: F.dayA], categories: F.categories)

        #expect(r.days.map { $0.date } == [tue, wed])
        #expect(r.trackedMs == 230 * minute)
        #expect(r.workMs == 211 * minute)
        #expect(r.billableMs == 200 * minute)
        #expect(r.unassignedWorkMs == 11 * minute)
        #expect(r.focusMs == 140 * minute)               // 110 (Tue) + 30 (Wed, one session)
        #expect(r.focusSessionCount == 3)
        #expect(r.avgFocusSessionMs == 140 * minute / 3) // Σfocus / Σsessions, not mean of means
        #expect(r.focusRatio == 140.0 / 211.0)
        #expect(r.meetingMs == 60 * minute && r.meetingCount == 1)
        #expect(r.breakMs == 70 * minute)
        #expect(r.switches == 4)
        #expect(abs(r.switchesPerHour! - 4.0 / (230.0 / 60.0)) < 1e-9)

        #expect(r.billable == [
            .init(date: tue, projectId: F.projA, ms: 170 * minute),
            .init(date: wed, projectId: F.projA, ms: 10 * minute),
            .init(date: wed, projectId: F.projB, ms: 20 * minute),
        ])
        #expect(r.byProject == [
            .init(key: F.projA, trackedMs: 180 * minute, workMs: 180 * minute),
            .init(key: nil, trackedMs: 30 * minute, workMs: 11 * minute),
            .init(key: F.projB, trackedMs: 20 * minute, workMs: 20 * minute),
        ])
        #expect(r.byCategory.first == .init(key: F.coding.id, trackedMs: 140 * minute, workMs: 140 * minute))
    }

    @Test func monthOfSyntheticDaysSumsExactly() {
        var days: [LocalDate: [ClassifiedSpan]] = [:]
        for d in 1...30 { days[LocalDate(year: 2026, month: 9, day: d)] = F.synthetic(n: 200, day: 6, seed: UInt64(d)) }
        let r = RangeMetrics.compute(days: days, categories: F.categories)
        #expect(r.trackedMs == r.days.reduce(0) { $0 + $1.metrics.trackedMs })
        #expect(r.workMs == r.days.reduce(0) { $0 + $1.metrics.workMs })
        #expect(r.billable.reduce(0) { $0 + $1.ms } == r.billableMs)
        #expect(r.byCategory.reduce(0) { $0 + $1.trackedMs } == r.trackedMs)
        #expect(r.byApp.reduce(0) { $0 + $1.trackedMs } == r.trackedMs)
        #expect(r.byHost.reduce(0) { $0 + $1.trackedMs } == r.trackedMs)
        // Range day == standalone day computation.
        let sep1 = LocalDate(year: 2026, month: 9, day: 1)
        #expect(r.days[0].metrics == DayMetrics.compute(spans: days[sep1]!, categories: F.categories))
    }

    @Test func emptyRange() {
        let r = RangeMetrics.compute(days: [:], categories: F.categories)
        #expect(r.days.isEmpty && r.trackedMs == 0 && r.avgFocusSessionMs == nil && r.focusRatio == nil)
    }
}
