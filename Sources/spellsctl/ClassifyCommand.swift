import Foundation
import HoursCore

/// `spellsctl classify [--since YYYY-MM-DD] [--dry-run]`: Jev backfill of rule-unmatched windows since
/// `--since` (default: 30 days ago). `--dry-run` counts misses without any network or keychain access.
func classify() async throws {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let since: LocalDate
    if let s = options["--since"] {
        guard let d = LocalDate(iso: s) else { die("bad --since '\(s)' (YYYY-MM-DD)") }
        since = d
    } else {
        since = LocalDate.containing(ms: nowMs - 30 * 86_400_000, in: tz)
    }
    let db = openDB()
    let config = try ExportConfig.load(db)
    let snapshot = try JevCacheStore(db).snapshot(nowMs: nowMs)
    guard snapshot.settings.enabled else { die("Jev classification is off (Settings → Classification)", 1) }
    let classifier = Classifier(categories: config.categories, rules: config.rules, projects: config.projects, jev: snapshot)

    let spans = try Store(db).effectiveSpans(rangeFrom: since.dayInterval(in: tz).lowerBound, to: nowMs)
        .filter { $0.kind == .active && $0.source == .tracked }
    let keys = Set(spans.map(ClassifyKey.init))
    let unmatched = keys.filter { classifier.resolve($0).categoryId == nil }
    let misses = ClassifyJevRunner.misses(spans, classifier: classifier)
    say("\(since)..\(today): \(spans.count) active spans, \(keys.count) distinct windows, \(unmatched.count) rule-unmatched; "
        + "\(snapshot.count) cached Jev answers; \(misses.count) cache miss(es) → \(misses.count) Jev request(s)")

    if flags.contains("--dry-run") {
        for m in misses.prefix(20) {
            let place = m.key.isWeb ? "\(m.key.host)\(m.key.pathTpl)" : m.key.app
            say("  \(String(format: "%5.1f", Double(m.totalMs) / 60_000)) min  \(place)  \(m.key.titleNorm)")
        }
        if misses.count > 20 { say("  … \(misses.count - 20) more") }
        say("dry run: no requests sent")
        return
    }

    if !misses.isEmpty {
        guard let client = JevClient.live() else {
            die("no TypeSafe key: set TYPESAFE_API_KEY or add Keychain item service 'typesafe-api-key', account '\(NSUserName())'", 1)
        }
        let r = try await ClassifyJevRunner.run(misses, db: db, client: client, categories: config.categories,
                                                projects: config.projects, nowMs: nowMs)
        if r.unauthorized { die("TypeSafe rejected the API key (401/403); nothing stored for the remaining keys", 1) }
        say("requests: \(r.requests) (answered \(r.answered), failed \(r.failed)), input tokens this run: \(r.inputTokens)")
        say("answers this run: " + r.histogram.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    } else {
        say("requests: 0 (every unmatched window is cached, fuzzy-matched, or waiting to retry)")
    }

    // Where the rule-unmatched windows land now: Jev category, Browsing fallback, or Uncategorized.
    let after = Classifier(categories: config.categories, rules: config.rules, projects: config.projects,
                           jev: try JevCacheStore(db).snapshot(nowMs: nowMs))
    let names = Dictionary(config.categories.map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
    var hist: [String: (windows: Int, ms: Int64)] = [:]
    var msByKey: [ClassifyKey: Int64] = [:]
    for s in spans { msByKey[ClassifyKey(s), default: 0] += s.durationMs }
    for k in unmatched {
        let r = after.resolution(k)
        let label = switch r.source {
        case .jev: "\(r.categoryId.flatMap { names[$0] } ?? "?") (jev)"
        case .fallback: "browsing (fallback)"
        default: "uncategorized"
        }
        hist[label, default: (0, 0)].windows += 1
        hist[label, default: (0, 0)].ms += msByKey[k] ?? 0
    }
    say("category histogram (rule-unmatched windows):")
    for (label, v) in hist.sorted(by: { $0.value.ms != $1.value.ms ? $0.value.ms > $1.value.ms : $0.key < $1.key }) {
        say("  \(label.padding(toLength: 24, withPad: " ", startingAt: 0)) \(String(format: "%4d", v.windows)) windows  \(String(format: "%6.1f", Double(v.ms) / 60_000)) min")
    }
    let monthStart = LocalDate(year: today.year, month: today.month, day: 1).dayInterval(in: tz).lowerBound
    say("cache: \(try JevCacheStore(db).count()) answers; input tokens this month: \(try JevCacheStore(db).inputTokens(sinceMs: monthStart))")
}
