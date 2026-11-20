#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/Resources/setup_core.sh"
FIXTURES="$ROOT/Tests/fixtures/pure_helpers"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label (expected=$expected actual=$actual)"
}

fixture_decode() {
  /usr/bin/python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.buffer.read()).decode(), end="")'
}

[[ -f "$CORE" ]] || fail "setup_core.sh is missing"
# shellcheck source=../Resources/setup_core.sh
source "$CORE"

manifest_record="$(read_appmanifest "$FIXTURES/appmanifest_valid.acf")"
IFS='|' read -r manifest_id manifest_name manifest_dir <<< "$manifest_record"
assert_equal "123456" "$manifest_id" "fixture appmanifest App ID"
assert_equal "Pure Helper Test" "$(printf '%s' "$manifest_name" | fixture_decode)" "fixture appmanifest name"
assert_equal "PureHelperTest" "$(printf '%s' "$manifest_dir" | fixture_decode)" "fixture appmanifest install directory"

pipe_record="$(read_appmanifest "$FIXTURES/appmanifest_pipe.acf")"
IFS='|' read -r pipe_id pipe_name pipe_dir <<< "$pipe_record"
assert_equal "654321" "$pipe_id" "pipe appmanifest App ID"
assert_equal "Game | Deluxe Edition" "$(printf '%s' "$pipe_name" | fixture_decode)" "pipe appmanifest name"
assert_equal "Game | Deluxe" "$(printf '%s' "$pipe_dir" | fixture_decode)" "pipe appmanifest install directory"

if read_appmanifest "$FIXTURES/appmanifest_invalid.acf" >/dev/null 2>&1; then
  fail "invalid fixture appmanifest must not parse"
fi

libraries="$(steam_library_steamapps "$FIXTURES/libraryfolders.vdf" /prefix)"
assert_equal "/prefix/drive_c/Program Files (x86)/Steam/steamapps
/Volumes/SSD/SteamLibrary/steamapps
/prefix/dosdevices/e:/Games/steamapps" "$libraries" "libraryfolders VDF paths"

printf 'PASS: pure setup helper tests\n'
