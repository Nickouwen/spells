#!/usr/bin/env bash
# install.sh — copy dist/ to stable paths (TCC + login items key off path + signature):
#   dist/Spells.app → ~/Applications/Spells.app, dist/spellsctl → ~/.local/bin/spellsctl
# then open the app, which registers + starts the helper. Run scripts/build.sh first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$HOME/Applications"
BIN_DIR="$HOME/.local/bin"

[[ -d "$ROOT/dist/Spells.app" && -x "$ROOT/dist/spellsctl" ]] || { echo "install: run scripts/build.sh first" >&2; exit 1; }

# Refuse a build that isn't signed with the Apple Development identity when one exists: an ad-hoc
# helper silently loses its Accessibility grant (TCC keys off the signature).
if security find-identity -v -p codesigning | grep -q '"Apple Development'; then
  for b in "$ROOT/dist/Spells.app" "$ROOT/dist/Spells.app/Contents/Library/LoginItems/HoursSpell.app" \
           "$ROOT/dist/Spells.app/Contents/Library/LoginItems/Incant.app" \
           "$ROOT/dist/Spells.app/Contents/Library/LoginItems/Scry.app"; do
    sig="$(codesign -dvv "$b" 2>&1)"   # not piped: grep -q + pipefail would SIGPIPE codesign into a false fail
    [[ "$sig" == *$'\n'"Authority=Apple Development"* ]] \
      || { echo "install: $b is not signed with Apple Development — rerun scripts/build.sh (keychain locked?)" >&2; exit 1; }
  done
fi

# Stop the old copies so the new binaries are what runs.
pkill -x HoursSpell || true   # a copy Spells launched directly
pkill -x Incant || true
pkill -x Scry || true
pkill -x Spells || true

mkdir -p "$APP_DIR" "$BIN_DIR"
rm -rf "$APP_DIR/Spells.app"
ditto "$ROOT/dist/Spells.app" "$APP_DIR/Spells.app"
install -m 0755 "$ROOT/dist/spellsctl" "$BIN_DIR/spellsctl"
# Login items launched by launchd run under their job label, so pkill -x above can miss them:
# restart the loaded jobs onto the new binaries (a spell that's switched off isn't loaded; skip it).
for job in dev.nic.spells.hours dev.nic.spells.incant dev.nic.spells.scry; do
  launchctl kickstart -k "gui/$(id -u)/$job" 2>/dev/null || true
done
open "$APP_DIR/Spells.app"

echo "installed $APP_DIR/Spells.app and $BIN_DIR/spellsctl"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: $BIN_DIR is not on PATH" ;; esac
