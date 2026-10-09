import AppKit
import SwiftUI
import HoursCore

/// EOD standup for one day (W20): editable text, Copy (plain text), Regenerate, Save.
/// Regenerate runs `StandupGenerator` in-process on a global queue (it blocks up to ~2 min on
/// `claude -p`), so the main actor only flips the progress state.
struct StandupSheet: View {
    let db: HoursDB
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
    /// Bumped only by a successful generate; keys the editor so new text fades in (saving never re-keys it).
    @State private var generation = 0

    init(db: HoursDB, date: LocalDate, timeZone: TimeZone = .current) {
        self.db = db; self.date = date; self.timeZone = timeZone
    }

    /// Render/preview entry point: state preloaded, no DB read on appear.
    init(db: HoursDB, date: LocalDate, preloaded: Standup?, timeZone: TimeZone = .current) {
        self.init(db: db, date: date, timeZone: timeZone)
        _stored = State(initialValue: preloaded)
        _text = State(initialValue: preloaded?.body ?? "")
        _loaded = State(initialValue: true)
    }

    private var dirty: Bool { stored.map { $0.body != text } ?? !text.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Button("Regenerate", role: .destructive) { generate() }
        } message: {
            Text("Regenerating overwrites the text you edited for this day.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("EOD standup").textRole(.micro)
                Text(title).textRole(.title)
            }
            Spacer()
            Text(provenance).textRole(.label, Theme.inkSecondary)
        }
    }

    @ViewBuilder private var content: some View {
        if !loaded {
            ProgressView().controlSize(.small)
        } else if stored == nil && !generating {
            EmptyState(symbol: "text.bubble", title: "No standup yet",
                       detail: "Generate one from this day's Claude Code sessions and tracked time.",
                       action: .init("Generate") { generate() })
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
                    if stored?.editedMs != nil || dirty { confirmReplace = true } else { generate() }
                }
                .buttonStyle(HoursButtonStyle())
                .settingsDimsWhenDisabled()
                .disabled(generating)
            }
            Spacer()
            Button { copy() } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(HoursButtonStyle())
            .animation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion), value: copied)
            .settingsDimsWhenDisabled()
            .disabled(text.isEmpty || generating)
            Button("Save") { save() }
                .buttonStyle(HoursButtonStyle())
                .settingsDimsWhenDisabled()
                .disabled(!dirty || text.isEmpty || generating)
                .keyboardShortcut("s", modifiers: .command)
            Button("Done") { dismiss() }
                .buttonStyle(HoursButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
    }

    private var title: String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let d = cal.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: 12))!
        return d.formatted(Date.FormatStyle(locale: Locale(identifier: "en_GB"), timeZone: timeZone).weekday(.wide).day().month(.wide))
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
        loaded = true
    }

    private func generate() {
        generating = true
        error = nil
        let db = db, date = date
        Task {
            do {
                let outcome = try await withCheckedThrowingContinuation { (c: CheckedContinuation<StandupGenerator.Outcome, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        c.resume(with: Result { try StandupGenerator.run(db: db, date: date, regenerate: true) })
                    }
                }
                if case .generated(let s) = outcome {
                    withAnimation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion)) {
                        stored = s; text = s.body; generating = false; generation += 1
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
