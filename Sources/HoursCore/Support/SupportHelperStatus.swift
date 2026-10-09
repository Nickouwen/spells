/// Tracker helper state as seen from the app (`AppHelperLifecycle.ensureTrackerRunning()`).
/// Lives in HoursCore so HoursUI can render the banner without depending on the app target.
public enum TrackerHelperStatus: Sendable, Equatable {
    /// Registered as a login item and running.
    case running
    /// Running now, but the login item awaits approval in System Settings → General → Login Items,
    /// so it won't start at the next login.
    case needsApproval
    /// `Contents/Library/LoginItems/HoursSpell.app` is missing — a packaging bug.
    case helperMissing
    /// App isn't running from a .app bundle (`swift run`), so there is no login item to manage.
    case notBundled
    /// Registration or launch failed; message is for display.
    case failed(String)
}
