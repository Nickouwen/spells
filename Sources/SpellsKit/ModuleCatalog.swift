import Foundation

/// What the launcher can install: `catalog.json` on the newest GitHub release (`scripts/release.sh`
/// writes it). One entry per module, carrying the same fields as the app's `SpellsModule` manifest
/// plus the version, the signed zip's URL and its SHA-256.
public struct ModuleCatalog: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var bundleID: String
        public var name: String
        public var summary: String
        public var symbol: String
        public var scheme: String
        public var loginItem: Bool
        public var version: String
        public var url: URL
        public var sha256: String
        public var id: String { bundleID }

        public init(bundleID: String, name: String, summary: String = "", symbol: String = "app", scheme: String, loginItem: Bool = false,
                    version: String, url: URL, sha256: String) {
            self.bundleID = bundleID; self.name = name; self.summary = summary; self.symbol = symbol; self.scheme = scheme
            self.loginItem = loginItem; self.version = version; self.url = url; self.sha256 = sha256
        }
    }

    public var modules: [Entry]
    public init(modules: [Entry]) { self.modules = modules }

    public static let defaultURL = URL(string: "https://github.com/Nickouwen/spells/releases/latest/download/catalog.json")!
    /// Row in the launcher's settings file that points somewhere else (a local build, a fork).
    public static let urlKey = "catalog_url"

    public static func url(_ rows: [String: String]) -> URL {
        let v = rows[urlKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? defaultURL : URL(string: v) ?? defaultURL
    }

    public static func decode(_ data: Data) throws -> ModuleCatalog { try JSONDecoder().decode(ModuleCatalog.self, from: data) }

    /// Dotted numbers, left to right; a missing part is 0 ("1.2" == "1.2.0"); anything else compares as 0.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
