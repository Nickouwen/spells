import AppKit
import HoursCore
import QuartzCore
import TrackerCore
import notify

/// Notch island (W18): a black shape hugging the notch — goal ring + category dot in the left ear,
/// today's work time in the right — that springs open on hover into a card with the day's details.
/// AppKit + Core Animation only. No timer of its own: data is re-queried on DB change (notify) and
/// on the runtime's 30 s tick; the label adds the live span's elapsed time in between. Core
/// Animation runs only while expanding/collapsing.
@MainActor final class TrackerIsland: NSObject {
    private let db: HoursDB
    private let runtime: TrackerRuntime
    private let actions: TrackerStatusItem
    private let forceExpanded: Bool

    private let panel = TrackerIslandPanel()
    private let root = TrackerIslandRootView()
    private let shapeView = TrackerIslandShapeView()

    // Collapsed ears.
    private let earRing = TrackerIslandRingView(lineWidth: 2.25)
    private let earDot = TrackerIslandDotView()
    private let earWarn = NSImageView()
    private let earTime = TrackerIslandLabel(font: TrackerIsland.earFont, color: TrackerIslandPalette.ink)
    // Expanded card.
    private let card = NSView()
    private let eyebrow = TrackerIslandLabel(font: .systemFont(ofSize: 11, weight: .semibold), color: TrackerIslandPalette.inkSecondary)
    private let state = TrackerIslandLabel(font: .systemFont(ofSize: 11, weight: .semibold), color: TrackerIslandPalette.inkSecondary)
    private let hero = TrackerIslandLabel(font: .monospacedDigitSystemFont(ofSize: 30, weight: .light), color: TrackerIslandPalette.ink)
    private let detail = TrackerIslandLabel(font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: TrackerIslandPalette.inkSecondary)
    private let appDot = TrackerIslandDotView()
    private let appLine = TrackerIslandLabel(font: .systemFont(ofSize: 11, weight: .medium), color: TrackerIslandPalette.ink)
    private let goalRing = TrackerIslandRingView(lineWidth: 3.5)
    private let goalPct = TrackerIslandLabel(font: .monospacedDigitSystemFont(ofSize: 15, weight: .semibold), color: TrackerIslandPalette.ink)
    private let goalOf = TrackerIslandLabel(font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: TrackerIslandPalette.inkSecondary)
    private lazy var pauseButton = TrackerIslandButton(title: "Pause", symbol: "pause.fill", target: self, action: #selector(pauseTapped))
    private lazy var openButton = TrackerIslandButton(title: "Open Spells", symbol: "arrow.up.forward.app", target: self, action: #selector(openTapped))

    private(set) var style: TrackerIslandStyle = .off
    private var geometry: TrackerIslandGeometry?
    private var today = TrackerIslandToday()
    private var queriedAtMs: Int64 = 0
    private var queriedLiveStart: Int64?
    private var isExpanded = false
    private var menuOpen = false
    private var collapseWork: DispatchWorkItem?
    private var token: Int32 = NOTIFY_TOKEN_INVALID
    private var refreshPending = false
    private var buttonShowsResume = false
    private var deferredQuery: DispatchWorkItem?
    private var rendered: RenderKey?
    /// LaunchServices lookup once, not per render.
    private lazy var canOpenHours = TrackerStatusItem.appURL() != nil

    init(db: HoursDB, runtime: TrackerRuntime, actions: TrackerStatusItem) {
        self.db = db; self.runtime = runtime; self.actions = actions
        let env = ProcessInfo.processInfo.environment
        forceExpanded = env["SPELLS_HOME"] != nil && env["HOURS_ISLAND_FORCE_EXPANDED"] == "1"
        super.init()
        build()
    }

    // MARK: - Lifecycle

    /// Reads `island_style`, subscribes to the change feed and screen changes.
    func start() {
        notify_register_dispatch(db.notifyName, &token, DispatchQueue.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
        applyStyle(loadStyle())
    }

    /// Persist + apply (status-item menu). The change-feed post re-applies it — a no-op by then.
    func setStyle(_ s: TrackerIslandStyle) {
        do { try SettingStore(db).set(TrackerIslandStyle.key, s.rawValue) } catch {
            SupportLog.tracker.error("island_style not saved: \(String(describing: error), privacy: .public)")
        }
        applyStyle(s)
    }

    /// From `TrackerRuntime.onChange` (every event incl. the 30 s tick). Asks for a query when a
    /// tick's worth of time passed or the live span changed; otherwise just re-renders (no I/O).
    func runtimeChanged() {
        guard style != .off else { return }
        let now = TrackerStateSync.wallMs()
        if now - queriedAtMs >= 25_000 || runtime.liveStartMs != queriedLiveStart { requestQuery() }
        render(nowMs: now)
    }

    // MARK: - Data

    private func loadStyle() -> TrackerIslandStyle {
        TrackerIslandStyle.parse(try? SettingStore(db).get(TrackerIslandStyle.key))
    }

    /// Coalesces a burst of DB notifications (span write + tracker_state) into one query.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPending = false
                self.applyStyle(self.loadStyle())
                guard self.style != .off else { return }
                self.requestQuery()
                self.render(nowMs: TrackerStateSync.wallMs())
            }
        }
    }

    /// Collapsed, only the minute label, dot and ring show: at most one query per 10 s. Expanded
    /// (the app line is visible): one per second. Title churn (a terminal spinner, the installed
    /// tracker's posts on the shared notify name) would otherwise run the day query many times a second.
    private var minQueryGapMs: Int64 { isExpanded ? 1_000 : 10_000 }

    /// Queries now if the last one is old enough, else once (one-shot, coalesced) when it will be.
    private func requestQuery() {
        let now = TrackerStateSync.wallMs()
        let wait = queriedAtMs + minQueryGapMs - now
        if wait <= 0 {
            deferredQuery?.cancel(); deferredQuery = nil
            query(nowMs: now)
            return
        }
        guard deferredQuery == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deferredQuery = nil
                guard self.style != .off else { return }
                let now = TrackerStateSync.wallMs()
                self.query(nowMs: now)
                self.render(nowMs: now)
            }
        }
        deferredQuery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(wait)), execute: work)
    }

    private func query(nowMs: Int64) {
        do { today = try TrackerIslandToday.load(db: db, nowMs: nowMs) } catch {
            SupportLog.tracker.error("island query failed: \(String(describing: error), privacy: .public)")
        }
        queriedAtMs = nowMs
        queriedLiveStart = runtime.liveStartMs
    }

    // MARK: - Show / hide / geometry

    private func applyStyle(_ s: TrackerIslandStyle) {
        guard s != style else { return }
        style = s
        if s == .off {
            collapseWork?.cancel()
            deferredQuery?.cancel(); deferredQuery = nil
            isExpanded = false
            panel.orderOut(nil)
            geometry = nil
            return
        }
        let now = TrackerStateSync.wallMs()
        query(nowMs: now)
        relayout()
        render(nowMs: now)
    }

    private func relayout() {
        guard style != .off else { return }
        geometry = TrackerIslandGeometry.make(screens: NSScreen.screens.map(Self.screenFacts), style: style,
                                              earWidth: Self.earWidth)
        guard let g = geometry else { panel.orderOut(nil); return }
        if forceExpanded { isExpanded = true }
        rendered = nil
        let win = isExpanded ? expandedWindow(g) : g.collapsedWindow
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(win, display: true)
        layout(in: win)
        shapeView.shape.path = path(isExpanded ? g.expanded : g.collapsed, in: win, expanded: isExpanded)
        earContainerAlpha(isExpanded ? 0 : 1)
        card.alphaValue = isExpanded ? 1 : 0
        shapeView.shape.shadowOpacity = isExpanded ? Self.shadowOpacity : 0
        CATransaction.commit()
        panel.orderFrontRegardless()
    }

    /// The expanded window leaves room for the card's soft layer shadow (a window shadow would add a
    /// light rim around the black, and along the notch flares). Only while expanded, so collapsed
    /// the window is exactly the shape and nothing around it eats clicks.
    private static let shadowMargin: CGFloat = 24
    private static let shadowOpacity: Float = 0.45

    private func expandedWindow(_ g: TrackerIslandGeometry) -> CGRect {
        let w = g.expandedWindow, m = Self.shadowMargin
        return CGRect(x: w.minX - m, y: w.minY - m, width: w.width + 2 * m, height: w.height + m)
    }

    /// Both ears get the width of the widest label the right one must hold, measured in its font.
    private static let earFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private static let earWidth: CGFloat = TrackerIslandGeometry.earWidth(forText: ["10h 59m", "Paused"].map {
        ceil(NSAttributedString(string: $0, attributes: [.font: earFont]).size().width)
    }.max() ?? 52)
    /// NSTextField labels draw their text this far inside their frame.
    private static let cellInset: CGFloat = 2

    static func screenFacts(_ s: NSScreen) -> TrackerIslandScreen {
        TrackerIslandScreen(frame: s.frame, visibleFrame: s.visibleFrame, safeAreaTop: s.safeAreaInsets.top,
                            auxiliaryTopLeft: s.auxiliaryTopLeftArea, auxiliaryTopRight: s.auxiliaryTopRightArea)
    }

    private func path(_ body: CGRect, in win: CGRect, expanded: Bool) -> CGPath {
        guard let g = geometry else { return CGMutablePath() }
        let local = body.offsetBy(dx: -win.minX, dy: -win.minY)
        let radius = expanded ? TrackerIslandGeometry.expandedRadius : g.collapsedRadius
        return TrackerIslandShapeView.path(body: local, bottom: radius, top: radius, flare: g.flare)
    }

    // MARK: - Build & layout

    private func build() {
        root.frame = .zero
        root.wantsLayer = true
        root.onHover = { [weak self] inside in self?.hover(inside) }
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        panel.contentView = root
        shapeView.autoresizingMask = [.width, .height]
        root.addSubview(shapeView)
        earWarn.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Accessibility permission missing")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        earWarn.contentTintColor = TrackerIslandPalette.rgb(TrackerIslandPalette.warn)
        earTime.alignment = .right
        earTime.lineBreakMode = .byClipping
        for v in [earRing, earDot, earWarn, earTime] as [NSView] { root.addSubview(v) }

        card.wantsLayer = true
        card.alphaValue = 0
        root.addSubview(card)
        state.alignment = .right
        goalPct.alignment = .right
        goalOf.alignment = .right
        hero.onClick = { [weak self] in self?.openTapped() }
        hero.toolTip = "Open Spells"
        for v in [eyebrow, state, hero, detail, appDot, appLine, goalRing, goalPct, goalOf, pauseButton, openButton] as [NSView] {
            card.addSubview(v)
        }
        eyebrow.stringValue = "Today"
    }

    private func earContainerAlpha(_ a: CGFloat) {
        for v in [earRing, earDot, earWarn, earTime] as [NSView] { v.alphaValue = a }
    }

    /// Positions everything for a window at `win` (global). Ear content keeps its global place, so
    /// it fades out in situ when the window grows; the card is laid out against the expanded rect.
    private func layout(in win: CGRect) {
        guard let g = geometry else { return }
        root.frame = CGRect(origin: .zero, size: win.size)
        shapeView.frame = root.bounds
        func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -win.minX, dy: -win.minY).integral }
        root.hoverRect = local(isExpanded ? g.expanded : g.collapsedWindow)

        // Same inset from each ear's outer edge: the time is right-aligned to it, the ring/dot
        // group left-aligned to it. The ear is sized for "10h 59m", so shorter labels leave the
        // slack on the notch side and the outer edge never moves.
        let inset = TrackerIslandGeometry.earOuterInset, ci = Self.cellInset
        let right = g.rightEar
        earTime.sizeToFit()
        let th = earTime.frame.height
        let tx0 = right.minX + TrackerIslandGeometry.earInnerGap - ci
        earTime.frame = local(CGRect(x: tx0, y: right.midY - th / 2, width: right.maxX - inset + ci - tx0, height: th))
        // Left ear: [ring  dot]; the warning glyph replaces the ring.
        let ring: CGFloat = 13, dot: CGFloat = 7, gap: CGFloat = 7
        if let left = g.leftEar {
            let hasRing = !earRing.isHidden || !earWarn.isHidden
            let x0 = left.minX + inset
            earRing.frame = local(CGRect(x: x0, y: left.midY - ring / 2, width: ring, height: ring))
            earWarn.frame = local(CGRect(x: x0 - 1, y: left.midY - 7.5, width: 15, height: 15))
            let dx = hasRing ? x0 + ring + gap : x0
            earDot.frame = local(CGRect(x: dx, y: left.midY - dot / 2, width: dot, height: dot))
        }

        // Card: the expanded rect; content lives in the band under the notch (+ the strip beside it).
        let e = g.expanded
        card.frame = local(e)
        let W = e.width, H = e.height, top = g.notch.height, pad: CGFloat = 20
        func at(_ x: CGFloat, _ yFromTop: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x, y: H - yFromTop - h, width: w, height: h)
        }
        let strip = (W - g.notch.width) / 2   // beside the notch
        // Text frames are shifted by the cell inset so the glyphs (not the frames) sit `pad` from
        // the card's edges, matching the ring and buttons.
        eyebrow.frame = at(pad - ci, top / 2 - 7, strip - pad, 14)
        state.frame = at(W - strip + ci, top / 2 - 7, strip - pad, 14)
        let colW = W * 0.56
        hero.frame = at(pad - ci - 1, top + 4, colW, 36)   // light 30 pt has ~1 pt more side bearing
        detail.frame = at(pad - ci, top + 44, colW, 15)
        appDot.frame = at(pad, top + 66 + 4, 7, 7)
        appLine.frame = at(pad + 13 - ci, top + 66, colW - 13, 15)
        let ringD: CGFloat = 34
        goalRing.frame = at(W - pad - ringD, top + 8, ringD, ringD)
        goalPct.frame = at(W - pad - ringD - 8 - 90 + ci, top + 9, 90, 19)
        goalOf.frame = goalRing.isHidden
            ? at(W - pad - 140 + ci, top + 8 + ringD / 2 - 7.5, 140, 15)   // "No goal today", flush right
            : at(W - pad - ringD - 8 - 90 + ci, top + 28, 90, 15)
        let bh: CGFloat = 24
        openButton.frame = at(W - pad - 92, top + 62, 92, bh)
        pauseButton.frame = at(W - pad - 92 - 6 - 74, top + 62, 74, bh)
    }

    // MARK: - Render

    /// Everything `render` shows; equal keys skip the AppKit work (onChange fires on every event).
    private struct RenderKey: Equatable {
        var today: TrackerIslandToday, work: String, percent: Int?, paused: Int64?
        var ax: Bool, tracking: Bool, expanded: Bool, style: TrackerIslandStyle
    }

    private func render(nowMs: Int64) {
        guard geometry != nil else { return }
        let paused = runtime.pausedUntilMs != nil
        let axMissing = !runtime.isAccessibilityTrusted
        let idle = !paused && !runtime.isTracking
        let work = TrackerIslandFormat.duration(ms: today.workMs(nowMs: nowMs))
        let progress = today.goalProgress(nowMs: nowMs)
        var stable = today
        stable.live?.endMs = 0   // moves every heartbeat; only `work` (already in the key) depends on it
        let key = RenderKey(today: stable, work: work, percent: progress.map { Int(($0 * 100).rounded()) },
                            paused: runtime.pausedUntilMs, ax: axMissing, tracking: runtime.isTracking,
                            expanded: isExpanded, style: style)
        guard key != rendered else { return }
        rendered = key
        let dotColor = TrackerIslandPalette.color(slot: today.live?.colorSlot)

        // Collapsed.
        // Right-only style has no room for the glyph: the time turns amber instead.
        let warnColor = TrackerIslandPalette.rgb(TrackerIslandPalette.warn)
        earTime.update(paused ? "Paused" : work, color: axMissing && geometry?.leftEar == nil ? warnColor
                       : idle || paused ? TrackerIslandPalette.inkDim : TrackerIslandPalette.ink)
        earWarn.isHidden = !axMissing || geometry?.leftEar == nil
        earRing.isHidden = axMissing || progress == nil
        earRing.progress = progress ?? 0
        earDot.set(color: idle ? TrackerIslandPalette.inkDim : dotColor, hollow: paused || today.live == nil)

        // Expanded.
        hero.update(work)
        state.update(axMissing ? "No access" : paused ? "Paused" : idle ? "Idle" : "Tracking",
                     color: axMissing ? TrackerIslandPalette.rgb(TrackerIslandPalette.warn) : TrackerIslandPalette.inkSecondary)
        detail.update("Focus \(TrackerIslandFormat.duration(ms: today.focusMs)) · Billable \(TrackerIslandFormat.duration(ms: today.billableMs))")
        if let until = runtime.pausedUntilMs {
            appLine.update("Paused until \(TrackerStatusItem.clock(until))", color: TrackerIslandPalette.inkSecondary)
        } else if let live = today.live, runtime.isTracking {
            appLine.update("\(live.appName) · \(live.categoryName)", color: TrackerIslandPalette.ink)
        } else {
            appLine.update(idle ? "Away — not tracking" : "Nothing tracked yet", color: TrackerIslandPalette.inkSecondary)
        }
        appDot.set(color: dotColor, hollow: paused || today.live == nil || !runtime.isTracking)
        if let progress, let goal = today.goalMs {
            goalRing.isHidden = false; goalPct.isHidden = false
            goalRing.progress = progress
            goalPct.update("\(Int((progress * 100).rounded()))%")
            goalOf.update("of \(TrackerIslandFormat.duration(ms: goal)) goal")
        } else {
            goalRing.isHidden = true; goalPct.isHidden = true
            goalOf.update("No goal today")
        }
        if paused != buttonShowsResume {
            buttonShowsResume = paused
            pauseButton.setTitle(paused ? "Resume" : "Pause")
            pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        }
        openButton.isEnabled = canOpenHours
        root.setAccessibilityLabel("Hours: \(paused ? "paused" : work + " work today")")
        // Ring / warning / goal presence changes the arrangement (a changed key, so rare).
        layout(in: panel.frame)
    }

    // MARK: - Hover / animation

    private func hover(_ inside: Bool) {
        guard !forceExpanded else { return }
        collapseWork?.cancel()
        if inside { expand(); return }
        guard !menuOpen else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.collapse() } }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func expand() {
        guard !isExpanded, let g = geometry else { return }
        isExpanded = true
        requestQuery()                              // ≤ 1 s old while open
        render(nowMs: TrackerStateSync.wallMs())   // the hero ticks on open
        let win = expandedWindow(g)
        // Hold the screen until the bigger window and the collapsed path (in its coordinates) are both
        // in: otherwise one frame shows the old path offset inside the new frame, detached from the top.
        panel.disableScreenUpdatesUntilFlush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(win, display: true)
        layout(in: win)
        shapeView.shape.path = path(g.collapsed, in: win, expanded: false)
        CATransaction.commit()
        animate(to: path(g.expanded, in: win, expanded: true)) {}
        fade(ears: 0, card: 1)
    }

    private func collapse() {
        guard isExpanded, let g = geometry else { return }
        isExpanded = false
        animate(to: path(g.collapsed, in: panel.frame, expanded: false)) { [weak self] in
            guard let self, !self.isExpanded, let g = self.geometry else { return }
            let win = g.collapsedWindow
            self.panel.disableScreenUpdatesUntilFlush()   // same one-frame glitch on the way back
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.panel.setFrame(win, display: true)
            self.layout(in: win)
            self.shapeView.shape.path = self.path(g.collapsed, in: win, expanded: false)
            CATransaction.commit()
        }
        fade(ears: 1, card: 0)
    }

    private func animate(to target: CGPath, completion: @escaping @MainActor () -> Void) {
        let layer = shapeView.shape
        let from = layer.presentation()?.path ?? layer.path
        let shadow: Float = isExpanded ? Self.shadowOpacity : 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        if !reduceMotion {
            let fade = CABasicAnimation(keyPath: "shadowOpacity")
            fade.fromValue = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
            fade.toValue = shadow
            fade.duration = 0.25
            layer.add(fade, forKey: "shadowOpacity")
            // No bounce: it drops down and settles, rather than overshooting (read as a judder).
            let spring = CASpringAnimation(perceptualDuration: 0.32, bounce: 0)
            spring.keyPath = "path"
            spring.fromValue = from
            spring.toValue = target
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "path")
        }
        layer.path = target
        layer.shadowOpacity = shadow
        CATransaction.commit()
    }

    private func fade(ears: CGFloat, card cardAlpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0 : (cardAlpha > 0 ? 0.28 : 0.14)
            for v in [earRing, earDot, earWarn, earTime] as [NSView] { v.animator().alphaValue = ears }
            card.animator().alphaValue = cardAlpha
        }
    }

    // MARK: - Actions

    @objc private func pauseTapped() {
        if runtime.pausedUntilMs != nil {
            actions.resumeTracking()
            render(nowMs: TrackerStateSync.wallMs())
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, minutes) in [("Pause 15 min", 15), ("Pause 1 hour", 60)] {
            let i = NSMenuItem(title: title, action: #selector(pauseFor(_:)), keyEquivalent: "")
            i.target = self; i.tag = minutes
            menu.addItem(i)
        }
        let t = NSMenuItem(title: "Pause until tomorrow", action: #selector(pauseTomorrow), keyEquivalent: "")
        t.target = self
        menu.addItem(t)
        menuOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: pauseButton)
        menuOpen = false
        // The pointer may have left while the menu was up.
        if let g = geometry, !g.expanded.contains(NSEvent.mouseLocation) { hover(false) }
    }

    @objc private func pauseFor(_ sender: NSMenuItem) {
        actions.pause(minutes: sender.tag)
        render(nowMs: TrackerStateSync.wallMs())
    }

    @objc private func pauseTomorrow() {
        actions.pauseUntilTomorrowNow()
        render(nowMs: TrackerStateSync.wallMs())
    }

    @objc private func openTapped() { actions.openHoursApp() }
}
