import Foundation

/// Minimal DER: just enough to build a TimeStampReq and walk a TimeStampResp. Definite lengths only.
enum ExportDER {
    // MARK: encode

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func sequence(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func octets(_ b: [UInt8]) -> [UInt8] { tlv(0x04, b) }
    static let null: [UInt8] = [0x05, 0x00]
    static func bool(_ v: Bool) -> [UInt8] { [0x01, 0x01, v ? 0xFF : 0x00] }

    /// Non-negative INTEGER from big-endian magnitude bytes (leading zeros stripped, 0x00 pad if the top bit is set).
    static func unsigned(_ magnitude: [UInt8]) -> [UInt8] {
        var m = Array(magnitude.drop { $0 == 0 })
        if m.isEmpty { m = [0] } else if m[0] & 0x80 != 0 { m.insert(0, at: 0) }
        return tlv(0x02, m)
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").map { UInt64($0)! }
        var out: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var v = arc >> 7
            while v > 0 { chunk.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            out += chunk
        }
        return tlv(0x06, out)
    }

    private static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    // MARK: decode

    struct Node {
        var tag: UInt8
        /// The content octets.
        var body: ArraySlice<UInt8>
        /// The whole TLV.
        var raw: ArraySlice<UInt8>

        var children: [Node] { get throws { try ExportDER.parseAll(body) } }
        /// INTEGER content with leading zero bytes stripped (callers only compare magnitudes).
        var magnitude: [UInt8] { Array(body.drop { $0 == 0 }) }
        var intValue: Int { body.reduce(0) { $0 << 8 | Int($1) } }
    }

    struct Malformed: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    static func parse(_ b: ArraySlice<UInt8>) throws -> Node {
        let all = try parseAll(b)
        guard all.count == 1 else { throw Malformed("expected one element, got \(all.count)") }
        return all[0]
    }

    static func parseAll(_ b: ArraySlice<UInt8>) throws -> [Node] {
        var out: [Node] = []
        var i = b.startIndex
        while i < b.endIndex {
            let start = i
            let tag = b[i]; i += 1
            if tag & 0x1F == 0x1F { throw Malformed("high tag numbers unsupported") }
            guard i < b.endIndex else { throw Malformed("truncated length") }
            var len = Int(b[i]); i += 1
            if len & 0x80 != 0 {
                let n = len & 0x7F
                guard n > 0, n <= 4, i + n <= b.endIndex else { throw Malformed("bad length (indefinite or oversize)") }
                len = b[i..<i + n].reduce(0) { $0 << 8 | Int($1) }
                i += n
            }
            guard len <= b.endIndex - i else { throw Malformed("truncated element") }
            out.append(Node(tag: tag, body: b[i..<i + len], raw: b[start..<i + len]))
            i += len
        }
        return out
    }
}
