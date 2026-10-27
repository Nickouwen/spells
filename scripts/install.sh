#!/usr/bin/env bash
# install.sh — copy dist/ to stable paths (TCC + login items key off path + signature):
#   dist/Spells.app → ~/Applications/Spells.app (the launcher)
#   dist/{Rewind,Incant,Scry}.app → ~/Applications/Spells/ (the modules; the launcher scans this folder)
#   dist/spellsctl → ~/.local/bin/spellsctl
# then starts Rewind (which registers its tracker), the menu-bar modules that were on, and the launcher.
# This is the dev install for one Mac; other Macs will get modules from the launcher's catalog (next step).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$HOME/Applications"
MOD_DIR="$APP_DIR/Spells"
BIN_DIR="$HOME/.local/bin"
MODULES=(Rewind Incant Scry)

for a in Spells "${MODULES[@]}"; do [[ -d "$ROOT/dist/$a.app" ]] || { echo "install: dist/$a.app missing — run scripts/build.sh first" >&2; exit 1; }; done
[[ -x "$ROOT/dist/spellsctl" ]] || { echo "install: run scripts/build.sh first" >&2; exit 1; }

# Refuse a build that isn't signed with the Apple Development identity when one exists: an ad-hoc
# helper silently loses its Accessibility grant (TCC keys off the signature).
if security find-identity -v -p codesigning | grep -q '"Apple Development'; then
  for b in "$ROOT/dist/Spells.app" "$ROOT/dist/Rewind.app" "$ROOT/dist/Rewind.app/Contents/Library/LoginItems/RewindTracker.app" \
           "$ROOT/dist/Incant.app" "$ROOT/dist/Scry.app"; do
    sig="$(codesign -dvv "$b" 2>&1)"   # not piped: grep -q + pipefail would SIGPIPE codesign into a false fail
    [[ "$sig" == *$'\n'"Authority=Apple Development"* ]] \
      || { echo "install: $b is not signed with Apple Development — rerun scripts/build.sh (keychain locked?)" >&2; exit 1; }
  done
fi

first_run=1; [[ -d "$MOD_DIR" ]] && first_run=0

# Stop the old copies so the new binaries are what runs.
for p in RewindTracker Incant Scry Rewind Spells; do pkill -x "$p" || true; done
# Login items launched by launchd run under their job label; pkill -x above can miss them. The old
# Incant/Scry jobs (login items of the pre-split Spells.app) are gone for good: the modules register themselves now.
for job in dev.nic.spells.hours dev.nic.spells.incant dev.nic.spells.scry; do
  launchctl bootout "gui/$(id -u)/$job" 2>/dev/null || true
done

mkdir -p "$APP_DIR" "$MOD_DIR" "$BIN_DIR"
rm -rf "${APP_DIR:?}/Spells.app"
ditto "$ROOT/dist/Spells.app" "$APP_DIR/Spells.app"
for m in "${MODULES[@]}"; do
  rm -rf "${MOD_DIR:?}/${m:?}.app"
  ditto "$ROOT/dist/$m.app" "$MOD_DIR/$m.app"
done
install -m 0755 "$ROOT/dist/spellsctl" "$BIN_DIR/spellsctl"

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# dist/ shares the installed bundle IDs; drop its Launch Services registrations so lookups by identifier
# (launchd, TCC, `open -b`, the launcher's verbs) only ever resolve the installed copies, which are registered.
for a in Spells "${MODULES[@]}"; do "$LSREG" -u "$ROOT/dist/$a.app" >/dev/null 2>&1 || true; done
"$LSREG" -f "$APP_DIR/Spells.app" >/dev/null 2>&1 || true
for m in "${MODULES[@]}"; do "$LSREG" -f "$MOD_DIR/$m.app" >/dev/null 2>&1 || true; done

# Rewind registers + starts its tracker. A menu-bar module comes back if it was set to start at login
# (first run after the split: both, as they were login items before), and keeps itself at login.
open "$MOD_DIR/Rewind.app"
for m in Incant Scry; do
  scheme="$(tr '[:upper:]' '[:lower:]' <<<"$m")"
  if [[ $first_run == 1 ]] || grep -q '"login_item" : "1"' "$HOME/Library/Application Support/Spells/$scheme/settings.json" 2>/dev/null; then
    open -g -a "$MOD_DIR/$m.app" "$scheme://login-item?on=1"
  fi
done
open "$APP_DIR/Spells.app"

echo "installed $APP_DIR/Spells.app, $MOD_DIR/{Rewind,Incant,Scry}.app and $BIN_DIR/spellsctl"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: $BIN_DIR is not on PATH" ;; esac
