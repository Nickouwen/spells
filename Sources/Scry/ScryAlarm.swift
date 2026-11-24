import AppKit
import SwiftUI
import SpellsKit
import SpellsUI
import ScryCore

/// Watches your meetings (the calendar's and the ones added by hand) and puts up "Your meeting is starting now"
/// when one starts and you're in no call. Joining a call takes the alarm down.
@MainActor final class ScryAlarm {
    /// The call app on the mic, or any name while recording in person; nil = not in a meeting.
    var call: () -> String? = { nil }
    private var alarm = ScryMeetingAlarm(), meetings: [ScryMeeting] = [], readAt = Date.distantPast
    private var panel: NSPanel?, shown: ScryMeeting?
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
            let on = ScryApp.loadSettings().settings.meetingAlarm
            meetings = on ? ScryCalendar.meetings(now: now) + ScryReminders.load() : []
        }
        let due = alarm.due(meetings, call: call(), at: now)
        if let due { show(due) } else { hide() }
    }

    private func show(_ m: ScryMeeting) {
        guard shown != m else { return }
        hide()
        shown = m
        SupportLog.scry.info("meeting alarm shown")
        let view = ScryAlarmView(meeting: m,
                                 join: m.link.map { url in { [weak self] in NSWorkspace.shared.open(url); self?.dismiss() } },
                                 dismiss: { [weak self] in self?.dismiss() })
        let host = NSHostingView(rootView: view)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = host
        // The screen you're on (the mouse's), upper middle.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + f.height * 0.62 - p.frame.height / 2))
        }
        // Rises a little into place; with Reduce Motion it only fades.
        let end = p.frame, move: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 8
        p.alphaValue = 0
        p.setFrame(end.offsetBy(dx: 0, dy: -move), display: false)
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            p.animator().setFrame(end, display: true)
            p.animator().alphaValue = 1
        }
        panel = p
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
        if let p = panel {
            p.ignoresMouseEvents = true   // a second click on Join must not open it twice
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                p.animator().alphaValue = 0
            }) { MainActor.assumeIsolated { p.orderOut(nil) } }
        }
        panel = nil
        shown = nil
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
