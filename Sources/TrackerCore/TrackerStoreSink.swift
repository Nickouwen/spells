import Foundation
import HoursCore

/// `TrackerSink` → W1's `SpanWriter`. Every sink call is one IMMEDIATE transaction; the store
/// posts the change notification itself (heartbeats excepted), so this never posts.
///
/// Writes that fail with SQLITE_BUSY/LOCKED (the app held the lock past busy_timeout) are queued
/// and replayed in order before the next call — heartbeats (every 30 s tick) are the retry clock.
/// Any other error (trigger abort, NUL) is logged and the live row resynced: retrying can't fix it.
/// Calls arrive on the main thread (TrackerRuntime); the sink is not thread-safe.
public final class TrackerStoreSink: TrackerSink {
    /// A queued write. open/replace/close all reduce to `SpanWriter.close(at:next:)`.
    private struct Write { var at: Int64; var next: RawSpan? }

    static let maxPending = 1000

    private let writer: SpanWriter
    private let timeZone: TimeZone?
    private let onDayRollover: () -> Void
    private var pending: [Write] = []
    private var day: LocalDate

    /// - Parameters:
    ///   - nowMs: when the helper launched (its launch-time backup covers that day).
    ///   - timeZone: fixed zone for the rollover check; nil = the current zone at each call.
    ///   - onDayRollover: called once when a write lands on a new local calendar day — i.e. at the
    ///     first tick after midnight, or the first span after waking on a later day.
    public init(_ writer: SpanWriter, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                timeZone: TimeZone? = nil, onDayRollover: @escaping () -> Void = {}) {
        self.writer = writer; self.timeZone = timeZone; self.onDayRollover = onDayRollover
        day = LocalDate.containing(ms: nowMs, in: timeZone ?? .current, dayStartHour: 0)
    }

    /// Writes waiting for a retry (tests, diagnostics).
    public var pendingCount: Int { pending.count }
    /// The most recent write attempt (span or heartbeat) failed — busy or dropped. Status-item health.
    public private(set) var lastWriteFailed = false

    public func open(live: RawSpan) { write(Write(at: live.startMs, next: clean(live)), dayMs: live.startMs) }

    /// The engine only replaces a live span that would be zero-length; closing it at `.min`
    /// makes `SpanWriter` drop it (it chains only when end > start) and installs `next`.
    public func replace(live: RawSpan?) { write(Write(at: .min, next: live.map(clean)), dayMs: live?.startMs) }

    public func close(at endMs: Int64, reason: EndReason, next: RawSpan?) {
        SupportLog.tracker.debug("close \(reason.rawValue, privacy: .public)")
        write(Write(at: endMs, next: next.map(clean)), dayMs: endMs)
    }

    public func heartbeat(lastSeenMs: Int64) {
        checkDay(lastSeenMs)
        guard flush() else { return }  // live row is stale until the queue drains
        do { try writer.heartbeat(lastSeenMs: lastSeenMs); lastWriteFailed = false } catch {
            // Not queued: the next tick's heartbeat supersedes it.
            lastWriteFailed = true
            SupportLog.tracker.error("heartbeat failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Internals

    private func write(_ w: Write, dayMs: Int64?) {
        if let dayMs { checkDay(dayMs) }
        pending.append(w)
        if pending.count > Self.maxPending {
            pending.removeFirst()
            SupportLog.tracker.error("write queue full; dropped the oldest span write")
        }
        flush()
    }

    /// Replays queued writes in order. Stops at the first busy failure (true = queue empty).
    @discardableResult
    private func flush() -> Bool {
        while let w = pending.first {
            do {
                try writer.close(at: w.at, next: w.next)
                lastWriteFailed = false
            } catch where Self.isBusy(error) {
                SupportLog.tracker.error("db busy; \(self.pending.count) write(s) queued for retry")
                lastWriteFailed = true
                return false
            } catch {
                lastWriteFailed = true
                SupportLog.tracker.error("span write dropped: \(String(describing: error), privacy: .public)")
                resync(w)
            }
            pending.removeFirst()
        }
        return true
    }

    /// After a non-busy failure the DB's live row no longer matches the engine, and left alone it
    /// would chain later with the wrong end. Chain it at the intended end (else drop it), then
    /// install `next` if that one is storable. Best effort: a failure here is already logged above.
    private func resync(_ w: Write) {
        if (try? writer.close(at: w.at, next: nil)) == nil { _ = try? writer.close(at: .min, next: nil) }
        if let next = w.next { _ = try? writer.close(at: .min, next: next) }
    }

    private func checkDay(_ ms: Int64) {
        let d = LocalDate.containing(ms: ms, in: timeZone ?? .current, dayStartHour: 0)
        guard d > day else { return }
        day = d
        onDayRollover()
    }

    /// SQLITE_BUSY (5) / SQLITE_LOCKED (6), via GRDB's `CustomNSError` bridge (TrackerCore
    /// doesn't link GRDB directly). Extended codes keep the primary code in the low byte.
    static func isBusy(_ error: any Error) -> Bool {
        let e = error as NSError
        return e.domain == "GRDB.DatabaseError" && [5, 6].contains(e.code & 0xFF)
    }

    /// The store rejects NUL bytes (`StoreError.nulByte`); an AX title could carry one.
    private func clean(_ s: RawSpan) -> RawSpan {
        var s = s
        s.title = s.title?.replacingOccurrences(of: "\0", with: "")
        s.url = s.url?.replacingOccurrences(of: "\0", with: "")
        return s
    }
}
