import SwiftUI
import HoursCore

/// Right-hand inspector (I): selection times (editable `HH:mm`), category / project pickers
/// (type-to-filter, recents first, Return applies), the actions with their keys, what's underneath,
/// and raw-vs-effective when edited. No reason field — reasons come from the toast or history.
struct EditInspector: View {
    @Bindable var session: EditSession
    let data: DayData

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack {
                    Text(session.picker == .newEntry ? "New entry" : "Selection").textRole(.heading)
                    Spacer()
                    DayIconButton(symbol: "sidebar.right", help: "Hide inspector (I)") { session.inspectorVisible = false }
                }
                if session.picker == .newEntry, session.newEntry != nil {
                    EditNewEntryForm(session: session, data: data)
                } else if let hull = session.selection.hull {
                    selectionBody(hull)
                } else {
                    Text("Click a block or drag across the lane to select time. N adds a manual entry; ⌘A selects the day.")
                        .textRole(.body, Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface)
    }

    @ViewBuilder private func selectionBody(_ hull: Range<Int64>) -> some View {
        let ranges = session.selection.ranges
        let tracked = EditPlanner.trackedMs(ranges, data)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(ranges.count == 1 ? "\(clock(hull.lowerBound))–\(clock(hull.upperBound))" : "\(ranges.count) ranges")
                    .textRole(.metric)
                Spacer()
            }
            Text("\(Fmt.duration(ms: tracked)) tracked of \(Fmt.duration(ms: ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound }))")
                .textRole(.label, Theme.inkSecondary)
            if ranges.count == 1 {
                HStack(spacing: Theme.Space.s) {
                    EditTimeField(title: "Start", ms: hull.lowerBound, tz: data.timeZone) { session.setEdge(.lower, text: $0) }
                    EditTimeField(title: "End", ms: hull.upperBound, tz: data.timeZone) { session.setEdge(.upper, text: $0) }
                }
                .padding(.top, Theme.Space.xs)
            }
        }
        divider
        EditPickerRow(session: session, data: data, kind: .category, current: currentCategory(ranges))
        EditPickerRow(session: session, data: data, kind: .project, current: currentProject(ranges))
        divider
        actions
        let under = underneath(ranges)
        if !under.isEmpty {
            divider
            VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                Text("Underneath").textRole(.micro)
                ForEach(under, id: \.name) { row in
                    HStack(spacing: Theme.Space.s) {
                        Text(row.name).textRole(.body).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Theme.Space.s)
                        Text(Fmt.duration(ms: row.ms)).textRole(.label, Theme.inkSecondary)
                    }
                }
            }
        }
        if ranges.contains(where: { r in EditPlanner.spans(in: r, data).contains { !$0.span.editSeqs.isEmpty } }) {
            divider
            let original = ranges.reduce(0) { $0 + session.originalMs($1) }
            HStack(spacing: Theme.Space.s) {
                DayEditedGlyph().frame(width: 8, height: 8)
                Text(original == tracked ? "Edited · time unchanged (\(Fmt.duration(ms: tracked)) tracked)"
                                         : "Original \(Fmt.duration(ms: original)) tracked · now \(Fmt.duration(ms: tracked))")
                    .textRole(.label, Theme.inkSecondary)
                Spacer()
                Button("History") { session.historyVisible = true }
                    .buttonStyle(.plain).font(TextRole.label.font).foregroundStyle(Theme.ink)
            }
        }
    }

    private var actions: some View {
        let one = session.selection.ranges.count == 1
        let pointerInside = session.pointerMs.map { p in session.selection.ranges.contains { $0.contains(p) } } ?? false
        return VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            EditActionRow(symbol: "person.crop.circle", title: "Mark personal", key: "X") { session.perform(.markPersonal) }
            EditActionRow(symbol: "trash", title: "Delete", key: "⌫") { session.perform(.delete) }
            EditActionRow(symbol: "scissors", title: "Split at pointer", key: "S", disabled: !pointerInside) { session.split() }
            EditActionRow(symbol: "arrow.right.to.line.compact", title: "Merge selected", key: "M",
                          disabled: EditPlanner.plan(.merge, selection: session.selection.ranges, in: data) == nil) {
                session.perform(.merge)
            }
            EditActionRow(symbol: "plus.square.dashed", title: "Add entry over selection", key: "N", disabled: !one) {
                session.beginNewEntry()
            }
        }
    }

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(height: Theme.Stroke.hairline) }

    private func clock(_ ms: Int64) -> String { Fmt.clock(ms: ms, timeZone: data.timeZone) }

    /// Category shared by all active time in the selection; "Mixed" otherwise.
    private func currentCategory(_ ranges: [Range<Int64>]) -> String {
        let active = ranges.flatMap { EditPlanner.spans(in: $0, data) }.filter { $0.span.kind == .active }
        let ids = Set(active.map(\.categoryId))
        if ids.count > 1 { return "Mixed" }
        // W24: one shared source → "Coding · Jev 92 %".
        let sources = Set(active.map { data.sourceLabel($0) })
        let suffix = sources.count == 1 ? sources.first!.map { " · \($0)" } ?? "" : ""
        return ids.first.map { data.categoryName($0) + suffix } ?? "—"
    }

    private func currentProject(_ ranges: [Range<Int64>]) -> String {
        let ids = Set(ranges.flatMap { EditPlanner.spans(in: $0, data) }.filter { $0.span.kind == .active }.map(\.projectId))
        if ids.count > 1 { return "Mixed" }
        return ids.first.flatMap { data.projectName($0) } ?? "None"
    }

    /// Apps / sites / manual labels under the selection, by time (top 6).
    private func underneath(_ ranges: [Range<Int64>]) -> [(name: String, ms: Int64)] {
        var ms: [String: Int64] = [:]
        for r in ranges {
            for c in EditPlanner.spans(in: r, data) {
                let s = c.span
                let name = s.kind == .idle ? "Idle" : s.source == .manual ? "✎ \(s.label ?? "Manual entry")"
                    : DayRows.host(s.url).map { "\(s.appName) · \($0)" } ?? s.appName
                ms[name, default: 0] += min(s.endMs, r.upperBound) - max(s.startMs, r.lowerBound)
            }
        }
        return ms.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }
    }
}

/// Category / project row; expands inline into a filterable list (so it also renders in snapshots).
struct EditPickerRow: View {
    enum Kind { case category, project }
    @Bindable var session: EditSession
    let data: DayData
    let kind: Kind
    let current: String
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    private var picker: EditSession.Picker { kind == .category ? .category : .project }
    private var open: Bool { session.picker == picker }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Button {
                session.picker = open ? nil : picker
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Text(kind == .category ? "Category" : "Project").textRole(.label, Theme.inkSecondary)
                        .frame(width: 64, alignment: .leading)
                    if kind == .category, let slot = slotFor(current) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.Palette.swatch(slot: slot)).frame(width: 9, height: 9)
                    }
                    Text(current).textRole(.bodyEmph).lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    EditKeyCap(kind == .category ? "C" : "P")
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                .padding(.vertical, Theme.Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { list }
        }
    }

    private var list: some View {
        let items = options
        return VStack(alignment: .leading, spacing: 0) {
            TextField(kind == .category ? "Filter categories" : "Filter projects", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .onSubmit { if let first = items.first { apply(first.id) } }
                .padding(.bottom, Theme.Space.xs)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                Button { apply(item.id) } label: {
                    HStack(spacing: Theme.Space.s) {
                        if kind == .category {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.Palette.swatch(slot: item.slot)).frame(width: 9, height: 9)
                        }
                        Text(item.name).textRole(.body).lineLimit(1)
                        Spacer()
                        if item.recent { Text("Recent").textRole(.label, Theme.inkTertiary) }
                        if i == 0 { Image(systemName: "return").font(.system(size: 10)).foregroundStyle(Theme.inkTertiary) }
                    }
                    .padding(.horizontal, Theme.Space.s).padding(.vertical, 5)
                    .background(i == 0 ? Theme.surfaceRaised : Theme.surface,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { filter = ""; filterFocused = true }
    }

    private struct Option: Identifiable { var id: Int64; var name: String; var slot: Int?; var recent: Bool }

    private var options: [Option] {
        let recents = kind == .category ? session.recentCategories : session.recentProjects
        let all: [Option] = kind == .category
            ? data.categories.filter { !$0.archived && $0.key != "uncategorized" }.sorted { $0.sort < $1.sort }
                .map { Option(id: $0.id, name: $0.name, slot: $0.colorSlot, recent: recents.contains($0.id)) }
            : data.projects.filter { !$0.archived }
                .map { Option(id: $0.id, name: $0.name, slot: nil, recent: recents.contains($0.id)) }
        let ordered = recents.compactMap { r in all.first { $0.id == r } } + all.filter { !recents.contains($0.id) }
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? ordered : ordered.filter { $0.name.localizedCaseInsensitiveContains(f) }
    }

    private func apply(_ id: Int64) {
        session.picker = nil
        switch kind {
        case .category: session.perform(.recategorize(id))
        case .project: session.perform(.assignProject(id))
        }
    }

    private func slotFor(_ name: String) -> Int? { data.categories.first { $0.name == name }?.colorSlot }
}

/// Manual entry: label (focused), times, category, project; Return adds.
struct EditNewEntryForm: View {
    @Bindable var session: EditSession
    let data: DayData
    @FocusState private var labelFocused: Bool

    var body: some View {
        if let entry = session.newEntry {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                TextField("What were you doing?", text: Binding(get: { session.newEntry?.label ?? "" },
                                                               set: { session.newEntry?.label = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .focused($labelFocused)
                    .onSubmit { session.commitNewEntry() }
                HStack(spacing: Theme.Space.s) {
                    EditTimeField(title: "Start", ms: entry.range.lowerBound, tz: data.timeZone) { setEdge(lower: true, $0) }
                    EditTimeField(title: "End", ms: entry.range.upperBound, tz: data.timeZone) { setEdge(lower: false, $0) }
                }
                Text(Fmt.duration(ms: entry.range.upperBound - entry.range.lowerBound)).textRole(.metric)
                Picker("Category", selection: Binding(get: { session.newEntry?.categoryId }, set: { session.newEntry?.categoryId = $0 })) {
                    Text("Uncategorized").tag(Int64?.none)
                    ForEach(data.categories.filter { !$0.archived && $0.key != "uncategorized" }) { c in
                        Text(c.name).tag(Int64?.some(c.id))
                    }
                }
                Picker("Project", selection: Binding(get: { session.newEntry?.projectId }, set: { session.newEntry?.projectId = $0 })) {
                    Text("None").tag(Int64?.none)
                    ForEach(data.projects.filter { !$0.archived }) { p in Text(p.name).tag(Int64?.some(p.id)) }
                }
                let replaced = EditPlanner.trackedMs([entry.range], data)
                if replaced > 0 {
                    Text("Replaces \(Fmt.duration(ms: replaced)) of tracked time (undoable).")
                        .textRole(.label, Theme.inkSecondary)
                }
                HStack {
                    Button("Cancel") { session.newEntry = nil; session.picker = nil }
                    Spacer()
                    Button("Add entry") { session.commitNewEntry() }
                        .buttonStyle(HoursButtonStyle())
                }
            }
            .onAppear { labelFocused = true }
        }
    }

    private func setEdge(lower: Bool, _ text: String) -> Bool {
        guard let e = session.newEntry, let t = EditTime.parse(text, bounds: data.bounds, timeZone: data.timeZone) else { return false }
        let r = lower ? t..<e.range.upperBound : e.range.lowerBound..<t
        guard let c = EditPlanner.clamp(r, data) else { return false }
        session.newEntry?.range = c
        session.selection.set([c])
        return true
    }
}

/// `HH:mm` field: commits on Return / focus loss, reverts on bad input.
struct EditTimeField: View {
    let title: String
    let ms: Int64
    let tz: TimeZone
    let commit: (String) -> Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).textRole(.micro)
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(TextRole.body.font)
                .labelsHidden()
                .focused($focused)
                .onSubmit { submit() }
                .onChange(of: focused) { if !focused { submit() } }
        }
        .onAppear { text = Fmt.clock(ms: ms, timeZone: tz) }
        .onChange(of: ms) { text = Fmt.clock(ms: ms, timeZone: tz) }
    }

    private func submit() {
        let current = Fmt.clock(ms: ms, timeZone: tz)
        guard text != current else { return }
        if !commit(text) { text = current }
    }
}

struct EditActionRow: View {
    let symbol: String
    let title: String
    let key: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 18)
                    .foregroundStyle(disabled ? Theme.inkDisabled : Theme.inkSecondary)
                Text(title).textRole(.body, disabled ? Theme.inkDisabled : Theme.ink)
                Spacer()
                EditKeyCap(key)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// Small key hint ("C", "⌫").
struct EditKeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold).monospaced())
            .foregroundStyle(Theme.inkSecondary)
            .frame(minWidth: 18, minHeight: 16)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
