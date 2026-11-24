import Foundation

/// A calendar event, from macOS Calendar or Google, as the invite matcher and the meeting alarm need it.
public struct ScryCalendarEvent: Sendable {
    public var candidate: ScryInvite.Candidate
    /// Cancelled, or declined by you.
    public var off: Bool
    public init(candidate: ScryInvite.Candidate, off: Bool) { self.candidate = candidate; self.off = off }

    /// A meeting for the alarm: other people or a call link, and not off. Focus blocks aren't meetings.
    public var meeting: ScryMeeting? {
        let link = ScryMeeting.callLink(in: candidate.text)
        guard !off, link != nil || !candidate.invitees.isEmpty else { return nil }
        return ScryMeeting(title: candidate.title, start: candidate.start, end: candidate.end, link: link)
    }

    /// Google often sends only an address: `laura.crane@x.com` → "Laura Crane"; kept whole when it isn't plain words.
    static func name(fromEmail e: String) -> String {
        let words = e.prefix { $0 != "@" }.split(separator: ".")
        guard !words.isEmpty, words.allSatisfy({ $0.allSatisfy(\.isLetter) }) else { return e }
        return words.map(\.capitalized).joined(separator: " ")
    }

    /// A Google Calendar `events.list` reply: its timed events, and the calendar's name (your address).
    public static func google(_ data: Data) throws -> (account: String, events: [ScryCalendarEvent]) {
        struct Reply: Decodable {
            struct Time: Decodable { var dateTime: String? }
            struct Person: Decodable { var email, displayName, responseStatus: String?; var `self`, resource: Bool? }
            struct Conference: Decodable { struct Entry: Decodable { var entryPointType, uri: String? }; var entryPoints: [Entry]? }
            struct Item: Decodable {
                var status, summary, description, location, hangoutLink: String?
                var start, end: Time?, attendees: [Person]?, organizer: Person?, conferenceData: Conference?
            }
            var summary: String?, items: [Item]?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let iso = ISO8601DateFormatter()
        let events = (reply.items ?? []).compactMap { e -> ScryCalendarEvent? in   // no dateTime = an all-day event
            guard let start = e.start?.dateTime.flatMap(iso.date(from:)), let end = e.end?.dateTime.flatMap(iso.date(from:)) else { return nil }
            var invitees: [ScryInvite.Invitee] = []
            for p in (e.attendees ?? []) + [e.organizer].compactMap({ $0 }) where p.`self` != true && p.resource != true {
                // A calendar you share (the team's) organizes its own events: not a person.
                guard let name = p.displayName ?? p.email.map(Self.name(fromEmail:)), p.email?.hasSuffix("calendar.google.com") != true,
                      !invitees.contains(where: { $0.name == name || ($0.email != nil && $0.email == p.email) }) else { continue }
                invitees.append(.init(name: name, email: p.email))
            }
            let video = (e.conferenceData?.entryPoints ?? []).filter { $0.entryPointType == "video" }.map(\.uri)
            let text = ([e.hangoutLink] + video + [e.location, e.description]).compactMap { $0 }.joined(separator: " ")
            return .init(candidate: .init(title: e.summary ?? "Meeting", start: start, end: end, text: text, invitees: invitees),
                         off: e.status == "cancelled" || e.attendees?.contains { $0.`self` == true && $0.responseStatus == "declined" } == true)
        }
        return (reply.summary ?? "Google", events)
    }
}

/// Google's sign-in for an installed app: the system browser, PKCE, and no client secret (an "iOS" OAuth client,
/// which is what Google gives a macOS app with its own URL scheme).
public enum ScryGoogleAuth {
    /// Read-only, events only.
    public static let scope = "https://www.googleapis.com/auth/calendar.events.readonly"

    /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`; nil when it isn't a client ID.
    public static func scheme(_ clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix), clientID.count > suffix.count,
              clientID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else { return nil }
        return "com.googleusercontent.apps." + clientID.dropLast(suffix.count)
    }
    public static func redirect(_ clientID: String) -> String? { scheme(clientID).map { $0 + ":/oauth2redirect" } }

    public static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func authURL(clientID: String, challenge: String, state: String) -> URL? {
        guard let redirect = redirect(clientID) else { return nil }
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = ["client_id": clientID, "redirect_uri": redirect, "response_type": "code", "scope": scope, "state": state,
                        "code_challenge": challenge, "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent"]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url
    }

    /// The code in Google's redirect; nil unless it answers this sign-in (`state`).
    public static func code(in callback: URL, state: String) -> String? {
        let q = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard q.first(where: { $0.name == "state" })?.value == state else { return nil }
        return q.first { $0.name == "code" }?.value
    }

    /// `application/x-www-form-urlencoded`.
    public static func form(_ fields: [String: String]) -> Data {
        let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: ok)!)" }
            .joined(separator: "&").utf8)
    }
}
