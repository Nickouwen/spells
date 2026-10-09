import AppKit

/// Wires OS notifications into `TrackerEngine` and its outputs into a `TrackerSink`.
/// Needs only the main run loop; the helper runs it via `NSApplication` (status item), dry runs bare.
@MainActor public final class TrackerRuntime {
    public struct Options: Sendable {
        public var config: TrackerConfig
        /// Show the Accessibility / Automation prompts. Off for dry runs.
        public var promptForPermissions: Bool
        public init(config: TrackerConfig = TrackerConfig(), promptForPermissions: Bool = true) {
            self.config = config; self.promptForPermissions = promptForPermissions
        }
    }

    private var engine: TrackerEngine
    private let sink: any TrackerSink
    private let options: Options
    private let ax = TrackerAX()
    private var frontApp: NSRunningApplication?
    private var tickTimer: DispatchSourceTimer?
    private var debounceTimer: DispatchSourceTimer?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var signalSources: [DispatchSourceSignal] = []
    private let browser = TrackerScriptRunner()
    /// Bumped per front-app observation; a browser reply applies only if no newer one started.
    private var observation = 0
    private var axTrusted = false

    /// Called on the main thread after every event the engine handles and on an Accessibility flip,
    /// so the status item can refresh its icon without a timer of its own.
    public var onChange: (() -> Void)?
    /// A live span is open (present, not paused, not gated off).
    public var isTracking: Bool { engine.live != nil }
    /// Pause end while paused, else nil. Expiry is noticed on the next event (≤ one 30 s tick).
    public var pausedUntilMs: Int64? { engine.pausedUntilMs.flatMap { $0 > TrackerSystem.wallMs() ? $0 : nil } }
    public var isAccessibilityTrusted: Bool { axTrusted }
    /// Start of the open span (nil = none) — changes at every span boundary.
    public var liveStartMs: Int64? { engine.live?.startMs }

    /// Idle threshold, applied live from Settings; the next event (≤ one 30 s tick) re-evaluates AFK.
    public var idleThresholdMs: Int64 {
        get { engine.config.idleThresholdMs }
        set { engine.config.idleThresholdMs = newValue }
    }

    public init(sink: any TrackerSink, options: Options = Options()) {
        self.sink = sink; self.options = options
        engine = TrackerEngine(config: options.config)
    }

    public func start() {
        if options.promptForPermissions {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        axTrusted = ax.isTrusted
        ax.onChange = { [weak self] in self?.observeFront() }

        let ws = NSWorkspace.shared.notificationCenter
        listen(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.activated(app)
        }
        let simple: [(NotificationCenter, Notification.Name, TrackerEvent)] = [
            (ws, NSWorkspace.willSleepNotification, .willSleep),
            (ws, NSWorkspace.didWakeNotification, .didWake),
            (ws, NSWorkspace.screensDidSleepNotification, .screensSlept),
            (ws, NSWorkspace.screensDidWakeNotification, .screensWoke),
            (ws, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (ws, NSWorkspace.sessionDidBecomeActiveNotification, .sessionActivated),
            (ws, NSWorkspace.willPowerOffNotification, .powerOff),
            // Undocumented but long-stable; loginwindow being excluded is the backstop.
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), .locked),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), .unlocked),
            (NotificationCenter.default, .NSSystemClockDidChange, .clockChanged),
        ]
        for (center, name, event) in simple {
            listen(center, name) { [weak self] _ in self?.send(event) }
        }
        listen(NotificationCenter.default, .NSSystemTimeZoneDidChange) { [weak self] _ in
            NSTimeZone.resetSystemTimeZone()
            self?.send(.timeZoneChanged)
        }
        // Accessibility grant/revoke, without polling.
        listen(DistributedNotificationCenter.default(), Notification.Name("com.apple.accessibility.api")) { [weak self] _ in
            // The flag flips shortly after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self?.recheckTrust() } }
        }

        let tick = DispatchSource.makeTimerSource(queue: .main)
        tick.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
        tick.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.recheckTrust()
                self?.observeFront() // title backstop (+ browser URL)
                self?.send(.tick)
            }
        }
        tick.resume()
        tickTimer = tick

        if let app = NSWorkspace.shared.frontmostApplication { activated(app) }
    }

    /// Closes the live span (`terminate`) and stops listening.
    public func stop() {
        send(.terminate)
        tickTimer?.cancel(); debounceTimer?.cancel()
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        ax.unbind()
    }

    /// Closes the live span and opens none until `untilMs`; nil resumes now. Not persisted here —
    /// the caller owns storage (`TrackerPauseSetting`).
    public func pause(untilMs: Int64?) { send(.pause(untilMs: untilMs)) }

    /// SIGTERM/SIGINT → `stop()` then `exit(0)`.
    public func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.stop(); exit(0) } }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: - Plumbing

    private func listen(_ center: NotificationCenter, _ name: Notification.Name,
                        _ handler: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated { handler(note) }
        }
        tokens.append((center, token))
    }

    private func activated(_ app: NSRunningApplication) {
        // Spotlight, Raycast, menu-bar popovers: previous app stays current.
        guard app.activationPolicy == .regular else { return }
        frontApp = app
        ax.bind(pid: app.processIdentifier)
        observeFront()
    }

    private func recheckTrust() {
        let now = ax.isTrusted
        guard now != axTrusted else { return }
        axTrusted = now
        if let app = frontApp { ax.bind(pid: app.processIdentifier) } // bind() no-ops when untrusted
        observeFront()
        onChange?()
    }

    private func observeFront() {
        guard let app = frontApp else { return }
        observation += 1
        let bundleId = app.bundleIdentifier
        let appName = app.localizedName ?? bundleId ?? "pid \(app.processIdentifier)"
        let axTitle = ax.title()
        guard TrackerBrowser.kind(bundleId) == .chromium, let bundleId else {
            send(.observed(TrackerBrowser.observation(bundleId: bundleId, appName: appName, axTitle: axTitle, scriptReply: nil)))
            return
        }
        // The script runs off the main thread (up to 2 s). The sample is taken now, so the switch is
        // timestamped when it happened; it's used only if the live span is unchanged by the time the
        // reply lands (else a fresh one). A newer observation or another front app supersedes the reply.
        let request = observation, pid = app.processIdentifier, taken = sample(), liveThen = engine.live
        browser.run(bundleId, ask: options.promptForPermissions) { [weak self] reply in
            guard let self, request == self.observation, self.frontApp?.processIdentifier == pid else { return }
            let obs = TrackerBrowser.observation(bundleId: bundleId, appName: appName, axTitle: axTitle, scriptReply: reply)
            self.send(.observed(obs), sample: self.engine.live == liveThen ? taken : nil)
        }
    }

    private func sample() -> TrackerSample {
        let idle = TrackerSystem.idleMs()
        let held = idle >= engine.config.idleThresholdMs
            && (frontApp.map { TrackerSystem.holdsDisplayAssertion(pid: $0.processIdentifier) } ?? false)
        let tz = TimeZone.current
        return TrackerSample(wallMs: TrackerSystem.wallMs(), monoMs: TrackerSystem.monoMs(), idleMs: idle,
                             heldActive: held, tzId: tz.identifier, tzOffsetS: tz.secondsFromGMT())
    }

    private func send(_ event: TrackerEvent, sample taken: TrackerSample? = nil) {
        var s = taken ?? sample()
        if event == .tick { s.session = TrackerSystem.session() } // the engine re-derives gates on ticks only
        let outputs = engine.handle(event, s)
        sink.apply(outputs)
        for o in outputs {
            if o == .armDebounce { armDebounce() }
            if o == .cancelDebounce { debounceTimer?.cancel(); debounceTimer = nil }
        }
        onChange?()
    }

    private func armDebounce() {
        debounceTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.debounceTimer?.cancel(); self?.debounceTimer = nil
                self?.send(.debounceFired)
            }
        }
        t.resume()
        debounceTimer = t
    }
}
