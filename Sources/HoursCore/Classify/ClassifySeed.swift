import Foundation

/// Bundled seed config. Ids are stable: categories 1…12, projects 1…6, category rules positional
/// from 1, project rules positional from 1001 — both lists are APPEND-ONLY (never reorder or delete).
/// Bundle ids verified with `mdls`; apps not installed there (Cursor, Zed, Ghostty, ClickUp,
/// Microsoft Teams) match by app name instead of a guessed bundle id.
public enum ClassifySeed {
    // Category ids.
    public static let coding: Int64 = 1, research: Int64 = 2, writing: Int64 = 3, planning: Int64 = 4
    public static let communication: Int64 = 5, meetings: Int64 = 6, system: Int64 = 7, personal: Int64 = 8
    public static let social: Int64 = 9, entertainment: Int64 = 10, uncategorized: Int64 = 11, excluded: Int64 = 12
    /// W24: browser time no rule matched and Jev didn't classify confidently. Look it up by key
    /// ("browsing"), not id — on an existing DB the seed may have had to give it a fresh id.
    public static let browsing: Int64 = 13

    /// `classify` returns `categoryId == nil` for Uncategorized; this row exists so views can name/style it.
    public static let categories: [Category] = [
        Category(id: coding, key: "coding", name: "Coding", level: .productive, isWork: true, behavior: .normal, colorSlot: 0, sort: 1),
        Category(id: research, key: "research", name: "Research & Docs", level: .productive, isWork: true, behavior: .normal, colorSlot: 1, sort: 2),
        Category(id: writing, key: "writing", name: "Writing & Notes", level: .productive, isWork: true, behavior: .normal, colorSlot: 2, sort: 3),
        Category(id: planning, key: "planning", name: "Planning", level: .productive, isWork: true, behavior: .normal, colorSlot: 3, sort: 4),
        Category(id: communication, key: "communication", name: "Communication", level: .neutral, isWork: true, behavior: .normal, colorSlot: 4, sort: 5),
        Category(id: meetings, key: "meetings", name: "Meetings", level: .neutral, isWork: true, behavior: .meeting, colorSlot: 5, sort: 6),
        Category(id: system, key: "system", name: "System & Admin", level: .neutral, isWork: true, behavior: .normal, colorSlot: 6, sort: 7),
        Category(id: personal, key: "personal", name: "Personal", level: .neutral, isWork: false, behavior: .normal, colorSlot: 7, sort: 8),
        Category(id: social, key: "social", name: "Social Media", level: .distracting, isWork: false, behavior: .normal, colorSlot: 8, sort: 9),
        Category(id: entertainment, key: "entertainment", name: "Entertainment", level: .distracting, isWork: false, behavior: .normal, colorSlot: 9, sort: 10),
        Category(id: uncategorized, key: "uncategorized", name: "Uncategorized", level: .neutral, isWork: false, behavior: .normal, colorSlot: nil, sort: 11),
        Category(id: excluded, key: "excluded", name: "Excluded", level: .neutral, isWork: false, behavior: .exclude, colorSlot: nil, sort: 12),
        Category(id: browsing, key: "browsing", name: "Browsing", level: .neutral, isWork: false, behavior: .normal, colorSlot: nil, sort: 11),
    ]

    public static let projects: [Project] = [
        "client-monitoring", "operations-dashboard", "data-scrapers",
        "outreach-systems", "example-ui-prototype", "spells",
    ].enumerated().map { Project(id: Int64($0.offset + 1), name: $0.element) }

    public static let rules: [Rule] = {
        let specs: [Spec] = [
            // Coding
            .init("coding.vscode", coding, bundle: "com.microsoft.VSCode"),
            .init("coding.xcode", coding, bundle: "com.apple.dt.Xcode"),
            .init("coding.cursor", coding, app: "Cursor"),
            .init("coding.zed", coding, app: "Zed"),
            .init("coding.terminal", coding, bundle: "com.apple.Terminal"),
            .init("coding.iterm", coding, bundle: "com.googlecode.iterm2"),
            .init("coding.ghostty", coding, app: "Ghostty"),
            .init("coding.cmux", coding, bundle: "com.cmuxterm.app"),
            .init("coding.github-desktop", coding, bundle: "com.github.GitHubClient"),
            .init("coding.github", coding, host: "github.com"),
            .init("coding.githubusercontent", coding, host: "githubusercontent.com"),
            .init("coding.vercel", coding, host: "vercel.com"),
            .init("coding.neon-console", coding, host: "console.neon.tech"),
            .init("coding.localhost", coding, host: "localhost"),
            .init("coding.loopback", coding, host: "127.0.0.1"),
            // Research & Docs
            .init("research.claude-app", research, bundle: "com.anthropic.claudefordesktop"),
            .init("research.claude-web", research, host: "claude.ai"),
            .init("research.apple-dev", research, host: "developer.apple.com"),
            .init("research.mdn", research, host: "developer.mozilla.org"),
            .init("research.stackoverflow", research, host: "stackoverflow.com"),
            .init("research.npm", research, host: "npmjs.com"),
            .init("research.swift", research, host: "swift.org"),
            // Writing & Notes
            .init("writing.obsidian", writing, bundle: "md.obsidian"),
            .init("writing.gdocs", writing, host: "docs.google.com"),
            // Planning
            .init("planning.clickup-web", planning, host: "app.clickup.com"),
            .init("planning.clickup-app", planning, app: "ClickUp"),
            // Communication (LinkedIn = Communication, PLAN Q15)
            .init("communication.slack", communication, bundle: "com.tinyspeck.slackmacgap"),
            .init("communication.mail", communication, bundle: "com.apple.mail"),
            .init("communication.messages", communication, bundle: "com.apple.MobileSMS"),
            .init("communication.slack-web", communication, host: "app.slack.com"),
            .init("communication.gmail", communication, host: "mail.google.com"),
            .init("communication.linkedin", communication, host: "linkedin.com"),
            // Meetings — window-based only; Zoom/Meet home windows deliberately not meetings.
            .init("meetings.zoom-call", meetings, bundle: "us.zoom.xos", title: "^Zoom Meeting"),
            .init("meetings.zoom-web", meetings, host: "zoom.us", path: "/wc/"),
            .init("meetings.meet", meetings, host: "meet.google.com", title: "^Meet - "),
            // Teams is chat most of the day: only call windows ("Meeting with …", "Call with …") count. Not
            // a bare "| Microsoft Teams$": the chat window ends that way too; not "Calls" (the call-log tab).
            .init("meetings.teams", meetings, app: "Microsoft Teams", title: #"\b(meeting|call|huddle)\b"#),
            .init("meetings.facetime", meetings, bundle: "com.apple.FaceTime"),
            .init("meetings.slack-huddle", meetings, bundle: "com.tinyspeck.slackmacgap", title: "huddle"),
            // System & Admin
            .init("system.finder", system, bundle: "com.apple.finder"),
            .init("system.settings", system, bundle: "com.apple.systempreferences"),
            .init("system.activity-monitor", system, bundle: "com.apple.ActivityMonitor"),
            .init("system.1password", system, bundle: "com.1password.1password"),
            // Spells itself (and each spell's own windows: Scry's live panel, Incant, HoursSpell's island).
            .init("system.spells", system, bundle: "dev.nic.spells"),
            .init("system.spells.scry", system, bundle: "dev.nic.spells.scry"),
            .init("system.spells.incant", system, bundle: "dev.nic.spells.incant"),
            .init("system.spells.hours", system, bundle: "dev.nic.spells.hours"),
            .init("system.calendar", system, bundle: "com.apple.iCal"),
            .init("system.gcal", system, host: "calendar.google.com"),
            // Personal
            .init("personal.spotify", personal, bundle: "com.spotify.client"),
            // Social Media
            .init("social.x", social, host: "x.com"),
            .init("social.twitter", social, host: "twitter.com"),
            .init("social.facebook", social, host: "facebook.com"),
            .init("social.instagram", social, host: "instagram.com"),
            .init("social.reddit", social, host: "reddit.com"),
            .init("social.tiktok", social, host: "tiktok.com"),
            // Entertainment (incl. news)
            .init("entertainment.youtube", entertainment, host: "youtube.com"),
            .init("entertainment.netflix", entertainment, host: "netflix.com"),
            .init("entertainment.twitch", entertainment, host: "twitch.tv"),
            .init("entertainment.hn", entertainment, host: "news.ycombinator.com"),
            .init("entertainment.google-news", entertainment, host: "news.google.com"),
            .init("entertainment.nytimes", entertainment, host: "nytimes.com"),
            .init("entertainment.wapo", entertainment, host: "washingtonpost.com"),
            .init("entertainment.wsj", entertainment, host: "wsj.com"),
            .init("entertainment.cnn", entertainment, host: "cnn.com"),
            .init("entertainment.foxnews", entertainment, host: "foxnews.com"),
            .init("entertainment.bbc", entertainment, host: "bbc.com"),
            .init("entertainment.bbc-uk", entertainment, host: "bbc.co.uk"),
            .init("entertainment.verge", entertainment, host: "theverge.com"),
            // Excluded
            .init("excluded.loginwindow", excluded, bundle: "com.apple.loginwindow"),
            .init("excluded.screensaver", excluded, bundle: "com.apple.ScreenSaver.Engine"),
            // W24 browsing/research upgrade. `docs.*` = host-prefix match (docs.google.com stays Writing:
            // its exact host is more specific).
            .init("research.docs-prefix", research, host: "docs.*"),
            .init("research.developer-prefix", research, host: "developer.*"),
            .init("research.api-prefix", research, host: "api.*"),
            .init("research.readthedocs", research, host: "readthedocs.io"),
            .init("research.wikipedia", research, host: "wikipedia.org"),
            .init("research.arxiv", research, host: "arxiv.org"),
            .init("research.google-search", research, host: "google.com", path: "/search"),
            .init("research.kagi-search", research, host: "kagi.com", path: "/search"),
            .init("research.duckduckgo", research, host: "duckduckgo.com"),
            .init("research.chatgpt", research, host: "chatgpt.com"),
            .init("research.perplexity", research, host: "perplexity.ai"),
            .init("coding.neon", coding, host: "neon.tech"),
            .init("coding.cloudflare-dash", coding, host: "dash.cloudflare.com"),
            // Keyword titles only decide when nothing else matched (priority −1): "guide.md — hours"
            // in VS Code stays Coding.
            .init("research.title-keywords", research, title: #"\b(documentation|api reference|guide|tutorial|how to|docs)\b"#,
                  priority: -1),
        ]
        var out = specs.enumerated().map { i, s in
            Rule(id: Int64(i + 1), origin: .seed, seedKey: s.key, priority: s.priority, bundleId: s.bundle, appName: s.app,
                 host: s.host, pathPrefix: s.path, titleRegex: s.title, categoryId: s.category)
        }
        // Project rules: title contains the repo name as a whole token. ponytail: no GitHub
        // host+path rules for the distinctive names — repo-page titles carry the repo name anyway.
        for (i, p) in projects.enumerated() {
            let regex = p.name == "spells" ? spellsTitleRegex : ClassifyRuleSuggester.projectTitleRegex(p.name)
            out.append(Rule(id: Int64(1001 + i), origin: .seed, seedKey: "project.\(p.name)",
                            titleRegex: regex, projectId: p.id))
        }
        // "spells" is an ordinary word, so its title rule needs path/editor context; repo pages match by URL.
        out.append(Rule(id: 1001 + Int64(projects.count), origin: .seed, seedKey: "project.spells.github",
                        host: "github.com", pathPrefix: "/ExampleOrg/spells",
                        projectId: projects.first { $0.name == "spells" }!.id))
        return out
    }()

    /// Seed upsert, pure: user rules untouched; seed rules matched by `seedKey` take the seed's
    /// predicates/targets/priority but keep their stored `id` and `enabled`; new seed rules get their
    /// seed id if free, else `max(id) + 1`. Seed keys no longer in `seed` are left as-is.
    /// Idempotent. The caller persists the result via the config store.
    public static func merge(seed: [Rule] = rules, into existing: [Rule]) -> [Rule] {
        let seedKeys = Set(seed.compactMap(\.seedKey))
        var bySeedKey: [String: Rule] = [:]
        for r in existing where r.origin == .seed { if let k = r.seedKey { bySeedKey[k] = r } }

        var out = existing.filter { $0.origin == .user || !seedKeys.contains($0.seedKey ?? "") }
        var used = Set(existing.map(\.id))
        for var s in seed {
            if let e = bySeedKey[s.seedKey ?? ""] {
                s.id = e.id
                s.enabled = e.enabled
            } else {
                if used.contains(s.id) { s.id = (used.max() ?? 0) + 1 }
                used.insert(s.id)
            }
            out.append(s)
        }
        return out.sorted { $0.id < $1.id }
    }

    /// `/hours`, `hours/`, `— hours`, `hours —` (editor title separators), never a bare "3 hours ago".
    static let spellsTitleRegex = #"/spells(?![\w-])|(?<![\w-])spells/|— spells(?![\w-])|(?<![\w-])spells —"#

    private struct Spec {
        let key: String, category: Int64
        let bundle: String?, app: String?, host: String?, path: String?, title: String?
        let priority: Int
        init(_ key: String, _ category: Int64, bundle: String? = nil, app: String? = nil,
             host: String? = nil, path: String? = nil, title: String? = nil, priority: Int = 0) {
            self.key = key; self.category = category
            self.bundle = bundle; self.app = app; self.host = host; self.path = path; self.title = title
            self.priority = priority
        }
    }
}
