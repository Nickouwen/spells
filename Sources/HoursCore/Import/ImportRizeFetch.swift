import Foundation

/// Pulls Rize history into a `RizeSnapshot` through Rize's public GraphQL API with the user's API key
/// (Rize → Settings → API). Read-only queries; talks to api.rize.io and nothing else.
/// Query shapes match the live schema (introspected 2026-10-05).
public struct RizeFetcher: Sendable {
    public static let endpoint = URL(string: "https://api.rize.io/api/v1/graphql")!
    let apiKey: String
    let log: @Sendable (String) -> Void

    public init(apiKey: String, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.apiKey = apiKey; self.log = log
    }

    /// Everything from `since` (default: the first day Rize has tracked time, searching back 3 years) to now.
    public func fetch(since: LocalDate? = nil, now: Date = Date()) async throws -> RizeSnapshot {
        let user = try await query("query { currentUser { timezone } }", [:])
        let tzName = ((user["currentUser"] as? [String: Any])?["timezone"] as? String).flatMap { TimeZone(identifier: $0)?.identifier }
            ?? TimeZone.current.identifier
        let tz = TimeZone(identifier: tzName)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let today = cal.startOfDay(for: now)

        // Day summaries, 90-day windows going back until a window is empty after data was seen.
        var buckets: [RizeSummaryBucket] = []
        var end = today
        let floor = since.map { cal.date(from: DateComponents(year: $0.year, month: $0.month, day: $0.day))! }
            ?? cal.date(byAdding: .year, value: -3, to: today)!
        while end >= floor {
            let start = max(floor, cal.date(byAdding: .day, value: -89, to: end)!)
            log("summaries \(day(start, tz))…\(day(end, tz))")
            let d = try await query("""
                query($s: ISO8601Date!, $e: ISO8601Date!) { summaries(startDate: $s, endDate: $e, bucketSize: "day") {
                  buckets { date startTime endTime trackedTime } } }
                """, ["s": day(start, tz), "e": day(end, tz)])
            let got = try decode([RizeSummaryBucket].self, ((d["summaries"] as? [String: Any])?["buckets"]) ?? [])
            buckets += got
            if since == nil, got.allSatisfy({ $0.trackedTime == 0 }), buckets.contains(where: { $0.trackedTime > 0 }) { break }
            end = cal.date(byAdding: .day, value: -1, to: start)!
        }
        buckets = Dictionary(buckets.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a }).values
            .filter { since == nil ? true : $0.date >= since!.description }.sorted { $0.date < $1.date }
        let active = buckets.filter { $0.trackedTime > 0 }
        guard let firstDate = active.first?.date, let first = parseDay(firstDate, cal) else {
            return RizeSnapshot(fetchedAt: now.ISO8601Format(), timezone: tzName, events: [], appsAndWebsites: [:],
                                summaryBuckets: buckets, timeEntries: [])
        }
        buckets = buckets.filter { $0.date >= firstDate }
        let stop = cal.date(byAdding: .day, value: 1, to: today)!

        // Raw events, 7-day windows, 200 per page.
        var events: [RizeEvent] = []
        var w = first
        while w < stop {
            let we = min(stop, cal.date(byAdding: .day, value: 7, to: w)!)
            log("events \(day(w, tz))…")
            events += try await paged("""
                query($s: ISO8601DateTime!, $e: ISO8601DateTime!, $after: String) {
                  events(startTime: $s, endTime: $e, first: 200, after: $after) {
                    nodes { appName title url urlHost source startTime endTime } pageInfo { hasNextPage endCursor } } }
                """, field: "events", ["s": w.ISO8601Format(), "e": we.ISO8601Format()])
            w = we
        }

        // Categories: appsAndWebsites per active Rize day.
        var apps: [String: [RizeAppUsage]] = [:]
        for b in active {
            guard let d0 = parseDay(b.date, cal) else { continue }
            let d1 = cal.date(byAdding: .day, value: 1, to: d0)!
            let d = try await query("""
                query($s: ISO8601DateTime!, $e: ISO8601DateTime!) { appsAndWebsites(startTime: $s, endTime: $e) {
                  appName url urlHost title type timeSpent timeCategory { key name idle work } } }
                """, ["s": d0.ISO8601Format(), "e": d1.ISO8601Format()])
            apps[b.date] = try decode([RizeAppUsage].self, d["appsAndWebsites"] ?? [])
        }
        log("apps/sites for \(apps.count) days")

        // Time entries (projects), monthly windows.
        var entries: [RizeTimeEntry] = []
        w = first
        while w < stop {
            let we = min(stop, cal.date(byAdding: .month, value: 1, to: w)!)
            entries += try await paged("""
                query($s: ISO8601DateTime!, $e: ISO8601DateTime!, $after: String) {
                  timeEntries(startTime: $s, endTime: $e, first: 100, after: $after) {
                    nodes { startTime endTime title project { name } client { name } } pageInfo { hasNextPage endCursor } } }
                """, field: "timeEntries", ["s": w.ISO8601Format(), "e": we.ISO8601Format()])
            w = we
        }
        log("\(events.count) events, \(entries.count) time entries")
        return RizeSnapshot(fetchedAt: now.ISO8601Format(), timezone: tzName, events: events, appsAndWebsites: apps,
                            summaryBuckets: buckets, timeEntries: entries)
    }

    private func paged<T: Decodable>(_ q: String, field: String, _ vars: [String: Any]) async throws -> [T] {
        var out: [T] = [], after: String? = nil
        repeat {
            var v = vars
            v["after"] = after ?? NSNull()
            let conn = try await query(q, v)[field] as? [String: Any] ?? [:]
            out += try decode([T].self, conn["nodes"] ?? [])
            let info = conn["pageInfo"] as? [String: Any] ?? [:]
            after = (info["hasNextPage"] as? Bool == true) ? info["endCursor"] as? String : nil
        } while after != nil
        return out
    }

    private func query(_ q: String, _ vars: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": q, "variables": vars])
        req.timeoutInterval = 60
        for attempt in 1...5 {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status >= 500, attempt < 5 {
                try await Task.sleep(for: .seconds(5 * attempt))
                continue
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let errs = body?["errors"] as? [[String: Any]], !errs.isEmpty {
                throw RizeImportError.api(errs.compactMap { $0["message"] as? String }.joined(separator: "; "))
            }
            guard status == 200, let d = body?["data"] as? [String: Any] else {
                throw RizeImportError.api("HTTP \(status)\(status == 401 ? " (check RIZE_API_KEY)" : "")")
            }
            return d
        }
        throw RizeImportError.api("gave up after retries")
    }

    private func decode<T: Decodable>(_: T.Type, _ any: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: any))
    }

    private func day(_ d: Date, _ tz: TimeZone) -> String {
        LocalDate.containing(ms: Int64(d.timeIntervalSince1970 * 1000), in: tz, dayStartHour: 0).description
    }

    private func parseDay(_ s: String, _ cal: Calendar) -> Date? {
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}
