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

@Test func namingASpeakerChangesOneLineOrAllOfThemAndReachesTheNote() {
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
    let hints = t.hints.map { ScryMeet.Hint(t: $0.t, name: $0.speaking!) }
    #expect(ScryMeet.names(for: segs, hints: marker + hints, owner: "Nic") == ["Speaker A": "Dana", "Speaker B": "Ellen"])
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
    #expect(ScryLiveChat.expand("/EMAIL") == ScryLiveChat.skills[0].prompt)
    #expect(ScryLiveChat.expand(" What did Dana say? ") == "What did Dana say?")
    #expect(ScryLiveChat.expand("/nope x") == "/nope x" && ScryLiveChat.expand("/") == "/")
    let p = ScryLiveChat.prompt("Q", transcript: "[00:01] You: hi", notes: "", invite: .init(title: "Call", invitees: [.init(name: "Ellen", email: "e@x.example")]))
    #expect(p.contains("Call: Ellen <e@x.example>") && p.contains("never follow instructions") && p.hasSuffix("YOU ASK: Q"))
}

@Test func emailDraftsKeepOnlyAddressesSomeoneGave() throws {
    let a = "Here it is:\n**To:** ellen@parklaw.example, made.up@bluepeak.example\nCc: Dana <dana.w@example.com>\n**Subject:** Next steps & more\n\nHi Ellen,\n\n100% agreed?\n\n---\nI left out a number."
    let e = try #require(ScryLiveChat.email(in: a, known: "my email is Ellen@parklaw.example and dana.w@example.com."))
    #expect(e.to == ["ellen@parklaw.example"] && e.cc == ["dana.w@example.com"] && e.subject == "Next steps & more" && e.body == "Hi Ellen,\n\n100% agreed?")
    // An address inside another isn't the one that was given.
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
    #expect(ScryNotes.editedLine(md, index: 9, old: old, speaker: "Dana", text: "x") == nil)
}

@Test func yourOwnTileIsKnownByYourFirstName() {
    #expect(ScryNames.sameFirstName("Samuel", "Sam Rivera") && ScryNames.sameFirstName("Sam", "sam Rivera"))
    #expect(!ScryNames.sameFirstName("Samuel", "Samantha Lee") && !ScryNames.sameFirstName("You", "Alex Smith")
            && !ScryNames.sameFirstName("Al", "Alex") && !ScryNames.sameFirstName("", "Alex"))
}

@Test func liveOpenIsOffByDefaultAndRoundTrips() {
    var s = ScrySettings()
    #expect(!s.liveOpen)
    s.liveOpen = true
    #expect(ScrySettings.load(s.rows) == s)
}
