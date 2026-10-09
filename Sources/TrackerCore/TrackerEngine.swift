import HoursCore

/// Pure activity state machine: `(state, event, sample) -> [output]`. Deterministic, no OS calls.
///
/// Timeline shape: `active` spans while present, an `idle` span (same front app, back-dated to
/// the last input) while AFK, and *gaps* while asleep / locked / switched out / an excluded app
/// is frontmost. An idle span only ever follows an active one — waking with no input opens nothing.
public struct TrackerEngine: Sendable {
    struct Key: Equatable, Sendable {
        var bundleId: String?
        var appName: String
        var title: String?
        var url: String?
    }
    struct Candidate: Sendable { var key: Key; var at: Int64 }

    /// `var` so the helper can apply a new idle threshold live (W16); takes effect on the next event.
    public var config: TrackerConfig
    public private(set) var live: RawSpan?
    /// Set while paused; cleared by `.pause(nil)` or by the first event at/after it.
    public private(set) var pausedUntilMs: Int64?

    var front: Key?
    var frontSince: Int64 = .min
    var candidate: Candidate?
    /// Every emitted boundary is ≥ this (the last start/end), so clock jumps can't make overlaps.
    var floor: Int64 = .min
    var gateOpenedAt: Int64 = .min
    var heldUntil: Int64 = .min
    var lastOffset: Int64?
    var asleep = false, displayAsleep = false, locked = false, sessionInactive = false, terminated = false
    /// When the last sleep / screens-sleep began: input after it proves we're awake (missed wake heal).
    var sleptAt: Int64 = .min
    /// Set by `.powerOff`; cleared by the first input after it (a cancelled logout/shutdown).
    var poweredOffAt: Int64?

    public init(config: TrackerConfig = TrackerConfig()) { self.config = config }

    public mutating func handle(_ event: TrackerEvent, _ s: TrackerSample) -> [TrackerOutput] {
        var out: [TrackerOutput] = []
        if gateOpenedAt == .min { gateOpenedAt = s.wallMs }
        if s.heldActive { heldUntil = s.wallMs }
        if let p = pausedUntilMs, s.wallMs >= p { pausedUntilMs = nil; gateOpenedAt = max(gateOpenedAt, p) }
        if let p = poweredOffAt, s.wallMs - s.idleMs > p { poweredOffAt = nil; gateOpenedAt = max(gateOpenedAt, s.wallMs - s.idleMs) }
        checkClock(s, &out)
        checkTimeZone(s, &out)
        reconcile(s, &out) // idle check on every event, before the event's own effect

        switch event {
        case .observed(let o): observe(o, s, &out)
        case .debounceFired: commitCandidate(&out)
        case .tick: rederiveGates(s)
        case .clockChanged, .timeZoneChanged: break
        case .willSleep: asleep = true; sleptAt = s.wallMs
        case .didWake: asleep = false; gateOpenedAt = s.wallMs
        case .screensSlept: displayAsleep = true; sleptAt = s.wallMs
        case .screensWoke: displayAsleep = false; gateOpenedAt = s.wallMs
        case .locked: locked = true
        case .unlocked: locked = false; gateOpenedAt = s.wallMs
        case .sessionResigned: sessionInactive = true
        case .sessionActivated: sessionInactive = false; gateOpenedAt = s.wallMs
        case .pause(let until):
            let wasPaused = pausedUntilMs != nil
            pausedUntilMs = until.flatMap { $0 > s.wallMs ? $0 : nil }
            if wasPaused, pausedUntilMs == nil { gateOpenedAt = s.wallMs }
        case .powerOff: poweredOffAt = s.wallMs
        case .terminate: terminated = true
        }

        reconcile(s, &out)
        if event == .tick, live != nil { out.append(.heartbeat(lastSeenMs: max(s.wallMs, floor))) }
        return out
    }

    // MARK: - Steps

    private mutating func observe(_ o: TrackerObservation, _ s: TrackerSample, _ out: inout [TrackerOutput]) {
        let key = Key(bundleId: o.bundleId, appName: o.appName,
                      title: o.isPrivate ? nil : TrackerSanitize.title(o.title),
                      url: o.isPrivate ? nil : TrackerSanitize.url(o.url))
        guard let front else { // first observation after launch: no debounce
            self.front = key; frontSince = s.wallMs
            return
        }
        if key == front {
            if candidate != nil { candidate = nil; out.append(.cancelDebounce) }
            return
        }
        if key == candidate?.key { return }
        candidate = Candidate(key: key, at: s.wallMs)
        out.append(.armDebounce)
    }

    private mutating func commitCandidate(_ out: inout [TrackerOutput]) {
        guard let c = candidate else { return }
        candidate = nil
        front = c.key; frontSince = c.at
        guard let cur = live else { return }
        if isExcluded(c.key) {
            close(at: c.at, .excluded, next: nil, &out)
        } else {
            close(at: c.at, .switch, next: span(c.key, cur.kind, c.at, tzId: cur.tzId, tzOffsetS: cur.tzOffsetS), &out)
        }
    }

    private mutating func reconcile(_ s: TrackerSample, _ out: inout [TrackerOutput]) {
        if let reason = gateClosedReason() {
            if live != nil { close(at: s.wallMs, reason, next: nil, &out) }
            return
        }
        guard let front else { return }
        let afk = s.idleMs >= config.idleThresholdMs && !s.heldActive
        let lastInput = s.wallMs - s.idleMs
        switch live?.kind {
        case nil:
            if !afk { open(span(front, .active, max(lastInput, gateOpenedAt, frontSince), s), &out) }
        case .active?:
            // Back-date to the last input, but not before the last tick that confirmed a media hold.
            if afk { let t = max(lastInput, heldUntil); close(at: t, .afk, next: span(front, .idle, t, s), &out) }
        case .idle?:
            if !afk { close(at: lastInput, .resume, next: span(front, .active, lastInput, s), &out) }
        }
    }

    /// Self-heals gates whose notification may have been missed (they'd otherwise stay shut for good).
    /// Sleep: input after it began proves we're awake (a dark wake has none). Lock / console: the
    /// session dictionary is authoritative both ways; a reopen starts at the tick that noticed.
    // ponytail: password typing is input too, so a healed unlock can't back-date — up to one tick
    // (30 s) after a *missed* unlock goes uncounted. The notification path is exact.
    private mutating func rederiveGates(_ s: TrackerSample) {
        let lastInput = s.wallMs - s.idleMs
        if asleep || displayAsleep, lastInput > sleptAt {
            asleep = false; displayAsleep = false; gateOpenedAt = max(gateOpenedAt, lastInput)
        }
        guard let session = s.session else { return }
        if locked != session.locked {
            locked = session.locked
            if !locked { gateOpenedAt = s.wallMs }
        }
        if sessionInactive == session.onConsole {
            sessionInactive = !session.onConsole
            if !sessionInactive { gateOpenedAt = s.wallMs }
        }
    }

    private mutating func checkClock(_ s: TrackerSample, _ out: inout [TrackerOutput]) {
        let offset = s.wallMs - s.monoMs
        defer { lastOffset = offset }
        guard let last = lastOffset, abs(offset - last) > config.clockJumpToleranceMs, let cur = live else { return }
        // Close at "now" in the old wall frame (start + monotonic elapsed), reopen at the new wall time.
        // ponytail: after a backwards jump the reopened span is pinned to the old end (floor), so it
        // stays zero-length until wall time catches up; that slice of time is lost, never overlapped.
        close(at: s.monoMs + last, .clock, next: span(key(of: cur), cur.kind, s.wallMs, s), &out)
    }

    private mutating func checkTimeZone(_ s: TrackerSample, _ out: inout [TrackerOutput]) {
        guard let cur = live, cur.tzId != s.tzId || cur.tzOffsetS != s.tzOffsetS else { return }
        close(at: s.wallMs, .timezone, next: span(key(of: cur), cur.kind, s.wallMs, s), &out)
    }

    // MARK: - Emission

    private mutating func open(_ next: RawSpan, _ out: inout [TrackerOutput]) {
        var n = next
        n.startMs = max(n.startMs, floor); n.endMs = n.startMs
        live = n; floor = n.startMs
        out.append(.open(n))
    }

    private mutating func close(at t: Int64, _ reason: EndReason, next: RawSpan?, _ out: inout [TrackerOutput]) {
        guard let cur = live else { return }
        let end = max(t, floor)
        var n = next
        if n != nil { n!.startMs = max(n!.startMs, end); n!.endMs = n!.startMs }
        // A zero-length span is never chained.
        out.append(end <= cur.startMs ? .replace(n) : .close(atMs: end, reason: reason, next: n))
        live = n
        floor = n?.startMs ?? end
    }

    // MARK: - Helpers

    private func gateClosedReason() -> EndReason? {
        if terminated { return .terminate }
        if poweredOffAt != nil { return .powerOff }
        if pausedUntilMs != nil { return .pause }
        if asleep || displayAsleep { return .sleep }
        if locked { return .lock }
        if sessionInactive { return .session }
        if let front, isExcluded(front) { return .excluded }
        return nil
    }

    private func isExcluded(_ k: Key) -> Bool { k.bundleId.map(config.excludedBundles.contains) ?? false }

    private func key(of s: RawSpan) -> Key { Key(bundleId: s.bundleId, appName: s.appName, title: s.title, url: s.url) }

    private func span(_ k: Key, _ kind: SpanKind, _ start: Int64, _ s: TrackerSample) -> RawSpan {
        span(k, kind, start, tzId: s.tzId, tzOffsetS: s.tzOffsetS)
    }

    private func span(_ k: Key, _ kind: SpanKind, _ start: Int64, tzId: String, tzOffsetS: Int) -> RawSpan {
        RawSpan(seq: 0, startMs: start, endMs: start, tzId: tzId, tzOffsetS: tzOffsetS, kind: kind,
                bundleId: k.bundleId, appName: k.appName, title: k.title, url: k.url)
    }
}
