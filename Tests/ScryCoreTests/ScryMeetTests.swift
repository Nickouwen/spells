import Foundation
import Testing
@testable import ScryCore

private func tile(_ id: String, _ name: String?, self isSelf: Bool = false, _ classes: Set<String>) -> ScryMeet.Tile {
    ScryMeet.Tile(id: id, name: name, isSelf: isSelf, classes: classes)
}

@Test func meetSampleMergesTilesAndPicksNames() {
    let json = """
    {"selfName":"Nic Kouwen","tiles":[
      {"id":"a","self":true,"lines":["You"],"classes":["x","y"]},
      {"id":"b","self":false,"lines":["Teagan Trapp (Presenting)","Meeting host"],"classes":["x","v5h6Xc"]},
      {"id":"b","self":false,"lines":["Teagan Trapp"],"classes":["row"]},
      {"id":"c","self":false,"lines":["12:03","Mute"],"classes":["x"]},
      {"id":"","lines":["Ghost"],"classes":[]}
    ]}
    """
    let s = ScryMeet.sample(fromJSON: json)!
    #expect(s.selfName == "Nic Kouwen")
    #expect(s.tiles.map(\.id) == ["a", "b", "c"])
    #expect(s.tiles[0].isSelf && s.tiles[0].name == nil)
    #expect(s.tiles[1].name == "Teagan Trapp")
    #expect(s.tiles[1].classes == ["x", "v5h6Xc", "row"])
    #expect(s.tiles[2].name == nil)
    #expect(s.participants == ["Nic Kouwen", "Teagan Trapp"])
    #expect(ScryMeet.sample(fromJSON: "not json") == nil)
}

@Test func meetTileNamesSkipChrome() {
    #expect(ScryMeet.tileName("Teagan Trapp (Presenting)") == "Teagan Trapp")
    #expect(ScryMeet.tileName("Alex (You)") == "Alex")
    #expect(ScryMeet.tileName("You") == nil)
    #expect(ScryMeet.tileName("Meeting host") == nil)
    #expect(ScryMeet.tileName("12:03") == nil)
    #expect(ScryMeet.tileName("Teagan's Loom Notetaker") == nil)
}

@Test func meetMarkerUsesTheKnownClassThenRediscovers() {
    var m = ScryMeet.Marker()
    let known = ScryMeet.Sample(selfName: nil, tiles: [tile("a", "Nic", ["x"]), tile("b", "Teagan", ["x", "v5h6Xc"])])
    #expect(m.speaking(known)?.name == "Teagan")
    #expect(m.current == "v5h6Xc")
    // Alone on the call: never a hint.
    #expect(m.speaking(ScryMeet.Sample(selfName: nil, tiles: [tile("a", "Nic", ["x", "v5h6Xc"])])) == nil)

    // Meet shipped a new build: the class is now "q1", moving between tiles; "lay" sits on one tile always.
    var r = ScryMeet.Marker()
    for i in 0..<19 {
        let on = i % 2 == 0 ? "a" : "b"
        let s = ScryMeet.Sample(selfName: nil, tiles: [tile("a", "Nic", on == "a" ? ["x", "q1", "lay"] : ["x", "lay"]),
                                                       tile("b", "Teagan", on == "b" ? ["x", "q1"] : ["x"])])
        #expect(r.speaking(s) == nil)   // under minSamples: no guess
    }
    let s20 = ScryMeet.Sample(selfName: nil, tiles: [tile("a", "Nic", ["x", "lay"]), tile("b", "Teagan", ["x", "q1"])])
    #expect(r.speaking(s20)?.name == "Teagan")
    #expect(r.current == "q1")
    // A class on both tiles at once: nobody.
    let both = ScryMeet.Sample(selfName: nil, tiles: [tile("a", "Nic", ["x", "q1", "lay"]), tile("b", "Teagan", ["x", "q1"])])
    #expect(r.speaking(both) == nil)
}

@Test func meetLogParsesLinesAndRoundTrips() {
    let l1 = ScryMeet.Line(t: 0.5, participants: ["Nic Kouwen", "Teagan Trapp"])
    let l2 = ScryMeet.Line(t: 1, speaking: "Teagan Trapp")
    #expect(l1.encoded == #"{"participants":["Nic Kouwen","Teagan Trapp"],"t":0.5}"#)
    #expect(l2.encoded == #"{"speaking":"Teagan Trapp","t":1}"#)
    let log = ScryMeet.log(fromJSONL: [l1.encoded, "garbage", l2.encoded, ScryMeet.Line(t: 9, participants: ["Teagan Trapp", "Alex"]).encoded].joined(separator: "\n"))
    #expect(log.participants == ["Nic Kouwen", "Teagan Trapp", "Alex"])
    #expect(log.hints == [ScryMeet.Hint(t: 1, name: "Teagan Trapp")])
}

@Test func meetNamesVoteAcrossTurns() {
    let segs = [
        ScrySegment(speaker: "You", start: 0, end: 5, text: "hi"),
        ScrySegment(speaker: "Speaker A", start: 5, end: 15, text: "a"),
        ScrySegment(speaker: "Speaker B", start: 16, end: 24, text: "b"),
        ScrySegment(speaker: "Speaker A", start: 25, end: 30, text: "a2"),
    ]
    var hints: [ScryMeet.Hint] = []
    for t in stride(from: 5.5, through: 14.5, by: 0.5) { hints.append(.init(t: t, name: "Teagan Trapp")) }
    for t in stride(from: 16.5, through: 23.5, by: 0.5) { hints.append(.init(t: t, name: "Alex Chen")) }
    hints.append(.init(t: 26, name: "Teagan Trapp")); hints.append(.init(t: 27, name: "Alex Chen"))
    // Your own tile lights up during A's turn (speakers, not headphones): ignored.
    for t in stride(from: 6.0, through: 12, by: 0.5) { hints.append(.init(t: t, name: "Nic Kouwen")) }
    #expect(ScryMeet.names(for: segs, hints: hints, owner: "Nic Kouwen") == ["Speaker A": "Teagan Trapp", "Speaker B": "Alex Chen"])
    #expect(ScryMeet.names(for: segs, hints: hints, owner: "Nic") == ["Speaker A": "Teagan Trapp", "Speaker B": "Alex Chen"])

    // Too few votes, or no majority: unnamed, never a guess.
    #expect(ScryMeet.names(for: segs, hints: [.init(t: 6, name: "Teagan Trapp"), .init(t: 7, name: "Teagan Trapp")], owner: "Nic").isEmpty)
    let split = (0..<6).map { ScryMeet.Hint(t: 6 + Double($0), name: "Teagan Trapp") } + (0..<6).map { ScryMeet.Hint(t: 9 + Double($0) * 0.5, name: "Alex Chen") }
    #expect(ScryMeet.names(for: segs, hints: split, owner: "Nic").isEmpty)

    // One name, two labels (a voice split by the diarizer): the label with more votes gets it.
    let twoLabels = (0..<10).map { ScryMeet.Hint(t: 5.5 + Double($0), name: "Teagan Trapp") } + (0..<5).map { ScryMeet.Hint(t: 17 + Double($0), name: "Teagan Trapp") }
    #expect(ScryMeet.names(for: segs, hints: twoLabels, owner: "Nic") == ["Speaker A": "Teagan Trapp"])
    #expect(ScryMeet.names(for: [], hints: hints, owner: "Nic").isEmpty)
}

@Test func meetScriptIsPlainJavaScript() {
    // The snippet is embedded in an AppleScript string: no backticks or template literals, returns a string.
    #expect(!ScryMeet.script.contains("`"))
    #expect(ScryMeet.script.contains("JSON.stringify"))
    #expect(ScryMeet.script.hasPrefix("(function") && ScryMeet.script.hasSuffix("})()"))
}
