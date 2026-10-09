import SwiftUI
import HoursCore

/// Review queue (uncategorized → one-click rule), rule list, add / edit / delete with a live
/// "which windows does this match, and does it win" preview.
struct SettingsRulesTab: View {
    let model: AppModel
    @State private var queue: [(key: ClassifyKey, totalMs: Int64)] = []
    @State private var editing: Rule?
    @State private var showSeed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let user = model.rules.filter { $0.origin == .user }
        let seed = model.rules.filter { $0.origin == .seed }
        SettingsPage {
            SettingsSection("Needs a category", detail: "Uncategorized windows from the last 7 days, longest first.") {
                if queue.isEmpty {
                    Text("Nothing to review.").textRole(.body, Theme.inkSecondary)
                }
                ForEach(Array(queue.prefix(12).enumerated()), id: \.offset) { i, item in
                    if i > 0 { SettingsDivider() }
                    SettingsReviewRow(key: item.key, totalMs: item.totalMs, categories: model.categories) { rule in
                        Task { await model.save(rule); await reloadQueue() }
                    }
                }
            }
            SettingsSection("Your rules", detail: "A rule beats seed rules on a tie; higher priority always wins.") {
                if user.isEmpty { Text("No rules yet.").textRole(.body, Theme.inkSecondary) }
                ruleRows(user)
                HStack {
                    Spacer()
                    Button("Add Rule") { editing = Rule(id: 0, origin: .user) }.buttonStyle(HoursButtonStyle())
                }
                .padding(.top, Theme.Space.s)
            }
            .animation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion), value: user.map(\.id))
            SettingsSection("Built-in rules", detail: "\(seed.count) rules shipped with Hours. Disable any you disagree with.") {
                DisclosureGroup(isExpanded: $showSeed) {
                    ruleRows(seed).padding(.top, Theme.Space.s)
                } label: {
                    Text(showSeed ? "Hide" : "Show all").textRole(.label, Theme.inkSecondary)
                }
            }
        }
        .task { await reloadQueue() }
        .sheet(item: $editing) { rule in
            SettingsRuleEditor(model: model, original: rule) { editing = nil; Task { await reloadQueue() } }
        }
    }

    @ViewBuilder private func ruleRows(_ rules: [Rule]) -> some View {
        ForEach(Array(rules.enumerated()), id: \.element.id) { i, r in
            if i > 0 { SettingsDivider() }
            SettingsRuleRow(rule: r, model: model, invalid: model.classifier.invalidRuleIds.contains(r.id),
                            onEdit: { editing = r },
                            onToggle: { on in var x = r; x.enabled = on; Task { await model.save(x) } })
        }
    }

    private func reloadQueue() async { queue = await model.reviewQueue() }
}

struct SettingsReviewRow: View {
    let key: ClassifyKey
    let totalMs: Int64
    let categories: [HoursCore.Category]
    let onRule: (Rule) -> Void

    var body: some View {
        let span = SettingsRuleText.span(key)
        let host = ClassifyURL.host(key.url)
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(host ?? key.appName).textRole(.bodyEmph).lineLimit(1)
                Text(key.title ?? "—").textRole(.label, Theme.inkSecondary).lineLimit(1)
            }
            Spacer()
            Text(Fmt.duration(ms: totalMs)).textRole(.body, Theme.inkSecondary)
            Menu("Categorize") {
                Section("All \(key.appName)") { targets(span, .app) }
                if let host { Section("All \(host)") { targets(span, .host) } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder private func targets(_ span: EffectiveSpan, _ field: ClassifyRuleSuggester.Field) -> some View {
        ForEach(categories.filter { !$0.archived && $0.key != "uncategorized" }) { c in
            Button(c.name) {
                if let r = ClassifyRuleSuggester.rule(from: span, field: field, categoryId: c.id) { onRule(r) }
            }
        }
    }
}

struct SettingsRuleRow: View {
    let rule: Rule
    let model: AppModel
    let invalid: Bool
    let onEdit: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { onToggle($0) }))
                .toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(SettingsRuleText.predicates(rule)).textRole(.mono, rule.enabled ? Theme.ink : Theme.inkTertiary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: Theme.Space.s) {
                    if let c = model.categories.first(where: { $0.id == rule.categoryId }) { CategoryChip(c) }
                    if let p = model.projects.first(where: { $0.id == rule.projectId }) {
                        Text(p.name).textRole(.label, Theme.inkSecondary)
                    }
                    if rule.priority != 0 { Text("priority \(rule.priority)").textRole(.label, Theme.inkTertiary) }
                    if invalid { Text("invalid pattern — ignored").textRole(.label, Theme.inkSecondary) }
                }
            }
            Spacer()
            Button("Edit", action: onEdit).buttonStyle(.borderless).textRole(.label, Theme.inkSecondary)
        }
    }
}

/// Add / edit sheet. Validation via `Classifier.validationError`; preview against recent windows.
struct SettingsRuleEditor: View {
    let model: AppModel
    let original: Rule
    let onDone: () -> Void
    @State private var draft: Rule
    @State private var keys: [(key: ClassifyKey, totalMs: Int64)] = []

    init(model: AppModel, original: Rule, onDone: @escaping () -> Void) {
        self.model = model
        self.original = original
        self.onDone = onDone
        _draft = State(initialValue: original)
    }

    var body: some View {
        let error = Classifier.validationError(draft)
        let preview = SettingsRulePreview.compute(draft: draft, model: model, keys: keys)
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(original.id > 0 ? "Edit Rule" : "New Rule").textRole(.title)
            Text("All conditions must match. Leave a field empty to ignore it.").textRole(.label, Theme.inkSecondary)
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                field("Bundle id", \.bundleId, "com.microsoft.VSCode")
                field("App name", \.appName, "Code")
                field("Host", \.host, "github.com")
                field("Path prefix", \.pathPrefix, "/ExampleOrg/hours")
                field("Title pattern", \.titleRegex, "regular expression")
                GridRow {
                    Text("Category").textRole(.body)
                    Picker("", selection: $draft.categoryId) {
                        Text("None").tag(Int64?.none)
                        ForEach(model.categories.filter { !$0.archived && $0.key != "uncategorized" }) { Text($0.name).tag(Int64?.some($0.id)) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Project").textRole(.body)
                    Picker("", selection: $draft.projectId) {
                        Text("None").tag(Int64?.none)
                        ForEach(model.projects.filter { !$0.archived }) { Text($0.name).tag(Int64?.some($0.id)) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Priority").textRole(.body)
                    Stepper("\(draft.priority)", value: $draft.priority, in: -10...10).textRole(.body)
                }
            }
            if let error { Text(error).textRole(.label, Theme.inkSecondary) }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(preview.summary).textRole(.bodyEmph)
                ForEach(Array(preview.rows.prefix(6).enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.label).textRole(.label).lineLimit(1)
                        Spacer()
                        Text(row.verdict).textRole(.label, Theme.inkSecondary)
                        Text(Fmt.duration(ms: row.ms)).textRole(.label, Theme.inkTertiary)
                    }
                }
            }
            .hoursCard(padding: Theme.Space.m)
            HStack {
                if original.id > 0 {
                    Button("Delete Rule") { Task { await model.deleteRule(id: original.id); onDone() } }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Save") { Task { await model.save(draft); onDone() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(error != nil)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
        .task { keys = await model.recentKeys() }
    }

    private func field(_ label: String, _ path: WritableKeyPath<Rule, String?>, _ prompt: String) -> some View {
        GridRow {
            Text(label).textRole(.body)
            TextField(prompt, text: Binding(get: { draft[keyPath: path] ?? "" },
                                            set: { draft[keyPath: path] = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// "Matches N windows · wins M" — which recent windows the draft matches, and whether it beats
/// the existing rules there (the same winner logic the classifier uses).
enum SettingsRulePreview {
    struct Row { var label: String; var ms: Int64; var verdict: String }
    struct Result { var summary: String; var rows: [Row] }

    static let draftId = Int64.max - 1

    @MainActor static func compute(draft: Rule, model: AppModel, keys: [(key: ClassifyKey, totalMs: Int64)]) -> Result {
        compute(draft: draft, rules: model.rules, categories: model.categories, projects: model.projects, keys: keys)
    }

    static func compute(draft: Rule, rules: [Rule], categories: [HoursCore.Category], projects: [Project],
                        keys: [(key: ClassifyKey, totalMs: Int64)]) -> Result {
        guard Classifier.validationError(draft) == nil else { return Result(summary: "Preview appears once the rule is valid.", rows: []) }
        var d = draft
        if d.id <= 0 { d.id = draftId }
        let alone = Classifier(categories: categories, rules: [d], projects: projects)
        let all = Classifier(categories: categories, rules: rules.filter { $0.id != d.id } + [d], projects: projects)
        var rows: [Row] = []
        var wins = 0, total: Int64 = 0
        for (key, ms) in keys {
            let a = alone.resolve(key)
            guard a.categoryRuleId == d.id || a.projectRuleId == d.id else { continue }
            let r = all.resolve(key)
            let won = (d.categoryId == nil || r.categoryRuleId == d.id) && (d.projectId == nil || r.projectRuleId == d.id)
            if won { wins += 1 }
            total += ms
            let other = d.categoryId != nil && r.categoryRuleId != d.id ? r.categoryRuleId : r.projectRuleId
            let loser = rules.first { $0.id == other }.map { "loses to \(SettingsRuleText.predicates($0))" } ?? "loses"
            rows.append(Row(label: key.title ?? ClassifyURL.host(key.url) ?? key.appName, ms: ms, verdict: won ? "wins" : loser))
        }
        let summary = rows.isEmpty ? "Matches nothing in the last 7 days."
            : "Matches \(rows.count) window\(rows.count == 1 ? "" : "s") (\(Fmt.duration(ms: total))) · wins \(wins)"
        return Result(summary: summary, rows: rows)
    }
}

enum SettingsRuleText {
    static func predicates(_ r: Rule) -> String {
        var parts: [String] = []
        if let v = r.bundleId { parts.append("bundle \(v)") }
        if let v = r.appName { parts.append("app \(v)") }
        if let v = r.host { parts.append("host \(v)") }
        if let v = r.pathPrefix { parts.append("path \(v)") }
        if let v = r.titleRegex { parts.append("title /\(v)/") }
        return parts.isEmpty ? "(no conditions)" : parts.joined(separator: " · ")
    }

    /// A representative span for a review-queue key (the suggester reads app/url/title from it).
    static func span(_ k: ClassifyKey) -> EffectiveSpan {
        EffectiveSpan(startMs: 0, endMs: 0, tzId: "UTC", kind: .active, bundleId: k.bundleId, appName: k.appName,
                      title: k.title, url: k.url, rawSeq: nil)
    }
}
