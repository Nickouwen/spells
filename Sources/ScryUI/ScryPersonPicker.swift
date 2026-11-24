import SwiftUI
import SpellsUI
import ScryCore

/// Who is this? Search the people you know, likeliest first, or make a note for someone new.
struct ScryPersonPicker: View {
    enum Choice { case known(String, ScryPerson), new(String), unlinked(String), cancel }
    let person: ScryNotePerson
    let known: [ScryPerson]
    let canCreate: Bool
    let done: (Choice) -> Void
    @State private var name = ""
    @State private var query = ""
    @FocusState private var searching: Bool

    private var adding: Bool { person.name.isEmpty }
    private var called: String { name.trimmingCharacters(in: .whitespaces) }

    private var list: [ScryPerson] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            return known.filter { k in ([k.name, k.detail] + k.aliases + k.emails).contains { $0.localizedCaseInsensitiveContains(q) } }
        }
        let likely = ScryPeople.suggestions(called, in: known)
        return likely + known.filter { k in !likely.contains { $0.id == k.id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(adding ? "Add someone mentioned" : "Who is \(person.name)?").textRole(.title)
            if adding { TextField("Name as they said it", text: $name).textFieldStyle(.roundedBorder) }
            TextField("Search people you know", text: $query).textFieldStyle(.roundedBorder).focused($searching)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list) { k in
                        Button { done(.known(called.isEmpty ? k.name : called, k)) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(k.name).textRole(.body)
                                if !k.detail.isEmpty { Text(k.detail).textRole(.label, Theme.inkTertiary).lineLimit(1) }
                            }
                            .padding(.vertical, Theme.Space.xs).padding(.horizontal, Theme.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if list.isEmpty { Text("Nobody matches.").textRole(.label, Theme.inkTertiary).padding(Theme.Space.s) }
                }
            }
            .frame(height: 240)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            HStack(spacing: Theme.Space.s) {
                // The name to give a new note: what was searched for, else the name in the call.
                let new = query.trimmingCharacters(in: .whitespaces).isEmpty ? called : query.trimmingCharacters(in: .whitespaces)
                if canCreate, !new.isEmpty { Button("New Person “\(new)”") { done(.new(new)) }.buttonStyle(RewindButtonStyle()) }
                if adding, !called.isEmpty { Button("Add Without Link") { done(.unlinked(called)) }.buttonStyle(QuietButtonStyle()) }
                Spacer()
                Button("Cancel") { done(.cancel) }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 420)
        .background(Theme.canvas)
        .onAppear { name = person.name; if !adding { searching = true } }
    }
}
