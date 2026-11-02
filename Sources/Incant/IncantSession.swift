import AppKit
import SpellsKit
import IncantCore

/// Monotonic ms (the gesture's clock and the timings).
func incantNowMs() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000) }

/// One dictation at a time: Fn gestures → open socket + mic (`start`), commit → correct → paste
/// (`finish`), or discard (`cancel`). In stream mode (`settings.stream`) words are typed as Scribe
/// hears them, each pause commits the sentence and its corrected form revises what the partials typed,
/// and the release flushes what was said since the last pause. Settled sentences are never revised.
/// Logs timings only — never text.
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

    /// Stream mode: the settled text (the next joiner depends on how it ends), the sentence in flight,
    /// the chain that applies edits in order, and the text held back once you switched apps.
    private struct Stream {
        var fix: IncantFixClients
        var document = "", held = ""
        var ghost: IncantGhost?
        var sentences = 0
        var diverted = false
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
        // trust the hardware state over our event history — except right after our own keystrokes,
        // which clobber that state (`IncantTyper.lastPostMs`); the real Fn-up still comes through the tap.
        if fnHeld, incantNowMs() - IncantTyper.lastPostMs > IncantTyper.settleMs,
           !CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn) {
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
                                        onPartial: { [weak self] t in Task { @MainActor in
                                            if overlay.isCurrent(shown) { overlay.text = t }
                                            if streaming { self?.heardPartial(t, shown: shown) }
                                        } },
                                        onCommitted: { [weak self] t in Task { @MainActor in self?.heard(t, shown: shown) } },
                                        onError: { m in Task { @MainActor in if overlay.isCurrent(shown) { overlay.fail(m) } } })
        do { try mic.start { socket.send($0) } } catch {
            socket.cancel()
            SupportLog.incant.error("mic start failed: \(error.localizedDescription, privacy: .public)")
            return abort("Microphone unavailable")
        }
        self.socket = socket
        stream?.chain?.cancel()
        targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let fix = IncantFixClients(settings: settings)
        self.fix = fix
        stream = streaming ? Stream(fix: fix) : nil
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
            if streaming { return await finishStream(text, shown: shown, committedMs: committedMs, released: released) }
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

    /// Words are typed as Scribe hears them: each partial extends the sentence in flight (`IncantGhost`),
    /// a pause commits it, the corrected sentence revises its tail, and the next one starts after the
    /// joiner. Everything that touches the target app runs on one chain, in socket order, so a
    /// correction still in flight is never overtaken by the next sentence's words.
    private func heardPartial(_ text: String, shown: Int) {
        guard self.shown == shown, stream != nil, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        chain(shown) { $0.show(text) }
    }

    private func heard(_ sentence: String, shown: Int) {
        guard self.shown == shown, stream != nil else { return }
        if overlay.isCurrent(shown) { overlay.text = "" }
        chain(shown) { await $0.settle(sentence) }
    }

    private func chain(_ shown: Int, _ work: @escaping @MainActor (IncantSession) async -> Void) {
        let previous = stream?.chain
        stream?.chain = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.shown == shown, self.stream != nil else { return }
            await work(self)
        }
    }

    /// A partial: the sentence so far, typed minus its trailing mark.
    private func show(_ partial: String) {
        guard stream != nil, !stream!.diverted else { return }
        if stream!.ghost == nil {
            stream!.ghost = IncantGhost(lead: IncantStream.joiner(after: stream!.document, before: partial))
        }
        apply(stream!.ghost!.partial(partial))
    }

    /// A commit: the sentence's final form (corrected) replaces what its partials typed, then it's settled.
    private func settle(_ sentence: String) async {
        guard let s = stream else { return }
        let result = await s.fix.run(sentence, settings: settings.perSentence)
        guard !Task.isCancelled, stream != nil else { return }
        if stream!.diverted {   // nothing is typed into the other app; the rest is copied on release
            if !result.text.isEmpty {
                stream!.held += IncantStream.joiner(after: stream!.held, before: result.text) + result.text
            }
            return
        }
        if stream!.ghost == nil {   // committed before any partial (a quick flush): the whole sentence lands now
            stream!.ghost = IncantGhost(lead: IncantStream.joiner(after: stream!.document, before: result.text))
        }
        apply(stream!.ghost!.commit(result.text))
        stream!.document += stream!.ghost!.typed
        if !result.text.isEmpty { stream!.sentences += 1 }
        stream!.ghost = nil
        SupportLog.incant.info("stream sentence \(self.stream!.sentences): fix \(result.ms) ms (\(result.source.rawValue, privacy: .public))")
    }

    /// Types an edit into the target app — unless you've switched apps, which ends the typing for good.
    private func apply(_ e: IncantGhost.Edit) {
        guard !e.isEmpty, stream != nil else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid else {
            stream!.diverted = true
            return
        }
        IncantTyper.delete(e.delete)
        IncantTyper.type(e.text)
    }

    /// The release in stream mode: what was said since the last pause settles after the sentences in
    /// flight; text held back after an app switch is copied for a manual ⌘V.
    private func finishStream(_ last: String, shown: Int, committedMs: Int64, released: Int64) async {
        if !last.isEmpty { chain(shown) { await $0.settle(last) } }
        await stream?.chain?.value
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
        stream?.chain?.cancel()
        // The sentence in flight was provisional: take it back (settled sentences stay).
        if let g = stream?.ghost, stream?.diverted == false, !g.typed.isEmpty,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid {
            IncantTyper.delete(g.typed.count)
        }
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
