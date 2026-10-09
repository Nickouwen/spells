import SwiftUI
import HoursCore

/// Everything a view loader needs, captured off the main actor.
public struct ShellContext: Sendable {
    public var db: HoursDB
    public var classifier: Classifier
    public var categories: [HoursCore.Category]
    public var projects: [Project]
    public var day: LocalDate
    public var today: LocalDate
    public var goal: Goal?
    public var timeZone: TimeZone
    /// Clock at refetch time; the ≤ 1/min "now" tick refetches, so today's DayData advances with it.
    public var nowMs: Int64
    public var health: TrackerHealth
}

/// The seam between the shell and the views (W10 Day, W11 Range, W13 Week).
@MainActor
enum ViewSlot {
    typealias DayPayload = DayData
    nonisolated static func loadDay(_ c: ShellContext) throws -> DayData {
        try DayData.load(store: Store(c.db), classifier: c.classifier, categories: c.categories,
                         projects: c.projects, day: c.day, goal: c.goal,
                         now: Date(timeIntervalSince1970: Double(c.nowMs) / 1000),
                         timeZone: c.timeZone, tracker: c.health)
    }
    /// Day with editing (W12): selection, inspector, undo/redo on the window's UndoManager.
    static func dayView(_ d: DayData, db: HoursDB, onNavigate: @escaping (LocalDate) -> Void) -> some View {
        EditingDayHost(data: d, db: db, onNavigate: onNavigate)
    }

    typealias WeekPayload = WeekData
    nonisolated static func loadWeek(_ c: ShellContext) throws -> WeekData {
        try WeekData.load(store: Store(c.db), classifier: c.classifier, categories: c.categories,
                          projects: c.projects, week: c.day, goal: c.goal,
                          now: Date(timeIntervalSince1970: Double(c.nowMs) / 1000), timeZone: c.timeZone)
    }
    /// `onOpenBlock`: a click on a block in Blocks mode (Day → Blocks with that block selected).
    static func weekView(_ d: WeekData, onSelectDay: @escaping (LocalDate) -> Void,
                         onNavigate: @escaping (LocalDate) -> Void,
                         onOpenBlock: @escaping (WeekBlockRoute) -> Void) -> some View {
        WeekView(data: d, onSelectDay: onSelectDay, onNavigate: onNavigate, onOpenBlock: onOpenBlock, pinnedMode: nil)
    }

    typealias Period = RangePeriod
    nonisolated static var defaultPeriod: RangePeriod { .currentBilling }
    typealias RangePayload = RangeData
    nonisolated static func loadRange(_ c: ShellContext, period: RangePeriod) throws -> RangeData {
        try RangeData.load(store: Store(c.db), classifier: c.classifier, categories: c.categories,
                           projects: c.projects, period: period, today: c.today, timeZone: c.timeZone)
    }
    static func rangeView(_ d: RangeData, period: Binding<RangePeriod>, today: LocalDate) -> some View {
        RangeView(data: d, period: period, today: today)
    }
}
