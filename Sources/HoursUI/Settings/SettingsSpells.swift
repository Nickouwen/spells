import AppKit
import SwiftUI
import HoursCore
import IncantCore
import ScryCore

/// A spell that runs as its own login item. The app target supplies it (ServiceManagement lives there).
public struct SpellSwitch {
    public enum State: Equatable { case off, needsApproval, on(running: Bool) }
    public var state: @MainActor () -> State
    /// Switches it on (register + launch) or off (unregister + quit); returns an error to show, if any.
    public var set: @MainActor (Bool) async -> String?
    public init(state: @escaping @MainActor () -> State, set: @escaping @MainActor (Bool) async -> String?) {
        self.state = state; self.set = set
    }
}

/// Settings → Spells: what each spell is and its switch. Hours is always on; Incant and Scry run only while on.
struct SettingsSpellsTab: View {
    let model: AppModel
    @State private var state: SpellSwitch.State = .off
    @State private var busy = false
    @State private var error: String?
    @State private var key = ""
    @State private var keySaved = SupportKeychain.read(SupportKeychain.elevenLabs) != nil
    @State private var cerebrasKey = ""
    @State private var cerebrasSaved = SupportKeychain.read(SupportKeychain.cerebras) != nil
    /// What's in the setting table; the text fields below are edits against it until Save.
    @State private var saved = IncantSettings()
    @State private var prompt = ""
    @State private var cues = ""
    @State private var keyterms = ""
    @State private var fixModel = ""
    @State private var scryState: SpellSwitch.State = .off
    @State private var scryError: String?
    @State private var scrySaved = ScrySettings()
    @State private var scryRoot = ""
    @State private var scryName = ""
    @State private var scryNever = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsPage {
            SettingsSection("Hours", detail: "Time tracking, the notch island and the EOD report. Always on.") {
                Text("HoursSpell runs in the background and starts at login.").textRole(.body, Theme.inkSecondary)
            }
            SettingsSection("Incant", detail: "Dictation: hold Fn (or double-tap it for hands-free), speak, and the text lands wherever you're typing. It runs as its own background app only while switched on. Off means nothing runs and nothing listens.") {
                if let incant = model.incant {
                    Toggle("On", isOn: Binding(get: { state != .off }, set: { on in toggle(incant, on) }))
                        .toggleStyle(.switch)
                        .textRole(.body)
                        .disabled(busy)
                    SettingsDivider()
                    HStack {
                        Text("Status").textRole(.body)
                        Spacer()
                        Text(Self.statusText(state)).textRole(.label, Theme.inkSecondary)
                        if state == .needsApproval {
                            Button("Open Login Items") { model.openLoginItems?() }.buttonStyle(HoursButtonStyle())
                        }
                    }
                    if let error { Text(error).textRole(.label, Theme.StateLayer.distraction) }
                } else {
                    Text("Available in the installed app.").textRole(.body, Theme.inkSecondary)
                }
                SettingsDivider()
                HStack(spacing: Theme.Space.s) {
                    Text("ElevenLabs API key").textRole(.body)
                    Spacer()
                    SecureField(keySaved ? "Saved in the Keychain" : "Paste key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    Button("Save") {
                        keySaved = SupportKeychain.write(SupportKeychain.elevenLabs, key) && !key.isEmpty
                        key = ""
                    }
                    .buttonStyle(HoursButtonStyle())
                    .disabled(key.isEmpty)
                    .settingsDimsWhenDisabled()
                }
            }
            SettingsSection("Incant correction", detail: "After you speak, a fast model applies spoken self-corrections (\"three, no, four\" → \"four\"). \"When needed\" runs it only when it hears a cue word.") {
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
                    TextField(IncantSettings.defaultModel, text: $fixModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                HStack {
                    Spacer()
                    Button("Save") { persist(edited) }
                        .buttonStyle(HoursButtonStyle())
                        .disabled(edited == saved)
                        .settingsDimsWhenDisabled()
                }
                SettingsDivider()
                HStack(spacing: Theme.Space.s) {
                    Text("Cerebras API key").textRole(.body)
                    Spacer()
                    SecureField(cerebrasSaved ? "Saved in the Keychain" : "Paste key", text: $cerebrasKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    Button("Save") {
                        cerebrasSaved = SupportKeychain.write(SupportKeychain.cerebras, cerebrasKey) && !cerebrasKey.isEmpty
                        cerebrasKey = ""
                    }
                    .buttonStyle(HoursButtonStyle())
                    .disabled(cerebrasKey.isEmpty)
                    .settingsDimsWhenDisabled()
                }
            }
            scrySection
        }
        .onAppear {
            state = model.incant?.state() ?? .off
            show(IncantSettings.load(model.settings))
            scryState = model.scry?.state() ?? .off
            showScry(ScrySettings.load(model.settings))
        }
    }

    // MARK: Scry

    static let screenRecordingPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    private var scrySection: some View {
        SettingsSection("Scry", detail: "Meeting notes: when a call app takes the mic, Scry offers to record. After the call it transcribes, summarises and writes a Markdown note you'll find under Meetings. Nothing joins the call. It runs as its own background app only while switched on.") {
            if let scry = model.scry {
                Toggle("On", isOn: Binding(get: { scryState != .off }, set: { on in toggleScry(scry, on) }))
                    .toggleStyle(.switch)
                    .textRole(.body)
                    .disabled(busy)
                SettingsDivider()
                HStack {
                    Text("Status").textRole(.body)
                    Spacer()
                    Text(Self.statusText(scryState)).textRole(.label, Theme.inkSecondary)
                    if scryState == .needsApproval {
                        Button("Open Login Items") { model.openLoginItems?() }.buttonStyle(HoursButtonStyle())
                    }
                }
                if let scryError { Text(scryError).textRole(.label, Theme.StateLayer.distraction) }
            } else {
                Text("Available in the installed app.").textRole(.body, Theme.inkSecondary)
            }
            SettingsDivider()
            Toggle("Offer to record when a call starts", isOn: Binding(get: { scrySaved.autoOffer }, set: { v in
                var s = scrySaved; s.autoOffer = v; persistScry(s, refresh: false)
            }))
            .toggleStyle(.switch)
            .textRole(.body)
            SettingsDivider()
            Toggle("Record calls automatically (no offer)", isOn: Binding(get: { scrySaved.autoRecord }, set: { v in
                var s = scrySaved; s.autoRecord = v; persistScry(s, refresh: false)
            }))
            .toggleStyle(.switch)
            .textRole(.body)
            SettingsDivider()
            Toggle("Live transcript and \u{201C}What did I miss?\u{201D}", isOn: Binding(get: { scrySaved.live }, set: { v in
                var s = scrySaved; s.live = v; persistScry(s, refresh: false)
            }))
            .toggleStyle(.switch)
            .textRole(.body)
            SettingsDivider()
            HStack(spacing: Theme.Space.s) {
                Text("Notes folder").textRole(.body)
                Spacer()
                TextField(ScrySettings.defaultRoot, text: $scryRoot)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Button("Choose…") { chooseScryFolder() }.buttonStyle(HoursButtonStyle())
            }
            let r = scryRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            if !r.isEmpty, !r.hasPrefix("/"), !r.hasPrefix("~") {
                Text("Use a full path (starting with / or ~). A relative one falls back to \(ScrySettings.defaultRoot).")
                    .textRole(.label, Theme.inkTertiary)
            }
            SettingsDivider()
            HStack(spacing: Theme.Space.s) {
                Text("Your name").textRole(.body)
                Spacer()
                TextField(ScrySettings().userName, text: $scryName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            SettingsDivider()
            editor("Never offer for these apps (bundle IDs, one per line)", $scryNever, lines: 3)
            HStack {
                Spacer()
                Button("Save") { persistScry(scryEdited) }
                    .buttonStyle(HoursButtonStyle())
                    .disabled(scryEdited == scrySaved)
                    .settingsDimsWhenDisabled()
            }
            SettingsDivider()
            HStack(spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Screen & System Audio Recording").textRole(.body)
                    Text("Scry needs it to hear the other side of the call.").textRole(.label, Theme.inkSecondary)
                }
                Spacer()
                Button("Open Settings") { openURL(Self.screenRecordingPane) }.buttonStyle(HoursButtonStyle())
            }
        }
    }

    private var scryEdited: ScrySettings { Self.scryEdited(scrySaved, root: scryRoot, name: scryName, never: scryNever) }

    /// The Scry text fields → settings. Blank folder/name fall back to the defaults; the app list drops blank lines.
    static func scryEdited(_ base: ScrySettings, root: String, name: String, never: String) -> ScrySettings {
        var s = base
        let r = root.trimmingCharacters(in: .whitespacesAndNewlines), n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        s.root = r.isEmpty ? ScrySettings.defaultRoot : r
        s.userName = n.isEmpty ? ScrySettings().userName : n
        s.never = never.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return s
    }

    private func showScry(_ s: ScrySettings) {
        scrySaved = s
        scryRoot = s.root
        scryName = s.userName
        scryNever = s.never.joined(separator: "\n")
    }

    private func persistScry(_ s: ScrySettings, refresh: Bool = true) {
        let old = scrySaved.rows
        let changed = s.rows.filter { old[$0.key] != $0.value }
        if refresh { showScry(s) } else { scrySaved = s }
        save(changed)
    }

    private func chooseScryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = Self.scryEdited(scrySaved, root: scryRoot, name: "", never: "").rootURL
        if panel.runModal() == .OK, let url = panel.url { scryRoot = (url.path as NSString).abbreviatingWithTildeInPath }
    }

    private func toggleScry(_ scry: SpellSwitch, _ on: Bool) {
        busy = true
        Task {
            scryError = await scry.set(on)
            scryState = scry.state()
            busy = false
        }
    }

    private var edited: IncantSettings {
        Self.edited(saved, prompt: prompt, cues: cues, keyterms: keyterms, model: fixModel)
    }

    /// The text fields → settings. Empty prompt/model fall back to the defaults; lists drop blank lines.
    static func edited(_ base: IncantSettings, prompt: String, cues: String, keyterms: String, model: String) -> IncantSettings {
        func lines(_ t: String) -> [String] {
            t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var s = base
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines), m = model.trimmingCharacters(in: .whitespaces)
        s.prompt = p.isEmpty ? IncantSettings.defaultPrompt : p
        s.model = m.isEmpty ? IncantSettings.defaultModel : m
        s.cues = lines(cues)
        s.keyterms = lines(keyterms)
        return s
    }

    private func show(_ s: IncantSettings) {
        saved = s
        prompt = s.prompt
        cues = s.cues.joined(separator: "\n")
        keyterms = s.keyterms.joined(separator: "\n")
        fixModel = s.model
    }

    /// Writes only the rows that changed. Incant reads settings at each key-down, so nothing to push.
    private func persist(_ s: IncantSettings, refresh: Bool = true) {
        let old = saved.rows
        let changed = s.rows.filter { old[$0.key] != $0.value }
        if refresh { show(s) } else { saved = s }
        save(changed)
    }

    /// Writes setting rows off the main actor.
    private func save(_ changed: [String: String]) {
        let db = model.db
        Task.detached(priority: .userInitiated) {
            for (key, value) in changed {
                do { try SettingStore(db).set(key, value) } catch {
                    SupportLog.app.error("\(key, privacy: .public) not saved: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func editor(_ title: String, _ text: Binding<String>, lines: Int, reset: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(title).textRole(.body)
                Spacer()
                if let reset { Button("Reset to default", action: reset).buttonStyle(HoursButtonStyle()) }
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

    private func toggle(_ incant: SpellSwitch, _ on: Bool) {
        busy = true
        Task {
            error = await incant.set(on)
            state = incant.state()
            busy = false
        }
    }

    static func statusText(_ s: SpellSwitch.State) -> String {
        switch s {
        case .off: "Off"
        case .needsApproval: "Waiting for approval in Login Items"
        case .on(running: true): "Running"
        case .on(running: false): "On, not running"
        }
    }
}
