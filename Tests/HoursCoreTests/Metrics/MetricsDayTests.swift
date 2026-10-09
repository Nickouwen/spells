import Foundation
import Testing
@testable import HoursCore

private typealias F = MetricsFixture
private let minute = F.minute

private func day(_ spans: [ClassifiedSpan], goal: Goal? = nil) -> DayMetrics {
    DayMetrics.compute(spans: spans, categories: F.categories, goal: goal)
}

@Suite struct MetricsDayTests {
    // Plan 05 acceptance A.
    @Test func mixedDayA() {
        let m = day(F.dayA)
        #expect(m.trackedMs == 200 * minute)
        #expect(m.workMs == 181 * minute)
        #expect(m.billableMs == 170 * minute)
        #expect(m.unassignedWorkMs == 11 * minute)
        #expect(m.byCategory.first { $0.key == F.entertainment.id }?.trackedMs == 19 * minute)

        #expect(m.focusSessions == [
            .init(startMs: F.t(6, 9, 0), endMs: F.t(6, 10, 31), activeMs: 90 * minute),
            .init(startMs: F.t(6, 13, 0), endMs: F.t(6, 13, 20), activeMs: 20 * minute),
        ])
        #expect(m.focusMs == 110 * minute)
        #expect(m.focusRatio == 110.0 / 181.0)

        #expect(m.breaks == [
            .init(startMs: F.t(6, 10, 31), endMs: F.t(6, 10, 41)),
            .init(startMs: F.t(6, 12, 0), endMs: F.t(6, 13, 0)),
        ])
        #expect(m.breakMs == 70 * minute)
        #expect(m.awayMs == 0)
        #expect(m.microPauseMs == 0)

        #expect(m.meetings == [.init(startMs: F.t(6, 11, 0), endMs: F.t(6, 12, 0), activeMs: 60 * minute)])
        #expect(m.meetingMs == 60 * minute)

        #expect(m.firstActivityMs == F.t(6, 9, 0))
        #expect(m.lastActivityMs == F.t(6, 13, 30))
        // Workday span invariant: end − start = tracked + breaks + micro + away.
        #expect(m.lastActivityMs! - m.firstActivityMs! == m.trackedMs + m.breakMs + m.microPauseMs + m.awayMs)

        #expect(m.switches == 4)
        #expect(abs(m.switchesPerHour! - 1.2) < 1e-9)

        // Breakdowns.
        #expect(m.byCategory.reduce(0) { $0 + $1.trackedMs } == m.trackedMs)
        #expect(m.byCategory.map { $0.key } == [F.coding.id, F.meetings.id, F.entertainment.id, F.communication.id])
        #expect(m.byProject == [
            .init(key: F.projA, trackedMs: 170 * minute, workMs: 170 * minute),
            .init(key: nil, trackedMs: 30 * minute, workMs: 11 * minute),
        ])
        #expect(m.byApp.map { $0.key.id } == [F.xcode, F.zoom, F.safari, F.mail, F.slack])
        #expect(m.byApp.first?.trackedMs == 110 * minute)
        #expect(m.byHost == [
            .init(key: nil, trackedMs: 181 * minute, workMs: 181 * minute),
            .init(key: "youtube.com", trackedMs: 19 * minute, workMs: 0),
        ])

        // Hourly (local clock hour): 9 → 60, 10 → 1+30+19 (work 31), 11 → 60, 12 → 0, 13 → 30.
        #expect(m.hourly.count == 24)
        #expect(m.hourly[9] == .init(trackedMs: 60 * minute, workMs: 60 * minute))
        #expect(m.hourly[10] == .init(trackedMs: 50 * minute, workMs: 31 * minute))
        #expect(m.hourly[11] == .init(trackedMs: 60 * minute, workMs: 60 * minute))
        #expect(m.hourly[12] == .init())
        #expect(m.hourly[13] == .init(trackedMs: 30 * minute, workMs: 30 * minute))
        #expect(m.hourly.reduce(0) { $0 + $1.trackedMs } == m.trackedMs)
    }

    // Plan 05 acceptance B (Tue day, clipped by the store to [Tue 04:00, Wed 04:00)).
    // Correction: the plan says billable 12600 s, but Finder has no project in the fixture → 12598 s.
    @Test func pastMidnightAndFlickerB() {
        let tue = day([
            F.span(F.t(6, 22, 0), F.t(6, 23, 0), F.xcode, F.coding, project: F.projB),
            F.span(F.t(6, 23, 0, 0), F.t(6, 23, 0, 2), F.finder, F.system),
            F.span(F.t(6, 23, 0, 2), F.t(7, 1, 30), F.xcode, F.coding, project: F.projB),
        ])
        #expect(tue.trackedMs == 12_600_000)
        #expect(tue.workMs == 12_600_000)
        #expect(tue.billableMs == 12_598_000)
        #expect(tue.firstActivityMs == F.t(6, 22, 0))
        #expect(tue.lastActivityMs == F.t(7, 1, 30))
        #expect(tue.focusSessions == [.init(startMs: F.t(6, 22, 0), endMs: F.t(7, 1, 30), activeMs: 12_598_000)])
        #expect(tue.focusSessions[0].wallMs == 12_600_000)
        #expect(tue.focusMs == 12_598_000)
        #expect(tue.focusRatio == 12_598.0 / 12_600.0)
        #expect(tue.switches == 0)
        #expect(tue.breaks.isEmpty)
        // Past-midnight time lands in local hours 0 and 1.
        #expect(tue.hourly[0].trackedMs == 60 * minute)
        #expect(tue.hourly[1].trackedMs == 30 * minute)

        let wed = day([F.span(F.t(7, 9, 0), F.t(7, 9, 20), F.xcode, F.coding, project: F.projB)])
        #expect(wed.trackedMs == 1_200_000)
        #expect(wed.focusSessions == [.init(startMs: F.t(7, 9, 0), endMs: F.t(7, 9, 20), activeMs: 1_200_000)])
    }

    // Plan 05 acceptance C.
    @Test func rizeAlternationC() {
        let m = day(F.dayC)
        #expect(m.trackedMs == 60 * minute)
        #expect(m.workMs == 60 * minute)
        #expect(m.focusSessions.isEmpty)
        #expect(m.focusMs == 0)
        #expect(m.switches == 59)
        #expect(m.switchesPerHour == 59)
        #expect(m.breaks.isEmpty)
    }

    @Test func focusMinimumBoundary() {
        let s = F.t(6, 9, 0)
        #expect(day([F.span(s, s + 14 * minute, F.xcode, F.coding)]).focusSessions.isEmpty)
        #expect(day([F.span(s, s + 15 * minute, F.xcode, F.coding)]).focusSessions.count == 1)
    }

    @Test func recursiveSplitKeepsTheSolidPart() {
        // 09:00–09:20 solid Xcode, then 09:20–10:00 alternating Slack/Xcode (Xcode on odd minutes).
        // Merged run: focus 40 / wall 60 < 75 % → split at the earliest widest gap (09:20→09:21):
        // left 20 min solid → session; right peels down to pieces < 15 min focus → nothing.
        var spans = [F.span(F.t(6, 9, 0), F.t(6, 9, 20), F.xcode, F.coding)]
        for i in 0..<40 {
            let s = F.t(6, 9, 20) + Int64(i) * minute
            spans.append(i % 2 == 0 ? F.span(s, s + minute, F.slack, F.communication) : F.span(s, s + minute, F.xcode, F.coding))
        }
        let m = day(spans)
        #expect(m.focusSessions == [.init(startMs: F.t(6, 9, 0), endMs: F.t(6, 9, 20), activeMs: 20 * minute)])
    }

    @Test func toleranceGapIsExactly120s() {
        let s = F.t(6, 9, 0)
        let within = day([F.span(s, s + 10 * minute, F.xcode, F.coding),
                          F.span(s + 10 * minute + 120_000, s + 20 * minute, F.xcode, F.coding)])
        #expect(within.focusSessions.count == 1)
        let beyond = day([F.span(s, s + 10 * minute, F.xcode, F.coding),
                          F.span(s + 10 * minute + 120_001, s + 20 * minute, F.xcode, F.coding)])
        #expect(beyond.focusSessions.isEmpty)   // two 10-min runs, each < 15 min
    }

    @Test func excludedIdleAndUncategorized() {
        let s = F.t(6, 9, 0)
        let m = day([
            F.span(s, s + 30 * minute, F.xcode, F.coding, project: F.projA),
            F.span(s + 30 * minute, s + 40 * minute, "com.apple.loginwindow", F.excluded, project: F.projA),
            F.idle(s + 40 * minute, s + 50 * minute),
            F.span(s + 50 * minute, s + 60 * minute, "com.example.unknown", nil, project: F.projA),
        ])
        #expect(m.trackedMs == 40 * minute)           // excluded + idle never count
        #expect(m.workMs == 30 * minute)              // Uncategorized is tracked, not work
        #expect(m.billableMs == 30 * minute)          // project on non-work time isn't billable
        #expect(m.breaks == [.init(startMs: s + 30 * minute, endMs: s + 50 * minute)])   // excluded time is a gap
        #expect(m.byCategory.map { $0.key } == [F.coding.id, nil])
        #expect(m.byProject == [.init(key: F.projA, trackedMs: 40 * minute, workMs: 30 * minute)])
    }

    @Test func gapThresholds() {
        let s = F.t(6, 9, 0)
        let m = day([
            F.span(s, s + 20 * minute, F.xcode, F.coding),
            F.span(s + 20 * minute + 299_999, s + 40 * minute, F.xcode, F.coding),            // micro-pause
            F.span(s + 45 * minute, s + 60 * minute, F.xcode, F.coding),                      // exactly 5 min → break
            F.span(s + 60 * minute + 180 * minute, s + 300 * minute, F.xcode, F.coding),         // exactly 180 min → away
        ])
        #expect(m.microPauseMs == 299_999)
        #expect(m.breaks == [.init(startMs: s + 40 * minute, endMs: s + 45 * minute)])
        #expect(m.awayMs == 180 * minute)
        #expect(m.lastActivityMs! - m.firstActivityMs! == m.trackedMs + m.breakMs + m.microPauseMs + m.awayMs)
    }

    @Test func strayWakeUpIgnoredForWorkdayStart() {
        let m = day([
            F.span(F.t(6, 5, 0), F.t(6, 5, 5), F.mail, F.communication),     // 5 min, then ≥ 3 h away
            F.span(F.t(6, 9, 0), F.t(6, 12, 0), F.xcode, F.coding),
        ])
        #expect(m.firstActivityMs == F.t(6, 9, 0))
        #expect(m.lastActivityMs == F.t(6, 12, 0))
        // Only stray blocks → fall back to all activity.
        let lone = day([F.span(F.t(6, 5, 0), F.t(6, 5, 5), F.mail, F.communication)])
        #expect(lone.firstActivityMs == F.t(6, 5, 0))
        #expect(day([]).firstActivityMs == nil)
    }

    @Test func meetingMergeAndMinimum() {
        let s = F.t(6, 11, 0)
        let m = day([
            F.span(s, s + 10 * minute, F.zoom, F.meetings),
            F.span(s + 11 * minute, s + 20 * minute, F.zoom, F.meetings),          // 60 s gap → same meeting
            F.span(s + 30 * minute, s + 30 * minute + 90_000, F.zoom, F.meetings), // 90 s alone → dropped
        ])
        #expect(m.meetings == [.init(startMs: s, endMs: s + 20 * minute, activeMs: 19 * minute)])
        #expect(m.meetingMs == 19 * minute)
        #expect(m.focusSessions.isEmpty)   // meetings never count as focus
    }

    @Test func switchesKeyOnHostForBrowsers() {
        let s = F.t(6, 9, 0)
        let m = day([
            F.span(s, s + 10 * minute, F.safari, F.coding, url: "https://github.com/a/b"),
            F.span(s + 10 * minute, s + 20 * minute, F.safari, F.coding, url: "https://github.com/c/d"), // same host
            F.span(s + 20 * minute, s + 30 * minute, F.safari, F.entertainment, url: "https://www.youtube.com/"),
            F.span(s + 30 * minute, s + 40 * minute, F.xcode, F.coding),
        ])
        #expect(m.switches == 2)
        #expect(m.byHost.map { $0.key } == ["github.com", "youtube.com", nil])
    }

    @Test func switchRateNeedsHalfAnHour() {
        let s = F.t(6, 9, 0)
        let m = day([F.span(s, s + 10 * minute, F.xcode, F.coding), F.span(s + 10 * minute, s + 20 * minute, F.slack, F.communication)])
        #expect(m.switches == 1)
        #expect(m.switchesPerHour == nil)
    }

    @Test func goalProgress() {
        let m = day(F.dayA, goal: Goal(dailyWorkMs: 362 * minute))
        #expect(m.goalProgress == 0.5)
        #expect(day(F.dayA).goalProgress == nil)
    }

    @Test func emptyDay() {
        let m = day([])
        #expect(m.trackedMs == 0 && m.focusRatio == nil && m.switchesPerHour == nil && m.focusSessions.isEmpty)
    }

    @Test func syntheticInvariants() {
        let m = day(F.synthetic(n: 1000, day: 6))
        #expect(m.byCategory.reduce(0) { $0 + $1.trackedMs } == m.trackedMs)
        #expect(m.byApp.reduce(0) { $0 + $1.trackedMs } == m.trackedMs)
        #expect(m.byHost.reduce(0) { $0 + $1.trackedMs } == m.trackedMs)
        #expect(m.hourly.reduce(0) { $0 + $1.trackedMs } == m.trackedMs)
        let projectWork = m.byProject.filter { $0.key != nil }.reduce(0) { $0 + $1.workMs }
        #expect(projectWork == m.billableMs)
        #expect(m.billableMs + m.unassignedWorkMs == m.workMs)
        #expect(m.focusMs <= m.workMs)
    }
}
