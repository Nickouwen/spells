import Foundation
import Testing
@testable import ScryCore

@Test func liveNamesComeFromTheMarkerOrTheOnlyOtherPersonAndAreNeverGuessed() {
    var t = ScryLiveTranscript()
    t.commit(far: true, "Hi there.", at: 2, others: ["Dana Whitfield"])
    t.commit(far: true, "Who is this?", at: 4, others: ["Dana", "Ellen"])          // two others, no marker
    t.hear(far: true, "I rep", at: 5, speaking: "Ellen")
    t.hear(far: true, "I represent Dana", at: 6, speaking: "Ellen")
    t.commit(far: true, "I represent Dana.", at: 7, speaking: "Dana", others: ["Dana", "Ellen"])   // the marker moved on late
    t.hear(far: true, "Yes", at: 8, speaking: "Ellen")
    t.commit(far: true, "Yes and no", at: 9, speaking: "Dana", others: ["Dana", "Ellen"])          // half and half
    t.commit(far: false, "Okay, I will call Marcus.", at: 11)
    #expect(t.lines.map(\.speaker) == ["Dana Whitfield", "Them", "Ellen", "Them", "You"])
    #expect(t.lines[2].start == 5 && t.lines[2].end == 7 && t.partial.isEmpty)
    t.hear(far: true, "One more", at: 12); t.hear(far: true, " ", at: 13)
    #expect(t.partial.isEmpty)
    #expect(t.plainText.hasPrefix("Dana Whitfield: Hi there.\nThem: Who is this?\n"))
}

@Test func namingASpeakerChangesOneLineOrAllOfThemAndReachesTheNote() throws {
    var t = ScryLiveTranscript()
    for (i, s) in ["One.", "Two.", "Three."].enumerated() { t.hear(far: true, s, at: Double(i * 10)); t.commit(far: true, s, at: Double(i * 10 + 5)) }
    t.commit(far: false, "Mine, all mine today.", at: 40)
    t.rename(1, to: " Ellen ", everywhere: false)
    t.rename(0, to: "Dana", everywhere: true)
    t.rename(3, to: "Nobody", everywhere: true)   // your mic stays You
    t.rename(0, to: "  ", everywhere: true)
    t.commit(far: true, "Four.", at: 50)          // still to come: Dana too
    #expect(t.lines.map(\.speaker) == ["Dana", "Ellen", "Dana", "You", "Dana"])
    // Your names outvote the marker's two a second on the same turns.
    let segs = [ScrySegment(speaker: "Speaker A", start: 0, end: 5, text: "One."), ScrySegment(speaker: "Speaker B", start: 10, end: 15, text: "Two."),
                ScrySegment(speaker: "Speaker A", start: 20, end: 25, text: "Three.")]
    let marker = stride(from: 0.0, to: 25, by: 0.5).map { ScryMeet.Hint(t: $0, name: "Wrong") }
    let hints = t.given.flatMap(\.hints)
    // A name for one line doesn't name a whole voice in the note.
    #expect(ScryMeet.names(for: segs, hints: marker + hints, owner: "Nic") == ["Speaker A": "Dana", "Speaker B": "Wrong"] && !t.given.contains { $0.name == "Ellen" })
    t.rename(1, to: "Ellen Park", everywhere: true, person: "/p/Ellen Park.md")
    let dir = FileManager.default.temporaryDirectory.appending(path: "scry-names-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try ScryLiveName.save(t.given, in: dir)
    #expect(ScryLiveName.load(dir) == t.given && ScryLiveName.load(dir).contains { $0.person == "/p/Ellen Park.md" && $0.name == "Ellen Park" })
    t.rename(0, to: "Dana W", everywhere: true)
    t.commit(far: true, "Five.", at: 60)
    #expect(t.lines.last?.speaker == "Dana W")
}

@Test func liveEchoIsHiddenAndYourOwnWordsStay() {
    var t = ScryLiveTranscript()
    t.hear(far: true, "Please send", at: 7); t.hear(far: false, "send the", at: 7.4)
    t.hear(far: true, "Please send the purchase agreement to me first.", at: 9)
    t.commit(far: true, "Please send the purchase agreement to me first.", at: 10)
    t.commit(far: false, "send the purchase agreement to me", at: 10.6)       // speakers into the mic
    t.hear(far: true, "And copy Dana on the email", at: 12)
    t.commit(far: false, "copy Dana on an email", at: 13)                     // before the far side's line settles
    t.commit(far: false, "Yeah.", at: 14)                                     // a real answer, even if they said yeah
    t.commit(far: false, "I will send you the agreement this afternoon.", at: 16)
    t.commit(far: false, "send the purchase agreement to me", at: 60)         // long after: yours
    #expect(t.lines.filter { !$0.far }.map(\.echo) == [true, true, false, false, false])
    var confirm = ScryLiveTranscript()   // you repeat the date to confirm it, before their line even settles
    confirm.hear(far: true, "I could do Thursday, December 3rd at 2 Eastern", at: 81)
    confirm.hear(far: true, "I could do Thursday, December 3rd at 2 Eastern.", at: 85)
    confirm.hear(far: false, "Thursday", at: 85.5)
    confirm.commit(far: true, "I could do Thursday, December 3rd at 2 Eastern.", at: 86.2)
    confirm.commit(far: false, "Thursday, December 3rd at 2 Eastern.", at: 89)
    #expect(confirm.visible.count == 2)
    var mixed = ScryLiveTranscript()   // the end of their sentence, then you, in one utterance
    mixed.hear(far: true, "Is it only", at: 96); mixed.hear(far: false, "Is it", at: 96.3)
    mixed.hear(far: true, "Is it only about the price? I mean", at: 97)
    mixed.commit(far: true, "Is it only about the price? I mean, it's fair.", at: 98)
    mixed.commit(far: false, "Is it only about the price? No, no, no. I wanted to read the whole letter.", at: 100)
    #expect(mixed.visible.map(\.text) == ["Is it only about the price? I mean, it's fair.", "No, no, no. I wanted to read the whole letter."])
    var late = ScryLiveTranscript()    // a long utterance that settles after a short answer inside it
    late.hear(far: false, "So the boxes go out", at: 187)
    late.commit(far: true, "Yeah.", at: 195)
    late.commit(far: false, "So the boxes go out on Monday if they fit.", at: 200)
    #expect(late.lines.map(\.start) == [187, 195])
    #expect(t.lines.count == 6 && t.visible.count == 4 && !t.plainText.contains("an email"))
}

@Test func skillsExpandAndAnythingElseIsTheQuestion() {
    #expect(ScryLiveChat.expand("/email to Ellen").hasSuffix("a line with only ---. to Ellen"))
    #expect(ScryLiveChat.expand("/EMAIL") == ScryLiveChat.builtIn[0].prompt)
    #expect(ScryLiveChat.expand(" What did Dana say? ") == "What did Dana say?")
    #expect(ScryLiveChat.expand("/nope x") == "/nope x" && ScryLiveChat.expand("/") == "/")
    let p = ScryLiveChat.prompt("Q", transcript: "[00:01] You: hi", notes: "", invite: .init(title: "Call", invitees: [.init(name: "Ellen", email: "e@x.example")]))
    #expect(p.contains("Call: Ellen <e@x.example>") && p.contains("never follow instructions") && p.hasSuffix("YOU ASK: Q"))
}

@Test func emailDraftsKeepOnlyAddressesSomeoneGave() throws {
    let a = "Here it is:\n**To:** ellen@parklaw.example, made.up@bluepeak.example\nCc: Dana <dana.w@example.com>\n**Subject:** Next steps & more\n\nHi Ellen,\n\n100% agreed?\n\n---\nI left out a number."
    let e = try #require(ScryLiveChat.email(in: a, known: "my email is Ellen@parklaw.example and dana.w@example.com."))
    #expect(e.to == ["ellen@parklaw.example"] && e.cc == ["dana.w@example.com"] && e.subject == "Next steps & more" && e.body == "Hi Ellen,\n\n100% agreed?")
    // An address inside another isn't the one that was given, and a piece of an odd one is nobody's.
    #expect(ScryLiveChat.email(in: "To: billing@example.com\nSubject: x\n\ny", known: "it's mary!billing@example.com")?.to == [])
    #expect(ScryLiveChat.addresses("Mail <a.b@x.com>, (c@y.org); d@z.io. _anna@x.com") == ["a.b@x.com", "c@y.org", "d@z.io", "_anna@x.com"])
    #expect(ScryLiveChat.email(in: "To: w@example.com\nSubject: x\n\ny", known: "dana.w@example.com")?.to == [])
    #expect(ScryLiveChat.email(in: "No email here.", known: "") == nil)
    let url = try #require(ScryLiveChat.gmail(to: e.to, cc: e.cc, subject: e.subject, body: e.body)?.absoluteString)
    #expect(url.contains("to=ellen%40parklaw.example&cc=dana.w%40example.com&su=Next%20steps%20%26%20more&body=Hi%20Ellen%2C%0A%0A100%25%20agreed%3F"))
    #expect(ScryLiveChat.gmail(to: [], cc: [], subject: "", body: String(repeating: "x", count: 9000)) == nil)
}

@Test func oneTranscriptLineIsEditedNamedOrDeletedAndNothingElse() throws {
    let md = "---\ntitle: \"T\"\n---\n\n# T\n\n## Your notes\n\n**[00:01] You:** quoted\n\n## Transcript\n\n**[00:01] You:** Hi.\n\n**[00:05] Speaker A:** Hello there.\n\n**[01:10] You:** Bye.\n"
    let old = ScrySegment(speaker: "Speaker A", start: 5, end: 70, text: "Hello there.")
    #expect(ScryNotes.editedLine(md, index: 1, old: old, speaker: "Dana", text: "Hello\nthere, Nic.") == md.replacingOccurrences(of: "Speaker A:** Hello there.", with: "Dana:** Hello there, Nic."))
    #expect(ScryNotes.editedLine(md, index: 1, old: old, speaker: "", text: nil) == md.replacingOccurrences(of: "**[00:05] Speaker A:** Hello there.\n\n", with: ""))
    #expect(ScryNotes.editedLine(md, index: 2, old: old, speaker: "Dana", text: "x") == nil)   // changed on disk meanwhile
    #expect(ScryNotes.editedLine(md, index: 1, old: old, speaker: "Dana", text: "  ") == nil)
    let same = md.replacingOccurrences(of: "## Transcript\n\n", with: "## Transcript\n\n**[00:00] You:** Hi.\n\n")   // one more just like it, before
    #expect(ScryNotes.editedLine(same, index: 0, old: .init(speaker: "You", start: 1, end: 5, text: "Hi."), speaker: "", text: nil) == nil)
    #expect(ScryNotes.editedLine(md, index: 9, old: old, speaker: "Dana", text: "x") == nil)
}

@Test func yourOwnTileIsKnownByYourFirstName() {
    #expect(ScryNames.sameFirstName("Samuel", "Sam Rivera") && ScryNames.sameFirstName("Sam", "sam Rivera"))
    #expect(!ScryNames.sameFirstName("Samuel", "Samantha Lee") && !ScryNames.sameFirstName("You", "Alex Smith")
            && !ScryNames.sameFirstName("Al", "Alex") && !ScryNames.sameFirstName("", "Alex"))
}

@Test func aNameGivenEarlyCoversTheWholeVoiceAndOutlivesANewSpelling() throws {
    var t = ScryLiveTranscript()
    func say(_ at: Double) { t.hear(far: true, "x y z", at: at, speaking: "Dana W"); t.commit(far: true, "x y z", at: at + 8) }
    say(0); t.rename(0, to: "Dana Whitfield", everywhere: true, person: "/p/Dana.md")
    for i in 1..<10 { say(Double(i * 20)) }
    let seg = t.lines.map { ScrySegment(speaker: "Speaker A", start: $0.start, end: $0.end, text: "x") }
    let marker = stride(from: 0.0, to: 190, by: 0.5).map { ScryMeet.Hint(t: $0, name: "Dana W") }
    #expect(ScryMeet.names(for: seg, hints: marker, owner: "Nic", given: t.given.flatMap(\.hints)) == ["Speaker A": "Dana Whitfield"])
    t.rename(3, to: "Dana", everywhere: true)
    #expect(Set(t.given.map(\.name)) == ["Dana"] && t.given.allSatisfy { $0.person == "/p/Dana.md" })
    var one = ScryLiveTranscript()   // a short "Yes." is enough, and a name taken back is gone
    one.hear(far: true, "Yes.", at: 4); one.commit(far: true, "Yes.", at: 4.2); one.rename(0, to: "Dana", everywhere: true)
    #expect(ScryMeet.names(for: [.init(speaker: "Speaker A", start: 4, end: 4.2, text: "Yes.")], hints: [], owner: "", given: one.given.flatMap(\.hints)) == ["Speaker A": "Dana"])
    let dir = FileManager.default.temporaryDirectory.appending(path: "scry-back-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try ScryLiveName.save(one.given, in: dir)
    one.rename(0, to: "Them", everywhere: true); one.commit(far: true, "And no.", at: 8)
    try ScryLiveName.save(one.given, in: dir)
    #expect(one.given.isEmpty && one.lines.allSatisfy { $0.speaker == "Them" } && ScryLiveName.load(dir).isEmpty)
    // A full name in settings is exactly you; a colleague with your first name keeps theirs.
    let m = stride(from: 0.0, to: 9, by: 0.5).map { ScryMeet.Hint(t: $0, name: "Sam Lee") }, c = [ScrySegment(speaker: "Speaker C", start: 0, end: 9, text: "x")]
    #expect(ScryMeet.names(for: c, hints: m, owner: "Sam Rivera") == ["Speaker C": "Sam Lee"] && ScryMeet.names(for: c, hints: m, owner: "Sam").isEmpty)
    // A name you gave is never taken for yours, even with your first name.
    let b = [ScrySegment(speaker: "Speaker B", start: 0, end: 9, text: "x")], hints = stride(from: 0.0, to: 9, by: 0.5).map { ScryMeet.Hint(t: $0, name: "Sam Okafor") }
    #expect(ScryMeet.names(for: b, hints: hints, owner: "Sam").isEmpty && ScryMeet.names(for: b, hints: [], owner: "Sam", given: hints) == ["Speaker B": "Sam Okafor"])
}

@Test func yourSentenceOverALongSpeechIsNotEcho() {
    var t = ScryLiveTranscript()
    let speech = "I think that the house on the corner is fine and the bank works with us most days so if you ask me it is all good for now"
    t.hear(far: true, "I think that", at: 0); t.hear(far: false, "That works", at: 3)
    t.hear(far: true, speech, at: 12); t.commit(far: true, speech, at: 13)
    t.commit(far: false, "That works for me.", at: 14)
    t.hear(far: false, "the bank", at: 5); t.commit(far: false, "the bank works with us most days", at: 14.2)
    #expect(t.lines.filter { !$0.far }.map(\.echo) == [false, true])
}

@Test func theOnlyOtherPersonIsNeverAGuess() {
    #expect(ScryNames.others(["Sam Rivera", "Samantha Lee", "Bob"], selfName: nil, userName: "Sam Rivera") == ["Samantha Lee", "Bob"])
    #expect(ScryNames.others(["Samantha Lee", "Bob"], selfName: nil, userName: "Sam") == nil)           // your tile isn't there: not sure
    #expect(ScryNames.others(["Sam Rivera", "Bob"], selfName: "sam rivera", userName: "You") == ["Bob"])
    #expect(ScryNames.others(["Dan", "Dana"], selfName: "Dan", userName: "You") == ["Dana"])
    let one = ScryInvite(title: "T", invitees: [.init(name: "Dana Whitfield", email: nil)])
    let two = ScryInvite(title: "T", invitees: one.invitees + [.init(name: "Ellen Park", email: nil)])
    #expect(ScryNames.soleInvitee(one, onScreen: ["Dana Whitfield", "Sam Rivera"], userName: "Sam Rivera") == "Dana Whitfield")
    #expect(ScryNames.soleInvitee(one, onScreen: ["Dana Whitfield", "Uninvited Guest"], userName: "Sam Rivera") == nil)
    #expect(ScryNames.soleInvitee(one, onScreen: ["Dana"], userName: "You") == nil && ScryNames.soleInvitee(nil, onScreen: ["Dana"], userName: "You") == nil)
    #expect(ScryNames.soleInvitee(two, onScreen: ["Dana Whitfield"], userName: "You") == nil)            // the other may be speaking
    #expect(ScryNames.soleInvitee(two, onScreen: ["Dana Whitfield"], userName: "Ellen Park") == "Dana Whitfield")
}

@Test func liveOpenIsOffByDefaultAndRoundTrips() {
    var s = ScrySettings()
    #expect(!s.liveOpen)
    s.liveOpen = true
    #expect(ScrySettings.load(s.rows) == s)
}

@Test func yourSkillsJoinTheBuiltInOnes() {
    let all = ScryLiveChat.skills(custom: ["Seller recap: list the seller's worries", "email: my own email", "no prompt:", "not a skill", ": x"])
    #expect(all.prefix(2).map(\.id) == ["seller-recap", "email"] && all.count == ScryLiveChat.builtIn.count + 1 && all[0].group == "Yours")
    #expect(ScryLiveChat.expand("/seller-recap now", skills: all) == "list the seller's worries now")
    #expect(ScryLiveChat.expand("/email", skills: all) == "my own email" && ScryLiveChat.expand("/slack", skills: all).contains("Slack"))
    #expect(Set(ScryLiveChat.builtIn.map(\.group)).isSubset(of: ScryLiveChat.groups) && Set(ScryLiveChat.builtIn.map(\.id)).count == ScryLiveChat.builtIn.count)
    var s = ScrySettings(); s.skills = ["a: b", "c: d: e"]
    #expect(ScrySettings.load(s.rows) == s)
}

private let noteText = "---\ntitle: \"T\"\ndate: 2026-11-24\nstart: 2026-11-24T10:00:00Z\nend: 2026-11-24T10:05:00Z\nspeakers: {}\nsource: scry\n---\n\n# T\n\n## Summary\n\nAll good.\n\n---\n\n## Transcript\n\n**[00:01] You:** Hi.\n\n**[00:05] Dana:** Bye.\n"

@Test func aFolderIsOneFrontmatterLineAndRoundTrips() throws {
    let a = ScryNotes.foldered(noteText, "Sales \"A\"\nx")
    #expect(a == noteText.replacingOccurrences(of: "source: scry\n", with: "source: scry\nfolder: \"Sales \\\"A\\\" x\"\n"))
    let n = try #require(ScryNote.parse(a))
    #expect(n.meta.folder == "Sales \"A\" x" && ScryNote.parse(n.markdown())?.meta.folder == n.meta.folder)   // kept when the note is rewritten
    #expect(ScryNotes.foldered(ScryNotes.foldered(a, "B"), nil) == noteText && ScryNotes.foldered(a, " ") == noteText)
    #expect(ScryNotes.foldered("no frontmatter", "B") == "no frontmatter")
}

@Test func sharingLeavesOutTheFrontmatterAndTheTranscriptUnlessAsked() {
    #expect(ScryNotes.shared(noteText, transcript: false) == "# T\n\n## Summary\n\nAll good.\n\n---")
    #expect(ScryNotes.shared(noteText, transcript: true).hasSuffix("**[00:05] Dana:** Bye.") && !ScryNotes.shared(noteText, transcript: true).contains("source: scry"))
}

@Test func undoOnlyWritesOverWhatTheEditLeft() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "scry-undo-\(UUID().uuidString).md")
    defer { try? FileManager.default.removeItem(at: url) }
    try noteText.write(to: url, atomically: true, encoding: .utf8)
    let after = try #require(try ScryNotes.editLine(url, index: 1, old: .init(speaker: "Dana", start: 5, end: 300, text: "Bye."), speaker: "", text: nil)).markdown
    #expect(after != noteText && !after.contains("Dana"))
    _ = try ScryNotes.undo(url, before: noteText, after: after)
    #expect(try String(contentsOf: url, encoding: .utf8) == noteText)
    let edited = after + "\nmy own line\n"   // changed in Obsidian meanwhile
    try edited.write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: ScryNotes.Changed.self) { try ScryNotes.undo(url, before: noteText, after: after) }
    #expect(throws: ScryNotes.Changed.self) { try ScryNotes.editLine(url, index: 0, old: .init(speaker: "You", start: 1, end: 5, text: "Different."), speaker: "You", text: "x") }
    #expect(try String(contentsOf: url, encoding: .utf8) == edited)
}

@Test func capturesKeepTheirPausesAndOldOnesHaveNone() throws {
    let c = ScryCapture(audioFile: "a.wav", startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 60), app: nil, screenshotText: [], userNotes: "", pauses: [[10, 20.5]])
    #expect(try ScryCapture.decode(c.encoded()).pauses == [[10, 20.5]])
    let old = #"{"audioFile":"a.wav","startedAt":"2026-11-24T10:00:00Z","endedAt":"2026-11-24T10:01:00Z","screenshotText":[],"userNotes":""}"#
    #expect(try ScryCapture.decode(Data(old.utf8)).pauses == nil)
}

@Test func aCorrectedNameDropsTheOtherPersonsNote() {
    var t = ScryLiveTranscript()
    t.commit(far: true, "Hi there.", at: 2, others: [])
    let id = t.lines[0].id
    t.rename(id, to: "Dana Whitfield", everywhere: true, person: "/people/Dana Whitfield.md")
    t.rename(id, to: "Dana", everywhere: true)
    #expect(t.given.first?.person == "/people/Dana Whitfield.md")
    t.rename(id, to: "Ellen Park", everywhere: true)
    #expect(t.given.map(\.name) == ["Ellen Park"] && t.given.first?.person == nil)
    t.rename(id, to: "them", everywhere: true)
    #expect(t.given.isEmpty && t.lines[0].speaker == "Them")
}

@Test func anAddressKeepsItsFirstCharacter() {
    #expect(ScryLiveChat.addresses("!billing@example.com").isEmpty && ScryLiveChat.addresses("**billing@example.com**!") == ["billing@example.com"])
}

@Test func aColleagueWithYourFirstNameIsStillOnTheCall() {
    let segs = [ScrySegment(speaker: "Speaker A", start: 1, end: 2, text: "Hey.")]
    #expect(ScryNames.soleSpeaker(segs, names: ["Sam Rivera", "Sam Chen", "Alex Client"], userName: "Sam Rivera").isEmpty)
    #expect(ScryNames.soleSpeaker(segs, names: ["Sam Chen", "Alex Client"], userName: "Sam Rivera").isEmpty)
    #expect(ScryNames.soleSpeaker(segs, names: ["Sam Rivera", "Alex Client"], userName: "Sam Rivera") == ["Speaker A": "Alex Client"])
    #expect(ScryNames.soleSpeaker(segs, names: ["Sam Rivera", "Sam Chen", "Alex Client"], userName: "Sam").isEmpty)
    #expect(ScryNames.soleSpeaker(segs, names: ["Sam R."], userName: "Sam Rivera").isEmpty)
    #expect(ScryNames.soleSpeaker(segs, names: ["Sam Rivera", "Sam Chen"], userName: "Sam Rivera") == ["Speaker A": "Sam Chen"])
}

@Test func aCorrectionOverThemIsNotEcho() {
    for said in ["We can't ship Friday.", "We can ship Monday.", "We can not ship Friday."] {
        var t = ScryLiveTranscript()
        t.hear(far: true, "We can ship Friday", at: 2)
        t.hear(far: false, "We", at: 2.5)
        t.commit(far: true, "We can ship Friday.", at: 3)
        t.commit(far: false, said, at: 4)
        #expect(t.visible.count == 2, "\(said)")
    }
}

@Test func aLostNotIsACorrectionAndTwoPeopleOfOneNameAreNotLinked() {
    var t = ScryLiveTranscript()
    t.hear(far: true, "We can not send the forms Monday", at: 2); t.hear(far: false, "We", at: 2.5)
    t.commit(far: true, "We can not send the forms Monday.", at: 3)
    t.commit(far: false, "We can send the forms Monday.", at: 4)
    #expect(t.visible.count == 2)
    var two = ScryLiveTranscript()
    two.commit(far: true, "Hi there.", at: 2, others: [])
    two.rename(two.lines[0].id, to: "Sam Lee", everywhere: true, person: "/a/Sam Lee.md")
    two.hear(far: true, "Hello to you", at: 5, speaking: "Guest")
    two.commit(far: true, "Hello to you.", at: 6, speaking: "Guest", others: ["Guest", "Other"])
    let guest = two.lines.first { $0.speaker == "Guest" }
    if let guest { two.rename(guest.id, to: "Sam Lee", everywhere: true, person: "/b/Sam Lee.md") }
    #expect(guest != nil && two.given.count == 2 && two.given.allSatisfy { $0.person?.isEmpty != false })
}

@Test func aPickOnThemNamesOnlyThatLine() {
    var t = ScryLiveTranscript()
    for (i, w) in ["One here.", "Two there."].enumerated() { t.commit(far: true, w, at: 2 + Double(i) * 5, others: []) }
    t.rename(t.lines[0].id, to: "Alex Reed", everywhere: false, person: "/p/Alex Reed.md")
    t.commit(far: true, "Three now.", at: 20, others: [])
    #expect(t.lines.map(\.speaker) == ["Alex Reed", "Them", "Them"])
    #expect(t.given.map(\.name) == ["Alex Reed"] && t.given.first?.person == "/p/Alex Reed.md")
}
