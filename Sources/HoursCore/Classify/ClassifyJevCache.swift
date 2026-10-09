import Foundation

/// One `jev_class` row: Jev's answer for a key, or a failed request waiting for `retryAfterMs`.
public struct JevEntry: Sendable, Hashable {
    public var key: JevKey
    /// nil = the request failed; asked again once `retryAfterMs` has passed.
    public var categoryKey: String?
    public var categoryConf: Double
    public var categoryProbs: [String: Double]
    /// nil or "none" = no project.
    public var projectName: String?
    public var projectConf: Double
    public var model: String?
    public var createdMs: Int64
    public var inputTokens: Int
    public var retryAfterMs: Int64?

    public init(key: JevKey, categoryKey: String?, categoryConf: Double = 0, categoryProbs: [String: Double] = [:],
                projectName: String? = nil, projectConf: Double = 0, model: String? = nil, createdMs: Int64,
                inputTokens: Int = 0, retryAfterMs: Int64? = nil) {
        self.key = key; self.categoryKey = categoryKey; self.categoryConf = categoryConf
        self.categoryProbs = categoryProbs; self.projectName = projectName; self.projectConf = projectConf
        self.model = model; self.createdMs = createdMs; self.inputTokens = inputTokens; self.retryAfterMs = retryAfterMs
    }

    public static func failure(_ key: JevKey, nowMs: Int64, retryAfterMs: Int64) -> JevEntry {
        JevEntry(key: key, categoryKey: nil, createdMs: nowMs, retryAfterMs: retryAfterMs)
    }
}

/// A cache lookup result. `confidence` is the exact entry's, or the agreeing entries' mean.
public struct JevHit: Sendable, Hashable {
    public enum Tier: String, Sendable { case exact, path, host }
    public var categoryKey: String
    public var confidence: Double
    public var projectName: String?
    public var projectConf: Double
    public var tier: Tier
}

/// Settings → Classification (`setting` table). Defaults: on, 0.6, titles sent.
public struct JevSettings: Sendable, Hashable {
    public static let enabledKey = "jev_enabled"
    public static let minConfidenceKey = "jev_min_confidence"
    public static let sendTitlesKey = "jev_send_titles"
    /// Project attribution bar (fixed): conf ≥ 0.75, work category, no rule set a project.
    public static let projectMinConfidence = 0.75

    public var enabled: Bool
    public var minConfidence: Double
    public var sendTitles: Bool

    public init(enabled: Bool = true, minConfidence: Double = 0.6, sendTitles: Bool = true) {
        self.enabled = enabled; self.minConfidence = minConfidence; self.sendTitles = sendTitles
    }

    public init(_ settings: [String: String]) {
        self.init(enabled: settings[Self.enabledKey] != "0",
                  minConfidence: settings[Self.minConfidenceKey].flatMap(Double.init).map { min(max($0, 0), 1) } ?? 0.6,
                  sendTitles: settings[Self.sendTitlesKey] != "0")
    }
}

/// Immutable view of the Jev cache that a `Classifier` consults. Lookup tiers, first hit wins:
/// 1. **exact** — same (app, host, pathTpl, titleNorm). Final even when below the apply threshold.
/// 2. **path** (web only) — ≥ 3 entries on (app, host, pathTpl), ≥ 80 % on one category, their mean conf ≥ 0.7.
/// 3. **host** — ≥ 5 entries on (app, host), ≥ 90 % on one category. For non-web apps host is "",
///    so this is the app-level consensus tier.
/// Otherwise a miss (→ one Jev request). Failed rows never answer a lookup.
public struct JevSnapshot: Sendable {
    public let settings: JevSettings
    private let exact: [String: JevEntry]
    private let byPath: [String: [JevEntry]]
    private let byHost: [String: [JevEntry]]
    /// Keys whose last request failed and isn't due for a retry yet (as of snapshot time).
    private let blocked: Set<String>

    public static let empty = JevSnapshot(entries: [], settings: JevSettings(enabled: false))

    public init(entries: [JevEntry], settings: JevSettings = JevSettings(), nowMs: Int64 = .max) {
        self.settings = settings
        var exact: [String: JevEntry] = [:], path: [String: [JevEntry]] = [:], host: [String: [JevEntry]] = [:]
        var blocked = Set<String>()
        for e in entries {
            guard e.categoryKey != nil else {
                if let r = e.retryAfterMs, r > nowMs { blocked.insert(e.key.id) }
                continue
            }
            exact[e.key.id] = e
            path[Self.pathId(e.key), default: []].append(e)
            host[Self.hostId(e.key), default: []].append(e)
        }
        self.exact = exact; byPath = path; byHost = host; self.blocked = blocked
    }

    public var isEmpty: Bool { exact.isEmpty }
    public var count: Int { exact.count }

    public func lookup(_ key: JevKey) -> JevHit? {
        if let e = exact[key.id], let cat = e.categoryKey {
            return JevHit(categoryKey: cat, confidence: e.categoryConf, projectName: e.projectName,
                          projectConf: e.projectConf, tier: .exact)
        }
        if key.isWeb, let hit = Self.consensus(byPath[Self.pathId(key)] ?? [], minCount: 3, minShare: 0.8,
                                                minMeanConf: 0.7, tier: .path) {
            return hit
        }
        return Self.consensus(byHost[Self.hostId(key)] ?? [], minCount: 5, minShare: 0.9, minMeanConf: 0, tier: .host)
    }

    /// True when a request for `key` would be wasted: answered at some tier, or failed recently.
    public func covers(_ key: JevKey) -> Bool { blocked.contains(key.id) || lookup(key) != nil }

    // ponytail: consensus hits carry no project — project attribution needs an exact answer.
    private static func consensus(_ entries: [JevEntry], minCount: Int, minShare: Double, minMeanConf: Double,
                                  tier: JevHit.Tier) -> JevHit? {
        guard entries.count >= minCount else { return nil }
        var votes: [String: [Double]] = [:]
        for e in entries { if let c = e.categoryKey { votes[c, default: []].append(e.categoryConf) } }
        guard let (cat, confs) = votes.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }),
              Double(confs.count) >= minShare * Double(entries.count) - 1e-9 else { return nil }
        let mean = confs.reduce(0, +) / Double(confs.count)
        guard mean >= minMeanConf else { return nil }
        return JevHit(categoryKey: cat, confidence: mean, projectName: nil, projectConf: 0, tier: tier)
    }

    private static func pathId(_ k: JevKey) -> String { [k.app, k.host, k.pathTpl].joined(separator: "\u{1F}") }
    private static func hostId(_ k: JevKey) -> String { [k.app, k.host].joined(separator: "\u{1F}") }
}
