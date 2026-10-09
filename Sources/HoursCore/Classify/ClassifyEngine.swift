import Foundation

/// The cache key: the four observed fields of an active span.
public struct ClassifyKey: Hashable, Sendable {
    public var bundleId: String?
    public var appName: String
    public var title: String?
    public var url: String?

    public init(bundleId: String?, appName: String, title: String?, url: String?) {
        self.bundleId = bundleId; self.appName = appName; self.title = title; self.url = url
    }

    public init(_ span: EffectiveSpan) {
        self.init(bundleId: span.bundleId, appName: span.appName, title: span.title, url: span.url)
    }
}

/// Rule-derived classification of one key, with the winning rule ids (for "why this category").
public struct ClassifyResult: Hashable, Sendable {
    /// nil = Uncategorized.
    public var categoryId: Int64?
    public var projectId: Int64?
    public var categoryRuleId: Int64?
    public var projectRuleId: Int64?
}

/// Where a span's category came from (Day tooltip / inspector). nil = Uncategorized.
public enum ClassifySource: Hashable, Sendable {
    case edited, rule, jev(confidence: Double), fallback

    /// "Edited", "Rule", "Jev 92 %", "Fallback".
    public var label: String {
        switch self {
        case .edited: "Edited"
        case .rule: "Rule"
        case .jev(let c): "Jev \(Int((c * 100).rounded())) %"
        case .fallback: "Fallback"
        }
    }
}

/// Read-time classifier. Precedence: edit override > rule > Jev cache (conf ≥ `jev_min_confidence`) >
/// Browsing fallback (browser apps only) > Uncategorized; category and project resolve independently.
/// A Jev project applies only at conf ≥ 0.75, on a work category, when no rule set a project.
/// Rule winner = priority desc, specificity desc, user over seed, id asc.
/// `jev: nil` = rules only (fixtures, previews); any snapshot (even empty) turns on the full chain.
/// Immutable config; the per-key cache is invalidated by constructing a new Classifier.
public final class Classifier: @unchecked Sendable {
    public let categories: [Category]
    public let rules: [Rule]
    public let projects: [Project]
    public let jev: JevSnapshot?
    /// Enabled rules skipped because their title regex doesn't compile.
    public let invalidRuleIds: Set<Int64>

    private let compiled: [Compiled]           // sorted by precedence; index = rank
    private let byBundle: [String: [Int]]
    private let byHost: [String: [Int]]
    private let byHostPrefix: [String: [Int]]
    private let byAppName: [String: [Int]]
    private let unindexed: [Int]

    private let lock = NSLock()
    private var cache: [ClassifyKey: ClassifyResult] = [:]
    private var fullCache: [ClassifyKey: Resolution] = [:]

    private let categoryByKey: [String: Category]
    private let workCategoryIds: Set<Int64>
    private let projectByName: [String: Int64]
    private let browsingId: Int64?

    public init(categories: [Category], rules: [Rule], projects: [Project], jev: JevSnapshot? = nil) {
        self.categories = categories
        self.rules = rules
        self.projects = projects
        self.jev = jev
        let live = categories.filter { !$0.archived }
        categoryByKey = Dictionary(live.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        workCategoryIds = Set(live.filter { $0.isWork && $0.behavior != .exclude }.map(\.id))
        projectByName = Dictionary(projects.filter { !$0.archived }.map { ($0.name.lowercased(), $0.id) },
                                   uniquingKeysWith: { a, _ in a })
        browsingId = categoryByKey["browsing"]?.id

        let catIds = Set(categories.map(\.id)), projIds = Set(projects.map(\.id))
        var invalid = Set<Int64>()
        var list: [Compiled] = []
        for rule in rules where rule.enabled {
            if let p = rule.titleRegex, (try? NSRegularExpression(pattern: p)) == nil { invalid.insert(rule.id) }
            guard let c = Compiled(rule, categoryIds: catIds, projectIds: projIds) else { continue }
            list.append(c)
        }
        list.sort(by: Compiled.precedes)
        compiled = list
        invalidRuleIds = invalid

        var bundle: [String: [Int]] = [:], host: [String: [Int]] = [:], app: [String: [Int]] = [:]
        var hostPrefix: [String: [Int]] = [:]
        var rest: [Int] = []
        // Index each rule under one predicate — every predicate must match anyway.
        for (rank, c) in list.enumerated() {
            if let b = c.rule.bundleId { bundle[b, default: []].append(rank) }
            else if let h = c.host, let p = ClassifyURL.hostPrefix(h) { hostPrefix[p, default: []].append(rank) }
            else if let h = c.host { host[h, default: []].append(rank) }
            else if let a = c.appLower { app[a, default: []].append(rank) }
            else { rest.append(rank) }
        }
        byBundle = bundle; byHost = host; byHostPrefix = hostPrefix; byAppName = app; unindexed = rest
    }

    public func classify(_ span: EffectiveSpan) -> ClassifiedSpan {
        var cat = span.categoryOverride, proj = span.projectOverride
        // Rules apply to tracked active time only; manual entries carry edit values only.
        if span.kind == .active, span.source == .tracked, cat == nil || proj == nil {
            let r = resolution(ClassifyKey(span))
            cat = cat ?? r.categoryId
            if proj == nil {
                proj = r.ruleProjectId ?? (cat.map(workCategoryIds.contains) == true ? r.jevProjectId : nil)
            }
        }
        return ClassifiedSpan(span: span, categoryId: cat, projectId: proj)
    }

    /// Where the span's category came from; nil = Uncategorized (or idle).
    public func source(_ span: EffectiveSpan) -> ClassifySource? {
        if span.categoryOverride != nil { return .edited }
        guard span.kind == .active, span.source == .tracked else { return nil }
        return resolution(ClassifyKey(span)).source
    }

    /// The Jev cache's answer for a key at any tier, regardless of the apply threshold
    /// (review queue: "Jev suggests X (62 %)"). nil without a snapshot, or for never-sent windows.
    public func jevHit(_ key: ClassifyKey) -> JevHit? {
        guard let jev, let k = ClassifyJevKey.make(key, includeTitle: jev.settings.sendTitles) else { return nil }
        return jev.lookup(k)
    }

    /// Full-precedence resolution of a key (ignores overrides).
    public struct Resolution: Hashable, Sendable {
        public var categoryId: Int64?
        public var source: ClassifySource?
        public var ruleProjectId: Int64?
        /// Jev project that cleared 0.75; applied only when the final category is work.
        public var jevProjectId: Int64?
    }

    /// Rule > Jev (≥ threshold) > Browsing fallback, for a key. Cached.
    public func resolution(_ key: ClassifyKey) -> Resolution {
        lock.lock()
        if let hit = fullCache[key] { lock.unlock(); return hit }
        lock.unlock()
        let rule = resolve(key)
        var out = Resolution(categoryId: rule.categoryId, source: rule.categoryId == nil ? nil : .rule,
                             ruleProjectId: rule.projectId, jevProjectId: nil)
        if out.categoryId == nil, let jev {
            if let hit = jevHit(key) {
                if hit.confidence >= jev.settings.minConfidence, let c = categoryByKey[hit.categoryKey] {
                    out.categoryId = c.id
                    out.source = .jev(confidence: hit.confidence)
                }
                if hit.projectConf >= JevSettings.projectMinConfidence, let name = hit.projectName {
                    out.jevProjectId = projectByName[name.lowercased()]
                }
            }
            if out.categoryId == nil, let browsingId, Self.isBrowser(key) {
                out.categoryId = browsingId
                out.source = .fallback
            }
        }
        lock.lock(); fullCache[key] = out; lock.unlock()
        return out
    }

    /// Browser windows: a URL was captured, or a known browser bundle (private/opaque windows too).
    public static func isBrowser(_ key: ClassifyKey) -> Bool {
        key.url != nil || browserBundles.contains(key.bundleId ?? "")
    }

    // Mirrors TrackerCore's `TrackerBrowser.kind` (HoursCore can't import it).
    static let browserBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "company.thebrowser.Browser",
    ]

    public func classifyAll(_ spans: [EffectiveSpan]) -> [ClassifiedSpan] {
        spans.map(classify)
    }

    /// Rule-only resolution of a key (ignores overrides). Cached.
    public func resolve(_ key: ClassifyKey) -> ClassifyResult {
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let r = compute(key)
        lock.lock(); cache[key] = r; lock.unlock()
        return r
    }

    /// Review queue: active, rule-uncategorized, un-overridden time grouped by key,
    /// groups under `minMs` dropped, longest first.
    public func uncategorizedGroups(_ spans: [EffectiveSpan], minMs: Int64 = 60_000) -> [(key: ClassifyKey, totalMs: Int64)] {
        var totals: [ClassifyKey: Int64] = [:]
        for s in spans where s.kind == .active && s.source == .tracked && s.categoryOverride == nil {
            let key = ClassifyKey(s)
            if resolve(key).categoryId == nil { totals[key, default: 0] += s.durationMs }
        }
        return totals.filter { $0.value >= minMs }
            .sorted { $0.value != $1.value ? $0.value > $1.value : ($0.key.appName, $0.key.title ?? "") < ($1.key.appName, $1.key.title ?? "") }
            .map { (key: $0.key, totalMs: $0.value) }
    }

    /// nil when the rule is saveable; otherwise a user-facing reason.
    public static func validationError(_ rule: Rule) -> String? {
        let hasPredicate = rule.bundleId != nil || rule.appName != nil || rule.host != nil
            || rule.pathPrefix != nil || rule.titleRegex != nil
        if !hasPredicate { return "Rule needs at least one condition." }
        if rule.categoryId == nil && rule.projectId == nil { return "Rule needs a category or a project." }
        if let p = rule.titleRegex, (try? NSRegularExpression(pattern: p, options: [.caseInsensitive])) == nil {
            return "Title pattern is not a valid regular expression."
        }
        return nil
    }

    /// `(bundle?10) + (app?8) + (host? 20 + 2·labels) + (path? 10 + len/8) + (title?15)`.
    public static func specificity(_ rule: Rule) -> Int {
        var s = 0
        if rule.bundleId != nil { s += 10 }
        if rule.appName != nil { s += 8 }
        if let h = rule.host { s += 20 + 2 * h.split(separator: ".").count }
        if let p = rule.pathPrefix { s += 10 + p.count / 8 }
        if rule.titleRegex != nil { s += 15 }
        return s
    }

    // MARK: - Private

    private func compute(_ key: ClassifyKey) -> ClassifyResult {
        let host = ClassifyURL.host(key.url)
        let path = host == nil ? nil : ClassifyURL.path(key.url)
        let appLower = key.appName.lowercased()

        var cands: [Int] = unindexed
        if let b = key.bundleId, let r = byBundle[b] { cands += r }
        if let a = byAppName[appLower] { cands += a }
        if let host {
            for suffix in ClassifyURL.suffixes(host) {
                if let r = byHost[String(suffix)] { cands += r }
            }
            var prefix = ""
            for label in host.split(separator: ".").dropLast() where !byHostPrefix.isEmpty {
                prefix += prefix.isEmpty ? String(label) : "." + label
                if let r = byHostPrefix[prefix] { cands += r }
            }
        }

        var bestCat: Int?, bestProj: Int?
        for rank in cands {
            let wantsCat = compiled[rank].categoryId != nil && rank < (bestCat ?? .max)
            let wantsProj = compiled[rank].projectId != nil && rank < (bestProj ?? .max)
            guard wantsCat || wantsProj,
                  compiled[rank].matches(key, appLower: appLower, host: host, path: path) else { continue }
            if wantsCat { bestCat = rank }
            if wantsProj { bestProj = rank }
        }
        return ClassifyResult(categoryId: bestCat.map { compiled[$0].categoryId! },
                              projectId: bestProj.map { compiled[$0].projectId! },
                              categoryRuleId: bestCat.map { compiled[$0].rule.id },
                              projectRuleId: bestProj.map { compiled[$0].rule.id })
    }

    private struct Compiled {
        let rule: Rule
        let appLower: String?
        let host: String?
        let regex: NSRegularExpression?
        let score: Int
        /// Targets referencing unknown categories/projects are dropped.
        let categoryId: Int64?
        let projectId: Int64?

        init?(_ rule: Rule, categoryIds: Set<Int64>, projectIds: Set<Int64>) {
            guard Classifier.validationError(rule) == nil else { return nil }
            self.rule = rule
            appLower = rule.appName?.lowercased()
            host = rule.host.map(ClassifyURL.normalizeHost)
            regex = rule.titleRegex.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
            score = Classifier.specificity(rule)
            categoryId = rule.categoryId.flatMap { categoryIds.contains($0) ? $0 : nil }
            projectId = rule.projectId.flatMap { projectIds.contains($0) ? $0 : nil }
            if categoryId == nil && projectId == nil { return nil }
        }

        static func precedes(_ a: Compiled, _ b: Compiled) -> Bool {
            if a.rule.priority != b.rule.priority { return a.rule.priority > b.rule.priority }
            if a.score != b.score { return a.score > b.score }
            if a.rule.origin != b.rule.origin { return a.rule.origin == .user }
            return a.rule.id < b.rule.id
        }

        func matches(_ key: ClassifyKey, appLower spanApp: String, host spanHost: String?, path: String?) -> Bool {
            if let b = rule.bundleId, b != key.bundleId { return false }
            if let a = appLower, a != spanApp { return false }
            if let h = host {
                guard let spanHost, ClassifyURL.hostMatches(h, spanHost) else { return false }
            }
            if let p = rule.pathPrefix {
                guard let path, path.hasPrefix(p) else { return false }
            }
            if let regex {
                guard let t = key.title else { return false }
                if regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) == nil { return false }
            }
            return true
        }
    }
}
