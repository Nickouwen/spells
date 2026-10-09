import SwiftUI

/// Attachment points for the editing layer (item 8 / W12). The Canvas stays render-only: the
/// overlay draws in the Canvas's coordinate space, and lane drags / hover / right-click are
/// forwarded as times. nil hooks = a read-only timeline.
struct DayEditHooks {
    /// Drawn over the timeline (same frame as the Canvas).
    var overlay: @MainActor (DayViewport) -> AnyView
    /// A drag across the lane: start + current time; `ended` on mouse-up.
    var laneDrag: @MainActor (_ startMs: Int64, _ ms: Int64, _ vp: DayViewport, _ ended: Bool) -> Void
    /// Pointer over the timeline (nil when it leaves).
    var hover: @MainActor (_ ms: Int64?, _ vp: DayViewport) -> Void
    /// Right-click menu; `ms` = pointer time when it opened.
    var contextMenu: @MainActor (_ ms: Int64?) -> AnyView
    /// Writes a planned gesture as one edit group (the Blocks column's edge drags, W21).
    var commit: @MainActor (EditPlan) -> Void = { _ in }
}
