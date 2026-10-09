import SwiftUI
import HoursCore

/// The Day view (Today = Day on today): date header, hero + tiles, Canvas timeline, breakdown panels.
/// Pure over `DayData` — the shell loads/refreshes the data and owns the date; `onNavigate` asks
/// it to move. No timers here: the shell re-supplies `DayData` (incl. `nowMs`) on DB change and
/// on its ≤ 1/min tick while today is visible.
public struct DayView: View {
    let data: DayData
    let onNavigate: (LocalDate) -> Void
    private let externalSelection: Binding<ClosedRange<Int64>?>?
    var scrollable = true
    var previewHoverMs: Int64?
    var editHooks: DayEditHooks?
    /// Renders: pins Blocks mode and its state (W21).
    var blocksPreview: BlocksPreview?

    @AppStorage(DayMode.storageKey) private var mode: DayMode = .timeline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Keyed by its day, so a new day's first render already fits (no stale frame, nothing to tween).
    @State private var window: (date: LocalDate, window: DayWindow)?
    @State private var highlight: Int64??
    @State private var localSelection: ClosedRange<Int64>?
    /// Visible page height and the Blocks card's top in the page: the card fills what's between.
    @State private var pageHeight: CGFloat = 0
    @State private var blocksTop: CGFloat = 0

    public init(data: DayData, onNavigate: @escaping (LocalDate) -> Void) {
        self.data = data
        self.onNavigate = onNavigate
        self.externalSelection = nil
    }

    /// Selection hook for editing (W12): the selected time range, driven by click-to-select here
    /// and by whatever gestures the editing layer attaches.
    public init(data: DayData, onNavigate: @escaping (LocalDate) -> Void, selectedRange: Binding<ClosedRange<Int64>?>) {
        self.data = data
        self.onNavigate = onNavigate
        self.externalSelection = selectedRange
    }

    /// Editing entry point (W12): selection hook + edit overlay / gestures; `scrollable: false` for renders.
    init(data: DayData, onNavigate: @escaping (LocalDate) -> Void, selectedRange: Binding<ClosedRange<Int64>?>,
         editHooks: DayEditHooks, scrollable: Bool = true, blocksPreview: BlocksPreview? = nil) {
        self.init(data: data, onNavigate: onNavigate, selectedRange: selectedRange)
        self.editHooks = editHooks
        self.scrollable = scrollable
        self.blocksPreview = blocksPreview
    }

    /// Render-test entry point: no ScrollView (ImageRenderer can't draw NSScrollView content), optional pinned hover.
    init(data: DayData, scrollable: Bool, previewHoverMs: Int64? = nil) {
        self.init(data: data, onNavigate: { _ in })
        self.scrollable = scrollable
        self.previewHoverMs = previewHoverMs
    }

    private var selection: Binding<ClosedRange<Int64>?> { externalSelection ?? $localSelection }
    private var windowBinding: Binding<DayWindow> {
        Binding(get: { window.flatMap { $0.date == data.date ? $0.window : nil } ?? DayWindow.fit(data) },
                set: { window = (data.date, $0) })
    }

    public var body: some View {
        Group {
            if scrollable {
                ScrollView(.vertical) { content }
                    .scrollEdgeEffectStyle(.hard, for: .top)
            } else {
                // Takes the offered size, not the content's, so `pageHeight` is the visible height.
                Color.clear.overlay(alignment: .top) { content }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
        .background(Theme.canvas)
        .onChange(of: data.date) {
            highlight = nil
            localSelection = nil
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            DayHeader(data: data, onNavigate: onNavigate, mode: blocksPreview == nil ? $mode : .constant(.blocks))
            if !data.isEmpty {
                // Outside the crossfade so its numbers roll (the way you travel) instead of fading.
                DayHeadline(data: data, compact: isBlocks)
                    .environment(\.hoursNumericValue, DayHeadline.rollValue(data.date))
                    .animation(swap, value: data.date)
            }
            // The cards crossfade on a day change or a Timeline ↔ Blocks toggle; a ZStack so the
            // outgoing and incoming cards overlap rather than stack.
            ZStack(alignment: .topLeading) {
                cards.id(cardsID).transition(.opacity)
            }
            .animation(swap, value: cardsID)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(Self.pageSpace))
    }

    @ViewBuilder private var cards: some View {
        if data.isEmpty {
            emptyDay
        } else if isBlocks {
            // Condensed (W25): compact stats above, breakdowns in the side panel, and the card
            // fills the rest of the window so the column's scale follows its height.
            BlocksCard(data: data, editable: editHooks != nil, commit: { editHooks?.commit($0) }, preview: blocksPreview,
                       fillHeight: pageHeight > 0 ? pageHeight - blocksTop - Theme.Space.l : nil)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.pageSpace)).minY } action: { blocksTop = $0 }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                DayTimelineCard(data: data, window: windowBinding, selectedRange: selection,
                                highlight: $highlight, previewHoverMs: previewHoverMs, editHooks: editHooks)
                    .zIndex(1)
                DayBreakdown(data: data)
            }
        }
    }

    private var cardsID: [AnyHashable] { [data.date, isBlocks] }
    private var swap: Animation? { Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion) }
    private var isBlocks: Bool { blocksPreview != nil || mode == .blocks }
    nonisolated private static let pageSpace = "day.page"

    /// Axis skeleton + the right empty state for why the day is blank.
    private var emptyDay: some View {
        VStack(spacing: Theme.Space.l) {
            DayTimelineCanvas(data: data, items: [], projectRuns: [], window: windowBinding,
                              selectedRange: .constant(nil), highlight: nil)
                .opacity(0.7)
            emptyState
                .padding(.vertical, Theme.Space.xl)
        }
        .hoursCard(padding: Theme.Space.l, radius: Theme.Radius.panel)
    }

    private var emptyState: EmptyState {
        if data.isToday {
            switch data.tracker {
            case .permissionMissing: return .permissionMissing()
            case .stopped: return .trackerNotRunning()
            default: return EmptyState(symbol: "clock", title: "Nothing tracked yet today",
                                       detail: "Activity appears here as soon as the tracker records it.")
            }
        }
        if data.date > DayHeader.today(data.timeZone) {
            return EmptyState(symbol: "calendar", title: "This day hasn't happened yet", detail: "Nothing to show for a future date.")
        }
        return EmptyState(symbol: "calendar", title: "No activity tracked",
                          detail: "Nothing was recorded. If you worked, the tracker was off — see Settings → Tracking.")
    }
}

#Preview("Weekday") { DayView(data: .fixture(), onNavigate: { _ in }).frame(width: 1280, height: 860) }
#Preview("Today") { DayView(data: .fixture(date: LocalDate(year: 2026, month: 10, day: 5), now: (14, 32)), onNavigate: { _ in }).frame(width: 1280, height: 860) }
#Preview("Empty") { DayView(data: .fixture(empty: true), onNavigate: { _ in }).frame(width: 1280, height: 860) }
#Preview("Permission lost") {
    DayView(data: .fixture(date: LocalDate(year: 2026, month: 10, day: 5), now: (9, 0), empty: true, tracker: .permissionMissing),
            onNavigate: { _ in }).frame(width: 1280, height: 860)
}
