import Foundation
import RewindCore

/// `spellsctl settings …` and `spellsctl rules …`: edit what the apps' Settings windows edit, without a
/// rebuild. Module settings are each module's flat JSON file; Rewind's live in hours.db's `setting` table;
/// rules go through `ConfigStore`, whose commit notifies the running Rewind and tracker to reload.

/// Module settings files, by the folder name under the support home.
private let fileModules = ["incant", "scry", "transmute", "ward", "spells"]
/// Rewind bookkeeping the apps write themselves; a hand edit would break the tracker or the export chain.
private let protectedRewindKeys: Set<String> = ["install_id", "tracker_state"]

/// One module's key/value store: a JSON file, or Rewind's `setting` table.
private struct SettingsTarget {
    let all: () throws -> [String: String]
    let set: (String, String?) throws -> Void

    static func named(_ module: String) -> SettingsTarget {
        if module == "rewind" {
            let store = SettingStore(openDB())
            return .init(all: { try store.all() }, set: { k, v in try store.set(k, v) })
        }
        guard fileModules.contains(module) else {
            die("unknown module '\(module)' (\((fileModules + ["rewind"]).joined(separator: ", ")))")
        }
        let file = SpellSettingsFile(spell: module, paths: paths)
        return .init(all: { file.all() }, set: { k, v in try file.set(k, v) })
    }
}

@MainActor func settings() throws {
    let args = positional
    guard let module = args.first else {
        for m in fileModules + ["rewind"] { try printSettings(m) }
        return
    }
    let target = SettingsTarget.named(module)
    let verb = args.count > 1 ? args[1] : "list"
    let key = args.count > 2 ? args[2] : nil
    let value = args.count > 3 ? args[3...].joined(separator: " ") : nil
    let current = try target.all()
    func need(_ what: String) -> Never { die("usage: spellsctl settings \(module) \(verb) \(what)") }
    if module == "rewind", let key, protectedRewindKeys.contains(key), verb != "get" {
        die("\(key) is written by Rewind itself; not editable here")
    }

    switch verb {
    case "list":
        try printSettings(module)
    case "get":
        guard let key else { need("<key>") }
        guard let v = current[key] else { die("\(module): \(key) is not set (the module uses its built-in default)", 1) }
        say(v)
    case "set":
        guard let key, var value else { need("<key> <value>   (value - reads stdin)") }
        if value == "-" {
            value = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            while value.hasSuffix("\n") { value.removeLast() }
        }
        if current[key] == nil { warn("\(module): \(key) wasn't set before; check the spelling, unknown keys are ignored") }
        try target.set(key, value)
        say("\(module).\(key) = \(value)")
    case "unset":
        guard let key else { need("<key>") }
        guard current[key] != nil else { die("\(module): \(key) is not set", 1) }
        try target.set(key, nil)
        say("\(module).\(key) removed; the module's built-in default applies")
    case "add", "remove":
        guard let key, let value else { need("<key> <item>") }
        // Unset lists mean "built-in default"; adding to an empty list would silently drop the defaults.
        guard let stored = current[key] else {
            die("\(module): \(key) is not set, so the module uses its built-in list. Set the full list first:\n"
                + "  printf 'a\\nb\\n' | spellsctl settings \(module) set \(key) -", 1)
        }
        var items = stored.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if verb == "add" {
            guard !items.contains(value) else { die("\(module).\(key) already has \"\(value)\"", 1) }
            items.append(value)
        } else {
            guard items.contains(value) else { die("\(module).\(key) has no line \"\(value)\"", 1) }
            items.removeAll { $0 == value }
        }
        try target.set(key, items.joined(separator: "\n"))
        say("\(module).\(key): \(items.joined(separator: ", "))")
    default:
        die("unknown settings verb '\(verb)' (list, get, set, unset, add, remove)")
    }
}

@MainActor private func printSettings(_ module: String) throws {
    let rows = try SettingsTarget.named(module).all()
    say("[\(module)]" + (rows.isEmpty ? "  (nothing set; built-in defaults)" : ""))
    for (k, v) in rows.sorted(by: { $0.key < $1.key }) {
        let shown = v.contains("\n") ? v.split(separator: "\n").joined(separator: " | ") : v
        say("  \(k) = \(shown.count > 160 ? shown.prefix(160) + "…" : shown)")
    }
}

private func warn(_ s: String) { FileHandle.standardError.write(Data(("warning: " + s + "\n").utf8)) }

// MARK: - rules

@MainActor func rules() throws {
    let args = positional
    let db = openDB()
    let config = ConfigStore(db)
    let categories = try config.categories()
    let projects = try config.projects()
    let verb = args.first ?? "list"

    switch verb {
    case "list":
        let all = try config.rules()
        let shown = flags.contains("--all") ? all : all.filter { $0.origin == .user || $0.enabled == false }
        if !flags.contains("--all") { say("user rules and disabled seed rules (--all for every rule):") }
        for r in shown { say("  " + describe(r, categories, projects)) }
        if shown.isEmpty { say("  (none)") }
        say("categories: " + categories.filter { !$0.archived }.map(\.key).joined(separator: ", "))
        say("projects:   " + projects.filter { !$0.archived }.map(\.name).joined(separator: ", "))

    case "add":
        guard let priority = Int(options["--priority"] ?? "0") else { die("bad --priority (an integer)") }
        var r = Rule(id: 0, origin: .user, priority: priority,
                     bundleId: options["--bundle"], appName: options["--app"], host: options["--host"],
                     pathPrefix: options["--path"], titleRegex: options["--title"])
        if let c = options["--category"] {
            guard let cat = categories.first(where: { $0.key == c || String($0.id) == c }) else {
                die("unknown --category '\(c)' (\(categories.map(\.key).joined(separator: ", ")))")
            }
            r.categoryId = cat.id
        }
        if let p = options["--project"] {
            guard let proj = projects.first(where: { $0.name == p || String($0.id) == p }) else {
                die("unknown --project '\(p)' (\(projects.map(\.name).joined(separator: ", ")))")
            }
            r.projectId = proj.id
        }
        guard [r.bundleId, r.appName, r.host, r.pathPrefix, r.titleRegex].contains(where: { $0 != nil }) else {
            die("rules add needs a match: --bundle ID, --app NAME, --host HOST [--path /prefix], --title REGEX")
        }
        guard r.categoryId != nil || r.projectId != nil else { die("rules add needs --category KEY and/or --project NAME") }
        if let t = r.titleRegex, (try? NSRegularExpression(pattern: t)) == nil { die("--title is not a valid regex: \(t)") }
        r.id = try config.insert(r)
        say("added " + describe(r, categories, projects))

    case "rm", "enable", "disable":
        guard args.count == 2, let id = Int64(args[1]) else { die("usage: spellsctl rules \(verb) <id>") }
        guard var r = try config.rules().first(where: { $0.id == id }) else { die("no rule \(id)", 1) }
        if verb == "rm" {
            // Seed rules come back on the next launch's seed merge; disabling them is what sticks.
            guard r.origin == .user else { die("rule \(id) is a built-in rule; use `spellsctl rules disable \(id)`", 1) }
            try config.deleteRule(id: id)
            say("removed " + describe(r, categories, projects))
        } else {
            r.enabled = verb == "enable"
            try config.update(r)
            say("\(verb)d " + describe(r, categories, projects))
        }

    default:
        die("unknown rules verb '\(verb)' (list, add, rm, enable, disable)")
    }
}

private func describe(_ r: Rule, _ cats: [RewindCore.Category], _ projs: [Project]) -> String {
    var parts: [String] = []
    if let v = r.bundleId { parts.append("bundle=\(v)") }
    if let v = r.appName { parts.append("app=\(v)") }
    if let v = r.host { parts.append("host=\(v)") }
    if let v = r.pathPrefix { parts.append("path=\(v)") }
    if let v = r.titleRegex { parts.append("title=/\(v)/") }
    if let id = r.categoryId { parts.append("→ " + (cats.first { $0.id == id }?.key ?? "#\(id)")) }
    if let id = r.projectId { parts.append("→ project " + (projs.first { $0.id == id }?.name ?? "#\(id)")) }
    let name = r.origin == .seed ? (r.seedKey ?? "seed") : "user"
    let state = (r.enabled ? "" : " [disabled]") + (r.priority != 0 ? " prio \(r.priority)" : "")
    return "#\(r.id) \(name)\(state)  " + parts.joined(separator: " ")
}
