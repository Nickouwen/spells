import Foundation
import HoursCore

/// One line of a breakdown list: label, time, and the category colour it mostly falls in.
struct DayRow: Hashable, Identifiable {
    var id: String
    var name: String
    var ms: Int64
    var slot: Int?
    var muted = false
}

/// Breakdown lists for the right-hand panels, derived from `DayMetrics` (totals) plus one pass
/// over the day's spans for each row's dominant category. Day-sized input only.
enum DayRows {
    static func categories(_ d: DayData) -> [DayRow] {
        d.metrics.byCategory.map { r in
            DayRow(id: "c\(r.key ?? -1)", name: d.categoryName(r.key), ms: r.trackedMs, slot: d.slot(r.key))
        }
    }

    static func projects(_ d: DayData) -> [DayRow] {
        var rows = d.metrics.byProject.compactMap { r -> DayRow? in
            guard let id = r.key, r.trackedMs > 0 else { return nil }
            return DayRow(id: "p\(id)", name: d.projectName(id) ?? "Project \(id)", ms: r.trackedMs, slot: nil)
        }
        if d.metrics.unassignedWorkMs > 0 {
            rows.append(DayRow(id: "p-none", name: "No project", ms: d.metrics.unassignedWorkMs, slot: nil, muted: true))
        }
        return rows
    }

    static func apps(_ d: DayData, limit: Int = 5) -> [DayRow] {
        let dom = dominant(d) { s in s.bundleId ?? s.appName }
        return d.metrics.byApp.prefix(limit).map { r in
            // Manual entries (W12) have no app: appName "".
            DayRow(id: "a" + r.key.id, name: r.key.name.isEmpty ? "Manual entries" : r.key.name, ms: r.trackedMs, slot: dom[r.key.id].flatMap { d.slot($0) })
        }
    }

    static func hosts(_ d: DayData, limit: Int = 4) -> [DayRow] {
        let dom = dominant(d) { s in host(s.url) ?? "" }
        return d.metrics.byHost.compactMap { r -> DayRow? in
            guard let h = r.key else { return nil }
            return DayRow(id: "h" + h, name: h, ms: r.trackedMs, slot: dom[h].flatMap { d.slot($0) })
        }.prefix(limit).map { $0 }
    }

    /// key → category id holding the most active time under that key.
    private static func dominant(_ d: DayData, key: (EffectiveSpan) -> String) -> [String: Int64?] {
        var acc: [String: [Int64?: Int64]] = [:]
        for c in d.spans where c.span.kind == .active {
            acc[key(c.span), default: [:]][c.categoryId, default: 0] += c.span.durationMs
        }
        return acc.mapValues { m in m.max { $0.value < $1.value }?.key ?? nil }
    }

    /// Lowercased host, `www.` stripped (matches the metrics' host key).
    static func host(_ url: String?) -> String? {
        guard let url, let h = URL(string: url)?.host(percentEncoded: false)?.lowercased(), !h.isEmpty else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}
