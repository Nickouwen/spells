import AppKit
import SwiftUI
import SpellsKit
import SpellsUI
import ScryCore

/// Watches your meetings (the calendar's and the ones added by hand) and puts up "Your meeting is starting now"
/// when one starts and you're in no call. Joining a call takes the alarm down. A quiet bar says so 5 minutes before, and offers Join 2 minutes before.
@MainActor final class ScryAlarm {
    /// The call app on the mic, or any name while recording in person; nil = not in a meeting.
    var call: () -> String? = { nil }
    private var alarm = ScryMeetingAlarm(), meetings: [ScryMeeting] = [], readAt = Date.distantPast
    private var panel: NSPanel?, shown: ScryMeeting?, soonPanel: NSPanel?, soon: ScryMeetingAlarm.Soon?
    private var ring = false, notice = false
    private var sound: NSSound?, timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        if now.timeIntervalSince(readAt) >= 15 {
            readAt = now
            let s = ScryApp.loadSettings().settings
            (ring, notice) = (s.meetingAlarm, s.meetingSoon)
            meetings = ring || notice ? ScryCalendar.meetings(now: now) + ScryReminders.load() : []
        }
        let due = alarm.due(meetings, call: call(), at: now)
        if ring, let due { show(due) } else { hide() }
        if notice, let next = alarm.soon(meetings, at: now) { showSoon(next) } else { hideSoon() }
    }

    private func show(_ m: ScryMeeting) {
        guard shown != m else { return }
        hide()
        shown = m
        SupportLog.scry.info("meeting alarm shown")
        let view = ScryAlarmView(meeting: m,
                                 join: m.link.map { url in { [weak self] in NSWorkspace.shared.open(url); self?.dismiss() } },
                                 dismiss: { [weak self] in self?.dismiss() })
        // The screen you're on, upper middle. Rises into place.
        panel = present(view, rise: -8) { f, size in NSPoint(x: f.midX - size.width / 2, y: f.minY + f.height * 0.62 - size.height / 2) }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Your meeting is starting now: \(m.title)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let s = NSSound(named: "Glass")
        s?.loops = true
        s?.play()
        sound = s
        Task { try? await Task.sleep(for: .seconds(30)); s?.stop() }   // the panel stays up, quietly
    }

    private func dismiss() {
        if let shown { alarm.handle(shown) }
        hide()
    }

    private func hide() {
        sound?.stop(); sound = nil
        if let panel { leave(panel) }
        panel = nil
        shown = nil
    }

    private func showSoon(_ s: ScryMeetingAlarm.Soon) {
        guard soon != s else { return }
        hideSoon()
        soon = s
        let m = s.meeting
        SupportLog.scry.info("meeting heads-up shown")
        let view = ScrySoonView(meeting: m,
                                join: !s.join ? nil : m.link.map { url in { [weak self] in
                                    NSWorkspace.shared.open(url)
                                    self?.alarm.handle(m)   // on your way in: no alarm while you wait to be let in
                                    self?.dismissSoon()
                                } },
                                dismiss: { [weak self] in self?.dismissSoon() })
        // Top middle, below the menu bar. Drops into place.
        soonPanel = present(view, rise: 8) { f, size in NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 10) }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(m.title) starts in \(s.join ? "two" : "five") minutes", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func dismissSoon() {
        if let soon { alarm.notice(soon) }
        hideSoon()
    }

    private func hideSoon() {
        if let soonPanel { leave(soonPanel) }
        soonPanel = nil
        soon = nil
    }

    /// A borderless panel on the mouse's screen, in from `rise` points off; with Reduce Motion it only fades.
    private func present(_ view: some View, rise: CGFloat, at origin: (NSRect, NSSize) -> NSPoint) -> NSPanel {
        let host = FirstMouseHost(rootView: view)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = host
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame { p.setFrameOrigin(origin(f, p.frame.size)) }
        let end = p.frame, move = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : rise
        p.alphaValue = 0
        p.setFrame(end.offsetBy(dx: 0, dy: move), display: false)
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            p.animator().setFrame(end, display: true)
            p.animator().alphaValue = 1
        }
        return p
    }

    private func leave(_ p: NSPanel) {
        p.ignoresMouseEvents = true   // a second click on Join must not open it twice
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }) { MainActor.assumeIsolated { p.orderOut(nil) } }
    }
}

/// Clicks land on the first try even though the panel is never key.
private final class FirstMouseHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The heads-up: the meeting, its countdown and (time to join) Join on one line.
struct ScrySoonView: View {
    let meeting: ScryMeeting
    /// nil = no call link, or not time yet.
    let join: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: meeting.link == nil ? "calendar" : "video.fill").foregroundStyle(Theme.ink).accessibilityHidden(true)
            Text(meeting.title).textRole(.bodyEmph).lineLimit(1).help(meeting.title)
            Spacer(minLength: 0)
            Text("Starts in \(Text(timerInterval: min(Date(), meeting.start)...meeting.start, countsDown: true))")
                .textRole(.body).monospacedDigit().fixedSize()
            HStack(spacing: Theme.Space.xs) {   // Join last, as in the alarm
                Button("Dismiss", action: dismiss).buttonStyle(QuietButtonStyle())
                if let join { Button("Join", action: join).buttonStyle(PrimaryButtonStyle()) }
            }
        }
        .padding(.leading, Theme.Space.l).padding(.trailing, Theme.Space.s).padding(.vertical, Theme.Space.s)
        .frame(width: 520)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
        .accessibilityElement(children: .contain)
    }
}

struct ScryAlarmView: View {
    let meeting: ScryMeeting
    /// nil = the meeting has no call link.
    let join: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Your meeting is starting now").textRole(.title)
                Text(meeting.title).textRole(.body).lineLimit(2)
                Text(meeting.start.formatted(date: .omitted, time: .shortened)).textRole(.label, Theme.inkSecondary)
            }
            HStack(spacing: Theme.Space.s) {
                Spacer()
                Button("Dismiss", action: dismiss).buttonStyle(RewindButtonStyle())
                if let join { Button("Join", action: join).buttonStyle(PrimaryButtonStyle()) }
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 400)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
        .accessibilityElement(children: .contain)
    }
}

/// The meetings added by hand.
@MainActor enum ScryReminders {
    static var url: URL { SupportPaths.current().home.appending(path: "scry/meeting-reminders.json") }
    static func load() -> [ScryMeeting] {
        do { return try ScryMeeting.load(url) } catch {
            SupportLog.scry.error("meeting reminders not read: \(String(describing: error), privacy: .private)")
            return []
        }
    }
}

/// Add a meeting by hand, see what's coming, remove one.
struct ScryRemindersView: View {
    @State private var reminders: [ScryMeeting] = []
    @State private var title = ""
    @State private var start = Date()
    @State private var link = ""
    @State private var clientID = ""
    private let google = ScryGoogle.shared
    @State private var error: String?

    var body: some View {
        SettingsPage {
            SettingsSection("Add a meeting", detail: "Scry pops up \u{201C}Your meeting is starting now\u{201D} if it starts and you're not in a call.") {
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                SettingsDivider()
                DatePicker("Starts", selection: $start)
                SettingsDivider()
                TextField("Call link (optional)", text: $link).textFieldStyle(.roundedBorder)
                SettingsDivider()
                HStack {
                    if let error { Text(error).textRole(.label, Theme.StateLayer.distraction) }
                    Spacer()
                    Button("Add", action: add).buttonStyle(PrimaryButtonStyle())
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            SettingsSection("Added by hand") {
                if reminders.isEmpty { Text("None.").textRole(.detail) }
                ForEach(reminders) { m in
                    HStack(spacing: Theme.Space.s) {
                        Text(m.title).textRole(.body).lineLimit(1)
                        Spacer()
                        Text(m.start.formatted(date: .abbreviated, time: .shortened)).textRole(.label, Theme.inkSecondary)
                        Button("Remove") { save { $0.removeAll { $0.id == m.id } } }.buttonStyle(RewindButtonStyle())
                            .accessibilityLabel("Remove \(m.title)")
                    }
                }
            }
            SettingsSection("Google Calendar", detail: "Read-only. Scry reads your main calendar for the alarm and for who was invited.") {
                if google.connected {
                    HStack(spacing: Theme.Space.s) {
                        Text("Connected\(google.account.map { ": \($0)" } ?? "")").textRole(.body)
                        Spacer()
                        Button("Disconnect") { Task { await google.disconnect() } }.buttonStyle(RewindButtonStyle())
                    }
                } else {
                    HStack(spacing: Theme.Space.s) {
                        TextField("Client ID (\u{2026}.apps.googleusercontent.com)", text: $clientID).textFieldStyle(.roundedBorder)
                        Button(google.busy ? "Waiting\u{2026}" : "Connect Google") { connect() }.buttonStyle(PrimaryButtonStyle())
                            .disabled(google.busy || ScryGoogleAuth.scheme(clientID.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                    }
                }
                if let e = google.error { Text(e).textRole(.label, Theme.StateLayer.distraction) }
                SettingsDivider()
                Text(ScryCalendar.status).textRole(.detail)
            }
        }
        .tint(Theme.ink)
        .onAppear {
            reminders = upcoming(ScryReminders.load())
            clientID = ScryApp.loadSettings().settings.googleClientID
        }
    }

    private func connect() {
        do {
            try SpellSettingsFile.scry().set(ScrySettings.googleClientIDKey, clientID.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch { self.error = "Couldn't save: \(error.localizedDescription)"; return }
        Task { await google.connect() }
    }

    private func add() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: text.contains("://") ? text : "https://" + text)
        guard text.isEmpty || (url?.host() != nil && ["https", "http"].contains(url?.scheme)) else { error = "That isn't a web link."; return }
        guard start > Date() else { error = "That time has passed."; return }
        let at = Calendar.current.dateInterval(of: .minute, for: start)?.start ?? start   // the picker keeps the seconds it opened with
        let m = ScryMeeting(title: title.trimmingCharacters(in: .whitespaces), start: at, end: at.addingTimeInterval(3600), link: text.isEmpty ? nil : url)
        if save({ $0.removeAll { $0.id == m.id }; $0.append(m) }) { title = ""; link = "" }
    }

    private func upcoming(_ m: [ScryMeeting]) -> [ScryMeeting] { m.filter { $0.end > Date() }.sorted { $0.start < $1.start } }

    /// An unreadable file is left alone rather than overwritten.
    @discardableResult private func save(_ change: (inout [ScryMeeting]) -> Void) -> Bool {
        do {
            var all = upcoming(try ScryMeeting.load(ScryReminders.url))
            change(&all)
            try ScryMeeting.save(all, to: ScryReminders.url)
            reminders = upcoming(all)
            error = nil
            return true
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }
}
