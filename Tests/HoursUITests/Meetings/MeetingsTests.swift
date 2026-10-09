import Foundation
import SwiftUI
import Testing
import HoursCore
import ScryCore
@testable import HoursUI

/// Two fixture notes under a temp root: today's Zoom call (one action already ticked) and yesterday's
/// in-person meeting.
func meetingsFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "spells-meetings-tests/\(UUID().uuidString)")
    let tz = TimeZone.current
    func at(_ d: Int, _ h: Int, _ m: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }
    let zoom = ScryNote(
        meta: .init(startedAt: at(7, 10, 0), endedAt: at(7, 10, 35), app: "Zoom", participants: ["Alex Client", "Jordan Smith"],
                    speakers: ["Speaker A": "Alex Client"]),
        summary: ScrySummary(
            title: "Example Project pipeline sync",
            recap: [.init(title: "Portal switch", points: ["The data source moved to a new portal; the fetcher now uses it.",
                                                           "403s stopped after the switch."]),
                    .init(title: "Rollout", points: ["Ship to the dashboard Friday."])],
            decisions: ["Ship the Example Project fetcher Friday", "Keep the old portal as a fallback for a week"],
            keyDates: ["Fri 9 Oct: Example Project live on the dashboard"],
            actionItems: [.init(owner: "You", task: "Send Alex the source list", due: "Thursday"),
                          .init(owner: "Jordan Smith", task: "Check the fallback alerts"),
                          .init(owner: "Alex Client", task: "Tell the project team")],
            openQuestions: ["Do we backfill September?"],
            insights: ["Talk time: Alex 48 %, You 37 %, Speaker B 15 %"],
            speakers: ["Speaker A": "Alex Client"],
            followUpEmail: "Hi Alex,\n\nThanks for the sync. Example Project ships Friday; I'll send the source list Thursday.\n\nYou"),
        userNotes: "ask about the September backfill",
        segments: [ScrySegment(speaker: "Alex Client", start: 0, end: 6, text: "Example Project's portal moved again."),
                   ScrySegment(speaker: "You", start: 6, end: 12, text: "I switched the fetcher over this morning."),
                   ScrySegment(speaker: "Speaker B", start: 12, end: 18, text: "I'll keep an eye on the fallback alerts.")])
    let inPerson = ScryNote(
        meta: .init(startedAt: at(6, 14, 0), endedAt: at(6, 14, 50), app: nil, participants: ["Alex Client"], speakers: [:]),
        summary: ScrySummary(title: "Communications weekly", decisions: ["Pause the example mailer"],
                             actionItems: [.init(owner: "You", task: "Draft the Q4 communications plan")]),
        userNotes: "", segments: [ScrySegment(speaker: "You", start: 0, end: 4, text: "Let's start with Duval.")])
    for (n, tick) in [(zoom, true), (inPerson, false)] {
        let url = ScryNote.fileURL(root: root, startedAt: n.meta.startedAt, title: n.summary.title, timeZone: tz)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var md = n.markdown()
        if tick, let first = ScryActions.items(in: md).first { md = ScryActions.toggled(md, line: first.line) }
        try md.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
}

@MainActor
@Suite(.serialized) struct MeetingsTests {
    @Test func renameUpdatesSpeakerMapAndSegments() {
        let note = ScryNote(meta: .init(startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 60), app: nil,
                                        participants: [], speakers: ["Speaker A": "Alex"]),
                            summary: ScrySummary(title: "t"), userNotes: "",
                            segments: [.init(speaker: "Alex", start: 0, end: 1, text: "a"),
                                       .init(speaker: "Speaker B", start: 1, end: 2, text: "b"),
                                       .init(speaker: "You", start: 2, end: 3, text: "c")])
        let a = MeetingsData.renamed(note, from: "Alex", to: " Alex Client ")
        #expect(a.meta.speakers == ["Speaker A": "Alex Client"])
        #expect(a.segments.map(\.speaker) == ["Alex Client", "Speaker B", "You"])
        let b = MeetingsData.renamed(a, from: "Speaker B", to: "Jordan")
        #expect(b.meta.speakers == ["Speaker A": "Alex Client", "Speaker B": "Jordan"])
        #expect(b.segments.map(\.speaker) == ["Alex Client", "Jordan", "You"])
        #expect(MeetingsData.renamed(b, from: "You", to: "  ") == b)
    }

    @Test func loadGroupsOverlapsAndTogglesOnDisk() throws {
        let root = try meetingsFixtureRoot()
        let notes = MeetingsData.load(root)
        #expect(notes.map(\.note.summary.title) == ["Example Project pipeline sync", "Communications weekly"])
        #expect(notes.map(\.openCount) == [2, 1])
        #expect(MeetingsData.byDay(notes, timeZone: .current).map(\.notes.count) == [1, 1])
        let call = notes[0]
        #expect(MeetingsData.overlapping(notes, (call.startMs - 600_000)..<(call.startMs + 60_000)).map(\.url) == [call.url])
        #expect(MeetingsData.overlapping(notes, (call.endMs)..<(call.endMs + 60_000)).isEmpty)

        let item = try #require(call.actions.first { !$0.done })
        let fresh = try #require(try MeetingsData.toggle(call.url, line: item.line, owner: item.owner, task: item.task))
        #expect(fresh.openCount == 1)
        #expect(MeetingsData.load(root)[0].openCount == 1)

        let renamed = try #require(try MeetingsData.rename(call.url, from: "Speaker B", to: "Jordan Smith"))
        #expect(renamed.speakers == ["Alex Client", "You", "Jordan Smith"])
        #expect(renamed.openCount == 1)   // the rewrite keeps the ticks
        // A hand edit above the actions shifts every line: the toggle still flips the right item.
        let original = try String(contentsOf: call.url, encoding: .utf8)
        let title = try #require(original.range(of: "\n# "))
        let lineEnd = try #require(original[title.upperBound...].firstIndex(of: "\n"))
        let edited = String(original[...lineEnd]) + "Hand-added line\n" + original[original.index(after: lineEnd)...]
        try edited.write(to: call.url, atomically: true, encoding: .utf8)
        let open = try #require(ScryActions.items(in: edited).first { !$0.done })
        let afterEdit = try #require(try MeetingsData.toggle(call.url, line: open.line - 1, owner: open.owner, task: open.task))
        #expect(afterEdit.openCount == 0 && afterEdit.markdown.contains("\nHand-added line\n"))
    }

    @Test func renameIsTextOnly() {
        let md = "---\nspeakers: {\"Speaker A\":\"Alex\"}\n---\n\nKeep **Speaker B** prose.\n\n## Action items\n\n- [ ] **Speaker B**: ship it\n\n## Transcript\n\n**[00:01] Speaker B:** hi\n**[00:02] Alex:** yo\n"
        let out = MeetingsData.renamedText(md, from: "Speaker B", to: "Jordan")
        #expect(out.contains("speakers: {\"Speaker A\":\"Alex\",\"Speaker B\":\"Jordan\"}"))
        #expect(out.contains("- [ ] **Jordan**: ship it") && out.contains("**[00:01] Jordan:** hi"))
        #expect(out.contains("Keep **Speaker B** prose.") && out.contains("**[00:02] Alex:** yo"))
    }

    /// `$TMPDIR/spells-meetings-{light,dark}.png`: the Meetings view over the two fixture notes.
    @Test(arguments: [ColorScheme.light, .dark])
    func renderMeetings(scheme: ColorScheme) throws {
        let root = try meetingsFixtureRoot()
        let view = MeetingsView(root: root, selection: .constant(nil), notes: MeetingsData.load(root))
        let name = "spells-meetings-\(scheme == .dark ? "dark" : "light")"
        let (url, rep) = try RangeRender.write(view, size: CGSize(width: 1280, height: 860), scheme: scheme, name: name)
        #expect(rep.size == CGSize(width: 1280, height: 860))
        print("MeetingsView (\(scheme)): \(url.path)")
    }

    @Test func renderEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "spells-meetings-tests/\(UUID().uuidString)")
        let (url, _) = try RangeRender.write(MeetingsView(root: root, selection: .constant(nil), notes: []),
                                             size: CGSize(width: 1000, height: 600), scheme: .light, name: "spells-meetings-empty")
        print("MeetingsView (empty): \(url.path)")
    }
}
