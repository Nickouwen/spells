import Foundation
import notify

/// Cross-process "the DB changed" signal: Darwin `notify_post` after commits, delivered to every
/// subscriber in every process (the poster included, so the app's own writes arrive the same way).
/// GRDB observation can't see the other process's writes; this replaces it. No polling.
/// Coalescing is fine: a yield means "re-query", not "one row changed".
public enum ChangeFeed {
    public static func post(name: String = Hours.dbChangedNotification) {
        notify_post(name)
    }

    public static func stream(name: String = Hours.dbChangedNotification) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, DispatchQueue.global(qos: .utility)) { _ in
                continuation.yield()
            }
            guard status == NOTIFY_STATUS_OK else { continuation.finish(); return }
            let t = token
            continuation.onTermination = { _ in notify_cancel(t) }
        }
    }
}
