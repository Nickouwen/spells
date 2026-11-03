import SwiftUI
import SpellsKit
import SpellsUI
import WardCore

/// Ward's window (and the hub's Network section): whether the capture runs and what it holds, then
/// the audit of the last read — destinations, DNS names, TLS names — and the IOC scan.
public struct WardView: View {
    @Bindable var model: WardModel
    var openSettings: () -> Void
    @State private var removing = false

    public init(model: WardModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                capture
                audit
            }
            .padding(Theme.Space.gutter)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        .tint(Theme.ink)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert("Stop capturing and remove the daemon?", isPresented: $removing) {
            Button("Remove", role: .destructive) { model.uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The capture files stay in \(Ward.captureDir) until you delete them yourself.")
        }
    }

    private var stateColor: Swatch {
        switch model.status.daemon {
        case .loaded(.some): Theme.StateLayer.live
        case .loaded(nil), .stopped: Theme.StateLayer.warn
        case .notInstalled: Theme.inkTertiary
        }
    }

    private var capture: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Circle().fill(stateColor).frame(width: 10, height: 10)
                Text(model.status.title).textRole(.heading)
                Spacer()
                if let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).textRole(.label, Theme.inkSecondary)
                } else if !model.status.toolsInstalled {
                    Text("Needs Wireshark's dumpcap and tshark (brew install wireshark)").textRole(.label, Theme.StateLayer.warn)
                } else if model.status.installed {
                    Button("Remove…") { removing = true }.buttonStyle(RewindButtonStyle())
                } else {
                    Button("Install…") { model.install() }.buttonStyle(RewindButtonStyle())
                }
            }
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.xs) {
                fact("Interface", Ward.interface)
                fact("Ring", "\(Ward.files) files × \(Ward.fileKiB / 1024) MiB (\(bytes(Ward.ringBytes))), oldest dropped first")
                fact("Per packet", "\(Ward.snaplen) bytes: headers, DNS, TLS server names")
                if let s = model.snapshot {
                    fact("On disk", "\(s.files) file\(s.files == 1 ? "" : "s"), \(bytes(s.bytes))")
                    if let first = s.first, let last = s.last {
                        fact("Covers", "\(Self.stamp(first)) → \(Self.stamp(last))" + (s.coverage.map { " · \(Fmt.duration(ms: Int64($0 * 1000)))" } ?? ""))
                    }
                    fact("Last read", Self.relative(s.takenAt) + (s.window.isEmpty ? ", everything kept" : ", " + windowTitle(s.window)))
                }
                fact("Folder", Ward.captureDir + " (root only)")
            }
            Text(Ward.whatItKeeps).textRole(.label, Theme.inkTertiary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error).textRole(.label, Theme.StateLayer.distraction).lineLimit(3)
            }
        }
        .card()
    }

    private func fact(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).textRole(.label, Theme.inkSecondary).gridColumnAlignment(.trailing)
            Text(value).textRole(.body).lineLimit(2)
        }
    }

    private var audit: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Text("Audit").textRole(.heading)
                Spacer()
                Picker("Window", selection: $model.window) {
                    ForEach(WardWindow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button("Read Captures…") { model.takeSnapshot() }
                    .buttonStyle(RewindButtonStyle())
                    .disabled(model.busy != nil || !model.status.installed || !model.status.toolsInstalled)
                    .help("Runs tshark over the capture files as root (asks for your password) and lists what the Mac connected to.")
            }
            if let s = model.snapshot {
                ioc(s)
                tables
            } else {
                EmptyState(symbol: "shield.lefthalf.filled", title: "Nothing read yet",
                           detail: "Read Captures asks for your password, since the files belong to root, then lists the addresses, DNS lookups and TLS server names in the window you pick. The last read stays here.")
                    .card()
            }
        }
    }

    private func ioc(_ s: WardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: s.iocHits.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(s.iocHits.isEmpty ? Theme.StateLayer.live : Theme.StateLayer.distraction)
                Text(s.iocHits.isEmpty ? "No traffic to the known-bad indicators of the 2026-11-02 infostealer"
                                       : "\(s.iocHits.count) packet\(s.iocHits.count == 1 ? "" : "s") matched the known-bad indicators")
                    .textRole(.body)
            }
            if !s.iocHits.isEmpty {
                ForEach(Array(s.iocHits.prefix(20).enumerated()), id: \.offset) { _, line in
                    Text(line).textRole(.label, Theme.inkSecondary).font(.system(.caption, design: .monospaced)).lineLimit(1)
                }
            }
            if !s.errors.isEmpty {
                Text(s.errors.joined(separator: " · ")).textRole(.label, Theme.StateLayer.warn).lineLimit(2)
            }
        }
        .card(padding: Theme.Space.m)
    }

    private var tables: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Picker("Table", selection: $model.table) {
                    ForEach(WardModel.Table.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                TextField("Filter", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Text("\(model.rows.count) row\(model.rows.count == 1 ? "" : "s")").textRole(.label, Theme.inkTertiary)
            }
            if model.rows.isEmpty {
                Text(model.query.isEmpty ? "Nothing in this window." : "No match.").textRole(.body, Theme.inkTertiary).padding(.vertical, Theme.Space.m)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.rows) { r in
                        HStack(spacing: Theme.Space.m) {
                            Text(r.count.formatted()).textRole(.body, Theme.inkSecondary)
                                .font(.system(.body, design: .monospaced)).frame(width: 72, alignment: .trailing)
                            Text(r.name).textRole(.body).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, Theme.Space.xs)
                        if r.id != model.rows.last?.id { Rectangle().fill(Theme.hairline).frame(height: Theme.Stroke.hairline) }
                    }
                }
                .card(padding: Theme.Space.m)
            }
        }
    }

    private func windowTitle(_ filter: String) -> String {
        filter.firstMatch(of: /frame\.time >= "([^"]+)"/).map { "since \($0.1)" } ?? filter
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"; return f.string(from: d)
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: .now)
    }
}

/// Ward's settings: the daemon's facts and the scripts it runs.
public struct WardSettingsView: View {
    @Bindable var model: WardModel
    public init(model: WardModel) { self.model = model }

    public var body: some View {
        SettingsPage {
            SettingsSection("Capture daemon", detail: "A root LaunchDaemon (\(Ward.label)) running dumpcap on \(Ward.interface). Installing and removing ask for your password.") {
                row("Status", model.status.title)
                SettingsDivider()
                row("Daemon", Ward.plistPath)
                SettingsDivider()
                row("Captures", Ward.captureDir)
                SettingsDivider()
                row("Tools", model.status.toolsInstalled ? "\(Ward.dumpcap), tshark, capinfos" : "dumpcap / tshark missing — brew install wireshark")
                HStack {
                    Spacer()
                    if model.status.installed {
                        Button("Remove…") { model.uninstall() }.buttonStyle(RewindButtonStyle()).disabled(model.busy != nil)
                    } else {
                        Button("Install…") { model.install() }.buttonStyle(RewindButtonStyle()).disabled(model.busy != nil || !model.status.toolsInstalled)
                    }
                }
            }
            SettingsSection("Scripts", detail: "The shell scripts Ward runs, as they were written on 2026-11-02. You can run any of them yourself with sudo.") {
                script(Ward.setupScript, "installs or reinstalls the daemon (idempotent)")
                SettingsDivider()
                script(Ward.snapshotScript, "what Read Captures runs: facts, the three tables and the IOC scan, one tshark pass per file")
                SettingsDivider()
                script(Ward.auditScript, "the same three tables on the terminal; takes a tshark filter")
                SettingsDivider()
                script(Ward.iocScript, "scans the whole ring for the infostealer's indicators")
                SettingsDivider()
                script(Ward.uninstallScript, "stops and removes the daemon, keeps the captures")
                HStack {
                    Text(model.scriptsDir.path).textRole(.label, Theme.inkTertiary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { model.revealScripts() }.buttonStyle(RewindButtonStyle())
                }
            }
            if let error = model.error { Text(error).textRole(.label, Theme.StateLayer.distraction) }
        }
        .frame(minWidth: 560, minHeight: 400)
        .tint(Theme.ink)
        .onAppear { model.refreshStatus() }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(name).textRole(.body)
            Spacer()
            Text(value).textRole(.body, Theme.inkSecondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }

    private func script(_ name: String, _ what: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(name).textRole(.body).font(.system(.body, design: .monospaced))
            Spacer()
            Text(what).textRole(.label, Theme.inkSecondary).multilineTextAlignment(.trailing)
        }
    }
}
