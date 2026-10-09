import Foundation

/// URL normalisation for rule matching. The tracker already strips query/fragment at write time.
public enum ClassifyURL {
    /// Lowercased host with a leading `www.` stripped. Scheme-less strings ("github.com/x") are accepted.
    public static func host(_ url: String?) -> String? {
        guard let comps = components(url), let h = comps.host?.lowercased(), !h.isEmpty else { return nil }
        return normalizeHost(h)
    }

    /// URL path ("/" when empty), nil when the URL doesn't parse.
    public static func path(_ url: String?) -> String? {
        guard let comps = components(url) else { return nil }
        return comps.path.isEmpty ? "/" : comps.path
    }

    /// Lowercase + strip `www.`; used for both span hosts and rule hosts.
    public static func normalizeHost(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// True when `host` equals `ruleHost` or ends with it on a label boundary
    /// (`github.com` matches `gist.github.com`; `x.com` does not match `box.com`).
    /// A rule host ending in `.*` is a prefix: `docs.*` matches `docs.python.org`, not `mydocs.io`.
    public static func hostMatches(_ ruleHost: String, _ host: String) -> Bool {
        if let prefix = hostPrefix(ruleHost) { return host.hasPrefix(prefix + ".") && host.count > prefix.count + 1 }
        guard host.hasSuffix(ruleHost) else { return false }
        if host.count == ruleHost.count { return true }
        return host.dropLast(ruleHost.count).hasSuffix(".")
    }

    /// `docs.*` → `docs`; nil for an ordinary (suffix) rule host.
    static func hostPrefix(_ ruleHost: String) -> String? {
        guard ruleHost.hasSuffix(".*"), ruleHost.count > 2 else { return nil }
        return String(ruleHost.dropLast(2))
    }

    /// `a.b.github.com` →[`a.b.github.com`, `b.github.com`, `github.com`, `com`] — the index keys to probe.
    static func suffixes(_ host: String) -> [Substring] {
        var out: [Substring] = [Substring(host)]
        var rest = Substring(host)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            out.append(rest)
        }
        return out
    }

    private static func components(_ url: String?) -> URLComponents? {
        guard let url, !url.isEmpty else { return nil }
        return URLComponents(string: url.contains("://") ? url : "https://" + url)
    }
}
