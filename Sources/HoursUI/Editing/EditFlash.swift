import SwiftUI

/// The range the last edit touched (commit, undo, redo, revert), for a brief highlight in the
/// timeline and the Blocks column. `id` changes on every edit, so the same range can flash twice.
/// Set by `EditableDayView` from `EditSession.flash`; nil outside editing.
public struct EditFlash: Equatable, Sendable {
    public var range: Range<Int64>
    public var id: Int
    public init(range: Range<Int64>, id: Int) { self.range = range; self.id = id }
}

extension EnvironmentValues {
    @Entry var hoursEditFlash: EditFlash? = nil
}
