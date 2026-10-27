import AppKit
import SwiftUI
import SpellsKit
import SpellsUI
import TransmuteCore

/// Transmute's settings: you, the client, the rate and what counts, where the PDFs go. Writes Transmute's
/// own settings file; the model re-reads it after each save.
public struct TransmuteSettingsView: View {
    var onSaved: () -> Void
    public init(onSaved: @escaping () -> Void = {}) { self.onSaved = onSaved }

    @State private var saved = InvoiceSettings()
    @State private var edited = InvoiceSettings()
    @State private var rate = ""
    @State private var next = ""
    @State private var error: String?

    public var body: some View {
        SettingsPage {
            SettingsSection("You", detail: "The top-left of the invoice.") {
                field("Name", $edited.fromName, prompt: "Your name or business")
                SettingsDivider()
                editor("Address (one line per row)", $edited.fromAddress)
                SettingsDivider()
                field("Email", $edited.fromEmail, prompt: "you@example.com")
                saveRow
            }
            SettingsSection("Client", detail: "Who the invoice bills.") {
                field("Name", $edited.clientName, prompt: "Client or company")
                SettingsDivider()
                editor("Address (one line per row)", $edited.clientAddress)
                SettingsDivider()
                field("Email", $edited.clientEmail, prompt: "billing@client.com")
                saveRow
            }
            SettingsSection("Billing", detail: "Hours come from Rewind's database, rounded to 0.01 h per day like its timesheet.") {
                HStack(spacing: Theme.Space.s) {
                    Text("Hourly rate").textRole(.body)
                    Spacer()
                    TextField("45.00", text: $rate).textFieldStyle(.roundedBorder).frame(width: 120)
                        .onChange(of: rate) { _, v in edited.rateCents = InvoiceSettings.parseRate(v) ?? 0 }
                    TextField("CAD", text: $edited.currency).textFieldStyle(.roundedBorder).frame(width: 64)
                }
                if !rate.isEmpty, InvoiceSettings.parseRate(rate) == nil {
                    Text("That isn't a number.").textRole(.label, Theme.StateLayer.distraction)
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.s) {
                        Text("Count").textRole(.body)
                        Spacer()
                        Picker("Count", selection: $edited.basis) {
                            ForEach(InvoiceSettings.Basis.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Text(edited.basis.detail).textRole(.label, Theme.inkSecondary)
                }
                SettingsDivider()
                field("Description", $edited.description, prompt: "For development {period}")
                Text("{period} becomes the dates, e.g. \u{201C}October 1–15, 2026\u{201D}.").textRole(.label, Theme.inkTertiary)
                SettingsDivider()
                field("Terms", $edited.terms, prompt: "Due on receipt.")
                SettingsDivider()
                HStack(spacing: Theme.Space.s) {
                    Text("Numbering").textRole(.body)
                    Spacer()
                    TextField("INV-", text: $edited.prefix).textFieldStyle(.roundedBorder).frame(width: 80)
                    TextField("1", text: $next).textFieldStyle(.roundedBorder).frame(width: 64)
                        .onChange(of: next) { _, v in edited.nextNumber = max(1, Int(v) ?? saved.nextNumber) }
                    Text("next: \(edited.number)").textRole(.label, Theme.inkTertiary)
                }
                saveRow
            }
            SettingsSection("Files") {
                HStack(spacing: Theme.Space.s) {
                    Text("Invoices folder").textRole(.body)
                    Spacer()
                    TextField(InvoiceSettings.defaultFolder, text: $edited.folder).textFieldStyle(.roundedBorder).frame(width: 240)
                    Button("Choose…") { chooseFolder() }.buttonStyle(RewindButtonStyle())
                }
                saveRow
            }
            if let error { Text(error).textRole(.label, Theme.StateLayer.distraction) }
        }
        .frame(minWidth: 560, minHeight: 400)
        .tint(Theme.ink)
        .onAppear(perform: load)
    }

    private func field(_ label: String, _ text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(label).textRole(.body)
            Spacer()
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).frame(width: 300)
        }
    }

    private func editor(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label).textRole(.body)
            TextEditor(text: text)
                .font(.body)
                .frame(height: 56)
                .padding(Theme.Space.xs)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
        }
    }

    private var saveRow: some View {
        HStack {
            Spacer()
            Button("Save") { persist() }
                .buttonStyle(RewindButtonStyle())
                .disabled(edited == saved)
                .settingsDimsWhenDisabled()
        }
        .padding(.top, Theme.Space.s)
    }

    private func load() {
        saved = InvoiceSettings.load(SpellSettingsFile.transmute().all())
        edited = saved
        rate = saved.rateCents > 0 ? InvoiceSettings.rateString(saved.rateCents) : ""
        next = String(saved.nextNumber)
    }

    /// Writes only the rows that changed.
    private func persist() {
        let old = saved.rows
        let changed = edited.rows.filter { old[$0.key] != $0.value }
        guard !changed.isEmpty else { return }
        do {
            try SpellSettingsFile.transmute().merge(changed.mapValues { Optional($0) })
            saved = edited
            error = nil
            onSaved()
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
            SupportLog.transmute.error("settings not saved: \(String(describing: error), privacy: .public)")
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = edited.folderURL
        if p.runModal() == .OK, let url = p.url { edited.folder = url.path(percentEncoded: false) }
    }
}
