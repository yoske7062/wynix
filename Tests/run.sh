#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/Resources/setup_core.sh"

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

[[ -f "$CORE" ]] || fail "setup_core.sh is missing"
# shellcheck source=../Resources/setup_core.sh
source "$CORE"

previous=-1
for phase in checking rosetta downloading wrapper windows steam configuring ready; do
  current="$(phase_percent "$phase")"
  (( current > previous )) || fail "progress must increase at $phase"
  previous="$current"
done
assert_equal "100" "$(phase_percent ready)" "ready progress"

assert_equal "wait" "$(installer_decision 0 0)" "missing Steam executable"
assert_equal "wait" "$(installer_decision 1 1)" "installer still visible"
assert_equal "finish" "$(installer_decision 1 0)" "installed Steam with closed installer"

launcher_path="/Users/test/Applications/Sikarugir/Steam.app/Contents/MacOS/Sikarugir"
printf '%s\n' "$launcher_path" | wrapper_launcher_is_running_in "$launcher_path" \
  || fail "wrapper launcher should be detected"
if printf '%s\n' '/another/prefix/Sikarugir' | wrapper_launcher_is_running_in "$launcher_path"; then
  fail "unrelated wrapper must not be detected"
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/macsteam-tests.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
plist="$tmp_dir/Info.plist"
cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>D3DMETAL</key><integer>0</integer>
  <key>Program Name and Path</key><string>/nothing.exe</string>
  <key>Program Flags</key><string></string>
  <key>Skip Gecko</key><integer>0</integer>
  <key>Skip Mono</key><integer>0</integer>
</dict></plist>
PLIST

configure_wrapper_plist "$plist"
assert_equal "1" "$(/usr/bin/plutil -extract D3DMETAL raw "$plist")" "D3DMetal enabled"
assert_equal "/Program Files (x86)/Steam/Steam.exe" "$(/usr/bin/plutil -extract 'Program Name and Path' raw "$plist")" "Steam target"
assert_equal "-nobootstrapupdate -skipinitialbootstrap" "$(/usr/bin/plutil -extract 'Program Flags' raw "$plist")" "repeat launch skips blocking bootstrap update"
assert_equal "true" "$(/usr/bin/plutil -extract LSUIElement raw "$plist")" "launcher hidden from Dock"
chmod 444 "$plist"
chmod 555 "$tmp_dir"
configure_wrapper_plist "$plist" \
  || fail "already-correct wrapper settings should not require write permission"
chmod 755 "$tmp_dir"
chmod 644 "$plist"

manifest="$tmp_dir/appmanifest_123.acf"
cat > "$manifest" <<'ACF'
"AppState"
{
  "appid" "123"
  "name" "Example Game"
  "installdir" "ExampleGame"
}
ACF
manifest_record="$(read_appmanifest "$manifest")"
IFS='|' read -r manifest_id manifest_name manifest_dir <<< "$manifest_record"
assert_equal "123" "$manifest_id" "manifest App ID parser"
assert_equal "Example Game" "$(protocol_decode "$manifest_name")" "manifest name parser"
assert_equal "ExampleGame" "$(protocol_decode "$manifest_dir")" "manifest directory parser"

pipe_manifest="$tmp_dir/appmanifest_456.acf"
cat > "$pipe_manifest" <<'ACF'
"AppState"
{
  "appid" "456"
  "name" "Example | Deluxe"
  "installdir" "ExampleDeluxe"
}
ACF
pipe_record="$(read_appmanifest "$pipe_manifest")"
IFS='|' read -r pipe_id pipe_name pipe_dir <<< "$pipe_record"
assert_equal "456" "$pipe_id" "delimiter game App ID"
assert_equal "Example | Deluxe" "$(protocol_decode "$pipe_name")" \
  "protocol fields preserve delimiter characters"
assert_equal "ExampleDeluxe" "$(protocol_decode "$pipe_dir")" "delimiter game install directory"

icon_cache="$tmp_dir/librarycache/123"
mkdir -p "$icon_cache"
touch "$icon_cache/0123456789abcdef0123456789abcdef01234567.jpg"
assert_equal "$icon_cache/0123456789abcdef0123456789abcdef01234567.jpg" \
  "$(find_game_icon "$tmp_dir/librarycache" 123)" "Steam game icon lookup"

template_source="$tmp_dir/template-source/Template-Test.app/Contents/SharedSupport"
mkdir -p "$template_source"
template_archive="$tmp_dir/template.tar"
/usr/bin/tar -cf "$template_archive" -C "$tmp_dir/template-source" Template-Test.app

bad_engine_source="$tmp_dir/bad-engine/not-the-engine"
mkdir -p "$bad_engine_source"
bad_engine_archive="$tmp_dir/bad-engine.tar"
/usr/bin/tar -cf "$bad_engine_archive" -C "$tmp_dir/bad-engine" not-the-engine

wrapper="$tmp_dir/final/Steam.app"
work_root="$tmp_dir/wrapper-work"
mkdir -p "${wrapper%/*}" "$work_root"
if install_wrapper_atomically \
  "$template_archive" "$bad_engine_archive" Template-Test "$wrapper" "$work_root"; then
  fail "invalid engine must not produce a wrapper"
fi
[[ ! -e "$wrapper" ]] || fail "failed wrapper install must leave final path untouched"

good_engine_source="$tmp_dir/good-engine/wswine.bundle/bin"
mkdir -p "$good_engine_source"
touch "$good_engine_source/wine"
good_engine_archive="$tmp_dir/good-engine.tar"
/usr/bin/tar -cf "$good_engine_archive" -C "$tmp_dir/good-engine" wswine.bundle
install_wrapper_atomically \
  "$template_archive" "$good_engine_archive" Template-Test "$wrapper" "$work_root"
[[ -d "$wrapper/Contents/SharedSupport/wine" ]] || fail "atomic wrapper install missing Wine engine"
[[ -f "$wrapper/Contents/.macsteamsetup-owner" ]] || fail "atomic wrapper install missing owner marker"

vdf_dir="$(/usr/bin/mktemp -d)"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"Z:\\\\Volumes\\\\SSD\\\\SteamLibrary"\n\t}\n\t"2"\n\t{\n\t\t"path"\t\t"E:\\\\Games"\n\t}\n}\n' > "$vdf_dir/libraryfolders.vdf"
libraries="$(steam_library_steamapps "$vdf_dir/libraryfolders.vdf" /prefix)"
assert_equal "/prefix/drive_c/Program Files (x86)/Steam/steamapps
/Volumes/SSD/SteamLibrary/steamapps
/prefix/dosdevices/e:/Games/steamapps" "$libraries" "steam library folders"
/bin/rm -rf "$vdf_dir"

reg_dir="$(/usr/bin/mktemp -d)"
printf '%s\n' 'WINE REGISTRY Version 2' \
  '[Software\\Microsoft\\Windows\\CurrentVersion\\Run] 1' '"Steam"="\"C:\\steam.exe\" -silent"' '"Other"="x"' '' \
  '[Software\\Valve\\Steam] 2' '"SuppressAutoRun"=dword:00000000' '"Language"="english"' > "$reg_dir/user.reg"
steam_disable_autorun "$reg_dir/user.reg"
/usr/bin/grep -q '^"Steam"=' "$reg_dir/user.reg" && fail "Steam autorun entry should be removed"
/usr/bin/grep -q '^"Other"="x"' "$reg_dir/user.reg" || fail "other Run entries must stay"
/usr/bin/grep -q '^"SuppressAutoRun"=dword:00000001' "$reg_dir/user.reg" || fail "SuppressAutoRun should be 1"
/usr/bin/grep -q '^"Language"="english"' "$reg_dir/user.reg" || fail "other Steam values must stay"
/bin/rm -rf "$reg_dir"

# Failed downloads must not leave .part files, and fetch() checks free space first.
setup_src="$ROOT/Resources/setup.sh"
[[ "$(/usr/bin/grep -c 'rm -f "\$partial' "$setup_src")" -ge 4 ]] || fail "fetch() must remove its partial file on every failure"
/usr/bin/grep -q 'rm -f "\$partial_setup"; fail_key download_failed "Steam"' "$setup_src" || fail "Steam installer download must clean up and fail_key"
/usr/bin/grep -q 'not_enough_space_download' "$setup_src" || fail "fetch() must check free disk space"
/usr/bin/grep -q 'rm -f "\$CURRENT_PART"' "$setup_src" && /usr/bin/grep -q "trap 'exit 143' INT TERM" "$setup_src" || fail "EXIT trap must remove the partial download, INT/TERM must exit"
/usr/bin/grep -q 'df failed: skip the check' "$setup_src" || fail "df failure must skip the space check"
# Behavior: killed by TERM, the trap pattern removes the partial file.
tmp_part="$(/usr/bin/mktemp)"
CP="$tmp_part" /bin/bash -c 'trap '"'"'status=$?; /bin/rm -f "$CP"; exit "$status"'"'"' EXIT; trap "exit 143" INT TERM; kill -TERM $$; sleep 1' || true
[[ ! -e "$tmp_part" ]] || fail "TERM trap pattern left the partial file"

printf 'PASS: setup core regression tests\n'
bash "$ROOT/Tests/protocol_integration.sh"
bash "$ROOT/Tests/localization.sh"
