# Spells

Spells is a family of macOS productivity apps built with SwiftUI and SwiftPM: a small launcher plus
standalone modules you install only if you want them.

- **Spells** (the hub): lists the modules installed in `~/Applications/Spells` and the ones in the catalog; installs, updates and removes them, starts and stops them, and sets which ones start at login. Its sidebar also carries every installed module's own views — Rewind's Day / Week / Range and settings, Scry's Meetings and settings, Incant's settings, Transmute's Invoices and settings — read straight from their data whether or not the module is running. It ships with nothing installed.
- **Rewind**: local-first automatic time tracking with SQLite, classification rules, editing, reports, CSV/PDF exports, and tamper-evident proof bundles. Its tracker helper runs at login.
- **Incant**: press-to-dictate. A menu-bar app with its own settings window.
- **Scry**: meeting note capture and summarization, with a Meetings window for the notes. A menu-bar app.
- **Ward**: network watch. A root LaunchDaemon keeps a rolling packet capture (dumpcap, a ~1 GB ring on `en0`, 256 bytes per packet: headers, DNS, TLS server names) in `/var/log/netcap`, so a security incident can be audited after the fact. The window shows whether it runs and what it covers, reads the captures with your password, and lists the destinations, DNS lookups and TLS names in a window of time plus a scan for the 2026-11-02 infostealer's indicators. The shell scripts it runs ship in its bundle. A windowed app; its views also sit in the hub.
- **Transmute**: invoices from your hours. Picks a period (the semi-month just finished, the one in progress, or any dates), reads the days' time from Rewind's database, prices it at your rate and writes a PDF (one line item, then the day-by-day hours). Keeps a ledger of what it issued and numbers the next one. A windowed app; its views also sit in the hub.

A module is an ordinary `.app` with a `SpellsModule` dictionary in its Info.plist (name, summary, symbol,
URL scheme, whether it is a login item). The launcher talks to it over `<scheme>://settings`, `quit` and
`login-item?on=1|0`; a module keeps its own settings in `~/Library/Application Support/Spells/<scheme>/settings.json`
and never opens another module's data. Shared code lives in `SpellsKit` (identifiers, log, keychain, paths, settings
files) and `SpellsUI` (design primitives, module windows and URL verbs); each module's views are a library
(`RewindUI`, `ScryUI`, `IncantUI`, `TransmuteUI`, `WardUI`) used by both the module's app and the hub.

## Privacy model

Time-tracking data is stored locally. Depending on which helpers you enable, the app can read window titles, browser URLs, microphone/system audio, and calendar metadata. Optional AI features send data to configured services: TypeSafe for activity classification, ElevenLabs for speech transcription, Cerebras for dictation correction, and Claude CLI for summaries and answers. Standup generation is off by default; when enabled it can read local Claude transcripts and meeting notes. Proof anchoring contacts DigiCert/FreeTSA with a chain digest, not raw activity records. Incant keeps your last 200 dictations in a local file only you can read (`incant/history.jsonl`, for "Paste last dictation"); delete the file to clear it. Scry keeps a processed call's audio for 7 days (`scry/kept`), so a call can be transcribed again, then deletes it.

No real user database, recordings, transcripts, exports, API keys, or private planning history are included in this public snapshot.

## Scry: push call items to a team vault

Off by default. After a call, Claude picks out what your team needs from the transcript and says where each item goes in a shared Obsidian vault. The pill offers "Push N items". Nothing is written until you click it. A write only adds a note or a section at the end of a note, with a source line. Sensitive numbers, passwords and keys become `[removed]`.

Each person keeps their own config. Set it in Scry's settings page, or put it in a JSON file and import it:

```json
{
  "scry_ops_push": "1",
  "scry_ops_vault": "~/Obsidian/team-ops",
  "scry_ops_sources": "~/Documents/Gemini notes\n~/Documents/Notetaker",
  "scry_ops_slack_user": "U0123456789",
  "scry_ops_rules": "- deal: a property, lead or transaction, and its status.\n- decision: something the team decided.\n- ask: something someone asked me to do."
}
```

```sh
spellsctl settings scry import my-scry.json
spellsctl scry ops "<a transcript.md>" --vault <a copy of the vault>   # see the items first
```

| Key | Meaning | Default |
|---|---|---|
| `scry_ops_push` | `1` turns the step on | `0` |
| `scry_ops_vault` | The vault folder (full path or `~/…`) | empty: off |
| `scry_ops_sources` | Other folders to watch for transcripts, one per line | none |
| `scry_ops_slack_user` | Slack member ID that gets a DM after a push | none |
| `scry_ops_rules` | What to look for, one `kind: description` per line | deal, document, decision, process, person, number, ask |

The vault's own `AGENTS.md` sets folders and frontmatter. The Slack DM also needs a bot token with `chat:write`, in `SLACK_BOT_TOKEN` (`~/Library/Application Support/Spells/.env`) or the Keychain item `slack-bot-token`.

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

## Releases and the catalog

The launcher reads `catalog.json` from the newest GitHub release (one entry per module: its manifest
fields, version, zip URL and SHA-256), downloads a module's zip, checks the hash, and only installs an
app whose signature is Apple-issued for the Spells team. Updates replace the app in place (quit, old copy
to the Trash, new copy in, relaunch); Remove quits it, turns its login item off and trashes it. Data under
`~/Library/Application Support/Spells` is never touched.

```sh
scripts/build.sh
scripts/release.sh --publish "v$(cat VERSION)"   # zips dist/*.app, writes catalog.json, creates the GitHub release
scripts/release.sh --base-url "file://$PWD/dist/release"   # a local catalog for testing
```

Every app, the launcher included, also checks the catalog for itself 30 s after launch and every six
hours. When its entry is newer it asks "Update / Later" (Later snoozes a day; a Scry recording or an
Incant dictation defers the question). Update downloads, verifies, swaps its own bundle and relaunches.

Every app carries the one suite version in `VERSION`, stamped in by `scripts/build.sh`. A release must be
`v<VERSION>` from a clean, pushed commit; publishing then moves `VERSION` to the next patch number, so a
development build never shares a number with the release before it.

To test against a local or forked catalog, put its URL in `~/Library/Application Support/Spells/spells/settings.json`
as `catalog_url`. Modules are signed with an Apple Development certificate for now; a Developer ID
certificate and notarization are needed before another Mac will run a downloaded module.

## Repository note

This repository starts from a clean source snapshot with fresh git history. Private planning documents and personal fixture data were removed or replaced with example data. App identifiers and data paths are preserved; do not run two tracker installations against the same database.

## Development hygiene

Keep personal settings and credentials in local configuration, never in source or tests. Use fictional demo data. Databases, `.env*`, recordings, exports, and signing keys must not be committed; inspect `git diff --cached` before pushing. Run `gitleaks git` if you have Gitleaks installed. Secret scanning cannot detect every kind of private information.

## License

MIT. See `LICENSE`. Third-party notices are in `THIRD_PARTY_NOTICES.md`.
