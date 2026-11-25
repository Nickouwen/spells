import Foundation

/// A meeting the alarm watches: from the calendar, or added by hand in Scry.
public struct ScryMeeting: Codable, Equatable, Identifiable, Sendable {
    public var title: String, start: Date, end: Date, link: URL?
    public init(title: String, start: Date, end: Date, link: URL? = nil) {
        self.title = title; self.start = start; self.end = end; self.link = link
    }
    /// The same invite on two calendars is one meeting; a moved one is new.
    public var id: String { "\(title)|\(start.timeIntervalSince1970)" }

    /// The first call link in an event's text: https, on a known call host only (anyone can send an invite).
    public static func callLink(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)).lazy.compactMap(\.url).first { url in
            guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
            return ScryInvite.webLinks.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    /// The reminders added by hand: `<home>/scry/meeting-reminders.json`. Missing file = none.
    public static func load(_ url: URL) throws -> [ScryMeeting] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ScryMeeting].self, from: Data(contentsOf: url))
    }

    public static func save(_ meetings: [ScryMeeting], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(meetings).write(to: url, options: .atomic)
    }
}

/// Which meeting you're about to miss. Fed about once a second.
/// - A meeting that started under `window` ago, while you're in no call → due, until handled.
/// - A call that began within `early` before its start (or after it) counts as joining it.
/// - A call that began earlier is another one running over: the meeting stays due for when it ends.
public struct ScryMeetingAlarm: Sendable {
    static let window: TimeInterval = 600, early: TimeInterval = 600
    /// Off the mic for less than this is the same call (a mute, a device change).
    static let gap: TimeInterval = 5
    private var call: String?, since = Date.distantPast, seen = Date.distantPast
    /// Before its start a meeting gets a notice (up for `noticeFor`), then the bar with Join.
    static let notice: TimeInterval = 300, noticeFor: TimeInterval = 30, join: TimeInterval = 120
    private var handled: Set<String> = [], noticed: Set<String> = []
    public init() {}

    public mutating func handle(_ m: ScryMeeting) { handled.insert(m.id) }
    /// The heads-up is dealt with. The alarm still rings if you miss the start.
    public mutating func notice(_ s: Soon) { noticed.insert(s.id) }

    public struct Soon: Equatable, Sendable {
        public var meeting: ScryMeeting
        /// Time to join; false = the early notice.
        public var join: Bool
        public init(meeting: ScryMeeting, join: Bool) { self.meeting = meeting; self.join = join }
        var id: String { "\(join)|\(meeting.id)" }
    }

    /// The meeting about to start that you haven't joined, also while another call runs over.
    /// Asked after `due`, which keeps track of the call.
    public func soon(_ meetings: [ScryMeeting], at date: Date) -> Soon? {
        let inCall = call != nil && date.timeIntervalSince(seen) < Self.gap
        return meetings.compactMap { m -> Soon? in
            let left = m.start.timeIntervalSince(date)
            guard left > 0, left <= Self.join || (left <= Self.notice && left > Self.notice - Self.noticeFor),
                  !(inCall && since >= m.start.addingTimeInterval(-Self.notice)) else { return nil }
            let s = Soon(meeting: m, join: left <= Self.join)
            return noticed.contains(s.id) ? nil : s
        }.min { $0.meeting.start < $1.meeting.start }
    }

    /// `call` = the call app on the mic (or any name for an in-person recording); nil = not in a meeting.
    public mutating func due(_ meetings: [ScryMeeting], call now: String?, at date: Date) -> ScryMeeting? {
        if let now {
            if now != call || date.timeIntervalSince(seen) >= Self.gap { since = date }
            call = now; seen = date
        }
        let open = meetings.filter { $0.start <= date && date < min($0.end, $0.start.addingTimeInterval(Self.window)) }
        let inCall = call != nil && date.timeIntervalSince(seen) < Self.gap
        guard inCall else { return open.filter { !handled.contains($0.id) }.min { $0.start < $1.start } }
        for m in open where since >= m.start.addingTimeInterval(-Self.early) { handled.insert(m.id) }
        return nil
    }
}
