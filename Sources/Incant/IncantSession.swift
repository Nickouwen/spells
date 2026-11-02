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
    private var startedMs: Int64 = 0   // this dictation's start: the key-state check is off once it has typed
    private var targetPid: pid_t?   // the app that was frontmost at start: the paste goes there or nowhere
    private var stream: Stream?   // stream mode's state for this dictation (nil = one paste on release)
    var onListening: (Bool) -> Void = { _ in }

    /// Stream mode: the settled text (the next joiner depends on how it ends), the sentence in flight,
    /// the chain that applies edits in order, and the text held back once you switched apps.
    private struct Stream {
        var fix: IncantFixClients, live: IncantFixClients
        var document = "", held = ""
        var ghost: IncantGhost?
        var sentences = 0, segment = 0
        var diverted = false, correcting = false
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
        // trust the system's key state over our event history — until this dictation has typed, which
        // leaves that state saying Fn is up for good (`IncantTyper.lastPostMs`). From then on only the
        // tap's flagsChanged, which the physical release always produces, ends the dictation.
        if fnHeld, IncantTyper.lastPostMs < startedMs,
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
        startedMs = incantNowMs()
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
        stream = streaming ? Stream(fix: fix, live: IncantFixClients(settings: settings.live)) : nil
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

    /// A partial: the sentence so far, typed at once minus fillers and its trailing mark; the live pass
    /// then cleans it in the background.
    private func show(_ partial: String) {
        guard stream != nil, !stream!.diverted else { return }
        if stream!.ghost == nil { stream!.ghost = IncantGhost(lead: provisionalLead(before: partial)) }
        apply(stream!.ghost!.partial(partial))
        correctLive()
    }

    /// Until a pass has seen it next to the settled text, a new segment continues the previous one: a
    /// pause short enough to split a sentence must not show a full stop even for a moment.
    private func provisionalLead(before text: String) -> String {
        let j = IncantStream.joiner(after: stream?.document ?? "", before: text)
        return j == ". " ? " " : j
    }

    /// One pass over `raw` with the settled text's tail in front, so the model decides whether the pause
    /// ended a sentence: (cleaned words, the joiner it chose or nil, the pass). A pass that didn't run
    /// (cutoff, failure) gives the raw words; one that rewrote the settled text is redone on the words alone.
    private func pass(_ clients: IncantFixClients, _ raw: String, settings: IncantSettings, cutoffMs: Int) async -> (text: String, lead: String?, result: IncantFixResult) {
        let ctx = IncantStream.context(stream?.document ?? "")
        guard !ctx.isEmpty else { let r = await clients.run(raw, settings: settings, cutoffMs: cutoffMs); return (r.text, nil, r) }
        let r = await clients.run(ctx + " " + raw, settings: settings, cutoffMs: cutoffMs)
        guard r.source == .primary || r.source == .fallback else {
            return (IncantFix.withoutTrailingPeriod(IncantFillers.strip(raw)), nil, r)
        }
        if let (joiner, text) = IncantStream.split(answer: r.text, context: ctx) { return (text, joiner, r) }
        SupportLog.incant.info("pass rewrote the settled text; redoing the sentence alone")
        let alone = await clients.run(raw, settings: settings, cutoffMs: cutoffMs)
        return (alone.text, nil, alone)
    }

    /// Stream mode's cutoffs: the live pass must land before the next partial (~1 s); a commit revises
    /// text that's already typed, so it may take longer; the final pass runs once, after the release.
    private static let liveCutoffMs = 900, commitCutoffMs = 1500, finalCutoffMs = 2500
    /// The final pass retypes at most this much of the dictation's tail, and never across a line break.
    private static let finalRetypeMax = 240

    /// One live pass at a time, always on the newest partial: its answer replaces the raw words it was
    /// given (`IncantGhost.live`), and a newer partial by then starts the next pass. A pass that ran
    /// past the cutoff or failed (rate limit, offline) changes nothing: the raw words stand.
    private func correctLive() {
        guard let s = stream, !s.correcting, settings.mode != .off, let g = s.ghost, !g.raw.isEmpty else { return }
        stream!.correcting = true
        let raw = g.raw, segment = s.segment, live = s.live, shown = shown, settings = settings.live
        Task { [weak self] in
            guard let self else { return }
            let (text, lead, r) = await self.pass(live, raw, settings: settings, cutoffMs: Self.liveCutoffMs)
            guard self.shown == shown, self.stream != nil else { return }
            self.stream!.correcting = false
            if r.source == .primary || r.source == .fallback {
                SupportLog.incant.info("live fix \(r.ms) ms (\(r.source.rawValue, privacy: .public))")
                self.chain(shown) { me in
                    guard me.stream?.segment == segment, me.stream?.ghost != nil else { return }   // the sentence has settled since
                    me.apply(me.stream!.ghost!.live(text, of: raw, lead: lead))
                }
            }
            if self.stream?.ghost?.raw != raw { self.correctLive() }
        }
    }

    /// A commit: the sentence's final form (corrected) replaces what its partials typed, then it's settled.
    private func settle(_ sentence: String) async {
        guard let s = stream else { return }
        let (text, lead, result) = await pass(s.fix, sentence, settings: settings.perSentence, cutoffMs: Self.commitCutoffMs)
        guard !Task.isCancelled, stream != nil else { return }
        if stream!.diverted {   // nothing is typed into the other app; the rest is copied on release
            if !text.isEmpty { stream!.held += (lead ?? IncantStream.joiner(after: stream!.held, before: text)) + text }
            return
        }
        if stream!.ghost == nil {   // committed before any partial (a quick flush): the whole sentence lands now
            stream!.ghost = IncantGhost(lead: provisionalLead(before: text))
        }
        apply(stream!.ghost!.commit(text, lead: lead))
        stream!.document += stream!.ghost!.typed
        if !result.text.isEmpty { stream!.sentences += 1 }
        stream!.ghost = nil
        stream!.segment += 1   // a live answer still in flight for this sentence is dropped
        SupportLog.incant.info("stream sentence \(self.stream!.sentences): fix \(result.ms) ms (\(result.source.rawValue, privacy: .public))")
    }

    /// The dictation is over: the model sees all of it, complete, and the tail that differs is retyped
    /// (a joiner it now hears differently, a question mark, a correction that spanned a pause). Bounded:
    /// a difference further back than `finalRetypeMax` characters, or one that would delete across a
    /// line break, is left as typed.
    private func finalPass() async {
        guard let s = stream, !s.diverted, settings.mode != .off, !s.document.isEmpty else { return }
        let r = await s.fix.run(s.document, settings: settings.perSentence, cutoffMs: Self.finalCutoffMs)
        guard !Task.isCancelled, stream != nil, r.source == .primary || r.source == .fallback, !r.text.isEmpty else { return }
        let before = stream!.document, after = IncantGhost.withoutPauseDots(r.text)
        let common = zip(before, after).prefix { $0 == $1 }.count
        let tail = before.dropFirst(common)
        guard before != after, tail.count <= Self.finalRetypeMax, !tail.contains(where: \.isNewline) else {
            SupportLog.incant.info("final pass \(r.ms) ms: \(before == after ? "no change" : "change too far back; left as typed")")
            return
        }
        apply(IncantGhost.Edit(delete: tail.count, text: String(after.dropFirst(common))))
        stream!.document = after
        SupportLog.incant.info("final pass \(r.ms) ms (\(r.source.rawValue, privacy: .public)): retyped \(tail.count) chars")
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
    /// flight, then the whole dictation gets one last pass; text held back after an app switch is
    /// copied for a manual ⌘V.
    private func finishStream(_ last: String, shown: Int, committedMs: Int64, released: Int64) async {
        if !last.isEmpty { chain(shown) { await $0.settle(last) } }
        chain(shown) { await $0.finalPass() }
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
