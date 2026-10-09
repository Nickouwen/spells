# Spells

Spells is a macOS productivity app built with SwiftUI and SwiftPM.

It includes:

- **Hours**: local-first automatic time tracking with SQLite, classification rules, editing, reports, CSV/PDF exports, and tamper-evident proof bundles.
- **Incant**: press-to-dictate helper.
- **Scry**: meeting note capture and summarization helper.

## Privacy model

Time-tracking data is stored locally. Depending on which helpers you enable, the app can read window titles, browser URLs, microphone/system audio, and calendar metadata. Optional AI features send data to configured services: TypeSafe for activity classification, ElevenLabs for speech transcription, Cerebras for dictation correction, and Claude CLI for summaries and answers. Standup generation is off by default; when enabled it can read local Claude transcripts and meeting notes. Proof anchoring contacts DigiCert/FreeTSA with a chain digest, not raw activity records.

No real user database, recordings, transcripts, exports, API keys, or private planning history are included in this public snapshot.

## Build

Requires macOS 26 and Swift 6.2+.

```sh
swift build
swift test
```

To assemble signed `.app` bundles locally:

```sh
scripts/build.sh
```

## Repository note

This repository starts from a clean source snapshot with fresh git history. Private planning documents and personal fixture data were removed or replaced with example data. App identifiers and data paths are preserved; do not run two tracker installations against the same database.

## Development hygiene

Keep personal settings and credentials in local configuration, never in source or tests. Use fictional demo data. Databases, `.env*`, recordings, exports, and signing keys must not be committed; inspect `git diff --cached` before pushing. Run `gitleaks git` if you have Gitleaks installed. Secret scanning cannot detect every kind of private information.

## License

No open-source license is granted in this snapshot. See `LICENSE`.
