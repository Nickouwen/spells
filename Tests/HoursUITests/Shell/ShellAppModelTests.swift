import Foundation
import Testing
import HoursCore
@testable import HoursUI

@MainActor
@Suite struct ShellAppModelTests {
    @Test func seedingIsIdempotent() throws {
        let model = try shellTempModel()
        let config = ConfigStore(model.db)
        #expect(try config.categories().count == ClassifySeed.categories.count)
        #expect(try config.projects().count == ClassifySeed.projects.count)
        #expect(try config.rules().count == ClassifySeed.rules.count)
        let revision = try config.rulesRevision()

        // Second launch writes nothing.
        #expect(try ShellSeed.run(config) == 0)
        #expect(try config.rulesRevision() == revision)

        // User choices survive a re-seed: rename, disabled seed rule, deleted seed rule.
        var coding = try #require(try config.categories().first { $0.key == "coding" })
        coding.name = "Building"
        try config.update(coding)
        var first = try config.rules()[0]
        first.enabled = false
        try config.update(first)
        let second = try config.rules()[1].id
        try config.deleteRule(id: second)

        #expect(try ShellSeed.run(config) == 0)
        #expect(try config.categories().first { $0.key == "coding" }?.name == "Building")
        #expect(try config.rules().first { $0.id == first.id }?.enabled == false)
        #expect(try config.rules().contains { $0.id == second } == false)
        #expect(try config.rules(includeDeleted: true).count == ClassifySeed.rules.count)

        // A whole new model on the same DB (relaunch) also changes nothing.
        let again = try AppModel(db: model.db, paths: model.paths, timeZone: model.timeZone)
        #expect(again.categories.count == ClassifySeed.categories.count)
        #expect(try config.rulesRevision() > revision)  // only the user edits above moved it
        let rev2 = try config.rulesRevision()
        _ = try AppModel(db: model.db, paths: model.paths, timeZone: model.timeZone)
        #expect(try config.rulesRevision() == rev2)
    }

    @Test func changeFeedEventTriggersExactlyOneRefetch() async throws {
        let model = try shellTempModel()
        model.setVisible(true)
        #expect(await shellWait { model.refetchCount >= 1 })
        try await Task.sleep(for: .milliseconds(300))   // let any launch-time notifications drain
        let before = model.refetchCount

        ChangeFeed.post(name: model.db.notifyName)
        #expect(await shellWait { model.refetchCount == before + 1 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.refetchCount == before + 1)

        // Hidden: the subscription is cancelled, so a write costs nothing.
        model.setVisible(false)
        ChangeFeed.post(name: model.db.notifyName)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.refetchCount == before + 1)
    }

    @Test func configEditRebuildsClassifier() async throws {
        let model = try shellTempModel()
        model.setVisible(true)
        #expect(await shellWait { model.refetchCount >= 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.classifierBuilds == 1)

        // A non-config change refetches without rebuilding.
        let before = model.refetchCount
        ChangeFeed.post(name: model.db.notifyName)
        #expect(await shellWait { model.refetchCount == before + 1 })
        #expect(model.classifierBuilds == 1)

        // A rule written by anyone (here: straight through ConfigStore) arrives via the feed.
        let rule = Rule(id: 0, origin: .user, host: "example.org", categoryId: ClassifySeed.research)
        try ConfigStore(model.db).insert(rule)
        #expect(await shellWait { model.classifierBuilds == 2 })
        let key = ClassifyKey(bundleId: "com.google.Chrome", appName: "Chrome", title: nil, url: "https://example.org/x")
        #expect(model.classifier.resolve(key).categoryId == ClassifySeed.research)
        model.setVisible(false)
    }

    @Test func loadsSelectedDayFromStore() async throws {
        let model = try shellTempModel(seedDemo: 0...3)
        await model.refetch()
        let day = try #require(model.dayData)
        #expect(day.date == LocalDate(year: 2026, month: 10, day: 5))
        #expect(day.isToday)
        #expect(day.metrics.trackedMs > 0)
        #expect(day.tracker == model.health)

        model.step(days: 1)   // never past today
        #expect(model.selectedDay == LocalDate(year: 2026, month: 10, day: 5))
        model.step(days: -3)
        #expect(await shellWait { model.dayData?.date == LocalDate(year: 2026, month: 10, day: 2) })
        #expect(model.dayData?.isToday == false)
        model.view = .range
        #expect(await shellWait { model.rangeData != nil })
        #expect(model.rangeData?.bounds == LocalDate(year: 2026, month: 10, day: 1)...LocalDate(year: 2026, month: 10, day: 15))
    }

    /// The minute tick refetches with a fresh clock; today's DayData carries it as `nowMs`.
    @Test func nowTickReachesTodaysDayData() async throws {
        let clock = ShellTestClock(shellMs(2026, 10, 5, 15, tz: TimeZone(identifier: "America/Vancouver")!))
        let model = try shellTempModel(clock: clock)
        await model.refetch()
        #expect(model.dayData?.nowMs == clock.ms)
        clock.ms += 60_000
        await model.refetch()   // what each tick does
        #expect(model.dayData?.nowMs == clock.ms)
    }

    @Test func exportWritesTimesheet() async throws {
        let model = try shellTempModel(seedDemo: 0...20)
        let out = try await model.export("previous", mode: .plain)
        #expect(out.dir.lastPathComponent == "2026-09-16_2026-09-30")
        #expect(FileManager.default.fileExists(atPath: out.dir.appending(path: "timesheet.csv").path))
        #expect(out.summary.contains("h billable"))
        await #expect(throws: (any Error).self) { try await model.export("someday", mode: .plain) }
    }

    /// Pause/Resume from the app is a settings write the helper picks up live (W16).
    @Test func pauseAndResumeWriteTheSharedSetting() async throws {
        let tz = TimeZone(identifier: "America/Vancouver")!
        let clock = ShellTestClock(shellMs(2026, 10, 5, 15, tz: tz))
        let model = try shellTempModel(clock: clock)
        await model.pause(minutes: 15)
        #expect(model.pausedUntilMs == clock.ms + 900_000)
        #expect(try SettingStore(model.db).get(TrackerPauseSetting.key) == String(clock.ms + 900_000))
        await model.pauseUntilTomorrow()
        #expect(model.pausedUntilMs == shellMs(2026, 10, 6, 4, tz: tz))   // next 04:00 day start
        await model.setPause(untilMs: nil)
        #expect(model.pausedUntilMs == nil)
        #expect(try SettingStore(model.db).get(TrackerPauseSetting.key) == nil)

        await model.setConsultantName("  Example User ")
        #expect(model.consultantName == "Example User")
        await model.setConsultantName("")
        #expect(model.consultantName == NSFullUserName())
    }

    @Test func settingsWritesRoundTrip() async throws {
        let model = try shellTempModel()
        await model.setGoal(Goal(dailyWorkMs: 7 * 3_600_000, weekdays: [2, 4, 6]))
        #expect(model.goal == Goal(dailyWorkMs: 7 * 3_600_000, weekdays: [2, 4, 6]))
        await model.setGoal(nil)
        #expect(model.goal == nil)

        #expect(model.idleThresholdS == 300)
        await model.setIdleThreshold(seconds: 600)
        #expect(model.idleThresholdS == 600)

        await model.addProject(name: "acme-site", client: "Acme", autoRule: true)
        let p = try #require(model.projects.first { $0.name == "acme-site" })
        #expect(p.client == "Acme")
        #expect(model.rules.contains { $0.projectId == p.id && $0.titleRegex != nil })
    }
}
