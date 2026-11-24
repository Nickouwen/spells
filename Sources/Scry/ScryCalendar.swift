import EventKit
import Foundation
import SpellsKit
import ScryCore

/// The calendar event behind a recording, and the meetings for the alarm: Google Calendar when connected
/// (`ScryGoogle`), plus EventKit (whatever accounts macOS Calendar has). Who was invited, with emails; the
/// screen says who actually came.
@MainActor enum ScryCalendar {
    private static let store = EKEventStore()

    static func requestAccess() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        store.requestFullAccessToEvents { granted, _ in
            SupportLog.scry.info("calendar access: \(granted, privacy: .public)")
        }
    }

    static func invite(app: String?, now: Date) -> ScryInvite? {
        ScryInvite.pick(events(now: now).map(\.candidate), app: app, now: now)
    }

    /// The meetings around now, for the alarm.
    static func meetings(now: Date) -> [ScryMeeting] {
        ScryGoogle.shared.refreshIfDue()
        return events(now: now).compactMap(\.meeting)
    }

    private static func events(now: Date) -> [ScryCalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return ScryGoogle.shared.events }
        let local = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600),
                                                                    end: now.addingTimeInterval(900), calendars: nil))
        return ScryGoogle.shared.events + local.filter { !$0.isAllDay }.map { e in
            let people = (e.attendees ?? []) + [e.organizer].compactMap { $0 }
            var invitees: [ScryInvite.Invitee] = []
            for p in people where !p.isCurrentUser && p.participantType == .person {
                let email = p.url.absoluteString.hasPrefix("mailto:") ? String(p.url.absoluteString.dropFirst(7)) : nil
                guard let name = p.name ?? email, !invitees.contains(where: { $0.name == name }) else { continue }
                invitees.append(.init(name: name, email: email))
            }
            let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
            let declined = e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } == true
            return ScryCalendarEvent(candidate: .init(title: e.title ?? "", start: e.startDate, end: e.endDate, text: text, invitees: invitees),
                                     off: e.status == .canceled || declined)
        }
    }

    /// Whether Scry can read macOS Calendar, in words.
    static var status: String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return "Scry isn't allowed to read macOS Calendar (System Settings \u{203A} Privacy & Security \u{203A} Calendars). It doesn't need to when Google is connected."
        }
        let names = Set(store.calendars(for: .event).map(\.source.title)).sorted().joined(separator: ", ")
        return "Scry also reads macOS Calendar: \(names)."
    }
}
