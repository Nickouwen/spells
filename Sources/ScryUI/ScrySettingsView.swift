import AppKit
import SwiftUI
import SpellsKit
import SpellsUI
import ScryCore
import ScryPipeline

/// Scry's settings window: recording behaviour, the notes folder, your name, never-offer apps, the
/// ElevenLabs key and the claude CLI path. Writes Scry's own settings file; Scry re-reads it per event.
public struct ScrySettingsView: View {
    /// After a save (Scry re-reads its never-offer list; the hub re-reads the notes folder).
    var onSaved: () -> Void
    public init(onSaved: @escaping () -> Void = {}) { self.onSaved = onSaved }

    @State private var saved = ScrySettings()
    @State private var root = ""
    @State private var name = ""
    @State private var never = ""
    @State private var claudePath = ""
    @State private var key = ""
    @State private var keySaved = SupportKeychain.read(SupportKeychain.elevenLabs) != nil
    @State private var opsVault = ""
    @State private var opsSources = ""
    @State private var opsSlackUser = ""
    @State private var opsRules = ""
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    static let screenRecordingPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    public var body: some View {
        SettingsPage {
            SettingsSection("Recording", detail: "When a call app takes the mic, Scry offers to record. After the call it transcribes, summarises and writes a Markdown note. Nothing joins the call.") {
                SettingsToggleRow("Offer to record when a call starts", isOn: Binding(get: { saved.autoOffer }, set: { v in
                    var s = saved; s.autoOffer = v; persist(s)
                }))
                SettingsDivider()
                SettingsToggleRow("Record calls automatically (no offer)", isOn: Binding(get: { saved.autoRecord }, set: { v in
                    var s = saved; s.autoRecord = v; persist(s)
                }))
                SettingsDivider()
                SettingsToggleRow("Alarm when a meeting starts and you're not in a call", isOn: Binding(get: { saved.meetingAlarm }, set: { v in
                    var s = saved; s.meetingAlarm = v; persist(s)
                }))
                SettingsDivider()
                SettingsToggleRow("Live transcript and \u{201C}What did I miss?\u{201D}", isOn: Binding(get: { saved.live }, set: { v in
                    var s = saved; s.live = v; persist(s)
                }))
                SettingsDivider()
                HStack(spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text("Screen & System Audio Recording").textRole(.body)
                        Text("Scry needs it to hear the other side of the call.").textRole(.detail)
                    }
                    Spacer()
                    Button("Open System Settings") { openURL(Self.screenRecordingPane) }.buttonStyle(RewindButtonStyle())
                }
            }
            SettingsSection("Notes") {
                HStack(spacing: Theme.Space.s) {
                    Text("Notes folder").textRole(.body)
                    Spacer()
                    TextField(ScrySettings.defaultRoot, text: $root).textFieldStyle(.roundedBorder).font(TextRole.mono.font).frame(width: 240)
                    Button("Choose…") { chooseFolder() }.buttonStyle(RewindButtonStyle())
                }
                let r = root.trimmingCharacters(in: .whitespacesAndNewlines)
                if !r.isEmpty, !r.hasPrefix("/"), !r.hasPrefix("~") {
                    Text("Use a full path (starting with / or ~). A relative one falls back to \(ScrySettings.defaultRoot).")
                        .textRole(.detail)
                }
                SettingsDivider()
                HStack(spacing: Theme.Space.s) {
                    Text("Your name").textRole(.body)
                    Spacer()
                    TextField(ScrySettings().userName, text: $name).textFieldStyle(.roundedBorder).frame(width: 240)
                }
                SettingsDivider()
                editor("Never offer for these apps (bundle IDs, one per line)", $never, lines: 3)
                SettingsDivider()
                HStack(spacing: Theme.Space.s) {
                    Text("Claude CLI").textRole(.body)
                    Spacer()
                    TextField(SpellsClaude.defaultPath, text: $claudePath).textFieldStyle(.roundedBorder).font(TextRole.mono.font).frame(width: 240)
                }
                SettingsSaveRow(dirty: edited != saved || claudePath != savedClaudePath) {
                    let defaultShown = opsRules == defaultRules   // follows a new name in "asked <name> to do"
                    persist(edited); showNotes(saved); saveClaudePath()
                    if defaultShown { opsRules = defaultRules }
                }
            }
            SettingsSection("Ops brain", detail: "After a call, Claude finds what the team needs: deals, documents, decisions, processes, people, numbers and asks. The pill offers to push them into the ops vault. Nothing is written until you click it.") {
                SettingsToggleRow("Offer to push call items to the ops brain", isOn: Binding(get: { saved.opsPush }, set: { v in
                    var s = saved; s.opsPush = v; persist(s)
                }))
                SettingsDivider()
                HStack(spacing: Theme.Space.s) {
                    Text("Ops vault folder").textRole(.body)
                    Spacer()
                    TextField("Not set", text: $opsVault).textFieldStyle(.roundedBorder).font(TextRole.mono.font).frame(width: 240)
                    Button("Choose…") { chooseFolder(into: $opsVault) }.buttonStyle(RewindButtonStyle())
                }
                SettingsDivider()
                editor("Other transcript folders to watch (one per line)", $opsSources, lines: 3)
                SettingsDivider()
                editor("What to look for (one kind per line: \u{201C}kind: what it is\u{201D})", $opsRules, lines: 7)
                SettingsDivider()
                HStack(spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text("Slack member ID for a DM").textRole(.body)
                        Text("Needs a bot token in SLACK_BOT_TOKEN (.env) or the Keychain.").textRole(.detail)
                    }
                    Spacer()
                    TextField("Not set", text: $opsSlackUser).textFieldStyle(.roundedBorder).font(TextRole.mono.font).frame(width: 240)
                }
                SettingsSaveRow(dirty: editedOps != saved) { persist(editedOps); showOps(saved) }
            }
            SettingsSection("ElevenLabs", detail: "Scribe transcribes the recording. The key is kept in the Keychain (or ~/Library/Application Support/Spells/.env).") {
                HStack(spacing: Theme.Space.s) {
                    Text("API key").textRole(.body)
                    Spacer()
                    SecureField(keySaved ? "Saved in the Keychain" : "Paste key", text: $key).textFieldStyle(.roundedBorder).frame(width: 240)
                    Button("Save") {
                        keySaved = SupportKeychain.write(SupportKeychain.elevenLabs, key) && !key.isEmpty
                        key = ""
                    }
                    .buttonStyle(RewindButtonStyle())
                    .disabled(key.isEmpty)
                }
            }
            if let error { Text(error).textRole(.label, Theme.StateLayer.distraction) }
        }
        .frame(minWidth: 560, minHeight: 400)
        .tint(Theme.ink)
        .onAppear(perform: load)
    }

    @State private var savedClaudePath = ""

    private var edited: ScrySettings { ScrySettings.edited(saved, root: root, name: name, never: never) }

    private var editedOps: ScrySettings {
        var s = saved
        s.opsVault = opsVault.trimmingCharacters(in: .whitespacesAndNewlines)
        s.opsSources = opsSources.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        s.opsSlackUser = opsSlackUser.trimmingCharacters(in: .whitespacesAndNewlines)
        // The built-in list is stored as "" so later changes to it still reach this Mac.
        let rules = opsRules.trimmingCharacters(in: .whitespacesAndNewlines)
        s.opsRules = rules == defaultRules ? "" : rules
        return s
    }

    private func load() {
        let rows = SpellSettingsFile.scry().all()
        saved = ScrySettings.load(rows)
        showNotes(saved); showOps(saved)
        savedClaudePath = rows[SpellsClaude.key] ?? ""
        claudePath = savedClaudePath
    }

    /// Each section's fields are reset only by its own Save, so a toggle or the other Save keeps unsaved typing.
    private func showNotes(_ s: ScrySettings) {
        root = s.root
        name = s.userName
        never = s.never.joined(separator: "\n")
    }

    private func showOps(_ s: ScrySettings) {
        opsVault = s.opsVault
        opsSources = s.opsSources.joined(separator: "\n")
        opsSlackUser = s.opsSlackUser
        opsRules = s.opsRules.isEmpty ? defaultRules : s.opsRules
    }

    private var defaultRules: String {
        ScryOps.defaultRules(userName: saved.userName).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes only the rows that changed.
    private func persist(_ s: ScrySettings) {
        let old = saved.rows
        let changed = s.rows.filter { old[$0.key] != $0.value }
        saved = s
        write(changed)
    }

    private func saveClaudePath() {
        let p = claudePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p != savedClaudePath else { return }
        savedClaudePath = p
        claudePath = p
        write([SpellsClaude.key: p.isEmpty ? nil : p])
    }

    private func write(_ rows: [String: String?]) {
        guard !rows.isEmpty else { return }
        do {
            try SpellSettingsFile.scry().merge(rows)
            error = nil
            onSaved()
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
            SupportLog.scry.error("settings not saved: \(String(describing: error), privacy: .public)")
        }
    }

    private func chooseFolder(into field: Binding<String>? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = field.flatMap { ScrySettings.folder($0.wrappedValue) } ?? edited.rootURL
        if panel.runModal() == .OK, let url = panel.url { (field ?? $root).wrappedValue = (url.path as NSString).abbreviatingWithTildeInPath }
    }

    private func editor(_ title: String, _ text: Binding<String>, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).textRole(.body)
            TextEditor(text: text)
                .font(TextRole.body.font)
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.xs)
                .frame(height: CGFloat(lines) * 17 + 2 * Theme.Space.xs)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .accessibilityLabel(title)
        }
    }
}
