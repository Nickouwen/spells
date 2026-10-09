import Foundation
import Security

/// HTTP to TypeSafe's System One endpoint. Injected so tests run on a fake (no network).
public typealias JevTransport = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

/// One Jev request per cache miss: 10 s timeout, 429/529 retried with exponential backoff,
/// every other failure returned as a failed entry with a retry-after (asked again later, not hammered).
public struct JevClient: Sendable {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let transientRetryMs: Int64 = 3_600_000          // 1 h: rate limit / overload / network
    public static let permanentRetryMs: Int64 = 24 * 3_600_000     // 24 h: 4xx / unparseable answer

    public enum Outcome: Sendable {
        case answered(JevEntry)
        case failed(JevEntry)
        /// 401/403: the key is wrong. The caller stops the batch and stores nothing.
        case unauthorized
    }

    private let apiKey: String
    public var transport: JevTransport
    public var maxAttempts: Int
    /// Backoff before retry `n` (1-based); default sleeps 2^(n-1) s.
    public var backoff: @Sendable (Int) async -> Void

    public init(apiKey: String, transport: @escaping JevTransport = JevClient.http, maxAttempts: Int = 4,
                backoff: @escaping @Sendable (Int) async -> Void = { n in try? await Task.sleep(for: .seconds(1 << (n - 1))) }) {
        self.apiKey = apiKey; self.transport = transport; self.maxAttempts = maxAttempts; self.backoff = backoff
    }

    /// `TYPESAFE_API_KEY` (tests) else the Keychain item; nil when neither exists.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> JevClient? {
        (environment["TYPESAFE_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } ?? keychainKey()).map { JevClient(apiKey: $0) }
    }

    /// Generic password, service `typesafe-api-key`, account = the login user.
    public static func keychainKey(account: String = NSUserName()) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "typesafe-api-key",
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    public static let http: JevTransport = { req in
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    public func classify(_ key: JevKey, body: Data, nowMs: Int64) async -> Outcome {
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        for attempt in 1...max(1, maxAttempts) {
            let status: Int, data: Data
            do { (status, data) = try await transport(req) } catch {
                SupportLog.app.error("jev request failed: \(String(describing: type(of: error)), privacy: .public)")
                return .failed(.failure(key, nowMs: nowMs, retryAfterMs: nowMs + Self.transientRetryMs))
            }
            switch status {
            case 200:
                guard let entry = Self.parse(data, key: key, nowMs: nowMs) else {
                    return .failed(.failure(key, nowMs: nowMs, retryAfterMs: nowMs + Self.permanentRetryMs))
                }
                return .answered(entry)
            case 401, 403:
                return .unauthorized
            case 429, 529:
                if attempt < maxAttempts { await backoff(attempt); continue }
                return .failed(.failure(key, nowMs: nowMs, retryAfterMs: nowMs + Self.transientRetryMs))
            default:
                SupportLog.app.error("jev HTTP \(status, privacy: .public)")
                let retry = (400..<500).contains(status) ? Self.permanentRetryMs : Self.transientRetryMs
                return .failed(.failure(key, nowMs: nowMs, retryAfterMs: nowMs + retry))
            }
        }
        return .failed(.failure(key, nowMs: nowMs, retryAfterMs: nowMs + Self.transientRetryMs))
    }

    /// `answers.category` / `answers.project` (choice, probabilities, confidence) + `usage.input_tokens`.
    static func parse(_ data: Data, key: JevKey, nowMs: Int64) -> JevEntry? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: Any],
              let cat = answers["category"] as? [String: Any], let choice = cat["choice"] as? String else { return nil }
        let proj = answers["project"] as? [String: Any]
        let projectName = (proj?["choice"] as? String).flatMap { $0 == "none" ? nil : $0 }
        let usage = json["usage"] as? [String: Any]
        return JevEntry(key: key, categoryKey: choice, categoryConf: (cat["confidence"] as? Double) ?? 0,
                        categoryProbs: (cat["probabilities"] as? [String: Double]) ?? [:],
                        projectName: projectName, projectConf: projectName == nil ? 0 : (proj?["confidence"] as? Double) ?? 0,
                        model: json["model"] as? String, createdMs: nowMs,
                        inputTokens: (usage?["input_tokens"] as? Int) ?? 0)
    }
}
