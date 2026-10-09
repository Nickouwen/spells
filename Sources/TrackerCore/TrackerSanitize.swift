import Foundation

/// Raw spans are immutable once chained, so minimisation happens here or never.
public enum TrackerSanitize {
    public static let maxTitle = 256
    public static let maxURL = 512

    public static func title(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(maxTitle))
    }

    /// `scheme://host/path`: query, fragment and userinfo dropped, then truncated.
    public static func url(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        var s = raw
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        if var c = URLComponents(string: s), c.user != nil || c.password != nil {
            c.user = nil; c.password = nil
            s = c.string ?? s
        }
        return s.isEmpty ? nil : String(s.prefix(maxURL))
    }
}
