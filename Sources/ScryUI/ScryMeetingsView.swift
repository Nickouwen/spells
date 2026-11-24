import AppKit
import Observation
import SwiftUI
import SpellsKit
import SpellsUI
import ScryCore
import ScryPipeline

/// The Meetings window's state: the notes folder (re-read from settings on each show) and the selected note.
@MainActor @Observable public final class ScryMeetingsModel {
    public var root: URL
    public var selection: URL?
    public init(root: URL, selection: URL? = nil) { self.root = root; self.selection = selection }
}

/// Scry's meeting notes: open action items across meetings and the notes by day (left), the selected
/// note (right), and Ask Scry along the bottom. Reads the Markdown files under `root`; action-item
/// toggles and speaker renames write them back. (Lived in Spells' window until the module split, 2026-10.)
public struct MeetingsView: View {
    @Bindable var model: ScryMeetingsModel
    /// Opens Scry's settings (the empty state's button); nil hides it.
    var openSettings: (() -> Void)?
    private var root: URL { model.root }
    private var selection: URL? {
        get { model.selection }
        nonmutating set { model.selection = newValue }
    }
    let timeZone: TimeZone
    @State private var notes: [ScryNoteFile]?
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
    /// The note a right-click asked to delete, until the alert answers.
    @State private var deleting: ScryNoteFile?
    @State private var newTask = ""
    @State private var transcriptQuery = ""
    /// The transcript line being edited (its place in the note), with the words and speaker so far; `askDelete`: about to go.
    @State private var editing: (note: ScryNoteFile, index: Int)?
    @State private var lineText = ""
    @State private var lineSpeaker = ""
    @State private var askDelete = false
    /// The last deleted line, until it's undone or another edit.
    @State private var deleted: (url: URL, before: String, after: String)?
    /// The folder the list shows; nil = all notes.
    @State private var folder: String?
    /// The note a new folder was asked for, and its name so far.
    @State private var foldering: ScryNoteFile?
    @State private var newFolder = ""
    /// People you know, from the people folders in settings; nil until read.
    @State private var known: [ScryPerson]?
    @State private var peopleFolders: [URL] = []
    /// Who is being linked (the picker's sheet), and a person mentioned being added by hand.
    @State private var linking: (note: ScryNoteFile, person: ScryNotePerson)?
    /// "Summarize Again": the note and the language, until confirmed. `working`: notes being redone.
    @State private var redoing: (note: ScryNoteFile, language: String?)?
    @State private var working: Set<URL> = []
    @State private var workError: String?
    /// The open-action backlog shows its first few until asked; it grows with every meeting.
    @State private var showAllOpen = false

    /// `notes`: preloaded (previews); otherwise loaded from the folder on appear.
    public init(model: ScryMeetingsModel, notes: [ScryNoteFile]? = nil, timeZone: TimeZone = .current, openSettings: (() -> Void)? = nil) {
        self.model = model; self.timeZone = timeZone; self.openSettings = openSettings
        _notes = State(initialValue: notes)
    }

    static let listWidth: CGFloat = 340

    public var body: some View {
        Group {
            if let notes {
                if notes.isEmpty && failed.isEmpty { empty } else { content(notes) }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        .tint(Theme.ink)
        .task(id: root) { await reload() }
        .alert("Delete this note?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { n in
            Button("Move to Trash", role: .destructive) { deleteNote(n) }
            Button("Cancel", role: .cancel) {}
        } message: { n in
            Text("“\(n.note.summary.title)” goes to the Trash.")
        }
    }

    private var empty: some View {
        EmptyState(symbol: "person.2.wave.2", title: "No meeting notes yet",
                   detail: "Scry offers to record when a call starts and writes a note for each: summary, decisions, action items and the transcript. Notes are read from \((root.path as NSString).abbreviatingWithTildeInPath).",
                   action: openSettings.map { open in .init("Open Settings") { open() } })
            .card()
            .padding(Theme.Space.gutter)
    }

    private func content(_ notes: [ScryNoteFile]) -> some View {
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

    private func list(_ notes: [ScryNoteFile]) -> some View {
        let folders = Set(notes.compactMap(\.note.meta.folder)).sorted()
        let shown = folder.map { f in notes.filter { $0.note.meta.folder == f } } ?? notes
        let open = shown.flatMap { n in n.actions.filter { !$0.done }.map { (id: "\(n.url.path)#\($0.line)", note: n, item: $0) } }
        let current = selection ?? notes.first?.url
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if !failed.isEmpty { failedCard }
                if !folders.isEmpty {
                    Picker("Folder", selection: $folder) {
                        Text("All notes").tag(String?.none)
                        ForEach(folders, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    // The last note left it: show all rather than an empty list.
                    .onChange(of: folders) { if let f = folder, !folders.contains(f) { folder = nil } }
                }
                if !open.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Open action items").textRole(.heading)
                            Spacer()
                            Text("\(open.count)").textRole(.label, Theme.inkTertiary)
                        }
                        ForEach(showAllOpen ? open : Array(open.prefix(3)), id: \.id) { o in actionRow(o.note, o.item, meeting: true) }
                        if open.count > 3 {
                            Button(showAllOpen ? "Show fewer" : "Show all \(open.count)") { showAllOpen.toggle() }
                                .buttonStyle(QuietButtonStyle())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }
                ForEach(Self.byDay(shown, timeZone: timeZone), id: \.day) { g in
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(Self.dayTitle(g.day, timeZone: timeZone)).textRole(.micro)
                        VStack(spacing: 0) {
                            ForEach(g.notes) { n in row(n, selected: n.url == current) }
                        }
                        .card(padding: Theme.Space.xs)
                    }
                }
            }
            .padding(Theme.Space.gutter)
        }
    }

    private func row(_ n: ScryNoteFile, selected: Bool) -> some View {
        Button { selection = n.url } label: {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(n.note.summary.title).textRole(.bodyEmph).lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    if n.openCount > 0 { Text("\(n.openCount) open").textRole(.label, Theme.inkSecondary) }
                }
                Text(n.note.meta.folder.map { meta(n) + " · " + $0 } ?? meta(n)).textRole(.label, Theme.inkTertiary).lineLimit(1)
                if !n.note.meta.participants.isEmpty {
                    Text(n.note.meta.participants.joined(separator: ", ")).textRole(.label, Theme.inkSecondary).lineLimit(1)
                }
            }
            .padding(Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.surfaceRaised : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            // Selection = fill + an ink bar on the leading edge (a full outline doubled up with the day card's border).
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1, style: .continuous).fill(Theme.ink)
                    .frame(width: 2).padding(.vertical, Theme.Space.s).opacity(selected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Open in Editor") { NSWorkspace.shared.open(n.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
            Menu("Folder") { folderItems(n) }
            Divider()
            Button("Delete Note…", role: .destructive) { deleting = n }
        }
    }

    /// "09:30 · Zoom · 35m".
    private func meta(_ n: ScryNoteFile) -> String {
        [Fmt.clock(ms: n.startMs, timeZone: timeZone), n.note.meta.app ?? "In person", Fmt.duration(ms: n.endMs - n.startMs)]
            .joined(separator: " · ")
    }

    private func actionRow(_ n: ScryNoteFile, _ item: ScryActions.Item, meeting: Bool) -> some View {
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
            if !meeting {
                Spacer(minLength: Theme.Space.s)
                IconButton(symbol: "xmark", help: "Remove this action item") { removeAction(n, item) }
            }
        }
    }

    /// The note's action items with a remove button each, and a field to add one (owner "You").
    private func actionsCard(_ n: ScryNoteFile) -> some View {
        card("Action items") {
            ForEach(n.actions, id: \.line) { actionRow(n, $0, meeting: false) }
            HStack(spacing: Theme.Space.s) {
                TextField("Add an action item", text: $newTask)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addAction(n) }
                Button("Add") { addAction(n) }
                    .buttonStyle(RewindButtonStyle())
                    .disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, n.actions.isEmpty ? 0 : Theme.Space.xs)
        }
    }

    // MARK: Detail

    private func detail(_ n: ScryNoteFile) -> some View {
        let s = n.note.summary
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.title).textRole(.title)
                        Spacer(minLength: Theme.Space.s)
                        if working.contains(n.url) { ProgressView().controlSize(.small) }
                        Menu("More") {
                            Menu("Share") {
                                ShareLink("Notes", item: ScryNotes.shared(n.markdown, transcript: false))
                                ShareLink("Notes and Transcript", item: ScryNotes.shared(n.markdown, transcript: true))
                            }
                            Menu("Folder") { folderItems(n) }
                            Menu("Summarize Again") {
                                Button("In the Call's Language") { redoing = (n, nil) }
                                Divider()
                                ForEach(["English", "French", "Spanish", "Portuguese", "German"], id: \.self) { l in Button("In \(l)") { redoing = (n, l) } }
                            }
                            Menu("Separate Voices") {
                                ForEach(2..<7) { k in Button("\(k) other people") { separate(n, voices: k) } }
                            }
                        }
                        .menuStyle(.button).fixedSize().disabled(working.contains(n.url))
                        Button("Open in Editor") { NSWorkspace.shared.open(n.url) }.buttonStyle(RewindButtonStyle())
                    }
                    if let workError { Text(workError).textRole(.label, Theme.StateLayer.distraction).fixedSize(horizontal: false, vertical: true) }
                    FlowLayout(spacing: Theme.Space.s) {
                        chip("calendar", "\(Self.dayTitle(Date(timeIntervalSince1970: Double(n.startMs) / 1000), timeZone: timeZone)) · \(Fmt.clock(ms: n.startMs, timeZone: timeZone))–\(Fmt.clock(ms: n.endMs, timeZone: timeZone))")
                        chip("clock", Fmt.duration(ms: n.endMs - n.startMs))
                        chip(n.note.meta.app == nil ? "person.2" : "video", n.note.meta.app ?? "In person")
                        // People once: the Speakers row below names them when the transcript has them.
                        if n.speakers.isEmpty { ForEach(n.note.meta.participants, id: \.self) { chip("person", $0) } }
                    }
                    if !n.speakers.isEmpty { speakers(n) }
                }
                // The summary is the note's lede, not one card among eight.
                if !s.overview.isEmpty {
                    Text(s.overview).textRole(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Theme.Space.readable, alignment: .leading)
                } else if !s.recap.isEmpty {
                    card("Summary") {
                        ForEach(s.recap.indices, id: \.self) { i in
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                Text(s.recap[i].title).textRole(.bodyEmph)
                                bullets(s.recap[i].points)
                            }
                        }
                    }
                }
                actionsCard(n)
                // The short lists share one card, each under an eyebrow, instead of a card apiece.
                let lists = [("Decisions", s.decisions), ("Key dates", s.keyDates), ("Open questions", s.openQuestions),
                             ("Insights", s.insights)].filter { !$0.1.isEmpty }
                if !lists.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        Text("Highlights").textRole(.heading)
                        ForEach(lists, id: \.0) { title, items in
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                Text(title).textRole(.label, Theme.inkSecondary)   // in-card section label, not an eyebrow
                                bullets(items)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }
                peopleCard(n)
                if !n.note.userNotes.isEmpty {
                    card("Your notes") { Text(n.note.userNotes).textRole(.body).textSelection(.enabled) }
                }
                if !s.followUpEmail.isEmpty {
                    card("Follow-up email") {
                        Text(s.followUpEmail).textRole(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button("Copy") { copy(s.followUpEmail) }
                        .buttonStyle(RewindButtonStyle())
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
        .sheet(isPresented: Binding(get: { linking != nil }, set: { if !$0 { linking = nil } })) {
            if let l = linking {
                ScryPersonPicker(person: l.person, known: known ?? [], canCreate: !peopleFolders.isEmpty) { choice in
                    linking = nil
                    switch choice {
                    case .known(let name, let p): link(l.note, l.person, as: name, to: p)
                    case .new(let name): create(l.note, l.person, as: name)
                    case .unlinked(let name): mention(l.note, l.person, as: name)
                    case .cancel: break
                    }
                }
            }
        }
        .alert("New folder", isPresented: Binding(get: { foldering != nil }, set: { if !$0 { foldering = nil } })) {
            TextField("Name", text: $newFolder)
            Button("Move") { if let f = foldering { move(f, to: newFolder) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Summarize this note again?", isPresented: Binding(get: { redoing != nil }, set: { if !$0 { redoing = nil } })) {
            Button("Summarize") { if let r = redoing { resummarize(r.note, language: r.language) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It replaces the title, summary, lists and action items, ticks included. The transcript and your notes stay.") }
    }

    // MARK: People

    /// Who spoke and who was mentioned, each linked to the person you know, or with a way to say who it is.
    private func peopleCard(_ n: ScryNoteFile) -> some View {
        let people = ScryPeople.people(in: n.note)
        return card("People") {
            if people.isEmpty { Text("Nobody yet.").textRole(.label, Theme.inkTertiary) }
            ForEach(people) { p in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).textRole(.bodyEmph)
                        Text([p.role == .speaker ? "Spoke" : p.at.map { "Mentioned at \($0)" } ?? "Mentioned", p.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                            .textRole(.label, Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.s)
                    if let l = p.link {
                        let who = known.flatMap { ScryPeople.person(for: l, in: $0) }
                        Button { if let who { NSWorkspace.shared.open(who.url) } } label: {
                            Label(who?.name ?? (known == nil ? "Linked" : "Linked note not found"), systemImage: "link")
                        }
                        .buttonStyle(QuietButtonStyle()).disabled(who == nil).help(who.map { $0.detail.isEmpty ? "Open the note" : $0.detail } ?? "")
                    }
                    Menu(p.link == nil ? "Link" : "Change") {
                        let likely = ScryPeople.suggestions(p.name, in: known ?? []).prefix(5)
                        if !likely.isEmpty { Section("Is this") { ForEach(likely) { k in Button(k.detail.isEmpty ? k.name : "\(k.name), \(k.detail)") { link(n, p, as: p.name, to: k) } } } }
                        Button("Choose or Create…") { linking = (n, p) }
                        if p.link != nil { Divider(); Button("Remove Link") { link(n, p, as: p.name, to: nil) } }
                    }
                    .menuStyle(.button).fixedSize()
                }
            }
            HStack {
                Button("Add Someone Mentioned…") { linking = (n, ScryNotePerson(name: "", role: .mentioned)) }.buttonStyle(QuietButtonStyle())
                Spacer()
                if known?.isEmpty == true {
                    Text(peopleFolders.isEmpty ? "Set your people folder in Scry's settings to link people." : "No person notes in your people folder yet.")
                        .textRole(.label, Theme.inkTertiary)
                }
            }
        }
    }

    private func link(_ n: ScryNoteFile, _ p: ScryNotePerson, as name: String, to who: ScryPerson?) {
        let url = n.url, p = ScryNotePerson(name: name, role: p.role, at: p.at, detail: p.detail, link: p.link)
        update(url) { try ScryNotes.linkPerson(url, p, to: who) }
    }

    private func mention(_ n: ScryNoteFile, _ p: ScryNotePerson, as name: String) {
        let url = n.url, p = ScryNotePerson(name: name, role: p.role, at: p.at, detail: p.detail, link: p.link)
        update(url) { try ScryNotes.linkPerson(url, p, to: nil) }
    }

    private func create(_ n: ScryNoteFile, _ p: ScryNotePerson, as name: String) {
        guard let folder = peopleFolders.first else { return }
        let url = n.url, date = ISO8601DateFormatter.string(from: Date(), timeZone: timeZone, formatOptions: [.withFullDate])
        Task {
            do {
                let who = try await Task.detached { try ScryPeople.create(name, email: nil, detail: p.detail, from: url, in: folder, date: date) }.value
                known = ((known ?? []) + [who]).sorted { $0.name < $1.name }
                link(n, p, as: p.name.isEmpty ? name : p.name, to: who)
            } catch {
                SupportLog.scry.error("person note not made: \(String(describing: error), privacy: .private)")
                workError = (error as? CocoaError)?.code == .fileWriteFileExists ? "A note named “\(name)” is already there. Choose it instead." : "Couldn't make the note: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder private func folderItems(_ n: ScryNoteFile) -> some View {
        ForEach(Set((notes ?? []).compactMap(\.note.meta.folder)).sorted(), id: \.self) { f in
            Button(f == n.note.meta.folder ? "✓ \(f)" : f) { move(n, to: f) }
        }
        Button("New Folder…") { newFolder = ""; foldering = n }
        if n.note.meta.folder != nil { Divider(); Button("Remove from Folder") { move(n, to: nil) } }
    }

    private func move(_ n: ScryNoteFile, to name: String?) {
        let url = n.url
        update(url) { try ScryNotes.setFolder(url, name) }
    }

    private func resummarize(_ n: ScryNoteFile, language: String?) {
        work(n) { settings, terms in
            _ = try await ScryPipeline.resummarize(note: n.url, settings: settings, keyterms: terms, language: language)
            return n.url
        }
    }

    /// The recording is transcribed again for that many people; the result is a second note, selected when it's done.
    private func separate(_ n: ScryNoteFile, voices: Int) {
        work(n) { settings, terms in try await ScryPipeline.separate(note: n.note, voices: voices, settings: settings, keyterms: terms).noteURL }
    }

    private func work(_ n: ScryNoteFile, _ body: @escaping @Sendable (ScrySettings, [String]) async throws -> URL) {
        working.insert(n.url)
        workError = nil
        Task {
            let rows = await Task.detached { ScryPipeline.settingRows() }.value
            do {
                let url = try await body(ScrySettings.load(rows), ScryPipeline.keyterms(rows))
                await reload()
                selection = url
            } catch {
                SupportLog.scry.error("scry note not redone: \(String(describing: error), privacy: .private)")
                workError = "That didn't work: \(error)"
            }
            working.remove(n.url)
        }
    }

    private func speakers(_ n: ScryNoteFile) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("Speakers").textRole(.label, Theme.inkSecondary)
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

    private func transcript(_ n: ScryNoteFile) -> some View {
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
                HStack(spacing: Theme.Space.s) {
                    TextField("Search the transcript", text: $transcriptQuery).textFieldStyle(.roundedBorder)
                    Button("Copy") { copy(n.note.segments.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")) }.buttonStyle(RewindButtonStyle())
                    Button("Copy Note as Markdown") { copy(n.markdown) }.buttonStyle(RewindButtonStyle())
                }
                let hits = n.note.segments.indices.filter { i in
                    transcriptQuery.count < 2 || n.note.segments[i].text.localizedCaseInsensitiveContains(transcriptQuery)
                        || n.note.segments[i].speaker.localizedCaseInsensitiveContains(transcriptQuery)
                }
                if let d = deleted, d.url == n.url {
                    HStack(spacing: Theme.Space.s) {
                        Text("Line deleted.").textRole(.label, Theme.inkSecondary)
                        Button("Undo") { deleted = nil; update(d.url) { try ScryNotes.undo(d.url, before: d.before, after: d.after) } }.buttonStyle(QuietButtonStyle())
                    }
                }
                if hits.isEmpty { Text("Nothing said matches “\(transcriptQuery)”.").textRole(.label, Theme.inkTertiary) }
                LazyVStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                    ForEach(hits, id: \.self) { i in
                        let seg = n.note.segments[i]
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Text(String(format: "%02d:%02d", Int(seg.start) / 60, Int(seg.start) % 60))
                                .textRole(.mono, Theme.inkTertiary)
                            (Text(seg.speaker).fontWeight(.semibold) + Text("  \(seg.text)"))
                                .textRole(.body).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Menu {
                                Button("Edit…") { lineText = seg.text; lineSpeaker = seg.speaker; askDelete = false; editing = (n, i) }
                                let names = Set(n.speakers + n.note.meta.participants).subtracting([seg.speaker]).sorted()
                                if !names.isEmpty {
                                    Menu("This line was said by") {
                                        ForEach(names, id: \.self) { name in Button(name) { edit(n, i, speaker: name, text: seg.text) } }
                                    }
                                }
                                Button("Rename “\(seg.speaker)” Everywhere…") { newName = seg.speaker; renaming = seg.speaker }
                                Button("Link Someone Mentioned Here…") {
                                    linking = (n, ScryNotePerson(name: "", role: .mentioned, at: String(format: "%02d:%02d", Int(seg.start) / 60, Int(seg.start) % 60)))
                                }
                                Divider()
                                Button("Delete Line…", role: .destructive) { askDelete = true; editing = (n, i) }
                            } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Line actions")
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .alert("Edit this line", isPresented: Binding(get: { editing != nil && !askDelete }, set: { if !$0 { editing = nil } })) {
            TextField("Speaker", text: $lineSpeaker)
            TextField("Text", text: $lineText)
            Button("Save") { if let e = editing { edit(e.note, e.index, speaker: lineSpeaker, text: lineText) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete this line?", isPresented: Binding(get: { editing != nil && askDelete }, set: { if !$0 { editing = nil } })) {
            Button("Delete", role: .destructive) { if let e = editing { edit(e.note, e.index, speaker: "", text: nil) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You can undo it until your next edit.") }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func edit(_ n: ScryNoteFile, _ i: Int, speaker: String, text: String?) {
        let url = n.url, old = n.note.segments[i], before = n.markdown
        deleted = nil
        // Undo writes `before` back, so only when this delete is all that changed in the file.
        let after = text == nil ? ScryNotes.editedLine(before, index: i, old: old, speaker: "", text: nil) : nil
        update(url, then: { fresh in if let after, fresh.markdown == after { deleted = (url, before, after) } }) {
            try ScryNotes.editLine(url, index: i, old: old, speaker: speaker, text: text)
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).textRole(.heading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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

    private func askBar(_ notes: [ScryNoteFile]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let answer {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(alignment: .top) {
                        ScrollView {
                            Text(answer.text).textRole(.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                        IconButton(symbol: "xmark", help: "Close the answer") { self.answer = nil }
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
                .card(padding: Theme.Space.m)
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
                        .buttonStyle(RewindButtonStyle())
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
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
                            Button("Retry") { retry(f.dir) }.buttonStyle(RewindButtonStyle())
                            Button("Delete") { delete(f.dir) }.buttonStyle(RewindButtonStyle())
                        }
                    }
                    if !f.error.isEmpty { Text(f.error).textRole(.label, Theme.inkTertiary).lineLimit(2) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func retry(_ dir: URL) {
        retrying.insert(dir)
        Task {
            let rows = await Task.detached { ScryPipeline.settingRows() }.value
            do {
                _ = try await ScryPipeline.process(captureDir: dir, settings: ScrySettings.load(rows),
                                                   keyterms: ScryPipeline.keyterms(rows))
            } catch {
                SupportLog.scry.error("scry retry failed: \(String(describing: error), privacy: .private)")
            }
            retrying.remove(dir)
            await reload()
        }
    }

    private func delete(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        failed.removeAll { $0.dir == dir }
    }

    // MARK: Days

    /// Newest day first, notes in their (newest-first) order; calendar days in `timeZone`.
    static func byDay(_ notes: [ScryNoteFile], timeZone: TimeZone) -> [(day: Date, notes: [ScryNoteFile])] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        var out: [(day: Date, notes: [ScryNoteFile])] = []
        for n in notes {
            let d = cal.startOfDay(for: Date(timeIntervalSince1970: Double(n.startMs) / 1000))
            if out.last?.day == d { out[out.count - 1].notes.append(n) } else { out.append((d, [n])) }
        }
        return out
    }

    /// "Today", "Yesterday", else "Mon 6 Oct" (with the year when it isn't this one).
    static func dayTitle(_ day: Date, timeZone: TimeZone, now: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let d = cal.startOfDay(for: day), today = cal.startOfDay(for: now)
        if d == today { return "Today" }
        if d == cal.date(byAdding: .day, value: -1, to: today) { return "Yesterday" }
        var f = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        if cal.component(.year, from: d) != cal.component(.year, from: today) { f = f.year() }
        f.timeZone = timeZone
        return d.formatted(f)
    }

    // MARK: File I/O (off the main actor)

    private func reload() async {
        let root = root
        notes = await Task.detached(priority: .userInitiated) { ScryNotes.load(root) }.value
        failed = await Task.detached(priority: .userInitiated) { ScryCaptures.failed() }.value
        let (folders, people) = await Task.detached(priority: .userInitiated) {
            let f = ScrySettings.load(ScryPipeline.settingRows()).people.compactMap(ScrySettings.folder)
            return (f, ScryPeople.load(f))
        }.value
        peopleFolders = folders; known = people
    }

    private func toggle(_ n: ScryNoteFile, _ item: ScryActions.Item) {
        let url = n.url
        update(url) { try ScryNotes.toggle(url, line: item.line, owner: item.owner, task: item.task) }
    }

    private func addAction(_ n: ScryNoteFile) {
        let url = n.url, task = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        newTask = ""
        update(url) { try ScryNotes.addAction(url, owner: "You", task: task) }
    }

    private func removeAction(_ n: ScryNoteFile, _ item: ScryActions.Item) {
        let url = n.url
        update(url) { try ScryNotes.removeAction(url, line: item.line, owner: item.owner, task: item.task) }
    }

    /// To the Trash; the list and selection drop it straight away.
    private func deleteNote(_ n: ScryNoteFile) {
        let url = n.url
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try ScryNotes.delete(url) }.value
                notes?.removeAll { $0.url == url }
                if selection == url { selection = nil }
            } catch {
                SupportLog.scry.error("scry note not deleted: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func rename(_ n: ScryNoteFile, from: String, to: String) {
        let url = n.url
        update(url) { try ScryNotes.rename(url, from: from, to: to) }
    }

    private func update(_ url: URL, then: @escaping (ScryNoteFile) -> Void = { _ in }, _ body: @escaping @Sendable () throws -> ScryNoteFile?) {
        Task {
            do {
                guard let fresh = try await Task.detached(priority: .userInitiated, operation: body).value,
                      let i = notes?.firstIndex(where: { $0.url == url }) else { return }
                notes?[i] = fresh
                then(fresh)
            } catch {
                SupportLog.scry.error("scry note not saved: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
