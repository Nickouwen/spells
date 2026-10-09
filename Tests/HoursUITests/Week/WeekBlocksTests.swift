import Foundation
import Testing
import HoursCore
@testable import HoursUI

@Suite struct WeekBlocksTests {
    static let min: Int64 = 60_000
    static let hour: Int64 = 3_600_000
    static let tz = TimeZone(identifier: "America/Vancouver")!
    static let classifier = Classifier(categories: ClassifySeed.categories, rules: ClassifySeed.rules, projects: ClassifySeed.projects)

    /// The fixture week rebuilt independently: DemoData minus the Wed 14:00–15:20 hole, plus the Thu
    /// 18:00–18:45 manual add, bucketed into store days and classified.
    static func independentDays(_ mon: LocalDate) -> [LocalDate: [ClassifiedSpan]] {
        let sun = mon.adding(days: 6)
        func at(_ d: LocalDate, _ h: Int, _ m: Int) -> Int64 { d.dayInterval(in: tz, dayStartHour: 0).lowerBound + Int64(h * 60 + m) * min }
        var raw = DemoData.spans(from: mon, through: sun, tzId: tz.identifier)
        let wed = mon.adding(days: 2), thu = mon.adding(days: 3)
        raw.removeAll { (at(wed, 14, 0)..<at(wed, 15, 20)).contains($0.startMs) }
        for i in raw.indices { raw[i].seq = Int64(i + 1) }
        let seq = Int64(raw.count + 1)
        let add = Edit(seq: seq, grp: seq, createdMs: at(thu, 19, 0), tzId: tz.identifier, op: .add,
                       loMs: at(thu, 18, 0), hiMs: at(thu, 18, 45), target: nil,
                       payload: .add(label: "Client call — Alex", categoryId: ClassifySeed.meetings, projectId: 2))
        return RangeData.bucket(effectiveSpans(raw: raw, edits: [add]), into: mon...sun).mapValues { classifier.classifyAll($0) }
    }

    /// Per-day block count, average and longest (and the week totals) equal `MetricsBlocks.compute`
    /// over each day's spans, at the default threshold and at 30 min.
    @Test(arguments: [10, 30]) func perDayStatsMatchMetricsBlocks(_ threshold: Int) {
        let data = WeekData.fixture(thresholdMin: threshold)
        let wb = WeekBlocks.build(data)
        let days = Self.independentDays(data.monday)
        var n = 0, total: Int64 = 0, longest: Int64 = 0
        #expect(wb.days.map(\.date) == data.dates)
        for day in wb.days {
            let blocks = MetricsBlocks.compute(spans: days[day.date] ?? [], categories: ClassifySeed.categories,
                                               breakThresholdMs: Int64(threshold) * Self.min)
            let wall = blocks.map(\.wallMs)
            #expect(day.count == blocks.count, "\(day.date)")
            #expect(day.averageMs == (blocks.isEmpty ? nil : wall.reduce(0, +) / Int64(blocks.count)), "\(day.date)")
            #expect(day.longestMs == wall.max(), "\(day.date)")
            #expect(day.blocks == blocks)
            n += blocks.count; total += wall.reduce(0, +); longest = max(longest, wall.max() ?? 0)
        }
        #expect(n > 7)   // DemoData weekdays have several blocks each
        #expect(wb.count == n)
        #expect(wb.averageMs == total / Int64(n))
        #expect(wb.longestMs == longest)
        #expect(wb.breakMs == wb.days.flatMap(\.breaks).reduce(0) { $0 + $1.durationMs })
    }

    @Test func raisingTheThresholdNeverAddsBlocks() {
        let a = WeekBlocks.build(.fixture(thresholdMin: 5)), b = WeekBlocks.build(.fixture(thresholdMin: 120))
        for (x, y) in zip(a.days, b.days) { #expect(y.count <= x.count, "\(x.date)") }
        #expect(b.count < a.count)
    }

    /// The axis is the whole 04:00 day and covers every block on every day (by local clock).
    @Test func axisFitsTheWeek() {
        let wb = WeekBlocks.build(.fixture())
        #expect(wb.axis == 0..<24 * Self.hour)
        for day in wb.days {
            for b in day.blocks {
                #expect(wb.offset(b.startMs, day) >= wb.axis.lowerBound)
                #expect(wb.offset(b.endMs, day) <= wb.axis.upperBound)
            }
        }
        // Offsets are clock time after 04:00: 09:00 local on Monday is 5 h in.
        let mon = wb.days[0]
        let nine = mon.date.dayInterval(in: Self.tz, dayStartHour: 0).lowerBound + 9 * Self.hour
        #expect(wb.offset(nine, mon) == 5 * Self.hour)
        #expect(wb.hourLabel(5 * Self.hour) == "09:00" && wb.hourLabel(21 * Self.hour) == "01:00")

        let empty = WeekBlocks.build(.fixture(empty: true))
        #expect(empty.count == 0 && empty.averageMs == nil && empty.longestMs == nil)
        #expect(empty.axis == 0..<24 * Self.hour)
    }

    /// DST: offsets follow the wall clock, so 09:00 is 5 h in on a fall-back day too (LA, Sun 1 Nov 2026).
    @Test func offsetsFollowTheClockAcrossDST() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let data = WeekData.fixture(week: rd(2026, 10, 26), today: rd(2026, 11, 2), tzId: la.identifier)
        let wb = WeekBlocks.build(data)
        let sat = wb.days[5], sun = wb.days[6]
        #expect(sun.date == rd(2026, 11, 1))
        let sunNine = sun.date.dayInterval(in: la, dayStartHour: 0).lowerBound + 10 * Self.hour   // 25 h day: 09:00 is 10 h after midnight
        #expect(Fmt.clock(ms: sunNine, timeZone: la) == "09:00")
        #expect(wb.offset(sunNine, sun) == 5 * Self.hour)
        // Saturday's store day holds the repeated 01:00 hour; 03:00 Sunday is still 23 h on the clock.
        let satThree = sun.date.dayInterval(in: la, dayStartHour: 0).lowerBound + 4 * Self.hour
        #expect(Fmt.clock(ms: satThree, timeZone: la) == "03:00")
        #expect(wb.offset(satThree, sat) == 23 * Self.hour)
    }

    /// Clicking a block routes to Day, Blocks mode, with an instant inside that block selected; applying
    /// the route without a host hook stores the Day mode and opens the day.
    @Test func clickRoutesToDayBlocksSelection() throws {
        let data = WeekData.fixture()
        let wb = WeekBlocks.build(data)
        let tue = wb.days[1]
        let b = try #require(tue.blocks.dropFirst().first)
        let route = WeekBlockRoute.open(b, on: tue.date)
        #expect(route.day == rd(2026, 9, 29))
        #expect(route.mode == .blocks)
        #expect(b.contains(route.selectedMs))
        // The selection survives the Day view regrouping the same spans at the same threshold.
        let dayBlocks = MetricsBlocks.compute(spans: data.daySpans[tue.date] ?? [], categories: ClassifySeed.categories,
                                              breakThresholdMs: 10 * Self.min)
        #expect(dayBlocks.filter { $0.contains(route.selectedMs) } == [b])
        // The grid's hit test (by column + clock offset) finds the same block.
        #expect(wb.block(day: 1, atOffset: wb.offset(route.selectedMs, tue)) == b)

        let suite = "hours.test.weekblocks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DayMode.timeline.rawValue, forKey: DayMode.storageKey)
        var opened: LocalDate?
        route.apply(defaults: defaults) { opened = $0 }
        #expect(opened == tue.date)
        #expect(defaults.string(forKey: DayMode.storageKey).flatMap(DayMode.init(rawValue:)) == .blocks)
    }

    /// `load` takes each day's threshold from the store settings (`BlocksThreshold.minutes(for:settings:)`,
    /// weekday overrides included) and the Blocks viewport settings.
    @Test func loadReadsBlocksSettingsFromTheStore() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hours-weekblocks-tests/\(UUID().uuidString)/hours.db")
        let db = try HoursDB.open(at: url, role: .app, notifyName: "dev.nic.spells.test.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func load() throws -> WeekData {
            try WeekData.load(store: Store(db), classifier: Self.classifier, categories: ClassifySeed.categories,
                              projects: ClassifySeed.projects, week: rd(2026, 9, 28), goal: nil,
                              now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: Self.tz)
        }
        let plain = try load()
        #expect(plain.dates.allSatisfy { plain.blockThresholdMin[$0] == MetricsBlocks.defaultThresholdMin })
        #expect(plain.blockWindowHours == 18 && plain.blockWindowStartMin == 6 * 60)

        let s = SettingStore(db)
        try s.set(BlocksThreshold.defaultKey, "25")
        try s.set(BlocksThreshold.weekdayKey, BlocksThreshold.encode([7: 40]))   // Saturdays
        try s.set(BlocksThreshold.windowHoursKey, "12")
        try s.set(BlocksThreshold.windowStartKey, "07:30")
        let data = try load()
        #expect(data.blockThresholdMin[rd(2026, 9, 28)] == 25)
        #expect(data.blockThresholdMin[rd(2026, 10, 3)] == 40)
        #expect(data.blockWindowHours == 12 && data.blockWindowStartMin == 450)
    }

    /// The columns use the Day column's scale (visible height / 18 h) over the whole 04:00 day, scrolled
    /// by default to 06:00–24:00 — moved up for a block before 06:00.
    @Test func columnsShowThe18HourWindow() {
        let wb = WeekBlocks.build(.fixture())
        #expect(wb.axis == 0..<24 * Self.hour)
        #expect(wb.windowMs == 18 * Self.hour)
        #expect(wb.days.allSatisfy { d in d.blocks.allSatisfy { b in wb.offset(b.startMs, d) >= 2 * Self.hour + 20 * Self.min } })
        #expect(wb.top == 2 * Self.hour)   // 06:00
        #expect(WeekBlocksGrid.pxPerHour(wb) == BlocksGeometry.pxPerHour(windowHours: 18, zoom: 1))
        #expect(WeekBlocks.build(.fixture(empty: true)).top == 2 * Self.hour)

        var early = WeekData.fixture()
        early.blockWindowHours = 12
        early.blockWindowStartMin = 7 * 60
        let tue = early.dates[1]
        let lo = tue.dayInterval(in: Self.tz, dayStartHour: 0).lowerBound + 5 * Self.hour + 10 * Self.min   // 05:10
        let span = EffectiveSpan(startMs: lo, endMs: lo + 30 * Self.min, tzId: Self.tz.identifier, kind: .active, bundleId: nil,
                                 appName: "Xcode", title: nil, url: nil, categoryOverride: nil, projectOverride: nil,
                                 source: .tracked, rawSeq: 1, label: nil)
        early.daySpans[tue, default: []].insert(ClassifiedSpan(span: span, categoryId: ClassifySeed.coding, projectId: nil), at: 0)
        let e = WeekBlocks.build(early)
        #expect(e.windowMs == 12 * Self.hour)
        #expect(e.top == 0)   // 05:10 − 20 min → the 04:00 hour
    }

    /// The current week: future days have no blocks, today's spans stop at now, and now is on the axis.
    @Test func currentWeekStopsAtNow() {
        let data = WeekData.fixture(today: rd(2026, 10, 2), now: (15, 10))
        let wb = WeekBlocks.build(data)
        let fri = wb.days[4]
        let now = fri.date.dayInterval(in: Self.tz, dayStartHour: 0).lowerBound + 15 * Self.hour + 10 * Self.min
        #expect(data.nowMs == now)
        #expect(wb.days[5].count == 0 && wb.days[6].count == 0)
        #expect(fri.count > 0 && fri.blocks.allSatisfy { $0.endMs <= now })
        #expect(wb.axis.contains(wb.offset(now, fri)))
    }
}
