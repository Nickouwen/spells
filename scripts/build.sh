#!/usr/bin/env bash
# build.sh — SwiftPM release build → signed dist/Spells.app (HoursSpell.app embedded as its login
# item at Contents/Library/LoginItems/) + dist/spellsctl. Then: scripts/install.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DIST="$ROOT/dist"
FLAGS=(-c release --arch arm64)

for product in Spells HoursSpell Incant Scry spellsctl; do
  swift build "${FLAGS[@]}" --product "$product"
done
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"

APP="$DIST/Spells.app"
HELPER="$APP/Contents/Library/LoginItems/HoursSpell.app"
INCANT="$APP/Contents/Library/LoginItems/Incant.app"
SCRY="$APP/Contents/Library/LoginItems/Scry.app"
rm -rf "$APP" "$DIST/spellsctl"

# bundle <dest.app> <executable>: Contents/{MacOS/<exe>, Info.plist, PkgInfo, Resources/}
bundle() {
  mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
  cp "$BIN/$2" "$1/Contents/MacOS/$2"
  cp "$ROOT/Resources/$2/Info.plist" "$1/Contents/Info.plist"
  printf 'APPL????' > "$1/Contents/PkgInfo"
}
bundle "$APP" Spells
cp "$ROOT/Resources/Spells/AppIcon.icns" "$APP/Contents/Resources/"
# ponytail: no SwiftPM resource bundles are copied — no target declares resources yet. If one does,
# its Bundle.module falls back to the absolute .build path (works on this Mac, not portable).
bundle "$HELPER" HoursSpell
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
sign "$HELPER" "$ROOT/Resources/HoursSpell/HoursSpell.entitlements"
sign "$INCANT" "$ROOT/Resources/Incant/Incant.entitlements"
sign "$SCRY" "$ROOT/Resources/Scry/Scry.entitlements"
sign "$APP" "$ROOT/Resources/Spells/Spells.entitlements"
codesign --verify --deep --strict "$APP"

echo "built $APP (signed: $([[ $IDENTITY == - ]] && echo ad-hoc || echo "Apple Development $IDENTITY")) and $DIST/spellsctl"
