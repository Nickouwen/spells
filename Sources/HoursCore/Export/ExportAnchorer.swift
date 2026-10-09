import Foundation
import os

/// A public RFC 3161 timestamp authority.
public struct TSA: Sendable, Hashable {
    public var name: String
    public var url: URL
    public init(name: String, url: URL) { self.name = name; self.url = url }

    public static let digicert = TSA(name: "digicert", url: URL(string: "http://timestamp.digicert.com")!)
    public static let freetsa = TSA(name: "freetsa", url: URL(string: "https://freetsa.org/tsr")!)
}

/// Anchors the chain head with RFC 3161 tokens. Both TSAs are asked concurrently; each success is
/// one insert-only `anchor` row (D1: one success is enough). No queue: "needs anchor" is derived
/// from `head_seq > max(anchor.head_seq)` (D4), so callers just call `runIfDue` on every trigger.
public enum Anchorer {
    public typealias Transport = @Sendable (URL, Data) async throws -> Data

    public enum Outcome: Sendable, Equatable {
        case notDue(String)
        case done(anchored: [ChainAnchor], failures: [String])
    }

    public static let defaultTSAs: [TSA] = [.digicert, .freetsa]

    /// Idempotent. Due when the head has advanced past every anchor AND (no anchor was requested
    /// yet this local day, or `force`). Tracker calls this on day rollover / wake / launch;
    /// `spellsctl anchor [--force]` on demand. `mirrorDir` gets `<id>-<tsa>.tst` copies of each token.
    public static func runIfDue(db: HoursDB, now: Date = Date(), force: Bool = false, tz: TimeZone = .current,
                                tsas: [TSA] = defaultTSAs, mirrorDir: URL? = nil,
                                transport: @escaping Transport = http, nonce: Data? = nil) async throws -> Outcome {
        let head = try db.head()
        guard head.seq > 0 else { return .notDue("chain is empty") }
        let anchors = try AnchorStore(db).list()
        if let maxSeq = anchors.map(\.headSeq).max(), maxSeq >= head.seq {
            return .notDue("head #\(head.seq) already anchored")
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        if !force, let last = anchors.last,
           LocalDate.containing(ms: last.requestedMs, in: tz) == LocalDate.containing(ms: nowMs, in: tz) {
            return .notDue("already anchored today (head advanced; use --force)")
        }

        let nonce = nonce ?? Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let request = RFC3161.request(digest: head.hash, nonce: nonce)
        let results = await withTaskGroup(of: (TSA, Result<RFC3161.TokenInfo, Error>).self) { group in
            for tsa in tsas {
                group.addTask {
                    do {
                        let resp = try await transport(tsa.url, request)
                        return (tsa, .success(try RFC3161.check(response: resp, digest: head.hash, nonce: nonce)))
                    } catch {
                        return (tsa, .failure(error))
                    }
                }
            }
            var out: [(TSA, Result<RFC3161.TokenInfo, Error>)] = []
            for await r in group { out.append(r) }
            return out.sorted { a, b in tsas.firstIndex(of: a.0)! < tsas.firstIndex(of: b.0)! }
        }

        var anchored: [ChainAnchor] = [], failures: [String] = []
        for (tsa, result) in results {
            switch result {
            case let .success(info):
                var a = ChainAnchor(headSeq: head.seq, headHash: head.hash, method: "rfc3161", tsa: tsa.name,
                                    requestedMs: nowMs, genTimeMs: info.genTimeMs, token: info.token, nonce: nonce)
                a.id = try AnchorStore(db).insert(a)
                if let mirrorDir {
                    try? FileManager.default.createDirectory(at: mirrorDir, withIntermediateDirectories: true)
                    try? info.token.write(to: mirrorDir.appending(path: "\(a.id)-\(tsa.name).tst"))
                }
                anchored.append(a)
            case let .failure(e):
                failures.append("\(tsa.name): \(e)")
                SupportLog.db.error("anchor \(tsa.name, privacy: .public) failed: \(String(describing: e), privacy: .public)")
            }
        }
        return .done(anchored: anchored, failures: failures)
    }

    /// POST `application/timestamp-query`, 10 s timeout, HTTP 200 required.
    public static let http: Transport = { url, body in
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/timestamp-query", forHTTPHeaderField: "Content-Type")
        req.setValue("application/timestamp-reply", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw RFC3161.Failure.malformed("HTTP \(code)") }
        return data
    }
}
