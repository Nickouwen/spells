import Foundation
import Security

/// API keys as generic passwords (service = provider, account = the login user), so they never sit
/// in a file or the database. `security add-generic-password -s <service> -a $USER -w` sets the same item.
public enum SupportKeychain {
    public static let elevenLabs = "elevenlabs-api-key"
    public static let cerebras = "cerebras-api-key"

    /// `<home>/.env` (`ELEVENLABS_API_KEY=…` lines, mode 0600, outside the repo; the repo's gitignored
    /// `.env` links to it). Checked after the process environment and before the Keychain: every rebuilt
    /// or ad-hoc binary is a new app to the Keychain and prompts again; the file doesn't.
    static func envURL(_ paths: SupportPaths = .current()) -> URL { paths.home.appending(path: ".env") }

    /// Keychain service → environment variable name.
    static func envName(_ service: String) -> String {
        switch service {
        case elevenLabs: "ELEVENLABS_API_KEY"
        case cerebras: "CEREBRAS_API_KEY"
        default: service.uppercased().replacingOccurrences(of: "-", with: "_")
        }
    }

    /// `KEY=value` lines; `#` comments, blank lines and surrounding quotes ignored.
    static func envFile(_ url: URL = envURL()) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
            let k = l[..<eq].trimmingCharacters(in: .whitespaces)
            var v = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == v.last, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
            out[k] = v
        }
        return out
    }

    public static func read(_ service: String, account: String = NSUserName()) -> String? {
        let name = envName(service)
        for source in [ProcessInfo.processInfo.environment, envFile()] {
            if let v = source[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    /// Replaces the item; an empty value deletes it.
    @discardableResult
    public static func write(_ service: String, _ value: String, account: String = NSUserName()) -> Bool {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        writeFile(service, value)
        SecItemDelete(match as CFDictionary)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return true }
        var add = match
        add[kSecValueData as String] = Data(v.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Keeps the `.env` in step with the Keychain (an empty value removes the line).
    static func writeFile(_ service: String, _ value: String, url: URL = envURL()) {
        var all = envFile(url)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        all[envName(service)] = v.isEmpty ? nil : v
        let text = all.keys.sorted().map { "\($0)=\(all[$0]!)" }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    }
}
