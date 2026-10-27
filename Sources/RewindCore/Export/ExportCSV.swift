import CryptoKit
import Foundation

/// RFC 4180 CSV, UTF-8, LF line endings, header row. Fields are quoted only when needed.
enum ExportCSV {
    static func render(header: [String], rows: [[String]]) -> Data {
        var s = line(header)
        for r in rows { s += line(r) }
        return Data(s.utf8)
    }

    static func line(_ fields: [String]) -> String { fields.map(field).joined(separator: ",") + "\n" }

    static func field(_ f: String) -> String {
        f.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
    }

    /// Parses what `render` writes (quoted fields may contain commas, quotes, newlines). First row = header.
    static func parse(_ data: Data) -> [[String: String]] {
        var rows: [[String]] = [], row: [String] = [], cur = "", quoted = false
        var it = String(decoding: data, as: UTF8.self).unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { cur.unicodeScalars.append("\"") } else { quoted = false; pending = n } }
                    else { quoted = false }
                } else { cur.unicodeScalars.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(cur); cur = "" }
            else if c == "\n" { row.append(cur); rows.append(row); row = []; cur = "" }
            else { cur.unicodeScalars.append(c) }
        }
        if !cur.isEmpty || !row.isEmpty { row.append(cur); rows.append(row) }
        guard let header = rows.first else { return [] }
        return rows.dropFirst().map { r in
            Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element, $0.offset < r.count ? r[$0.offset] : "") })
        }
    }
}

func exportSHA256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

func exportHex(_ d: Data) -> String { d.storeHex }

func exportUnhex(_ s: String) -> Data? {
    guard s.count % 2 == 0 else { return nil }
    var out = Data(capacity: s.count / 2), i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
        out.append(b); i = j
    }
    return out
}

/// `2026-10-01T08:12:00.000Z`.
func exportUTC(_ ms: Int64) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

/// `2026-10-01T01:12:00-07:00` in `tzId`.
func exportLocal(_ ms: Int64, _ tzId: String) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(identifier: tzId) ?? .gmt
    return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}
