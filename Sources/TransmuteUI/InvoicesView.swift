import SwiftUI
import RewindCore
import SpellsUI
import TransmuteCore

/// Transmute's window (and the hub's Invoices section): pick a period, see the invoice it makes, write
/// the PDF; below, the invoices already issued.
public struct InvoicesView: View {
    @Bindable var model: TransmuteModel
    var openSettings: () -> Void
    @State private var deleting: InvoiceLedger.Entry?
    @State private var amending = false

    public init(model: TransmuteModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
    }

    public var body: some View {
        Group {
            if !model.settings.missing.isEmpty {
                EmptyState(symbol: "flask", title: "Set up your invoice first",
                           detail: "Transmute needs \(model.settings.missing.joined(separator: ", ")). Everything else is optional.",
                           action: .init("Open Settings", perform: openSettings))
                    .padding(Theme.Space.gutter)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                        periodPicker
                        preview
                        issued
                    }
                    .padding(Theme.Space.gutter)
                    .frame(maxWidth: 820, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        .tint(Theme.ink)
        .onAppear { model.start() }
        .alert("Delete this invoice?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { e in
            Button("Move to Trash", role: .destructive) { model.delete(e); deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { e in
            Text("\(e.id) and its PDF go to the Trash. The number isn't reused.")
        }
    }

    private var periodPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Picker("Period", selection: $model.preset) {
                    ForEach(InvoicePreset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if model.preset == .custom {
                    DatePicker("From", selection: dateBinding(\.customFrom), displayedComponents: .date).labelsHidden()
                    Text("to").textRole(.label, Theme.inkSecondary)
                    DatePicker("Through", selection: dateBinding(\.customThrough), displayedComponents: .date).labelsHidden()
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
            }
            Text(Invoice.periodTitle(model.period)).textRole(.title)
        }
    }

    private func dateBinding(_ key: ReferenceWritableKeyPath<TransmuteModel, LocalDate>) -> Binding<Date> {
        Binding(get: { Self.date(model[keyPath: key]) }, set: { model[keyPath: key] = Self.localDate($0) })
    }

    static func date(_ d: LocalDate) -> Date {
        Calendar.current.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12))!
    }

    static func localDate(_ date: Date) -> LocalDate {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return LocalDate(year: c.year!, month: c.month!, day: c.day!)
    }

    @ViewBuilder private var preview: some View {
        if let inv = model.preview {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Invoice \(inv.number)").textRole(.heading)
                    Spacer()
                    Text("\(inv.fromName) → \(inv.clientName)").textRole(.label, Theme.inkSecondary).lineLimit(1).truncationMode(.middle)
                }
                .padding(.bottom, Theme.Space.m)
                ForEach(inv.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text(line.title).textRole(.body, line.amendment == nil ? nil : Theme.inkSecondary).lineLimit(2)
                        Spacer()
                        if let h = line.hundredths { Text("\(Invoice.hours(h)) h × \(inv.rate)").textRole(.body, Theme.inkSecondary) }
                        Text(Money.format(cents: line.cents, currency: inv.currency)).textRole(.bodyEmph).frame(width: 100, alignment: .trailing)
                        if let id = line.amendment {
                            IconButton(symbol: "xmark.circle", help: "Remove this amendment") { model.remove(amendment: id) }
                        } else {
                            Color.clear.frame(width: 26, height: 26)   // keeps the amounts in one column
                        }
                    }
                }
                Rectangle().fill(Theme.hairline).frame(height: Theme.Stroke.hairline).padding(.vertical, Theme.Space.m)
                if inv.days.isEmpty {
                    Text("No \(InvoiceSettings.Basis(rawValue: inv.basis)?.title.lowercased() ?? "time") recorded in this period.")
                        .textRole(.body, Theme.inkTertiary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.l)], alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(inv.days, id: \.date) { d in
                            let paid = inv.paidBy(d.date) != nil
                            HStack {
                                Text(Invoice.dayLabel(d.date)).textRole(.body, paid ? Theme.inkTertiary : Theme.inkSecondary)
                                Spacer()
                                Text(ExportPeriodData.hours(d.hundredths)).textRole(.body, paid ? Theme.inkTertiary : nil).strikethrough(paid)
                            }
                            .help(paid ? "Already paid; not billed" : "")
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("\(inv.days.count) day\(inv.days.count == 1 ? "" : "s") · \(Fmt.duration(ms: inv.totalMs))"
                         + (inv.billedHundredths == inv.totalHundredths ? "" : " · \(inv.billedHours) h billed"))
                        .textRole(.label, Theme.inkTertiary)
                    Spacer()
                    Text("Total").textRole(.label, Theme.inkSecondary)
                    Text(inv.amount).textRole(.metric).frame(minWidth: 100, alignment: .trailing)
                }
                .padding(.top, Theme.Space.l)
                HStack(spacing: Theme.Space.s) {
                    if let e = model.justIssued {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.StateLayer.live)
                        Text("Wrote \(e.url.lastPathComponent)").textRole(.label, Theme.inkSecondary)
                        Button("Open") { model.open(e) }.buttonStyle(RewindButtonStyle())
                    } else if let error = model.error {
                        Text(error).textRole(.label, Theme.StateLayer.distraction).lineLimit(2)
                    }
                    Spacer()
                    Button("Amend…") { amending = true }.buttonStyle(RewindButtonStyle()).disabled(inv.days.isEmpty || model.loading)
                        .popover(isPresented: $amending, arrowEdge: .bottom) {
                            AmendmentForm(period: inv.period, currency: inv.currency) { model.add($0); amending = false }
                        }
                    Button("Make PDF") { model.issue() }.buttonStyle(RewindButtonStyle()).disabled(inv.days.isEmpty || model.loading)
                }
                .padding(.top, Theme.Space.l)
            }
            .card()
        } else if let error = model.error {
            Text(error).textRole(.body, Theme.StateLayer.distraction).card()
        }
    }

    private var issued: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Issued").textRole(.heading)
                Spacer()
                Button("Show Folder") { model.revealFolder() }.buttonStyle(RewindButtonStyle())
            }
            if model.issued.isEmpty {
                Text("Nothing yet. Each PDF you make lands in \(model.settings.folderURL.path(percentEncoded: false)) and is listed here.")
                    .textRole(.body, Theme.inkTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.issued) { e in
                        HStack(spacing: Theme.Space.m) {
                            Image(systemName: "doc.text").foregroundStyle(Theme.inkSecondary)
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                Text("\(e.id) · \(Invoice.periodTitle(e.invoice.period))").textRole(.body)
                                Text("Issued \(Invoice.longDate(e.invoice.issued)) · \(e.invoice.hours) h").textRole(.label, Theme.inkTertiary)
                            }
                            Spacer()
                            Text(e.invoice.amount).textRole(.bodyEmph)
                            IconButton(symbol: "arrow.up.forward.square", help: "Open the PDF") { model.open(e) }
                            IconButton(symbol: "trash", help: "Delete…") { deleting = e }
                        }
                        .padding(.vertical, Theme.Space.s)
                        .contextMenu {
                            Button("Open") { model.open(e) }
                            Button("Show in Finder") { model.reveal(e) }
                            Divider()
                            Button("Delete…") { deleting = e }
                        }
                        if e.id != model.issued.last?.id { Rectangle().fill(Theme.hairline).frame(height: Theme.Stroke.hairline) }
                    }
                }
                .card(padding: Theme.Space.m)
            }
        }
    }
}
