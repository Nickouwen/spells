import AppKit
import SpellsKit
import SpellsUI
import IncantCore
import ScryCore
import SwiftUI

/// The live side of a recording (when `settings.live`): two Scribe v2 Realtime sockets (your mic → "You",
/// system audio → "Them") streaming each utterance in grey and committing it on the pause, a notes area (→ `ScryCapture.userNotes`), and "What did
/// I miss?" through Cerebras. The sockets start the first time the panel opens (the note comes from the
/// batch pass either way, so an unopened panel costs nothing) and run until the recording stops.
@MainActor final class ScryLive {
    let model: ScryLiveModel
    private var sockets: [ScryLiveSocket] = []
    private var panel: NSPanel?
    private let started: Date
    private let recorder: ScryRecorder, keyterms: [String], systemAudio: Bool
    private let onStop: () -> Void, onDiscard: () -> Void
    /// The capture folder: your notes are saved there (`notes.txt`) as you type, so a crash or a quit
    /// mid-meeting keeps them (`ScryCaptures.recoverCrashed` reads the file).
    private let dir: URL
    private var notesSave: Task<Void, Never>?

    /// `app`: the call app's display name (nil = in person). `onStop` / `onDiscard`: the menu's actions, for the panel's buttons.
    init(recorder: ScryRecorder, keyterms: [String], systemAudio: Bool, dir: URL, app: String?, startedAt: Date,
         onStop: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.recorder = recorder; self.keyterms = keyterms; self.systemAudio = systemAudio; self.dir = dir
        started = startedAt; self.onStop = onStop; self.onDiscard = onDiscard
        model = ScryLiveModel(app: app, startedAt: startedAt)
    }

    static let notesFile = "notes.txt"

    /// Debounced: the file catches up a second after the last keystroke.
    func notesChanged() {
        notesSave?.cancel()
        notesSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNotes()
        }
    }

    private func saveNotes() {
        let url = dir.appending(path: Self.notesFile)
        do { try model.notes.write(to: url, atomically: true, encoding: .utf8) } catch {
            SupportLog.scry.error("live notes not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startSockets() {
        guard sockets.isEmpty, model.problem == nil else { return }
        guard let key = SupportKeychain.read(SupportKeychain.elevenLabs) else {
            model.problem = "No ElevenLabs key — the live transcript is off. The note still covers the whole call."
            return
        }
        let fatal: @Sendable (String) -> Void = { [weak self] m in Task { @MainActor in self?.model.problem = m } }
        let you = ScryLiveSocket(apiKey: key, keyterms: keyterms, onFatal: fatal) { [weak self] text, final in
            Task { @MainActor in self?.add("You", text, final: final) }
        }
        sockets = [you]
        var system: (@Sendable (Data) -> Void)?
        if systemAudio {
            let them = ScryLiveSocket(apiKey: key, keyterms: keyterms, onFatal: fatal) { [weak self] text, final in
                Task { @MainActor in self?.add("Them", text, final: final) }
            }
            sockets.append(them)
            system = { them.send($0) }
        }
        recorder.feed(mic: { you.send($0) }, system: system)
        model.liveSince = Date()
    }

    /// A partial replaces the speaker's in-progress line; the commit (on the pause) makes it a segment.
    private func add(_ speaker: String, _ text: String, final: Bool) {
        guard final else { model.partial[speaker] = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text; return }
        model.partial[speaker] = nil
        // ponytail: a VAD commit arrives at the end of the utterance, so start = end = commit time.
        let t = Date().timeIntervalSince(started)
        model.segments.append(ScrySegment(speaker: speaker, start: t, end: t, text: text))
    }

    /// The pill's level timer feeds this too (0…1).
    func pushLevel(_ level: Double) { model.level = level }

    func show() {
        startSockets()
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: true)
            p.title = "Scry — live"
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.minSize = NSSize(width: 340, height: 460)
            p.contentView = NSHostingView(rootView: ScryLiveView(model: model, onCatchUp: { [weak self] in self?.catchUp() },
                                                                 onNotesChanged: { [weak self] in self?.notesChanged() },
                                                                 onStop: onStop, onDiscard: onDiscard))
            if let v = NSScreen.main?.visibleFrame { p.setFrameTopLeftPoint(NSPoint(x: v.maxX - 420, y: v.maxY - 20)) }
            panel = p
        }
        NSApp.activate()   // you type in it
        // The panel, its transcript and your notes live as long as the recording: closing or minimising it
        // only hides it, and "Show live panel" (or the pill) brings the same one back.
        if panel?.isMiniaturized == true { panel?.deminiaturize(nil) }
        panel?.makeKeyAndOrderFront(nil)
    }

    func stop() {
        sockets.forEach { $0.stop() }
        notesSave?.cancel()
        if !model.notes.isEmpty { saveNotes() }
        panel?.close()
    }

    private func catchUp() {
        model.busy = true
        let segments = model.segments
        Task {
            do { model.catchUp = try await ScryCerebras.catchUp(segments) } catch {
                SupportLog.scry.error("catch-up failed: \(String(describing: error), privacy: .public)")
                model.catchUp = "Couldn't get a catch-up right now."
            }
            model.busy = false
        }
    }
}

@Observable @MainActor final class ScryLiveModel {
    let app: String?
    let startedAt: Date
    var segments: [ScrySegment] = []
    /// Speaker → what they're saying right now, before the pause commits it.
    var partial: [String: String] = [:]
    var notes = ""
    var catchUp = ""
    var busy = false
    /// Why there is no live transcript (no key, out of credits); nil while it works.
    var problem: String?
    /// When the sockets came up; nil until the panel first opened.
    var liveSince: Date?
    /// The mic's current level, 0…1.
    var level: Double = 0

    init(app: String?, startedAt: Date) { self.app = app; self.startedAt = startedAt }
}

/// The panel: a recording header (pulse, source, elapsed, level), the transcript as speaker-tagged rows
/// with the in-progress line in grey, an optional catch-up card, your notes, and the actions the menu has.
struct ScryLiveView: View {
    @Bindable var model: ScryLiveModel
    var onCatchUp: () -> Void
    var onNotesChanged: () -> Void
    var onStop: () -> Void
    var onDiscard: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            if let p = model.problem { problem(p) }
            transcript
            if !model.catchUp.isEmpty { catchUpCard }
            notes
            footer
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.xl + Theme.Space.s)   // under the transparent title bar
        .padding(.bottom, Theme.Space.l)
        .frame(minWidth: 340, minHeight: 460)
        .background(Theme.canvas)
        .tint(Theme.ink)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
        .onChange(of: model.notes) { _, _ in onNotesChanged() }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Circle().fill(Theme.StateLayer.distraction).frame(width: 8, height: 8).opacity(pulse ? 1 : 0.3)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Recording").textRole(.heading)
                Text(model.app.map { "\($0) call" } ?? "In person").textRole(.label, Theme.inkTertiary)
            }
            Spacer()
            LevelMeter(level: model.level)
            TimelineView(.periodic(from: model.startedAt, by: 1)) { ctx in
                Text(Self.clock(ctx.date.timeIntervalSince(model.startedAt))).textRole(.metric)
            }
        }
    }

    private func problem(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.StateLayer.warn)
            Text(text).textRole(.label, Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.StateLayer.warn.over(Theme.surface, alpha: 0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    private var transcript: some View {
        GeometryReader { geo in
            ScrollView {
                transcriptBody
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)   // top until it fills, then pinned to the newest line
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
    }

    @ViewBuilder private var transcriptBody: some View {
            if model.segments.isEmpty, model.partial.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "waveform").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.inkTertiary)
                    Text(model.liveSince == nil ? "Connecting…" : "Listening").textRole(.bodyEmph, Theme.inkSecondary)
                    Text("Each thing said appears here as it's said, and settles when the speaker pauses.")
                        .textRole(.label, Theme.inkTertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.xxl)
            } else {
                LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(Array(model.segments.enumerated()), id: \.offset) { _, s in
                        row(speaker: s.speaker, text: s.text, at: s.start, partial: false)
                    }
                    ForEach(model.partial.keys.sorted().reversed(), id: \.self) { k in   // You, then Them
                        row(speaker: k, text: model.partial[k] ?? "", at: nil, partial: true)
                    }
                }
                .padding(Theme.Space.m)
                .textSelection(.enabled)
            }
    }

    private func row(speaker: String, text: String, at start: TimeInterval?, partial: Bool) -> some View {
        let you = speaker == "You"
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(start.map(Self.clock) ?? "now").textRole(.mono, Theme.inkTertiary).frame(width: 40, alignment: .trailing)
            Text(speaker).textRole(.micro, you ? Theme.ink : Theme.StateLayer.meeting)
                .padding(.horizontal, Theme.Space.xs + 2).padding(.vertical, 2)
                .background((you ? Theme.ink : Theme.StateLayer.meeting).over(Theme.surface, alpha: 0.12),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            Text(text).textRole(.body, partial ? Theme.inkTertiary : Theme.ink).italic(partial)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var catchUpCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("What you missed").textRole(.heading)
                Spacer()
                IconButton(symbol: "xmark", help: "Dismiss") { model.catchUp = "" }
            }
            ScrollView { Text(model.catchUp).textRole(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 140)
        }
        .card(padding: Theme.Space.m)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Your notes").textRole(.label, Theme.inkTertiary)
            ZStack(alignment: .topLeading) {
                if model.notes.isEmpty {
                    Text("Anything you type here is kept with the meeting note.").textRole(.body, Theme.inkTertiary)
                        .padding(.horizontal, Theme.Space.s + 1).padding(.vertical, Theme.Space.s)
                }
                TextEditor(text: $model.notes)
                    .font(.body).foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Space.xs)
            }
            .frame(minHeight: 72, maxHeight: 120)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            Button {
                onCatchUp()
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    if model.busy { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                    Text("What did I miss?")
                }
                .lineLimit(1).fixedSize()
            }
            .buttonStyle(RewindButtonStyle())
            .disabled(model.busy || model.segments.isEmpty)
            Spacer()
            Button(action: onDiscard) { Text("Discard").lineLimit(1).fixedSize() }.buttonStyle(RewindButtonStyle())
            Button(action: onStop) { Text("Stop & make notes").lineLimit(1).fixedSize() }.buttonStyle(ScryFilledButtonStyle())
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Five bars that fill with the mic level.
struct LevelMeter: View {
    var level: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let on = level >= Double(i + 1) / 5.5
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(on ? Theme.StateLayer.live : Theme.hairline)
                    .frame(width: 3, height: CGFloat(6 + i * 3))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

/// The primary action: ink on canvas, inverted.
struct ScryFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textRole(.bodyEmph, Theme.canvas)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.xs + Theme.Space.xxs)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// One continuous Scribe v2 Realtime socket (VAD commits). Audio is sent in ~100 ms chunks; chunks sent
/// before `session_started` are queued (up to ~30 s). A dropped connection reconnects after 2 s while
/// running, except after `quota_exceeded`, which stops it and reports through `onFatal`. Never logs text —
/// only event types.
final class ScryLiveSocket: @unchecked Sendable {
    private let apiKey: String, keyterms: [String], onFatal: @Sendable (String) -> Void
    /// (text, final): partials as the utterance grows (final false), then its commit.
    private let onText: @Sendable (String, Bool) -> Void
    private let lock = NSLock()
    // Guarded by `lock`.
    private var ws: URLSessionWebSocketTask?, open = false, running = true, pending = Data(), queued: [String] = []

    init(apiKey: String, keyterms: [String], onFatal: @escaping @Sendable (String) -> Void,
         onText: @escaping @Sendable (String, Bool) -> Void) {
        self.apiKey = apiKey; self.keyterms = keyterms; self.onFatal = onFatal; self.onText = onText
        connect()
    }

    func send(_ pcm: Data) {
        lock.withLock {
            pending.append(pcm)
            guard pending.count >= 3200 else { return }   // 100 ms at 16 kHz × 2 bytes
            let m = IncantScribe.chunk(pending, commit: false)
            pending = Data()
            if open { ws?.send(.string(m)) { _ in } } else if queued.count < 300 { queued.append(m) }
        }
    }

    func stop() {
        let task: URLSessionWebSocketTask? = lock.withLock { running = false; return ws }
        task?.cancel(with: .normalClosure, reason: nil)
    }

    /// `IncantScribe.url` with `commit_strategy=vad`: segments commit on pauses.
    static func url(keyterms: [String]) -> URL { IncantScribe.url(keyterms: keyterms, vad: true) }

    private func connect() {
        var req = URLRequest(url: Self.url(keyterms: keyterms))
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let task = URLSession.shared.webSocketTask(with: req)
        lock.withLock { ws = task; open = false }
        task.resume()
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [self] result in
            guard case .success(let message) = result else {
                guard lock.withLock({ running && ws === task }) else { return }
                SupportLog.scry.error("live socket dropped; reconnecting")
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                    if lock.withLock({ running }) { connect() }
                }
                return
            }
            if case .string(let json) = message {
                switch IncantScribe.decode(json) {
                case .started:
                    lock.withLock {
                        open = true
                        for m in queued { task.send(.string(m)) { _ in } }
                        queued = []
                    }
                case .partial(let text):
                    onText(text, false)
                case .committed(let text):
                    onText(text, !text.trimmingCharacters(in: .whitespaces).isEmpty)   // empty: just clears the grey line
                case .error(let type, _):
                    SupportLog.scry.error("live Scribe: \(type, privacy: .public)")
                    if type == "quota_exceeded" {
                        stop()
                        onFatal("Out of ElevenLabs credits — live transcript off")
                        return
                    }
                default:
                    break
                }
            }
            receive(task)
        }
    }
}

/// "What did I miss?" — `ScryPrompt.catchUp` through Cerebras (OpenAI-compatible chat completions).
enum ScryCerebras {
    struct NoKey: Error {}

    static func catchUp(_ segments: [ScrySegment]) async throws -> String {
        guard let key = SupportKeychain.read(SupportKeychain.cerebras) else { throw NoKey() }
        let (system, user) = ScryPrompt.catchUp(segments)
        let t = Date()
        let (data, resp) = try await URLSession.shared.data(for: IncantCerebras.request(
            text: user, instructions: system, model: "qwen-3.8-27b", apiKey: key))
        let text = try IncantCerebras.parse(data, status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        SupportLog.scry.info("catch-up: \(segments.count, privacy: .public) segments in \(Int(Date().timeIntervalSince(t) * 1000), privacy: .public) ms")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
