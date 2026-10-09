import EventKit
import Foundation
import HoursCore
import ScryCore

/// The calendar event behind a recording, via EventKit (whatever accounts macOS Calendar has — add Google
/// under Internet Accounts). Who was invited, with emails; the screen says who actually came.
@MainActor enum ScryCalendar {
    private static let store = EKEventStore()

    static func requestAccess() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        store.requestFullAccessToEvents { granted, _ in
            SupportLog.scry.info("calendar access: \(granted, privacy: .public)")
        }
    }

    static func invite(app: String?, now: Date) -> ScryInvite? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600),
                                                                     end: now.addingTimeInterval(900), calendars: nil))
        let candidates = events.filter { !$0.isAllDay }.map { e in
            let people = (e.attendees ?? []) + [e.organizer].compactMap { $0 }
            var invitees: [ScryInvite.Invitee] = []
            for p in people where !p.isCurrentUser && p.participantType == .person {
                let email = p.url.absoluteString.hasPrefix("mailto:") ? String(p.url.absoluteString.dropFirst(7)) : nil
                guard let name = p.name ?? email, !invitees.contains(where: { $0.name == name }) else { continue }
                invitees.append(.init(name: name, email: email))
            }
            let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
            return ScryInvite.Candidate(title: e.title ?? "", start: e.startDate, end: e.endDate, text: text, invitees: invitees)
        }
        return ScryInvite.pick(candidates, app: app, now: now)
    }
}
