import SwiftUI
import HoursCore

/// Jev fallback (W24): on/off, confidence bar, title sending, cache size + clear, tokens this month,
/// and below-the-bar suggestions with one-click "Make rule".
/// Values are held locally once changed: `model.settings` only refetches while the main window is visible.
struct SettingsClassificationTab: View {
    let model: AppModel
    @State private var values: JevSettings?
    @State private var stats: (count: Int, tokensThisMonth: Int) = (0, 0)
    @State private var suggestions: [JevSuggestion] = []

    var body: some View {
        let v = values ?? model.jevSettings
        SettingsPage {
            SettingsSection("Jev", detail: "Windows no rule matches are classified by TypeSafe's Jev model. Each kind of page is asked about once and cached. Rules and your edits always win; private windows and excluded apps are never sent.") {
                Toggle("Classify unmatched windows with Jev", isOn: Binding(get: { v.enabled }, set: { on in
                    update(JevSettings.enabledKey, on ? "1" : "0") { $0.enabled = on }
                }))
                .toggleStyle(.switch)
                .textRole(.body)
                SettingsDivider()
                HStack {
                    Text("Minimum confidence").textRole(.body)
                    Spacer()
                    Text("\(Int((v.minConfidence * 100).rounded())) %").textRole(.bodyEmph).accessibilityHidden(true)
                    Stepper("Minimum confidence", value: Binding(get: { v.minConfidence }, set: { c in
                        let r = (c * 20).rounded() / 20
                        update(JevSettings.minConfidenceKey, String(r)) { $0.minConfidence = r }
                    }), in: 0.5...0.95, step: 0.05)
                    .labelsHidden()
                    .accessibilityValue("\(Int((v.minConfidence * 100).rounded())) percent")
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Toggle("Send page titles", isOn: Binding(get: { v.sendTitles }, set: { on in
                        update(JevSettings.sendTitlesKey, on ? "1" : "0") { $0.sendTitles = on }
                    }))
                    .toggleStyle(.switch)
                    .textRole(.body)
                    Text("Off: only the app, site and path template are sent (never query strings).")
                        .textRole(.label, Theme.inkSecondary)
                }
            }
            SettingsSection("Cache", detail: "Answers are kept until cleared and reused for similar pages.") {
                row("Cached answers", "\(stats.count)")
                SettingsDivider()
                row("Input tokens this month", stats.tokensThisMonth.formatted())
                SettingsDivider()
                HStack {
                    Spacer()
                    Button("Clear Cache") { Task { await model.clearJevCache(); await reload() } }
                        .buttonStyle(HoursButtonStyle())
                        .settingsDimsWhenDisabled()
                        .disabled(stats.count == 0)
                }
            }
            SettingsSection("Jev suggestions", detail: "Answers below your confidence bar from the last 7 days, so not applied. Make a rule to accept one.") {
                if suggestions.isEmpty {
                    Text("Nothing to review.").textRole(.body, Theme.inkSecondary)
                }
                ForEach(Array(suggestions.prefix(12).enumerated()), id: \.offset) { i, s in
                    if i > 0 { SettingsDivider() }
                    suggestionRow(s)
                }
            }
        }
        .task { await reload() }
    }

    private func suggestionRow(_ s: JevSuggestion) -> some View {
        let host = ClassifyURL.host(s.key.url)
        let category = model.categories.first { $0.key == s.hit.categoryKey }
        return HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(host ?? s.key.appName).textRole(.bodyEmph).lineLimit(1)
                Text(s.key.title ?? "—").textRole(.label, Theme.inkSecondary).lineLimit(1)
                Text("Jev suggests \(category?.name ?? s.hit.categoryKey) (\(Int((s.hit.confidence * 100).rounded())) %)")
                    .textRole(.label, Theme.inkSecondary)
            }
            Spacer()
            Text(Fmt.duration(ms: s.totalMs)).textRole(.body, Theme.inkSecondary)
            Button("Make rule") {
                guard let category, let rule = Self.rule(for: s.key, categoryId: category.id) else { return }
                Task { await model.save(rule); await reload() }
            }
            .buttonStyle(HoursButtonStyle())
            .settingsDimsWhenDisabled()
            .disabled(category == nil)
        }
    }

    /// Site rule for web pages, app rule otherwise.
    static func rule(for key: ClassifyKey, categoryId: Int64) -> Rule? {
        let span = EffectiveSpan(startMs: 0, endMs: 1, tzId: "UTC", kind: .active, bundleId: key.bundleId,
                                 appName: key.appName, title: key.title, url: key.url, rawSeq: nil)
        return ClassifyRuleSuggester.rule(from: span, field: ClassifyURL.host(key.url) == nil ? .app : .host,
                                          categoryId: categoryId)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).textRole(.body); Spacer(); Text(value).textRole(.bodyEmph) }
    }

    private func reload() async {
        stats = await model.jevStats()
        suggestions = await model.jevSuggestions()
    }

    /// Optimistic local update + an off-main write; the change feed rebuilds the classifier.
    private func update(_ key: String, _ value: String, _ apply: (inout JevSettings) -> Void) {
        var v = values ?? model.jevSettings
        apply(&v)
        values = v
        let db = model.db
        Task.detached(priority: .userInitiated) {
            do { try SettingStore(db).set(key, value) } catch {
                SupportLog.app.error("\(key, privacy: .public) not saved: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
