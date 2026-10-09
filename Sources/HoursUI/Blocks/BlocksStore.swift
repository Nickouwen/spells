import SwiftUI
import HoursCore

/// The Blocks view's link to the store: its display settings (`BlocksThreshold` keys in the
/// `setting` table) and "Always for these apps" rules. The editing Day view owns one and puts it in
/// the environment; without it (renders, read-only) Blocks falls back to defaults and hides rules.
@MainActor @Observable
final class BlocksStore {
    let db: HoursDB
    private(set) var settings: [String: String] = [:]
    @ObservationIgnored private var loaded = false

    init(db: HoursDB) { self.db = db }

    /// First appearance: one small synchronous read, so the first frame groups at the stored threshold.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        settings = (try? SettingStore(db).all()) ?? [:]
    }

    /// On the change feed (the Settings window or another view wrote).
    func reload() async {
        let db = db
        if let s = try? await Task.detached(priority: .userInitiated, operation: { try SettingStore(db).all() }).value,
           s != settings {
            settings = s
        }
    }

    /// nil removes the key. Applied locally at once; the write posts the change feed.
    func set(_ key: String, _ value: String?) {
        settings[key] = value
        do { try SettingStore(db).set(key, value) } catch {
            SupportLog.app.error("blocks setting \(key, privacy: .public) not saved: \(String(describing: error), privacy: .public)")
        }
    }

    /// Persists rules (the classifier rebuilds on the change feed). Returns how many were saved.
    @discardableResult
    func save(_ rules: [Rule]) -> Int {
        let config = ConfigStore(db)
        return rules.reduce(0) { n, r in (try? config.insert(r)) != nil ? n + 1 : n }
    }

    // MARK: Threshold writes (the header picker)

    /// Header picker: writes the default, or `day`'s weekday override when `weekdayOnly`.
    func setThreshold(_ minutes: Int, for day: LocalDate, weekdayOnly: Bool) {
        let m = min(max(minutes, BlocksThreshold.range.lowerBound), BlocksThreshold.range.upperBound)
        if weekdayOnly {
            var o = BlocksThreshold.overrides(settings)
            o[BlocksThreshold.weekday(day)] = m
            set(BlocksThreshold.weekdayKey, BlocksThreshold.encode(o))
        } else {
            set(BlocksThreshold.defaultKey, String(m))
        }
    }

    /// "Only on <weekday>": on copies today's effective value into an override; off removes it.
    func setWeekdayOnly(_ on: Bool, for day: LocalDate) {
        var o = BlocksThreshold.overrides(settings)
        let wd = BlocksThreshold.weekday(day)
        o[wd] = on ? BlocksThreshold.minutes(for: day, settings: settings) : nil
        set(BlocksThreshold.weekdayKey, BlocksThreshold.encode(o))
    }
}

extension EnvironmentValues {
    @Entry var blocksStore: BlocksStore? = nil
}
