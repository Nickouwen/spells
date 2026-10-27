import Foundation

/// Fuzzy cache key for one Jev classification. Web pages: (browser bundle, host, path template,
/// normalised title). Other apps: (bundle, "", "", normalised title). `titleNorm` is "" when page
/// titles aren't sent (Settings → Classification).
public struct JevKey: Hashable, Sendable {
    public var app: String
    public var host: String
    public var pathTpl: String
    public var titleNorm: String

    public init(app: String, host: String = "", pathTpl: String = "", titleNorm: String) {
        self.app = app; self.host = host; self.pathTpl = pathTpl; self.titleNorm = titleNorm
    }

    /// `jev_class.key`: the four fields joined by U+001F (never present in a normalised field).
    public var id: String { [app, host, pathTpl, titleNorm].joined(separator: "\u{1F}") }
    public var isWeb: Bool { !host.isEmpty }
}

public enum ClassifyJevKey {
    /// nil when the window must never be sent: no title (private/incognito window, Safari/Arc,
    /// no Accessibility) or no app identity.
    public static func make(_ key: ClassifyKey, includeTitle: Bool = true) -> JevKey? {
        guard let title = key.title else { return nil }
        let app = key.bundleId ?? key.appName
        guard !app.isEmpty else { return nil }
        let t = includeTitle ? normalizeTitle(title) : ""
        if let host = ClassifyURL.host(key.url) {
            return JevKey(app: app, host: host, pathTpl: pathTemplate(ClassifyURL.path(key.url) ?? "/"), titleNorm: t)
        }
        return JevKey(app: app, titleNorm: t)
    }

    /// First 3 path segments, lowercased; ids (numeric, UUID, hex ≥ 8, long slugs with digits) → `*`.
    /// `/ExampleOrg/hours/pull/42` → `/exampleorg/hours/pull`; `/9011/v/l/6-901` → `/*/v/l`.
    public static func pathTemplate(_ path: String) -> String {
        let segs = path.split(separator: "/", omittingEmptySubsequences: true).prefix(3)
            .map { isIdentifier($0) ? "*" : $0.lowercased() }
        return "/" + segs.joined(separator: "/")
    }

    /// Lowercase; drop a trailing " - Google Chrome"-style suffix, a leading "(3) " count and emoji;
    /// digits → `#`; collapse whitespace; ≤ 120 characters.
    public static func normalizeTitle(_ title: String) -> String {
        var t = title
        for re in [browserSuffix, leadingCount] {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        var out = String.UnicodeScalarView()
        var space = false
        for s in t.lowercased().unicodeScalars where !isEmoji(s) {
            if s.properties.isWhitespace { space = !out.isEmpty; continue }
            if space { out.append(" "); space = false }
            out.append(CharacterSet.decimalDigits.contains(s) ? "#" : s)
        }
        return String(String(out).prefix(120))
    }

    // MARK: -

    private static let browserSuffix = try! NSRegularExpression(
        pattern: #"\s+[-–—|]\s+(google chrome|chrome|chromium|mozilla firefox|firefox|safari|brave|microsoft edge|edge|arc|vivaldi)\s*$"#,
        options: [.caseInsensitive])
    private static let leadingCount = try! NSRegularExpression(pattern: #"^\s*\(\d+\+?\)\s*"#)

    private static func isEmoji(_ s: Unicode.Scalar) -> Bool {
        if s.value == 0x200D || (0xFE00...0xFE0F).contains(s.value) { return true }   // ZWJ, variation selectors
        return s.properties.isEmojiPresentation || (s.properties.isEmoji && s.value > 0x238C)
    }

    private static let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    static func isIdentifier(_ seg: Substring) -> Bool {
        let scalars = seg.unicodeScalars
        if scalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) { return true }
        if UUID(uuidString: String(seg)) != nil { return true }
        if seg.count >= 8, scalars.allSatisfy({ hex.contains($0) }) { return true }
        // ponytail: "long slug with digits" = ≥ 10 chars with a digit and a - or _ (listing/blog slugs,
        // `12345_zpid`, dates); a real word-only segment like `pull-requests` survives.
        if seg.count >= 10, seg.contains(where: \.isNumber), seg.contains(where: { $0 == "-" || $0 == "_" }) { return true }
        return false
    }
}
