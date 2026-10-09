import SwiftUI
import HoursCore
import ScryCore

extension FocusedValues {
    @Entry var shellModel: AppModel?
}

/// Main window content: sidebar (Day / Week / Range / Meetings, Settings pinned bottom, health pill) + detail
/// (tracker banner, the view slot) + toolbar date navigation.
public struct ShellRootView: View {
    @Bindable var model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The day whose EOD standup sheet is open (W20).
    @State private var standupDay: LocalDate?
    /// The block last opened from the Week's Blocks mode; Day → Blocks selects it on that day (W22).
    @State private var openedBlock: WeekBlockRoute?

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .navigationTitle(model.view.title)
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
                .environment(\.openStandup, { standupDay = $0 })
                .environment(\.scryRoot, scryRoot)
                .environment(\.openMeeting, { model.openMeeting($0) })
                .sheet(isPresented: Binding(get: { standupDay != nil }, set: { if !$0 { standupDay = nil } })) {
                    if let day = standupDay { StandupSheet(db: model.db, date: day, timeZone: model.timeZone) }
                }
        }
        // Minimum window 900 × 600: the title bar/toolbar adds 52 pt above the content.
        .frame(minWidth: 900, minHeight: 548)
        .tint(Theme.ink)
        .background(ShellWindowObserver(onVisible: { model.setVisible($0) }, onActivate: { model.appDidActivate() }))
        .focusedSceneValue(\.shellModel, model)
        .onKeyPress(.leftArrow) { arrow(-1) }
        .onKeyPress(.rightArrow) { arrow(1) }
        // Bare T = Today (⌘T is the menu item). Text fields get the key first, so typing a "t" is safe.
        .onKeyPress(keys: ["t"]) { press in
            guard press.modifiers.subtracting([.shift, .capsLock]).isEmpty else { return .ignored }
            model.goToday()
            return .handled
        }
        .onDisappear { model.setVisible(false) }
    }

    private var subtitle: String {
        // Day, Week and Range headers show their own date/period.
        ""
    }

    private var scryRoot: URL { ScrySettings.load(model.settings).rootURL }

    private func arrow(_ days: Int) -> KeyPress.Result {
        guard model.view != .range, model.view != .meetings else { return .ignored }
        model.step(days: model.view == .week ? 7 * days : days)
        return .handled
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $model.view) {
            ForEach(ShellView.allCases) { v in
                Label(v.title, systemImage: v.symbol).tag(v)
            }
        }
        .symbolRenderingMode(.monochrome)
        .navigationSplitViewColumnWidth(min: 190, ideal: 208, max: 260)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .buttonStyle(.plain)
                    .textRole(.body)
                HealthPill(model.health, timeZone: model.timeZone)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            if let banner {
                ShellBanner(content: banner) { bannerAction() }
                    .padding([.horizontal, .top], Theme.Space.gutter)
                    // The app's one slide: down from the toolbar edge, back up on dismiss. The animation
                    // rides on the transition so the page below re-lays out unanimated (Blocks stays pinned).
                    .transition(.move(edge: .top).combined(with: .opacity).animation(Theme.Motion.settle(reduceMotion: reduceMotion)))
            }
            // min 0 + topLeading + clipped: a view larger than the detail column clips at its right/bottom
            // edge instead of growing the window content (which shoves the sidebar off-screen / under the title bar).
            // ⌘1–⌘4 crossfade; the ZStack overlaps the outgoing and incoming views.
            ZStack {
                content.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .id(model.view)
                    .transition(.opacity)
            }
            .clipped()
            .animation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion), value: model.view)
        }
        .clipped()   // the banner slides out from under the toolbar edge, not over it
        .background(Theme.canvas)
    }

    private var banner: ShellBanner.Content? {
        ShellBanner.content(helper: model.helperStatus, health: model.health, timeZone: model.timeZone)
    }

    @ViewBuilder private var content: some View {
        switch model.view {
        case .day:
            if let d = model.dayData {
                ViewSlot.dayView(d, db: model.db) { model.selectedDay = $0 }
                    .environment(\.blocksOpenRequest, openedBlock)
            } else { loading }
        case .week:
            if let w = model.weekData {
                ViewSlot.weekView(w, onSelectDay: { model.selectedDay = $0; model.view = .day },
                                  onNavigate: { model.selectedDay = min($0, model.today) },
                                  onOpenBlock: { route in
                                      openedBlock = route
                                      route.apply { model.selectedDay = $0; model.view = .day }
                                  })
            } else { loading }
        case .range:
            if let r = model.rangeData {
                ViewSlot.rangeView(r, period: $model.rangePeriod, today: model.today)
            } else { loading }
        case .meetings:
            MeetingsView(root: scryRoot, selection: $model.meetingNote, timeZone: model.timeZone)
        }
    }

    @ViewBuilder private var loading: some View {
        if let err = model.loadError {
            EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load", detail: err)
        } else {
            Color.clear
        }
    }

    private func bannerAction() {
        switch (model.helperStatus, model.health) {
        case (_, .permissionMissing):
            openURL(ShellSystemPane.accessibility)
        case (.needsApproval, _) where !isStopped:
            model.openLoginItems?()
        default:
            Task { await model.checkTracker() }
        }
    }

    private var isStopped: Bool { if case .stopped = model.health { true } else { false } }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Day, Week and Range carry their own ‹ › controls; Week keeps the toolbar calendar to jump to any week.
        if model.view == .week {
            ToolbarItemGroup(placement: .navigation) {
                ShellDatePickerButton(model: model)
            }
        }
    }
}

/// Toolbar date: "Mon 5 Oct ▾" → graphical calendar popover.
struct ShellDatePickerButton: View {
    @Bindable var model: AppModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Theme.Space.xs) {
                Text(model.selectedDay.shellTitle).monospacedDigit()
                Image(systemName: "chevron.down").imageScale(.small)
            }
        }
        .popover(isPresented: $open) {
            DatePicker("", selection: Binding(
                get: { model.selectedDay.shellDate },
                set: { model.selectedDay = LocalDate(shellDate: $0, in: TimeZone(identifier: "UTC")!); open = false }),
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                .padding(Theme.Space.m)
        }
    }
}

/// System Settings deep links.
enum ShellSystemPane {
    static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let automation = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}

/// "Go" menu: views and day navigation. ⌘[ / ⌘] work even while a text field has focus.
public struct ShellCommands: Commands {
    @FocusedValue(\.shellModel) private var model

    public init() {}

    public var body: some Commands {
        CommandMenu("Go") {
            ForEach(Array(ShellView.allCases.enumerated()), id: \.element) { i, v in
                Button(v.title) { model?.view = v }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
            Divider()
            Button("Previous Day") { model?.step(days: -1) }.keyboardShortcut("[", modifiers: .command)
            Button("Next Day") { model?.step(days: 1) }.keyboardShortcut("]", modifiers: .command)
            Button("Today") { model?.goToday() }.keyboardShortcut("t", modifiers: .command)
        }
        CommandMenu("Tracker") {
            if model?.pausedUntilMs != nil {
                Button("Resume Tracking") { Task { await model?.setPause(untilMs: nil) } }
            }
            Button("Pause for 15 Minutes") { Task { await model?.pause(minutes: 15) } }
            Button("Pause for 1 Hour") { Task { await model?.pause(minutes: 60) } }
            Button("Pause Until Tomorrow") { Task { await model?.pauseUntilTomorrow() } }
        }
        EditCommands()   // W12: timeline editing items in the Edit menu (Undo/Redo come from the window's UndoManager)
    }
}
