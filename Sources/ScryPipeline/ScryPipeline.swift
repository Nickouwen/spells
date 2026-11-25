import Foundation
import SpellsKit
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
        /// Not a fault: no words on either side and no notes typed, so there is nothing to write up.
        case nothingSaid
        case recordingGone
        /// The note was edited while Claude read it: nothing is written.
        case noteChanged
        public var description: String {
            switch self {
            case .noteChanged: "the note changed meanwhile, so nothing was written; try again"
            case .recordingGone: "the recording is gone (it's kept for a week)"
            case .nothingSaid: "nobody spoke in the recording, so no note was made"
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

    /// Processes `<dir>/capture.json` (+ its audio). On success the capture dir is retired (`ScryCaptures.retire`:
    /// kept for a week, unless `SCRY_KEEP_CAPTURE=1` leaves it where it is); on failure it stays, with the attempt
    /// count + error in `error.txt`. A recording nobody spoke in throws `Failure.nothingSaid`: no note, and the
    /// capture is retired like a finished one (there is nothing to try again).
    public static func process(captureDir: URL, settings: ScrySettings, keyterms: [String]) async throws -> Result {
        let retire = { if ProcessInfo.processInfo.environment["SCRY_KEEP_CAPTURE"] != "1" { ScryCaptures.retire(captureDir) } }
        do {
            let r = try await run(captureDir, settings, keyterms)
            retire()
            return r
        } catch Failure.nothingSaid {
            retire()
            SupportLog.scry.info("nobody spoke in the recording: no note")
            throw Failure.nothingSaid
        } catch {
            ScryCaptures.recordFailure(captureDir, error)
            SupportLog.scry.error("pipeline failed: \(String(describing: error), privacy: .private)")
            throw error
        }
    }

    /// Transcribes a note's recording again, told how many people are on the far side, when the first pass heard two as
    /// one. Writes a second note beside it. Throws when the recording is gone (it's kept for a week).
    public static func separate(note: ScryNote, voices: Int, settings: ScrySettings, keyterms: [String]) async throws -> Result {
        let dir = ScryCaptures.dirs(ScryCaptures.kept(.current())).first { d in
            guard let c = try? ScryCapture.decode(Data(contentsOf: d.appending(path: "capture.json"))) else { return false }
            return abs(c.startedAt.timeIntervalSince(note.meta.startedAt)) < 1.5
        }
        guard let dir else { throw Failure.recordingGone }
        return try await run(dir, settings, keyterms, voices: voices)
    }

    static func run(_ dir: URL, _ settings: ScrySettings, _ keyterms: [String], voices: Int? = nil) async throws -> Result {
        let capture = try ScryCapture.decode(Data(contentsOf: dir.appending(path: "capture.json")))
        // Who was on the call: the Meet tab's participant tiles when the recorder could read them (exact names,
        // and who spoke when), else on-screen names completed from the calendar invite; nobody → the invitees.
        let meet = ScryMeet.log(fromJSONL: (try? String(contentsOf: dir.appending(path: "speakers.jsonl"), encoding: .utf8)) ?? "")
        // The names you gave in the live panel (`ScryLive.saveNames`), with who they are when you picked someone you know.
        let given = ScryLiveName.load(dir)
        let expected = (capture.invite?.invitees.map(\.name) ?? []) + [settings.userName]
        let shown = meet.participants.isEmpty ? ScryNames.fromOCR(capture.screenshotText, known: expected) : meet.participants
        let seen = meet.participants.isEmpty ? ScryNames.completed(shown, capture.invite) : shown
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
            json = try await scribe(mono(wav, channel: 0).wav, keyterms: terms, diarize: true, voices: voices.map { $0 + 1 }); diarized = true
        } else {
            let far = mono(wav, channel: 1)
            async let you = scribe(mono(wav, channel: 0).wav, keyterms: terms, diarize: false)
            // ponytail: RMS < 0.001 (~−60 dBFS) = nobody on the far side; skip paying to transcribe silence.
            let them = far.rms < 0.001 ? nil : try await scribe(far.wav, keyterms: terms, diarize: true, voices: voices)
            json = try merged(you: try await you, farSide: them); diarized = them != nil
        }
        let scribeMs = ms(clock.now - t0)
        // On a call, how loud each side was tells the far side's echo in the mic from what you said.
        let levels = capture.app == nil ? nil : levels(wav)
        // SSNs, card and bank numbers never reach the model or the note (the note is synced; the audio goes after a week).
        let turns = try ScryTranscript.segments(fromScribeJSON: json, levels: levels)
        let raw = zip(turns, ScryOps.redacted(turns: turns.map(\.text))).map { s, t in var s = s; s.text = t; return s }
        let userNotes = ScryOps.redacted(capture.userNotes, numbersOnly: true)
        // A call nobody spoke in (2026-11-10): asked for a summary of nothing, the model writes a note about an
        // empty transcript and a follow-up email asking what was said. Notes you typed are still worth a note.
        if raw.isEmpty, capture.userNotes.allSatisfy(\.isWhitespace) { throw Failure.nothingSaid }
        // Named before the summary, so its recap says "Alex", not "Speaker A": Meet's speaking indicator votes
        // first; with nothing from it, a lone far-side speaker is the one other person named.
        let fromMeet = capture.app == nil ? [:] : ScryMeet.names(for: raw, hints: meet.hints, owner: settings.userName, given: given.flatMap(\.hints))
        // A name you gave beats the screen's: the only voice is the one person you named.
        let named = Set(given.map(\.name))
        let sole = capture.app == nil || !fromMeet.isEmpty || named.count > 1 ? [:]
            : ScryNames.soleSpeaker(raw, names: named.isEmpty ? names : Array(named), userName: named.isEmpty ? settings.userName : "")
        let known = fromMeet.merging(sole) { a, _ in a }
        if !meet.hints.isEmpty || !given.isEmpty {
            SupportLog.scry.info("Meet speakers: \(meet.hints.count, privacy: .public) hints named \(fromMeet.count, privacy: .public) of \(Set(raw.map(\.speaker)).subtracting(["You"]).count, privacy: .public) far-side speakers")
        }
        let segments = ScryTranscript.renamed(raw, known)

        let appName = capture.app.flatMap { ScryCallApps.known[$0] }
        let prompt = ScryPrompt.summary(segments: segments, participants: names, userNotes: userNotes,
                                        userName: settings.userName, appName: appName, startedAt: capture.startedAt,
                                        keyterms: terms, invite: safe(capture.invite))
        t0 = clock.now
        var summary = try ScryPrompt.parseSummary(try await claude(prompt))
        if levels?.throughSpeakers == true {
            summary.insights.append(speakersLine)
        }
        if let p = capture.pauses, !p.isEmpty {
            func at(_ t: Double) -> String { String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }
            summary.insights.append(pausePrefix + " " + p.filter { $0.count == 2 }.map { "\(at($0[0]))–\(at($0[1]))" }.joined(separator: ", ") + ".")
        }
        let claudeMs = ms(clock.now - t0)

        summary.speakers = ScryTranscript.safeNames(summary.speakers, for: segments)
        let speakers = known.merging(summary.speakers) { a, _ in a }
        var participants = names
        for n in speakers.values.sorted() where !participants.contains(where: { $0 == n || $0.hasPrefix(n + " ") }) {
            participants.append(n)   // "Alex" is already there as "Alex Client"
        }
        let url = unique(ScryNote.fileURL(root: settings.rootURL, startedAt: capture.startedAt, title: summary.title))
        let spoken = ScryTranscript.renamed(segments, summary.speakers)
        let emails = Dictionary(grouping: capture.invite?.invitees ?? [], by: \.name)   // two invitees with one name: neither email is sure
            .compactMapValues { $0.count == 1 ? $0[0].email : nil }
        var picked = Dictionary(given.compactMap { g in g.person.map { (g.name, $0) } }, uniquingKeysWith: { _, b in b })
        // A voice named from the invite or by the model is a guess, so its link is yours to make: sure is Meet's marker, the
        // only other name on the screen as it stood there, or a name you gave.
        let sure = named.union(fromMeet.values).union(sole.values.filter(shown.contains))
        for s in spoken where !sure.contains(s.speaker) && picked[s.speaker] == nil { picked[s.speaker] = "" }
        for n in summary.speakers.values { picked[n] = "" }   // the model's, also when you picked that name for another voice
        let people = ScryPeople.rows(segments: spoken, mentioned: summary.people, emails: emails, owner: settings.userName,
                                     known: ScryPeople.load(settings.people.compactMap(ScrySettings.folder)), note: url,
                                     picked: picked)
        let note = ScryNote(meta: .init(startedAt: capture.startedAt, endedAt: capture.endedAt, app: appName,
                                        participants: participants, speakers: speakers),
                            summary: summary, userNotes: userNotes,
                            segments: spoken, people: people)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(note.markdown().utf8).write(to: url, options: .withoutOverwriting)
        SupportLog.scry.info("note: \(segments.count) segments, \(summary.actionItems.count) actions, diarized \(diarized), scribe \(scribeMs) ms, claude \(claudeMs) ms")
        return Result(noteURL: url, summary: summary, scribeMs: scribeMs, claudeMs: claudeMs, diarized: diarized)
    }

    /// The invite for a prompt: its title without numbers.
    static func safe(_ invite: ScryInvite?) -> ScryInvite? {
        invite.map { var i = $0; i.title = ScryOps.redacted(i.title, numbersOnly: true); return i }
    }

    private static let pausePrefix = "Recording paused:"
    private static let speakersLine = "The call played through speakers, so the mic also heard the far side. Scry removed that echo from your lines."

    /// Re-summarizes a note from its own transcript with the current prompt and rewrites it in place: same
    /// times, participants, transcript and your notes; new title, summary and action items (ticks are lost).
    public static func resummarize(note url: URL, settings: ScrySettings, keyterms: [String], language: String? = nil) async throws -> (summary: ScrySummary, before: String, after: String) {
        let before = try String(contentsOf: url, encoding: .utf8)
        guard let note = ScryNote.parse(before), !note.segments.isEmpty else {
            throw Failure.claude("\(url.lastPathComponent) isn't a Scry note with a transcript")
        }
        // A note from before 2026-11-24 can still hold numbers: they don't go to the model, nor into the note again.
        let lines = note.summary.insights.filter { $0.hasPrefix(pausePrefix) || $0 == speakersLine }
        let safe = zip(note.segments, ScryOps.redacted(turns: note.segments.map(\.text))).map { s, t in var s = s; s.text = t; return s }
        let userNotes = ScryOps.redacted(note.userNotes, numbersOnly: true)
        let prompt = ScryPrompt.summary(segments: safe, participants: note.meta.participants, userNotes: userNotes,
                                        userName: settings.userName, appName: note.meta.app, startedAt: note.meta.startedAt,
                                        keyterms: keyterms, language: language)
        var summary = try ScryPrompt.parseSummary(try await claude(prompt))
        summary.insights += lines   // the model can't know these
        summary.speakers = ScryTranscript.safeNames(summary.speakers, for: note.segments)
        var meta = note.meta
        meta.speakers = meta.speakers.merging(summary.speakers) { a, _ in a }
        let spoken = ScryTranscript.renamed(safe, summary.speakers)
        // Links already made stay (yours or not linking someone included); people found this time join them.
        let found = ScryPeople.rows(segments: spoken, mentioned: summary.people, emails: [:], owner: settings.userName,
                                    known: ScryPeople.load(settings.people.compactMap(ScrySettings.folder)), note: url,
                                    picked: Dictionary(spoken.map { ($0.speaker, "") }, uniquingKeysWith: { a, _ in a }))   // nothing says who gave these names
        let kept = note.people.map { p in
            p.role == .speaker ? ScryNotePerson(name: summary.speakers[p.name] ?? p.name, role: p.role, at: p.at, detail: p.detail, link: p.link) : p
        }
        let out = ScryNote(meta: meta, summary: summary, userNotes: userNotes, segments: spoken,
                           people: ScryPeople.merged(kept, found.filter { f in !kept.contains { $0.id == f.id } }))   // one you unlinked stays unlinked
        guard try String(contentsOf: url, encoding: .utf8) == before else { throw Failure.noteChanged }
        let after = ScryNotes.carried(from: before, to: out.markdown())
        try Data(after.utf8).write(to: url, options: .atomic)
        return (summary, before, after)
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
    static func multipartHead(boundary: String, keyterms: [String], diarize: Bool, voices: Int? = nil) -> Data {
        var fields = [("model_id", "scribe_v2"), ("no_verbatim", "true"), ("timestamps_granularity", "word"), ("tag_audio_events", "false")]
        if diarize { fields.append(("diarize", "true")) }
        if diarize, let voices { fields.append(("num_speakers", String(voices))) }
        fields += keyterms.map { ("keyterms", $0) }
        var s = ""
        for (k, v) in fields { s += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n" }
        s += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        return Data(s.utf8)
    }

    /// POSTs a mono WAV to Scribe v2 batch → the response JSON; non-200 throws status + body prefix. The
    /// multipart body is spooled to a temp file and uploaded from there.
    static func scribe(_ wav: Data, keyterms: [String], diarize: Bool, voices: Int? = nil) async throws -> Data {
        guard let key = SupportKeychain.read(SupportKeychain.elevenLabs) else { throw Failure.noKey }
        let boundary = "scry-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory.appending(path: "\(boundary).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        FileManager.default.createFile(atPath: bodyURL.path, contents: multipartHead(boundary: boundary, keyterms: keyterms, diarize: diarize, voices: voices),
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
            guard let p = pcm(b) else { return (wav, 1) }
            if let c = channel, c >= p.channels { return (Data(), 0) }
            var samples = [Int16](repeating: 0, count: p.frames), sq = 0.0
            for f in 0..<p.frames {
                let at = p.body + f * p.channels * 2
                var v = 0
                if let c = channel { v = s16(b, at + c * 2) } else { for c in 0..<p.channels { v += s16(b, at + c * 2) }; v /= p.channels }
                samples[f] = Int16(v); sq += Double(v * v)
            }
            var out = Data(capacity: 44 + p.frames * 2)
            func put(_ v: Int, _ n: Int) { for k in 0..<n { out.append(UInt8((v >> (8 * k)) & 0xFF)) } }
            out.append(contentsOf: Array("RIFF".utf8)); put(36 + p.frames * 2, 4); out.append(contentsOf: Array("WAVEfmt ".utf8))
            put(16, 4); put(1, 2); put(1, 2); put(p.rate, 4); put(p.rate * 2, 4); put(2, 2); put(16, 2)
            out.append(contentsOf: Array("data".utf8)); put(p.frames * 2, 4)
            samples.withUnsafeBytes { out.append(contentsOf: $0) }   // little-endian host
            return (out, p.frames == 0 ? 0 : (sq / Double(p.frames)).squareRoot() / 32768)
        }
    }

    /// A call's 2-channel 16-bit WAV → the mic's and the far side's power per `ScryLevels.frame`; nil for any
    /// other shape (then echo falls back to the word match).
    static func levels(_ wav: Data) -> ScryLevels? {
        wav.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> ScryLevels? in
            guard let p = pcm(b), p.channels == 2 else { return nil }
            let n = max(1, Int(Double(p.rate) * ScryLevels.frame)), count = p.frames / n
            var mic = [Float](repeating: 0, count: count), far = mic
            for i in 0..<count {
                var m = 0.0, f = 0.0
                for s in 0..<n {
                    let at = p.body + (i * n + s) * 4
                    let a = Double(s16(b, at)) / 32768, c = Double(s16(b, at + 2)) / 32768
                    m += a * a; f += c * c
                }
                mic[i] = Float(m / Double(n)); far[i] = Float(f / Double(n))
            }
            return ScryLevels(mic: mic, far: far)
        }
    }

    /// The `data` chunk of a 16-bit PCM WAV: where its samples start, whole frames in it, channels, rate.
    private static func pcm(_ b: UnsafeRawBufferPointer) -> (body: Int, frames: Int, channels: Int, rate: Int)? {
        func u32(_ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }
        var i = 12, channels = 0, bits = 0, rate = 0
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<i + 4], as: UTF8.self), size = u32(i + 4), body = i + 8
            if id == "fmt ", body + 16 <= b.count { channels = u16(b, body + 2); rate = u32(body + 4); bits = u16(b, body + 14) }
            if id == "data" {
                guard channels > 0, bits == 16 else { return nil }
                return (body, min(size, b.count - body) / (2 * channels), channels, rate)
            }
            i = body + size + (size & 1)
        }
        return nil
    }
    private static func u16(_ b: UnsafeRawBufferPointer, _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private static func s16(_ b: UnsafeRawBufferPointer, _ i: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(b, i)))) }

    /// Scribe vocabulary: Incant's keyterms row, or its built-in defaults when none is saved.
    public static func keyterms(_ rows: [String: String]) -> [String] { IncantSettings.load(rows).keyterms }

    /// Scry's settings file (ScrySettings, the claude path) over Incant's (keyterms); empty when neither exists.
    public static func settingRows() -> [String: String] {
        SpellSettingsFile.incant().all().merging(SpellSettingsFile.scry().all()) { _, scry in scry }
    }

    /// `claude -p` isolated like the standup's (`StandupGenerator.liveClaude`, which is internal to
    /// RewindCore and carries the standup system prompt): no tools, MCP, hooks or transcript. → `result`.
    static func claude(_ prompt: String, model: String = "sonnet") async throws -> String {
        let path = SpellsClaude.path(settingRows())
        guard FileManager.default.isExecutableFile(atPath: path) else { throw Failure.claude("not found or not executable: \(path)") }
        let args = ["-p", "--model", model, "--output-format", "json", "--safe-mode", "--no-session-persistence",
                    "--tools", "", "--strict-mcp-config"]
        let r = try await withCheckedThrowingContinuation { (c: CheckedContinuation<SupportProcess.Result, Error>) in
            DispatchQueue.global().async {
                c.resume(with: Swift.Result { try SupportProcess.run(URL(filePath: path), args, stdin: Data(prompt.utf8), timeout: 300) })
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

/// The live panel's chat, answered by Haiku (a few seconds). Sensitive numbers are out of the transcript and the
/// notes before they leave (`ScryOps.redacted`).
public enum ScryLiveAsk {
    public static func answer(_ question: String, transcript: ScryLiveTranscript, notes: String, invite: ScryInvite?,
                              skills: [ScryLiveChat.Skill] = ScryLiveChat.builtIn) async throws -> String {
        let safe = zip(transcript.segments, ScryOps.redacted(turns: transcript.segments.map(\.text))).map { s, t in var s = s; s.text = t; return s }
        let text = safe.map { String(format: "[%02d:%02d] ", Int($0.start) / 60, Int($0.start) % 60) + "\($0.speaker): \($0.text)" }
        let prompt = ScryLiveChat.prompt(ScryOps.redacted(ScryLiveChat.expand(question, skills: skills)), transcript: ScryOps.redacted(text.joined(separator: "\n")),
                                         notes: ScryOps.redacted(notes), invite: ScryPipeline.safe(invite))
        return try await ScryPipeline.claude(prompt, model: "haiku").trimmingCharacters(in: .whitespacesAndNewlines)
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
        let prompt = ScryPrompt.ask(ScryOps.redacted(question), notes: top.map {
            (ScryOps.redacted($0.note.summary.title, numbersOnly: true), f.string(from: $0.note.meta.startedAt), ScryOps.redacted(withoutTranscript($0.markdown), numbersOnly: true))
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
