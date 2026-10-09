import Foundation
import Observation
import HoursCore

public enum ShellView: String, CaseIterable, Identifiable, Sendable {
    case day, week, range, meetings
    public var id: String { rawValue }
    var title: String {
        switch self { case .day: "Day"; case .week: "Week"; case .range: "Range"; case .meetings: "Meetings" }
    }
    var symbol: String {
        switch self {
        case .day: "sun.max"; case .week: "calendar"; case .range: "calendar.badge.clock"; case .meetings: "person.2.wave.2"
        }
    }
}

/// The running app's state: DB, config, classifier, selection, loaded view data, tracker health.
/// Refreshes on store changes (`ChangeFeed`), app activation and selection changes — never by
/// polling. While the window is hidden the feed subscription is cancelled; showing it again does
/// one catch-up read. The only timer is the ≤ 1/min "now" tick while today's Day view is visible.
@MainActor @Observable
public final class AppModel {
    public let db: HoursDB
    public let paths: SupportPaths
    public let timeZone: TimeZone

    public private(set) var categories: [HoursCore.Category] = []
    public private(set) var projects: [Project] = []
    public private(set) var rules: [Rule] = []
    public private(set) var settings: [String: String] = [:]
    public private(set) var classifier: Classifier
    public private(set) var goal: Goal?

    public var view: ShellView = .day { didSet { if view != oldValue { selectionChanged() } } }
    public var selectedDay: LocalDate { didSet { if selectedDay != oldValue { selectionChanged() } } }
    /// The Scry note shown in Meetings (nil = the newest).
    public var meetingNote: URL?
    var rangePeriod: ViewSlot.Period = ViewSlot.defaultPeriod { didSet { if rangePeriod != oldValue { selectionChanged() } } }
    public private(set) var today: LocalDate
    public private(set) var nowMs: Int64

    private(set) var dayData: ViewSlot.DayPayload?
    private(set) var weekData: ViewSlot.WeekPayload?
    private(set) var rangeData: ViewSlot.RangePayload?
    public private(set) var loadError: String?

    public private(set) var helperStatus: TrackerHelperStatus?
    public private(set) var health: TrackerHealth = .unknown
    public private(set) var isVisible = false

    /// Counters for tests and the "zero work while hidden" check.
    public private(set) var refetchCount = 0
    public private(set) var classifierBuilds = 0

    /// App-target hooks (ServiceManagement lives there): start/register the helper, open Login Items.
    public var ensureTracker: (@MainActor () async -> TrackerHelperStatus)?
    public var openLoginItems: (@MainActor () -> Void)?
    /// App-target switch for Incant (registers/unregisters its login item). nil = not bundled (tests).
    public var incant: SpellSwitch?
    /// App-target switch for Scry (meeting notes). nil = not bundled (tests).
    public var scry: SpellSwitch?
    /// W24: Jev client factory (reads the key lazily, only when there are misses). nil = no Jev requests
    /// (tests); `live()` sets it.
    public var jevClient: (@Sendable () -> JevClient?)?

    private var jevRevision = ""
    private var jevDebounce: Task<Void, Never>?
    private var jevRunning = false
    private var jevStopped = false
    private let changes: @Sendable () -> AsyncStream<Void>
    private let clock: @Sendable () -> Int64
    private var tzObserver: (any NSObjectProtocol)?
    private var feedTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var generation = 0

    /// Opens nothing itself: pass an open `.app` DB. Seeds config (idempotent) and builds the classifier.
    /// The default zone follows the system (`autoupdatingCurrent`); a zone change triggers a refetch.
    public init(db: HoursDB, paths: SupportPaths, timeZone: TimeZone = .autoupdatingCurrent,
                changes: (@Sendable () -> AsyncStream<Void>)? = nil,
                clock: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }) throws {
        self.db = db
        self.paths = paths
        self.timeZone = timeZone
        let name = db.notifyName
        self.changes = changes ?? { ChangeFeed.stream(name: name) }
        self.clock = clock
        let now = clock()
        let today = ShellCalendar.today(nowMs: now, in: timeZone)
        self.nowMs = now
        self.today = today
        self.selectedDay = today

        try ShellSeed.run(ConfigStore(db))
        let snap = try Self.readConfig(db)
        self.classifier = Classifier(categories: snap.categories, rules: snap.rules, projects: snap.projects,
                                     jev: try JevCacheStore(db).snapshot(nowMs: now))
        (categories, projects, rules, settings, jevRevision) = (snap.categories, snap.projects, snap.rules, snap.settings, snap.jevRevision)
        goal = ShellPrefs.goal(snap.settings)
        classifierBuilds = 1
        // Travel / DST-zone change: `today` and every day bound move. One notification, no polling.
        tzObserver = NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.timeZoneChanged() }
        }
    }

    private func timeZoneChanged() {
        NSTimeZone.resetSystemTimeZone()
        let wasToday = selectedDay == today
        nowMs = clock()
        today = ShellCalendar.today(nowMs: nowMs, in: timeZone)
        if wasToday { selectedDay = today }
        updateTick()
        Task { await refetch() }
    }

    /// Production entry: DB at `SupportPaths.current().db`, role `.app`.
    public static func live() throws -> AppModel {
        let paths = SupportPaths.current()
        try paths.createDirectories()
        let model = try AppModel(db: HoursDB.open(at: paths.db, role: .app), paths: paths)
        model.jevClient = { JevClient.live() }
        return model
    }

    // MARK: Lifecycle

    /// Window became visible / hidden (occlusion, minimise, app hide, window close).
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            subscribe()
            Task { await refetch() }   // one catch-up read
        } else {
            feedTask?.cancel(); feedTask = nil
        }
        updateTick()
    }

    /// App activated: refetch (another process may have written while we weren't listening).
    public func appDidActivate() {
        guard isVisible else { return }
        Task { await refetch() }
    }

    /// Launch: ask the app target to start/register the helper, then render its status.
    public func checkTracker() async {
        guard let ensureTracker else { return }
        helperStatus = await ensureTracker()
        await refetch()
    }

    private func subscribe() {
        guard feedTask == nil else { return }
        let stream = changes()   // registers now, so no write between here and the loop is missed
        feedTask = Task { [weak self] in
            for await _ in stream {
                guard let self, !Task.isCancelled else { return }
                await self.refetch()
            }
        }
    }

    private func selectionChanged() {
        updateTick()
        Task { await refetch() }
    }

    private var wantsTick: Bool { isVisible && view == .day && selectedDay == today }

    private func updateTick() {
        if !wantsTick { tickTask?.cancel(); tickTask = nil; return }
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                let wasToday = self.selectedDay == self.today
                await self.refetch()
                if wasToday && self.selectedDay != self.today { self.selectedDay = self.today }  // day rolled over
            }
        }
    }

    // MARK: Navigation

    /// Never past today (matches DayView's disabled "next" on today).
    public func step(days: Int) { selectedDay = min(selectedDay.shellShifted(by: days), today) }
    /// Meetings with that note selected (Blocks → a meeting during the block).
    public func openMeeting(_ url: URL) {
        meetingNote = url
        view = .meetings
    }

    public func goToday() {
        nowMs = clock()
        today = ShellCalendar.today(nowMs: nowMs, in: timeZone)
        selectedDay = today
    }

    // MARK: Refetch

    private struct ConfigSnapshot: Sendable {
        var categories: [HoursCore.Category]
        var projects: [Project]
        var rules: [Rule]
        var settings: [String: String]
        var jevRevision: String
    }

    private struct Fetched: Sendable {
        var config: ConfigSnapshot
        var classifier: Classifier?
        var day: ViewSlot.DayPayload?
        var week: ViewSlot.WeekPayload?
        var range: ViewSlot.RangePayload?
        var health: TrackerHealth
    }

    nonisolated private static func readConfig(_ db: HoursDB) throws -> ConfigSnapshot {
        let config = ConfigStore(db)
        return ConfigSnapshot(categories: try config.categories(), projects: try config.projects(),
                              rules: try config.rules(), settings: try SettingStore(db).all(),
                              jevRevision: try JevCacheStore(db).revision())
    }

    /// Re-reads config (rebuilding the classifier only if it changed), the visible view's data and
    /// tracker health — off the main actor. Stale results (a newer refetch started) are dropped.
    public func refetch() async {
        generation += 1
        let gen = generation
        let now = clock()
        let today = ShellCalendar.today(nowMs: now, in: timeZone)
        let (db, view, day, period, tz) = (self.db, self.view, self.selectedDay, self.rangePeriod, self.timeZone)
        let current = ConfigSnapshot(categories: categories, projects: projects, rules: rules, settings: settings,
                                     jevRevision: jevRevision)
        let currentClassifier = classifier

        let result: Result<Fetched, any Error> = await Task.detached(priority: .userInitiated) {
            Result {
                let config = try Self.readConfig(db)
                let changed = config.categories != current.categories || config.projects != current.projects
                    || config.rules != current.rules || config.jevRevision != current.jevRevision
                    || JevSettings(config.settings) != JevSettings(current.settings)
                let classifier = changed
                    ? Classifier(categories: config.categories, rules: config.rules, projects: config.projects,
                                 jev: try JevCacheStore(db).snapshot(nowMs: now))
                    : currentClassifier
                let live = try SpanWriter(db).liveSpan()
                let recent = try Store(db).rawSpans(from: now - 12 * 3_600_000, to: now).filter { $0.seq != 0 }
                let health = ShellHealth.health(live: live, recent: recent.sorted { $0.startMs < $1.startMs },
                                                state: TrackerState.decode(config.settings[TrackerState.key]), nowMs: now)
                let ctx = ShellContext(db: db, classifier: classifier, categories: config.categories,
                                       projects: config.projects, day: day, today: today,
                                       goal: ShellPrefs.goal(config.settings), timeZone: tz, nowMs: now, health: health)
                return Fetched(
                    config: config, classifier: changed ? classifier : nil,
                    day: view == .day ? try ViewSlot.loadDay(ctx) : nil,
                    week: view == .week ? try ViewSlot.loadWeek(ctx) : nil,
                    range: view == .range ? try ViewSlot.loadRange(ctx, period: period) : nil,
                    health: health)
            }
        }.value

        guard gen == generation else { return }
        refetchCount += 1
        nowMs = now
        self.today = today
        switch result {
        case .success(let f):
            (categories, projects, rules, settings) = (f.config.categories, f.config.projects, f.config.rules, f.config.settings)
            jevRevision = f.config.jevRevision
            goal = ShellPrefs.goal(settings)
            if let c = f.classifier { classifier = c; classifierBuilds += 1 }
            if let d = f.day { dayData = d }
            if let w = f.week { weekData = w }
            if let r = f.range { rangeData = r }
            health = f.health
            loadError = nil
            scheduleJev()
        case .failure(let error):
            loadError = String(describing: error)
            SupportLog.app.error("refetch failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// W24: 2 s after the last refetch, ask Jev about cache misses on the visible day + today in the
    /// background. The cache write posts the change feed → refetch → classifier rebuild; that refetch
    /// finds no misses, so it settles. Zero work when Jev is off or no client is wired.
    private func scheduleJev() {
        guard let jevClient, !jevStopped, JevSettings(settings).enabled else { return }
        jevDebounce?.cancel()
        jevDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, !self.jevRunning else { return }
            self.jevRunning = true
            let (db, classifier, cats, projs, now) = (self.db, self.classifier, self.categories, self.projects, self.clock())
            let days = Array(Set([self.selectedDay, self.today]))
            // true = no key / key rejected: stop asking until relaunch instead of retrying every refetch.
            let stop = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    let misses = try ClassifyJevRunner.misses(db: db, days: days, classifier: classifier)
                    if misses.isEmpty { return false }
                    guard let client = jevClient() else { return true }
                    return try await ClassifyJevRunner.run(misses, db: db, client: client, categories: cats,
                                                           projects: projs, nowMs: now).unauthorized
                } catch {
                    SupportLog.app.error("jev classify failed: \(String(describing: error), privacy: .public)")
                    return false
                }
            }.value
            if stop { self.jevStopped = true; SupportLog.app.error("jev: no API key or key rejected; paused until relaunch") }
            self.jevRunning = false
        }
    }

    // MARK: Config writes (Settings). Each write posts the change feed; the direct refetch keeps
    // Settings current even while the main window is hidden and the feed is paused.

    public func save(_ category: HoursCore.Category) async { await write { try ConfigStore(self.db).update(category) } }
    public func save(_ project: Project) async { await write { try ConfigStore(self.db).update(project) } }

    /// Adds a project; with `autoRule`, also a rule matching window titles that contain its name.
    public func addProject(name: String, client: String?, autoRule: Bool) async {
        await write {
            let config = ConfigStore(self.db)
            let id = try config.insert(Project(id: 0, name: name, client: client))
            if autoRule { try config.insert(ClassifyRuleSuggester.projectRule(for: Project(id: id, name: name))) }
        }
    }

    /// Insert (id ≤ 0) or update. Callers validate with `Classifier.validationError` first.
    public func save(_ rule: Rule) async {
        await write {
            let config = ConfigStore(self.db)
            if rule.id > 0 { try config.update(rule) } else { try config.insert(rule) }
        }
    }

    public func deleteRule(id: Int64) async { await write { try ConfigStore(self.db).deleteRule(id: id) } }

    public func setGoal(_ goal: Goal?) async { await write { try ShellPrefs.write(goal: goal, to: SettingStore(self.db)) } }

    public func setIdleThreshold(seconds: Int) async {
        await write { try SettingStore(self.db).set(ShellPrefs.idleThresholdS, String(seconds)) }
    }

    public var idleThresholdS: Int { ShellPrefs.idleThreshold(settings) }

    /// Pause tracking until `untilMs` (nil = resume). The helper applies it live from the change feed.
    public func setPause(untilMs: Int64?) async {
        await write { try TrackerPauseSetting.save(SettingStore(self.db), untilMs: untilMs) }
    }

    /// Pause for `minutes` from now.
    public func pause(minutes: Int) async { await setPause(untilMs: clock() + Int64(minutes) * 60_000) }

    /// Pause until the next day start (04:00) — the app's day boundary.
    public func pauseUntilTomorrow() async {
        await setPause(untilMs: today.shellShifted(by: 1).dayInterval(in: timeZone).lowerBound)
    }

    /// The stored pause end if it's still ahead (what was asked; `health` shows what the helper applied).
    public var pausedUntilMs: Int64? {
        settings[TrackerPauseSetting.key].flatMap { Int64($0) }.flatMap { $0 > nowMs ? $0 : nil }
    }

    /// Name on the PDF timesheet (`consultant_name`), default `NSFullUserName()`.
    public var consultantName: String { ExportPDF.consultantName(settings) }

    public func setConsultantName(_ name: String) async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        await write { try SettingStore(self.db).set(ExportPDF.consultantNameKey, n.isEmpty ? nil : n) }
    }

    private func write(_ body: @escaping @Sendable () throws -> Void) async {
        do {
            try await Task.detached(priority: .userInitiated) { try body() }.value
        } catch {
            loadError = String(describing: error)
            SupportLog.app.error("config write failed: \(String(describing: error), privacy: .public)")
        }
        await refetch()
    }

    // MARK: Settings reads

    /// Distinct window keys seen in the last `days` days with their active time — rule previews.
    public func recentKeys(days: Int = 7) async -> [(key: ClassifyKey, totalMs: Int64)] {
        let (db, now) = (self.db, clock())
        let spans = (try? await Task.detached { try Store(db).effectiveSpans(rangeFrom: now - Int64(days) * 86_400_000, to: now) }.value) ?? []
        var totals: [ClassifyKey: Int64] = [:]
        for s in spans where s.kind == .active && s.source == .tracked { totals[ClassifyKey(s), default: 0] += s.durationMs }
        return totals.sorted { $0.value > $1.value }.map { (key: $0.key, totalMs: $0.value) }
    }

    /// Review queue: uncategorized window keys over the last `days` days, longest first.
    public func reviewQueue(days: Int = 7) async -> [(key: ClassifyKey, totalMs: Int64)] {
        let (db, now, classifier) = (self.db, clock(), self.classifier)
        return (try? await Task.detached {
            classifier.uncategorizedGroups(try Store(db).effectiveSpans(rangeFrom: now - Int64(days) * 86_400_000, to: now))
        }.value) ?? []
    }
}
