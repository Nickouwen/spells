import AppKit
import SwiftUI
import RewindCore

/// EOD standup for one day (W20): editable text, Copy (plain text), Regenerate, Save. "Covers" makes one
/// combined standup since an earlier day; Revise regenerates with a typed correction, which sticks.
/// Regenerate runs `StandupGenerator` in-process on a global queue (it blocks up to ~2 min on
/// `claude -p`), so the main actor only flips the progress state.
struct StandupSheet: View {
    let db: RewindDB
    let date: LocalDate
    var timeZone: TimeZone = .current

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stored: Standup?
    @State private var text = ""
    @State private var loaded = false
    @State private var generating = false
    @State private var error: String?
    @State private var copied = false
    @State private var confirmReplace = false
    /// First day covered; `date` = just this day.
    @State private var from: LocalDate
    @State private var fix = ""
    /// Bumped only by a successful generate; keys the editor so new text fades in (saving never re-keys it).
    @State private var generation = 0

    init(db: RewindDB, date: LocalDate, timeZone: TimeZone = .current) {
        self.db = db; self.date = date; self.timeZone = timeZone
        _from = State(initialValue: date)
    }

    /// Render/preview entry point: state preloaded, no DB read on appear.
    init(db: RewindDB, date: LocalDate, preloaded: Standup?, timeZone: TimeZone = .current) {
        self.init(db: db, date: date, timeZone: timeZone)
        _stored = State(initialValue: preloaded)
        _text = State(initialValue: preloaded?.body ?? "")
        _loaded = State(initialValue: true)
        _from = State(initialValue: preloaded?.fromDate ?? date)
    }

    private var dirty: Bool { stored.map { $0.body != text } ?? !text.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if stored != nil { revision }
            if let error {
                Text(error).textRole(.label, Theme.StateLayer.distraction)
                    .lineLimit(3).textSelection(.enabled)
            }
            footer
        }
        .padding(Theme.Space.xl)
        .frame(width: 640, height: 580)
        .background(Theme.canvas)
        .task { await load() }
        .confirmationDialog("Replace your edited standup?", isPresented: $confirmReplace) {
            Button("Regenerate", role: .destructive) { generate(.clear) }
        } message: {
            Text("Regenerating starts over: it replaces the text and drops your corrections. Revise keeps them.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("EOD standup").textRole(.micro)
                Text(title).textRole(.title)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
                Text(provenance).textRole(.label, Theme.inkSecondary)
                Picker("Covers", selection: $from) {
                    ForEach(0..<10, id: \.self) { n in
                        let d = shifted(-n)
                        Text(n == 0 ? "This day only" : "Since \(label(d))").tag(d)
                    }
                }
                .pickerStyle(.menu).fixedSize()
                .disabled(generating)
                .help("One combined standup since an earlier day; applies when you generate, regenerate or revise")
            }
        }
    }

    /// Correction box: Revise regenerates with it on top of the corrections already kept.
    private var revision: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.m) {
                TextField("Correction, e.g. \"drop the Spells item, mention the client demo\"", text: $fix)
                    .textFieldStyle(.roundedBorder)
                    .disabled(generating)
                    .onSubmit(revise)
                Button("Revise", action: revise)
                    .buttonStyle(RewindButtonStyle())
                    .settingsDimsWhenDisabled()
                    .disabled(fix.trimmingCharacters(in: .whitespaces).isEmpty || generating)
            }
            if let kept = stored?.corrections, !kept.isEmpty {
                Text("Kept on regenerate: " + kept.joined(separator: " · "))
                    .textRole(.label, Theme.inkSecondary).lineLimit(2).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !loaded {
            ProgressView().controlSize(.small)
        } else if stored == nil && !generating {
            EmptyState(symbol: "text.bubble", title: "No standup yet",
                       detail: "Generate one from this day's Claude Code sessions and tracked time.",
                       action: .init("Generate") { generate(.clear) })
                .hoursCard(padding: Theme.Space.l, radius: Theme.Radius.panel)
        } else {
            ZStack {
                TextEditor(text: $text)
                    .font(TextRole.body.font)
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .disabled(generating)
                    .opacity(generating ? 0.4 : 1)
                    .accessibilityLabel("Standup text")
                    // Keyed by generation: freshly generated text fades in over the old instead of popping.
                    .id(generation)
                    .transition(.opacity)
                if generating {
                    VStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Generating with Claude… up to 2 minutes").textRole(.label, Theme.inkSecondary)
                    }
                }
            }
            .hoursCard(padding: Theme.Space.m, radius: Theme.Radius.panel)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            if stored != nil {   // the empty state carries its own Generate
                Button("Regenerate") {
                    if stored?.editedMs != nil || dirty || !(stored?.corrections.isEmpty ?? true) { confirmReplace = true } else { generate(.clear) }
                }
                .buttonStyle(RewindButtonStyle())
                .settingsDimsWhenDisabled()
                .disabled(generating)
            }
            Spacer()
            Button { copy() } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(RewindButtonStyle())
            .animation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion), value: copied)
            .settingsDimsWhenDisabled()
            .disabled(text.isEmpty || generating)
            Button("Save") { save() }
                .buttonStyle(RewindButtonStyle())
                .settingsDimsWhenDisabled()
                .disabled(!dirty || text.isEmpty || generating)
                .keyboardShortcut("s", modifiers: .command)
            Button("Done") { dismiss() }
                .buttonStyle(RewindButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
    }

    private var title: String {
        let full = Date.FormatStyle(locale: Locale(identifier: "en_GB"), timeZone: timeZone).weekday(.wide).day().month(.wide)
        let day = noon(date).formatted(full)
        return from < date ? "\(label(from)) – \(day)" : day
    }

    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = timeZone; return c }

    private func noon(_ d: LocalDate) -> Date { calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12))! }

    private func shifted(_ days: Int) -> LocalDate {
        let c = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: days, to: noon(date))!)
        return LocalDate(year: c.year!, month: c.month!, day: c.day!)
    }

    /// "Mon 20 Oct"
    private func label(_ d: LocalDate) -> String {
        noon(d).formatted(Date.FormatStyle(locale: Locale(identifier: "en_GB"), timeZone: timeZone).weekday(.abbreviated).day().month(.abbreviated))
    }

    private var provenance: String {
        guard let s = stored else { return "" }
        if let e = s.editedMs { return "Edited \(Fmt.clock(ms: e, timeZone: timeZone))" }
        guard let g = s.generatedMs else { return "" }
        return "Generated \(Fmt.clock(ms: g, timeZone: timeZone))" + (s.model.map { " · \($0)" } ?? "")
    }

    // MARK: Actions

    private func load() async {
        guard !loaded else { return }
        let db = db, date = date
        let s = try? await Task.detached(priority: .userInitiated) { try StandupStore(db).get(date) }.value
        stored = s
        text = s?.body ?? ""
        from = s?.fromDate ?? date
        loaded = true
    }

    private func revise() {
        let f = fix.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !generating else { return }
        // Revise works on the text on screen: an unsaved edit is saved first so Claude revises it.
        if dirty, !text.isEmpty {
            try? StandupStore(db).saveEdit(date, body: text, editedMs: Int64(Date().timeIntervalSince1970 * 1000))
        }
        generate(.add(f))
    }

    private func generate(_ corrections: StandupGenerator.Corrections) {
        generating = true
        error = nil
        let db = db, date = date, from = from
        Task {
            do {
                let outcome = try await withCheckedThrowingContinuation { (c: CheckedContinuation<StandupGenerator.Outcome, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        c.resume(with: Result { try StandupGenerator.run(db: db, date: date, from: from, regenerate: true, corrections: corrections) })
                    }
                }
                if case .generated(let s) = outcome {
                    withAnimation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion)) {
                        stored = s; text = s.body; generating = false; generation += 1
                        if case .add = corrections { fix = "" }
                    }
                }
            } catch {
                self.error = String(describing: error)
            }
            generating = false
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    private func save() {
        let db = db, date = date, body = text
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        Task {
            do {
                let s = try await Task.detached(priority: .userInitiated) {
                    try StandupStore(db).saveEdit(date, body: body, editedMs: now)
                    return try StandupStore(db).get(date)
                }.value
                stored = s
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}
