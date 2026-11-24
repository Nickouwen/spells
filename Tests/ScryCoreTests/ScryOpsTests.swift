import Foundation
import Testing
@testable import ScryPipeline
import ScryCore

/// A temporary vault: AGENTS.md, a deals note and a hidden .obsidian folder. Never a real vault.
private func tempVault() throws -> URL {
    let v = FileManager.default.temporaryDirectory.appending(path: "scry-ops-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: v.appending(path: "deals"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: v.appending(path: ".obsidian"), withIntermediateDirectories: true)
    try "# Rules\n".write(to: v.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
    try "# 142 Lake Shore\n\nListed.\n".write(to: v.appending(path: "deals/142-lake-shore.md"), atomically: true, encoding: .utf8)
    return v
}

@Test func opsRedactsWhatMustNeverReachTheVault() {
    func r(_ s: String) -> String { ScryOps.redacted(s) }
    #expect(r("SSN 123-45-6789 on file") == "SSN [removed] on file")
    #expect(r("her social security number is 123456789.") == "her social security number is [removed].")
    #expect(r("card 4111 1111 1111 1111 exp 09/28") == "card [removed] exp 09/28")
    #expect(r("call 555-123-4567 or case 2024-CP-10-01234, $86,128") == "call 555-123-4567 or case 2024-CP-10-01234, $86,128")
    #expect(r("routing number 021000021, account # 1234567890") == "routing number [removed], account # [removed]")
    #expect(r("the account ending 4821") == "the account ending 4821")   // a last 4 is fine
    #expect(r("IBAN: DE89370400440532013000") == "IBAN: [removed]")
    #expect(r("password is hunter2!") == "password is [removed]")
    #expect(r("the password is in 1Password") == "the password is in 1Password")
    #expect(r("door PIN: 4471") == "door PIN: [removed]")
    #expect(r("key sk-ant-api03-abcdefghijklmnopqrstuvwx and xoxb-1234-5678-abcdefgh") == "key [removed] and [removed]")
    #expect(r("API key: 9f8e7d6c5b4a39281706f5e4") == "API key: [removed]")
}

@Test func savedNotesLeaveOutNumbersOnly() {
    func r(_ s: String) -> String { ScryOps.redacted(s, numbersOnly: true) }
    #expect(r("Do you need my social? It's 123-45-6789.") == "Do you need my social? It's [removed].")
    #expect(r("my social is 123 45 6789") == "my social is [removed]" && r("Social: 123, 45, 6789") == "Social: [removed]")
    #expect(r("card 4111 1111 1111 1111") == "card [removed]" && r("routing number 021000021") == "routing number [removed]")
    #expect(r("call 864-555-0142, case 2026-CP-23-01234, $14,500") == "call 864-555-0142, case 2026-CP-23-01234, $14,500")
    #expect(r("social media had 1,200 views in 2026") == "social media had 1,200 views in 2026")
    #expect(r("the password is hunter2!") == "the password is hunter2!")   // not a number: your words stay
}

@Test func opsWritesOnlyInsideTheVault() throws {
    let v = try tempVault()
    defer { try? FileManager.default.removeItem(at: v) }
    #expect(ScryOps.target("deals/142-lake-shore.md", in: v) != nil)
    #expect(ScryOps.target("people/new-person.md", in: v) != nil)   // a new folder is fine
    for bad in ["../x.md", "/etc/x.md", "~/x.md", "deals/../../x.md", ".obsidian/x.md", "AGENTS.md", "deals/AGENTS.md",
                "deals/note.txt", "deals//x.md", ""] {
        #expect(ScryOps.target(bad, in: v) == nil, "\(bad)")
    }
    // A symlinked folder that leads out of the vault.
    let outside = FileManager.default.temporaryDirectory.appending(path: "scry-ops-out-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: v.appending(path: "escape"), withDestinationURL: outside)
    #expect(ScryOps.target("escape/x.md", in: v) == nil)
    // A note that is itself a symlink out of the vault.
    try "x".write(to: outside.appending(path: "other.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: v.appending(path: "deals/link.md"), withDestinationURL: outside.appending(path: "other.md"))
    #expect(ScryOps.target("deals/link.md", in: v) == nil)
    // A vault folder that doesn't exist (a typo, not synced yet) gets nothing written, and no new folder.
    #expect(ScryOps.target("deals/x.md", in: v.appending(path: "missing")) == nil)
}

@Test func opsPushAppendsOrCreatesWithASourceLineAndDeletesNothing() throws {
    let v = try tempVault()
    defer { try? FileManager.default.removeItem(at: v) }
    let offer = ScryOps.Offer(transcript: "/x/2026-11-17-1039-listing.md", date: "2026-11-17", items: [
        .init(kind: "deal", title: "Lake Shore", path: "deals/142-lake-shore.md", text: "## Update\n\nOffer at $86,128. Seller SSN 123-45-6789."),
        .init(kind: "person", title: "Max", path: "people/max.md", text: "---\ntype: person\n---\n# Max\n\nRuns the dialer."),
        .init(kind: "deal", title: "Lake Shore again", path: "deals/142-lake-shore.md", text: "## Also\n\nClosing Friday."),
        .init(kind: "x", title: "bad", path: "../outside.md", text: "nope"),
    ])
    let (written, failed) = ScryOps.push(offer, vault: v)
    #expect(written == ["deals/142-lake-shore.md", "people/max.md"] && failed == 1)   // the unsafe path counts as failed
    let deal = try String(contentsOf: v.appending(path: "deals/142-lake-shore.md"), encoding: .utf8)
    let source = "Source: 2026-11-17-1039-listing.md (2026-11-17), filed by Scry."
    #expect(deal == "# 142 Lake Shore\n\nListed.\n\n\n## Update\n\nOffer at $86,128. Seller SSN [removed].\n\n\(source)\n\n\n## Also\n\nClosing Friday.\n\n\(source)\n")
    let max = try String(contentsOf: v.appending(path: "people/max.md"), encoding: .utf8)
    #expect(max == "---\ntype: person\n---\n# Max\n\nRuns the dialer.\n\n\(source)\n")
    #expect(!FileManager.default.fileExists(atPath: v.deletingLastPathComponent().appending(path: "outside.md").path))
    #expect(try String(contentsOf: v.appending(path: "AGENTS.md"), encoding: .utf8) == "# Rules\n")
}

@Test func opsParsesTheReplyAndListsTheVault() throws {
    let reply = """
    Here you go:
    {"items": [{"kind": "decision", "title": "T", "path": "decisions/x.md", "text": "We use {braces}."},
               {"kind": "ask", "title": "no path", "text": "x"}, {"kind": "ask", "path": "a.md", "text": "  "}]}
    """
    #expect(try ScryOps.parse(reply) == [.init(kind: "decision", title: "T", path: "decisions/x.md", text: "We use {braces}.")])
    #expect(try ScryOps.parse(#"{"items": []}"#).isEmpty)
    #expect(throws: (any Error).self) { try ScryOps.parse("no json") }
    let v = try tempVault()
    defer { try? FileManager.default.removeItem(at: v) }
    try "x".write(to: v.appending(path: ".obsidian/workspace.md"), atomically: true, encoding: .utf8)
    #expect(ScryOps.index(v) == ["AGENTS.md", "deals/142-lake-shore.md"])
    #expect(ScryOps.callDate("---\ntitle: \"x\"\ndate: 2026-11-17\nstart: …\n---\n") == "2026-11-17")
    let p = ScryOps.prompt(transcript: "T", name: "n.md", date: "2026-11-17", agents: nil, notes: ScryOps.index(v), userName: "Nic")
    #expect(p.contains("deals/142-lake-shore.md") && p.contains("asked Nic to do") && p.contains("(none)"))
    // Your own rules replace the built-in list.
    let own = ScryOps.prompt(transcript: "T", name: "n.md", date: "d", agents: nil, notes: [], userName: "Nic",
                             rules: "- listing: a property and its asking price")
    #expect(own.contains("- listing: a property and its asking price") && !own.contains("asked Nic to do"))
}

@Test func opsStateTakesEachNewTranscriptOnceAndNoBacklog() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "scry-ops-src-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func file(_ name: String, minutesAgo: Double) throws -> URL {
        let u = folder.appending(path: name)
        try "t".write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: u.path)
        return u
    }
    _ = try file("old.md", minutesAgo: 600)
    var state = ScryOps.State()
    #expect(state.newTranscripts(in: [folder], now: Date().addingTimeInterval(-300 * 60)).isEmpty)   // first look: marks only
    let new = try file("sub/gemini.txt", minutesAgo: 10)
    _ = try file("writing.md", minutesAgo: 0.5)   // still being written
    _ = try file("audio.m4a", minutesAgo: 10)
    #expect(state.newTranscripts(in: [folder]).map(\.lastPathComponent) == [new.lastPathComponent])
    state.transcripts[new.standardizedFileURL.path] = .init(status: .nothing)
    #expect(state.newTranscripts(in: [folder]).isEmpty)
    // Waiting offers survive a save and load.
    let offer = ScryOps.Offer(transcript: "/t.md", date: "2026-11-17", items: [.init(kind: "ask", title: "a", path: "a.md", text: "b")])
    state.transcripts["/t.md"] = .init(status: .offered, offer: offer)
    let url = folder.appending(path: "state.json")
    try state.save(url)
    #expect(ScryOps.State.load(url).waiting == [offer])
    // A failed read is tried again, 10 minutes later, up to 3 times; a read that worked never.
    state.transcripts["/f.md"] = .init(status: .failed, at: Date().addingTimeInterval(-900), attempts: 2)
    #expect(state.mayRead("/f.md") && !state.mayRead("/t.md") && state.mayRead("/new.md"))
    #expect(state.retries().map(\.path) == ["/f.md"])
    state.transcripts["/f.md"]?.attempts = 3
    #expect(!state.mayRead("/f.md") && state.retries().isEmpty)
}

@Test func opsSettingsAreOffAndEmptyByDefault() {
    let s = ScrySettings()
    #expect(!s.opsPush && s.opsVault.isEmpty && s.opsSources.isEmpty && s.opsSlackUser.isEmpty)
    var t = s
    t.opsPush = true; t.opsVault = "~/Ops"; t.opsSources = ["~/Gemini", "/tmp/Whisper"]; t.opsSlackUser = "U123"; t.opsRules = "- deal: x\n- ask: y"
    #expect(ScrySettings.load(t.rows) == t)
    #expect(ScrySettings.folder("relative") == nil && ScrySettings.folder("  ") == nil && ScrySettings.folder("~/Ops")?.path.hasSuffix("/Ops") == true)
}
