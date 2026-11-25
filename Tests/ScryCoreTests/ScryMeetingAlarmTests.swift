import Foundation
import Testing
import ScryCore

private let t0 = Date(timeIntervalSince1970: 1_795_500_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private let meeting = ScryMeeting(title: "Check-in", start: t0, end: t0.addingTimeInterval(900))

@Test func alarmRingsFromTheStartUntilDismissed() {
    var a = ScryMeetingAlarm()
    #expect(a.due([meeting], call: nil, at: at(-1)) == nil)
    #expect(a.due([meeting], call: nil, at: at(0)) == meeting)
    #expect(a.due([meeting], call: nil, at: at(599)) == meeting)
    #expect(a.due([meeting], call: nil, at: at(600)) == nil)   // too late to help
    a.handle(meeting)
    #expect(a.due([meeting], call: nil, at: at(60)) == nil)
    var moved = meeting; moved.start = at(120)
    #expect(a.due([moved], call: nil, at: at(120)) == moved)   // rescheduled: rings again
}

@Test func headsUpShowsTheLastMinuteAndLeavesTheAlarmAlone() {
    var a = ScryMeetingAlarm()
    #expect(a.soon([meeting], at: at(-61)) == nil)
    #expect(a.soon([meeting], at: at(-60)) == meeting)
    #expect(a.soon([meeting], at: at(0)) == nil)   // now it's the alarm's
    a.notice(meeting)
    #expect(a.soon([meeting], at: at(-30)) == nil)
    #expect(a.due([meeting], call: nil, at: at(0)) == meeting)
    var joined = ScryMeetingAlarm()
    _ = joined.due([meeting], call: "zoom", at: at(-40))
    #expect(joined.soon([meeting], at: at(-40)) == nil)
    var over = ScryMeetingAlarm()   // another call runs over
    for s in stride(from: -1800.0, through: -50, by: 1) { _ = over.due([meeting], call: "zoom", at: at(s)) }
    #expect(over.soon([meeting], at: at(-50)) == meeting)
}

@Test func joiningTakesTheAlarmDownAndLeavingDoesNotBringItBack() {
    var a = ScryMeetingAlarm()
    #expect(a.due([meeting], call: nil, at: at(5)) == meeting)
    #expect(a.due([meeting], call: "zoom", at: at(20)) == nil)
    #expect(a.due([meeting], call: nil, at: at(200)) == nil)
    var early = ScryMeetingAlarm()   // joined 2 min early, left 1 min in
    for s in stride(from: -120.0, through: 60, by: 1) { #expect(early.due([meeting], call: "zoom", at: at(s)) == nil) }
    #expect(early.due([meeting], call: nil, at: at(120)) == nil)
}

@Test func aCallRunningOverRingsForTheNextMeetingOnceItEnds() {
    var a = ScryMeetingAlarm()
    for s in stride(from: -1800.0, through: 180, by: 1) where s != -60 {   // one missed poll is the same call
        #expect(a.due([meeting], call: "zoom", at: at(s)) == nil)
    }
    #expect(a.due([meeting], call: nil, at: at(183)) == nil)   // a mute, not the end
    #expect(a.due([meeting], call: nil, at: at(186)) == meeting)
}

@Test func switchingToAnotherCallAppCountsAsJoining() {
    var a = ScryMeetingAlarm()
    for s in stride(from: -1800.0, through: 60, by: 1) { _ = a.due([meeting], call: "zoom", at: at(s)) }
    #expect(a.due([meeting], call: "chrome", at: at(61)) == nil)
    #expect(a.due([meeting], call: nil, at: at(120)) == nil)
}

@Test func callLinksOnlyOnKnownHosts() {
    #expect(ScryMeeting.callLink(in: "Join: https://meet.google.com/abc-defg-hij now")?.host() == "meet.google.com")
    #expect(ScryMeeting.callLink(in: "https://us02web.zoom.us/j/123")?.host() == "us02web.zoom.us")
    #expect(ScryMeeting.callLink(in: "https://evilzoom.us/j/1 https://zoom.us.evil.com/x http://zoom.us/j/1 notes") == nil)
}

@Test func remindersRoundTripAndABadFileThrows() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "scry-rem-\(UUID().uuidString)/r.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(try ScryMeeting.load(url).isEmpty)
    let m = ScryMeeting(title: "Dentist", start: t0, end: at(3600), link: URL(string: "https://meet.google.com/x"))
    try ScryMeeting.save([m], to: url)
    #expect(try ScryMeeting.load(url) == [m])
    try Data("nope".utf8).write(to: url)
    #expect(throws: (any Error).self) { try ScryMeeting.load(url) }
}

@Test func googleEventsBecomeMeetings() throws {
    let json = """
    {"summary": "me@example.com", "items": [
     {"status": "confirmed", "summary": "Check-in", "start": {"dateTime": "2026-11-24T10:45:00-07:00"}, "end": {"dateTime": "2026-11-24T11:00:00-07:00"},
      "attendees": [{"email": "me@example.com", "self": true, "responseStatus": "accepted"}, {"email": "a@example.com", "displayName": "Alex Client"}, {"email": "pat.lee@example.com"}, {"email": "x1@example.com"},
                    {"email": "room@resource.calendar.google.com", "resource": true}],
      "organizer": {"email": "a@example.com"},
      "conferenceData": {"entryPoints": [{"entryPointType": "phone", "uri": "tel:+1"}, {"entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"}]}},
     {"status": "confirmed", "summary": "Focus", "start": {"dateTime": "2026-11-24T12:45:00Z"}, "end": {"dateTime": "2026-11-24T13:00:00Z"},
      "organizer": {"email": "me@example.com", "self": true}, "description": "<a href=\\"https://x.slack.com/archives/1\\">notes</a> https://meet.google.com/abc-defg-hij"},
     {"status": "confirmed", "summary": "Team block", "start": {"dateTime": "2026-11-24T12:45:00Z"}, "end": {"dateTime": "2026-11-24T13:00:00Z"},
      "organizer": {"email": "c_1@group.calendar.google.com", "displayName": "Team Calendar"}},
     {"status": "confirmed", "summary": "Declined", "start": {"dateTime": "2026-11-24T12:00:00Z"}, "end": {"dateTime": "2026-11-24T13:00:00Z"},
      "attendees": [{"email": "me@example.com", "self": true, "responseStatus": "declined"}, {"email": "a@example.com"}]},
     {"status": "cancelled", "summary": "Off", "start": {"dateTime": "2026-11-24T12:00:00Z"}, "end": {"dateTime": "2026-11-24T13:00:00Z"}, "attendees": [{"email": "a@example.com"}]},
     {"status": "confirmed", "summary": "Pay Day", "start": {"date": "2026-11-27"}, "end": {"date": "2026-11-28"}, "attendees": [{"email": "a@example.com"}]}]}
    """
    let (account, events) = try ScryCalendarEvent.google(Data(json.utf8))
    #expect(account == "me@example.com" && events.count == 5)   // the all-day one isn't timed
    let meetings = events.compactMap(\.meeting)
    #expect(meetings.map(\.title) == ["Check-in"])
    #expect(meetings.first?.link?.absoluteString == "https://meet.google.com/abc-defg-hij")
    #expect(meetings.first?.start == ISO8601DateFormatter().date(from: "2026-11-24T17:45:00Z"))
    #expect(events[0].candidate.invitees == [.init(name: "Alex Client", email: "a@example.com"), .init(name: "Pat Lee", email: "pat.lee@example.com"),
                                                .init(name: "x1@example.com", email: "x1@example.com")])
    #expect(throws: (any Error).self) { try ScryCalendarEvent.google(Data("<html>".utf8)) }
}

@Test func googleSignInUsesPKCEAndChecksItsState() throws {
    let id = "123-abc.apps.googleusercontent.com"
    #expect(ScryGoogleAuth.redirect(id) == "com.googleusercontent.apps.123-abc:/oauth2redirect")
    #expect(ScryGoogleAuth.scheme("") == nil && ScryGoogleAuth.scheme("x.apps.googleusercontent.com.evil.com") == nil && ScryGoogleAuth.scheme("a b.apps.googleusercontent.com") == nil)
    let url = try #require(ScryGoogleAuth.authURL(clientID: id, challenge: "ch", state: "s1")?.absoluteString)
    #expect(url.hasPrefix("https://accounts.google.com/") && url.contains("code_challenge=ch") && url.contains("code_challenge_method=S256")
            && url.contains("calendar.events.readonly") && url.contains("access_type=offline"))
    let back = "com.googleusercontent.apps.123-abc:/oauth2redirect?"
    #expect(ScryGoogleAuth.code(in: URL(string: back + "state=s1&code=4/0Ab&scope=x")!, state: "s1") == "4/0Ab")
    #expect(ScryGoogleAuth.code(in: URL(string: back + "state=other&code=4/0Ab")!, state: "s1") == nil)
    #expect(ScryGoogleAuth.code(in: URL(string: back + "state=s1&error=access_denied")!, state: "s1") == nil)
    #expect(String(decoding: ScryGoogleAuth.form(["code": "4/0+a b&c", "a": "1"]), as: UTF8.self) == "a=1&code=4%2F0%2Ba%20b%26c")
    #expect(ScryGoogleAuth.base64URL(Data([0xfb, 0xff, 0xfe])) == "-__-")
}

@Test func alarmSettingIsOnByDefaultAndRoundTrips() {
    var s = ScrySettings()
    #expect(s.meetingAlarm)
    #expect(s.meetingSoon)
    s.meetingAlarm = false
    s.meetingSoon = false
    #expect(ScrySettings.load(s.rows) == s)
}
