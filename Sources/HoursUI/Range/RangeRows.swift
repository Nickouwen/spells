import Foundation
import HoursCore

/// One table row: a group key's totals over the period, plus its per-day series.
public struct RangeRow: Identifiable, Hashable, Sendable {
    public var id: RangeKey
    public var name: String
    /// Category colour slot (category group only; other groups are monochrome).
    public var slot: Int?
    public var isCategory: Bool
    public var trackedMs: Int64
    /// Work ms; for project rows, billable ms (the nil row: unassigned work).
    public var workMs: Int64
    /// trackedMs / period tracked.
    public var share: Double
    /// Days with any tracked time for this key.
    public var activeDays: Int
    /// Tracked ms per day of the period (empty days included), in date order.
    public var daily: [Int64]
    public var avgPerActiveDayMs: Int64 { activeDays > 0 ? trackedMs / Int64(activeDays) : 0 }
}

extension RangeData {
    /// Rows for `group`, sorted tracked-descending (ties: name). Σ trackedMs = `metrics.trackedMs`.
    public func rows(_ group: RangeGroup) -> [RangeRow] {
        let total = metrics.trackedMs
        let index = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1.date, $0) })
        func make(_ key: RangeKey, _ tracked: Int64, _ work: Int64, _ perDay: (DayMetrics) -> Int64?) -> RangeRow {
            var daily = Array(repeating: Int64(0), count: days.count)
            for d in metrics.days { if let i = index[d.date] { daily[i] = perDay(d.metrics) ?? 0 } }
            let (name, slot) = label(key)
            return RangeRow(id: key, name: name, slot: slot, isCategory: group == .category,
                            trackedMs: tracked, workMs: work,
                            share: total > 0 ? Double(tracked) / Double(total) : 0,
                            activeDays: daily.filter { $0 > 0 }.count, daily: daily)
        }
        let rows: [RangeRow]
        switch group {
        case .category:
            rows = metrics.byCategory.map { r in make(.category(r.key), r.trackedMs, r.workMs) { m in m.byCategory.first { $0.key == r.key }?.trackedMs } }
        case .project:
            rows = metrics.byProject.map { r in make(.project(r.key), r.trackedMs, r.workMs) { m in m.byProject.first { $0.key == r.key }?.trackedMs } }
        case .app:
            rows = metrics.byApp.map { r in make(.app(r.key.id), r.trackedMs, r.workMs) { m in m.byApp.first { $0.key == r.key }?.trackedMs } }
        case .site:
            rows = metrics.byHost.map { r in make(.site(r.key), r.trackedMs, r.workMs) { m in m.byHost.first { $0.key == r.key }?.trackedMs } }
        }
        return rows.sorted { ($0.trackedMs, $1.name) > ($1.trackedMs, $0.name) }
    }

    /// Display name and colour slot for a key.
    public func label(_ key: RangeKey) -> (name: String, slot: Int?) {
        switch key {
        case let .category(id):
            guard let id, let c = categories.first(where: { $0.id == id }) else { return ("Uncategorized", nil) }
            return (c.name, c.colorSlot)
        case let .project(id):
            guard let id else { return ("No project", nil) }
            return (projects.first { $0.id == id }?.name ?? "Project \(id)", nil)
        case let .app(id):
            if id.isEmpty { return ("Manual entries", nil) }
            return (metrics.byApp.first { $0.key.id == id }?.key.name ?? id, nil)
        case let .site(host):
            return (host ?? "No site (apps)", nil)
        }
    }

    /// Category legend for the stacked bars: top 7 by tracked time, the rest folded into "Other"
    /// (grey), Uncategorized last. Keeps a chart at ≤ 8 colours + grey.
    public var chartLegend: [(key: Int64?, name: String, slot: Int?)] {
        let named = metrics.byCategory.compactMap { r -> (Int64?, String, Int?)? in
            guard let id = r.key else { return nil }
            let l = label(.category(id))
            return (id, l.name, l.slot)
        }
        var out = Array(named.prefix(7)).map { (key: $0.0, name: $0.1, slot: $0.2) }
        if named.count > 7 { out.append((key: -1, name: "Other", slot: nil)) }
        if metrics.byCategory.contains(where: { $0.key == nil }) { out.append((key: nil, name: "Uncategorized", slot: nil)) }
        return out
    }

    /// Stacked-bar segments per day × legend entry with time, in legend order (bottom first).
    /// `startMs` = time stacked below this segment that day; `isTop` = last segment of its day.
    public var chartMarks: [(date: LocalDate, name: String, ms: Int64, startMs: Int64, isTop: Bool)] {
        let legend = chartLegend
        let shown = Set(legend.compactMap(\.key))
        var out: [(LocalDate, String, Int64)] = []
        for d in metrics.days {
            var other: Int64 = 0
            for r in d.metrics.byCategory {
                if let k = r.key, !shown.contains(k) { other += r.trackedMs; continue }
                guard let e = legend.first(where: { $0.key == r.key }) else { continue }
                out.append((d.date, e.name, r.trackedMs))
            }
            if other > 0 { out.append((d.date, "Other", other)) }
        }
        let order = Dictionary(uniqueKeysWithValues: legend.enumerated().map { ($1.name, $0) })
        let sorted = out.sorted { ($0.0, order[$0.1] ?? 99) < ($1.0, order[$1.1] ?? 99) }
        var stacked: [(date: LocalDate, name: String, ms: Int64, startMs: Int64, isTop: Bool)] = []
        var below: Int64 = 0
        for (i, m) in sorted.enumerated() {
            if i == 0 || sorted[i - 1].0 != m.0 { below = 0 }
            let isTop = i == sorted.count - 1 || sorted[i + 1].0 != m.0
            stacked.append((date: m.0, name: m.1, ms: m.2, startMs: below, isTop: isTop))
            below += m.2
        }
        return stacked
    }

    /// Billable per project, edited vs raw, sorted edited-descending. Unassigned work is separate.
    public var billableByProject: [(id: Int64, name: String, ms: Int64, rawMs: Int64)] {
        var rawBy: [Int64: Int64] = [:]
        for r in raw.byProject { if let k = r.key { rawBy[k] = r.workMs } }
        var ids = Set(rawBy.keys)
        var editedBy: [Int64: Int64] = [:]
        for r in metrics.byProject { if let k = r.key { editedBy[k] = r.workMs; ids.insert(k) } }
        return ids.map { id in (id: id, name: label(.project(id)).name, ms: editedBy[id] ?? 0, rawMs: rawBy[id] ?? 0) }
            .filter { $0.ms > 0 || $0.rawMs > 0 }
            .sorted { ($0.ms, $1.name) > ($1.ms, $0.name) }
    }
}
