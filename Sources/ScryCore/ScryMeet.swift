import Foundation

/// Who's speaking on a Google Meet call, read from the Meet tab's page rather than from the audio: each
/// participant tile carries the display name, and Meet marks the active speaker's tile with a class that
/// moves to whoever is talking. The reading happens in the browser (`ScryMeet.script`, run through Chrome's
/// "Allow JavaScript from Apple Events"); everything that decides what a sample means is here, so it's
/// testable without a call.
///
/// Meet's class names are build artefacts that change between releases (`v5h6Xc` was it on 2026-10-23), so
/// `Marker` rediscovers the one that sits on exactly one tile nearly every sample and moves between tiles.
/// Matching nothing means no hints — never a guess.
public enum ScryMeet {
    /// Runs inside the Meet tab. One entry per `[data-participant-id]` element: the id, the text lines in it,
    /// every DOM class in its subtree (capped), and whether it's your own tile (`data-self-name`). The page's
    /// own name for you comes along so your tile is dropped even when it just says "You".
    public static let script = """
    (function () {
      var out = [];
      var selfEl = document.querySelector('[data-self-name]');
      document.querySelectorAll('[data-participant-id]').forEach(function (t) {
        var cls = {}, n = 0, el = t;
        var w = document.createTreeWalker(t, NodeFilter.SHOW_ELEMENT);
        do { if (el.classList) { el.classList.forEach(function (c) { cls[c] = 1; }); } n++; } while ((el = w.nextNode()) && n < 400);
        var lines = (t.innerText || '').split('\\n').map(function (s) { return s.trim(); }).filter(Boolean).slice(0, 6);
        out.push({ id: t.getAttribute('data-participant-id'), self: t.hasAttribute('data-self-name') || !!t.querySelector('[data-self-name]'),
                   lines: lines, classes: Object.keys(cls) });
      });
      return JSON.stringify({ selfName: selfEl ? selfEl.getAttribute('data-self-name') : null, tiles: out });
    })()
    """

    public struct Tile: Equatable, Sendable {
        public var id: String, name: String?, isSelf: Bool, classes: Set<String>
        public init(id: String, name: String?, isSelf: Bool, classes: Set<String>) {
            self.id = id; self.name = name; self.isSelf = isSelf; self.classes = classes
        }
    }

    public struct Sample: Equatable, Sendable {
        public var selfName: String?
        public var tiles: [Tile]
        /// Everyone on the call right now, by display name, you included (your tile's name, or `selfName`).
        public var participants: [String] {
            var out: [String] = []
            for t in tiles {
                guard let n = t.name ?? (t.isSelf ? selfName : nil), !out.contains(n) else { continue }
                out.append(n)
            }
            return out
        }
    }

    private struct Raw: Decodable {
        struct T: Decodable { var id: String?, lines: [String]?, classes: [String]?, isSelf: Bool?
            enum CodingKeys: String, CodingKey { case id, lines, classes, isSelf = "self" } }
        var selfName: String?, tiles: [T]?
    }

    /// The script's JSON → one sample. The same participant can show twice (a video tile and a row in the
    /// People panel): those merge by id, classes unioned. A tile's name is its first line that looks like a
    /// name ("Teagan Trapp (Presenting)" → "Teagan Trapp"; "You", "Meeting host", "12:03" don't).
    public static func sample(fromJSON json: String) -> Sample? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else { return nil }
        var tiles: [Tile] = []
        for t in raw.tiles ?? [] {
            guard let id = t.id, !id.isEmpty else { continue }
            let name = (t.lines ?? []).lazy.compactMap(tileName).first
            let isSelf = t.isSelf ?? false
            if let i = tiles.firstIndex(where: { $0.id == id }) {
                tiles[i].classes.formUnion(t.classes ?? [])
                tiles[i].isSelf = tiles[i].isSelf || isSelf
                if tiles[i].name == nil { tiles[i].name = name }
            } else {
                tiles.append(Tile(id: id, name: name, isSelf: isSelf, classes: Set(t.classes ?? [])))
            }
        }
        return Sample(selfName: raw.selfName.flatMap { $0.isEmpty ? nil : $0 }, tiles: tiles)
    }

    /// A tile line → a display name, or nil for Meet chrome and status text. "(…)" suffixes are trimmed.
    public static func tileName(_ line: String) -> String? {
        let name = line.replacing(/\s*\([^)]*\)\s*$/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.lowercased() != "you", let n = ScryNames.candidate(name) else { return nil }
        return n
    }

    /// The class on the active speaker's tile, kept across samples: the known one while it's seen, otherwise
    /// rediscovered from the last `window` samples as the class that is on exactly one tile in ≥ 90% of them
    /// and has moved between at least two tiles (so a per-tile layout class never qualifies).
    public struct Marker: Sendable {
        public static let known: Set<String> = ["v5h6Xc"]
        public var window = 60, minSamples = 20
        private var history: [[Tile]] = []
        public private(set) var current: String?
        public init() {}

        /// Feeds a sample; the tile Meet marks as speaking in it, if exactly one is marked.
        public mutating func speaking(_ sample: Sample) -> Tile? {
            let tiles = sample.tiles
            guard tiles.count >= 2 else { return nil }   // alone on the call: nothing to attribute
            history.append(tiles)
            if history.count > window { history.removeFirst(history.count - window) }
            current = Self.known.first { k in tiles.contains { $0.classes.contains(k) } } ?? rediscovered()
            guard let m = current else { return nil }
            let holding = tiles.filter { $0.classes.contains(m) }
            return holding.count == 1 ? holding[0] : nil
        }

        private func rediscovered() -> String? {
            guard history.count >= minSamples else { return nil }
            var exclusive: [String: Int] = [:], holders: [String: Set<String>] = [:]
            for sample in history {
                var on: [String: [String]] = [:]
                for t in sample { for c in t.classes { on[c, default: []].append(t.id) } }
                for (c, ids) in on where ids.count == 1 {
                    exclusive[c, default: 0] += 1
                    holders[c, default: []].insert(ids[0])
                }
            }
            let need = Int((0.9 * Double(history.count)).rounded(.up))
            return exclusive.filter { $0.value >= need && (holders[$0.key]?.count ?? 0) >= 2 }
                .max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
        }
    }

    // MARK: - speakers.jsonl

    /// One line per poll in `speakers.jsonl`: `{"t": 12.5, "speaking": "Teagan Trapp"}` whenever someone other
    /// than you is marked as speaking (`t` = seconds since the recording started), and
    /// `{"t": 0.5, "participants": [...]}` whenever the set of people on the call changes.
    public struct Line: Codable, Equatable, Sendable {
        public var t: Double
        public var speaking: String?
        public var participants: [String]?
        public init(t: Double, speaking: String? = nil, participants: [String]? = nil) {
            self.t = t; self.speaking = speaking; self.participants = participants
        }
        public var encoded: String {
            let e = JSONEncoder(); e.outputFormatting = .sortedKeys
            return String(decoding: (try? e.encode(self)) ?? Data("{}".utf8), as: UTF8.self)
        }
    }

    public struct Hint: Equatable, Sendable {
        public var t: Double, name: String
        public init(t: Double, name: String) { self.t = t; self.name = name }
    }

    public struct Log: Equatable, Sendable {
        /// Everyone ever seen, in order of first appearance.
        public var participants: [String] = []
        public var hints: [Hint] = []
        public init(participants: [String] = [], hints: [Hint] = []) { self.participants = participants; self.hints = hints }
    }

    /// Parses `speakers.jsonl`; malformed lines are skipped.
    public static func log(fromJSONL text: String) -> Log {
        var out = Log()
        let d = JSONDecoder()
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let l = try? d.decode(Line.self, from: Data(raw.utf8)) else { continue }
            if let s = l.speaking { out.hints.append(Hint(t: l.t, name: s)) }
            for p in l.participants ?? [] where !out.participants.contains(p) { out.participants.append(p) }
        }
        return out
    }

    /// Diarized labels ("Speaker A"…) → Meet names, by vote: each hint goes to the far-side turn it falls in
    /// (± `slack`, the page and the audio don't line up exactly). A label takes the name with more than half of
    /// its votes and at least `minVotes`; a name goes to one label only, the one with the most votes for it.
    /// Hints in your own name are ignored: your voice is the mic channel, never a far-side speaker, and with
    /// speakers rather than headphones Meet keeps marking you while others talk.
    public static func names(for segments: [ScrySegment], hints: [Hint], owner: String,
                             slack: Double = 0.5, minVotes: Int = 4) -> [String: String] {
        let me = owner.lowercased(), meFirst = owner.split(separator: " ").first.map { $0.lowercased() } ?? ""
        let far = segments.filter { $0.speaker != "You" }.sorted { $0.start < $1.start }
        guard !far.isEmpty else { return [:] }
        var votes: [String: [String: Int]] = [:]
        for h in hints {
            let n = h.name.lowercased()
            if n == me || (!meFirst.isEmpty && n.split(separator: " ").first.map(String.init) == meFirst) { continue }
            let inside = far.filter { $0.start - slack <= h.t && h.t <= $0.end + slack }
            guard inside.count == 1 || Set(inside.map(\.speaker)).count == 1, let label = inside.first?.speaker else { continue }
            votes[label, default: [:]][h.name, default: 0] += 1
        }
        // Each label's winner, then each name's strongest label.
        var claim: [String: (label: String, votes: Int)] = [:]
        for (label, byName) in votes {
            let total = byName.values.reduce(0, +)
            guard let (name, v) = byName.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }),
                  v >= minVotes, Double(v) > Double(total) / 2 else { continue }
            if let c = claim[name], c.votes >= v { continue }
            claim[name] = (label, v)
        }
        return Dictionary(uniqueKeysWithValues: claim.map { ($0.value.label, $0.key) })
    }
}
