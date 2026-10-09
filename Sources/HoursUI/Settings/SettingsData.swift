import AppKit
import SwiftUI
import HoursCore

/// DB location, backups, export / anchor.
struct SettingsDataTab: View {
    let model: AppModel
    @State private var backups: [SettingsBackup] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsPage {
            SettingsSection("Timesheet", detail: "Shown as Consultant on the PDF timesheet. Leave blank to use your macOS account name.") {
                HStack(spacing: Theme.Space.m) {
                    Text("Consultant name").textRole(.body)
                    Spacer()
                    TextField("Consultant name", text: $consultant, prompt: Text(NSFullUserName()))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .onSubmit { Task { await model.setConsultantName(consultant) } }
                }
            }
            SettingsSection("Database") {
                HStack(spacing: Theme.Space.m) {
                    Text(model.paths.db.path).textRole(.mono, Theme.inkSecondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.db]) }
                        .buttonStyle(HoursButtonStyle())
                }
            }
            SettingsSection("Backups", detail: "Daily snapshots by the tracker: the last 14 days plus one per month for a year.") {
                if backups.isEmpty {
                    Text("No backups yet.").textRole(.body, Theme.inkSecondary)
                }
                ForEach(Array(backups.enumerated()), id: \.element.name) { i, b in
                    if i > 0 { SettingsDivider() }
                    HStack {
                        Text(b.name).textRole(.mono)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: b.bytes, countStyle: .file))
                            .textRole(.label, Theme.inkSecondary)
                    }
                }
            }
            SettingsSection("Export", detail: "Billable hours per day and project. Audit adds the chain rows and anchors so the bundle verifies without the app.") {
                HStack(spacing: Theme.Space.m) {
                    Picker("Period", selection: $period) {
                        Text("Previous billing period").tag("previous")
                        Text("Current billing period").tag("current")
                    }
                    .labelsHidden().fixedSize()
                    Picker("Mode", selection: $audit) {
                        Text("Timesheet").tag(false)
                        Text("Audit bundle").tag(true)
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                    Button { runExport() } label: {
                        Label("Export", systemImage: exported ? "checkmark" : "square.and.arrow.up")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(HoursButtonStyle())
                    .animation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion), value: exported)
                    .settingsDimsWhenDisabled()
                    .disabled(busy)
                }
                if let exportStatus {
                    Text(exportStatus).textRole(.label, Theme.inkSecondary).padding(.top, Theme.Space.s)
                }
            }
            SettingsSection("Proof", detail: "Timestamps the chain head with DigiCert and FreeTSA. The tracker also does this once a day.") {
                HStack(spacing: Theme.Space.m) {
                    Text(anchorStatus ?? lastAnchor ?? "Not anchored yet.").textRole(.body, Theme.inkSecondary)
                    Spacer()
                    Button { runAnchor() } label: {
                        Label("Anchor Now", systemImage: anchored ? "checkmark" : "seal")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(HoursButtonStyle())
                    .animation(Theme.Motion.animation(Theme.Motion.swap, reduceMotion: reduceMotion), value: anchored)
                    .settingsDimsWhenDisabled()
                    .disabled(busy)
                }
            }
        }
        .onDisappear { if consultant != storedConsultant { Task { await model.setConsultantName(consultant) } } }
        .task {
            consultant = storedConsultant
            backups = SettingsBackup.list(in: model.paths.backups)
            lastAnchor = Self.lastAnchorText(model)
        }
    }

    @State private var consultant = ""
    /// The stored value, blank when it's the default (so the field shows the default as its prompt).
    private var storedConsultant: String { model.settings[ExportPDF.consultantNameKey] ?? "" }
    @State private var period = "previous"
    @State private var audit = false
    @State private var busy = false
    @State private var exportStatus: String?
    @State private var anchorStatus: String?
    @State private var lastAnchor: String?
    /// The last run succeeded: its button shows a checkmark until the next run starts.
    @State private var exported = false
    @State private var anchored = false

    private func runExport() {
        busy = true
        exported = false
        Task {
            do {
                let mode: ExportMode = audit ? .audit : .plain
                let out = try await model.export(period, mode: mode)
                // The PDF timesheet goes next to timesheet.csv (its footer pins that file's digest).
                var reveal = out.dir
                if let p = ExportPeriod.parse(period, today: model.today) {
                    let (db, tz, dir) = (model.db, model.timeZone, out.dir)
                    reveal = try await Task.detached(priority: .userInitiated) {
                        try ExportPDF.write(db: db, period: p, mode: mode, to: dir, tz: tz).url
                    }.value
                }
                exportStatus = out.summary + " · PDF"
                exported = true
                NSWorkspace.shared.activateFileViewerSelecting([reveal])
            } catch {
                exportStatus = "Export failed: \(error)"
            }
            busy = false
        }
    }

    private func runAnchor() {
        busy = true
        anchored = false
        Task {
            anchorStatus = await model.anchorNow()
            anchored = anchorStatus?.hasPrefix("Anchored") == true   // anchorNow's success line
            busy = false
        }
    }

    static func lastAnchorText(_ model: AppModel) -> String? {
        guard let a = (try? AnchorStore(model.db).list())?.last else { return nil }
        let when = Date(timeIntervalSince1970: Double(a.genTimeMs ?? a.requestedMs) / 1000)
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = model.timeZone
        return "Last anchored \(when.formatted(style)) · head #\(a.headSeq) by \(a.tsa ?? "?")"
    }
}

struct SettingsBackup: Hashable {
    var name: String
    var bytes: Int64

    /// `hours-YYYY-MM-DD.db` files, newest first.
    static func list(in dir: URL) -> [SettingsBackup] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("hours-") && $0.hasSuffix(".db") }.sorted(by: >).map { name in
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: name).path)[.size] as? Int64) ?? 0
            return SettingsBackup(name: name, bytes: size)
        }
    }
}
