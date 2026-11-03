import SwiftUI
import RewindCore
import SpellsUI
import TransmuteCore

/// The popover behind "Amend…": days the client already paid for (defaulting to the invoice's period),
/// or an amount off or on, with a note that prints on the line.
struct AmendmentForm: View {
    let period: ExportPeriod
    let currency: String
    var add: (Amendment) -> Void

    @State private var kind: Amendment.Kind = .paidDays
    @State private var from: Date
    @State private var through: Date
    @State private var amount = ""
    @State private var note = ""

    init(period: ExportPeriod, currency: String, add: @escaping (Amendment) -> Void) {
        self.period = period
        self.currency = currency
        self.add = add
        _from = State(initialValue: InvoicesView.date(period.from))
        _through = State(initialValue: InvoicesView.date(period.through))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Picker("Kind", selection: $kind) {
                ForEach(Amendment.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            if kind == .paidDays {
                HStack(spacing: Theme.Space.s) {
                    DatePicker("From", selection: $from, displayedComponents: .date).labelsHidden()
                    Text("to").textRole(.label, Theme.inkSecondary)
                    DatePicker("Through", selection: $through, displayedComponents: .date).labelsHidden()
                }
                Text("Those days' hours come off at your rate, as their own line.").textRole(.label, Theme.inkTertiary)
            } else {
                HStack(spacing: Theme.Space.s) {
                    Text(currency).textRole(.body, Theme.inkSecondary)
                    TextField("0.00", text: $amount).textFieldStyle(.roundedBorder).frame(width: 120)
                    if !amount.isEmpty, cents == nil { Text("That isn't a number.").textRole(.label, Theme.StateLayer.distraction) }
                }
            }
            TextField(prompt, text: $note).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Add") { add(amendment) }.buttonStyle(RewindButtonStyle()).disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 380)
    }

    private var prompt: String {
        switch kind {
        case .paidDays: "already paid"
        case .credit: "Deposit received"
        case .charge: "Rush fee"
        }
    }

    private var cents: Int64? { InvoiceSettings.parseRate(amount).flatMap { $0 > 0 ? $0 : nil } }
    private var valid: Bool { kind == .paidDays || cents != nil }

    private var amendment: Amendment {
        switch kind {
        case .paidDays: .paidDays(InvoicesView.localDate(from), InvoicesView.localDate(through), note: note)
        case .credit: .credit(cents: cents ?? 0, note: note)
        case .charge: .charge(cents: cents ?? 0, note: note)
        }
    }
}
