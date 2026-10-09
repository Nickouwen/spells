import AppKit
import HoursCore
import IncantCore
import ScryCore
import SwiftUI

/// The live side of a recording (when `settings.live`): two Scribe v2 Realtime sockets (your mic → "You",
/// system audio → "Them") committing on pauses, a notes area (→ `ScryCapture.userNotes`), and "What did
/// I miss?" through Cerebras. The sockets run for the whole recording; the panel opens from the menu.
@MainActor final class ScryLive {
    let model = ScryLiveModel()
    private var sockets: [ScryLiveSocket] = []
    private var panel: NSPanel?
    private let started = Date()

    init(recorder: ScryRecorder, keyterms: [String], systemAudio: Bool) {
        guard let key = SupportKeychain.read(SupportKeychain.elevenLabs) else {
            model.status = "No ElevenLabs key — live transcript off"
            return
        }
        let you = ScryLiveSocket(apiKey: key, keyterms: keyterms) { [weak self] text in
            Task { @MainActor in self?.add("You", text) }
        }
        recorder.onMic = { you.send($0) }
        sockets = [you]
        if systemAudio {
            let them = ScryLiveSocket(apiKey: key, keyterms: keyterms) { [weak self] text in
                Task { @MainActor in self?.add("Them", text) }
            }
            recorder.onSystem = { them.send($0) }
            sockets.append(them)
        }
    }

    private func add(_ speaker: String, _ text: String) {
        // ponytail: a VAD commit arrives at the end of the utterance, so start = end = commit time.
        let t = Date().timeIntervalSince(started)
        model.segments.append(ScrySegment(speaker: speaker, start: t, end: t, text: text))
    }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
            p.title = "Scry — live"
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: ScryLiveView(model: model, onCatchUp: { [weak self] in self?.catchUp() }))
            if let v = NSScreen.main?.visibleFrame { p.setFrameTopLeftPoint(NSPoint(x: v.maxX - 380, y: v.maxY - 20)) }
            panel = p
        }
        NSApp.activate()   // you type in it
        panel?.makeKeyAndOrderFront(nil)
    }

    func stop() {
        sockets.forEach { $0.stop() }
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
    var segments: [ScrySegment] = []
    var notes = ""
    var catchUp = ""
    var busy = false
    var status: String?
}

struct ScryLiveView: View {
    @Bindable var model: ScryLiveModel
    var onCatchUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = model.status { Text(s).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.segments.enumerated()), id: \.offset) { _, s in
                        Text("\(s.speaker): \(s.text)").textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            Text("Notes").font(.headline)
            TextEditor(text: $model.notes).frame(minHeight: 80)
            HStack {
                Button("What did I miss?", action: onCatchUp).disabled(model.busy || model.segments.isEmpty)
                if model.busy { ProgressView().controlSize(.small) }
            }
            if !model.catchUp.isEmpty {
                ScrollView { Text(model.catchUp).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140)
            }
        }
        .padding(12)
        .frame(minWidth: 320, minHeight: 420)
    }
}

/// One continuous Scribe v2 Realtime socket (VAD commits). Audio is sent in ~100 ms chunks; chunks sent
/// before `session_started` are queued (up to ~30 s). A dropped connection reconnects after 2 s while
/// running. Never logs text — only event types.
final class ScryLiveSocket: @unchecked Sendable {
    private let apiKey: String, keyterms: [String], onCommitted: @Sendable (String) -> Void
    private let lock = NSLock()
    // Guarded by `lock`.
    private var ws: URLSessionWebSocketTask?, open = false, running = true, pending = Data(), queued: [String] = []

    init(apiKey: String, keyterms: [String], onCommitted: @escaping @Sendable (String) -> Void) {
        self.apiKey = apiKey; self.keyterms = keyterms; self.onCommitted = onCommitted
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

    /// `IncantScribe.url` with `commit_strategy=vad` (Incant's is manual): segments commit on pauses.
    static func url(keyterms: [String]) -> URL {
        var c = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        c.queryItems = [.init(name: "model_id", value: IncantScribe.model), .init(name: "audio_format", value: "pcm_16000"),
                        .init(name: "commit_strategy", value: "vad"), .init(name: "no_verbatim", value: "true"),
                        .init(name: "language_code", value: "en")]
            + keyterms.map { URLQueryItem(name: "keyterms", value: $0) }
        // URLQueryItem leaves "+" alone, which servers read as a space ("C++" → "C  ").
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

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
                case .committed(let text) where !text.trimmingCharacters(in: .whitespaces).isEmpty:
                    onCommitted(text)
                case .error(let type, _):
                    SupportLog.scry.error("live Scribe: \(type, privacy: .public)")
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
