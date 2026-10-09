import AppKit
import AVFoundation
import HoursCore
import IncantCore
import ScryCore
import ScryPipeline
import UserNotifications

/// Scry's brain: the status item + menu, the mic watch → offer pill, and one recording at a time
/// (recorder, live side, call-window screenshots). Stopping writes `capture.json` and hands the capture
/// dir to `ScryPipeline.process`; a notification opens the note when it's ready. Quitting (or SIGTERM)
/// mid-recording saves the capture instead, and the next launch runs the pipeline on it.
@MainActor final class ScryApp: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    @MainActor final class Session {
        let dir: URL, app: String?, startedAt = Date(), recorder: ScryRecorder, settings: ScrySettings, keyterms: [String]
        var live: ScryLive?, screens: [[String]] = [], timer: Timer?, levels: Timer?, invite: ScryInvite?
        init(dir: URL, app: String?, recorder: ScryRecorder, settings: ScrySettings, keyterms: [String]) {
            self.dir = dir; self.app = app; self.recorder = recorder; self.settings = settings; self.keyterms = keyterms
        }
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let pill = ScryOfferPill()
    private let watch = ScryMicWatch()
    private var offered: String?
    private var session: Session?
    private var sigterm: (any DispatchSourceSignal)?
    nonisolated private static let canNotify = Bundle.main.bundleIdentifier != nil   // UNUserNotificationCenter traps outside a bundle

    /// The running instance (the pipeline's completion hops back to it).
    static weak var shared: ScryApp?

    override init() {
        super.init()
        Self.shared = self
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
        pill.onRecord = { [weak self] in self?.start(app: self?.offered, systemAudio: true) }
        pill.onNever = { [weak self] in self?.never(self?.offered) }
        pill.onOpenLive = { [weak self] in self?.session?.live?.show() }
        pill.onStop = { [weak self] in self?.stop() }
        pill.onOpenNote = { url in Self.openInSpells(url) }
        watch.onTick = { [weak self] stopsIn in self?.tickRecording(stopsIn) }
        watch.detector.never = Set(Self.loadSettings().settings.never)
        watch.recording = { [weak self] in
            guard let s = self?.session else { return .none }
            return s.app.map { .call($0) } ?? .inPerson
        }
        watch.onAction = { [weak self] in self?.handle($0) }
        watch.start()
        if Self.canNotify {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        ScryCalendar.requestAccess()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveForLater() }
        }
        signal(SIGTERM, SIG_IGN)   // SIGTERM (Scry switched off, logout) → a normal terminate, so willTerminate runs
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        sigterm = source
        processLeftovers()
    }

    private func handle(_ action: ScryDetectAction) {
        switch action {
        case .offer(let app):
            let s = Self.loadSettings().settings
            guard s.autoOffer || s.autoRecord, !s.never.contains(app), session == nil else { return }
            offered = app
            guard s.autoRecord else { pill.show(appName: Self.name(app)); return }
            Task {
                // A browser on the mic isn't always a call (voice notes, dictation sites): auto-record only with a
                // call-titled window, else just offer.
                let call = ScryScreens.browsers.contains(app) ? await ScryScreens.meetingWindowOpen(app: app) : true
                guard session == nil, offered == app else { return }
                if call {
                    SupportLog.scry.info("auto-recording \(app, privacy: .public)")
                    start(app: app, systemAudio: true)
                } else if s.autoOffer {
                    pill.show(appName: Self.name(app))
                }
            }
        case .withdraw: pill.hide()
        case .stop: stop()
        case .none: break
        }
    }

    // MARK: Recording

    /// The recording pill beside the notch: "● mm:ss", or "Ending · Ns" once the call app has let go of the mic.
    /// The pipeline finished: the "Meeting notes ready" pill (unless a new recording holds it), plus a quiet
    /// notification for when you weren't looking.
    func notesReady(_ r: ScryPipeline.Result) {
        if session == nil { pill.showReady(title: r.summary.title, note: r.noteURL) }
        Task { await Self.notify("Meeting notes ready: \(r.summary.title)", open: r.noteURL) }
    }

    /// Opens Spells on that note (Meetings view) via its `spells://meeting?path=` URL.
    static func openInSpells(_ note: URL) {
        var c = URLComponents(); c.scheme = "spells"; c.host = "meeting"
        c.queryItems = [URLQueryItem(name: "path", value: note.path)]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    private func tickRecording(_ stopsIn: Int64?) {
        guard let s = session else { return }
        // Who's with you (names read off the call window), so you can see it's recording the right call.
        // The pill: who's on screen now (the latest screenshot), so leavers drop off; the note gets everyone
        // ever seen (all screenshots go to the pipeline).
        // Nobody on screen yet → the invite's title (still says it's the right meeting), else the app.
        let now = ScryNames.completed(s.screens.last.map { ScryNames.fromOCR([$0]) } ?? [], s.invite)
        let who = ScryNames.pillLabel(now, userName: s.settings.userName,
                                      fallback: s.invite?.title ?? s.app.map(Self.name) ?? "In person")
        if let ms = stopsIn {
            pill.showRecording("Ending · \(Int((Double(ms) / 1000).rounded(.up)))s · \(who.short)", tooltip: who.full)
        } else {
            let secs = Int(Date().timeIntervalSince(s.startedAt))
            pill.showRecording(String(format: "● %02d:%02d · ", secs / 60, secs % 60) + who.short, tooltip: who.full)
        }
    }

    /// `app` nil = no call app to watch (in person, or "Record call" with no call app on the mic): never auto-stops.
    private func start(app: String?, systemAudio: Bool) {
        guard session == nil else { return }
        pill.hide()
        let (settings, keyterms) = Self.loadSettings()
        let dir = SupportPaths.current().home.appending(path: "scry/captures/\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            let recorder = try ScryRecorder(audio: dir.appending(path: "audio.wav"))
            let s = Session(dir: dir, app: app, recorder: recorder, settings: settings, keyterms: keyterms)
            try recorder.startMic()
            // Only once the mic is up: a failed start must not leave live sockets reconnecting.
            if settings.live { s.live = ScryLive(recorder: recorder, keyterms: keyterms, systemAudio: systemAudio) }
            if systemAudio {   // off main: the first run blocks on the System Audio Recording prompt
                DispatchQueue.global().async {
                    do { try recorder.startSystem() } catch {
                        SupportLog.scry.error("system audio unavailable, recording mic only: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            session = s
            tickRecording(nil)   // the pill shows straight away, not at the next poll
            s.levels = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self, weak s] _ in
                MainActor.assumeIsolated { if let s { self?.pill.pushLevel(s.recorder.level) } }
            }
            s.invite = ScryCalendar.invite(app: app, now: s.startedAt)
            if let i = s.invite { SupportLog.scry.info("calendar invite matched: \(i.invitees.count, privacy: .public) invitees") }
            if let app {
                screenshot(s, app)
                // Every 30 s: a late joiner shows in the pill within half a minute; OCR is ~0.5 s on-device each.
                s.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self, weak s] _ in
                    MainActor.assumeIsolated { if let s { self?.screenshot(s, app) } }
                }
            }
            SupportLog.scry.info("recording started (\(app ?? "in person", privacy: .public), live: \(settings.live, privacy: .public))")
        } catch {
            SupportLog.scry.error("couldn't start recording: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: dir)
            Task { await Self.notify("Scry couldn't start recording", open: nil) }
        }
        refreshIcon()
    }

    private func screenshot(_ s: Session, _ app: String) {
        Task {
            if let lines = await ScryScreens.lines(app: app), !lines.isEmpty { s.screens.append(lines) }
        }
    }

    /// Ends the recording without keeping anything.
    private func endSession() -> (Session, ScryRecorder.Stats)? {
        guard let s = session else { return nil }
        session = nil
        pill.hide()
        s.timer?.invalidate(); s.levels?.invalidate()
        let stats = s.recorder.stop()
        s.live?.stop()
        refreshIcon()
        return (s, stats)
    }

    /// Ends the recording (WAV header patched) and writes `capture.json`. nil if there was nothing to finish
    /// or the manifest couldn't be written.
    private func finish() -> Session? {
        guard let (s, stats) = endSession() else { return nil }
        SupportLog.scry.info("recording stopped: \(stats.frames, privacy: .public) frames, \(s.screens.count, privacy: .public) screenshots")
        let capture = ScryCapture(audioFile: "audio.wav", startedAt: s.startedAt, endedAt: Date(), app: s.app,
                                  screenshotText: s.screens, userNotes: s.live?.model.notes ?? "", invite: s.invite)
        do { try capture.encoded().write(to: s.dir.appending(path: "capture.json")) } catch {
            SupportLog.scry.error("couldn't write capture.json: \(error.localizedDescription, privacy: .public)")
            Task { await Self.notify("Scry couldn't finish the notes", open: nil) }
            return nil
        }
        return s
    }

    @objc private func stop() {
        guard let s = finish() else { return }
        Self.process(s.dir, settings: s.settings, keyterms: s.keyterms)
    }

    /// Quit / SIGTERM mid-recording: keep the capture; `processLeftovers` picks it up on the next launch.
    private func saveForLater() {
        if let s = finish() { SupportLog.scry.info("recording saved for the next launch: \(s.dir.lastPathComponent, privacy: .public)") }
    }

    /// At launch: stale upload spools go, crashed recordings get a manifest, and every capture with fewer than
    /// `ScryCaptures.maxAttempts` failures (a quit mid-recording, or a transient failure like being offline) is
    /// processed again. Ones that keep failing wait in the Meetings view's Failed captures.
    private func processLeftovers() {
        ScryCaptures.cleanSpool()
        ScryCaptures.recoverCrashed()
        let dirs = ScryCaptures.retryable()
        guard !dirs.isEmpty else { return }
        let (settings, keyterms) = Self.loadSettings()
        for d in dirs {
            SupportLog.scry.info("processing a leftover capture: \(d.lastPathComponent, privacy: .public)")
            Self.process(d, settings: settings, keyterms: keyterms)
        }
    }

    /// Runs the pipeline off the main actor; on failure the capture dir stays (with its attempt count) and
    /// a notification says so.
    private static func process(_ dir: URL, settings: ScrySettings, keyterms: [String]) {
        Task.detached {
            do {
                let r = try await ScryPipeline.process(captureDir: dir, settings: settings, keyterms: keyterms)
                await MainActor.run { ScryApp.shared?.notesReady(r) }
            } catch {   // the pipeline already recorded the attempt in error.txt; the error may quote model output
                SupportLog.scry.error("pipeline failed (capture kept at \(dir.lastPathComponent, privacy: .public)): \(String(describing: error), privacy: .private)")
                await notify("Scry couldn't finish the notes", open: nil)
            }
        }
    }

    @objc private func discard() {
        guard let (s, _) = endSession() else { return }
        try? FileManager.default.removeItem(at: s.dir)
        SupportLog.scry.info("recording discarded")
    }

    private func never(_ app: String?) {
        guard let app else { return }
        var s = Self.loadSettings().settings
        if !s.never.contains(app) { s.never.append(app) }
        do { try SettingStore(HoursDB.open(at: SupportPaths.current().db, role: .app)).set(ScrySettings.neverKey, s.rows[ScrySettings.neverKey]) } catch {
            SupportLog.scry.error("couldn't save never-offer: \(error.localizedDescription, privacy: .public)")
        }
        watch.detector.never.insert(app)
    }

    // MARK: Settings + notifications

    static func loadSettings() -> (settings: ScrySettings, keyterms: [String]) {
        var rows: [String: String] = [:]
        do { rows = try SettingStore(HoursDB.open(at: SupportPaths.current().db, role: .app)).all() } catch {
            SupportLog.scry.error("couldn't read settings, using defaults: \(error.localizedDescription, privacy: .public)")
        }
        return (ScrySettings.load(rows), IncantSettings.load(rows).keyterms)   // Incant's defaults when unset
    }

    static func name(_ app: String) -> String { ScryCallApps.known[app] ?? app }

    nonisolated static func notify(_ title: String, open url: URL?) async {
        guard canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        if let url { c.userInfo = ["path": url.path] }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["path"] as? String else { return }
        await MainActor.run { ScryApp.openInSpells(URL(filePath: path)) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: Status menu

    private func refreshIcon() {
        let (symbol, tip) = session == nil ? ("eye", "Scry") : ("record.circle.fill", "Scry: recording")
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        item.button?.toolTip = tip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let s = session {
            let secs = Int(Date().timeIntervalSince(s.startedAt))
            let info = NSMenuItem(title: "● Recording \(s.app.map(Self.name) ?? "in person") — \(String(format: "%02d:%02d", secs / 60, secs % 60))",
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            if s.live != nil { menu.addItem(action("Show live panel", #selector(showLive))) }
            menu.addItem(action("Stop and make notes", #selector(stop)))
            menu.addItem(action("Discard", #selector(discard)))
        } else {
            menu.addItem(action("Record call", #selector(recordCall)))
            menu.addItem(action("Record in person", #selector(recordInPerson)))
            menu.addItem(action("Open notes folder", #selector(openNotes)))
            menu.addItem(.separator())
            menu.addItem(action("Settings…", #selector(openSpells)))
            menu.addItem(action("Quit Scry", #selector(quit)))
        }
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func recordCall() { start(app: watch.callApp, systemAudio: true) }
    @objc private func recordInPerson() { start(app: nil, systemAudio: false) }
    @objc private func showLive() { session?.live?.show() }

    @objc private func openNotes() {
        let root = Self.loadSettings().settings.rootURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    @objc private func openSpells() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Hours.bundlePrefix) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
