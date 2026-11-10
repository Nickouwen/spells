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

@Test func fixDropsTheTrailingPeriodOnEveryPath() async {
    // The model's answer, the raw Scribe text when no pass is needed, and the raw text after a failed pass.
    #expect(await IncantFix.run("fix the build", settings: always, primary: { _ in "Fix the build." }, fallback: nil).text == "Fix the build")
    #expect(await IncantFix.run("fix the build.", settings: IncantSettings(), primary: { _ in "x" }, fallback: nil).text == "fix the build")
    #expect(await IncantFix.run("fix the build. ", settings: always, primary: { _ in throw CancellationError() }, fallback: nil).text == "fix the build")
    // Only one final full stop goes; everything else stays as it was.
    #expect(IncantFix.withoutTrailingPeriod("Really?") == "Really?")
    #expect(IncantFix.withoutTrailingPeriod("Wait...") == "Wait...")
    #expect(IncantFix.withoutTrailingPeriod("Two sentences. Second one.") == "Two sentences. Second one")
    #expect(IncantFix.withoutTrailingPeriod("open main.swift") == "open main.swift")
    #expect(IncantFix.withoutTrailingPeriod("line one.\nline two.\n") == "line one.\nline two")
    #expect(IncantFix.withoutTrailingPeriod("") == "")
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
    #expect(j["reasoning_effort"] as? String == "none")
    let oss = IncantCerebras.request(text: "t", instructions: "i", model: "gpt-oss-120b", apiKey: "k")
    #expect((try JSONSerialization.jsonObject(with: oss.httpBody ?? Data()) as? [String: Any])?["reasoning_effort"] as? String == "low")
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

    @Test func anEmptyAnswerNeverDropsRealWords() async {
        var always = IncantSettings(); always.mode = .always
        let r = await IncantFix.run("Next.", settings: always, primary: { _ in "EMPTY" }, fallback: nil)
        #expect(r.text == "Next" && r.source == .primary)
        let um = await IncantFix.run("Um, uh.", settings: always, primary: { _ in "EMPTY" }, fallback: nil)
        #expect(um.text.isEmpty)   // only hesitation sounds: stripped before the model, nothing typed
    }
}

@Suite struct IncantScribeURLTests {
    @Test func plusInKeytermsIsEncoded() {
        let q = IncantScribe.url(keyterms: ["C++", "ExampleCRM"]).absoluteString
        #expect(q.contains("keyterms=C%2B%2B") && q.contains("keyterms=ExampleCRM") && !q.contains("C++"))
    }
}

@Suite struct IncantStreamTests {
    @Test func streamSettingRoundTrips() {
        var s = IncantSettings(); s.stream = true
        #expect(s.rows[IncantSettings.streamKey] == "1")
        #expect(IncantSettings.load(s.rows) == s)
        #expect(IncantSettings.load([IncantSettings.streamKey: "0"]).stream == false)
        #expect(IncantSettings().stream == false)
    }

    @Test func perSentenceCorrectsAlwaysUnlessOff() {
        var s = IncantSettings(); s.mode = .whenNeeded
        #expect(s.perSentence.mode == .always)
        s.mode = .off
        #expect(s.perSentence.mode == .off)
    }

    @Test func vadURLCommitsOnPauses() throws {
        let c = try #require(URLComponents(url: IncantScribe.url(keyterms: [], vad: true), resolvingAgainstBaseURL: false))
        #expect(c.queryItems?.first { $0.name == "commit_strategy" }?.value == "vad")
    }

    @Test func sentencesJoinWithTheStopThePassRemoved() {
        #expect(IncantStream.joiner(after: "", before: "Hello") == "")
        #expect(IncantStream.joiner(after: "Fix the auth module", before: "Then run the tests") == ". ")
        #expect(IncantStream.joiner(after: "Is it done?", before: "Check again") == " ")
        #expect(IncantStream.joiner(after: "First,", before: "the tests") == " ")
        #expect(IncantStream.joiner(after: "He said \"fine\"", before: "Then left") == ". ")
        #expect(IncantStream.joiner(after: "He said \"fine.\"", before: "Then left") == " ")
        #expect(IncantStream.joiner(after: "Title", before: "\nBody") == "")
        #expect(IncantStream.joiner(after: "Line one\n", before: "Line two") == "")
        #expect(IncantStream.unjoined(". Then left") == "Then left")
        #expect(IncantStream.unjoined(" and more") == "and more")
    }
}

@Suite struct IncantGhostTests {
    @Test func partialsAppendWithoutTheirTrailingMark() {
        var g = IncantGhost(lead: ". ")
        #expect(g.partial("This is a test-") == IncantGhost.Edit(delete: 0, text: ". This is a test"))
        #expect(g.partial("This is a test of the stream as I") == IncantGhost.Edit(delete: 0, text: " of the stream as I"))
        #expect(g.partial("") == IncantGhost.Edit(delete: 0, text: ""))   // keepalive
        #expect(g.partial("This is a test of the stream as I speak feature.") == IncantGhost.Edit(delete: 0, text: " speak feature"))
        #expect(g.typed == ". This is a test of the stream as I speak feature")
    }

    @Test func aRevisedTailIsDeletedAndRetyped() {
        var g = IncantGhost()
        _ = g.partial("It's currently not streaming at all.")
        #expect(g.partial("It's currently not streaming at all, which is an") == IncantGhost.Edit(delete: 0, text: ", which is an"))
        _ = g.partial("Let's fix the auth module")
        #expect(g.commit("Let's fix the billing module") == IncantGhost.Edit(delete: 11, text: "billing module"))
        #expect(g.commit("Let's fix the billing module").isEmpty)
        #expect(g.commit("") == IncantGhost.Edit(delete: 28, text: ""))   // only filler: it goes
        #expect(g.typed == "")
    }

    @Test func aCommitBeforeAnyPartialTypesTheWholeSentence() {
        var g = IncantGhost(lead: " ")
        #expect(g.commit("Is it done?") == IncantGhost.Edit(delete: 0, text: " Is it done?"))
        #expect(IncantGhost.open("Is it done? ") == "Is it done")
        #expect(IncantGhost.open("well…") == "well")
    }

    @Test func vadURLCarriesTheSilenceThreshold() throws {
        let c = try #require(URLComponents(url: IncantScribe.url(keyterms: [], vad: true), resolvingAgainstBaseURL: false))
        func value(_ n: String) -> String? { c.queryItems?.first { $0.name == n }?.value }
        #expect(value("vad_silence_threshold_secs") == "0.4" && value("min_silence_duration_ms") == "100")
        let manual = try #require(URLComponents(url: IncantScribe.url(keyterms: []), resolvingAgainstBaseURL: false))
        #expect(manual.queryItems?.contains { $0.name == "vad_silence_threshold_secs" } == false)
    }
}

@Suite struct IncantSeamTests {
    @Test func aSentenceInFlightReadsAsAContinuationUntilThePause() {
        var g = IncantGhost(lead: " ", continues: true)
        #expect(g.partial("So then we") == IncantGhost.Edit(delete: 0, text: " so then we"))
        #expect(g.partial("So then we can run the tests.") == IncantGhost.Edit(delete: 0, text: " can run the tests"))
        // The pause decided it was a new sentence: the one rewrite.
        #expect(g.commit("So then we can run the tests", lead: ". ")
                == IncantGhost.Edit(delete: 29, text: ". So then we can run the tests"))
        var c = IncantGhost(lead: " ", continues: true)
        _ = c.partial("But only after the tests pass")
        #expect(c.commit("but only after the tests pass", lead: ", ") == IncantGhost.Edit(delete: 30, text: ", but only after the tests pass"))
    }

    @Test func onlyWordsScribeCapitalizedForTheSegmentAreLowered() {
        #expect(IncantStream.continuing("So then we") == "so then we")
        #expect(IncantStream.continuing("Probably wait") == "probably wait")
        #expect(IncantStream.continuing("Priya wants it") == "Priya wants it")   // a name
        #expect(IncantStream.continuing("I think so") == "I think so")
        #expect(IncantStream.continuing("GitHub is down") == "GitHub is down")
        #expect(IncantStream.continuing("OK so") == "OK so")
    }

    @Test func aFallbackJoinCasesTheFirstWordToMatch() {
        #expect(IncantStream.cased("so then we", after: ". ") == "So then we")
        #expect(IncantStream.cased("so then we", after: "? ") == "So then we")
        #expect(IncantStream.cased("so then we", after: "") == "So then we")
        #expect(IncantStream.cased("so then we", after: "\n") == "So then we")
        #expect(IncantStream.cased("so then we", after: ", ") == "so then we")
        #expect(IncantStream.cased("so then we", after: " ") == "so then we")
    }

    @Test func thePausePassKeepsTheTypedWords() {
        let s = IncantSettings()
        #expect(s.seam.mode == .always && s.seam.instructions.contains("ALREADY_TYPED") && s.seam.instructions.contains("Vocabulary"))
    }
}

@Suite struct IncantPauseDotsTests {
    @Test func pauseDotsNeverReachTheApp() {
        #expect(IncantGhost.withoutPauseDots("This is a test... of the stream") == "This is a test of the stream")
        #expect(IncantGhost.withoutPauseDots("wait…") == "wait")
        #expect(IncantGhost.withoutPauseDots("so... um... let's go") == "so um let's go")
        #expect(IncantGhost.withoutPauseDots("one...two") == "onetwo" || IncantGhost.withoutPauseDots("one...two") == "one two")
        #expect(IncantGhost.withoutPauseDots("fine.") == "fine.")   // a single stop is not a pause
        var g = IncantGhost()
        _ = g.partial("This is a test...")
        #expect(g.partial("This is a test... of the stream") == IncantGhost.Edit(delete: 0, text: " of the stream"))
        #expect(g.commit("This is a test… of the stream").isEmpty)
    }
}

@Suite struct IncantJoinerByModelTests {
    @Test func thePausePassAsksForTheJoinerAsJSON() throws {
        let r = IncantCerebras.request(text: "then run the tests", instructions: "i", model: "m", apiKey: "k", after: "so let's fix the auth module")
        let j = try #require(JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
        #expect((j["messages"] as? [[String: String]])?.last?["content"] == "ALREADY_TYPED: so let's fix the auth module\nNEW_WORDS: then run the tests")
        let format = try #require((j["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])
        #expect(format["strict"] as? Bool == true)
        // An ordinary pass carries no format.
        let plain = IncantCerebras.request(text: "t", instructions: "i", model: "m", apiKey: "k")
        #expect((try JSONSerialization.jsonObject(with: plain.httpBody ?? Data()) as? [String: Any])?["response_format"] == nil)
    }

    @Test func thePausePassAnswerCarriesTheJoiner() throws {
        #expect(try IncantCerebras.seam(#"{"joiner": ". ", "text": "Then run the tests"}"#) == (". ", "Then run the tests"))
        #expect(try IncantCerebras.seam(#"{"joiner": "\n", "text": ""}"#) == ("\n", ""))   // only filler
        #expect(throws: IncantCerebras.Failure.malformed) { try IncantCerebras.seam(#"{"joiner": " — ", "text": "x"}"#) }
        #expect(throws: IncantCerebras.Failure.malformed) { try IncantCerebras.seam("Then run the tests") }
        #expect(IncantStream.context("one two three four five", words: 3) == "three four five")
    }

    @Test func aCommitCanChangeTheLeadItWasTypedWith() {
        var g = IncantGhost(lead: " ")
        _ = g.partial("then run the tests")
        #expect(g.commit("Then run the tests", lead: ". ") == IncantGhost.Edit(delete: 19, text: ". Then run the tests"))
        #expect(g.lead == ". ")
    }
}

@Suite struct IncantHistoryTests {
    @Test func theLastDictationsAreKeptInAPrivateFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "incant-history-\(UUID().uuidString)/history.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(IncantHistory.last(in: url) == nil)
        for i in 0..<(IncantHistory.keep + 3) {
            try IncantHistory.append(IncantHistoryEntry(at: Date(timeIntervalSince1970: Double(i)), app: "com.example.app",
                                                        raw: ["um line one", "line two"], text: "Line one.\nLine \(i)"), to: url)
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == IncantHistory.keep)   // one line each, the oldest dropped
        let last = try #require(IncantHistory.last(in: url))
        #expect(last.text == "Line one.\nLine \(IncantHistory.keep + 2)" && last.raw == ["um line one", "line two"] && last.app == "com.example.app")
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }
}
