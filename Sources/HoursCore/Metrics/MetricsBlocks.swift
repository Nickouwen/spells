import Foundation

/// One continuous stretch at the computer: active spans joined across idle and untracked stretches
/// shorter than the break threshold. Display-only grouping (the Blocks day view); no metric depends on it.
public struct WorkBlock: Sendable, Hashable {
    /// Active ms per key (category or project id; nil = Uncategorized / no project), largest first.
    public struct Share: Sendable, Hashable {
        public var key: Int64?
        public var ms: Int64
        public init(key: Int64?, ms: Int64) { self.key = key; self.ms = ms }
    }

    /// An app or site inside the block: the URL host when there is one, else the app name.
    public struct Context: Sendable, Hashable {
        public var name: String
        public var isHost: Bool
        public var ms: Int64
        public init(name: String, isHost: Bool, ms: Int64) { self.name = name; self.isHost = isHost; self.ms = ms }
    }

    /// First active start / last active end.
    public var startMs: Int64
    public var endMs: Int64
    public var activeMs: Int64
    /// Idle time inside the block (short idle stretches that didn't break it).
    public var idleInsideMs: Int64
    public var byCategory: [Share]
    public var byProject: [Share]
    /// Category / project holding the most active ms (ties: first seen). nil = Uncategorized / no project.
    public var dominantCategoryId: Int64?
    public var dominantProjectId: Int64?
    /// Top 3 apps/sites by active ms.
    public var topContexts: [Context]
    /// Any span in the block carries an edit (or is a manual entry).
    public var hasEdits: Bool

    public var wallMs: Int64 { endMs - startMs }
    public func contains(_ ms: Int64) -> Bool { startMs <= ms && ms < endMs }
}

/// A gap between two blocks that reached the threshold. `away` when idle spans cover at least half
/// of it (the tracker saw no input), else `notTracking` (no spans: asleep, quit, paused, or excluded apps).
public struct BlockBreak: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case away, notTracking }
    public var startMs: Int64
    public var endMs: Int64
    public var kind: Kind
    public var durationMs: Int64 { endMs - startMs }
    public init(startMs: Int64, endMs: Int64, kind: Kind) { self.startMs = startMs; self.endMs = endMs; self.kind = kind }
}

public enum MetricsBlocks {
    /// Setting key; minutes. Display-only: changing it regroups, never writes edits.
    public static let thresholdKey = "break_threshold_min"
    public static let defaultThresholdMin = 10
    public static let presetsMin = [5, 10, 15, 30]

    public struct Day: Sendable, Hashable {
        public var blocks: [WorkBlock]
        /// Between consecutive blocks only (leading/trailing inactivity isn't a break).
        public var breaks: [BlockBreak]
    }

    public static func compute(spans: [ClassifiedSpan], categories: [Category], breakThresholdMs: Int64) -> [WorkBlock] {
        day(spans: spans, categories: categories, breakThresholdMs: breakThresholdMs).blocks
    }

    /// Walks the day's effective spans in start order. Active spans join the current block; a
    /// stretch without active time (no span, idle, or an `exclude` category) joins it when shorter
    /// than the threshold and ends it otherwise (exactly equal = break).
    public static func day(spans: [ClassifiedSpan], categories: [Category], breakThresholdMs: Int64) -> Day {
        var cats: [Int64: Category] = [:]
        for c in categories { cats[c.id] = c }
        let sorted = spans.sorted { $0.span.startMs < $1.span.startMs }
        let excluded = { (c: ClassifiedSpan) in c.categoryId.flatMap { cats[$0] }?.behavior == .exclude }
        let active = sorted.filter { $0.span.kind == .active && $0.span.endMs > $0.span.startMs && !excluded($0) }
        let idle = sorted.filter { $0.span.kind == .idle && !excluded($0) }.map { $0.span.startMs..<$0.span.endMs }

        func idleMs(_ lo: Int64, _ hi: Int64) -> Int64 {
            idle.reduce(0) { $0 + max(0, min($1.upperBound, hi) - max($1.lowerBound, lo)) }
        }

        var blocks: [WorkBlock] = [], breaks: [BlockBreak] = []
        var members: [ClassifiedSpan] = []
        var start: Int64 = 0, end: Int64 = 0, idleInside: Int64 = 0

        func close() {
            guard !members.isEmpty else { return }
            blocks.append(build(members, start: start, end: end, idleInside: idleInside, all: sorted))
            members = []
        }

        for c in active {
            let s = c.span
            if members.isEmpty {
                start = s.startMs; end = s.endMs; idleInside = 0
            } else if s.startMs - end >= breakThresholdMs {
                let idle = idleMs(end, s.startMs)
                breaks.append(BlockBreak(startMs: end, endMs: s.startMs, kind: idle * 2 >= s.startMs - end ? .away : .notTracking))
                close()
                start = s.startMs; end = s.endMs; idleInside = 0
            } else {
                if s.startMs > end { idleInside += idleMs(end, s.startMs) }
                end = max(end, s.endMs)
            }
            members.append(c)
        }
        close()
        return Day(blocks: blocks, breaks: breaks)
    }

    private static func build(_ members: [ClassifiedSpan], start: Int64, end: Int64, idleInside: Int64,
                              all: [ClassifiedSpan]) -> WorkBlock {
        var cat = Tally<Int64?>(), proj = Tally<Int64?>(), ctx = Tally<String>()
        var isHost: [String: Bool] = [:]
        var active: Int64 = 0
        for c in members {
            let s = c.span, d = s.durationMs
            active += d
            cat.add(c.categoryId, d)
            proj.add(c.projectId, d)
            let host = metricsHost(s.url)
            let name = host ?? (s.source == .manual ? (s.label ?? "Manual entry") : s.appName)
            ctx.add(name, d)
            isHost[name] = host != nil
        }
        let edited = all.contains {
            $0.span.startMs < end && $0.span.endMs > start && (!$0.span.editSeqs.isEmpty || $0.span.source == .manual)
        }
        let cats = cat.sorted.map { WorkBlock.Share(key: $0.key, ms: $0.ms) }
        let projs = proj.sorted.map { WorkBlock.Share(key: $0.key, ms: $0.ms) }
        return WorkBlock(startMs: start, endMs: end, activeMs: active, idleInsideMs: idleInside,
                         byCategory: cats, byProject: projs,
                         dominantCategoryId: cats.first?.key ?? nil, dominantProjectId: projs.first?.key ?? nil,
                         topContexts: ctx.sorted.prefix(3).map { .init(name: $0.key, isHost: isHost[$0.key] ?? false, ms: $0.ms) },
                         hasEdits: edited)
    }

    /// Insertion-ordered sums, sorted largest first with ties kept in first-seen order.
    private struct Tally<K: Hashable> {
        var order: [K] = []
        var ms: [K: Int64] = [:]
        mutating func add(_ k: K, _ d: Int64) {
            if ms[k] == nil { order.append(k) }
            ms[k, default: 0] += d
        }
        var sorted: [(key: K, ms: Int64)] {
            order.enumerated().map { (i: $0.offset, key: $0.element, ms: ms[$0.element]!) }
                .sorted { $0.ms != $1.ms ? $0.ms > $1.ms : $0.i < $1.i }
                .map { (key: $0.key, ms: $0.ms) }
        }
    }
}
