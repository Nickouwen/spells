import Foundation

/// Display formatting. Durations are rounded once, here, at the display edge.
// ponytail: lives in HoursUI because W6 may not touch HoursCore; it is Foundation-only so it can
// move to HoursCore verbatim when export (item 9) needs the same strings.
public enum Fmt {
    public struct Part: Hashable, Sendable {
        public let value: String
        public let unit: String
    }

    /// `6h 42m`, `6h`, `42m`, `<1m`, `0m`. Nearest minute, half up. Negative → leading `−`.
    public static func duration(ms: Int64) -> String {
        let parts = durationParts(ms: ms).map { $0.value + $0.unit }.joined(separator: " ")
        return ms < 0 ? "\u{2212}" + parts : parts
    }

    /// The pieces of `duration(ms:)` (sign dropped), so the hero/metric can style units smaller.
    public static func durationParts(ms: Int64) -> [Part] {
        let ms = ms.magnitude
        if ms == 0 { return [Part(value: "0", unit: "m")] }
        if ms < 60_000 { return [Part(value: "<1", unit: "m")] }
        let minutes = (ms + 30_000) / 60_000
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return [Part(value: "\(m)", unit: "m")] }
        if m == 0 { return [Part(value: "\(h)", unit: "h")] }
        return [Part(value: "\(h)", unit: "h"), Part(value: "\(m)", unit: "m")]
    }

    /// VoiceOver form: "6 hours 42 minutes".
    public static func durationSpoken(ms: Int64) -> String {
        durationParts(ms: ms).map { p in
            let n = Int(p.value) ?? 0
            switch p.unit {
            case "h": return n == 1 ? "1 hour" : "\(p.value) hours"
            default: return p.value == "<1" ? "less than a minute" : (n == 1 ? "1 minute" : "\(p.value) minutes")
            }
        }.joined(separator: " ")
    }

    /// `08:12`, 24-hour, in `timeZone`.
    // ponytail: always 24 h; honour the system 12/24 h preference when a user asks.
    public static func clock(ms: Int64, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Integer percent of a 0…1 fraction: `0.427` → `43%`.
    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
