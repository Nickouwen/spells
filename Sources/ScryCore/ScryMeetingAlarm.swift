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
    /// How long before its start a meeting gets the heads-up.
    static let notice: TimeInterval = 60
    private var handled: Set<String> = [], noticed: Set<String> = []
    public init() {}

    public mutating func handle(_ m: ScryMeeting) { handled.insert(m.id) }
    /// The heads-up is dealt with. The alarm still rings if you miss the start.
    public mutating func notice(_ m: ScryMeeting) { noticed.insert(m.id) }

    /// The meeting that starts within a minute and that you haven't joined, also while another call runs over.
    /// Asked after `due`, which keeps track of the call.
    public func soon(_ meetings: [ScryMeeting], at date: Date) -> ScryMeeting? {
        let inCall = call != nil && date.timeIntervalSince(seen) < Self.gap
        return meetings.filter { m in
            date < m.start && m.start.timeIntervalSince(date) <= Self.notice && !noticed.contains(m.id)
                && !(inCall && since >= m.start.addingTimeInterval(-Self.early))
        }.min { $0.start < $1.start }
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
