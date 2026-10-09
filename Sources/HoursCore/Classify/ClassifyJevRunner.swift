import Foundation

/// Finds Jev cache misses and asks Jev about each one (4 in flight), then writes the cache in one
/// transaction. Used by the app (visible day + today, after a refetch) and `spellsctl classify`.
public enum ClassifyJevRunner {
    public struct Miss: Sendable, Hashable {
        public var key: JevKey
        /// One window that produced the key; its app name and raw title go into the request.
        public var sample: ClassifyKey
        public var totalMs: Int64
    }

    public struct Report: Sendable {
        public var requests = 0, answered = 0, failed = 0, inputTokens = 0
        public var unauthorized = false
        /// Answered category keys this run.
        public var histogram: [String: Int] = [:]
    }

    /// Distinct misses among `spans`, longest first. Nothing when the classifier has no enabled snapshot.
    /// Never a miss: idle, manual or category-edited spans; keys a rule categorises (so `exclude`
    /// categories never leave the machine); windows without a title (private/incognito, Safari/Arc);
    /// keys the cache answers at any tier or that failed and aren't due for a retry.
    public static func misses(_ spans: [EffectiveSpan], classifier: Classifier) -> [Miss] {
        guard let jev = classifier.jev, jev.settings.enabled else { return [] }
        var out: [String: Miss] = [:]
        var seen: [ClassifyKey: JevKey?] = [:]
        for s in spans where s.kind == .active && s.source == .tracked && s.categoryOverride == nil {
            let ck = ClassifyKey(s)
            let jk: JevKey?
            if let cached = seen[ck] { jk = cached } else {
                jk = classifier.resolve(ck).categoryId == nil
                    ? ClassifyJevKey.make(ck, includeTitle: jev.settings.sendTitles).flatMap { jev.covers($0) ? nil : $0 }
                    : nil
                seen[ck] = jk
            }
            guard let jk else { continue }
            out[jk.id, default: Miss(key: jk, sample: ck, totalMs: 0)].totalMs += s.durationMs
        }
        return out.values.sorted { $0.totalMs != $1.totalMs ? $0.totalMs > $1.totalMs : $0.key.id < $1.key.id }
    }

    /// Misses over whole store days.
    public static func misses(db: HoursDB, days: [LocalDate], classifier: Classifier) throws -> [Miss] {
        let store = Store(db)
        return misses(try days.flatMap { try store.effectiveSpans(day: $0) }, classifier: classifier)
    }

    /// One request per miss, `concurrency` in flight; every answer and failure is stored in one write.
    /// A 401/403 stops dispatching (that key's row isn't written).
    public static func run(_ misses: [Miss], db: HoursDB, client: JevClient, categories: [Category],
                           projects: [Project], nowMs: Int64, concurrency: Int = 4) async throws -> Report {
        var report = Report()
        var rows: [JevEntry] = []
        await withTaskGroup(of: JevClient.Outcome.self) { group in
            var next = misses.makeIterator()
            func body(_ m: Miss) -> Data { ClassifyJevPrompt.body(key: m.key, sample: m.sample, categories: categories, projects: projects) }
            for _ in 0..<max(1, concurrency) {
                guard let m = next.next() else { break }
                let b = body(m)
                group.addTask { await client.classify(m.key, body: b, nowMs: nowMs) }
                report.requests += 1
            }
            for await outcome in group {
                switch outcome {
                case .answered(let e):
                    rows.append(e)
                    report.answered += 1
                    report.inputTokens += e.inputTokens
                    report.histogram[e.categoryKey ?? "?", default: 0] += 1
                case .failed(let e):
                    rows.append(e)
                    report.failed += 1
                case .unauthorized:
                    report.unauthorized = true
                }
                if !report.unauthorized, let m = next.next() {
                    let b = body(m)
                    group.addTask { await client.classify(m.key, body: b, nowMs: nowMs) }
                    report.requests += 1
                }
            }
        }
        try JevCacheStore(db).upsert(rows)
        return report
    }
}
