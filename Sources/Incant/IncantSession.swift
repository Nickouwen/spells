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
        var fix: IncantFixClients
        var document = "", held = ""
        var ghost: IncantGhost?
        var sentences = 0
        var diverted = false, why = "App changed"   // typing has stopped for good; the rest is held and copied
        var frozen = false   // you pressed a key or clicked after the release: the pending corrections are dropped
        var raw: [String] = []   // what Scribe committed, for the history
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

    /// A real key press or click (never Incant's own keystrokes) while this dictation's text is on screen. The
    /// field may no longer match what Incant typed — the cursor moved, a message was sent — so it deletes and
    /// retypes nothing more. While you're still speaking, the rest is held and copied at the end, as after an
    /// app switch. After the release, the pending corrections are dropped: what you saw when you pressed the
    /// key is what stays (an Enter right after letting go no longer gets the last rewrite in the next message).
    func userActed() {
        guard let s = stream, !(s.document.isEmpty && (s.ghost?.typed ?? "").isEmpty) else { return }   // nothing typed yet
        guard gesture.isListening else { stream!.frozen = true; return }
        guard !s.diverted else { return }
        stream!.diverted = true
        stream!.why = "You typed"
        if overlay.isCurrent(shown) { overlay.hint = "You typed · the rest will be copied" }
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
                Self.remember(raw: [text], text: result.text, pid: targetPid)
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
        stream!.raw.append(sentence)
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

    /// A partial: the sentence so far, typed at once minus fillers and its trailing mark. It isn't corrected
    /// mid-sentence (rewriting the words you're still saying several times a second read as the text
    /// overwriting itself); the pause's commit corrects it once.
    private func show(_ partial: String) {
        guard stream != nil, !stream!.diverted else { return }
        if stream!.ghost == nil { stream!.ghost = provisional(before: partial) }
        apply(stream!.ghost!.partial(partial))
    }

    /// Until a pass has seen it next to the settled text, a new segment continues the previous one: a
    /// pause short enough to split a sentence must not show a full stop even for a moment, and the words
    /// read as a continuation ("…the tests so then we"), so the pause's commit is the one rewrite.
    private func provisional(before text: String) -> IncantGhost {
        let j = IncantStream.joiner(after: stream?.document ?? "", before: text)
        return j == ". " ? IncantGhost(lead: " ", continues: true) : IncantGhost(lead: j)
    }

    /// Stream mode's cutoffs: a commit revises text that's already typed; the final pass runs once, after the release.
    private static let commitCutoffMs = 1500, finalCutoffMs = 2500
    /// The final pass retypes at most this much of the dictation's tail, and never across a line break.
    private static let finalRetypeMax = 240

    /// A commit: the sentence's final form (corrected) replaces what its partials typed, then it's settled.
    private func settle(_ sentence: String) async {
        guard let s = stream else { return }
        let (result, lead) = await s.fix.seam(after: IncantStream.context(s.document), sentence, settings: settings.seam,
                                              cutoffMs: Self.commitCutoffMs)
        let text = result.text
        guard !Task.isCancelled, stream != nil else { return }
        if stream!.diverted {   // nothing is typed into the other app; the rest is copied on release
            let j = lead ?? IncantStream.joiner(after: stream!.document + stream!.held, before: text)
            if !text.isEmpty { stream!.held += j + IncantStream.cased(text, after: j) }
            return
        }
        // The model's joiner when it saw the seam; otherwise (a failed pass, or one redone alone) the plain
        // rule — ". " after a bare word — with the first word cased to match, so a seam is never "tests So".
        let j = lead ?? IncantStream.joiner(after: stream!.document, before: text)
        if stream!.ghost == nil { stream!.ghost = IncantGhost(lead: j) }   // committed before any partial (a quick flush)
        apply(stream!.ghost!.commit(IncantStream.cased(text, after: j), lead: j))
        stream!.document += stream!.ghost!.typed
        if !result.text.isEmpty { stream!.sentences += 1 }
        stream!.ghost = nil
        SupportLog.incant.info("stream sentence \(self.stream!.sentences): fix \(result.ms) ms (\(result.source.rawValue, privacy: .public))")
    }

    /// The dictation is over: the model sees all of it, complete, and the tail that differs is retyped
    /// (a joiner it now hears differently, a question mark, a correction that spanned a pause). Bounded:
    /// a difference further back than `finalRetypeMax` characters, or one that would delete across a
    /// line break, is left as typed.
    private func finalPass() async {
        guard let s = stream, !s.diverted, !s.frozen, settings.mode != .off, !s.document.isEmpty else { return }
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
        guard !e.isEmpty, stream != nil, !stream!.frozen else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid else {
            stream!.diverted = true
            return
        }
        IncantTyper.replace(delete: e.delete, with: e.text)
    }

    /// The release in stream mode: what was said since the last pause settles after the sentences in
    /// flight, then the whole dictation gets one last pass; text held back after an app switch is
    /// copied for a manual ⌘V.
    private func finishStream(_ last: String, shown: Int, committedMs: Int64, released: Int64) async {
        if !last.isEmpty { stream?.raw.append(last); chain(shown) { await $0.settle(last) } }
        chain(shown) { await $0.finalPass() }
        await stream?.chain?.value
        guard self.shown == shown, let s = stream else { return }
        stream = nil
        if !s.held.isEmpty {
            IncantPaster.copy(IncantStream.unjoined(s.held))
            if overlay.isCurrent(shown) { overlay.fail("\(s.why): rest copied") }
        }
        Self.remember(raw: s.raw, text: s.document + s.held, pid: targetPid)
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
        // The sentence in flight was provisional: take it back (settled sentences stay) — unless a key of yours
        // cancelled it (`userActed` diverted the stream first): then the cursor may have moved, and it stays.
        if let g = stream?.ghost, stream?.diverted == false, !g.typed.isEmpty,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid {
            IncantTyper.delete(g.typed.count)
        }
        stream = nil
        overlay.hide(shown, after: 0)
    }

    /// Where the last dictations are kept (`IncantHistory`).
    nonisolated static var historyURL: URL { SupportPaths.current().home.appending(path: "incant/history.jsonl") }

    private static func remember(raw: [String], text: String, pid: pid_t?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } ?? ""
        do { try IncantHistory.append(IncantHistoryEntry(at: Date(), app: app, raw: raw, text: text), to: historyURL) }
        catch { SupportLog.incant.error("history not saved: \(error.localizedDescription, privacy: .public)") }
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
