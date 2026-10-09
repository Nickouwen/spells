import Foundation
import HoursCore

/// A rule-unmatched window Jev answered below the confidence bar (so nothing was applied).
struct JevSuggestion: Sendable, Hashable {
    var key: ClassifyKey
    var hit: JevHit
    var totalMs: Int64
}

/// Settings → Classification reads and writes. Settings writes post the change feed, so the
/// classifier rebuilds on the next refetch.
extension AppModel {
    var jevSettings: JevSettings { JevSettings(settings) }

    /// (answered entries, input tokens since the 1st of this month).
    func jevStats() async -> (count: Int, tokensThisMonth: Int) {
        let (db, today, tz) = (self.db, self.today, self.timeZone)
        let monthStart = LocalDate(year: today.year, month: today.month, day: 1).dayInterval(in: tz).lowerBound
        return (try? await Task.detached {
            let store = JevCacheStore(db)
            return (try store.count(), try store.inputTokens(sinceMs: monthStart))
        }.value) ?? (0, 0)
    }

    func clearJevCache() async {
        let db = self.db
        do { try await Task.detached { try JevCacheStore(db).clear() }.value } catch {
            SupportLog.app.error("jev cache not cleared: \(String(describing: error), privacy: .public)")
        }
        await refetch()
    }

    /// Rule-unmatched windows of the last `days` days that Jev answered below `jev_min_confidence`, longest first.
    func jevSuggestions(days: Int = 7) async -> [JevSuggestion] {
        let (db, now, classifier) = (self.db, nowMs, self.classifier)
        guard let min = classifier.jev?.settings.minConfidence else { return [] }
        return (try? await Task.detached {
            var totals: [ClassifyKey: Int64] = [:]
            for s in try Store(db).effectiveSpans(rangeFrom: now - Int64(days) * 86_400_000, to: now)
            where s.kind == .active && s.source == .tracked && s.categoryOverride == nil {
                totals[ClassifyKey(s), default: 0] += s.durationMs
            }
            return totals.compactMap { key, ms -> JevSuggestion? in
                guard classifier.resolve(key).categoryId == nil, let hit = classifier.jevHit(key),
                      hit.confidence < min, hit.categoryKey != "other" else { return nil }
                return JevSuggestion(key: key, hit: hit, totalMs: ms)
            }
            .sorted { $0.totalMs != $1.totalMs ? $0.totalMs > $1.totalMs : $0.key.appName < $1.key.appName }
        }.value) ?? []
    }
}
