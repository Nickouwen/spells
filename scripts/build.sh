#!/usr/bin/env bash
# build.sh — SwiftPM release build → signed apps in dist/: Spells.app (the launcher), Rewind.app (with
# RewindTracker.app embedded as its login item at Contents/Library/LoginItems/), Incant.app, Scry.app, and
# dist/spellsctl. Then: scripts/install.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DIST="$ROOT/dist"
FLAGS=(-c release --arch arm64)

for product in Spells Rewind RewindTracker Incant Scry spellsctl; do
  swift build "${FLAGS[@]}" --product "$product"
done
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"

LAUNCHER="${DIST:?}/Spells.app"
REWIND="${DIST:?}/Rewind.app"
HELPER="$REWIND/Contents/Library/LoginItems/RewindTracker.app"
INCANT="${DIST:?}/Incant.app"
SCRY="${DIST:?}/Scry.app"
rm -rf "${DIST:?}/Spells.app" "${DIST:?}/Rewind.app" "${DIST:?}/Incant.app" "${DIST:?}/Scry.app" "${DIST:?}/spellsctl"

# bundle <dest.app> <executable>: Contents/{MacOS/<exe>, Info.plist, PkgInfo, Resources/}
bundle() {
  mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
  cp "$BIN/$2" "$1/Contents/MacOS/$2"
  cp "$ROOT/Resources/$2/Info.plist" "$1/Contents/Info.plist"
  [[ -f "$ROOT/Resources/$2/AppIcon.icns" ]] && cp "$ROOT/Resources/$2/AppIcon.icns" "$1/Contents/Resources/"
  for f in "$ROOT/Resources/$2"/MenuBar*.png; do [[ -f "$f" ]] && cp "$f" "$1/Contents/Resources/"; done   # status item glyphs
  printf 'APPL????' > "$1/Contents/PkgInfo"
}
bundle "$LAUNCHER" Spells
bundle "$REWIND" Rewind
# ponytail: no SwiftPM resource bundles are copied — no target declares resources yet. If one does,
# its Bundle.module falls back to the absolute .build path (works on this Mac, not portable).
bundle "$HELPER" RewindTracker
bundle "$INCANT" Incant
bundle "$SCRY" Scry
mkdir -p "$DIST"
cp "$BIN/spellsctl" "$DIST/spellsctl"   # linker ad-hoc signature is enough for a CLI (no TCC)

IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  cat >&2 <<'EOF'

  ##########################################################################
  #  WARNING: no "Apple Development" codesigning identity — signing AD-HOC.  #
  #  TCC grants (Accessibility, Automation) are bound to the signature and  #
  #  will NOT survive a rebuild: expect a re-prompt after every build.      #
  #  Fix: Xcode → Settings → Accounts → Manage Certificates → + Apple Dev.  #
  ##########################################################################

EOF
fi

# Inside-out, Hardened Runtime, no sandbox anywhere. --timestamp=none: no network, local-only app.
sign() { codesign --force --options runtime --timestamp=none --entitlements "$2" --sign "$IDENTITY" "$1"; }
sign "$HELPER" "$ROOT/Resources/RewindTracker/RewindTracker.entitlements"
sign "$REWIND" "$ROOT/Resources/Rewind/Rewind.entitlements"
sign "$INCANT" "$ROOT/Resources/Incant/Incant.entitlements"
sign "$SCRY" "$ROOT/Resources/Scry/Scry.entitlements"
sign "$LAUNCHER" "$ROOT/Resources/Spells/Spells.entitlements"
for app in "$LAUNCHER" "$REWIND" "$INCANT" "$SCRY"; do codesign --verify --deep --strict "$app"; done

echo "built $LAUNCHER, $REWIND, $INCANT, $SCRY (signed: $([[ $IDENTITY == - ]] && echo ad-hoc || echo "Apple Development $IDENTITY")) and $DIST/spellsctl"
