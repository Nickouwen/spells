import Foundation
import HoursCore

/// Where the engine's span lifecycle goes. The integration wave adapts W1's `SpanWriter` to this;
/// `PrintSink` is the dry-run implementation. Live spans are `seq == 0`, `endMs == startMs`.
public protocol TrackerSink: AnyObject {
    /// No live span exists; start this one.
    func open(live: RawSpan)
    /// Swap the live span without chaining (it would have been zero-length). nil = drop it.
    func replace(live: RawSpan?)
    /// Chain the live span ending at `endMs`, then start `next` if given.
    func close(at endMs: Int64, reason: EndReason, next: RawSpan?)
    /// Live span still current at `lastSeenMs` (crash recovery closes it there).
    func heartbeat(lastSeenMs: Int64)
}

extension TrackerSink {
    /// Applies the sink-bound outputs; timer outputs are the runtime's business.
    public func apply(_ outputs: [TrackerOutput]) {
        for o in outputs {
            switch o {
            case .open(let s): open(live: s)
            case .replace(let s): replace(live: s)
            case .close(let at, let reason, let next): close(at: at, reason: reason, next: next)
            case .heartbeat(let ms): heartbeat(lastSeenMs: ms)
            case .armDebounce, .cancelDebounce: break
            }
        }
    }
}

/// One JSON object per line on stdout.
public final class PrintSink: TrackerSink {
    private struct Line: Encodable {
        var op: String
        var span: RawSpan?
        var atMs: Int64?
        var reason: EndReason?
        var next: RawSpan?
        var lastSeenMs: Int64?
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public init() {}

    public func open(live: RawSpan) { emit(Line(op: "open", span: live)) }
    public func replace(live: RawSpan?) { emit(Line(op: "replace", span: live)) }
    public func close(at endMs: Int64, reason: EndReason, next: RawSpan?) {
        emit(Line(op: "close", atMs: endMs, reason: reason, next: next))
    }
    public func heartbeat(lastSeenMs: Int64) { emit(Line(op: "heartbeat", lastSeenMs: lastSeenMs)) }

    private func emit(_ line: Line) {
        guard let data = try? encoder.encode(line) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }
}
