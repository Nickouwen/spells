import CryptoKit
import Foundation

/// A local snapshot of Rize history, as fetched by `RizeFetcher` from Rize's GraphQL API
/// (`api.rize.io/api/v1/graphql`). The node shapes are Rize's own field names, verbatim, so the
/// importer parses the real format. Rize 3.x keeps no history on disk; this file is the only source.
public struct RizeSnapshot: Codable, Sendable {
    public static let formatId = "hours-rize-snapshot/1"
    public var format: String
    public var fetchedAt: String
    /// IANA zone from Rize's `currentUser.timezone`. Rize events carry no zone of their own.
    public var timezone: String
    /// `events` — raw app/site switches (Rize's finest granularity), all days.
    public var events: [RizeEvent]
    /// `appsAndWebsites`, one query per Rize day (local midnight bounds), keyed "YYYY-MM-DD".
    /// The only place Rize exposes the category of an app or site.
    public var appsAndWebsites: [String: [RizeAppUsage]]
    /// `summaries(bucketSize: "day")` buckets — Rize's own per-day totals (the cross-check).
    public var summaryBuckets: [RizeSummaryBucket]
    /// `timeEntries` — Rize sessions with client/project/task, when importing them.
    public var timeEntries: [RizeTimeEntry]

    public init(format: String = RizeSnapshot.formatId, fetchedAt: String, timezone: String, events: [RizeEvent],
                appsAndWebsites: [String: [RizeAppUsage]], summaryBuckets: [RizeSummaryBucket], timeEntries: [RizeTimeEntry]) {
        self.format = format; self.fetchedAt = fetchedAt; self.timezone = timezone; self.events = events
        self.appsAndWebsites = appsAndWebsites; self.summaryBuckets = summaryBuckets; self.timeEntries = timeEntries
    }

    public var tz: TimeZone { TimeZone(identifier: timezone) ?? .current }

    /// Loads a snapshot file; returns it with the sha256 (hex) of the file's bytes.
    public static func load(_ url: URL) throws -> (snapshot: RizeSnapshot, sha256: String) {
        let data = try Data(contentsOf: url)
        let snap = try JSONDecoder().decode(RizeSnapshot.self, from: data)
        guard snap.format == formatId else { throw RizeImportError.badFormat(snap.format) }
        return (snap, sha256Hex(data))
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct RizeEvent: Codable, Sendable, Hashable {
    public var appName: String?
    public var title: String?
    public var url: String?
    public var urlHost: String?
    public var source: String
    public var startTime: String
    public var endTime: String
    public init(appName: String?, title: String?, url: String?, urlHost: String?, source: String, startTime: String, endTime: String) {
        self.appName = appName; self.title = title; self.url = url; self.urlHost = urlHost
        self.source = source; self.startTime = startTime; self.endTime = endTime
    }
}

public struct RizeCategory: Codable, Sendable, Hashable {
    public var key: String
    public var name: String
    public var idle: Bool?
    public var work: Bool?
    public init(key: String, name: String, idle: Bool? = nil, work: Bool? = nil) {
        self.key = key; self.name = name; self.idle = idle; self.work = work
    }
}

public struct RizeAppUsage: Codable, Sendable, Hashable {
    public var appName: String?
    public var url: String?
    public var urlHost: String?
    public var title: String
    public var type: String
    public var timeCategory: RizeCategory
    /// Seconds.
    public var timeSpent: Int
    public init(appName: String?, url: String?, urlHost: String?, title: String, type: String,
                timeCategory: RizeCategory, timeSpent: Int) {
        self.appName = appName; self.url = url; self.urlHost = urlHost; self.title = title; self.type = type
        self.timeCategory = timeCategory; self.timeSpent = timeSpent
    }
}

public struct RizeSummaryBucket: Codable, Sendable, Hashable {
    public var date: String
    public var startTime: String
    public var endTime: String
    /// Seconds.
    public var trackedTime: Int
    public init(date: String, startTime: String, endTime: String, trackedTime: Int) {
        self.date = date; self.startTime = startTime; self.endTime = endTime; self.trackedTime = trackedTime
    }
}

public struct RizeNamed: Codable, Sendable, Hashable {
    public var name: String
    public init(name: String) { self.name = name }
}

public struct RizeTimeEntry: Codable, Sendable, Hashable {
    public var startTime: String
    public var endTime: String
    public var title: String?
    public var project: RizeNamed?
    public var client: RizeNamed?
    public init(startTime: String, endTime: String, title: String? = nil, project: RizeNamed? = nil, client: RizeNamed? = nil) {
        self.startTime = startTime; self.endTime = endTime; self.title = title; self.project = project; self.client = client
    }
}

public enum RizeImportError: Error, CustomStringConvertible {
    case badFormat(String), badTime(String), api(String), noLocalHistory
    public var description: String {
        switch self {
        case let .badFormat(f): "not a Rize snapshot (format '\(f)', expected \(RizeSnapshot.formatId))"
        case let .badTime(t): "unparseable Rize timestamp '\(t)'"
        case let .api(m): "Rize API: \(m)"
        case .noLocalHistory:
            "Rize 3.x keeps no activity history on disk (its user-data dir holds settings, tracking rules and web caches only). "
                + "Use --source api with RIZE_API_KEY set (create a key in Rize → Settings → API)."
        }
    }
}

/// Rize's ISO 8601 timestamps → unix ms. Accepts fractional seconds and any offset.
public func rizeMs(_ s: String) throws -> Int64 {
    if let ms = rizeFastMs(s) { return ms }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let d = ISO8601DateFormatter().date(from: s) ?? f.date(from: s) else { throw RizeImportError.badTime(s) }
    return Int64((d.timeIntervalSince1970 * 1000).rounded())
}

/// `YYYY-MM-DDTHH:MM:SS[.fff…](Z|±HH:MM)` without a formatter (~30 µs each, ×3 per event, was most of
/// the planning time). nil for anything else, which falls back to ISO8601DateFormatter.
private func rizeFastMs(_ s: String) -> Int64? {
    let b = Array(s.utf8)
    func num(_ i: Int, _ n: Int) -> Int64? {
        guard i + n <= b.count else { return nil }
        var v: Int64 = 0
        for c in b[i..<i + n] { guard (48...57).contains(c) else { return nil }; v = v * 10 + Int64(c - 48) }
        return v
    }
    guard b.count >= 20, b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58,
          let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2)
    else { return nil }
    var i = 19, frac: Int64 = 0
    if b[i] == 46 {
        var scale: Int64 = 100
        i += 1
        while i < b.count, (48...57).contains(b[i]) { frac += Int64(b[i] - 48) * scale; scale /= 10; i += 1 }
    }
    var off: Int64 = 0
    if i == b.count - 1, b[i] == 90 {
        off = 0
    } else if i == b.count - 6, b[i] == 43 || b[i] == 45, b[i + 3] == 58, let oh = num(i + 1, 2), let om = num(i + 4, 2) {
        off = (oh * 60 + om) * 60 * (b[i] == 45 ? -1 : 1)
    } else {
        return nil
    }
    // Days from civil (H. Hinnant).
    let yy = mo <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let doy = (153 * (mo > 2 ? mo - 3 : mo + 9) + 2) / 5 + d - 1
    let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
    return ((days * 24 + h) * 3600 + mi * 60 + sec - off) * 1000 + frac
}
