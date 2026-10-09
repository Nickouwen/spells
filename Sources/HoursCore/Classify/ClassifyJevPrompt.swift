import Foundation

/// Request body for one Jev classification: state `{app, host, path, title}` + two Choice questions.
/// Never carries a query string (the path is the template), and no title when titles are off.
public enum ClassifyJevPrompt {
    public static let model = "jev-latest"
    static let persona = "The user is a senior software engineer working across monitoring, dashboards, data pipelines, communications tools and prototypes; personal activity also occurs."

    public static func body(key: JevKey, sample: ClassifyKey, categories: [Category], projects: [Project]) -> Data {
        var state: [String: String] = ["app": sample.appName.isEmpty ? key.app : sample.appName]
        if key.isWeb {
            state["host"] = key.host
            state["path"] = key.pathTpl
        }
        // The title goes out exactly when the key carries one (titles off → titleNorm "").
        if !key.titleNorm.isEmpty, let t = sample.title { state["title"] = String(t.prefix(200)) }
        let json: [String: Any] = [
            "model": model,
            "state": state,
            "questions": [
                "category": [
                    "type": "choice",
                    "instructions": "Which category best describes what the user is doing in this window (`app`, `host`, `path`, `title`)? \(persona)",
                    "criteria": categoryCriteria(categories),
                ],
                "project": [
                    "type": "choice",
                    "instructions": "Which of the user's software projects is this window clearly about? Answer `none` unless the window evidently concerns one project.",
                    "criteria": projectCriteria(projects),
                ],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Options = live category keys except Uncategorized and exclude-behaviour ones, plus `other`.
    static func categoryCriteria(_ categories: [Category]) -> [String: String] {
        var out: [String: String] = ["other": "None of the categories fits."]
        for c in categories where !c.archived && c.key != "uncategorized" && c.behavior != .exclude {
            guard let d = descriptions[c.key] else { out[c.key] = c.name; continue }
            out[c.key] = "\(c.name): \(d.what) Not this: \(d.notThis) Examples: \(d.examples.joined(separator: "; "))."
        }
        return out
    }

    /// Options = live project names plus `none`, each with its repo purpose where known.
    static func projectCriteria(_ projects: [Project]) -> [String: String] {
        var out: [String: String] = ["none": "Not clearly about any one of these projects."]
        for p in projects where !p.archived {
            out[p.name] = projectPurpose[p.name] ?? p.client.map { "Work for client \($0)." } ?? p.name
        }
        return out
    }

    private struct Text { let what: String, notThis: String, examples: [String] }

    private static let descriptions: [String: Text] = [
        "coding": Text(what: "Writing, reviewing, running or deploying software: editors, terminals, code hosting, CI, deploy and database consoles.",
                       notThis: "reading documentation is research; tickets and boards are planning.",
                       examples: ["a GitHub pull request diff", "a Vercel deployment log"]),
        "research": Text(what: "Reading to learn or look something up: documentation, API references, tutorials, search results, Q&A sites, AI assistants, papers, and work-related reference sources.",
                         notThis: "writing your own docs is writing; general news is entertainment.",
                         examples: ["the Python asyncio docs", "a product analytics guide"]),
        "writing": Text(what: "Producing prose: documents, notes, specs, long emails, blog posts.",
                        notThis: "reading someone else's docs is research; chat is communication.",
                        examples: ["a Google Doc spec", "an Obsidian daily note"]),
        "planning": Text(what: "Organising work: task trackers, roadmaps, sprint boards, project plans.",
                         notThis: "live meetings are meetings; doing the task itself is coding or writing.",
                         examples: ["a ClickUp sprint board", "a Linear issue list"]),
        "communication": Text(what: "Asynchronous messages with colleagues or clients: chat, email, professional messaging.",
                              notThis: "live calls are meetings; social feeds are social.",
                              examples: ["a Slack DM with a teammate", "the Gmail inbox"]),
        "meetings": Text(what: "Live calls and video meetings.",
                         notThis: "scheduling a meeting is system; chat is communication.",
                         examples: ["a Zoom call", "a Google Meet call"]),
        "system": Text(what: "Computer and account admin: settings, files, password managers, calendars, billing and admin pages.",
                       notThis: "developer and database consoles are coding.",
                       examples: ["macOS System Settings", "a SaaS billing page"]),
        "personal": Text(what: "Personal errands and life admin unrelated to work: shopping, banking, travel, health, personal email.",
                         notThis: "leisure media is entertainment; social feeds are social.",
                         examples: ["an Amazon order page", "online banking"]),
        "social": Text(what: "Social media feeds, threads and posting.",
                       notThis: "work messages on LinkedIn are communication.",
                       examples: ["the X timeline", "a Reddit thread"]),
        "entertainment": Text(what: "Leisure media: video, streaming, music, games, general news, sports.",
                              notThis: "technical talks and tutorials are research.",
                              examples: ["a YouTube music video", "a news homepage"]),
        "browsing": Text(what: "General web browsing that is unclear, mixed, or fits no other category.",
                         notThis: "anything that clearly matches another category.",
                         examples: ["a new-tab page", "a generic landing page"]),
    ]

    private static let projectPurpose: [String: String] = [
        "client-monitoring": "Monitoring ingestion for a data stack (Python scripts, Postgres monitoring schema).",
        "operations-dashboard": "Next.js monitoring and operations dashboard UI (app.example.com/monitoring).",
        "data-scrapers": "Data pipeline jobs and scheduled fetchers running on GitHub Actions.",
        "outreach-systems": "Communications automation: notifications, mail and workflow workers, CRM integration.",
        "example-ui-prototype": "Next.js prototype of the new ExampleCo app (dashboard, pipeline and workflow views).",
        "spells": "This macOS app: time tracking and voice tools (Swift, SwiftUI, SQLite).",
    ]
}
