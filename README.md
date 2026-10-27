# Spells

Spells is a family of macOS productivity apps built with SwiftUI and SwiftPM: a small launcher plus
standalone modules you install only if you want them.

- **Spells** (the launcher): lists the modules installed in `~/Applications/Spells`, starts and stops them, opens their settings, and sets which ones start at login. It installs nothing by itself.
- **Rewind**: local-first automatic time tracking with SQLite, classification rules, editing, reports, CSV/PDF exports, and tamper-evident proof bundles. Its tracker helper runs at login.
- **Incant**: press-to-dictate. A menu-bar app with its own settings window.
- **Scry**: meeting note capture and summarization, with a Meetings window for the notes. A menu-bar app.

A module is an ordinary `.app` with a `SpellsModule` dictionary in its Info.plist (name, summary, symbol,
URL scheme, whether it is a login item). The launcher talks to it over `<scheme>://settings`, `quit` and
`login-item?on=1|0`; a module keeps its own settings in `~/Library/Application Support/Spells/<scheme>/settings.json`
and never opens another module's data. Shared code lives in `SpellsKit` (identifiers, log, keychain, paths, settings
files) and `SpellsUI` (design primitives, module windows and URL verbs).

## Privacy model

Time-tracking data is stored locally. Depending on which helpers you enable, the app can read window titles, browser URLs, microphone/system audio, and calendar metadata. Optional AI features send data to configured services: TypeSafe for activity classification, ElevenLabs for speech transcription, Cerebras for dictation correction, and Claude CLI for summaries and answers. Standup generation is off by default; when enabled it can read local Claude transcripts and meeting notes. Proof anchoring contacts DigiCert/FreeTSA with a chain digest, not raw activity records.

No real user database, recordings, transcripts, exports, API keys, or private planning history are included in this public snapshot.

## Build

Requires macOS 26 and Swift 6.2+.

```sh
swift build
swift test
```

To assemble signed `.app` bundles locally and install them (launcher to `~/Applications`, modules to
`~/Applications/Spells`):

```sh
scripts/build.sh
scripts/install.sh
```

## Repository note

This repository starts from a clean source snapshot with fresh git history. Private planning documents and personal fixture data were removed or replaced with example data. App identifiers and data paths are preserved; do not run two tracker installations against the same database.

## Development hygiene

Keep personal settings and credentials in local configuration, never in source or tests. Use fictional demo data. Databases, `.env*`, recordings, exports, and signing keys must not be committed; inspect `git diff --cached` before pushing. Run `gitleaks git` if you have Gitleaks installed. Secret scanning cannot detect every kind of private information.

## License

MIT. See `LICENSE`. Third-party notices are in `THIRD_PARTY_NOTICES.md`.
