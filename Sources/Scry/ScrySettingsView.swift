import AppKit
import SwiftUI
import SpellsKit
import SpellsUI
import ScryCore

/// Scry's settings window: recording behaviour, the notes folder, your name, never-offer apps, the
/// ElevenLabs key and the claude CLI path. Writes Scry's own settings file; Scry re-reads it per event.
struct ScrySettingsView: View {
    @State private var saved = ScrySettings()
    @State private var root = ""
    @State private var name = ""
    @State private var never = ""
    @State private var claudePath = ""
    @State private var key = ""
    @State private var keySaved = SupportKeychain.read(SupportKeychain.elevenLabs) != nil
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    static let screenRecordingPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    var body: some View {
        SettingsPage {
            SettingsSection("Recording", detail: "When a call app takes the mic, Scry offers to record. After the call it transcribes, summarises and writes a Markdown note. Nothing joins the call.") {
                Toggle("Offer to record when a call starts", isOn: Binding(get: { saved.autoOffer }, set: { v in
                    var s = saved; s.autoOffer = v; persist(s)
                }))
                .toggleStyle(.switch).textRole(.body)
                SettingsDivider()
                Toggle("Record calls automatically (no offer)", isOn: Binding(get: { saved.autoRecord }, set: { v in
                    var s = saved; s.autoRecord = v; persist(s)
                }))
                .toggleStyle(.switch).textRole(.body)
                SettingsDivider()
                Toggle("Live transcript and \u{201C}What did I miss?\u{201D}", isOn: Binding(get: { saved.live }, set: { v in
                    var s = saved; s.live = v; persist(s)
                }))
                .toggleStyle(.switch).textRole(.body)
                SettingsDivider()
                HStack(spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text("Screen & System Audio Recording").textRole(.body)
                        Text("Scry needs it to hear the other side of the call.").textRole(.label, Theme.inkSecondary)
                    }
                    Spacer()
                    Button("Open System Settings") { openURL(Self.screenRecordingPane) }.buttonStyle(RewindButtonStyle())
                }
            }
            SettingsSection("Notes") {
                HStack(spacing: Theme.Space.s) {
                    Text("Notes folder").textRole(.body)
                    Spacer()
                    TextField(ScrySettings.defaultRoot, text: $root).textFieldStyle(.roundedBorder).frame(width: 240)
                    Button("Choose…") { chooseFolder() }.buttonStyle(RewindButtonStyle())
                }
                let r = root.trimmingCharacters(in: .whitespacesAndNewlines)
                if !r.isEmpty, !r.hasPrefix("/"), !r.hasPrefix("~") {
                    Text("Use a full path (starting with / or ~). A relative one falls back to \(ScrySettings.defaultRoot).")
                        .textRole(.label, Theme.inkTertiary)
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
                    Text("claude CLI").textRole(.body)
                    Spacer()
                    TextField(SpellsClaude.defaultPath, text: $claudePath).textFieldStyle(.roundedBorder).frame(width: 240)
                }
                HStack {
                    Spacer()
                    Button("Save") { persist(edited); saveClaudePath() }
                        .buttonStyle(RewindButtonStyle())
                        .disabled(edited == saved && claudePath == savedClaudePath)
                        .settingsDimsWhenDisabled()
                }
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
                    .settingsDimsWhenDisabled()
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

    private func load() {
        let rows = SpellSettingsFile.scry().all()
        show(ScrySettings.load(rows))
        savedClaudePath = rows[SpellsClaude.key] ?? ""
        claudePath = savedClaudePath
    }

    private func show(_ s: ScrySettings) {
        saved = s
        root = s.root
        name = s.userName
        never = s.never.joined(separator: "\n")
    }

    /// Writes only the rows that changed.
    private func persist(_ s: ScrySettings) {
        let old = saved.rows
        let changed = s.rows.filter { old[$0.key] != $0.value }
        show(s)
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
            ScryWindows.settingsChanged()
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
            SupportLog.scry.error("settings not saved: \(String(describing: error), privacy: .public)")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = edited.rootURL
        if panel.runModal() == .OK, let url = panel.url { root = (url.path as NSString).abbreviatingWithTildeInPath }
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
