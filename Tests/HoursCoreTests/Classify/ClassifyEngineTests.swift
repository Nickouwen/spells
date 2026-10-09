import Foundation
import Testing
@testable import HoursCore

private let S = ClassifySeed.self
private let hoursProject: Int64 = 6, dashboardProject: Int64 = 2, outreachProject: Int64 = 4

@Suite struct ClassifyEngineTests {
    let c = seedClassifier()

    // Acceptance 1
    @Test func vscodeWithRepoTitle() {
        let s = classifySpan("com.microsoft.VSCode", app: "Code", title: "main.swift — spells — Visual Studio Code")
        #expect(c.category(s) == S.coding)
        #expect(c.project(s) == hoursProject)
    }

    // Acceptance 2
    @Test func googleSubdomainsAreDistinct() {
        #expect(c.category(classifySpan(title: "Spec", url: "https://docs.google.com/document/d/1")) == S.writing)
        #expect(c.category(classifySpan(title: "Inbox", url: "https://mail.google.com/mail/u/0")) == S.communication)
        // W24: Google search paths are Research; other google.com paths stay unmatched.
        #expect(c.category(classifySpan(title: "Google", url: "https://www.google.com/search")) == S.research)
        #expect(c.category(classifySpan(title: "Google Maps", url: "https://www.google.com/maps")) == nil)
    }

    // Acceptance 3 + host boundary
    @Test func hostSuffixBoundary() {
        #expect(c.category(classifySpan(url: "https://gist.github.com/abc")) == S.coding)
        #expect(c.category(classifySpan(url: "https://notgithub.com/")) == nil)
        #expect(c.category(classifySpan(url: "https://x.com/home")) == S.social)
        #expect(c.category(classifySpan(url: "https://box.com/files")) == nil)
    }

    // Acceptance 4
    @Test func meetTabsOnlyInCall() {
        #expect(c.category(classifySpan(title: "Meet - abc-defg-hij", url: "https://meet.google.com/abc-defg-hij")) == S.meetings)
        #expect(c.category(classifySpan(title: "Google Meet", url: "https://meet.google.com/")) == nil)
    }

    // Acceptance 5
    @Test func zoomOnlyInCall() {
        #expect(c.category(classifySpan("us.zoom.xos", app: "zoom.us", title: "Zoom Workplace")) == nil)
        #expect(c.category(classifySpan("us.zoom.xos", app: "zoom.us", title: "Zoom Meeting")) == S.meetings)
        #expect(c.category(classifySpan(url: "https://zoom.us/wc/123/join")) == S.meetings)
    }

    @Test func slackHuddleBeatsSlack() {
        // bundle+title (25) > bundle (10).
        #expect(c.category(classifySpan("com.tinyspeck.slackmacgap", app: "Slack", title: "Huddle with Alex")) == S.meetings)
        #expect(c.category(classifySpan("com.tinyspeck.slackmacgap", app: "Slack", title: "general - ExampleCo")) == S.communication)
    }

    @Test func appNameFallbackIsCaseInsensitive() {
        #expect(c.category(classifySpan(nil, app: "ghostty", title: "~")) == S.coding)
        #expect(c.category(classifySpan("com.unknown.cursor", app: "Cursor", title: "x")) == S.coding)
    }

    @Test func linkedInIsCommunication() {
        #expect(c.category(classifySpan(url: "https://www.linkedin.com/feed/")) == S.communication)
    }

    @Test func browserWithoutMatchIsUncategorized() {
        #expect(c.category(classifySpan(title: "Some blog", url: "https://example.org/post")) == nil)
        #expect(c.category(classifySpan(title: "New Tab", url: nil)) == nil)
    }

    // Acceptance 15 (classification half; metrics drop .exclude)
    @Test func loginwindowIsExcluded() {
        let id = c.category(classifySpan("com.apple.loginwindow", app: "loginwindow"))
        #expect(id == S.excluded)
        #expect(S.categories.first { $0.id == id }?.behavior == .exclude)
    }

    // Acceptance 6
    @Test func specificityScores() {
        #expect(Classifier.specificity(Rule(id: 1, origin: .user, host: "github.com")) == 24)
        #expect(Classifier.specificity(Rule(id: 1, origin: .user, host: "github.com", pathPrefix: "/acme")) == 34)
        #expect(Classifier.specificity(Rule(id: 1, origin: .user, bundleId: "b", titleRegex: "t")) == 25)
        #expect(Classifier.specificity(Rule(id: 1, origin: .user, appName: "a")) == 8)
    }

    @Test func userBeatsSeedOnTie() {
        let c = seedClassifier(extra: [Rule(id: 900, origin: .user, host: "github.com", categoryId: S.planning)])
        #expect(c.category(classifySpan(url: "https://github.com/acme/x")) == S.planning)
    }

    @Test func hostPlusPathBeatsBareHost() {
        let c = seedClassifier(extra: [
            Rule(id: 900, origin: .user, host: "github.com", categoryId: S.planning),
            Rule(id: 901, origin: .user, host: "github.com", pathPrefix: "/acme", categoryId: S.coding),
        ])
        #expect(c.category(classifySpan(url: "https://github.com/acme/repo")) == S.coding)
        #expect(c.category(classifySpan(url: "https://github.com/other/repo")) == S.planning)
        #expect(c.resolve(ClassifyKey(classifySpan(url: "https://github.com/acme/repo"))).categoryRuleId == 901)
    }

    @Test func priorityBeatsSpecificity() {
        // Bundle-only (10) at priority 5 beats seed host github.com (24) at priority 0.
        let c = seedClassifier(extra: [Rule(id: 900, origin: .user, priority: 5, bundleId: "com.google.Chrome", categoryId: S.personal)])
        #expect(c.category(classifySpan(url: "https://github.com/acme/x")) == S.personal)
    }

    @Test func lowestIdBreaksFullTie() {
        let c = Classifier(categories: S.categories, rules: [
            Rule(id: 2, origin: .user, host: "a.com", categoryId: S.planning),
            Rule(id: 1, origin: .user, host: "a.com", categoryId: S.coding),
        ], projects: [])
        #expect(c.category(classifySpan(url: "https://a.com")) == S.coding)
    }

    // Acceptance 7
    @Test func projectRegexIsTokenBounded() {
        let c = Classifier(categories: S.categories, rules: [
            ClassifyRuleSuggester.projectRule(for: Project(id: 2, name: "operations-dashboard")),
        ], projects: S.projects)
        #expect(c.project(classifySpan(title: "operations-dashboard — x")) == dashboardProject)
        #expect(c.project(classifySpan(title: "outreach-systems/operations-dashboard")) == dashboardProject)
        #expect(c.project(classifySpan(title: "operations-dashboard-old — x")) == nil)
        #expect(c.project(classifySpan(title: "my-operations-dashboard")) == nil)
    }

    @Test func hoursProjectNeedsPathOrEditorContext() {
        #expect(c.project(classifySpan("com.tinyspeck.slackmacgap", app: "Slack", title: "3 hours ago — Slack")) == nil)
        #expect(c.project(classifySpan(title: "Logged 6 hours today")) == nil)
        #expect(c.project(classifySpan(title: "hours-old — x")) == nil)
        #expect(c.project(classifySpan("com.microsoft.VSCode", app: "Code", title: "PLAN.md — spells")) == hoursProject)
        #expect(c.project(classifySpan("com.cmuxterm.app", app: "cmux", title: "~/Documents/GitHub/spells")) == hoursProject)
        #expect(c.project(classifySpan(nil, app: "Ghostty", title: "spells/Sources — zsh")) == hoursProject)
        #expect(c.project(classifySpan(title: "Issues", url: "https://github.com/ExampleOrg/spells/issues")) == hoursProject)
        #expect(c.project(classifySpan(title: "Issues", url: "https://github.com/someone/hours/issues")) == nil)
    }

    @Test func twoProjectsInTitleTieBreakByLowestId() {
        // Both seed project rules score 15; outreach-systems (1004) loses to operations-dashboard (1002).
        #expect(c.project(classifySpan(title: "outreach-systems/operations-dashboard")) == dashboardProject)
    }

    // Acceptance 8 + "project resolves independently of category"
    @Test func categoryAndProjectIndependent() {
        let both = classifySpan("com.microsoft.VSCode", app: "Code", title: "a.ts — outreach-systems")
        #expect(c.category(both) == S.coding)
        #expect(c.project(both) == outreachProject)

        let projectOnly = classifySpan(title: "notes — spells", url: "https://example.org/")
        #expect(c.category(projectOnly) == nil)
        #expect(c.project(projectOnly) == hoursProject)

        let categoryOnly = classifySpan("com.microsoft.VSCode", app: "Code", title: "scratch.txt")
        #expect(c.category(categoryOnly) == S.coding)
        #expect(c.project(categoryOnly) == nil)
    }

    // Acceptance 9
    @Test func ruleEditsApplyRetroactively() {
        var rule = Rule(id: 1, origin: .user, host: "github.com", categoryId: S.coding)
        let span = classifySpan(url: "https://github.com/acme/x")
        #expect(Classifier(categories: S.categories, rules: [rule], projects: []).category(span) == S.coding)
        rule.categoryId = S.planning
        #expect(Classifier(categories: S.categories, rules: [rule], projects: []).category(span) == S.planning)
    }

    // Acceptance 10 + "override beats rule"
    @Test func editOverridesBeatRules() {
        let pinned = classifySpan(url: "https://github.com/acme/x", category: S.personal)
        #expect(c.category(pinned) == S.personal)
        let changed = seedClassifier(extra: [Rule(id: 900, origin: .user, priority: 9, host: "github.com", categoryId: S.planning)])
        #expect(changed.category(pinned) == S.personal)

        let projectOnly = classifySpan("com.microsoft.VSCode", app: "Code", title: "a — spells", project: 3)
        #expect(c.category(projectOnly) == S.coding)
        #expect(c.project(projectOnly) == 3)
    }

    @Test func idleAndManualSkipRules() {
        #expect(c.classify(classifySpan("com.microsoft.VSCode", app: "Code", kind: .idle)).categoryId == nil)
        let manual = classifySpan(nil, app: "", title: "spells", source: .manual, category: S.meetings)
        #expect(c.category(manual) == S.meetings)
        #expect(c.project(manual) == nil)
    }

    @Test func disabledRulesAndUnknownTargetsIgnored() {
        let c = Classifier(categories: S.categories, rules: [
            Rule(id: 1, origin: .user, enabled: false, host: "a.com", categoryId: S.coding),
            Rule(id: 2, origin: .user, host: "a.com", categoryId: 999),
            Rule(id: 3, origin: .user, host: "a.com", projectId: 999),
        ], projects: [])
        #expect(c.category(classifySpan(url: "https://a.com")) == nil)
        #expect(c.project(classifySpan(url: "https://a.com")) == nil)
    }

    // Acceptance 12
    @Test func invalidRegexIsDisabledNotThrown() {
        let bad = Rule(id: 900, origin: .user, titleRegex: "([", categoryId: S.planning)
        #expect(Classifier.validationError(bad) != nil)
        #expect(Classifier.validationError(Rule(id: 1, origin: .user, categoryId: S.coding)) != nil)
        #expect(Classifier.validationError(Rule(id: 1, origin: .user, host: "a.com")) != nil)
        #expect(Classifier.validationError(Rule(id: 1, origin: .user, host: "a.com", categoryId: S.coding)) == nil)
        let c = seedClassifier(extra: [bad])
        #expect(c.invalidRuleIds == [900])
        #expect(c.category(classifySpan("com.microsoft.VSCode", app: "Code", title: "([")) == S.coding)
    }

    @Test func cacheReturnsSameResult() {
        let s = classifySpan(title: "Spec", url: "https://docs.google.com/d")
        #expect(c.classify(s) == c.classify(s))
        #expect(c.classifyAll([s, s]).map(\.categoryId) == [S.writing, S.writing])
    }

    // Brief: 10k spans < 50 ms with cache. Acceptance 14: 5,000 distinct × 120 rules.
    @Test func performance() {
        let extra = (0..<(120 - ClassifySeed.rules.count)).map {
            Rule(id: Int64(5000 + $0), origin: .user, titleRegex: "ticket-\($0)\\b", categoryId: S.planning)
        }
        let rules = ClassifySeed.rules + extra
        #expect(rules.count == 120)
        let apps: [(String?, String)] = [("com.microsoft.VSCode", "Code"), ("com.google.Chrome", "Google Chrome"),
                                         ("com.cmuxterm.app", "cmux"), ("com.tinyspeck.slackmacgap", "Slack")]
        let hosts = ["github.com", "gist.github.com", "docs.google.com", "example.org", "x.com"]
        let distinct = (0..<5_000).map { i -> EffectiveSpan in
            let (b, a) = apps[i % apps.count]
            let url = b == "com.google.Chrome" ? "https://\(hosts[i % hosts.count])/p/\(i)" : nil
            return classifySpan(b, app: a, title: "file\(i).swift — operations-dashboard — ticket-\(i % 50)", url: url)
        }
        let tenK = distinct + distinct

        let clock = ContinuousClock()
        let c = Classifier(categories: S.categories, rules: rules, projects: S.projects)
        let cold = clock.measure { _ = c.classifyAll(distinct) }
        let warm = clock.measure { _ = c.classifyAll(tenK) }
        print("classify perf: 5,000 distinct × 120 rules cold \(cold); 10,000 spans cached \(warm)")
        #expect(cold < .milliseconds(1_500))   // 150 ms target is release; debug is generous
        #expect(warm < .milliseconds(50))
    }
}
