#!/usr/bin/env bash
# release.sh [--base-url URL] [--publish TAG] — after scripts/build.sh: zips every app in dist/ into
# dist/release/<App>-<version>.zip and writes dist/release/catalog.json, the file the launcher reads
# (ModuleCatalog). Each module entry copies the app's SpellsModule manifest and adds version, url and
# sha256. --base-url is where the zips will be served from (default: the GitHub release for TAG);
# --publish creates that GitHub release with gh and uploads everything. A local test:
#   scripts/release.sh --base-url "file://$PWD/dist/release"   then point catalog_url at the json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"; OUT="$DIST/release"
BASE=""; TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) BASE="$2"; shift 2 ;;
    --publish) TAG="$2"; shift 2 ;;
    *) echo "usage: release.sh [--base-url URL] [--publish TAG]" >&2; exit 64 ;;
  esac
done
[[ -d "$DIST/Spells.app" ]] || { echo "release: run scripts/build.sh first" >&2; exit 1; }
if [[ -z "$BASE" ]]; then
  [[ -n "$TAG" ]] || { echo "release: --base-url or --publish TAG is needed to know where the zips will live" >&2; exit 64; }
  BASE="https://github.com/Nickouwen/spells/releases/download/$TAG"
fi
rm -rf "${OUT:?}"; mkdir -p "$OUT"

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

entries=()
for app in "$DIST"/*.app; do
  name="$(basename "$app" .app)"
  version="$(plist "$app" CFBundleShortVersionString)"
  zip="$OUT/$name-$version.zip"
  ditto -c -k --keepParent "$app" "$zip"   # keeps signatures, symlinks and resource forks intact
  sha="$(shasum -a 256 "$zip" | awk '{print $1}')"
  echo "$name $version  $(du -h "$zip" | cut -f1)  $sha"
  [[ -n "$(plist "$app" SpellsModule:Name)" ]] || continue   # the launcher itself isn't a module
  login="$(plist "$app" SpellsModule:LoginItem)"
  entries+=("$(cat <<JSON
    {"bundleID": $(json_str "$(plist "$app" CFBundleIdentifier)"),
     "name": $(json_str "$(plist "$app" SpellsModule:Name)"),
     "summary": $(json_str "$(plist "$app" SpellsModule:Summary)"),
     "symbol": $(json_str "$(plist "$app" SpellsModule:Symbol)"),
     "scheme": $(json_str "$(plist "$app" SpellsModule:Scheme)"),
     "loginItem": $([[ $login == true ]] && echo true || echo false),
     "version": $(json_str "$version"),
     "url": $(json_str "$BASE/$name-$version.zip"),
     "sha256": $(json_str "$sha")}
JSON
)")
done
{ echo '{"modules": ['; (IFS=,; echo "${entries[*]}"); echo ']}'; } | python3 -m json.tool > "$OUT/catalog.json"
echo "wrote $OUT/catalog.json ($(( ${#entries[@]} )) modules, zips served from $BASE)"

if [[ -n "$TAG" ]]; then
  gh release create "$TAG" "$OUT"/*.zip "$OUT/catalog.json" --title "Spells $TAG" --generate-notes
  echo "published https://github.com/Nickouwen/spells/releases/tag/$TAG"
fi
