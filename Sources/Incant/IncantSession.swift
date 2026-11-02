import AppKit
import SpellsKit
import IncantCore

/// Monotonic ms (the gesture's clock and the timings).
func incantNowMs() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000) }

/// One dictation at a time: Fn gestures → open socket + mic (`start`), commit → correct → paste
/// (`finish`), or discard (`cancel`). In stream mode (`settings.stream`) Scribe commits on each pause
/// and every sentence is corrected and pasted as it lands, in order, while you keep talking; the
/// release flushes what was said since the last pause. Typed text is never revised. Logs timings
/// only — never text.
@MainActor final class IncantSession {
    private var gesture = IncantGesture()
    private let mic = IncantMic()
    private let overlay = IncantOverlay()
    private var socket: IncantScribeSocket?
    private var fix: IncantFixClients?
    private var settings = IncantSettings()
    private var timer: Timer?
    private var shown = 0   // this dictation's overlay token
    private var fnHeld = false   // Fn is down per our events; tick() re-checks the real key state
    private var targetPid: pid_t?   // the app that was frontmost at start: the paste goes there or nowhere
    private var stream: Stream?   // stream mode's state for this dictation (nil = one paste on release)
    var onListening: (Bool) -> Void = { _ in }

    /// Stream mode: what has been typed so far (the joiner before the next sentence depends on how it
    /// ends), the chain that lands sentences in order, and the text held back once you switched apps.
    private struct Stream {
        var typed = "", held = ""
        var sentences = 0
        var chain: Task<Void, Never>?
    }

    var isListening: Bool { gesture.isListening }

    func prepare() { mic.prepare() }

    func handle(_ event: IncantKeyEvent) {
        if event == .fnDown { fnHeld = true } else if event == .fnUp { fnHeld = false }
        apply(gesture.handle(event, atMs: incantNowMs()))
    }

    private func tick() {
        // A missed Fn-up (screen lock, fast user switch, sleep with Fn down) would leave the mic open:
        // trust the hardware state over our event history.
        if fnHeld, !CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn) {
            SupportLog.incant.info("Fn-up missed; resyncing from key state")
            handle(.fnUp)
            guard gesture.isListening else { return }
        }
        overlay.level = mic.level
        if gesture.isHandsFree, overlay.hint == nil { overlay.hint = "Hands-free · tap Fn to finish" }
        apply(gesture.tick(atMs: incantNowMs()))
    }

    private func apply(_ action: IncantGestureAction) {
        switch action {
        case .start: start()
        case .finish: finish()
        case .cancel: cancel()
        case .none: break
        }
    }

    private func start() {
        settings = Self.loadSettings()
        shown = overlay.show()
        guard let key = SupportKeychain.read(SupportKeychain.elevenLabs) else {
            return abort("No ElevenLabs key — add it in Spells")
        }
        let overlay = overlay, shown = shown, streaming = settings.stream
        let socket = IncantScribeSocket(apiKey: key, keyterms: settings.keyterms, vad: streaming,
                                        onPartial: { t in Task { @MainActor in if overlay.isCurrent(shown) { overlay.text = t } } },
                                        onCommitted: { [weak self] t in Task { @MainActor in self?.heard(t, shown: shown) } },
                                        onError: { m in Task { @MainActor in if overlay.isCurrent(shown) { overlay.fail(m) } } })
        do { try mic.start { socket.send($0) } } catch {
            socket.cancel()
            SupportLog.incant.error("mic start failed: \(error.localizedDescription, privacy: .public)")
            return abort("Microphone unavailable")
        }
        self.socket = socket
        stream?.chain?.cancel()
        stream = streaming ? Stream() : nil
        targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        fix = IncantFixClients(settings: settings)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        onListening(true)
    }

    private func finish() {
        let released = incantNowMs()
        stopListening()
        guard let socket, let fix else { _ = mic.stop(); return overlay.hide(shown) }
        self.socket = nil; self.fix = nil
        let settings = settings, overlay = overlay, shown = shown, targetPid = targetPid, mic = mic
        let streaming = stream != nil
        Task {
            // Keep the mic 60 ms past the release: people let go as the last word ends, and the
            // engine's last buffer (~40 ms) would otherwise be lost.
            // ponytail: a new Fn press inside these 60 ms would have its mic stopped by this tail; make the
            // mic hand off between sessions if back-to-back dictations ever need that.
            try? await Task.sleep(for: .milliseconds(60))
            let rest = mic.stop()
            let text = await socket.finish(rest)
            let committedMs = incantNowMs() - released
            if streaming { return await finishStream(text, fix: fix, shown: shown, committedMs: committedMs, released: released) }
            guard !text.isEmpty else {
                SupportLog.incant.info("release→committed \(committedMs) ms, nothing heard")
                return overlay.hide(shown)
            }
            if overlay.isCurrent(shown),
               settings.mode == .always || (settings.mode == .whenNeeded && IncantCues.heard(text, cues: settings.cues)) {
                overlay.hint = "Fixing…"
            }
            let result = await fix.run(text, settings: settings)
            if !result.text.isEmpty {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid {
                    IncantPaster.paste(result.text)
                } else {   // you switched apps mid-dictation: don't type into the new one, leave it to paste
                    IncantPaster.copy(result.text)
                    if overlay.isCurrent(shown) { overlay.fail("App changed: text copied") }
                }
            }
            SupportLog.incant.info("""
                release→committed \(committedMs) ms, fix \(result.ms) ms (\(result.source.rawValue, privacy: .public)), \
                total \(incantNowMs() - released) ms
                """)
            overlay.hide(shown)
        }
    }

    // MARK: Stream mode

    /// A pause committed one sentence. It's corrected and pasted after the previous one has landed,
    /// while you keep talking; the grey line clears for the next.
    private func heard(_ sentence: String, shown: Int) {
        guard stream != nil, self.shown == shown, let fix else { return }
        if overlay.isCurrent(shown) { overlay.text = "" }
        let previous = stream?.chain
        stream?.chain = Task { [weak self] in
            await previous?.value
            await self?.place(sentence, fix: fix, shown: shown)
        }
    }

    /// Corrects one sentence and pastes it after what's there — or holds it, once the app changed.
    private func place(_ sentence: String, fix: IncantFixClients, shown: Int) async {
        let result = await fix.run(sentence, settings: settings.perSentence)
        guard !Task.isCancelled, self.shown == shown, stream != nil, !result.text.isEmpty else { return }
        let piece = IncantStream.joiner(after: stream!.typed, before: result.text) + result.text
        stream!.typed += piece
        stream!.sentences += 1
        if stream!.held.isEmpty, NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid {
            IncantPaster.paste(piece)
        } else {   // you switched apps: the rest is copied on release, not typed into the new one
            stream!.held += piece
        }
        SupportLog.incant.info("stream sentence \(self.stream!.sentences): fix \(result.ms) ms (\(result.source.rawValue, privacy: .public))")
    }

    /// The release in stream mode: sentences still in flight land first, then what was said since the
    /// last pause.
    private func finishStream(_ last: String, fix: IncantFixClients, shown: Int, committedMs: Int64, released: Int64) async {
        await stream?.chain?.value
        if !last.isEmpty { await place(last, fix: fix, shown: shown) }
        guard self.shown == shown, let s = stream else { return }
        stream = nil
        if !s.held.isEmpty {
            IncantPaster.copy(IncantStream.unjoined(s.held))
            if overlay.isCurrent(shown) { overlay.fail("App changed: rest copied") }
        }
        SupportLog.incant.info("""
            release→committed \(committedMs) ms, \(s.sentences) sentence(s) streamed, \
            total \(incantNowMs() - released) ms
            """)
        overlay.hide(shown)
    }

    private func cancel() {
        _ = mic.stop()
        stopListening()
        socket?.cancel()
        socket = nil; fix = nil
        stream?.chain?.cancel()   // a sentence mid-correction isn't typed; what's typed stays
        stream = nil
        overlay.hide(shown, after: 0)
    }

    /// Start failed: reset the gesture (so Fn-up doesn't finish a session that never began) and say why.
    private func abort(_ message: String) {
        gesture = IncantGesture(timing: gesture.timing)
        overlay.fail(message)
        overlay.hide(shown)
    }

    private func stopListening() {
        timer?.invalidate(); timer = nil
        overlay.level = 0
        onListening(false)
    }

    /// Current settings from Incant's own file (defaults if it doesn't exist yet). Read at each key-down,
    /// so an edit in the settings window applies to the next dictation.
    nonisolated static func loadSettings() -> IncantSettings { IncantSettings.load(SpellSettingsFile.incant().all()) }
}
