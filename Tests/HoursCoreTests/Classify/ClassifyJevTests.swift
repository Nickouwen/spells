import Foundation
import Testing
@testable import HoursCore

private let S = ClassifySeed.self
private let chrome = "com.google.Chrome"

/// A cached answer for a web key.
func jevEntry(_ host: String, _ path: String, _ title: String, _ cat: String?, conf: Double = 0.9,
              app: String = "com.google.Chrome", project: String? = nil, projectConf: Double = 0,
              retryAfterMs: Int64? = nil) -> JevEntry {
    JevEntry(key: JevKey(app: app, host: host, pathTpl: path, titleNorm: title), categoryKey: cat, categoryConf: conf,
             projectName: project, projectConf: projectConf, createdMs: 1, inputTokens: 400, retryAfterMs: retryAfterMs)
}

func jevClassifier(_ entries: [JevEntry], settings: JevSettings = JevSettings()) -> Classifier {
    Classifier(categories: S.categories, rules: S.rules, projects: S.projects,
               jev: JevSnapshot(entries: entries, settings: settings, nowMs: 0))
}

@Suite struct ClassifyJevKeyTests {
    @Test func titleNormalisation() {
        let K = ClassifyJevKey.self
        #expect(K.normalizeTitle("(3) Inbox 🚀 — Order #12345 - Google Chrome") == "inbox — order ######")
        #expect(K.normalizeTitle("Pull requests · ExampleOrg/spells — Mozilla Firefox") == "pull requests · exampleorg/spells")
        #expect(K.normalizeTitle("  Hello\t\n  World  ") == "hello world")
        #expect(K.normalizeTitle("👍🏽 Done") == "done")
        #expect(K.normalizeTitle("Chrome tips - Brave") == "chrome tips")
        #expect(K.normalizeTitle("Q3 plan 2026") == "q# plan ####")
        #expect(K.normalizeTitle(String(repeating: "a", count: 300)).count == 120)
    }

    @Test func pathTemplate() {
        let K = ClassifyJevKey.self
        #expect(K.pathTemplate("/ExampleOrg/spells/pull/42") == "/exampleorg/spells/pull")
        #expect(K.pathTemplate("/repos/123/issues/9") == "/repos/*/issues")
        #expect(K.pathTemplate("/d/3F2504E0-4F89-11D3-9A0C-0305E82C3301/edit") == "/d/*/edit")
        #expect(K.pathTemplate("/commit/deadbeef01") == "/commit/*")
        #expect(K.pathTemplate("/a1b2c3/x") == "/a1b2c3/x")                 // hex but < 8
        #expect(K.pathTemplate("/homedetails/123-Main-St-Columbia-SC-29201/12345_zpid") == "/homedetails/*/*")
        #expect(K.pathTemplate("/ExampleOrg/spells/pull-requests") == "/exampleorg/spells/pull-requests")
        #expect(K.pathTemplate("/") == "/")
        #expect(K.pathTemplate("") == "/")
    }

    @Test func keyFields() {
        let web = ClassifyJevKey.make(ClassifyKey(bundleId: chrome, appName: "Google Chrome", title: "Some Post (2) - Google Chrome",
                                                  url: "https://www.Example.org/blog/2024/post?utm=x#top"))
        #expect(web == JevKey(app: chrome, host: "example.org", pathTpl: "/blog/*/post", titleNorm: "some post (#)"))
        #expect(web?.isWeb == true)
        let app = ClassifyJevKey.make(ClassifyKey(bundleId: "com.figma.Desktop", appName: "Figma", title: "Dashboard – Figma", url: nil))
        #expect(app == JevKey(app: "com.figma.Desktop", titleNorm: "dashboard – figma"))
        #expect(app?.isWeb == false)
        // No bundle id → app name.
        #expect(ClassifyJevKey.make(ClassifyKey(bundleId: nil, appName: "Thing", title: "x", url: nil))?.app == "Thing")
        // Private / incognito (title nil) is never a key.
        #expect(ClassifyJevKey.make(ClassifyKey(bundleId: chrome, appName: "Google Chrome", title: nil, url: nil)) == nil)
        // Titles off → host + path only.
        let off = ClassifyJevKey.make(ClassifyKey(bundleId: chrome, appName: "Google Chrome", title: "Secret plan",
                                                  url: "https://example.org/a"), includeTitle: false)
        #expect(off?.titleNorm == "")
        #expect(off?.id.contains("secret") == false)
    }
}

@Suite struct ClassifyJevTierTests {
    let pr = { (t: String) in JevKey(app: chrome, host: "github.com", pathTpl: "/exampleorg/spells/pull", titleNorm: t) }

    @Test func exactMatch() {
        let s = JevSnapshot(entries: [jevEntry("example.org", "/a", "post", "research", conf: 0.4)])
        let hit = s.lookup(JevKey(app: chrome, host: "example.org", pathTpl: "/a", titleNorm: "post"))
        #expect(hit?.tier == .exact && hit?.categoryKey == "research" && hit?.confidence == 0.4)
        // Another title on the same path: 1 entry < 3 → miss.
        #expect(s.lookup(JevKey(app: chrome, host: "example.org", pathTpl: "/a", titleNorm: "other")) == nil)
        // Same page in another browser: different key.
        #expect(s.lookup(JevKey(app: "org.mozilla.firefox", host: "example.org", pathTpl: "/a", titleNorm: "post")) == nil)
    }

    @Test func pathConsensus() {
        let three = (1...3).map { jevEntry("github.com", "/exampleorg/spells/pull", "pr \($0)", "coding", conf: 0.8) }
        let hit = JevSnapshot(entries: three).lookup(pr("a new pr"))
        #expect(hit?.tier == .path && hit?.categoryKey == "coding")
        #expect(abs((hit?.confidence ?? 0) - 0.8) < 1e-9)
        #expect(hit?.projectName == nil)   // consensus never attributes a project
        // Counter-example: github.com issues on another repo — different path template, and only
        // 3 host entries (< 5), so no fuzzy answer.
        #expect(JevSnapshot(entries: three).lookup(JevKey(app: chrome, host: "github.com", pathTpl: "/acme/api/issues",
                                                          titleNorm: "bug")) == nil)
        // Needs ≥ 3 entries.
        #expect(JevSnapshot(entries: Array(three.prefix(2))).lookup(pr("x")) == nil)
        // Needs ≥ 80 % agreement: 3 of 4 = 75 %.
        let split = three + [jevEntry("github.com", "/exampleorg/spells/pull", "pr 4", "planning")]
        #expect(JevSnapshot(entries: split).lookup(pr("x")) == nil)
        // 4 of 5 = 80 % passes (and the host tier would need 90 %).
        let fourOfFive = split + [jevEntry("github.com", "/exampleorg/spells/pull", "pr 5", "coding", conf: 0.8)]
        #expect(JevSnapshot(entries: fourOfFive).lookup(pr("x"))?.tier == .path)
        // Needs mean confidence ≥ 0.7 among the agreeing entries.
        let unsure = (1...3).map { jevEntry("github.com", "/exampleorg/spells/pull", "pr \($0)", "coding", conf: 0.65) }
        #expect(JevSnapshot(entries: unsure).lookup(pr("x")) == nil)
    }

    @Test func hostConsensus() {
        let paths = ["/a", "/b", "/c", "/d", "/e"]
        let five = paths.map { jevEntry("docs-site.dev", $0, "t", "research", conf: 0.6) }
        let hit = JevSnapshot(entries: five).lookup(JevKey(app: chrome, host: "docs-site.dev", pathTpl: "/zzz", titleNorm: "new"))
        #expect(hit?.tier == .host && hit?.categoryKey == "research")
        // 4 entries < 5.
        #expect(JevSnapshot(entries: Array(five.prefix(4))).lookup(JevKey(app: chrome, host: "docs-site.dev", pathTpl: "/z", titleNorm: "n")) == nil)
        // 9 of 10 = 90 % passes; 8 of 10 fails.
        let ten = (0..<10).map { jevEntry("mixed.dev", "/p\($0)", "t", $0 < 9 ? "research" : "personal") }
        #expect(JevSnapshot(entries: ten).lookup(JevKey(app: chrome, host: "mixed.dev", pathTpl: "/new", titleNorm: "n"))?.categoryKey == "research")
        let eight = (0..<10).map { jevEntry("mixed.dev", "/p\($0)", "t", $0 < 8 ? "research" : "personal") }
        #expect(JevSnapshot(entries: eight).lookup(JevKey(app: chrome, host: "mixed.dev", pathTpl: "/new", titleNorm: "n")) == nil)
    }

    @Test func appLevelConsensusForNonBrowserApps() {
        let figma = (1...5).map { JevEntry(key: JevKey(app: "com.figma.Desktop", titleNorm: "file \($0)"), categoryKey: "coding",
                                           categoryConf: 0.9, createdMs: 1) }
        let s = JevSnapshot(entries: figma)
        #expect(s.lookup(JevKey(app: "com.figma.Desktop", titleNorm: "file 1"))?.tier == .exact)
        #expect(s.lookup(JevKey(app: "com.figma.Desktop", titleNorm: "brand new file"))?.tier == .host)
        #expect(JevSnapshot(entries: Array(figma.prefix(4))).lookup(JevKey(app: "com.figma.Desktop", titleNorm: "new")) == nil)
    }

    @Test func failuresNeverAnswerAndBlockUntilRetry() {
        let key = JevKey(app: chrome, host: "flaky.dev", pathTpl: "/", titleNorm: "x")
        let failed = JevEntry.failure(key, nowMs: 0, retryAfterMs: 1_000)
        #expect(JevSnapshot(entries: [failed], nowMs: 500).lookup(key) == nil)
        #expect(JevSnapshot(entries: [failed], nowMs: 500).covers(key))       // not re-asked yet
        #expect(!JevSnapshot(entries: [failed], nowMs: 1_000).covers(key))    // due again
    }
}

@Suite struct ClassifyJevPrecedenceTests {
    let blog = { (title: String) in classifySpan(title: title, url: "https://example.org/post") }

    @Test func precedenceChain() {
        let entries = [jevEntry("example.org", "/post", "a post", "research", conf: 0.92),
                       jevEntry("github.com", "/acme", "repo", "entertainment", conf: 1)]
        let c = jevClassifier(entries)
        // Jev ≥ threshold.
        #expect(c.category(blog("A post")) == S.research)
        #expect(c.source(blog("A post")) == .jev(confidence: 0.92))
        #expect(c.source(blog("A post"))?.label == "Jev 92 %")
        // Rule beats Jev.
        let gh = classifySpan(title: "repo", url: "https://github.com/acme")
        #expect(c.category(gh) == S.coding && c.source(gh) == .rule)
        // Edit beats everything.
        let edited = classifySpan(title: "A post", url: "https://example.org/post", category: S.personal)
        #expect(c.category(edited) == S.personal && c.source(edited) == .edited)
        // No Jev answer, browser → Browsing fallback.
        #expect(c.category(blog("Unseen")) == S.browsing && c.source(blog("Unseen")) == .fallback)
        // Private window (no title/URL) in a browser → fallback too.
        #expect(c.category(classifySpan(title: nil, url: nil)) == S.browsing)
        // Non-browser, no rule, no answer → Uncategorized.
        let other = classifySpan("com.example.app", app: "Example", title: "Window")
        #expect(c.category(other) == nil && c.source(other) == nil)
        // No snapshot = rules only (fixtures): no fallback.
        #expect(seedClassifier().category(blog("Unseen")) == nil)
        // Rule-only resolve (review queue) ignores Jev and the fallback.
        #expect(c.resolve(ClassifyKey(blog("A post"))).categoryId == nil)
    }

    @Test func categoryThreshold() {
        let at = jevClassifier([jevEntry("example.org", "/post", "x", "research", conf: 0.6)])
        #expect(at.category(blog("x")) == S.research)
        let below = jevClassifier([jevEntry("example.org", "/post", "x", "research", conf: 0.59)])
        #expect(below.category(blog("x")) == S.browsing)
        #expect(below.jevHit(ClassifyKey(blog("x")))?.categoryKey == "research")   // still a suggestion
        let strict = jevClassifier([jevEntry("example.org", "/post", "x", "research", conf: 0.7)],
                                   settings: JevSettings(minConfidence: 0.8))
        #expect(strict.category(blog("x")) == S.browsing)
        // Non-browser below threshold → Uncategorized, not Browsing.
        let app = JevEntry(key: JevKey(app: "com.example.app", titleNorm: "window"), categoryKey: "writing",
                           categoryConf: 0.5, createdMs: 1)
        #expect(jevClassifier([app]).category(classifySpan("com.example.app", app: "Example", title: "Window")) == nil)
        // `other` never maps to a category.
        #expect(jevClassifier([jevEntry("example.org", "/post", "x", "other", conf: 1)]).category(blog("x")) == S.browsing)
    }

    @Test func projectPolicy() {
        func c(_ cat: String, _ pconf: Double) -> Classifier {
            jevClassifier([jevEntry("example.org", "/post", "x", cat, conf: 0.9, project: "outreach-systems", projectConf: pconf)])
        }
        let outreach: Int64 = 4, hours: Int64 = 6
        #expect(c("coding", 0.75).project(blog("x")) == outreach)
        #expect(c("coding", 0.74).project(blog("x")) == nil)
        // Not on a non-work category.
        #expect(c("entertainment", 0.99).project(blog("x")) == nil)
        // A rule's project wins (title "— spells" → hours).
        let titled = jevClassifier([jevEntry("example.org", "/post", "notes — spells", "coding", project: "outreach-systems",
                                             projectConf: 0.99)])
        #expect(titled.project(blog("notes — spells")) == hours)
        // Category edited to a work category: the Jev project still applies (category and project are independent).
        let edited = classifySpan(title: "x", url: "https://example.org/post", category: S.coding)
        #expect(c("personal", 0.9).project(edited) == outreach)
        // Disabled Jev (empty snapshot) applies nothing but keeps the fallback.
        let off = Classifier(categories: S.categories, rules: S.rules, projects: S.projects,
                             jev: JevSnapshot(entries: [], settings: JevSettings(enabled: false)))
        #expect(off.category(blog("x")) == S.browsing && off.project(blog("x")) == nil)
    }
}

@Suite struct ClassifyBrowsingRulesTests {
    let c = seedClassifier()
    func cat(_ url: String, title: String = "Page") -> Int64? { c.category(classifySpan(title: title, url: url)) }

    @Test func researchHosts() {
        #expect(cat("https://docs.python.org/3/library/asyncio.html") == S.research)
        #expect(cat("https://developer.android.com/guide") == S.research)
        #expect(cat("https://api.stripe.com/v1") == S.research)
        #expect(cat("https://swiftpackage.readthedocs.io/en/latest/") == S.research)
        #expect(cat("https://en.wikipedia.org/wiki/Foreclosure") == S.research)
        #expect(cat("https://arxiv.org/abs/2401.00001") == S.research)
        #expect(cat("https://www.google.com/search") == S.research)
        #expect(cat("https://kagi.com/search") == S.research)
        #expect(cat("https://duckduckgo.com/") == S.research)
        #expect(cat("https://chatgpt.com/c/abc") == S.research)
        #expect(cat("https://www.perplexity.ai/search/x") == S.research)
    }

    @Test func prefixMatchIsLabelBounded() {
        #expect(cat("https://mydocs.example.com/") == nil)
        #expect(cat("https://docs/") == nil)                         // the prefix needs a following label
        #expect(cat("https://kagi.com/settings") == nil)              // search path only
        // The exact host is more specific than the prefix: Google Docs stays Writing.
        #expect(cat("https://docs.google.com/document/d/1") == S.writing)
        #expect(ClassifyURL.hostMatches("docs.*", "docs.python.org"))
        #expect(!ClassifyURL.hostMatches("docs.*", "mydocs.python.org"))
    }

    @Test func planningAndCodingHosts() {
        #expect(cat("https://app.clickup.com/9011/v/l/6-901") == S.planning)
        #expect(cat("https://neon.tech/docs/introduction") == S.coding)
        #expect(cat("https://console.neon.tech/app/projects") == S.coding)
        #expect(cat("https://vercel.com/dashboard") == S.coding)
        #expect(cat("https://dash.cloudflare.com/abc/workers") == S.coding)
    }

    @Test func titleKeywordsOnlyDecideWhenNothingElseMatches() {
        #expect(cat("https://example.org/x", title: "SwiftUI Tutorial: Lists") == S.research)
        #expect(cat("https://example.org/x", title: "How to cook rice") == S.research)
        #expect(cat("https://example.org/x", title: "Stripe API Reference") == S.research)
        #expect(cat("https://example.org/x", title: "Guidelines") == nil)        // word-bounded
        #expect(c.category(classifySpan("com.apple.Preview", app: "Preview", title: "Docs export.pdf")) == S.research)
        // Any p0 rule wins: VS Code editing a guide stays Coding, YouTube tutorials stay Entertainment.
        #expect(c.category(classifySpan("com.microsoft.VSCode", app: "Code", title: "guide.md — spells")) == S.coding)
        #expect(cat("https://www.youtube.com/watch", title: "Swift tutorial") == S.entertainment)
    }

    @Test func newRulesApplyRetroactively() {
        // A Classifier built from yesterday's seed (without the W24 rules) vs today's: same span, new answer.
        let old = Classifier(categories: S.categories, rules: S.rules.filter { !($0.seedKey ?? "").hasPrefix("research.wikipedia") },
                             projects: S.projects)
        let span = classifySpan(title: "Foreclosure - Wikipedia", url: "https://en.wikipedia.org/wiki/Foreclosure")
        #expect(old.category(span) == nil)
        #expect(c.category(span) == S.research)
    }

    @Test func browsingCategoryShape() {
        let b = S.categories.first { $0.key == "browsing" }!
        #expect(b.id == S.browsing && b.level == .neutral && !b.isWork && b.behavior == .normal && b.colorSlot == nil)
    }
}

@Suite struct ClassifyJevPromptTests {
    @Test func bodyCarriesStateAndChoices() throws {
        let key = JevKey(app: chrome, host: "example.org", pathTpl: "/a/*", titleNorm: "a post")
        let sample = ClassifyKey(bundleId: chrome, appName: "Google Chrome", title: "A post", url: "https://example.org/a/1?token=secret")
        let json = try JSONSerialization.jsonObject(with: ClassifyJevPrompt.body(key: key, sample: sample,
                                                                                categories: S.categories, projects: S.projects)) as! [String: Any]
        #expect(json["model"] as? String == "jev-latest")
        #expect(json["state"] as? [String: String] == ["app": "Google Chrome", "host": "example.org", "path": "/a/*", "title": "A post"])
        let q = json["questions"] as! [String: [String: Any]]
        let cats = q["category"]!["criteria"] as! [String: String]
        #expect(q["category"]!["type"] as? String == "choice")
        #expect(Set(cats.keys) == ["coding", "research", "writing", "planning", "communication", "meetings", "system",
                                   "personal", "social", "entertainment", "browsing", "other"])
        #expect(cats["research"]!.contains("Not this:") && cats["research"]!.contains("Examples:"))
        #expect((q["category"]!["instructions"] as! String).contains("monitoring, dashboards, data pipelines"))
        let projs = q["project"]!["criteria"] as! [String: String]
        #expect(Set(projs.keys) == Set(S.projects.map(\.name) + ["none"]))
        #expect(projs["spells"]!.contains("time tracking"))
    }

    @Test func titlesOffAndNonWebState() throws {
        let off = JevKey(app: chrome, host: "example.org", pathTpl: "/a", titleNorm: "")
        let sample = ClassifyKey(bundleId: chrome, appName: "Google Chrome", title: "Secret", url: "https://example.org/a")
        let body = String(decoding: ClassifyJevPrompt.body(key: off, sample: sample, categories: S.categories, projects: S.projects), as: UTF8.self)
        #expect(!body.contains("Secret"))
        let app = JevKey(app: "com.figma.Desktop", titleNorm: "dashboard")
        let s = try JSONSerialization.jsonObject(with: ClassifyJevPrompt.body(
            key: app, sample: ClassifyKey(bundleId: "com.figma.Desktop", appName: "Figma", title: "Dashboard", url: nil),
            categories: S.categories, projects: S.projects)) as! [String: Any]
        #expect(s["state"] as? [String: String] == ["app": "Figma", "title": "Dashboard"])
    }
}
