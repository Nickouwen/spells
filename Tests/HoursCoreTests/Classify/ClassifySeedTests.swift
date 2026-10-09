import Testing
@testable import HoursCore

private let S = ClassifySeed.self

@Suite struct ClassifySeedTests {
    @Test func categoriesShape() {
        #expect(S.categories.count == 13)
        #expect(Set(S.categories.map(\.id)) == Set(1...13))
        #expect(Set(S.categories.map(\.key)).count == 13)
        #expect(S.categories.compactMap(\.colorSlot) == Array(0...9))
        #expect(S.categories.filter { $0.colorSlot == nil }.map(\.key) == ["uncategorized", "excluded", "browsing"])
        // productive ⇒ work; distracting ⇒ not work; Uncategorized ≠ work.
        for c in S.categories {
            if c.level == .productive { #expect(c.isWork) }
            if c.level == .distracting { #expect(!c.isWork) }
        }
        #expect(S.categories.first { $0.id == S.uncategorized }?.isWork == false)
        #expect(S.categories.filter { $0.behavior == .meeting }.map(\.id) == [S.meetings])
    }

    @Test func rulesShape() {
        let catIds = Set(S.categories.map(\.id)), projIds = Set(S.projects.map(\.id))
        #expect(Set(S.rules.map(\.id)).count == S.rules.count)
        #expect(Set(S.rules.compactMap(\.seedKey)).count == S.rules.count)
        for r in S.rules {
            #expect(r.origin == .seed)
            #expect(Classifier.validationError(r) == nil, "\(r.seedKey ?? "")")
            if let id = r.categoryId { #expect(catIds.contains(id)) }
            if let id = r.projectId { #expect(projIds.contains(id)) }
        }
        // No browser bundle rules: unmatched sites must land in the review queue.
        let browsers: Set<String> = ["com.google.Chrome", "company.thebrowser.Browser", "com.apple.Safari"]
        #expect(S.rules.allSatisfy { !browsers.contains($0.bundleId ?? "") })
        #expect(S.projects.map(\.name) == ["client-monitoring", "operations-dashboard", "data-scrapers",
                                           "outreach-systems", "example-ui-prototype", "spells"])
        #expect(S.rules.filter { $0.projectId != nil }.map(\.id) == Array(1001...1007))
    }

    /// Teams counts as Meetings only in a call window, not the chat it lives in all day.
    @Test func teamsIsAMeetingOnlyInACall() {
        let c = seedClassifier()
        func teams(_ title: String) -> Int64? { c.category(classifySpan("com.microsoft.teams2", app: "Microsoft Teams", title: title)) }
        #expect(teams("Meeting with Alex Client | Microsoft Teams") == S.meetings)
        #expect(teams("Call with Jordan | Microsoft Teams") == S.meetings)
        #expect(teams("Weekly sync (Meeting) | Microsoft Teams") == S.meetings)
        #expect(teams("Chat | Alex Client | Microsoft Teams") != S.meetings)
        #expect(teams("Calls | Microsoft Teams") != S.meetings)
        #expect(teams("Calendar | Microsoft Teams") != S.meetings)
    }

    // Acceptance 11
    @Test func mergeKeepsUserChoicesAndIsIdempotent() {
        var existing = S.merge(into: [])
        #expect(existing == S.rules)
        let user = Rule(id: 2000, origin: .user, host: "github.com", categoryId: S.planning)
        existing.append(user)
        let ghIndex = existing.firstIndex { $0.seedKey == "coding.github" }!
        existing[ghIndex].enabled = false

        var seed = S.rules
        let seedIndex = seed.firstIndex { $0.seedKey == "coding.github" }!
        seed[seedIndex].categoryId = S.research
        seed.append(Rule(id: 900, origin: .seed, seedKey: "new.rule", host: "new.example", categoryId: S.coding))
        seed.append(Rule(id: 2000, origin: .seed, seedKey: "new.clash", host: "clash.example", categoryId: S.coding))

        let merged = S.merge(seed: seed, into: existing)
        let gh = merged.first { $0.seedKey == "coding.github" }!
        #expect(gh.categoryId == S.research)
        #expect(gh.enabled == false)
        #expect(gh.id == existing[ghIndex].id)
        #expect(merged.contains(user))
        #expect(merged.first { $0.seedKey == "new.rule" }?.id == 900)
        let clash = merged.first { $0.seedKey == "new.clash" }!
        #expect(clash.id != 2000)
        #expect(Set(merged.map(\.id)).count == merged.count)

        #expect(S.merge(seed: seed, into: merged) == merged)
    }

    // Acceptance 13
    @Test func reviewQueueThresholdAndOrder() {
        let c = seedClassifier()
        let a = classifySpan(title: "Blog A", url: "https://a.example/", ms: 30_000)
        let b = classifySpan(title: "Blog B", url: "https://b.example/", ms: 45_000)
        let d = classifySpan(title: "Blog D", url: "https://d.example/", ms: 120_000)
        let pinned = classifySpan(title: "Pinned", url: "https://p.example/", ms: 600_000, category: S.personal)
        let idle = classifySpan(title: "Idle", url: "https://i.example/", ms: 600_000, kind: .idle)
        let coding = classifySpan("com.microsoft.VSCode", app: "Code", title: "x", ms: 600_000)
        let groups = c.uncategorizedGroups([a, b, b, d, pinned, idle, coding])
        #expect(groups.map(\.key.title) == ["Blog D", "Blog B"])   // 120 s, 90 s; A's 30 s dropped
        #expect(groups.map(\.totalMs) == [120_000, 90_000])
    }

    @Test func suggesterPresets() {
        let s = classifySpan(title: "Spec — Acme", url: "https://www.acme.com/a?b")
        #expect(ClassifyRuleSuggester.rule(from: s, field: .app) == nil)  // no target
        let app = ClassifyRuleSuggester.rule(from: s, field: .app, categoryId: S.coding)!
        #expect(app.bundleId == "com.google.Chrome" && app.host == nil && app.origin == .user && app.id == 0)
        let host = ClassifyRuleSuggester.rule(from: s, field: .host, categoryId: S.coding)!
        #expect(host.host == "acme.com" && host.bundleId == nil)
        let both = ClassifyRuleSuggester.rule(from: s, field: .appAndHost, projectId: 1)!
        #expect(both.bundleId == "com.google.Chrome" && both.host == "acme.com" && both.projectId == 1)
        #expect(ClassifyRuleSuggester.rule(from: classifySpan(url: nil), field: .host, categoryId: S.coding) == nil)

        let noBundle = classifySpan(nil, app: "Ghostty")
        #expect(ClassifyRuleSuggester.rule(from: noBundle, field: .app, categoryId: S.coding)?.appName == "Ghostty")

        // Title contains is literal: "a.b" must not match "axb".
        let t = ClassifyRuleSuggester.rule(from: s, field: .titleContains("a.b (1)"), categoryId: S.planning)!
        let c = Classifier(categories: S.categories, rules: [Rule(id: 1, origin: .user, titleRegex: t.titleRegex, categoryId: S.planning)], projects: [])
        #expect(c.category(classifySpan(title: "x A.B (1) y")) == S.planning)
        #expect(c.category(classifySpan(title: "axb (1)")) == nil)
    }
}
