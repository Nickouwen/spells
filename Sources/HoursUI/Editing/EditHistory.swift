import SwiftUI
import HoursCore

/// One edit group in the history list.
public struct EditHistoryRow: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable { case active, reverted, noEffect }
    public var id: Int64 { group }
    public var group: Int64
    public var createdMs: Int64
    public var tzId: String
    public var summary: String
    public var range: Range<Int64>
    /// Net effect on effective (tracked + manual) time; nil when reverted.
    public var deltaMs: Int64?
    public var reasons: [String]
    public var status: Status
    /// For undo groups: the group they revert.
    public var target: Int64?
}

/// Pure: edit rows → history rows (newest first). Status and Δ come from replaying the derivation
/// with and without the group, so they're exact (no stored `affected_seconds` needed).
public enum EditHistory {
    /// `raw(r)` returns the raw spans overlapping `r` (each group is replayed over its own hull only).
    public static func rows(edits: [Edit], raw: (Range<Int64>) -> [RawSpan], categories: [HoursCore.Category],
                            projects: [Project], timeZone: TimeZone, limit: Int = .max) -> [EditHistoryRow] {
        let byGroup = Dictionary(grouping: edits.filter { $0.op != .note }, by: \.grp)
        var notes: [Int64: [String]] = [:]
        for e in edits.sorted(by: { $0.seq < $1.seq }) {
            if case let .note(text) = e.payload, let t = e.target { notes[t, default: []].append(text) }
        }
        let dead = deadGroups(edits)
        let nextSeq = (edits.map(\.seq).max() ?? 0) + 1

        return byGroup.keys.sorted(by: >).prefix(limit).compactMap { g in
            guard let rows = byGroup[g]?.sorted(by: { $0.seq < $1.seq }), let first = rows.first else { return nil }
            let range = rows.map(\.loMs).min()!..<rows.map(\.hiMs).max()!
            var status: EditHistoryRow.Status = dead.contains(g) ? .reverted : .active
            var delta: Int64?
            if status == .active {
                // Only raw + edits overlapping the hull can change time inside it.
                let r = raw(range)
                let local = edits.filter { $0.loMs < range.upperBound && $0.hiMs > range.lowerBound }
                let undo = Edit(seq: nextSeq, grp: nextSeq, createdMs: 0, tzId: "UTC", op: .undo,
                                loMs: range.lowerBound, hiMs: range.upperBound, target: g, payload: .undo)
                let with = clip(effectiveSpans(raw: r, edits: local), range)
                let without = clip(effectiveSpans(raw: r, edits: local + [undo]), range)
                delta = with.reduce(0) { $0 + $1.durationMs } - without.reduce(0) { $0 + $1.durationMs }
                if with == without { status = .noEffect }
            }
            return EditHistoryRow(group: g, createdMs: first.createdMs, tzId: first.tzId,
                                  summary: summary(rows, byGroup: byGroup, categories: categories, projects: projects, tz: timeZone),
                                  range: range, deltaMs: delta, reasons: notes[g] ?? [], status: status, target: first.target)
        }
    }

    /// Clipped to `r`, provenance dropped — "did this group change anything visible?"
    private static func clip(_ spans: [EffectiveSpan], _ r: Range<Int64>) -> [EffectiveSpan] {
        spans.compactMap { s in
            var c = s
            c.startMs = max(s.startMs, r.lowerBound); c.endMs = min(s.endMs, r.upperBound); c.editSeqs = []
            return c.endMs > c.startMs ? c : nil
        }
    }

    /// Chain verify for the history header, off the main actor (a full walk is ~1.35 s at 365k rows).
    /// nil when the verifier throws. `verifier` is a test seam.
    public static func verify(_ db: HoursDB,
                              verifier: @escaping @Sendable (HoursDB) throws -> VerifyResult = { try ChainVerifier.verify($0) })
        async -> VerifyResult? {
        await Task.detached(priority: .utility) { try? verifier(db) }.value
    }

    /// Groups reverted by a live undo (same rule as the derivation: descending seq, undo-of-undo = redo).
    static func deadGroups(_ edits: [Edit]) -> Set<Int64> {
        var dead = Set<Int64>()
        for e in edits.sorted(by: { $0.seq > $1.seq }) where !dead.contains(e.grp) {
            if e.op == .undo, let t = e.target { dead.insert(t) }
        }
        return dead
    }

    static func summary(_ rows: [Edit], byGroup: [Int64: [Edit]], categories: [HoursCore.Category], projects: [Project],
                        tz: TimeZone) -> String {
        let first = rows[0]
        let span = { (e: Edit) in "\(Fmt.clock(ms: e.loMs, timeZone: tz))–\(Fmt.clock(ms: e.hiMs, timeZone: tz))" }
        let more = rows.count > 1 ? " (\(rows.count) ranges)" : ""
        let cat = { (id: Int64) in categories.first { $0.id == id }?.name ?? "category \(id)" }
        let proj = { (id: Int64) in projects.first { $0.id == id }?.name ?? "project \(id)" }
        if Set(rows.map(\.op)).count > 1 { return "Merged \(span(first))" }
        switch first.payload {
        case .delete: return "Deleted \(span(first))\(more)"
        case let .assign(c?, p?): return "Assigned \(span(first)) → \(cat(c)) · \(proj(p))\(more)"
        case let .assign(c?, nil): return "Recategorized \(span(first)) → \(cat(c))\(more)"
        case let .assign(nil, p?): return "Project \(proj(p)) on \(span(first))\(more)"
        case .assign: return "Assigned \(span(first))\(more)"
        case let .add(label, _, _): return "Added “\(label)” \(span(first))"
        case .undo:
            let t = first.target ?? 0
            let inner = byGroup[t]?.sorted(by: { $0.seq < $1.seq })
            let what = inner.map { summary($0, byGroup: byGroup, categories: categories, projects: projects, tz: tz) } ?? "#\(t)"
            return inner?.first?.op == .undo ? "Redo: \(what.replacingOccurrences(of: "Undo: ", with: ""))" : "Undo: \(what)"
        case .note: return "Note"
        }
    }
}

/// Edit history (⇧⌘H): newest first, grouped by day; Revert / Unrevert, jump to range, add reason;
/// chain verify status in the header.
struct EditHistoryView: View {
    enum Scope: String, CaseIterable { case day = "This day", all = "All" }

    let session: EditSession
    var onJump: ((Range<Int64>) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope = .day
    @State private var rows: [EditHistoryRow] = []
    @State private var verify: VerifyResult?
    /// Bumped by `reload()`; re-runs the (detached) chain verify.
    @State private var verifyRun = 0
    @State private var noting: Int64?
    @State private var noteText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if rows.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "No edits",
                           detail: scope == .day ? "Nothing on this day has been changed." : "Nothing has been changed yet.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { list.padding(Theme.Space.l) }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .background(Theme.surface)
        .task(id: scope) { reload() }
        .task(id: verifyRun) { if verifyRun > 0 { verify = await EditHistory.verify(session.db) } }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            Text("Edit history").textRole(.title)
            Picker("", selection: $scope) { ForEach(Scope.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            Spacer()
            if let verify {
                Label(verify.ok ? "Chain verified · \(verify.rows) rows" : "Chain broken at #\(verify.firstBadSeq ?? 0)",
                      systemImage: verify.ok ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(TextRole.label.font)
                    .foregroundStyle(verify.ok ? Theme.inkSecondary : Theme.StateLayer.distraction)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(Theme.Space.l)
    }

    private var list: some View {
        let tz = session.data?.timeZone ?? .current
        let days = Dictionary(grouping: rows) { LocalDate.containing(ms: $0.range.lowerBound, in: tz) }
        return LazyVStack(alignment: .leading, spacing: Theme.Space.l) {
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(day.description).textRole(.micro)
                    ForEach(days[day] ?? []) { row in rowView(row, tz: tz) }
                }
            }
        }
    }

    private func rowView(_ row: EditHistoryRow, tz: TimeZone) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.m) {
                Text(Fmt.clock(ms: row.createdMs, timeZone: tz)).font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
                    .frame(width: 40, alignment: .leading)
                Text(row.summary).textRole(.body).lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                Text(delta(row)).font(TextRole.label.font).foregroundStyle(Theme.inkSecondary)
                Text(status(row)).font(TextRole.label.font)
                    .foregroundStyle(row.status == .active ? Theme.ink : Theme.inkTertiary)
                    .frame(width: 96, alignment: .trailing)
                Menu {
                    if row.status == .reverted {
                        Button("Unrevert") { unrevert(row) }
                    } else {
                        Button("Revert") { session.revert(group: row.group); reload() }
                    }
                    if let onJump { Button("Jump to range") { onJump(row.range); dismiss() } }
                    Button("Add reason…") { noting = row.group; noteText = "" }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            ForEach(row.reasons, id: \.self) { r in
                Text("“\(r)”").font(TextRole.label.font).foregroundStyle(Theme.inkSecondary).padding(.leading, 52)
            }
            if noting == row.group {
                TextField("Reason", text: $noteText)
                    .textFieldStyle(.roundedBorder).padding(.leading, 52)
                    .onSubmit { session.note(group: row.group, text: noteText); noting = nil; reload() }
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private func delta(_ row: EditHistoryRow) -> String {
        guard let d = row.deltaMs, d != 0 else { return row.deltaMs == nil ? "—" : "±0m" }
        return (d > 0 ? "+" : "") + Fmt.duration(ms: d)
    }

    private func status(_ row: EditHistoryRow) -> String {
        switch row.status {
        case .active: "Active"
        case .reverted: "Reverted"
        case .noEffect: "No visible effect"
        }
    }

    /// Unrevert = revert the live undo group that killed it.
    private func unrevert(_ row: EditHistoryRow) {
        guard let edits = try? Store(session.db).allEdits() else { return }
        let dead = EditHistory.deadGroups(edits)
        if let u = edits.filter({ $0.op == .undo && $0.target == row.group && !dead.contains($0.grp) }).map(\.grp).max() {
            session.revert(group: u, name: "Unrevert")
        }
        reload()
    }

    private func reload() {
        rows = session.historyRows(allDays: scope == .all)
        verifyRun += 1
    }
}

extension EditSession {
    /// History rows for the current day (edits overlapping it) or everything (newest 200 groups).
    public func historyRows(allDays: Bool) -> [EditHistoryRow] {
        guard let data else { return [] }
        let store = Store(db)
        let edits = (allDays ? try? store.allEdits()
                             : try? store.edits(overlapping: data.bounds.lowerBound, data.bounds.upperBound)) ?? []
        let rows = EditHistory.rows(edits: edits, raw: { (try? store.rawSpans(from: $0.lowerBound, to: $0.upperBound)) ?? [] },
                                    categories: data.categories, projects: data.projects, timeZone: data.timeZone,
                                    limit: 200)   // ponytail: newest 200 groups; page it if history ever gets long
        return rows
    }
}
