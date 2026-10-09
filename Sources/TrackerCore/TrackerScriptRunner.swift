import Foundation

/// Runs the Chromium URL AppleScript (and the Automation check, which can block on a prompt) on one
/// serial queue, so a slow or hung browser (2 s script timeout) never stalls the main thread and so
/// never delays the timestamps of other events. Replies arrive on the main thread.
/// OSA is thread-safe since 10.6; the compiled scripts and the denied set are confined to `queue`.
final class TrackerScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.nic.spells.hours.applescript", qos: .utility)
    /// Test seam: replaces the real AppleScript call.
    private let execute: (@Sendable (_ bundleId: String, _ ask: Bool) -> String?)?
    private var scripts: [String: NSAppleScript] = [:]
    private var denied: Set<String> = []

    init(execute: (@Sendable (_ bundleId: String, _ ask: Bool) -> String?)? = nil) { self.execute = execute }

    /// `reply` gets the script's result (nil: denied, undetermined, error or timeout), on main.
    func run(_ bundleId: String, ask: Bool, reply: @escaping @MainActor @Sendable (String?) -> Void) {
        queue.async { [self] in
            let r = execute.map { $0(bundleId, ask) } ?? appleScriptReply(bundleId, ask: ask)
            DispatchQueue.main.async { MainActor.assumeIsolated { reply(r) } }
        }
    }

    private func appleScriptReply(_ bundleId: String, ask: Bool) -> String? {
        guard !denied.contains(bundleId) else { return nil }
        switch TrackerSystem.automation(bundleId, ask: ask) {
        case .denied: denied.insert(bundleId); return nil // never retried
        case .undetermined: return nil
        case .granted: break
        }
        let script = scripts[bundleId] ?? {
            let s = NSAppleScript(source: TrackerBrowser.chromiumScript(bundleId))!
            s.compileAndReturnError(nil)
            scripts[bundleId] = s
            return s
        }()
        var error: NSDictionary?
        let reply = script.executeAndReturnError(&error)
        return error == nil ? reply.stringValue : nil
    }
}
