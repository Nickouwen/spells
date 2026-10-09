import Foundation

// Shared contract between all items. Changing a type here is an orchestrator decision —
// workers extend in their own files instead of editing this one.
// Times are Unix milliseconds UTC throughout. Ranges are half-open [lo, hi).

public enum Hours {
    public static let bundlePrefix = "dev.nic.spells"
    public static let appBundleID = "dev.nic.spells"
    public static let trackerBundleID = "dev.nic.spells.hours"
    /// Incant, the dictation spell: a login item of Spells.app, registered only while switched on.
    public static let incantBundleID = "dev.nic.spells.incant"
    /// Scry, the meeting-notes spell: a login item of Spells.app, registered only while switched on.
    public static let scryBundleID = "dev.nic.spells.scry"
    /// Darwin notification posted after every committed write (either process).
    public static let dbChangedNotification = "dev.nic.spells.db.changed"
    /// Local hour at which a "day" starts. Late-night work belongs to the day it started (PLAN Q2).
    public static let defaultDayStartHour = 4
}

// MARK: - Raw (tracker-observed, immutable once closed)

public enum SpanKind: String, Codable, Sendable, CaseIterable {
    case active, idle
}

public struct RawSpan: Codable, Sendable, Hashable {
    /// Chain sequence number. 0 = the live (open, unchained) span.
    public var seq: Int64
    public var startMs: Int64
    public var endMs: Int64
    public var tzId: String
    public var tzOffsetS: Int
    public var kind: SpanKind
    public var bundleId: String?
    public var appName: String
    public var title: String?
    public var url: String?

    public init(seq: Int64, startMs: Int64, endMs: Int64, tzId: String, tzOffsetS: Int,
                kind: SpanKind, bundleId: String?, appName: String, title: String?, url: String?) {
        self.seq = seq; self.startMs = startMs; self.endMs = endMs; self.tzId = tzId
        self.tzOffsetS = tzOffsetS; self.kind = kind; self.bundleId = bundleId
        self.appName = appName; self.title = title; self.url = url
    }
}

// MARK: - Edits (append-only, range-addressed)

public enum EditOp: String, Codable, Sendable {
    /// Erase [lo,hi) from the timeline (trim, split-delete, "not work").
    case delete
    /// Override category and/or project over [lo,hi).
    case assign
    /// Manual time over [lo,hi); replaces tracked time beneath it.
    case add
    /// Revert every edit in group `target` (undo of an undo = redo).
    case undo
    /// Attach a free-text reason to group `target`. Never required, never changes time.
    case note
}

public enum EditPayload: Codable, Sendable, Hashable {
    case delete
    case assign(categoryId: Int64?, projectId: Int64?)
    case add(label: String, categoryId: Int64?, projectId: Int64?)
    case undo
    case note(text: String)
}

public struct Edit: Codable, Sendable, Hashable {
    public var seq: Int64
    /// Group id = seq of the first edit emitted by one user gesture. One group = one undo step.
    public var grp: Int64
    public var createdMs: Int64
    public var tzId: String
    public var op: EditOp
    public var loMs: Int64
    public var hiMs: Int64
    /// For .undo and .note: the group being reverted/annotated. nil otherwise.
    public var target: Int64?
    public var payload: EditPayload

    public init(seq: Int64, grp: Int64, createdMs: Int64, tzId: String, op: EditOp,
                loMs: Int64, hiMs: Int64, target: Int64?, payload: EditPayload) {
        self.seq = seq; self.grp = grp; self.createdMs = createdMs; self.tzId = tzId; self.op = op
        self.loMs = loMs; self.hiMs = hiMs; self.target = target; self.payload = payload
    }
}

// MARK: - Effective (raw ⊕ edits)

public enum SpanSource: String, Codable, Sendable { case tracked, manual }

public struct EffectiveSpan: Codable, Sendable, Hashable {
    public var startMs: Int64
    public var endMs: Int64
    public var tzId: String
    public var kind: SpanKind
    public var bundleId: String?
    public var appName: String
    public var title: String?
    public var url: String?
    public var categoryOverride: Int64?
    public var projectOverride: Int64?
    public var source: SpanSource
    /// Originating raw span (nil for manual). 0 = live span.
    public var rawSeq: Int64?
    /// Manual entry label.
    public var label: String?
    /// Edit seqs that shaped this span (provenance for the "edited" marker + audit).
    public var editSeqs: [Int64]

    public var durationMs: Int64 { endMs - startMs }

    public init(startMs: Int64, endMs: Int64, tzId: String, kind: SpanKind, bundleId: String?,
                appName: String, title: String?, url: String?, categoryOverride: Int64? = nil,
                projectOverride: Int64? = nil, source: SpanSource = .tracked, rawSeq: Int64?,
                label: String? = nil, editSeqs: [Int64] = []) {
        self.startMs = startMs; self.endMs = endMs; self.tzId = tzId; self.kind = kind
        self.bundleId = bundleId; self.appName = appName; self.title = title; self.url = url
        self.categoryOverride = categoryOverride; self.projectOverride = projectOverride
        self.source = source; self.rawSeq = rawSeq; self.label = label; self.editSeqs = editSeqs
    }
}

// MARK: - Classification config (item 4 owns semantics)

public enum Productivity: String, Codable, Sendable, CaseIterable { case productive, neutral, distracting }
public enum CategoryBehavior: String, Codable, Sendable { case normal, meeting, exclude }

public struct Category: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var key: String          // immutable slug, e.g. "coding"
    public var name: String
    public var level: Productivity
    public var isWork: Bool
    public var behavior: CategoryBehavior
    /// Index into the design system's category palette (item 6). nil = grey.
    public var colorSlot: Int?
    public var sort: Int
    public var archived: Bool

    public init(id: Int64, key: String, name: String, level: Productivity, isWork: Bool,
                behavior: CategoryBehavior, colorSlot: Int?, sort: Int, archived: Bool = false) {
        self.id = id; self.key = key; self.name = name; self.level = level; self.isWork = isWork
        self.behavior = behavior; self.colorSlot = colorSlot; self.sort = sort; self.archived = archived
    }
}

public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var name: String
    public var client: String?
    public var archived: Bool

    public init(id: Int64, name: String, client: String? = nil, archived: Bool = false) {
        self.id = id; self.name = name; self.client = client; self.archived = archived
    }
}

/// Predicates are AND-ed; nil = wildcard. At least one predicate and one target.
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public enum Origin: String, Codable, Sendable { case seed, user }
    public var id: Int64
    public var origin: Origin
    public var seedKey: String?
    public var enabled: Bool
    public var priority: Int
    public var bundleId: String?
    public var appName: String?
    public var host: String?
    public var pathPrefix: String?
    public var titleRegex: String?
    public var categoryId: Int64?
    public var projectId: Int64?

    public init(id: Int64, origin: Origin, seedKey: String? = nil, enabled: Bool = true, priority: Int = 0,
                bundleId: String? = nil, appName: String? = nil, host: String? = nil,
                pathPrefix: String? = nil, titleRegex: String? = nil,
                categoryId: Int64? = nil, projectId: Int64? = nil) {
        self.id = id; self.origin = origin; self.seedKey = seedKey; self.enabled = enabled
        self.priority = priority; self.bundleId = bundleId; self.appName = appName; self.host = host
        self.pathPrefix = pathPrefix; self.titleRegex = titleRegex
        self.categoryId = categoryId; self.projectId = projectId
    }
}

/// An effective span with its resolved category/project. Input to metrics, views, export.
public struct ClassifiedSpan: Sendable, Hashable {
    public var span: EffectiveSpan
    /// nil = Uncategorized.
    public var categoryId: Int64?
    public var projectId: Int64?

    public init(span: EffectiveSpan, categoryId: Int64?, projectId: Int64?) {
        self.span = span; self.categoryId = categoryId; self.projectId = projectId
    }
}

// MARK: - Calendar day

/// A local calendar day. Its bounds are [date dayStartHour:00, next date dayStartHour:00) in a given tz.
public struct LocalDate: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public var year: Int, month: Int, day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
    public static func < (a: LocalDate, b: LocalDate) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
}
