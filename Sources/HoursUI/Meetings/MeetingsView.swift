import AppKit
import SwiftUI
import HoursCore
import ScryCore
import ScryPipeline

extension EnvironmentValues {
    /// Scry's notes folder, for views that link to meetings (Blocks). nil = no link.
    @Entry var scryRoot: URL? = nil
    /// Switches to Meetings with that note selected.
    @Entry var openMeeting: ((URL) -> Void)? = nil
}

/// Scry's meeting notes: open action items across meetings and the notes by day (left), the selected
/// note (right), and Ask Scry along the bottom. Reads the Markdown files under `root`; action-item
/// toggles and speaker renames write them back.
struct MeetingsView: View {
    let root: URL
    @Binding var selection: URL?
    let timeZone: TimeZone
    @State private var notes: [MeetingsNote]?
    @State private var question = ""
    @State private var asking = false
    @State private var answer: (text: String, sources: [URL])?
    @State private var askError: String?
    @State private var transcriptOpen = false
    @State private var renaming: String?
    /// Captures whose processing failed (kept on disk): retried at Scry's launch up to 3×, or by hand here.
    @State private var failed: [ScryCaptures.Failed] = []
    @State private var retrying: Set<URL> = []
    @State private var newName = ""
    @Environment(\.openSettings) private var openSettings

    /// `notes`: preloaded (render tests); otherwise loaded from `root` on appear.
    init(root: URL, selection: Binding<URL?>, notes: [MeetingsNote]? = nil, timeZone: TimeZone = .current) {
        self.root = root; self._selection = selection; self.timeZone = timeZone
        _notes = State(initialValue: notes)
    }

    static let listWidth: CGFloat = 340

    var body: some View {
        Group {
            if let notes {
                if notes.isEmpty && failed.isEmpty { empty } else { content(notes) }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        .task(id: root) { await reload() }
    }

    private var empty: some View {
        EmptyState(symbol: "person.2.wave.2", title: "No meeting notes yet",
                   detail: "Scry records your calls and writes a note for each: summary, decisions, action items and the transcript. Switch it on in Settings → Spells. Notes are read from \((root.path as NSString).abbreviatingWithTildeInPath).",
                   action: .init("Open Settings") { openSettings() })
            .hoursCard()
            .padding(Theme.Space.gutter)
    }

    private func content(_ notes: [MeetingsNote]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                list(notes).frame(width: Self.listWidth)
                Rectangle().fill(Theme.hairline).frame(width: Theme.Stroke.hairline)
                if let n = notes.first(where: { $0.url == selection }) ?? notes.first { detail(n) } else { Spacer() }
            }
            Rectangle().fill(Theme.hairline).frame(height: Theme.Stroke.hairline)
            askBar(notes)
        }
    }

    // MARK: List

    private func list(_ notes: [MeetingsNote]) -> some View {
        let open = notes.flatMap { n in n.actions.filter { !$0.done }.map { (id: "\(n.url.path)#\($0.line)", note: n, item: $0) } }
        let current = selection ?? notes.first?.url
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if !failed.isEmpty { failedCard }
                if !open.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Open action items").textRole(.heading)
                            Spacer()
                            Text("\(open.count)").textRole(.label, Theme.inkTertiary)
                        }
                        ForEach(open, id: \.id) { o in actionRow(o.note, o.item, meeting: true) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hoursCard()
                }
                ForEach(MeetingsData.byDay(notes, timeZone: timeZone), id: \.day) { g in
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(g.day.shellTitle).textRole(.micro)
                        VStack(spacing: 0) {
                            ForEach(g.notes) { n in row(n, selected: n.url == current) }
                        }
                        .hoursCard(padding: Theme.Space.xs)
                    }
                }
            }
            .padding(Theme.Space.gutter)
        }
    }

    private func row(_ n: MeetingsNote, selected: Bool) -> some View {
        Button { selection = n.url } label: {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(n.note.summary.title).textRole(.bodyEmph).lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    if n.openCount > 0 { Text("\(n.openCount) open").textRole(.label, Theme.inkSecondary) }
                }
                Text(meta(n)).textRole(.label, Theme.inkTertiary).lineLimit(1)
                if !n.note.meta.participants.isEmpty {
                    Text(n.note.meta.participants.joined(separator: ", ")).textRole(.label, Theme.inkSecondary).lineLimit(1)
                }
            }
            .padding(Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.surfaceRaised : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// "09:30 · Zoom · 35m".
    private func meta(_ n: MeetingsNote) -> String {
        [Fmt.clock(ms: n.startMs, timeZone: timeZone), n.note.meta.app ?? "In person", Fmt.duration(ms: n.endMs - n.startMs)]
            .joined(separator: " · ")
    }

    private func actionRow(_ n: MeetingsNote, _ item: ScryActions.Item, meeting: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Toggle(isOn: Binding(get: { item.done }, set: { _ in toggle(n, item) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .accessibilityLabel("\(item.owner): \(item.task)")
            VStack(alignment: .leading, spacing: 1) {
                (Text(item.owner).fontWeight(.semibold) + Text(": \(item.task)"))
                    .textRole(.body, item.done ? Theme.inkTertiary : Theme.ink)
                    .strikethrough(item.done)
                    .fixedSize(horizontal: false, vertical: true)
                if meeting {
                    Button { selection = n.url } label: {
                        Text(n.note.summary.title).textRole(.label, Theme.inkTertiary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Detail

    private func detail(_ n: MeetingsNote) -> some View {
        let s = n.note.summary
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.title).textRole(.title)
                        Spacer(minLength: Theme.Space.s)
                        Button("Open in editor") { NSWorkspace.shared.open(n.url) }.buttonStyle(HoursButtonStyle())
                    }
                    FlowLayout(spacing: Theme.Space.s) {
                        chip("calendar", "\(LocalDate.containing(ms: n.startMs, in: timeZone).shellTitle) · \(Fmt.clock(ms: n.startMs, timeZone: timeZone))–\(Fmt.clock(ms: n.endMs, timeZone: timeZone))")
                        chip("clock", Fmt.duration(ms: n.endMs - n.startMs))
                        chip(n.note.meta.app == nil ? "person.2" : "video", n.note.meta.app ?? "In person")
                        ForEach(n.note.meta.participants, id: \.self) { chip("person", $0) }
                    }
                    if !n.speakers.isEmpty { speakers(n) }
                }
                if !s.recap.isEmpty {
                    card("Summary") {
                        ForEach(s.recap.indices, id: \.self) { i in
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                Text(s.recap[i].title).textRole(.bodyEmph)
                                bullets(s.recap[i].points)
                            }
                        }
                    }
                }
                if !s.decisions.isEmpty { card("Decisions") { bullets(s.decisions) } }
                if !s.keyDates.isEmpty { card("Key dates") { bullets(s.keyDates) } }
                if !n.actions.isEmpty {
                    card("Action items") { ForEach(n.actions, id: \.line) { actionRow(n, $0, meeting: false) } }
                }
                if !s.openQuestions.isEmpty { card("Open questions") { bullets(s.openQuestions) } }
                if !s.insights.isEmpty { card("Insights") { bullets(s.insights) } }
                if !n.note.userNotes.isEmpty {
                    card("Your notes") { Text(n.note.userNotes).textRole(.body).textSelection(.enabled) }
                }
                if !s.followUpEmail.isEmpty {
                    card("Follow-up email") {
                        Text(s.followUpEmail).textRole(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(s.followUpEmail, forType: .string)
                        }
                        .buttonStyle(HoursButtonStyle())
                    }
                }
                if !n.note.segments.isEmpty { transcript(n) }
            }
            .padding(Theme.Space.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(n.url)
        .alert("Rename speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let from = renaming { rename(n, from: from, to: newName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces “\(renaming ?? "")” throughout this note.")
        }
    }

    private func speakers(_ n: MeetingsNote) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("Speakers").textRole(.micro)
            ForEach(n.speakers, id: \.self) { sp in
                Menu {
                    Button("Rename…") { newName = sp; renaming = sp }
                } label: {
                    Text(sp).textRole(.label)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func transcript(_ n: MeetingsNote) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button { transcriptOpen.toggle() } label: {
                HStack {
                    Text("Transcript").textRole(.heading)
                    Spacer()
                    Text("\(n.note.segments.count) segments").textRole(.label, Theme.inkTertiary)
                    Image(systemName: transcriptOpen ? "chevron.up" : "chevron.down").foregroundStyle(Theme.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if transcriptOpen {
                LazyVStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                    ForEach(n.note.segments.indices, id: \.self) { i in
                        let seg = n.note.segments[i]
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Text(String(format: "%02d:%02d", Int(seg.start) / 60, Int(seg.start) % 60))
                                .textRole(.mono, Theme.inkTertiary)
                            (Text(seg.speaker).fontWeight(.semibold) + Text("  \(seg.text)"))
                                .textRole(.body).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoursCard()
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).textRole(.heading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoursCard()
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(items.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text("•").textRole(.body, Theme.inkTertiary)
                    Text(items[i]).textRole(.body).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: Theme.Space.xs + 2) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            Text(text).textRole(.label).lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.s + 2)
        .frame(height: 24)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }

    // MARK: Ask

    private func askBar(_ notes: [MeetingsNote]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let answer {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(alignment: .top) {
                        ScrollView {
                            Text(answer.text).textRole(.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                        DayIconButton(symbol: "xmark", help: "Close the answer") { self.answer = nil }
                    }
                    ForEach(answer.sources, id: \.self) { url in
                        Button { selection = url } label: {
                            HStack(spacing: Theme.Space.xs + 2) {
                                Image(systemName: "doc.text").foregroundStyle(Theme.inkTertiary)
                                Text(notes.first { $0.url == url }?.note.summary.title ?? url.deletingPathExtension().lastPathComponent)
                                    .textRole(.label, Theme.inkSecondary).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .hoursCard(padding: Theme.Space.m)
            }
            if let askError { Text(askError).textRole(.label, Theme.StateLayer.distraction).lineLimit(2) }
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Theme.inkTertiary)
                TextField("Ask across your meetings…", text: $question)
                    .textFieldStyle(.plain)
                    .textRole(.body)
                    .onSubmit(ask)
                if asking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Ask", action: ask)
                        .buttonStyle(HoursButtonStyle())
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                        .settingsDimsWhenDisabled()
                }
            }
            .padding(.leading, Theme.Space.m)
            .padding(.trailing, Theme.Space.xs)
            .padding(.vertical, Theme.Space.xs)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.m)
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        asking = true
        askError = nil
        let root = root
        Task {
            do {
                let r = try await ScryAsk.answer(q, root: root)
                answer = (r.answer, r.sources)
            } catch {
                askError = "Couldn't answer: \(error)"
            }
            asking = false
        }
    }

    /// Recordings the pipeline couldn't finish (offline, no key, an API error): date, size, the error, and
    /// Retry / Delete. The audio stays on disk until one of them succeeds.
    private var failedCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Failed captures").textRole(.heading)
                Spacer()
                Text("\(failed.count)").textRole(.label, Theme.inkTertiary)
            }
            ForEach(failed) { f in
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    HStack(spacing: Theme.Space.s) {
                        Text(f.date.formatted(date: .abbreviated, time: .shortened)).textRole(.body)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(f.bytes), countStyle: .file)).textRole(.label, Theme.inkTertiary)
                        Spacer()
                        if retrying.contains(f.dir) { ProgressView().controlSize(.small) } else {
                            Button("Retry") { retry(f.dir) }.buttonStyle(HoursButtonStyle())
                            Button("Delete") { delete(f.dir) }.buttonStyle(HoursButtonStyle())
                        }
                    }
                    if !f.error.isEmpty { Text(f.error).textRole(.label, Theme.inkTertiary).lineLimit(2) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoursCard()
    }

    private func retry(_ dir: URL) {
        retrying.insert(dir)
        Task {
            let rows = await Task.detached { ScryPipeline.settingRows() }.value
            do {
                _ = try await ScryPipeline.process(captureDir: dir, settings: ScrySettings.load(rows),
                                                   keyterms: ScryPipeline.keyterms(rows))
            } catch {
                SupportLog.app.error("scry retry failed: \(String(describing: error), privacy: .private)")
            }
            retrying.remove(dir)
            await reload()
        }
    }

    private func delete(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        failed.removeAll { $0.dir == dir }
    }

    // MARK: File I/O (off the main actor)

    private func reload() async {
        let root = root
        notes = await Task.detached(priority: .userInitiated) { MeetingsData.load(root) }.value
        failed = await Task.detached(priority: .userInitiated) { ScryCaptures.failed() }.value
    }

    private func toggle(_ n: MeetingsNote, _ item: ScryActions.Item) {
        let url = n.url
        update(url) { try MeetingsData.toggle(url, line: item.line, owner: item.owner, task: item.task) }
    }

    private func rename(_ n: MeetingsNote, from: String, to: String) {
        let url = n.url
        update(url) { try MeetingsData.rename(url, from: from, to: to) }
    }

    private func update(_ url: URL, _ body: @escaping @Sendable () throws -> MeetingsNote?) {
        Task {
            do {
                guard let fresh = try await Task.detached(priority: .userInitiated, operation: body).value,
                      let i = notes?.firstIndex(where: { $0.url == url }) else { return }
                notes?[i] = fresh
            } catch {
                SupportLog.app.error("scry note not saved: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
