import Foundation

/// A tracked span resolved against its category: the only shape the metric passes look at.
struct MetricsSpan {
    var start: Int64
    var end: Int64
    var categoryId: Int64?
    var projectId: Int64?
    var isWork: Bool
    var isFocus: Bool
    var isMeeting: Bool
    var tzId: String
    var app: DayMetrics.App
    var host: String?
    /// Context-switch key: site host for browser spans, else the app.
    var key: String { host ?? app.id }
    var durationMs: Int64 { end - start }

    /// Active, non-excluded, positive-length spans, sorted by start. Idle never counts;
    /// `exclude` categories are dropped from every metric. Unknown category ids count as Uncategorized.
    static func resolve(_ spans: [ClassifiedSpan], categories: [Int64: Category]) -> [MetricsSpan] {
        var out: [MetricsSpan] = []
        out.reserveCapacity(spans.count)
        for c in spans {
            let s = c.span
            guard s.kind == .active, s.endMs > s.startMs else { continue }
            let cat = c.categoryId.flatMap { categories[$0] }
            if cat?.behavior == .exclude { continue }
            let isMeeting = cat?.behavior == .meeting
            out.append(MetricsSpan(
                start: s.startMs, end: s.endMs,
                categoryId: cat?.id, projectId: c.projectId,
                isWork: cat?.isWork ?? false,
                isFocus: cat?.level == .productive && !isMeeting,
                isMeeting: isMeeting,
                tzId: s.tzId,
                app: DayMetrics.App(id: s.bundleId ?? s.appName, name: s.appName),
                host: metricsHost(s.url)))
        }
        out.sort { $0.start < $1.start }
        return out
    }
}

/// Lowercased host with `www.` stripped (item 4's normalization), nil when there is no URL.
func metricsHost(_ url: String?) -> String? {
    guard let url, let host = URL(string: url)?.host(percentEncoded: false)?.lowercased(), !host.isEmpty
    else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}
