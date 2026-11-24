import Foundation

/// Someone you already know: a note in one of your people folders (`scry_people`). The file name is the name; the
/// frontmatter may add `aliases`, `email`, `phone`, `role`, `company`.
public struct ScryPerson: Identifiable, Equatable, Sendable {
    public var name: String, aliases: [String], emails: [String], detail: String, url: URL
    public var id: String { url.path }
    public init(name: String, aliases: [String] = [], emails: [String] = [], detail: String = "", url: URL) {
        self.name = name; self.aliases = aliases; self.emails = emails; self.detail = detail; self.url = url
    }
}

/// A person in a meeting note: someone who spoke, or someone who was talked about, and who that is (`link`).
public struct ScryNotePerson: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case speaker, mentioned }
    public var name: String, role: Role
    /// When they were first mentioned ("01:44").
    public var at: String?
    /// "brother, owns the other half".
    public var detail: String
    /// A Markdown or wiki link to the person's note; nil = not linked.
    public var link: String?
    public var id: String { "\(role.rawValue)/\(name)" }
    public init(name: String, role: Role, at: String? = nil, detail: String = "", link: String? = nil) {
        self.name = Self.plain(name); self.role = role; self.at = at; self.detail = Self.plain(detail); self.link = link
    }

    /// One line without the characters the note's own format uses: a model or a caption wrote these.
    static func plain(_ s: String) -> String {
        String(s.map { $0.isNewline ? " " : $0 }.filter { !"*[]|→·".contains($0) }).trimmingCharacters(in: .whitespaces)
    }

    /// `- **Marcus** (mentioned 01:44) → [[People/Marcus Whitfield|Marcus Whitfield]] · brother`
    public var markdown: String {
        "- **\(name)** (\(role.rawValue)\(at.map { " \($0)" } ?? ""))" + (link.map { " → \($0)" } ?? "") + (detail.isEmpty ? "" : " · \(detail)")
    }

    public static func parse(_ line: String) -> ScryNotePerson? {
        guard let m = line.wholeMatch(of: #/- \*\*(.+?)\*\* \((speaker|mentioned)(?: (\d+:\d\d))?\)(?: → (\[\[.+?\]\]|\[.+?\]\(.+?\)))?(?: · (.*))?\s*/#) else { return nil }
        return .init(name: String(m.1), role: Role(rawValue: String(m.2))!, at: m.3.map(String.init), detail: m.5.map(String.init) ?? "", link: m.4.map(String.init))
    }
}

public enum ScryPeople {
    // MARK: Who we know

    /// Every person note in `folders` (subfolders too, hidden ones not), by name.
    public static func load(_ folders: [URL]) -> [ScryPerson] {
        var seen: Set<String> = []
        return folders.flatMap { folder -> [ScryPerson] in
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "md" } ?? []
            return files.compactMap { url in
                let url = url.resolvingSymlinksInPath()
                guard seen.insert(url.path).inserted, let md = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return person(md, url: url)
            }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// nil for a note whose frontmatter says it's something else (`type: project`).
    static func person(_ md: String, url: URL) -> ScryPerson? {
        var fm: [String: [String]] = [:], key = ""
        let lines = md.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.first == "---" {
            for l in lines.dropFirst() {
                if l == "---" { break }
                if l.hasPrefix("- "), !key.isEmpty { fm[key, default: []].append(unquoted(String(l.dropFirst(2)))) }
                else if let c = l.firstIndex(of: ":") {
                    key = l[..<c].trimmingCharacters(in: .whitespaces).lowercased()
                    let v = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
                    fm[key] = (v.hasPrefix("[") ? v.dropFirst().dropLast().split(separator: ",").map(String.init) : [v]).map(unquoted).filter { !$0.isEmpty }
                }
            }
        }
        if let t = fm["type"]?.first, !["person", "people", "contact"].contains(t.lowercased()) { return nil }
        let file = url.deletingPathExtension().lastPathComponent, name = bare(file)
        guard !name.isEmpty else { return nil }
        let heading = lines.first { $0.hasPrefix("# ") }.map { bare(String($0.dropFirst(2))) }
        let aliases = ((fm["aliases"] ?? fm["alias"] ?? []) + [heading].compactMap { $0 }).filter { !$0.isEmpty && matchKey($0) != matchKey(name) }
        return ScryPerson(name: name, aliases: aliases, emails: (fm["email"] ?? []) + (fm["emails"] ?? []),
                          detail: [fm["role"]?.first, fm["company"]?.first].compactMap { $0 }.joined(separator: ", "), url: url)
    }

    private static func unquoted(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
    /// "Patrick (sales rep)" → "Patrick".
    private static func bare(_ s: String) -> String { s.replacing(/\s*\([^)]*\)/, with: "").trimmingCharacters(in: .whitespaces) }
    static func matchKey(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") }

    // MARK: Matching

    /// The one person this must be: the same email, or the same full name (two words or more). Two people who fit, or a
    /// first name alone, is nobody: that's for you to say.
    public static func exact(_ name: String, email: String? = nil, in people: [ScryPerson]) -> ScryPerson? {
        if let e = email?.lowercased(), !e.isEmpty {
            let same = people.filter { $0.emails.contains { $0.lowercased() == e } }
            if !same.isEmpty { return same.count == 1 ? same[0] : nil }
        }
        let k = matchKey(name)
        guard k.contains(" ") else { return nil }
        // "D. Whitfield" is an alias for choosing, not for being sure: an initial is nobody's full name.
        guard k.split(separator: " ").allSatisfy({ $0.count > 1 }) else { return nil }
        let same = people.filter { ([$0.name] + $0.aliases).contains { matchKey($0) == k } }
        return same.count == 1 ? same[0] : nil
    }

    /// Best guesses first, for you to choose from: same name, then every word shared, then the same first name.
    public static func suggestions(_ name: String, in people: [ScryPerson]) -> [ScryPerson] {
        let words = matchKey(name).split(separator: " ").map(String.init)
        guard let first = words.first else { return [] }
        func score(_ p: ScryPerson) -> Int {
            ([p.name] + p.aliases).map { n in
                let theirs = matchKey(n).split(separator: " ").map(String.init)
                if theirs == words { return 4 }
                if Set(words).isSubset(of: Set(theirs)) || Set(theirs).isSubset(of: Set(words)) { return 3 }
                if let f = theirs.first, f == first || min(f.count, first.count) >= 3 && (f.hasPrefix(first) || first.hasPrefix(f)) { return 2 }
                return theirs.last == words.last && words.count > 1 ? 1 : 0
            }.max() ?? 0
        }
        return people.map { ($0, score($0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)   // stable: by name within a score
    }

    // MARK: Links

    /// How the meeting note points at `person`: a wiki link inside the same Obsidian vault, else a file link.
    public static func link(to person: ScryPerson, from note: URL) -> String {
        let target = person.url.resolvingSymlinksInPath(), name = ScryNotePerson.plain(person.name)
        if let vault = vault(of: target), vault == Self.vault(of: note.resolvingSymlinksInPath()) {
            let path = target.deletingPathExtension().path.dropFirst(vault.path.count + 1)
            if !path.contains(where: { "|#^[]".contains($0) }) { return "[[\(path)|\(name)]]" }
        }
        let url = target.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[\(name)](\(url))"
    }

    private static func vault(of url: URL) -> URL? {
        var d = url.deletingLastPathComponent().standardizedFileURL
        while d.path != "/" {
            if FileManager.default.fileExists(atPath: d.appending(path: ".obsidian").path) { return d }
            d = d.deletingLastPathComponent().standardizedFileURL
        }
        return nil
    }

    /// The known person a note's link points at; nil when that note is gone (renamed, moved). A wiki link is a path in the
    /// meeting note's own vault.
    public static func person(for link: String, from note: URL, in people: [ScryPerson]) -> ScryPerson? {
        if let m = link.wholeMatch(of: #/\[\[(.+?)(?:\|.*)?\]\]/#) {
            guard let vault = vault(of: note.resolvingSymlinksInPath()) else { return nil }
            let path = vault.appending(path: String(m.1) + ".md").path
            return people.first { $0.url.path == path }
        }
        guard let m = link.wholeMatch(of: #/\[.*?\]\((.+)\)/#), let u = URL(string: String(m.1)), u.isFileURL else { return nil }
        return people.first { $0.url.path == u.resolvingSymlinksInPath().path }
    }

    // MARK: In a note

    /// The note's people: its "## People" rows, plus a row for every speaker who has none ("You" is you).
    public static func people(in note: ScryNote) -> [ScryNotePerson] {
        var seen = Set(note.people.filter { $0.role == .speaker }.map(\.name))
        let more = note.segments.map(\.speaker).filter { $0 != "You" && seen.insert(ScryNotePerson.plain($0)).inserted }
        return more.map { ScryNotePerson(name: $0, role: .speaker) } + note.people
    }

    /// Everyone in a new note, linked where there is no doubt (`exact`). `emails`: the invite's, by name.
    public static func rows(segments: [ScrySegment], mentioned: [ScryNotePerson], emails: [String: String], owner: String,
                            known: [ScryPerson], note: URL, picked: [String: String] = [:]) -> [ScryNotePerson] {
        var seen: Set<String> = []
        func row(_ p: ScryNotePerson) -> ScryNotePerson? {
            guard !p.name.isEmpty, seen.insert(matchKey(p.name)).inserted else { return nil }
            var p = p
            // Who you picked in the live panel, else no doubt.
            let who = picked[p.name].flatMap { path in known.first { $0.id == path } } ?? exact(p.name, email: emails[p.name], in: known)
            p.link = who.map { link(to: $0, from: note) }
            return p
        }
        var speakers: [ScryNotePerson] = [], names: Set<String> = []
        for s in segments where s.speaker != "You" && names.insert(s.speaker).inserted {
            if let r = row(.init(name: s.speaker, role: .speaker)) { speakers.append(r) }
        }
        return speakers + mentioned.filter { matchKey($0.name) != matchKey(owner) && matchKey($0.name) != "you" }.compactMap(row)
    }

    /// Adds or replaces one row of the note's "## People" section; everything else stays as it is.
    public static func setting(_ p: ScryNotePerson, in md: String) -> String {
        var lines = md.components(separatedBy: "\n")
        let head = lines.firstIndex(of: "## Transcript") ?? lines.count   // never inside the transcript
        if let start = lines[..<head].firstIndex(of: "## People") {
            let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
            let same = (start + 1..<end).filter { ScryNotePerson.parse(lines[$0])?.id == p.id }
            if let i = same.first {
                lines[i] = p.markdown
                for j in same.dropFirst().reversed() { lines.remove(at: j) }
            } else {
                let last = (start + 1..<end).last { !lines[$0].isEmpty } ?? start
                lines.insert(contentsOf: last == start ? ["", p.markdown] : [p.markdown], at: last + 1)
            }
            return lines.joined(separator: "\n")
        }
        let at = ["## Your notes", "## Follow-up email", "## Transcript"].compactMap { lines[..<min(head + 1, lines.count)].firstIndex(of: $0) }.min() ?? lines.count
        lines.insert(contentsOf: ["## People", "", p.markdown, ""], at: at)
        return lines.joined(separator: "\n")
    }

    /// Rows for the same person become one, keeping what either knew.
    public static func merged(_ rows: [ScryNotePerson], _ more: [ScryNotePerson] = []) -> [ScryNotePerson] {
        (rows + more).reduce(into: []) { out, p in
            guard let i = out.firstIndex(where: { $0.id == p.id }) else { out.append(p); return }
            out[i].link = out[i].link ?? p.link
            out[i].at = out[i].at ?? p.at
            if out[i].detail.isEmpty { out[i].detail = p.detail }
        }
    }

    /// `merged` over a note's "## People" rows; the note is unchanged when no two rows are the same.
    static func tidied(_ md: String) -> String {
        let rows = rows(in: md), one = merged(rows.map(\.person))
        guard one.count < rows.count else { return md }
        var lines = md.components(separatedBy: "\n")
        for (i, p) in zip(rows.map(\.line), rows.map(\.person)) where rows.first(where: { $0.person.id == p.id })?.line == i {
            lines[i] = one.first { $0.id == p.id }!.markdown
        }
        for row in rows.reversed() where rows.first(where: { $0.person.id == row.person.id })!.line != row.line { lines.remove(at: row.line) }
        return lines.joined(separator: "\n")
    }

    /// The note without one row.
    static func removing(_ p: ScryNotePerson, from md: String) -> String {
        var lines = md.components(separatedBy: "\n")
        for row in rows(in: md).reversed() where row.person.id == p.id { lines.remove(at: row.line) }
        return lines.joined(separator: "\n")
    }

    static func rows(in md: String) -> [(line: Int, person: ScryNotePerson)] {
        let lines = md.components(separatedBy: "\n"), head = lines.firstIndex(of: "## Transcript") ?? lines.count
        guard let start = lines[..<head].firstIndex(of: "## People") else { return [] }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
        return (start + 1..<end).compactMap { i in ScryNotePerson.parse(lines[i]).map { (i, $0) } }
    }

    /// Writes a new person note; throws when one with that name is there.
    public static func create(_ name: String, email: String?, detail: String, from note: URL, in folder: URL, date: String) throws -> ScryPerson {
        let name = ScryNotePerson.plain(name).filter { !"/\\:#^".contains($0) }.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !name.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name + ".md"), from = note.deletingPathExtension().lastPathComponent
        let md = (["---", "type: person", "email: \(email ?? "")", "created: \(date)", "author: ai", "source: Scry note \(from)", "---", "# \(name)", "",
                   "**How I know them:** from the call in [[\(from)]]."] + (detail.isEmpty ? [] : ["", detail])).joined(separator: "\n") + "\n"
        try Data(md.utf8).write(to: url, options: .withoutOverwriting)
        return ScryPerson(name: name, emails: [email].compactMap { $0 }, url: url.resolvingSymlinksInPath())
    }
}
