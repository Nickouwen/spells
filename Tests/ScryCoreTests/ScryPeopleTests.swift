import Foundation
import Testing
@testable import ScryCore

/// A vault (it has .obsidian) with a people folder and a calls folder. Invented people.
private func vault() throws -> URL {
    let v = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "scry-people-\(UUID().uuidString)", directoryHint: .isDirectory)
    for d in [".obsidian", "People/old", "calls"] { try FileManager.default.createDirectory(at: v.appending(path: d), withIntermediateDirectories: true) }
    func put(_ p: String, _ s: String) throws { try s.write(to: v.appending(path: p), atomically: true, encoding: .utf8) }
    try put("People/Dana Whitfield.md", "---\ntype: person\nrole: Seller\ncompany: Estate\nemail: dana@example.com\naliases:\n  - Dana W\n  - \"D. Whitfield\"\n---\n# Dana Whitfield\n")
    try put("People/Alex (sales rep).md", "---\ntype: person\nemail:\n---\n# Alex (Alexander Reed, Sales)\n")
    try put("People/Sam Lee.md", "# Sam Lee\n")
    try put("People/old/Sam Lee.md", "---\ntype: person\naliases: [Samuel Lee, \"Sammy\"]\n---\n")
    try put("People/Project X.md", "---\ntype: project\n---\n")
    return v
}

private func md(_ extra: String = "") -> String {
    "---\ntitle: \"T\"\ndate: 2026-11-24\nstart: 2026-11-24T10:00:00Z\nend: 2026-11-24T10:05:00Z\nspeakers: {\"Speaker A\":\"Dana\"}\nsource: scry\n---\n\n# T\n\n## Summary\n\nFine.\n\n\(extra)## Follow-up email\n\nHi.\n\n## Transcript\n\n**[00:01] You:** Hi.\n\n**[00:05] Dana:** My brother Marcus.\n\n**[00:09] Dana:** ## People\n"
}

@Test func peopleAreReadFromTheirNotes() throws {
    let v = try vault(); defer { try? FileManager.default.removeItem(at: v) }
    let all = ScryPeople.load([v.appending(path: "People"), v.appending(path: "People")])
    #expect(all.map(\.name) == ["Alex", "Dana Whitfield", "Sam Lee", "Sam Lee"])   // the project isn't one; twice the folder is once
    #expect(all[1].aliases == ["Dana W", "D. Whitfield"] && all[1].emails == ["dana@example.com"] && all[1].detail == "Seller, Estate")
    #expect(all[0].emails.isEmpty)
    #expect(ScryPeople.load([v.appending(path: "missing")]).isEmpty)
}

@Test func onlyNoDoubtLinksByItself() throws {
    let v = try vault(); defer { try? FileManager.default.removeItem(at: v) }
    let all = ScryPeople.load([v.appending(path: "People")])
    #expect(ScryPeople.exact("dana  WHITFIELD", in: all)?.name == "Dana Whitfield" && ScryPeople.exact("D Whitfield", in: all)?.name == "Dana Whitfield")
    #expect(ScryPeople.exact("Anyone", email: "Dana@Example.com", in: all)?.name == "Dana Whitfield")
    #expect(ScryPeople.exact("Dana", in: all) == nil && ScryPeople.exact("Alex", in: all) == nil)   // a first name alone
    #expect(ScryPeople.exact("Sam Lee", in: all) == nil)                                            // two of them
    #expect(ScryPeople.exact("Sammy", in: all) == nil && ScryPeople.exact("Samuel Lee", in: all)?.url.path.contains("/old/") == true)
    #expect(ScryPeople.suggestions("Dana", in: all).map(\.name) == ["Dana Whitfield"])
    #expect(ScryPeople.suggestions("Alexander", in: all).first?.name == "Alex" && ScryPeople.suggestions("", in: all).isEmpty)
    #expect(ScryPeople.suggestions("Zoe", in: all).isEmpty)
}

@Test func rowsRoundTripAndCannotBreakTheNote() throws {
    for p in [ScryNotePerson(name: "Marcus", role: .mentioned, at: "01:44", detail: "brother, owns half", link: "[[People/Marcus Whitfield|Marcus Whitfield]]"),
              ScryNotePerson(name: "Dana", role: .speaker, link: "[Dana](file:///a%20b/Dana%20%28x%29.md)"), ScryNotePerson(name: "Speaker B", role: .speaker)] {
        #expect(ScryNotePerson.parse(p.markdown) == p)
    }
    let odd = ScryNotePerson(name: "**A** → [[x]]\n## Transcript", role: .mentioned, detail: "a · b\nc")
    #expect(!odd.markdown.contains("\n") && ScryNotePerson.parse(odd.markdown) == odd && odd.link == nil)
    #expect(ScryNotePerson.parse("- [ ] **You**: call (due x)") == nil && ScryNotePerson.parse("- **You** (later): x") == nil)
    let note = try #require(ScryNote.parse(md()))
    #expect(note.people.isEmpty && ScryPeople.people(in: note).map(\.id) == ["speaker/Dana"])   // a row for the speaker, not for You
    var full = note
    full.people = [ScryNotePerson(name: "Dana", role: .speaker, link: "[[People/Dana Whitfield|Dana Whitfield]]"), ScryNotePerson(name: "Marcus", role: .mentioned)]
    #expect(ScryNote.parse(full.markdown())?.people == full.people && ScryPeople.people(in: full).count == 2)
}

@Test func linkingASpeakerNamesThemAndOnlyTouchesWhatItMust() throws {
    let v = try vault(); defer { try? FileManager.default.removeItem(at: v) }
    let url = v.appending(path: "calls/note.md"), all = ScryPeople.load([v.appending(path: "People")])
    try md().write(to: url, atomically: true, encoding: .utf8)
    let dana = try #require(all.first { $0.name == "Dana Whitfield" })
    let a = try #require(try ScryNotes.linkPerson(url, .init(name: "Dana", role: .speaker), to: dana))
    #expect(a.note.people == [.init(name: "Dana Whitfield", role: .speaker, link: "[[People/Dana Whitfield|Dana Whitfield]]")])
    #expect(a.note.segments.map(\.speaker) == ["You", "Dana Whitfield", "Dana Whitfield"] && a.note.segments[2].text == "## People")
    #expect(a.markdown.contains("\n\n## People\n\n- **Dana Whitfield** (speaker) → [[People/Dana Whitfield|Dana Whitfield]]\n\n## Follow-up email\n"))
    #expect(ScryPeople.person(for: a.note.people[0].link!, in: all) == dana)
    let b = try #require(try ScryNotes.linkPerson(url, .init(name: "Marcus", role: .mentioned, at: "00:05", detail: "brother"), to: nil))
    let c = try #require(try ScryNotes.linkPerson(url, b.note.people[1], to: all[0]))   // a mention keeps the name that was said
    #expect(c.note.people.map(\.name) == ["Dana Whitfield", "Marcus"] && c.note.people[1].link == "[[People/Alex (sales rep)|Alex]]" && c.note.people[1].detail == "brother")
    let d = try #require(try ScryNotes.linkPerson(url, c.note.people[0], to: nil))
    #expect(d.note.people[0].link == nil && d.note.people.count == 2)
    // Renaming the speaker by hand keeps the row; the rest is as it was.
    let e = try #require(try ScryNotes.rename(url, from: "Dana Whitfield", to: "Dana"))
    #expect(e.note.people.map(\.name) == ["Dana", "Marcus"])
    let withoutPeople = e.markdown.replacingOccurrences(of: #"## People\n\n(- .*\n)+\n"#, with: "", options: .regularExpression)
    #expect(withoutPeople == md())
}

@Test func twoVoicesThatAreOnePersonBecomeOneRow() throws {
    let v = try vault(); defer { try? FileManager.default.removeItem(at: v) }
    let url = v.appending(path: "calls/two.md"), dana = try #require(ScryPeople.load([v.appending(path: "People")]).first { $0.name == "Dana Whitfield" })
    try md("## People\n\n- **Dana** (speaker)\n- **Speaker B** (speaker)\n\n").replacingOccurrences(of: "**[00:09] Dana:**", with: "**[00:09] Speaker B:**").write(to: url, atomically: true, encoding: .utf8)
    _ = try ScryNotes.linkPerson(url, .init(name: "Dana", role: .speaker), to: dana)
    let n = try #require(try ScryNotes.linkPerson(url, .init(name: "Speaker B", role: .speaker), to: dana))
    #expect(n.note.people.map(\.name) == ["Dana Whitfield"] && Set(n.note.segments.map(\.speaker)) == ["You", "Dana Whitfield"])
}

@Test func linksOutsideTheVaultAreFileLinksAndOddNamesStillWork() throws {
    let v = try vault(); defer { try? FileManager.default.removeItem(at: v) }
    let out = FileManager.default.temporaryDirectory.appending(path: "elsewhere-\(UUID().uuidString).md")
    let alex = try #require(ScryPeople.load([v.appending(path: "People")]).first { $0.name == "Alex" })
    let l = ScryPeople.link(to: alex, from: out)
    #expect(l.hasPrefix("[Alex](file:///") && !l.contains("(sales") && ScryPeople.person(for: l, in: [alex]) == alex)
    #expect(ScryNotePerson.parse(ScryNotePerson(name: "Alex", role: .mentioned, link: l).markdown)?.link == l)
    #expect(ScryPeople.person(for: "[[People/Gone]]", in: [alex]) == nil && ScryPeople.person(for: "[x](https://example.com)", in: [alex]) == nil)
}

@Test func aNewNoteLinksSpeakersAndMentionsWithoutDoubles() throws {
    let v = try vault(); defer { try? FileManager.default.removeItem(at: v) }
    let all = ScryPeople.load([v.appending(path: "People")]), note = v.appending(path: "calls/n.md")
    func s(_ who: String) -> ScrySegment { .init(speaker: who, start: 0, end: 1, text: "x") }
    let rows = ScryPeople.rows(segments: [s("You"), s("Dana"), s("Alex"), s("Dana")],
                               mentioned: [.init(name: "dana", role: .mentioned), .init(name: "Sam Lee", role: .mentioned, at: "00:05"), .init(name: "Nic Example", role: .mentioned), .init(name: "Sam Lee", role: .mentioned)],
                               emails: ["Dana": "dana@example.com"], owner: "Nic Example", known: all, note: note)
    #expect(rows.map(\.name) == ["Dana", "Alex", "Sam Lee"])
    #expect(rows[0].link == "[[People/Dana Whitfield|Dana Whitfield]]" && rows[1].link == nil && rows[2].link == nil)
}

@Test func aNewPersonNoteNeverReplacesOne() throws {
    let v = try vault(); defer { try? FileManager.default.removeItem(at: v) }
    let folder = v.appending(path: "People"), call = v.appending(path: "calls/2026-11-24-call.md")
    let p = try ScryPeople.create("Marcus / Whit:field", email: nil, detail: "brother", from: call, in: folder, date: "2026-11-24")
    #expect(p.url.lastPathComponent == "Marcus  Whitfield.md" || p.url.lastPathComponent == "Marcus Whitfield.md")
    let made = try String(contentsOf: p.url, encoding: .utf8)
    #expect(ScryPeople.load([folder]).contains { $0.name == p.name } && made.contains("[[2026-11-24-call]]"))
    #expect(throws: (any Error).self) { try ScryPeople.create("Dana Whitfield", email: nil, detail: "", from: call, in: folder, date: "2026-11-24") }
    #expect(throws: (any Error).self) { try ScryPeople.create(" ../ ", email: nil, detail: "", from: call, in: folder, date: "2026-11-24") }
}

@Test func theSummaryNamesPeopleMentionedAndPeopleFoldersRoundTrip() throws {
    let r = try ScryPrompt.parseSummary(#"{"title":"T","summary":"s","people":[{"name":"Marcus","detail":"her brother","at":"00:31"},{"name":null},{"name":"X","at":"soon"}]}"#)
    #expect(r.people == [.init(name: "Marcus", role: .mentioned, at: "00:31", detail: "her brother"), .init(name: "X", role: .mentioned)])
    #expect(try ScryPrompt.parseSummary(#"{"title":"T","summary":"s"}"#).people.isEmpty)
    var s = ScrySettings(); s.people = ["~/People", "/tmp/p"]
    #expect(ScrySettings.load(s.rows) == s)
}
