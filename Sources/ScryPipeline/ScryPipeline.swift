import Foundation
import HoursCore
import IncantCore
import ScryCore

/// After a recording: Scribe v2 batch (multichannel, diarized) → segments → `claude -p` summary → the
/// Markdown note in `ScrySettings.rootURL` → audio/screenshots deleted.
public enum ScryPipeline {
    public struct Result: Sendable {
        public var noteURL: URL; public var summary: ScrySummary
        /// Timings, and whether Scribe diarized (false only when a call's far side was silent and skipped).
        public var scribeMs = 0, claudeMs = 0, diarized = true
    }

    public enum Failure: Error, CustomStringConvertible {
        case noKey
        case scribe(Int, String)
        case claude(String)
        public var description: String {
            switch self {
            case .noKey: "no ElevenLabs key (ELEVENLABS_API_KEY, Spells/.env or Keychain \(SupportKeychain.elevenLabs))"
            case let .scribe(status, body): "Scribe HTTP \(status): \(body)"
            case .claude(let s): "claude -p failed: \(s)"
            }
        }
    }

    static let scribeURL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600; c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    /// Processes `<dir>/capture.json` (+ its audio). On success the capture dir is deleted (unless
    /// `SCRY_KEEP_CAPTURE=1`); on failure it stays, with the attempt count + error in `error.txt`.
    public static func process(captureDir: URL, settings: ScrySettings, keyterms: [String]) async throws -> Result {
        do {
            let r = try await run(captureDir, settings, keyterms)
            if ProcessInfo.processInfo.environment["SCRY_KEEP_CAPTURE"] != "1" { try? FileManager.default.removeItem(at: captureDir) }
            return r
        } catch {
            ScryCaptures.recordFailure(captureDir, error)
            SupportLog.scry.error("pipeline failed: \(String(describing: error), privacy: .private)")
            throw error
        }
    }

    static func run(_ dir: URL, _ settings: ScrySettings, _ keyterms: [String]) async throws -> Result {
        let capture = try ScryCapture.decode(Data(contentsOf: dir.appending(path: "capture.json")))
        // On-screen names completed from the calendar invite; nobody read off the screen → the invitees.
        let seen = ScryNames.completed(ScryNames.fromOCR(capture.screenshotText), capture.invite)
        let names = seen.isEmpty ? capture.invite?.invitees.map(\.name) ?? [] : seen
        // ponytail: on-screen names join the vocabulary, so Scribe spells them the way the call shows them.
        var vocab: [String] = []
        for t in keyterms + names where !t.isEmpty && !vocab.contains(t) { vocab.append(t) }
        let terms = Array(vocab.prefix(100))

        let clock = ContinuousClock()
        var t0 = clock.now
        let wav = try Data(contentsOf: dir.appending(path: capture.audioFile), options: .alwaysMapped)
        // Scribe rejects `diarize` with `use_multi_channel` (HTTP 400, checked 2026-10-08), so each channel goes
        // up as its own mono file: in person, the mix (the room is all on the mic) diarized; on calls, channel 0
        // (you) plain and channel 1 (the far side) diarized, in parallel, merged into the per-channel
        // `transcripts[]` shape `ScryTranscript.segments` reads.
        let json: Data, diarized: Bool
        if capture.app == nil {
            // Channel 0 only: channel 1 is silent in person, and averaging it in would halve the level.
            json = try await scribe(mono(wav, channel: 0).wav, keyterms: terms, diarize: true); diarized = true
        } else {
            let far = mono(wav, channel: 1)
            async let you = scribe(mono(wav, channel: 0).wav, keyterms: terms, diarize: false)
            // ponytail: RMS < 0.001 (~−60 dBFS) = nobody on the far side; skip paying to transcribe silence.
            let them = far.rms < 0.001 ? nil : try await scribe(far.wav, keyterms: terms, diarize: true)
            json = try merged(you: try await you, farSide: them); diarized = them != nil
        }
        let scribeMs = ms(clock.now - t0)
        let segments = try ScryTranscript.segments(fromScribeJSON: json)

        let appName = capture.app.flatMap { ScryCallApps.known[$0] }
        let prompt = ScryPrompt.summary(segments: segments, participants: names, userNotes: capture.userNotes,
                                        userName: settings.userName, appName: appName, startedAt: capture.startedAt,
                                        keyterms: terms, invite: capture.invite)
        t0 = clock.now
        let summary = try ScryPrompt.parseSummary(try await claude(prompt))
        let claudeMs = ms(clock.now - t0)

        var participants = names
        for n in summary.speakers.values.sorted() where !participants.contains(where: { $0 == n || $0.hasPrefix(n + " ") }) {
            participants.append(n)   // "Alex" is already there as "Alex Client"
        }
        let note = ScryNote(meta: .init(startedAt: capture.startedAt, endedAt: capture.endedAt, app: appName,
                                        participants: participants, speakers: summary.speakers),
                            summary: summary, userNotes: capture.userNotes,
                            segments: ScryTranscript.renamed(segments, summary.speakers))
        let url = unique(ScryNote.fileURL(root: settings.rootURL, startedAt: capture.startedAt, title: summary.title))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(note.markdown().utf8).write(to: url, options: .withoutOverwriting)
        SupportLog.scry.info("note: \(segments.count) segments, \(summary.actionItems.count) actions, diarized \(diarized), scribe \(scribeMs) ms, claude \(claudeMs) ms")
        return Result(noteURL: url, summary: summary, scribeMs: scribeMs, claudeMs: claudeMs, diarized: diarized)
    }

    /// `x.md` → `x-2.md`, `x-3.md`… while the path exists.
    static func unique(_ url: URL) -> URL {
        let base = url.deletingPathExtension().path
        var u = url, n = 2
        while FileManager.default.fileExists(atPath: u.path) { u = URL(filePath: "\(base)-\(n).md"); n += 1 }
        return u
    }

    static func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }

    /// Multipart text fields + the file part's header; the WAV bytes and the closing boundary follow it.
    static func multipartHead(boundary: String, keyterms: [String], diarize: Bool) -> Data {
        var fields = [("model_id", "scribe_v2"), ("no_verbatim", "true"), ("timestamps_granularity", "word"), ("tag_audio_events", "false")]
        if diarize { fields.append(("diarize", "true")) }
        fields += keyterms.map { ("keyterms", $0) }
        var s = ""
        for (k, v) in fields { s += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n" }
        s += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        return Data(s.utf8)
    }

    /// POSTs a mono WAV to Scribe v2 batch → the response JSON; non-200 throws status + body prefix. The
    /// multipart body is spooled to a temp file and uploaded from there.
    static func scribe(_ wav: Data, keyterms: [String], diarize: Bool) async throws -> Data {
        guard let key = SupportKeychain.read(SupportKeychain.elevenLabs) else { throw Failure.noKey }
        let boundary = "scry-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory.appending(path: "\(boundary).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        FileManager.default.createFile(atPath: bodyURL.path, contents: multipartHead(boundary: boundary, keyterms: keyterms, diarize: diarize),
                                       attributes: [.posixPermissions: 0o600])
        let h = try FileHandle(forWritingTo: bodyURL)
        try h.seekToEnd()
        try h.write(contentsOf: wav)
        try h.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try h.close()

        var req = URLRequest(url: scribeURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.upload(for: req, fromFile: bodyURL)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        SupportLog.scry.info("scribe: HTTP \(status), diarize \(diarize), \(keyterms.count) keyterms")
        guard status == 200 else { throw Failure.scribe(status, String(String(decoding: data, as: UTF8.self).prefix(300))) }
        return data
    }

    /// Two single-channel Scribe responses → `{"transcripts": [{channel_index 0, words…}, {channel_index 1, …}]}`,
    /// the per-channel shape `ScryTranscript.segments` flattens (channel 0 = "You", channel 1 speaker_ids kept).
    static func merged(you: Data, farSide: Data?) throws -> Data {
        var transcripts: [[String: Any]] = []
        for (c, data) in [(0, you), (1, farSide)] {
            guard let data, var t = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            t["channel_index"] = c
            transcripts.append(t)
        }
        return try JSONSerialization.data(withJSONObject: ["transcripts": transcripts])
    }

    /// A 16-bit PCM WAV → a mono 16-bit WAV of one channel (`channel`), or of all channels averaged (nil),
    /// plus its RMS (0…1 of full scale). Other formats come back unchanged (RMS 1); a missing channel is
    /// empty (RMS 0).
    static func mono(_ wav: Data, channel: Int? = nil) -> (wav: Data, rms: Double) {
        wav.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> (wav: Data, rms: Double) in
            func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
            func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
            func s16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(i)))) }
            var i = 12, channels = 0, bits = 0, rate = 0
            while i + 8 <= b.count {
                let id = String(decoding: b[i..<i + 4], as: UTF8.self), size = u32(i + 4), body = i + 8
                if id == "fmt ", body + 16 <= b.count { channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14) }
                if id == "data" {
                    guard channels > 0, bits == 16 else { return (wav, 1) }
                    if let c = channel, c >= channels { return (Data(), 0) }
                    let frames = min(size, b.count - body) / (2 * channels)
                    var samples = [Int16](repeating: 0, count: frames), sq = 0.0
                    for f in 0..<frames {
                        let at = body + f * channels * 2
                        var v = 0
                        if let c = channel { v = s16(at + c * 2) } else { for c in 0..<channels { v += s16(at + c * 2) }; v /= channels }
                        samples[f] = Int16(v); sq += Double(v * v)
                    }
                    var out = Data(capacity: 44 + frames * 2)
                    func put(_ v: Int, _ n: Int) { for k in 0..<n { out.append(UInt8((v >> (8 * k)) & 0xFF)) } }
                    out.append(contentsOf: Array("RIFF".utf8)); put(36 + frames * 2, 4); out.append(contentsOf: Array("WAVEfmt ".utf8))
                    put(16, 4); put(1, 2); put(1, 2); put(rate, 4); put(rate * 2, 4); put(2, 2); put(16, 2)
                    out.append(contentsOf: Array("data".utf8)); put(frames * 2, 4)
                    samples.withUnsafeBytes { out.append(contentsOf: $0) }   // little-endian host
                    return (out, frames == 0 ? 0 : (sq / Double(frames)).squareRoot() / 32768)
                }
                i = body + size + (size & 1)
            }
            return (wav, 1)
        }
    }

    /// Scribe vocabulary: Incant's keyterms row, or its built-in defaults when none is saved.
    public static func keyterms(_ rows: [String: String]) -> [String] { IncantSettings.load(rows).keyterms }

    /// The setting table's rows (empty if the DB can't be opened): the claude path, and ScrySettings for spellsctl.
    public static func settingRows() -> [String: String] {
        (try? HoursDB.open(at: SupportPaths.current().db, role: .app)).flatMap { try? SettingStore($0).all() } ?? [:]
    }

    /// `claude -p` isolated like the standup's (`StandupGenerator.liveClaude`, which is internal to
    /// HoursCore and carries the standup system prompt): no tools, MCP, hooks or transcript. → `result`.
    static func claude(_ prompt: String) async throws -> String {
        let path = StandupSettings.load(settingRows()).claudePath
        guard FileManager.default.isExecutableFile(atPath: path) else { throw Failure.claude("not found or not executable: \(path)") }
        let args = ["-p", "--model", "sonnet", "--output-format", "json", "--safe-mode", "--no-session-persistence",
                    "--tools", "", "--strict-mcp-config"]
        let r = try await withCheckedThrowingContinuation { (c: CheckedContinuation<StandupProcess.Result, Error>) in
            DispatchQueue.global().async {
                c.resume(with: Swift.Result { try StandupProcess.run(URL(filePath: path), args, stdin: Data(prompt.utf8), timeout: 300) })
            }
        }
        let json = (try? JSONSerialization.jsonObject(with: r.stdout)) as? [String: Any]
        guard r.status == 0, let json, json["is_error"] as? Bool != true, let text = json["result"] as? String else {
            let detail = (json?["result"] as? String).map { "\($0.prefix(300)) " } ?? ""
            throw Failure.claude("exit \(r.status): \(detail)\(r.stderrText.prefix(500))")
        }
        return text
    }
}

/// Ask Scry: rank the notes under `root` for the question (`ScrySearch`), send the best `limit` to
/// `claude -p` with `ScryPrompt.ask`, return the answer and the notes it was given.
public enum ScryAsk {
    public static func answer(_ question: String, root: URL, limit: Int = 5) async throws -> (answer: String, sources: [URL]) {
        let all = notes(root: root)
        guard !all.isEmpty else { return ("No Scry notes under \(root.path).", []) }
        let byID = Dictionary(all.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = ScrySearch.rank(question, notes: all.map { ($0.url.path, $0.note.summary.title, $0.markdown, $0.note.meta.startedAt) },
                                  limit: limit)
        let top = ids.compactMap { byID[$0] }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        // Summary sections only: five whole transcripts could overrun claude's context or the timeout.
        let prompt = ScryPrompt.ask(question, notes: top.map {
            ($0.note.summary.title, f.string(from: $0.note.meta.startedAt), withoutTranscript($0.markdown))
        })
        return (try await ScryPipeline.claude(prompt).trimmingCharacters(in: .whitespacesAndNewlines), top.map(\.url))
    }

    static func withoutTranscript(_ md: String) -> String {
        guard let r = md.range(of: "\n## Transcript") else { return md }
        return String(md[..<r.lowerBound])
    }

    /// Every `*.md` under `root` that parses as a Scry note.
    public static func notes(root: URL) -> [(url: URL, note: ScryNote, markdown: String)] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(url: URL, note: ScryNote, markdown: String)] = []
        for case let url as URL in e where url.pathExtension == "md" {
            guard let md = try? String(contentsOf: url, encoding: .utf8), let note = ScryNote.parse(md) else { continue }
            out.append((url, note, md))
        }
        return out
    }
}
