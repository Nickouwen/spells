import AppKit
import SpellsKit
import SpellsUI
import IncantCore
import ScryCore
import ScryPipeline
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
    /// Who the Meet tab shows speaking now, and everyone else in the call.
    var who: () -> (speaking: String?, others: [String]) = { (nil, []) }
    var invite: ScryInvite?
    var onPause: () -> Void = {}
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
        let t = Date().timeIntervalSince(started), far = speaker != "You", now = who()
        model.others = now.others
        if final { model.transcript.commit(far: far, text, at: t, speaking: now.speaking, others: now.others) }
        else { model.transcript.hear(far: far, text, at: t, speaking: now.speaking) }
    }

    /// The pill's level timer feeds this too (0…1).
    func pushLevel(_ level: Double) { model.level = level }

    /// `activate` false: shown without taking the focus (a recording that just started).
    func show(activate: Bool = true) {
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
                                                                 onAsk: { [weak self] in self?.ask($0) },
                                                                 onPause: { [weak self] in self?.onPause() },
                                                                 onNotesChanged: { [weak self] in self?.notesChanged() },
                                                                 onStop: onStop, onDiscard: onDiscard))
            if let v = NSScreen.main?.visibleFrame { p.setFrameTopLeftPoint(NSPoint(x: v.maxX - 420, y: v.maxY - 20)) }
            panel = p
        }
        model.skills = ScryLiveChat.skills(custom: ScryApp.loadSettings().settings.skills)
        if activate { NSApp.activate() }   // you type in it
        // The panel, its transcript and your notes live as long as the recording: closing or minimising it
        // only hides it, and "Show live panel" (or the pill) brings the same one back.
        if panel?.isMiniaturized == true { panel?.deminiaturize(nil) }
        if activate { panel?.makeKeyAndOrderFront(nil) } else { panel?.orderFrontRegardless() }
    }

    func stop() {
        sockets.forEach { $0.stop() }
        notesSave?.cancel()
        if !model.notes.isEmpty { saveNotes() }
        saveNames()
        panel?.close()
    }

    /// The names you gave join the Meet watcher's, which has stopped by now, so the note uses them.
    private func saveNames() {
        let hints = model.transcript.hints
        guard !hints.isEmpty else { return }
        let url = dir.appending(path: "speakers.jsonl"), data = Data(hints.map { $0.encoded + "\n" }.joined().utf8)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.seekToEnd(); try h.write(contentsOf: data)
            } else { try data.write(to: url) }
        } catch { SupportLog.scry.error("speaker names not saved: \(error.localizedDescription, privacy: .public)") }
    }

    private func ask(_ question: String) {
        model.chat.append(.init(question: question))
        let i = model.chat.count - 1, transcript = model.transcript, notes = model.notes, invite = invite
        Task {
            do {
                let text = try await ScryLiveAsk.answer(question, transcript: transcript, notes: notes, invite: invite, skills: model.skills)
                let known = ([transcript.plainText, notes] + (invite?.invitees.compactMap(\.email) ?? [])).joined(separator: "\n")
                model.chat[i].answer = text
                model.chat[i].gmail = ScryLiveChat.email(in: text, known: known)
                    .flatMap { ScryLiveChat.gmail(to: $0.to, cc: $0.cc, subject: $0.subject, body: $0.body) }
            } catch {
                SupportLog.scry.error("live ask failed: \(String(describing: error), privacy: .private)")
                model.chat[i].answer = "Couldn't get an answer right now."
            }
        }
    }

    private func catchUp() {
        model.busy = true
        let segments = model.transcript.segments.map { var s = $0; s.text = ScryOps.redacted(s.text); return s }
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
    struct Chat: Identifiable { let id = UUID(); var question: String, answer: String? = nil, gmail: URL? = nil }
    let app: String?
    let startedAt: Date
    var transcript = ScryLiveTranscript()
    /// Everyone else in the call, as far as the Meet tab shows.
    var others: [String] = []
    var chat: [Chat] = []
    var skills = ScryLiveChat.builtIn
    var paused = false
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

/// The panel: a recording header (pulse, source, elapsed, level), three tabs (the transcript with names, search and
/// copy; your notes; the chat), an ask field that works from any of them, and the actions the menu has.
struct ScryLiveView: View {
    enum Tab: String, CaseIterable { case transcript = "Transcript", notes = "Your notes", chat = "Ask" }
    @Bindable var model: ScryLiveModel
    var onCatchUp: () -> Void
    var onAsk: (String) -> Void = { _ in }
    var onPause: () -> Void = {}
    var onNotesChanged: () -> Void
    var onStop: () -> Void
    var onDiscard: () -> Void
    @State var tab = Tab.transcript
    @State private var pulse = false
    @State private var query = ""
    @State private var question = ""
    @State private var showEcho = false
    @State private var atBottom = true
    @State private var scroll = ScrollPosition(edge: .bottom)
    /// The line whose speaker you are naming, and the name so far.
    @State private var naming: ScryLiveTranscript.Line?
    @State private var newName = ""
    @FocusState private var searching: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            if let p = model.problem { problem(p) }
            Picker("View", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            switch tab {
            case .transcript: transcript
            case .notes: notes
            case .chat: chat
            }
            if !model.catchUp.isEmpty { catchUpCard }
            askField
            footer
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.xl + Theme.Space.s)   // under the transparent title bar
        .padding(.bottom, Theme.Space.l)
        .frame(minWidth: 340, minHeight: 460)
        .background(Theme.canvas)
        .tint(Theme.ink)
        .onAppear {
            // Reduce Motion: a steady dot (the recording state is also spelled out beside it).
            if reduceMotion { pulse = true } else { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
        }
        .onChange(of: model.notes) { _, _ in onNotesChanged() }
        .alert("Who is this?", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }), presenting: naming) { l in
            TextField("Name", text: $newName)
            Button("All “\(l.speaker)” lines") { model.transcript.rename(l.id, to: newName, everywhere: true) }
            Button("This line") { model.transcript.rename(l.id, to: newName, everywhere: false) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("The note uses the name too.") }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Circle().fill(model.paused ? Theme.inkTertiary : Theme.StateLayer.recording).frame(width: 8, height: 8).opacity(model.paused || pulse ? 1 : 0.3)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(model.paused ? "Paused" : "Recording").textRole(.heading)
                Text(model.others.isEmpty ? model.app.map { "\($0) call" } ?? "In person" : model.others.joined(separator: ", "))
                    .textRole(.label, Theme.inkTertiary).lineLimit(1)
            }
            Spacer()
            IconButton(symbol: model.paused ? "play.fill" : "pause.fill", help: model.paused ? "Resume recording" : "Pause: nothing is recorded until you resume") { onPause() }
            LevelMeter(level: model.level)
            TimelineView(.periodic(from: model.startedAt, by: 1)) { ctx in
                Text(Self.clock(ctx.date.timeIntervalSince(model.startedAt))).textRole(.title).monospacedDigit()   // .metric out-shouted the transcript; fixed digits so it doesn't jitter
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

    // MARK: Transcript

    private var shown: [ScryLiveTranscript.Line] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return (showEcho ? model.transcript.lines : model.transcript.visible)
            .filter { q.count < 2 || $0.text.localizedCaseInsensitiveContains(q) || $0.speaker.localizedCaseInsensitiveContains(q) }
    }

    private var transcript: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkTertiary)
                TextField("Search", text: $query).textFieldStyle(.plain).textRole(.body).focused($searching)
                    .onExitCommand { query = ""; searching = false }
                let echoes = model.transcript.lines.count { $0.echo }
                if echoes > 0 {
                    Button(showEcho ? "Hide echo" : "\(echoes) echo hidden") { showEcho.toggle() }.buttonStyle(QuietButtonStyle())
                        .help("Lines of yours that repeat the other side: your speakers, heard by your mic")
                }
                IconButton(symbol: "hand.raised", help: "Copy a consent notice to paste into the meeting's chat") { copy(ScryLiveChat.consent) }
                IconButton(symbol: "doc.on.doc", help: "Copy the transcript") { copy(model.transcript.plainText) }
            }
            .background { Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).opacity(0).accessibilityHidden(true) }
            GeometryReader { geo in
                ScrollView {
                    transcriptBody
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)   // top until it fills, then pinned to the newest line
                }
                .defaultScrollAnchor(.bottom)
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 24 } action: { _, v in atBottom = v }
                .onChange(of: model.transcript) { if atBottom, query.isEmpty { scroll.scrollTo(edge: .bottom) } }   // reading back or searching: stay put
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button("Jump to latest") { scroll.scrollTo(edge: .bottom) }.buttonStyle(RewindButtonStyle()).padding(Theme.Space.s)
                }
            }
        }
    }

    @ViewBuilder private var transcriptBody: some View {
        let lines = shown
        if model.transcript.lines.isEmpty, model.transcript.partial.isEmpty {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "waveform").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.inkTertiary)
                Text(model.liveSince == nil ? "Connecting…" : "Listening").textRole(.bodyEmph, Theme.inkSecondary)
                Text("Each thing said appears here as it's said, and settles when the speaker pauses. Always get consent before you transcribe others.")
                    .textRole(.label, Theme.inkTertiary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.xxl)
            .padding(.horizontal, Theme.Space.m)
        } else if lines.isEmpty, query.count >= 2 {
            Text("Nothing said matches “\(query)”.").textRole(.label, Theme.inkTertiary).frame(maxWidth: .infinity).padding(Theme.Space.xl)
        } else {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(lines) { l in row(l) }
                if query.count < 2 {
                    ForEach([false, true], id: \.self) { far in   // You, then them
                        if let p = model.transcript.partial[far] {
                            row(chip: chip(far ? model.transcript.speaker(p, others: model.others) : "You", you: !far), time: "now", text: p.text, faint: true)
                        }
                    }
                }
            }
            .padding(Theme.Space.m)
            .textSelection(.enabled)
        }
    }

    /// A far-side name opens the menu that says who it is (yours is your mic: nothing to change).
    private func row(_ l: ScryLiveTranscript.Line) -> some View {
        row(chip: Group {
            if l.far {
                Menu {
                    let names = model.others.filter { $0 != l.speaker }
                    if !names.isEmpty {
                        Section("All “\(l.speaker)” lines") { ForEach(names, id: \.self) { n in Button(n) { model.transcript.rename(l.id, to: n, everywhere: true) } } }
                        Section("This line") { ForEach(names, id: \.self) { n in Button(n) { model.transcript.rename(l.id, to: n, everywhere: false) } } }
                    }
                    Button("Rename…") { newName = l.speaker == "Them" ? "" : l.speaker; naming = l }
                } label: { chip(l.speaker, you: false) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Say who this is")
            } else { chip("You", you: true) }
        }, time: Self.clock(l.start), text: l.text, faint: l.echo)
    }

    private func row(chip: some View, time: String, text: String, faint: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(time).textRole(.label, Theme.inkTertiary).frame(width: 40, alignment: .trailing)
            chip.frame(minWidth: 64, alignment: .leading)   // one text column whatever the name's length
            Text(text).textRole(.body, faint ? Theme.inkTertiary : Theme.ink).italic(faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Neutral chips: a shared hue on every other speaker carried no meaning. You = full ink. First names: the column is narrow.
    private func chip(_ name: String, you: Bool) -> some View {
        Text(name.split(separator: " ").first.map(String.init) ?? name).textRole(.micro, you ? Theme.ink : Theme.inkSecondary).lineLimit(1)
            .padding(.horizontal, Theme.Space.xs + 2).padding(.vertical, 2)
            .background(Theme.ink.over(Theme.surface, alpha: you ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .accessibilityLabel(name)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    // MARK: Notes and chat

    private var notes: some View {
        ZStack(alignment: .topLeading) {
            if model.notes.isEmpty {
                Text("Anything you type here is kept with the meeting note.").textRole(.body, Theme.inkTertiary)
                    .padding(.horizontal, Theme.Space.s + 1).padding(.vertical, Theme.Space.s)
            }
            TextEditor(text: $model.notes)
                .font(.body).foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.xs)
                .accessibilityLabel("Your notes")
        }
        .frame(maxHeight: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
    }

    private var chat: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if model.chat.isEmpty {
                    Text("Ask about the call so far, or pick a skill. Answers use the transcript, your notes and the invite.")
                        .textRole(.label, Theme.inkTertiary)
                    ForEach(ScryLiveChat.groups, id: \.self) { g in
                        let some = model.skills.filter { $0.group == g }
                        if !some.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                Text(g).textRole(.label, Theme.inkSecondary)
                                ForEach(some) { s in Button("/\(s.id)  \(s.title)") { send("/" + s.id) }.buttonStyle(QuietButtonStyle()) }
                            }
                        }
                    }
                }
                ForEach(model.chat) { c in
                    Text(c.question).textRole(.bodyEmph).textSelection(.enabled)
                    if let a = c.answer {
                        Text(a).textRole(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Theme.Space.s) {
                            Button("Copy") { copy(a) }.buttonStyle(QuietButtonStyle())
                            if let url = c.gmail { Button("Open in Gmail") { NSWorkspace.shared.open(url) }.buttonStyle(RewindButtonStyle()) }
                        }
                    } else { ProgressView().controlSize(.small) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
        }
        .defaultScrollAnchor(model.chat.isEmpty ? .top : .bottom)
        .frame(maxHeight: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
    }

    private var askField: some View {
        HStack(spacing: Theme.Space.s) {
            Menu {
                ForEach(ScryLiveChat.groups, id: \.self) { g in
                    let some = model.skills.filter { $0.group == g }
                    if !some.isEmpty { Section(g) { ForEach(some) { s in Button(s.title) { send("/" + s.id) } } } }
                }
            } label: { Image(systemName: "sparkles") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Skills").accessibilityLabel("Skills")
            TextField("Ask anything, or type / for a skill", text: $question).textFieldStyle(.plain).textRole(.body).onSubmit { send(question) }
            Button("Ask") { send(question) }.buttonStyle(QuietButtonStyle())
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.xs)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
        .disabled(model.transcript.lines.isEmpty)
    }

    private func send(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.transcript.lines.isEmpty else { return }
        question = ""
        tab = .chat
        onAsk(text)
    }

    /// The three buttons don't fit the panel's 340 pt minimum with labels: the catch-up button drops to its
    /// icon first, so "Stop & Make Notes" always shows whole.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerRow(compact: false)
            footerRow(compact: true)
        }
    }

    private func footerRow(compact: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Button {
                onCatchUp()
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    if model.busy { ProgressView().controlSize(.mini) } else { Image(systemName: "clock.arrow.circlepath") }
                    if !compact { Text("What did I miss?") }
                }
                .lineLimit(1).fixedSize()
            }
            .buttonStyle(QuietButtonStyle())
            .help("What did I miss?")
            .disabled(model.busy || model.transcript.lines.isEmpty)
            Spacer(minLength: 0)
            Button(action: onDiscard) { Text("Discard").lineLimit(1).fixedSize() }.buttonStyle(QuietButtonStyle())
            Button(action: onStop) { Text("Stop & Make Notes").lineLimit(1).fixedSize() }.buttonStyle(PrimaryButtonStyle())
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
