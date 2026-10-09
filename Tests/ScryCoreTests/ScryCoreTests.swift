import Foundation
import Testing
@testable import ScryCore

// MARK: - Call apps + detection

@Test func callAppOwner() {
    #expect(ScryCallApps.owner(ofBundleID: "us.zoom.xos") == "us.zoom.xos")
    #expect(ScryCallApps.owner(ofBundleID: "com.google.Chrome.helper") == "com.google.Chrome")
    #expect(ScryCallApps.owner(ofBundleID: "com.google.Chrome.helper.Renderer") == "com.google.Chrome")
    #expect(ScryCallApps.owner(ofBundleID: "com.microsoft.teams2.helper") == "com.microsoft.teams2")
    #expect(ScryCallApps.owner(ofBundleID: "us.zoom.CptHost") == nil)
    #expect(ScryCallApps.owner(ofBundleID: "com.apple.Music") == nil)
}

private let zoom = "us.zoom.xos"

private func run(_ d: inout ScryDetector, _ steps: [(String?, ScryRecording, Int64)]) -> [ScryDetectAction] {
    steps.map { d.update(callApp: $0.0, recording: $0.1, atMs: $0.2) }
}

@Test func offersOnceAfterSustainThenTimesOut() {
    var d = ScryDetector(timing: .init(offerMs: 10_000))
    #expect(run(&d, [(zoom, .none, 0), (zoom, .none, 2_999), (zoom, .none, 3_000), (zoom, .none, 4_000),
                     (zoom, .none, 13_000), (zoom, .none, 20_000), (zoom, .none, 200_000)])
            == [.none, .none, .offer(zoom), .none, .withdraw, .none, .none])
}

@Test func neverListedAppsAreNotOffered() {
    var d = ScryDetector(never: [zoom])
    #expect(run(&d, [(zoom, .none, 0), (zoom, .none, 5_000)]) == [.none, .none])
}

@Test func releaseWhileOfferedWithdraws() {
    var d = ScryDetector()
    #expect(run(&d, [(zoom, .none, 0), (zoom, .none, 3_000), (nil, .none, 4_000)]) == [.none, .offer(zoom), .withdraw])
}

@Test func recordingCallStopsOnceAfterIdle() {
    var d = ScryDetector(timing: .init(idleStopMs: 60_000))
    #expect(run(&d, [(zoom, .call(zoom), 0), (nil, .call(zoom), 1_000), (zoom, .call(zoom), 30_000), // back: resets
                     (nil, .call(zoom), 31_000), (nil, .call(zoom), 90_999), (nil, .call(zoom), 91_000),
                     (nil, .call(zoom), 92_000)])
            == [.none, .none, .none, .none, .none, .stop, .none])
}

@Test func inPersonNeverStops() {
    var d = ScryDetector()
    #expect(run(&d, [(nil, .inPerson, 0), (nil, .inPerson, 61_000), (nil, .inPerson, 1_000_000)]) == [.none, .none, .none])
}

@Test func newCallAfterIdleGapOffersAgain() {
    var d = ScryDetector(timing: .init(idleStopMs: 60_000))
    #expect(run(&d, [(zoom, .none, 0), (zoom, .none, 3_000), (nil, .none, 4_000),
                     (zoom, .none, 10_000), (zoom, .none, 14_000), (nil, .none, 20_000), // same call: no re-offer
                     (zoom, .none, 80_000), (zoom, .none, 83_000)])
            == [.none, .offer(zoom), .withdraw, .none, .none, .none, .none, .offer(zoom)])
}

// MARK: - Settings + capture

@Test func settingsRoundTripAndDefaults() {
    var s = ScrySettings()
    s.autoOffer = false; s.autoRecord = true; s.root = "/tmp/Notes"; s.never = ["us.zoom.xos", "com.apple.FaceTime"]; s.userName = "Test User"
    #expect(ScrySettings.load(s.rows) == s)
    #expect(ScrySettings.load([:]) == ScrySettings())
    #expect(ScrySettings.load([ScrySettings.rootKey: "  ", ScrySettings.liveKey: "", ScrySettings.neverKey: "\n"]) == ScrySettings())
    let url = ScrySettings().rootURL
    #expect(url.path.hasPrefix(NSHomeDirectory()) && url.path.hasSuffix("/Documents/Scry") && !url.path.contains("~"))
}

@Test func captureRoundTripAndISODates() throws {
    let c = ScryCapture(audioFile: "audio.wav", startedAt: Date(timeIntervalSince1970: 1_791_467_964),
                        endedAt: Date(timeIntervalSince1970: 1_791_468_000), app: nil,
                        screenshotText: [["Alex Client", "Mute"]], userNotes: "notes")
    #expect(try ScryCapture.decode(c.encoded()) == c)
    let json = """
    {"audioFile": "audio.wav", "startedAt": "2026-10-08T13:59:24.760750Z", "endedAt": "2026-10-08T14:00:00Z",
     "app": "us.zoom.xos", "screenshotText": [], "userNotes": ""}
    """
    let d = try ScryCapture.decode(Data(json.utf8))
    #expect(abs(d.startedAt.timeIntervalSince1970 - 1_791_467_964.76075) < 0.001)
    #expect(d.endedAt.timeIntervalSince1970 == 1_791_468_000 && d.app == "us.zoom.xos")
}

// MARK: - Transcript

@Test func multichannelSegments() throws {
    func w(_ text: String, _ start: Double, _ end: Double, ch: Int, spk: String, type: String = "word") -> String {
        #"{"text":"\#(text)","start":\#(start),"end":\#(end),"type":"\#(type)","speaker_id":"\#(spk)","channel_index":\#(ch)}"#
    }
    let words = [
        w("Hey", 0, 0.3, ch: 1, spk: "speaker_0"), w(" ", 0.3, 0.35, ch: 1, spk: "speaker_0", type: "spacing"),
        w("Sam.", 0.35, 0.7, ch: 1, spk: "speaker_0"), w("(laughs)", 0.8, 1.2, ch: 1, spk: "speaker_0", type: "audio_event"),
        w("Hi", 1.5, 1.8, ch: 0, spk: "speaker_0"), w("all.", 1.9, 2.2, ch: 0, spk: "speaker_0"),
        w("Morning.", 2.5, 3.0, ch: 1, spk: "speaker_1"),
        w("Hello", 3.1, 3.5, ch: 1, spk: "speaker_0"), w("again.", 5.1, 5.5, ch: 1, spk: "speaker_0"), // 1.6 s gap
    ]
    let segs = try ScryTranscript.segments(fromScribeJSON: Data(#"{"words":[\#(words.joined(separator: ","))]}"#.utf8))
    #expect(segs == [
        ScrySegment(speaker: "Speaker A", start: 0, end: 0.7, text: "Hey Sam."),
        ScrySegment(speaker: "You", start: 1.5, end: 2.2, text: "Hi all."),
        ScrySegment(speaker: "Speaker B", start: 2.5, end: 3.0, text: "Morning."),
        ScrySegment(speaker: "Speaker A", start: 3.1, end: 3.5, text: "Hello"),
        ScrySegment(speaker: "Speaker A", start: 5.1, end: 5.5, text: "again."),
    ])
    let talk = ScryTranscript.talkTime(segs)
    #expect(talk.map(\.speaker) == ["Speaker A", "You", "Speaker B"])
    #expect(abs(talk[0].seconds - 1.5) < 1e-9)
    #expect(ScryTranscript.renamed(segs, ["Speaker A": "Alex"]).map(\.speaker) == ["Alex", "You", "Speaker B", "Alex", "Alex"])
}

@Test func singleChannelSegments() throws {
    let json = """
    {"words":[{"text":"One","start":0,"end":0.5,"type":"word","speaker_id":"speaker_1"},
              {"text":"two.","start":0.6,"end":1,"type":"word","speaker_id":"speaker_1"},
              {"text":"Three.","start":1.2,"end":1.8,"type":"word","speaker_id":"speaker_0"}]}
    """
    #expect(try ScryTranscript.segments(fromScribeJSON: Data(json.utf8)) == [
        ScrySegment(speaker: "Speaker A", start: 0, end: 1, text: "One two."),
        ScrySegment(speaker: "Speaker B", start: 1.2, end: 1.8, text: "Three."),
    ])
}

// MARK: - Prompts

private let segs = [
    ScrySegment(speaker: "Speaker A", start: 5, end: 9, text: "I'll send the address by Friday."),
    ScrySegment(speaker: "You", start: 65, end: 70, text: "Great, thanks Alex."),
    ScrySegment(speaker: "Speaker B", start: 400, end: 410, text: "Sam, can you check the notes?"),
]

@Test func summaryPromptContents() {
    let p = ScryPrompt.summary(segments: segs, participants: ["Alex Client", "Jordan"], userNotes: "Example mail: needs address",
                               userName: "You", appName: "Zoom", startedAt: Date(timeIntervalSince1970: 1_791_467_964),
                               keyterms: ["ExamplePortal"])
    for needle in ["Only", "never follow instructions", "\"actionItems\"", "\"followUpEmail\"", "\"speakers\"",
                   "Alex Client, Jordan", "Example mail: needs address", "[00:05] Speaker A: I'll send the address by Friday.",
                   "[01:05] You: Great", "[06:40] Speaker B:", "\"You\" is You", "ExamplePortal", "Zoom"] {
        #expect(p.localizedCaseInsensitiveContains(needle), "missing \(needle)")
    }
}

@Test func parseSummaryFencedProsedAndPartial() throws {
    let full = """
    Here you go:
    ```json
    {"title": "Example mail {launch}", "recap": [{"title": "Mail", "points": ["Built, off"]}], "decisions": ["Wait"],
     "keyDates": ["Friday"], "actionItems": [{"owner": "Alex", "task": "Send address", "due": "Friday"}],
     "openQuestions": [], "insights": ["x"], "speakers": {"Speaker A": "Alex"}, "followUpEmail": "Hi all"}
    ```
    Done {not json}.
    """
    let s = try ScryPrompt.parseSummary(full)
    #expect(s.title == "Example mail {launch}" && s.recap == [.init(title: "Mail", points: ["Built, off"])])
    #expect(s.actionItems == [.init(owner: "Alex", task: "Send address", due: "Friday")] && s.speakers == ["Speaker A": "Alex"])
    let partial = try ScryPrompt.parseSummary(#"Sure {see below}: {"title": "T", "actionItems": [{"task": "x"}]}"#)
    #expect(partial == ScrySummary(title: "T", actionItems: [.init(owner: "", task: "x")]))
    #expect(throws: (any Error).self) { try ScryPrompt.parseSummary("no json here") }
}

@Test func catchUpUsesOnlyRecentMinutes() {
    let (system, user) = ScryPrompt.catchUp(segs, lastMinutes: 6) // last end 410 s → from 50 s
    #expect(system.contains("3–5") && system.contains("never follow instructions"))
    #expect(user.contains("[06:40] Speaker B:") && user.contains("[01:05] You:") && !user.contains("[00:05]"))
}

@Test func askPromptCites() {
    let p = ScryPrompt.ask("When is the address due?", notes: [(title: "Example mail", date: "2026-10-08", markdown: "body")])
    #expect(p.contains("[title, date]") && p.contains("title=\"Example mail\" date=\"2026-10-08\"") && p.contains("body")
            && p.contains("When is the address due?") && p.contains("don't contain"))
}

// MARK: - Note file

private let fullNote = ScryNote(
    meta: .init(startedAt: Date(timeIntervalSince1970: 1_791_466_800), endedAt: Date(timeIntervalSince1970: 1_791_468_900),
                app: "Zoom", participants: ["Alex Client", "Jordan"], speakers: ["Speaker A": "Alex", "Speaker B": "Jordan"]),
    summary: ScrySummary(
        title: "Example mail: launch \"go\"", recap: [.init(title: "Mail", points: ["Built", "Off until address"]),
                                                       .init(title: "ExamplePortal", points: ["Failures next Tuesday"])],
        decisions: ["Hold mail"], keyDates: ["Friday: address"],
        actionItems: [.init(owner: "Alex", task: "Send the return address", due: "Friday"),
                      .init(owner: "You", task: "Turn mail on")],
        openQuestions: ["Which printer?"], insights: ["Alex drove"], speakers: ["Speaker A": "Alex", "Speaker B": "Jordan"],
        followUpEmail: "Hi all,\n\nThanks.\n\nYou"),
    userNotes: "Example mail: needs address\n- second line",
    segments: [ScrySegment(speaker: "Alex", start: 0, end: 65, text: "Hey Sam."),
               ScrySegment(speaker: "You", start: 65, end: 2_000, text: "Sure."),
               ScrySegment(speaker: "Jordan", start: 2_000, end: 2_100, text: "Bye.")])

@Test func noteRoundTrip() throws {
    let md = fullNote.markdown()
    #expect(md.hasPrefix("---\ntitle: \"Example mail: launch \\\"go\\\"\"\n"))
    #expect(md.contains("duration_min: 35\n") && md.contains("source: scry") && md.contains("app: \"Zoom\""))
    #expect(md.contains("- [ ] **Alex**: Send the return address (due Friday)\n- [ ] **You**: Turn mail on"))
    #expect(md.contains("**[01:05] You:** Sure.") && md.contains("- Talk time: You 32:15"))
    #expect(ScryNote.parse(md) == fullNote)
    #expect(ScryNote.parse("# Just a heading\n") == nil)
}

@Test func emptySectionsOmitted() {
    let n = ScryNote(meta: .init(startedAt: .now, endedAt: .now, app: nil, participants: [], speakers: [:]),
                     summary: ScrySummary(title: "Quick sync", decisions: ["Ship"]), userNotes: " ", segments: [])
    let md = n.markdown()
    #expect(md.contains("## Decisions") && !md.contains("app:"))
    for h in ["## Summary", "## Key dates", "## Action items", "## Open questions", "## Insights", "## Your notes",
              "## Follow-up email", "## Transcript"] {
        #expect(!md.contains(h), "\(h) should be omitted")
    }
}

@Test func noteFileURL() {
    let url = ScryNote.fileURL(root: URL(filePath: "/tmp/Scry"), startedAt: Date(timeIntervalSince1970: 1_791_493_500), // 21:05Z
                               title: "Example Mail Launch & Café Review: Next Steps!",
                               timeZone: TimeZone(identifier: "America/Los_Angeles")!)
    #expect(url.path == "/tmp/Scry/2026/10/2026-10-08-1405-example-mail-launch-cafe-review-next.md")
    #expect(ScryNote.fileURL(root: URL(filePath: "/tmp/Scry"), startedAt: Date(timeIntervalSince1970: 1_791_493_500), title: "!!",
                             timeZone: TimeZone(identifier: "UTC")!).lastPathComponent == "2026-10-08-2105-meeting.md")
}

// MARK: - Names, actions, search

@Test func namesFromOCR() {
    let names = ScryNames.fromOCR([
        ["Alex Client", "Mute", "Stop Video", "Jordan", "Example User (Host)", "Share Screen", "Participants", "12:04",
         "https://zoom.us/j/123", "meet.google.com", "Meeting details", "TT"],
        ["Alex Client", "Jordan", "Recording", "Leave"],
    ])
    #expect(names == ["Alex Client", "Jordan", "Example User"])
}

@Test func actionItemsAndToggle() {
    let md = """
    # T

    ## Decisions

    - [ ] not an action

    ## Action items

    - [ ] **Alex**: Send address (due Friday)
    - [x] **You**: Turn mail on
    - [ ] loose task

    ## Open questions
    """
    #expect(ScryActions.items(in: md) == [
        .init(line: 8, owner: "Alex", task: "Send address (due Friday)", done: false),
        .init(line: 9, owner: "You", task: "Turn mail on", done: true),
        .init(line: 10, owner: "", task: "loose task", done: false),
    ])
    let flipped = ScryActions.toggled(md, line: 8)
    let before = md.components(separatedBy: "\n"), after = flipped.components(separatedBy: "\n")
    #expect(after[8] == "- [x] **Alex**: Send address (due Friday)")
    #expect(before.indices.filter { before[$0] != after[$0] } == [8])
    #expect(ScryActions.toggled(flipped, line: 8) == md)
    #expect(ScryActions.toggled(md, line: 0) == md)
}

@Test func searchRanking() {
    let day: TimeInterval = 86_400, now = Date(timeIntervalSince1970: 1_791_467_964)
    let notes: [(id: String, title: String, text: String, date: Date)] = [
        ("old-mail", "Weekly sync", "We talked about the Example mail launch.", now - 9 * day),
        ("new-mail", "Weekly sync", "Example mail launch is blocked on the address.", now - day),
        ("titled", "Example mail launch", "Short.", now - 20 * day),
        ("other", "Hiring", "Interview loop for the designer.", now),
    ]
    #expect(ScrySearch.rank("What did we decide about the Example mail launch?", notes: notes)
            == ["titled", "new-mail", "old-mail", "other"])
    #expect(ScrySearch.rank("designer interview", notes: notes, limit: 1) == ["other"])
}

@Suite struct ScryReviewFixTests {
    @Test func parseSummaryNeverTakesANestedObject() {
        // The outer object fails to decode (a number where a string goes); a recap topic must not pass for it.
        let bad = #"{"title": 5, "recap": [{"title": "Portal", "points": ["x"]}], "actionItems": []}"#
        #expect(throws: (any Error).self) { try ScryPrompt.parseSummary(bad) }
        // A null speaker mapping is just unmapped, not a failure.
        let ok = try? ScryPrompt.parseSummary(#"Here: {"title": "T", "speakers": {"Speaker A": null, "Speaker B": "Pat"}}"#)
        #expect(ok?.title == "T" && ok?.speakers == ["Speaker B": "Pat"])
    }

    @Test func ownerMatchesCaseInsensitivelyAndSafariViaWebKit() {
        #expect(ScryCallApps.owner(ofBundleID: "company.thebrowser.browser.helper") == "company.thebrowser.Browser")
        #expect(ScryCallApps.owner(ofBundleID: "com.apple.WebKit.GPU", running: ["com.apple.Safari"]) == "com.apple.Safari")
        #expect(ScryCallApps.owner(ofBundleID: "com.apple.WebKit.GPU", running: []) == nil)
    }

    @Test func relativeRootFallsBackToTheDefault() {
        var s = ScrySettings(); s.root = "Notes"
        #expect(s.rootURL.path.hasSuffix("/Documents/Scry"))
        s.root = "/tmp/x"
        #expect(s.rootURL.path == "/tmp/x")
    }

    @Test func parseSurvivesHandEditedTimestamps() {
        let md = "---\ntitle: \"T\"\ndate: 2026-10-08\nstart: 2026-10-08T10:00:00-07:00\nend: 2026-10-08T10:30:00-07:00\n---\n\n# T\n\n## Transcript\n\n**[99999999999999999999:00] You:** hi\n**[01:05] You:** ok\n"
        #expect(ScryNote.parse(md)?.segments.count == 1)
    }
}

@Test func defaultStopIs5sWithACountdown() {
    var d = ScryDetector()
    #expect(d.timing.idleStopMs == 5_000)
    _ = d.update(callApp: "us.zoom.xos", recording: .call("us.zoom.xos"), atMs: 0)
    #expect(d.stopsIn(atMs: 0) == nil)                          // still on the mic
    _ = d.update(callApp: nil, recording: .call("us.zoom.xos"), atMs: 1_000)
    #expect(d.stopsIn(atMs: 4_000) == 2_000)                    // let go at 1 s → 2 s left at 4 s
    #expect(d.update(callApp: nil, recording: .call("us.zoom.xos"), atMs: 6_000) == .stop)
    #expect(d.stopsIn(atMs: 6_000) == nil)
}

@Test func pillLabelShowsWhoIsWithYou() {
    let names = ["Alex Client", "Jordan", "Example User", "Morgan Lee"]
    let l = ScryNames.pillLabel(names, userName: "Example", fallback: "Chrome")
    #expect(l.short == "Alex, Jordan +1" && l.full == "Alex Client, Jordan, Morgan Lee")
    #expect(ScryNames.pillLabel(["Example User"], userName: "Example", fallback: "Chrome").short == "Chrome")
    #expect(ScryNames.pillLabel([], userName: "Example", fallback: "In person").short == "In person")
}

@Test func invitePicksTheLinkedEventRunningNow() {
    let now = Date(timeIntervalSince1970: 1_791_468_000)
    let t = ScryInvite.Invitee(name: "Alex Client", email: "t@x.com")
    func ev(_ title: String, _ startMin: Double, _ text: String, _ who: [ScryInvite.Invitee] = [t]) -> ScryInvite.Candidate {
        .init(title: title, start: now.addingTimeInterval(startMin * 60), end: now.addingTimeInterval((startMin + 30) * 60), text: text, invitees: who)
    }
    let events = [ev("Lunch", -2, ""), ev("Example sync", -10, "https://meet.google.com/abc-defg-hij"),
                  ev("Zoom 1:1", -1, "https://zoom.us/j/1"), ev("Solo focus", 0, "https://meet.google.com/x", []),
                  ev("Tomorrow", 1440, "https://meet.google.com/y")]
    #expect(ScryInvite.pick(events, app: "com.google.Chrome", now: now)?.title == "Zoom 1:1")   // browser: any link, closest start
    #expect(ScryInvite.pick(events, app: "us.zoom.xos", now: now)?.title == "Zoom 1:1")
    #expect(ScryInvite.pick(Array(events.prefix(2)), app: "com.google.Chrome", now: now)?.title == "Example sync")  // link beats closer
    #expect(ScryInvite.pick([events[0]], app: nil, now: now)?.title == "Lunch")
    #expect(ScryInvite.pick([events[3], events[4]], app: nil, now: now) == nil)
}

@Test func screenNamesCompletedFromInvite() {
    let i = ScryInvite(title: "Example sync", invitees: [.init(name: "Alex Client", email: nil), .init(name: "Jordan Lee", email: nil),
                                                    .init(name: "Jordan Moss", email: nil)])
    #expect(ScryNames.completed(["Alex", "Jordan", "Morgan Lee", "alex"], i) == ["Alex Client", "Jordan", "Morgan Lee"])
    let p = ScryPrompt.summary(segments: [], participants: [], userNotes: "", userName: "You", appName: nil,
                               startedAt: Date(), keyterms: [], invite: .init(title: "Example sync", invitees: [.init(name: "Alex Client", email: "t@x.com")]))
    #expect(p.contains("\"Example sync\" — invited: Alex Client <t@x.com>"))
}
