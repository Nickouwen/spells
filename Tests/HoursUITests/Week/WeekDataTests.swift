import Foundation
import Testing
import HoursCore
@testable import HoursUI

@Suite struct WeekDataTests {
    static let min: Int64 = 60_000
    static let hour: Int64 = 3_600_000
    static let classifier = Classifier(categories: ClassifySeed.categories, rules: ClassifySeed.rules, projects: ClassifySeed.projects)

    /// Week totals are exactly Σ of per-day `DayMetrics`, each computed independently from that
    /// day's classified spans; the stacked bars add up to each day's work; the heatmap to each day's work.
    @Test func totalsEqualSumOfDayMetrics() {
        let data = WeekData.fixture()
        let tz = TimeZone(identifier: "America/Vancouver")!
        #expect(data.dates.count == 7 && data.monday == rd(2026, 9, 28) && data.sunday == rd(2026, 10, 4))

        // Independent recomputation: fixture's raw spans per day, no edits (the fixture's one edit is a +45 m add).
        var raw = DemoData.spans(from: data.monday, through: data.sunday, tzId: tz.identifier)
        let wed = rd(2026, 9, 30)
        let lo = wed.dayInterval(in: tz, dayStartHour: 0).lowerBound
        raw.removeAll { (lo + 14 * Self.hour..<lo + 15 * Self.hour + 20 * Self.min).contains($0.startMs) }
        for i in raw.indices { raw[i].seq = Int64(i + 1) }
        let days = RangeData.bucket(effectiveSpans(raw: raw, edits: []), into: data.monday...data.sunday)
        var work: Int64 = 0, focus: Int64 = 0, meeting: Int64 = 0, billable: Int64 = 0, tracked: Int64 = 0
        for (_, spans) in days {
            let m = DayMetrics.compute(spans: Self.classifier.classifyAll(spans), categories: ClassifySeed.categories)
            work += m.workMs; focus += m.focusMs; meeting += m.meetingMs; billable += m.billableMs; tracked += m.trackedMs
        }
        #expect(work > 20 * Self.hour)
        #expect(data.range.raw.workMs == work)
        #expect(data.range.raw.focusMs == focus)
        #expect(data.range.raw.meetingMs == meeting)
        #expect(data.range.raw.billableMs == billable)
        #expect(data.range.raw.trackedMs == tracked)
        // Edited = raw + the 45 min manual meeting (work, billable to project 2).
        #expect(data.metrics.workMs == work + 45 * Self.min)
        #expect(data.metrics.billableMs == billable + 45 * Self.min)
        #expect(data.workDeltaMs == 45 * Self.min)
        #expect(data.metrics.workMs == data.metrics.days.reduce(0) { $0 + $1.metrics.workMs })

        for (i, d) in data.dates.enumerated() {
            let bar = data.segments.filter { $0.day == i }
            #expect(bar.map { $0.hiMs - $0.loMs }.reduce(0, +) == data.workMs(d), "\(d)")
            #expect(bar.filter(\.isTop).count == (data.workMs(d) > 0 ? 1 : 0))
            #expect(data.heat[i].reduce(0, +) == data.workMs(d), "heat \(d)")
        }
        #expect(data.hasGap(wed) && !data.hasGap(rd(2026, 9, 29)))
    }

    @Test func goalWeekdaysAndPace() {
        let data = WeekData.fixture(goal: Goal(dailyWorkMs: 7 * Self.hour))   // Mon–Fri
        #expect(data.goalMs(rd(2026, 9, 28)) == 7 * Self.hour)
        #expect(data.goalMs(rd(2026, 10, 3)) == nil && data.goalMs(rd(2026, 10, 4)) == nil)   // weekend: no goal line
        #expect(data.weeklyTargetMs == 35 * Self.hour)
        #expect(data.paceTargetMs == 35 * Self.hour)   // past week: pace = full target
        #expect(data.goalDays.of == 5)
        #expect(data.goalDays.met == data.dates.filter { data.workMs($0) >= 7 * Self.hour && !$0.isWeekend }.count)

        // Current week, today = Thursday: three past scheduled days count, today only once met.
        let cur = WeekData.fixture(week: rd(2026, 10, 1), today: rd(2026, 10, 1))
        #expect(cur.isCurrentWeek)
        #expect(cur.paceTargetMs == 4 * 7 * Self.hour)
        #expect(cur.goalDays.of == 3 + (cur.goalMet(rd(2026, 10, 1)) ? 1 : 0))
        #expect(cur.workMs(rd(2026, 10, 2)) == 0 && cur.isFuture(rd(2026, 10, 2)))

        let none = WeekData.fixture(goal: nil)
        #expect(none.weeklyTargetMs == 0 && none.streak == 0 && none.goalMs(rd(2026, 9, 28)) == nil)
    }

    @Test func streakWalksBackAcrossWeeks() {
        // A 1-minute goal: every demo weekday meets it, so the streak = scheduled days in the walk.
        let data = WeekData.fixture(goal: Goal(dailyWorkMs: Self.min))
        let walked = (0...WeekData.streakLookbackDays).map { data.sunday.adding(days: -$0) }.filter { !$0.isWeekend }.count
        #expect(data.streak == walked)
        // An unreachable goal: zero.
        #expect(WeekData.fixture(goal: Goal(dailyWorkMs: 24 * Self.hour)).streak == 0)
    }

    @Test func heatLevels() {
        #expect(WeekData.heatLevel(0) == 0)
        #expect(WeekData.heatLevel(1) == 1)
        #expect(WeekData.heatLevel(12 * Self.min) == 1)
        #expect(WeekData.heatLevel(12 * Self.min + 1) == 2)
        #expect(WeekData.heatLevel(48 * Self.min) == 4)
        #expect(WeekData.heatLevel(60 * Self.min) == 5)
        #expect(Theme.heat.count == 6)
    }

    @Test func weekStartsMondayAcrossDST() {
        // US fall-back Sun 1 Nov 2026, US spring-forward Sun 8 Mar 2026, EU spring-forward Sun 29 Mar 2026.
        #expect(WeekData.weekStart(rd(2026, 11, 1)) == rd(2026, 10, 26))
        #expect(WeekData.weekStart(rd(2026, 11, 2)) == rd(2026, 11, 2))
        #expect(WeekData.weekStart(rd(2026, 3, 8)) == rd(2026, 3, 2))
        #expect(WeekData.weekStart(rd(2026, 3, 29)) == rd(2026, 3, 23))
        #expect(WeekData.weekStart(rd(2026, 3, 30)) == rd(2026, 3, 30))
        #expect(WeekData.weekStart(rd(2027, 1, 1)) == rd(2026, 12, 28))   // across a year end

        // Fall-back week in Los Angeles: Saturday's store day (31 Oct 04:00 → 1 Nov 04:00) is 25 h.
        // (Not Vancouver: BC is on permanent daylight time in current tzdata.)
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let data = WeekData.fixture(week: rd(2026, 10, 29), today: rd(2026, 11, 10), tzId: tz.identifier)
        #expect(data.dates == (26...31).map { rd(2026, 10, $0) } + [rd(2026, 11, 1)])
        let mon = data.monday.dayInterval(in: tz), nextMon = rd(2026, 11, 2).dayInterval(in: tz)
        #expect(nextMon.lowerBound - mon.lowerBound == 7 * 24 * Self.hour + Self.hour)
        #expect(data.weekNumber == 44)
    }

    /// A late-night span across the fall-back hour lands on Saturday's day, and its repeated 01:00
    /// hour folds into one heatmap cell without losing time.
    @Test func dstNightSpanStaysWhole() {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let sat = rd(2026, 10, 31)
        let start = sat.dayInterval(in: tz, dayStartHour: 0).lowerBound + 23 * Self.hour   // Sat 23:00 PDT
        let end = start + 4 * Self.hour                                                      // Sun 02:00 PST (wall: 3 h later)
        let span = EffectiveSpan(startMs: start, endMs: end, tzId: tz.identifier, kind: .active,
                                 bundleId: "com.apple.dt.Xcode", appName: "Xcode", title: "x", url: nil, rawSeq: 1)
        let bounds = rd(2026, 10, 26)...rd(2026, 11, 1)
        let b = RangeData.bucket([span], into: bounds)
        let range = RangeData.build(period: .custom(bounds.lowerBound, bounds.upperBound), bounds: bounds, edited: b, raw: b,
                                    classifier: Self.classifier, categories: ClassifySeed.categories,
                                    projects: ClassifySeed.projects, timeZone: tz)
        let data = WeekData.assemble(range: range, goal: nil, today: rd(2026, 11, 10), history: [:], dayStartHour: 4)
        #expect(data.workMs(sat) == 4 * Self.hour)
        let row = data.heat[5]
        #expect(row.reduce(0, +) == 4 * Self.hour)
        // Columns start at 04:00: 23:00 → col 19, 00:00 → 20, 01:00 → 21 (twice), 02:00 → none (span ends 02:00 PST).
        #expect(row[19] == Self.hour && row[20] == Self.hour && row[21] == 2 * Self.hour)
    }

    /// `load` through a real store equals the fixture-free pure build over the same spans.
    @Test func loadFromStoreMatchesPureBuild() throws {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let url = FileManager.default.temporaryDirectory.appending(path: "hours-week-tests/\(UUID().uuidString)/hours.db")
        let db = try HoursDB.open(at: url, role: .tracker, notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // The DST week plus two weeks before it, so the streak has history.
        let bounds = rd(2026, 10, 12)...rd(2026, 11, 1)
        var raw = DemoData.spans(from: bounds.lowerBound, through: bounds.upperBound, tzId: tz.identifier)
        for i in raw.indices { raw[i].seq = Int64(i + 1) }
        let writer = SpanWriter(db)
        for s in raw { _ = try writer.append(s) }

        let goal = Goal(dailyWorkMs: Self.min)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))!
        let data = try WeekData.load(store: Store(db), classifier: Self.classifier, categories: ClassifySeed.categories,
                                     projects: ClassifySeed.projects, week: rd(2026, 10, 30), goal: goal, now: now, timeZone: tz)
        #expect(data.monday == rd(2026, 10, 26) && data.today == rd(2026, 11, 5))
        let week = data.monday...data.sunday
        let days = RangeData.bucket(effectiveSpans(raw: raw, edits: []), into: week)
        let pure = RangeData.build(period: .custom(week.lowerBound, week.upperBound), bounds: week, edited: days, raw: days,
                                   classifier: Self.classifier, categories: ClassifySeed.categories,
                                   projects: ClassifySeed.projects, timeZone: tz)
        #expect(data.metrics.workMs > 0)
        #expect(data.metrics == pure.metrics)
        // Blocks mode input: the same per-day spans, so its blocks equal MetricsBlocks over the pure days.
        for d in data.dates {
            let mine = data.daySpans[d] ?? [], theirs = Self.classifier.classifyAll(days[d] ?? [])
            #expect(mine.map(\.span.startMs) == theirs.map(\.span.startMs), "\(d)")
            #expect(MetricsBlocks.compute(spans: mine, categories: ClassifySeed.categories, breakThresholdMs: 600_000)
                    == MetricsBlocks.compute(spans: theirs, categories: ClassifySeed.categories, breakThresholdMs: 600_000))
            #expect(data.blockThresholdMin[d] != nil)
        }
        #expect(data.nowMs == nil)   // now (5 Nov) is after the week
        // 15 demo weekdays (12 Oct – 30 Oct) all meet a 1-minute goal; the walk ends at Sunday 1 Nov.
        #expect(data.streak == 15)
    }
}
