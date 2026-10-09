import Foundation
import Testing
@testable import IncantCore

// MARK: - Gesture

private func run(_ g: inout IncantGesture, _ steps: [(IncantKeyEvent, Int64)]) -> [IncantGestureAction] {
    steps.map { g.handle($0.0, atMs: $0.1) }
}

/// Fn tapped at 0–100, pressed again at 300 → hands-free.
private func handsFree(_ timing: IncantGesture.Timing = .init()) -> IncantGesture {
    var g = IncantGesture(timing: timing)
    #expect(run(&g, [(.fnDown, 0), (.fnUp, 100), (.fnDown, 300)]) == [.start, .none, .none])
    #expect(g.isListening && g.isHandsFree)
    return g
}

@Test func holdThenReleaseFinishes() {
    var g = IncantGesture()
    #expect(run(&g, [(.fnDown, 0)]) == [.start])
    #expect(g.isListening && !g.isHandsFree)
    #expect(g.tick(atMs: 5_000) == .none)
    #expect(run(&g, [(.fnUp, 5_000)]) == [.finish])
    #expect(!g.isListening)
}

@Test func tapThenTimeoutCancels() {
    var g = IncantGesture()
    #expect(run(&g, [(.fnDown, 0), (.fnUp, 100)]) == [.start, .none])
    #expect(g.tick(atMs: 450) == .none) // exactly the window: still waiting
    #expect(g.isListening)
    #expect(g.tick(atMs: 500) == .cancel)
    #expect(!g.isListening)
}

@Test func doubleTapEntersHandsFreeAndItsReleaseIsIgnored() {
    var g = handsFree()
    #expect(run(&g, [(.fnUp, 400)]) == [.none])
    #expect(g.tick(atMs: 60_000) == .none)
    #expect(g.isListening && g.isHandsFree)
}

@Test func fnPressFinishesHandsFreeAndItsReleaseIsIgnored() {
    var g = handsFree()
    #expect(run(&g, [(.fnUp, 400), (.fnDown, 9_000), (.fnUp, 9_100)]) == [.none, .finish, .none])
    #expect(!g.isListening && !g.isHandsFree)
}

@Test func handsFreeCapFinishes() {
    var g = handsFree(.init(handsFreeCapMs: 1_000))
    #expect(g.tick(atMs: 1_299) == .none)
    #expect(g.tick(atMs: 1_300) == .finish)
    #expect(!g.isListening)
}

@Test func escapeCancelsInEveryPhase() {
    var idle = IncantGesture()
    #expect(run(&idle, [(.escape, 0)]) == [.none])
    var held = IncantGesture()
    #expect(run(&held, [(.fnDown, 0), (.escape, 50)]) == [.start, .cancel])
    var tapped = IncantGesture()
    #expect(run(&tapped, [(.fnDown, 0), (.fnUp, 100), (.escape, 150)]) == [.start, .none, .cancel])
    var free = handsFree()
    #expect(run(&free, [(.fnUp, 400), (.escape, 2_000)]) == [.none, .cancel])
    #expect(!held.isListening && !tapped.isListening && !free.isListening)
}

@Test func fnChordCancels() {
    var g = IncantGesture()
    #expect(run(&g, [(.fnDown, 0), (.otherKeyDown, 50)]) == [.start, .cancel])
    #expect(!g.isListening)
    // Typing while hands-free with Fn up is not a chord.
    var free = handsFree()
    #expect(run(&free, [(.fnUp, 400), (.otherKeyDown, 500)]) == [.none, .none])
    #expect(free.isListening)
}

@Test func startIsReturnedExactlyOncePerSession() {
    var g = IncantGesture()
    let actions = run(&g, [(.fnDown, 0), (.fnDown, 30), (.fnUp, 100), (.fnDown, 300), (.fnDown, 320), (.fnUp, 400),
                           (.fnDown, 2_000), (.fnUp, 2_100)])
    #expect(actions.filter { $0 == .start }.count == 1)
    #expect(actions.last(where: { $0 != .none }) == .finish)
    #expect(run(&g, [(.fnDown, 3_000)]) == [.start]) // next session starts again
}

// MARK: - Settings

@Test func settingsRoundTripWithListsOnePerLine() {
    var s = IncantSettings()
    s.mode = .always; s.prompt = "p"; s.cues = ["um", "no,"]; s.model = "m"; s.keyterms = ["A B", "C"]
    #expect(s.rows[IncantSettings.cuesKey] == "um\nno,")
    #expect(IncantSettings.load(s.rows) == s)
    #expect(IncantSettings.load([:]) == IncantSettings())
    let loose = IncantSettings.load([IncantSettings.modeKey: "bogus", IncantSettings.keytermsKey: "\n A \n\n B\n"])
    #expect(loose.mode == .whenNeeded && loose.keyterms == ["A", "B"])
    let blank = [IncantSettings.promptKey: "  \n", IncantSettings.modelKey: "", IncantSettings.cuesKey: "\n \n",
                 IncantSettings.keytermsKey: " "]
    #expect(IncantSettings.load(blank) == IncantSettings())
}

// MARK: - Cues

@Test func cuesMatchOnWordBoundaries() {
    let cues = IncantSettings.defaultCues
    #expect(IncantCues.heard("three, no, four", cues: cues))
    #expect(IncantCues.heard("No, four", cues: cues))
    #expect(!IncantCues.heard("I know, right", cues: cues))
    #expect(!IncantCues.heard("the piano, the drums", cues: cues))
    #expect(IncantCues.heard("Tuesday, actually Wednesday", cues: cues))
    #expect(IncantCues.heard("Actually.", cues: cues))
    #expect(!IncantCues.heard("factually correct", cues: ["actually"]))
    #expect(!IncantCues.heard("actuallyish", cues: ["actually"]))
    #expect(!IncantCues.heard("no cue here", cues: ["no,"]))
}

// MARK: - Fix policy

private struct Boom: Error {}
private let always = { var s = IncantSettings(); s.mode = .always; return s }()
private let unexpected: @Sendable (String) async throws -> String = { _ in Issue.record("closure called"); return "x" }

@Test func fixSkipsWhenOffOrNoCue() async {
    var off = IncantSettings(); off.mode = .off
    let a = await IncantFix.run("three, no, four", settings: off, primary: unexpected, fallback: unexpected)
    #expect(a == IncantFixResult(text: "three, no, four", source: .none, ms: 0))
    let b = await IncantFix.run("hello there", settings: IncantSettings(), primary: unexpected, fallback: unexpected)
    #expect(b.source == .none && b.text == "hello there")
}

@Test func fixPrimarySucceeds() async {
    let r = await IncantFix.run("three, no, four", settings: IncantSettings(), primary: { _ in "four" }, fallback: unexpected)
    #expect(r.source == .primary && r.text == "four")
}

@Test func fixFallsBackWhenPrimaryThrows() async {
    let r = await IncantFix.run("a b", settings: always, primary: { _ in throw Boom() }, fallback: { _ in "b" })
    #expect(r.source == .fallback && r.text == "b")
}

@Test func fixRawWhenBothThrow() async {
    let r = await IncantFix.run("a b", settings: always, primary: { _ in throw Boom() }, fallback: { _ in throw Boom() })
    #expect(r.source == .raw && r.text == "a b")
}

@Test func fixRawPastCutoffAndCancelsLosers() async {
    // ponytail: up to 5 tries — the full suite starves the cooperative pool for ~1 s at startup (a 100 ms
    // sleep measured 1376 ms). An unenforced cutoff returns the 300 ms primary on every try, so it still fails.
    // The primary ignores cancellation (like a slow on-device call), so returning on time proves we don't await it.
    let deaf: @Sendable (String) async throws -> String = { _ in
        await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { c.resume() } }
        return "late"
    }
    var seen: [String] = []
    for _ in 0..<5 {
        let clock = ContinuousClock(), start = clock.now
        let r = await IncantFix.run("a b", settings: always, cutoffMs: 100, primary: deaf, fallback: unexpected)
        let took = clock.now - start
        if r.source == .raw && r.text == "a b" && took >= .milliseconds(100) && took < .milliseconds(150) { return }
        seen.append("\(r.source) \(took)")
    }
    Issue.record("never .raw within cutoff + 50 ms: \(seen)")
}

@Test func fixRejectsEmptyAndOverlongAnswers() async {
    let empty = await IncantFix.run("a b", settings: always, primary: { _ in " \"\" " }, fallback: { _ in "b" })
    #expect(empty.source == .fallback)
    let chatty = String(repeating: "x", count: 100) // > 1.5 × 20 + 40
    let long = await IncantFix.run(String(repeating: "y", count: 20), settings: always,
                                   primary: { _ in chatty }, fallback: nil)
    #expect(long.source == .raw)
    let fits = String(repeating: "x", count: 70) // = 1.5 × 20 + 40
    #expect(await IncantFix.run(String(repeating: "y", count: 20), settings: always,
                                primary: { _ in fits }, fallback: nil).source == .primary)
}

@Test func fixTrimsWhitespaceAndWrappingQuotes() async {
    for answer in ["  \"four\"\n", "“four”", "'four' ", "\n four \n"] {
        let r = await IncantFix.run("three, no, four", settings: always, primary: { _ in answer }, fallback: nil)
        #expect(r.text == "four", "\(answer)")
    }
}

// MARK: - Scribe

@Test func scribeURL() throws {
    let c = try #require(URLComponents(url: IncantScribe.url(keyterms: ["Claude Code", "GHL"]), resolvingAgainstBaseURL: false))
    #expect(c.scheme == "wss" && c.host == "api.elevenlabs.io" && c.path == "/v1/speech-to-text/realtime")
    let items = c.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    #expect(value("model_id") == "scribe_v2_realtime" && value("audio_format") == "pcm_16000")
    #expect(value("commit_strategy") == "manual" && value("no_verbatim") == "true" && value("language_code") == "en")
    #expect(items.filter { $0.name == "keyterms" }.map(\.value) == ["Claude Code", "GHL"])
}

@Test func scribeChunk() throws {
    let pcm = Data([0, 1, 254, 255])
    let s = IncantScribe.chunk(pcm, commit: true)
    #expect(s == #"{"message_type":"input_audio_chunk","audio_base_64":"AAH+/w==","commit":true,"sample_rate":16000}"#)
    let j = try #require(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    #expect(Data(base64Encoded: j["audio_base_64"] as? String ?? "") == pcm)
    #expect(IncantScribe.chunk(Data(), commit: false).contains(#""commit":false"#))
}

@Test func scribeDecode() {
    typealias E = IncantScribe.Event
    #expect(IncantScribe.decode(#"{"message_type":"session_started","session_id":"s"}"#) == E.started)
    #expect(IncantScribe.decode(#"{"message_type":"partial_transcript","text":"hel"}"#) == E.partial("hel"))
    #expect(IncantScribe.decode(#"{"message_type":"committed_transcript","text":"hello"}"#) == E.committed("hello"))
    #expect(IncantScribe.decode(#"{"message_type":"committed_transcript_with_timestamps","text":"hi","words":[]}"#)
            == E.committed("hi"))
    #expect(IncantScribe.decode(#"{"message_type":"auth_error","error":"bad key"}"#) == E.error(type: "auth_error", message: "bad key"))
    for type in ["error", "quota_exceeded", "rate_limited", "invalid_request"] {
        #expect(IncantScribe.decode(#"{"message_type":"\#(type)","message":"m"}"#) == E.error(type: type, message: "m"))
    }
    #expect(IncantScribe.decode(#"{"message_type":"something_new"}"#) == E.other("something_new"))
    #expect(IncantScribe.decode("not json") == E.other(""))
}

// MARK: - Cerebras

@Test func cerebrasRequest() throws {
    let r = IncantCerebras.request(text: "t", instructions: "i", model: "m", apiKey: "k")
    #expect(r.url?.absoluteString == "https://api.cerebras.ai/v1/chat/completions" && r.httpMethod == "POST")
    #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    let j = try #require(JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
    #expect(j["model"] as? String == "m" && j["temperature"] as? Int == 0 && j["max_tokens"] as? Int == 400)
    let msgs = j["messages"] as? [[String: String]]
    #expect(msgs == [["role": "system", "content": "i"], ["role": "user", "content": "t"]])
}

@Test func cerebrasParse() throws {
    let ok = Data(#"{"choices":[{"message":{"role":"assistant","content":"four"}}]}"#.utf8)
    #expect(try IncantCerebras.parse(ok, status: 200) == "four")
    #expect(throws: IncantCerebras.Failure.rateLimited) { try IncantCerebras.parse(Data(), status: 429) }
    #expect(throws: IncantCerebras.Failure.http(500, "oops")) { try IncantCerebras.parse(Data("oops".utf8), status: 500) }
    #expect(throws: IncantCerebras.Failure.malformed) { try IncantCerebras.parse(Data("nope".utf8), status: 200) }
    #expect(throws: IncantCerebras.Failure.malformed) { try IncantCerebras.parse(Data(#"{"choices":[]}"#.utf8), status: 200) }
}

@Suite struct IncantFillersAndHedgeTests {
    @Test func fillersAreStrippedAsWholeWords() {
        #expect(IncantFillers.strip("Um, I need four bottles.") == "I need four bottles.")
        #expect(IncantFillers.strip("So uh we should, um, ship it") == "So we should, ship it")
        #expect(IncantFillers.strip("Ummm uhh hmm okay") == "Okay")
        #expect(IncantFillers.strip("The umbrella and the user, erm, left") == "The umbrella and the user, left")
        #expect(IncantFillers.strip("No fillers here.") == "No fillers here.")
        #expect(IncantFillers.strip("To err is human") == "To err is human")
        #expect(IncantFillers.strip("uh-huh, and uh-oh") == "uh-huh, and uh-oh")
        #expect(IncantFillers.strip("I think, um.") == "I think.")
        #expect(IncantFillers.strip("An em dash") == "An em dash")
    }

    @Test func noPassStillStripsFillers() async {
        let r = await IncantFix.run("Um, hello there", settings: IncantSettings(), primary: { _ in "x" }, fallback: nil)
        #expect(r.source == .none && r.text == "Hello there")
    }

    @Test func slowPrimaryIsCoveredByTheHedgedFallback() async {
        var always = IncantSettings(); always.mode = .always
        // Retried like the cutoff test: under full-suite load the shared async pool can stall ~1 s at start.
        var best = Double.infinity
        for _ in 0..<5 {
            let t = Date()
            let r = await IncantFix.run("a b", settings: always, cutoffMs: 600, hedgeMs: 50,
                                        primary: { _ in try await Task.sleep(for: .milliseconds(500)); return "slow" },
                                        fallback: { _ in "fast" })
            #expect(r.source == .fallback && r.text == "fast")
            best = min(best, Date().timeIntervalSince(t))
            if best < 0.3 { break }
        }
        #expect(best < 0.3)
    }
}

@Suite struct IncantPromptTests {
    @Test func instructionsCarryTheVocabularyAndTheNoExecuteRule() {
        let s = IncantSettings()
        #expect(s.instructions.hasPrefix(s.prompt) && s.instructions.contains("ExampleCRM, ExampleData"))
        #expect(s.prompt.contains("Never fulfill, answer, or execute") && s.prompt.contains("EMPTY"))
        var none = IncantSettings(); none.keyterms = []
        #expect(none.instructions == none.prompt)
    }

    @Test func emptyAnswerPastesNothing() async {
        var always = IncantSettings(); always.mode = .always
        let r = await IncantFix.run("the thing", settings: always, primary: { _ in "EMPTY" }, fallback: nil)
        #expect(r.text.isEmpty)
    }
}

@Suite struct IncantScribeURLTests {
    @Test func plusInKeytermsIsEncoded() {
        let q = IncantScribe.url(keyterms: ["C++", "ExampleCRM"]).absoluteString
        #expect(q.contains("keyterms=C%2B%2B") && q.contains("keyterms=ExampleCRM") && !q.contains("C++"))
    }
}
