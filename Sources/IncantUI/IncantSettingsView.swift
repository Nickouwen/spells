import AppKit
import SwiftUI
import SpellsKit
import SpellsUI
import IncantCore

/// Incant's settings window: correction mode, prompt, cue words, keyterms, model, the two API keys and
/// the permission status. Writes Incant's own settings file; the key tap re-reads it at each key-down.
public struct IncantSettingsView: View {
    /// What Incant itself can see about its grants; nil (the Spells hub) shows a pointer to Incant instead.
    public struct Permissions: Sendable, Equatable {
        public var microphone: Bool, accessibility: Bool
        public init(microphone: Bool, accessibility: Bool) { self.microphone = microphone; self.accessibility = accessibility }
    }
    var permissions: Permissions?
    public init(permissions: Permissions?) { self.permissions = permissions }

    @State private var saved = IncantSettings()
    @State private var prompt = ""
    @State private var cues = ""
    @State private var keyterms = ""
    @State private var fixModel = ""
    @State private var key = ""
    @State private var keySaved = SupportKeychain.read(SupportKeychain.elevenLabs) != nil
    @State private var cerebrasKey = ""
    @State private var cerebrasSaved = SupportKeychain.read(SupportKeychain.cerebras) != nil
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    public var body: some View {
        SettingsPage {
            SettingsSection("Dictation", detail: "Hold Fn (or double-tap it for hands-free), speak, and the text lands wherever you're typing.") {
                if let p = permissions {
                    permission("Microphone", ok: p.microphone, pane: "Privacy_Microphone")
                    SettingsDivider()
                    permission("Accessibility", ok: p.accessibility, pane: "Privacy_Accessibility")
                } else {
                    HStack(spacing: Theme.Space.s) {
                        Text("Microphone and Accessibility are granted to Incant itself.").textRole(.body, Theme.inkSecondary)
                        Spacer()
                        Button("Open Incant Settings") { _ = ModuleURLs.send(Spells.incantBundleID, scheme: "incant", verb: "settings") }
                            .buttonStyle(RewindButtonStyle())
                    }
                }
                SettingsDivider()
                HStack(spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stream as I speak").textRole(.body)
                        Text("Words are typed as you say them, about a second behind. Each sentence is corrected at the pause that ends it; earlier sentences are never changed.")
                            .textRole(.label, Theme.inkSecondary)
                    }
                    Spacer()
                    Toggle("Stream as I speak", isOn: Binding(get: { saved.stream }, set: { on in
                        var s = saved; s.stream = on; persist(s, refresh: false)   // keep unsaved text edits
                    }))
                    .toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsSection("Correction", detail: "After you speak, a fast model applies spoken self-corrections (\"three, no, four\" → \"four\"). \"When needed\" runs it only when it hears a cue word.") {
                HStack {
                    Text("Correction").textRole(.body)
                    Spacer()
                    Picker("Correction", selection: Binding(get: { saved.mode }, set: { m in
                        var s = saved; s.mode = m; persist(s, refresh: false)   // keep unsaved text edits
                    })) {
                        Text("When needed").tag(IncantFixMode.whenNeeded)
                        Text("Always").tag(IncantFixMode.always)
                        Text("Off").tag(IncantFixMode.off)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                SettingsDivider()
                editor("Prompt", $prompt, lines: 6) { prompt = IncantSettings.defaultPrompt }
                SettingsDivider()
                editor("Cue words, one per line", $cues, lines: 4)
                SettingsDivider()
                editor("Keyterms, one per line", $keyterms, lines: 4)
                SettingsDivider()
                HStack(spacing: Theme.Space.s) {
                    Text("Correction model").textRole(.body)
                    Spacer()
                    TextField(IncantSettings.defaultModel, text: $fixModel).textFieldStyle(.roundedBorder).frame(width: 240)
                }
                HStack {
                    Spacer()
                    Button("Save") { persist(edited) }
                        .buttonStyle(RewindButtonStyle())
                        .disabled(edited == saved)
                        .settingsDimsWhenDisabled()
                }
            }
            SettingsSection("API keys", detail: "ElevenLabs Scribe transcribes; Cerebras runs the correction. Keys are kept in the Keychain (or ~/Library/Application Support/Spells/.env).") {
                keyRow("ElevenLabs API key", $key, saved: $keySaved, service: SupportKeychain.elevenLabs)
                SettingsDivider()
                keyRow("Cerebras API key", $cerebrasKey, saved: $cerebrasSaved, service: SupportKeychain.cerebras)
            }
            if let error { Text(error).textRole(.label, Theme.StateLayer.distraction) }
        }
        .frame(minWidth: 560, minHeight: 400)
        .tint(Theme.ink)
        .onAppear { show(IncantSettings.load(SpellSettingsFile.incant().all())) }
    }

    private var edited: IncantSettings { IncantSettings.edited(saved, prompt: prompt, cues: cues, keyterms: keyterms, model: fixModel) }

    private func show(_ s: IncantSettings) {
        saved = s
        prompt = s.prompt
        cues = s.cues.joined(separator: "\n")
        keyterms = s.keyterms.joined(separator: "\n")
        fixModel = s.model
    }

    /// Writes only the rows that changed.
    private func persist(_ s: IncantSettings, refresh: Bool = true) {
        let old = saved.rows
        let changed = s.rows.filter { old[$0.key] != $0.value }
        if refresh { show(s) } else { saved = s }
        guard !changed.isEmpty else { return }
        do {
            try SpellSettingsFile.incant().merge(changed)
            error = nil
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
            SupportLog.incant.error("settings not saved: \(String(describing: error), privacy: .public)")
        }
    }

    private func permission(_ name: String, ok: Bool, pane: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(name).textRole(.body)
            Spacer()
            Text(ok ? "Allowed" : "Not allowed").textRole(.label, ok ? Theme.inkSecondary : Theme.StateLayer.distraction)
            if !ok {
                Button("Open System Settings") {
                    openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
                .buttonStyle(RewindButtonStyle())
            }
        }
    }

    private func keyRow(_ title: String, _ text: Binding<String>, saved: Binding<Bool>, service: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(title).textRole(.body)
            Spacer()
            SecureField(saved.wrappedValue ? "Saved in the Keychain" : "Paste key", text: text).textFieldStyle(.roundedBorder).frame(width: 240)
            Button("Save") {
                saved.wrappedValue = SupportKeychain.write(service, text.wrappedValue) && !text.wrappedValue.isEmpty
                text.wrappedValue = ""
            }
            .buttonStyle(RewindButtonStyle())
            .disabled(text.wrappedValue.isEmpty)
            .settingsDimsWhenDisabled()
        }
    }

    private func editor(_ title: String, _ text: Binding<String>, lines: Int, reset: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(title).textRole(.body)
                Spacer()
                if let reset { Button("Reset to default", action: reset).buttonStyle(RewindButtonStyle()) }
            }
            TextEditor(text: text)
                .font(TextRole.body.font)
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.xs)
                .frame(height: CGFloat(lines) * 17 + 2 * Theme.Space.xs)   // ponytail: ~17 pt per body line
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .accessibilityLabel(title)
        }
    }
}
