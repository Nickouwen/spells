import Foundation

/// Scrubs secrets from the transcript dump before it leaves the process (the `claude -p` stdin).
/// Order matters: credentialed URLs before emails (`user:pw@host` looks like one), env assignments
/// before the generic blob rule (so the key name survives).
// ponytail: pattern-based, not a secret scanner. Catches the shapes that show up in Claude
// transcripts (env lines, auth headers, vendor tokens, credentialed DB URLs, long random blobs);
// a short custom password typed as prose would get through.
public enum StandupRedact {
    public static let placeholder = "[redacted]"

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    /// scheme://user:password@host… → the whole URL.
    private static let credentialURL = rx(#"\b[A-Za-z][A-Za-z0-9+.\-]*://[^\s:/@'"`]+:[^\s@/'"`]+@[^\s'"`<>)]+"#)
    /// `NAME=value` / `"name": "value"` where the name looks secret-bearing. Keeps the name.
    private static let envAssign = rx(#"(?i)\b([A-Za-z_][A-Za-z0-9_]*(?:key|token|secret|passw(?:or)?d|pwd|auth|credentials?|dsn|cookie|session_?id)[A-Za-z0-9_]*)(\s*=\s*)("[^"\n]*"|'[^'\n]*'|[^\s,;'"`]+)"#)
    private static let jsonAssign = rx(#"(?i)("[A-Za-z0-9_\-]*(?:key|token|secret|passw(?:or)?d|pwd|auth|credentials?|dsn|cookie)[A-Za-z0-9_\-]*"\s*:\s*)"[^"\n]+""#)
    private static let bearer = rx(#"\b((?i:Bearer)|Basic)\s+[A-Za-z0-9._~+/=\-]{12,}"#)
    /// Vendor token shapes: OpenAI/Anthropic `sk-…`, Stripe, GitHub, Slack, AWS, Google, JWTs.
    private static let vendor = rx(#"\b(?:sk-[A-Za-z0-9_\-]{16,}|[sr]k_(?:live|test)_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abposr]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{35}|eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,})"#)
    private static let email = rx(#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#)
    private static let hexBlob = rx(#"\b[0-9a-fA-F]{32,}\b"#)
    /// No `/`: URL paths (`github.com/Org-Name-LLC/repo-name/pull/123`) would otherwise read as one blob.
    private static let blobCandidate = rx(#"[A-Za-z0-9+=_\-]{32,}"#)

    public static func redact(_ text: String, allowEmails: Set<String> = [StandupSettings.defaultAllowEmails]) -> String {
        var s = text
        s = replace(credentialURL, in: s) { _ in placeholder }
        s = replace(envAssign, in: s) { "\($0[1])\($0[2])\(placeholder)" }
        s = replace(jsonAssign, in: s) { "\($0[1])\"\(placeholder)\"" }
        s = replace(bearer, in: s) { "\($0[1]) \(placeholder)" }
        s = replace(vendor, in: s) { _ in placeholder }
        let allow = Set(allowEmails.map { $0.lowercased() })
        s = replace(email, in: s) { allow.contains($0[0].lowercased()) ? $0[0] : placeholder }
        s = replace(hexBlob, in: s) { _ in placeholder }
        s = replace(blobCandidate, in: s) { looksRandom($0[0]) ? placeholder : $0[0] }
        return s
    }

    /// Base64/base62-ish runs: a digit, both cases, and entropy ≥ 85 % of the most a string that long
    /// can have (log2 of min(length, 64)). Random keys land near the max; CamelCase identifiers and
    /// slugs repeat letters and sit well under it (a 43-char identifier ≈ 4.2 bits/char vs 4.6 needed).
    static func looksRandom(_ s: String) -> Bool {
        let chars = Array(s.utf8)
        guard chars.contains(where: { (48...57).contains($0) }), chars.contains(where: { (65...90).contains($0) }),
              chars.contains(where: { (97...122).contains($0) }) else { return false }
        var counts: [UInt8: Int] = [:]
        for c in chars { counts[c, default: 0] += 1 }
        let n = Double(chars.count)
        let h = counts.values.reduce(0.0) { acc, k in let p = Double(k) / n; return acc - p * log2(p) }
        return h >= 0.85 * log2(min(n, 64))
    }

    private static func replace(_ re: NSRegularExpression, in s: String, _ with: ([String]) -> String) -> String {
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = "", last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
            out += with(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
