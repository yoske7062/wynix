#!/bin/bash
# Wine 11 engine variants: setup.sh relinks the bottle's wine to variants/<renderer>/wine, never while
# the bottle's wineserver runs, and finds that wineserver through the link's real path. Fake dirs only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/relink.XXXXXX")"
trap 'kill $pid 2>/dev/null || true; rm -rf "$tmp"' EXIT
pid=""

# Pull just the three functions out of setup.sh (the file runs on source).
eval "$(/usr/bin/awk '/^(wine_link_target|wrapper_wineserver_running|relink_engine_variant)\(\) \{/ {p=1} p {print} p && /^}/ {p=0}' "$ROOT/Resources/setup.sh")"
declare -F relink_engine_variant >/dev/null || fail "relink_engine_variant missing from setup.sh"

WRAPPER="$tmp/Steam.app"
engine="$tmp/Engines/wine-11.19"
mkdir -p "$WRAPPER/Contents/SharedSupport" "$engine/wine" "$engine/variants/dxmt/wine" "$engine/variants/d3dmetal/wine"
wine="$WRAPPER/Contents/SharedSupport/wine"
target() { /usr/bin/readlink "$wine"; }

ln -s "$engine/wine" "$wine"
relink_engine_variant dxmt;     [[ "$(target)" == "$engine/variants/dxmt/wine" ]] || fail "engine root -> dxmt"
relink_engine_variant d3dmetal; [[ "$(target)" == "$engine/variants/d3dmetal/wine" ]] || fail "dxmt -> d3dmetal"
relink_engine_variant d3dmetal; [[ "$(target)" == "$engine/variants/d3dmetal/wine" ]] || fail "same variant is a no-op"

# A wineserver started from the resolved path (what ps shows with a symlinked engine) blocks the relink.
bash -c "sleep 30; :" "$engine/variants/d3dmetal/wine/lib/wine/../../bin/wineserver" & pid=$!
sleep 0.3
wrapper_wineserver_running || fail "wineserver under the real path not detected"
relink_engine_variant dxmt;     [[ "$(target)" == "$engine/variants/d3dmetal/wine" ]] || fail "relinked while wineserver runs"
kill "$pid"; wait "$pid" 2>/dev/null || true; pid=""
wrapper_wineserver_running && fail "false positive without wineserver"
relink_engine_variant dxmt;     [[ "$(target)" == "$engine/variants/dxmt/wine" ]] || fail "relink after stop"

# Engine without variants and a real (non-link) wine folder stay untouched.
rm "$wine"; mkdir -p "$tmp/old/wine"; ln -s "$tmp/old/wine" "$wine"
relink_engine_variant dxmt;     [[ "$(target)" == "$tmp/old/wine" ]] || fail "engine without variants changed"
rm "$wine"; mkdir "$wine"
relink_engine_variant dxmt;     [[ -d "$wine" && ! -L "$wine" ]] || fail "real folder touched"
echo "PASS: engine relink"
