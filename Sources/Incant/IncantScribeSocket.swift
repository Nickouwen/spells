import Foundation
import HoursCore
import IncantCore

/// One dictation's Scribe v2 Realtime socket. Opens on init; chunks sent before `session_started` are
/// queued and flushed in order. `finish` commits and waits up to 2 s for the committed text, falling
/// back to the last partial. Never logs text — only event types and timings.
final class IncantScribeSocket: @unchecked Sendable {
    private let ws: URLSessionWebSocketTask
    private let onPartial: (@Sendable (String) -> Void)?
    private let onError: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    // All guarded by `lock`.
    private var open = false, queued: [String] = [], lastPartial = ""
    private var ended: String?                                   // committed text, or the last partial after a failure
    private var waiter: CheckedContinuation<String, Never>?

    init(apiKey: String, keyterms: [String], onPartial: (@Sendable (String) -> Void)? = nil,
         onError: (@Sendable (String) -> Void)? = nil) {
        var req = URLRequest(url: IncantScribe.url(keyterms: keyterms))
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        ws = URLSession.shared.webSocketTask(with: req)
        self.onPartial = onPartial; self.onError = onError
        ws.resume()
        receive()
    }

    func send(_ pcm: Data) { enqueue(IncantScribe.chunk(pcm, commit: false)) }

    /// Sends `rest` with commit:true and returns the committed text ("" if nothing was heard).
    func finish(_ rest: Data) async -> String {
        enqueue(IncantScribe.chunk(rest.isEmpty ? Data(count: 320) : rest, commit: true))   // commit needs some audio
        let text = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            lock.withLock { if let ended { c.resume(returning: ended) } else { waiter = c } }
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.end(nil) { SupportLog.incant.error("Scribe commit timed out after 2 s; using the last partial") }
            }
        }
        cancel()
        return text
    }

    func cancel() {
        end(nil)   // first, so the receive failure the close causes isn't reported as an error
        ws.cancel(with: .normalClosure, reason: nil)
    }

    private func enqueue(_ message: String) {
        lock.withLock {
            if open { ws.send(.string(message)) { _ in } } else { queued.append(message) }
        }
    }

    /// Settles the session with `text` (nil = the last partial). True if this call settled it.
    @discardableResult private func end(_ text: String?) -> Bool {
        let (settled, c): (String?, CheckedContinuation<String, Never>?) = lock.withLock {
            guard ended == nil else { return (nil, nil) }
            ended = text ?? lastPartial
            defer { waiter = nil }
            return (ended, waiter)
        }
        if let settled { c?.resume(returning: settled) }
        return settled != nil
    }

    private func receive() {
        ws.receive { [self] result in
            guard case .success(let message) = result else {
                if end(nil) { onError?("Lost the connection to Scribe") }
                return
            }
            guard case .string(let json) = message else { return receive() }
            switch IncantScribe.decode(json) {
            case .started:
                lock.withLock {
                    open = true
                    for m in queued { ws.send(.string(m)) { _ in } }
                    queued = []
                }
            case .partial(let text):
                lock.withLock { lastPartial = text }
                onPartial?(text)
            case .committed(let text):
                end(text)
                return
            case .error(let type, _):
                SupportLog.incant.error("Scribe error: \(type, privacy: .public)")
                onError?("Scribe: \(type)")
                end(nil)
                return
            case .other:
                break
            }
            receive()
        }
    }
}
