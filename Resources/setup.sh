#!/bin/bash
# PROTOTYPE — CC0-derived orchestration based on:
# https://github.com/mirpo/windows-steam-on-apple-silicon
# Downloads third-party components from their official distribution URLs.

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=setup_core.sh
source "$SCRIPT_DIR/setup_core.sh"
# shellcheck source=localization.sh
source "$SCRIPT_DIR/localization.sh"

ENGINE="WS12WineSikarugir10.0_6"
TEMPLATE="Template-1.0.11"
WRAPPER="$HOME/Applications/Sikarugir/Steam.app"
CACHE="$HOME/Library/Application Support/Sikarugir"
APP_CACHE="$HOME/Library/Caches/MacSteamSetup"
ENGINE_ARCHIVE="$CACHE/Engines/${ENGINE}.tar.xz"
TEMPLATE_ARCHIVE="$CACHE/Template/${TEMPLATE}.tar.xz"
ENGINE_SHA256="9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2"
TEMPLATE_SHA256="9fa15479e7ff6abd99c1d07be285fb95f41fc6991586502427152b1f7d6ccb8a"
ENGINE_URL="https://github.com/Sikarugir-App/Engines/releases/download/v1.0/${ENGINE}.tar.xz"
TEMPLATE_URL="https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/${TEMPLATE}.tar.xz"
STEAM_SETUP="$HOME/Applications/Sikarugir/SteamSetup.exe"
STEAM_URL="https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
STEAM_EXE="$WRAPPER/Contents/drive_c/Program Files (x86)/Steam/steam.exe"
STEAM_CLIENT_DLL="$WRAPPER/Contents/drive_c/Program Files (x86)/Steam/steamclient.dll"
PLIST="$WRAPPER/Contents/Info.plist"
OWNER_MARKER="$WRAPPER/Contents/.macsteamsetup-owner"
HTML_CACHE="$WRAPPER/Contents/drive_c/users/$USER/AppData/Local/Steam/htmlcache"
PREFIX_ROOT="$WRAPPER/Contents/SharedSupport/prefix"
LOCK_DIR="$APP_CACHE/setup.lock"
STEAMAPPS="$WRAPPER/Contents/drive_c/Program Files (x86)/Steam/steamapps"
LIBRARY_CACHE="$WRAPPER/Contents/drive_c/Program Files (x86)/Steam/appcache/librarycache"
GAME_SHORTCUTS_DIR="$HOME/Applications/Windows Steam Games"
SHORTCUT_OWNER_TEXT="MacSteamSetup game shortcut owner v1"

progress() { printf '@@PROGRESS|%s|%s\n' "$1" "${2:-}"; }
phase() {
  printf '@@PHASE|%s\n' "$1"
  progress "$(phase_percent "$1")" "$1"
}
message() { printf '@@MESSAGE|%s\n' "$1"; }
fail() { printf '@@ERROR|%s\n' "$1" >&2; exit 1; }
message_key() {
  local key="$1"
  shift
  message "$(ui_text "$key" "$@")"
}
fail_key() {
  local key="$1"
  shift
  fail "$(ui_text "$key" "$@")"
}

open_wrapper() {
  if [[ "${MACSTEAM_TEST_NO_OPEN:-0}" == "1" ]]; then
    return 0
  fi
  /usr/bin/open "$WRAPPER"
}

open_steam_main() {
  open_wrapper
}

steam_is_running() {
  /bin/ps -axo command= | wrapper_launcher_is_running_in "$WRAPPER/Contents/MacOS/Sikarugir"
}

steam_process_candidates() {
  /bin/ps -axo pid=,command= | /usr/bin/awk '
    {
      pid=$1
      $1=""
      sub(/^[[:space:]]+/, "", $0)
      command=tolower($0)
      if (command ~ /^[a-z]:\\/) print pid
    }
  '
}

# Bounds a command that can hang (lsof, wine reg) so Play never waits forever. Usage: with_timeout SECONDS cmd...
with_timeout() { /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$@"; }

process_belongs_to_wrapper() {
  local pid="$1"
  local contents_path
  contents_path="$(cd "$WRAPPER/Contents" && pwd -P)/" || return 1  # missing wrapper must not match "/"
  with_timeout 5 /usr/sbin/lsof -a -p "$pid" -d cwd,txt -Fn 2>/dev/null \
    | /usr/bin/grep -Fq "n$contents_path"
}

steam_process_pids() {
  local pid
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    process_belongs_to_wrapper "$pid" && printf '%s\n' "$pid"
  done < <(steam_process_candidates)
}

wrapper_has_named_process() {
  local process_name
  local contents_path
  local lsof_args=(-a -d cwd -Fn)
  contents_path="$(cd "$WRAPPER/Contents" && pwd -P)/" || return 1  # missing wrapper must not match "/"
  for process_name in "$@"; do
    lsof_args+=(-c "$process_name")
  done
  with_timeout 5 /usr/sbin/lsof "${lsof_args[@]}" 2>/dev/null \
    | /usr/bin/grep -Fq "n$contents_path"
}

steam_client_is_running() {
  wrapper_has_named_process Steam.exe steamwebhelper steamservice \
    || [[ -n "$(steam_process_pids)" ]]
}

steam_runtime_is_running() {
  steam_is_running || steam_client_is_running
}

steam_ui_is_running() {
  wrapper_has_named_process steamwebhelper
}

shortcut_is_owned() {
  local shortcut="$1"
  local app_id="$2"
  local marker="$shortcut/Contents/.macsteamsetup-shortcut-owner"
  local plist="$shortcut/Contents/Info.plist"
  [[ -f "$marker" && "$(<"$marker")" == "$SHORTCUT_OWNER_TEXT" ]] && return 0
  [[ -f "$plist" && -x "$shortcut/Contents/MacOS/GameLauncher" ]] || return 1
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$plist" 2>/dev/null || true)" \
      == "local.macsteam.game.${app_id}" ]] || return 1
  [[ "$(/usr/bin/plutil -extract SteamAppID raw "$plist" 2>/dev/null || true)" == "$app_id" ]]
}

terminate_orphaned_steam_processes() {
  local pids pid
  pids="$(steam_process_pids)"
  [[ -n "$pids" ]] || return 0

  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] && /bin/kill -TERM "$pid" 2>/dev/null || true
  done <<< "$pids"
  for _ in {1..20}; do
    pids="$(steam_process_pids)"
    [[ -z "$pids" ]] && return 0
    /bin/sleep 0.25
  done

  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] && /bin/kill -KILL "$pid" 2>/dev/null || true
  done <<< "$pids"
  for _ in {1..20}; do
    [[ -z "$(steam_process_pids)" ]] && return 0
    /bin/sleep 0.25
  done
  return 1
}

# Runs `wine reg ...` inside the Steam bottle while it is already awake (so Wine's
# auto-start list is not replayed).
steam_bottle_reg() {
  (
    export WINEPREFIX="$PREFIX_ROOT" WINEDEBUG=-all WINEMSYNC=1 WINEESYNC=1
    export DYLD_FALLBACK_LIBRARY_PATH="$WRAPPER/Contents/Frameworks/moltenvkcx:$WRAPPER/Contents/SharedSupport/wine/lib:$WRAPPER/Contents/Frameworks:/usr/lib"
    with_timeout 20 "$WRAPPER/Contents/SharedSupport/wine/bin/wine" reg "$@" >/dev/null 2>&1
  ) || true
}

# Steam re-enables "run at startup" every time it starts. Undo it while it runs; otherwise
# Wine relaunches Steam whenever anything wakes the bottle.
steam_remove_autorun_live() {
  steam_bottle_reg delete 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' /v Steam /f
  steam_bottle_reg add 'HKCU\Software\Valve\Steam' /v SuppressAutoRun /t REG_DWORD /d 1 /f
}

# Waits in the background for Steam to finish starting, then removes its auto-start entry.
steam_remove_autorun_after_start() {
  (
    for _ in {1..120}; do steam_client_is_running && break; /bin/sleep 1; done
    /bin/sleep 20
    steam_client_is_running && steam_remove_autorun_live
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

wrapper_wineserver_running() {
  /usr/bin/pgrep -qf -- "$WRAPPER/Contents/SharedSupport/wine/lib/wine/\.\./\.\./bin/wineserver"  # pgrep never matches itself
}

# Turns Steam's auto-start off without racing Wine: while the bottle's wineserver runs it owns
# the registry (a file edit would be overwritten when it saves), so go through `wine reg`;
# once it has exited, edit user.reg directly (waking the bottle would replay the auto-start).
steam_autorun_off() {
  if wrapper_wineserver_running; then
    steam_remove_autorun_live
  else
    steam_disable_autorun "$PREFIX_ROOT/user.reg"
  fi
}

# Remembers which renderer a cold Steam start used and when (mtime), so Play can tell a stale or
# wrong-renderer Steam from a booting one. Call right after configure_wrapper_plist on a cold start.
renderer_mark="$APP_CACHE/steam-renderer"
# Present only while a Steam started by pre-warm (not by the user or Play) is waiting for a game.
prewarm_mark="$APP_CACHE/steam-prewarm"
PREWARM_SECONDS="${PREWARM_SECONDS:-300}"
record_renderer() {
  /bin/mkdir -p "$APP_CACHE"
  if [[ "$(/usr/bin/plutil -extract DXMT raw "$PLIST" 2>/dev/null || true)" == "1" ]]; then
    printf 'dxmt' > "$renderer_mark"
  else
    printf 'd3dmetal' > "$renderer_mark"
  fi
}

# Last resort for stop: Windows-path processes of the Steam bottle that survived wineserverkill
# (lsof can time out on a busy Wine, so the pid check above may miss them; seen 2026-11-19 with
# Steam + the Rockstar launcher left running after "Close Everything").
kill_leftover_steam_processes() {
  local pids sig
  for sig in TERM KILL; do
    pids="$(/bin/ps -axo pid=,command= | /usr/bin/awk '
      { pid=$1; $1=""; c=tolower($0); sub(/^ +/, "", c) }
      c ~ /^[a-z]:\\/ && (c ~ /\\steam\\/ || c ~ /rockstar games/ || c ~ /steamapps\\common\\/) { print pid }')"
    [[ -z "$pids" ]] && return 0
    /bin/kill -"$sig" $pids 2>/dev/null || true
    /bin/sleep 2
  done
}

stop_wrapper() {
  /bin/rm -f "$renderer_mark" "$prewarm_mark"
  steam_client_is_running && steam_remove_autorun_live
  "$WRAPPER/Contents/MacOS/Sikarugir" WSS-wineserverkill >/dev/null 2>&1 || true
  terminate_orphaned_steam_processes || true
  kill_leftover_steam_processes
  for _ in {1..20}; do
    if ! steam_is_running && ! steam_client_is_running; then
      # wineserver saves the registry as it exits; edit only after that.
      for _ in {1..40}; do wrapper_wineserver_running || break; /bin/sleep 0.25; done
      steam_disable_autorun "$PREFIX_ROOT/user.reg"
      return 0
    fi
    /bin/sleep 0.25
  done
  return 1
}

# After Play: once the game's processes have exited and no game from any Steam library has run
# for STEAM_GRACE_SECONDS, close the Steam that Play started. Keep resources free: the short
# delay only avoids racing a game that relaunches itself.
STEAM_GRACE_SECONDS="${STEAM_GRACE_SECONDS:-5}"

any_steam_game_running() {
  /usr/bin/pgrep -if '^[a-z]:.*steamapps.common.' >/dev/null  # Windows-path games only (not native Mac Steam games); pgrep never matches itself
}

# True when any Wine process of Windows-path style is not one of Steam's own or Wine's services:
# a game may be running even if its path isn't under steamapps\common. Used only to veto a restart.
game_may_be_running() {
  any_steam_game_running && return 0
  /bin/ps -axo command= | /usr/bin/awk '
    { c=tolower($0) }
    c !~ /^[a-z]:\\/ { next }
    { sub(/\.exe.*/, "", c); n=split(c, p, "\\"); b=p[n]
      if (b ~ /^(steam|steamwebhelper|steamservice|wineserver|explorer|services|winedevice|plugplay|rpcss|svchost|conhost|start|cmd)$/) next
      found=1 }
    END { exit !found }'
}

stop_steam_after_game() {
  local install_dir="$1"
  (
    for _ in {1..600}; do
      [[ "$(/bin/ps -axo command=)" == *"common\\${install_dir}"* ]] && break  # no pipe: grep -q + pipefail gave false negatives
      /bin/sleep 1
    done
    idle=0
    while (( idle < STEAM_GRACE_SECONDS )); do
      if any_steam_game_running; then idle=0; else idle=$(( idle + 5 )); fi
      steam_client_is_running || exit 0  # user closed Steam themselves
      /bin/sleep 5
    done
    stop_wrapper
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

create_game_icns() {
  local source="$1"
  local output="$2"
  local work iconset result=0
  [[ -f "$source" && ! -L "$source" ]] || return 1
  work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/macsteam-game-icon.XXXXXX")" || return 1
  iconset="$work/GameIcon.iconset"
  /bin/mkdir -p "$iconset"
  /usr/bin/sips -s format png -z 16 16 "$source" --out "$iconset/icon_16x16.png" >/dev/null || result=1
  /usr/bin/sips -s format png -z 32 32 "$source" --out "$iconset/icon_16x16@2x.png" >/dev/null || result=1
  /usr/bin/sips -s format png -z 32 32 "$source" --out "$iconset/icon_32x32.png" >/dev/null || result=1
  /usr/bin/sips -s format png -z 64 64 "$source" --out "$iconset/icon_32x32@2x.png" >/dev/null || result=1
  /usr/bin/sips -s format png -z 128 128 "$source" --out "$iconset/icon_128x128.png" >/dev/null || result=1
  /usr/bin/sips -s format png -z 256 256 "$source" --out "$iconset/icon_128x128@2x.png" >/dev/null || result=1
  /usr/bin/sips -s format png -z 256 256 "$source" --out "$iconset/icon_256x256.png" >/dev/null || result=1
  /usr/bin/sips -s format png -z 512 512 "$source" --out "$iconset/icon_256x256@2x.png" >/dev/null || result=1
  /usr/bin/sips -s format png -z 512 512 "$source" --out "$iconset/icon_512x512.png" >/dev/null || result=1
  /usr/bin/sips -s format png -z 1024 1024 "$source" --out "$iconset/icon_512x512@2x.png" >/dev/null || result=1
  if (( result == 0 )); then
    /usr/bin/iconutil -c icns "$iconset" -o "$output" || result=1
  fi
  /bin/rm -rf "$work"
  return "$result"
}

# The default library first, then every extra library Steam knows about (deduplicated).
all_steam_libraries() {
  { printf '%s\n' "$STEAMAPPS"
    steam_library_steamapps "$STEAMAPPS/libraryfolders.vdf" "$PREFIX_ROOT"
  } | /usr/bin/awk '!seen[$0]++'
}

# True when Steam lists an external library folder that isn't there (e.g. an unplugged external drive).
games_drive_missing() {
  local library
  while IFS= read -r library; do
    # Libraries inside the bottle's C: drive are not external: a missing one is not an unplugged drive.
    [[ "$library" == "$WRAPPER/Contents/drive_c/"* || "$library" == "$PREFIX_ROOT/drive_c/"* ]] && continue
    [[ -d "$library" ]] || return 0
  done < <(all_steam_libraries)
  return 1
}

steam_installer_is_running() {
  /bin/ps -axo command= | /usr/bin/awk '
    tolower($0) ~ /^[[:space:]]*[a-z]:\\.*steamsetup\.exe/ { found=1 }
    END { exit(found ? 0 : 1) }
  '
}

steam_install_is_complete() {
  [[ -f "$STEAM_EXE" && -f "$STEAM_CLIENT_DLL" ]]
}

steam_setup_is_valid() {
  local installer="$1"
  local size
  [[ -f "$installer" && ! -L "$installer" ]] || return 1
  size="$(/usr/bin/stat -f %z "$installer" 2>/dev/null || printf '0')"
  (( size >= 1048576 )) || return 1
  /usr/bin/file "$installer" | /usr/bin/grep -Eq 'PE32(\+)? executable'
}

configure_steam_english() {
  local wine="$WRAPPER/Contents/SharedSupport/wine/bin/wine"
  local prefix="$WRAPPER/Contents/SharedSupport/prefix"
  [[ -x "$wine" && -d "$prefix" ]] || fail_key steam_language_environment_missing
  (
    export WINEPREFIX="$prefix"
    export DYLD_FALLBACK_LIBRARY_PATH="$WRAPPER/Contents/Frameworks/moltenvkcx:$WRAPPER/Contents/SharedSupport/wine/lib:$WRAPPER/Contents/SharedSupport/wine/lib64:$WRAPPER/Contents/Frameworks:$WRAPPER/Contents/Frameworks/GStreamer.framework/Libraries:/opt/wine/lib:/usr/lib:/usr/libexec:/usr/lib/system"
    "$wine" reg add 'HKCU\Software\Valve\Steam' /v Language /t REG_SZ /d english /f >/dev/null 2>&1
    "$wine" reg add 'HKLM\Software\Wow6432Node\Valve\Steam' /v Language /t REG_SZ /d english /f >/dev/null 2>&1
    "$wine" reg add 'HKLM\Software\Wow6432Node\Valve\Steam\NSIS' /v InstallerLanguage /t REG_SZ /d 1033 /f >/dev/null 2>&1
    # Hide Windows tray icons: on macOS they become menu bar icons that can't be clicked.
    "$wine" reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' /v NoTrayItemsDisplay /t REG_DWORD /d 1 /f >/dev/null 2>&1
  ) || fail_key steam_language_config_failed
  "$WRAPPER/Contents/MacOS/Sikarugir" WSS-wineserverkill >/dev/null 2>&1 || true
}

acquire_setup_lock() {
  /bin/mkdir -p "$APP_CACHE"
  [[ ! -L "$LOCK_DIR" ]] || fail_key unsafe_lock_path
  if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
    local old_pid=""
    [[ -f "$LOCK_DIR/pid" ]] && old_pid="$(<"$LOCK_DIR/pid")"
    if [[ "$old_pid" =~ ^[0-9]+$ ]] && /bin/kill -0 "$old_pid" 2>/dev/null; then
      fail_key installation_already_running
    fi
    /bin/rm -f "$LOCK_DIR/pid"
    /bin/rmdir "$LOCK_DIR" 2>/dev/null || fail_key stale_lock_cleanup_failed
    /bin/mkdir "$LOCK_DIR"
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  trap 'status=$?; [[ -z "${CURL_PID:-}" ]] || /bin/kill "$CURL_PID" 2>/dev/null; [[ -z "${CURRENT_PART:-}" ]] || /bin/rm -f "$CURRENT_PART"; /bin/rm -f "$LOCK_DIR/pid"; /bin/rmdir "$LOCK_DIR" 2>/dev/null || true; exit "$status"' EXIT
  trap 'exit 143' INT TERM  # so the EXIT trap runs and removes the partial download
}

is_configured() {
  [[ -f "$PLIST" ]] || return 1
  [[ "$(/usr/bin/plutil -extract D3DMETAL raw -o - "$PLIST" 2>/dev/null || true)" == "1" \
      || "$(/usr/bin/plutil -extract DXMT raw -o - "$PLIST" 2>/dev/null || true)" == "1" ]] || return 1
  [[ "$(/usr/bin/plutil -extract 'Program Name and Path' raw -o - "$PLIST" 2>/dev/null || true)" == "/Program Files (x86)/Steam/Steam.exe" ]]
}

check_state() {
  if steam_install_is_complete && is_configured; then
    if steam_runtime_is_running; then
      printf '@@STATE|running\n'
    else
      printf '@@STATE|ready\n'
    fi
  elif [[ -d "$WRAPPER" ]]; then
    printf '@@STATE|partial\n'
  else
    printf '@@STATE|not_installed\n'
  fi
}

if [[ "${1:-setup}" == "runtime-status" ]]; then
  if steam_runtime_is_running; then
    printf '@@RUNTIME|running\n'
  else
    printf '@@RUNTIME|stopped\n'
  fi
  exit 0
fi

if [[ "${1:-setup}" == "autorun-off" ]]; then
  steam_autorun_off
  exit 0
fi

if [[ "${1:-setup}" == "check" ]]; then
  # Shortcuts made by older versions carry an old GameLauncher: refresh the ones we own.
  for shortcut in "$GAME_SHORTCUTS_DIR"/*.app; do
    [[ -f "$shortcut/Contents/.macsteamsetup-shortcut-owner" && -x "$shortcut/Contents/MacOS/GameLauncher" ]] || continue
    /usr/bin/cmp -s "$SCRIPT_DIR/game_launcher.sh" "$shortcut/Contents/MacOS/GameLauncher" && continue
    /usr/bin/ditto "$SCRIPT_DIR/game_launcher.sh" "$shortcut/Contents/MacOS/GameLauncher" \
      && /bin/chmod +x "$shortcut/Contents/MacOS/GameLauncher" \
      && /usr/bin/codesign --force --deep --sign - "$shortcut" >/dev/null 2>&1 || true
  done
  check_state
  exit 0
fi

if [[ "${1:-setup}" == "launch" ]]; then
  [[ -f "$OWNER_MARKER" && -x "$WRAPPER/Contents/MacOS/Sikarugir" \
      && -f "$STEAM_EXE" && -f "$STEAM_CLIENT_DLL" && -f "$PLIST" ]] \
    || fail_key installed_steam_not_found
  /bin/rm -f "$prewarm_mark"  # the user opened Steam: it is theirs now, pre-warm must not close it
  configure_wrapper_plist "$PLIST"
  if steam_runtime_is_running; then
    if steam_ui_is_running; then
      open_steam_main || fail_key steam_window_reopen_failed
      printf '@@STATE|running\n'
      message_key steam_window_foregrounded
      exit 0
    fi
    message_key steam_stalled_restarting
    stop_wrapper || fail_key steam_stalled_cleanup_failed
  fi
  phase "launching"
  message_key steam_starting
  steam_autorun_off
  record_renderer
  open_wrapper
  steam_remove_autorun_after_start
  printf '@@STATE|running\n'
  message_key steam_start_requested
  exit 0
fi

# Starts Steam silently in the background so a later Play only hands over the applaunch.
# Does nothing when Steam or any Wine of the bottle is already up, or Steam isn't installed.
if [[ "${1:-setup}" == "prewarm" ]]; then
  [[ -f "$OWNER_MARKER" && -x "$WRAPPER/Contents/MacOS/Sikarugir" \
      && -f "$STEAM_EXE" && -f "$STEAM_CLIENT_DLL" && -f "$PLIST" ]] || exit 0
  if steam_runtime_is_running || wrapper_wineserver_running; then exit 0; fi
  configure_wrapper_plist "$PLIST"
  plist_set "$PLIST" 'Program Flags' string '-silent -nobootstrapupdate -skipinitialbootstrap'
  steam_autorun_off
  record_renderer
  /bin/mkdir -p "$APP_CACHE"
  : > "$prewarm_mark"
  open_wrapper
  steam_remove_autorun_after_start
  # Watcher: ends when Play/Open takes the Steam over (marker gone) or Steam exits; closes it after
  # PREWARM_SECONDS unless a game is running.
  (
    waited=0
    while (( waited < PREWARM_SECONDS )); do
      /bin/sleep 5; waited=$(( waited + 5 ))
      configure_wrapper_plist "$PLIST"  # drop -silent again so Open/Finder starts show the window
      [[ -f "$prewarm_mark" ]] || exit 0
      steam_runtime_is_running || { /bin/rm -f "$prewarm_mark"; exit 0; }
    done
    [[ -f "$prewarm_mark" ]] && ! game_may_be_running && stop_wrapper  # Play may have taken over at the last second
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
  exit 0
fi

# WYNIX quit or stayed hidden: close the Steam that pre-warm started, never one the user opened
# (marker gone) and never while a game runs.
if [[ "${1:-setup}" == "prewarm-stop" ]]; then
  [[ -f "$prewarm_mark" ]] || exit 0
  game_may_be_running && exit 0
  stop_wrapper || true
  exit 0
fi

if [[ "${1:-setup}" == "stop" ]]; then
  phase "stopping"
  message_key steam_stopping
  [[ -x "$WRAPPER/Contents/MacOS/Sikarugir" ]] || fail_key steam_launcher_not_found
  stop_wrapper || fail_key steam_stop_failed
  printf '@@STATE|ready\n'
  message_key steam_stopped
  exit 0
fi

if [[ "${1:-setup}" == "list-games" ]]; then
  found=0
  while IFS= read -r library; do
    [[ -d "$library" ]] || continue
    while IFS= read -r manifest; do
      game="$(read_appmanifest "$manifest" 2>/dev/null || true)"
      [[ -n "$game" ]] || continue
      IFS='|' read -r app_id encoded_name encoded_install_dir <<< "$game"
      [[ "$app_id" =~ ^[0-9]+$ ]] || continue
      [[ "$app_id" == "228980" ]] && continue  # Steamworks Common Redistributables, not a game
      # Only fully installed games (StateFlags bit 4); paused or partial downloads aren't playable.
      state_flags="$(acf_value "$manifest" StateFlags)"
      if [[ "$state_flags" =~ ^[0-9]+$ ]] && (( (state_flags & 4) == 0 )); then continue; fi
      icon_path="$(find_game_icon "$LIBRARY_CACHE" "$app_id" 2>/dev/null || true)"
      printf '@@GAME64|%s|%s|%s|%s\n' \
        "$app_id" "$encoded_name" "$encoded_install_dir" "$(protocol_encode "$icon_path")"
      found=1
      # DLSS support: games that use it ship NVIDIA's runtime next to the executable.
      game_dir="$library/common/$(protocol_decode "$encoded_install_dir")"
      dlss="none"
      if [[ -d "$game_dir" ]]; then
        if [[ -n "$(/usr/bin/find "$game_dir" -maxdepth 5 -iname 'nvngx_dlssg.dll' -print -quit 2>/dev/null)" ]]; then
          dlss="framegen"
        elif [[ -n "$(/usr/bin/find "$game_dir" -maxdepth 5 -iname 'nvngx_dlss.dll' -print -quit 2>/dev/null)" ]]; then
          dlss="dlss"
        fi
      fi
      printf '@@DLSS|%s|%s\n' "$app_id" "$dlss"
    done < <(/usr/bin/find "$library" -maxdepth 1 -type f -name 'appmanifest_*.acf' -print | /usr/bin/sort)
  done < <(all_steam_libraries)
  if (( found == 0 )) && games_drive_missing; then message_key games_drive_missing
  elif (( found == 0 )); then message_key no_installed_games; fi
  exit 0
fi

if [[ "${1:-setup}" == "play" ]]; then
  app_id="${2:-}"
  # Games such as GTA V (Rockstar Launcher) fail without the Windows Documents folder.
  for user_dir in "$WRAPPER/Contents/drive_c/users"/*/; do
    [[ -L "${user_dir%/}" || "$(basename "$user_dir")" == Public ]] && continue
    /bin/mkdir -p "$user_dir"{Documents,Desktop,Downloads,Music,Pictures,Videos} 2>/dev/null || true
  done
  [[ "$app_id" =~ ^[0-9]+$ ]] || fail_key invalid_game_id
  [[ -f "$OWNER_MARKER" && -x "$WRAPPER/Contents/MacOS/Sikarugir" && -f "$STEAM_EXE" ]] \
    || fail_key installed_steam_not_found
  # The game's manifest is in no reachable library but a library folder is missing: the drive is unplugged.
  have_manifest=0
  while IFS= read -r library; do
    [[ -f "$library/appmanifest_${app_id}.acf" ]] && have_manifest=1
  done < <(all_steam_libraries)
  (( have_manifest )) || ! games_drive_missing || fail_key games_drive_missing
  /bin/mkdir -p "$APP_CACHE"
  play_bat="$APP_CACHE/play-${app_id}.bat"
  /usr/bin/sed "s/__STEAM_APP_ID__/$app_id/g" "$SCRIPT_DIR/game_launch.bat.template" > "$play_bat"
  # The bat starts Steam itself with -silent when it isn't running, so only the game shows.
  # $3 = renderer the game needs (d3dmetal|dxmt). Swift already wrote SteamyBoost for it, so the
  # plist can't tell which renderer the RUNNING Steam booted with; a marker written at each cold start can.
  wanted_renderer="${3:-}"
  # No Wine at all: a marker left by a crash or force-quit is stale.
  if ! steam_is_running && ! steam_client_is_running && ! wrapper_wineserver_running; then
    /bin/rm -f "$renderer_mark" "$prewarm_mark"
  fi
  cold_start=1
  if steam_client_is_running; then
    cold_start=0
    started_with="$(/bin/cat "$renderer_mark" 2>/dev/null || true)"
    # Opened from Finder/Dock (no marker): the bottle plist is what it booted with.
    if [[ -z "$started_with" ]]; then
      if [[ "$(/usr/bin/plutil -extract DXMT raw "$PLIST" 2>/dev/null || true)" == "1" ]]; then started_with=dxmt; else started_with=d3dmetal; fi
    fi
    # Switch renderer only when no game may be running; never kill a game in progress.
    if [[ -n "$wanted_renderer" && "$started_with" != "$wanted_renderer" ]]; then
      if game_may_be_running; then
        printf '@@NOTICE|renderer_kept|%s\n' "$app_id"
      else
        stop_wrapper || fail_key steam_stop_failed
        cold_start=1
      fi
    fi
  elif steam_is_running; then
    # Wrapper up, client not ready: Steam may just be slow (network login). Hand over the applaunch
    # and let Steam pick it up; never kill it from here.
    cold_start=0
  fi
  if (( cold_start )); then
    configure_wrapper_plist "$PLIST"
    steam_autorun_off
    record_renderer
  fi
  steam_was_running=$(( 1 - cold_start ))
  # A pre-warmed Steam is ours to close after the game, like a cold start from Play.
  if (( cold_start == 0 )) && [[ -f "$prewarm_mark" ]]; then
    /bin/rm -f "$prewarm_mark"
    steam_was_running=0
  fi
  "$WRAPPER/Contents/MacOS/Sikarugir" WSS-installer "$play_bat" >/dev/null 2>&1 &
  steam_remove_autorun_after_start
  if (( steam_was_running == 0 )); then
    play_dir=""
    while IFS= read -r library; do
      if [[ -f "$library/appmanifest_${app_id}.acf" ]]; then
        play_dir="$(acf_value "$library/appmanifest_${app_id}.acf" installdir)"
        break
      fi
    done < <(all_steam_libraries)
    [[ -n "$play_dir" ]] && stop_steam_after_game "$play_dir"
  fi
  printf '@@STATE|running\n'
  exit 0
fi

if [[ "${1:-setup}" == "create-shortcut" ]]; then
  app_id="${2:-}"
  [[ "$app_id" =~ ^[0-9]+$ ]] || fail_key invalid_game_id
  manifest=""
  while IFS= read -r library; do
    if [[ -f "$library/appmanifest_${app_id}.acf" ]]; then
      manifest="$library/appmanifest_${app_id}.acf"
      break
    fi
  done < <(all_steam_libraries)
  [[ -n "$manifest" ]] || fail_key game_info_not_found
  game="$(read_appmanifest "$manifest")" || fail_key game_info_read_failed
  IFS='|' read -r parsed_id encoded_name encoded_install_dir <<< "$game"
  [[ "$parsed_id" == "$app_id" ]] || fail_key game_id_mismatch
  game_name="$(protocol_decode "$encoded_name")" || fail_key game_name_read_failed
  install_dir="$(protocol_decode "$encoded_install_dir")" || fail_key game_install_read_failed
  safe_name="$(printf '%s' "$game_name" | /usr/bin/tr '/:\r\n\t' '-----')"
  shortcut="$GAME_SHORTCUTS_DIR/${safe_name}.app"
  [[ ! -L "$shortcut" ]] || fail_key unsafe_shortcut_path
  if [[ -e "$shortcut" ]] && ! shortcut_is_owned "$shortcut" "$app_id"; then
    fail_key shortcut_conflict "${safe_name}.app"
  fi
  /bin/mkdir -p "$shortcut/Contents/MacOS" "$shortcut/Contents/Resources"
  printf '%s\n' "$SHORTCUT_OWNER_TEXT" > "$shortcut/Contents/.macsteamsetup-shortcut-owner"
  /usr/bin/ditto "$SCRIPT_DIR/game_launcher.sh" "$shortcut/Contents/MacOS/GameLauncher"
  /usr/bin/ditto "$SCRIPT_DIR/localization.sh" "$shortcut/Contents/Resources/localization.sh"
  /bin/chmod +x "$shortcut/Contents/MacOS/GameLauncher"
  /usr/bin/sed "s/__STEAM_APP_ID__/$app_id/g" \
    "$SCRIPT_DIR/game_launch.bat.template" > "$shortcut/Contents/Resources/LaunchGame.bat"
  icon_path="$(find_game_icon "$LIBRARY_CACHE" "$app_id" 2>/dev/null || true)"
  has_game_icon=0
  if [[ -n "$icon_path" ]] && create_game_icns "$icon_path" "$shortcut/Contents/Resources/GameIcon.icns"; then
    has_game_icon=1
  fi
  plist="$shortcut/Contents/Info.plist"
  /usr/bin/plutil -create xml1 "$plist"
  /usr/bin/plutil -insert CFBundleExecutable -string GameLauncher "$plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "local.macsteam.game.${app_id}" "$plist"
  /usr/bin/plutil -insert CFBundleName -string "$game_name" "$plist"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string 1.1 "$plist"
  /usr/bin/plutil -insert CFBundleVersion -string 2 "$plist"
  /usr/bin/plutil -insert LSUIElement -bool true "$plist"
  /usr/bin/plutil -insert SteamAppID -string "$app_id" "$plist"
  if (( has_game_icon == 1 )); then
    /usr/bin/plutil -insert CFBundleIconFile -string GameIcon "$plist"
  fi
  /usr/bin/codesign --force --deep --sign - "$shortcut" >/dev/null
  printf '@@SHORTCUT|%s\n' "$shortcut"
  message_key shortcut_created "$game_name"
  exit 0
fi

if [[ "${1:-setup}" == "repair" ]]; then
  phase "repairing"
  message_key repairing_login
  [[ -f "$OWNER_MARKER" && -x "$WRAPPER/Contents/MacOS/Sikarugir" ]] \
    || fail_key owned_wrapper_not_found
  if [[ -e "$HTML_CACHE" || -L "$HTML_CACHE" ]]; then
    [[ ! -L "$HTML_CACHE" ]] \
      && path_parent_resolves_within "$PREFIX_ROOT" "$HTML_CACHE" \
      || fail_key unsafe_html_cache
  fi
  "$WRAPPER/Contents/MacOS/Sikarugir" WSS-wineserverkill >/dev/null 2>&1 || true
  if [[ -e "$HTML_CACHE" ]]; then
    /bin/rm -rf "$HTML_CACHE"
  fi
  open_wrapper
  progress 100 repairing
  printf '@@STATE|ready\n'
  message_key login_repaired
  exit 0
fi

# Requirements, Rosetta and the pinned Wine engine + bottle template. Shared by Steam setup and
# create-bottle, so a fresh Mac can make any bottle (Epic, GOG, ...) without installing Steam first.
fetch() {
  local url="$1"
  local destination="$2"
  local expected_sha="$3"
  local label="$4"
  local base_percent="$5"
  local span_percent="$6"
  [[ ! -L "$destination" ]] || fail_key unsafe_download_path "$(basename "$destination")"
  if [[ ! -s "$destination" ]]; then
    local partial total_bytes=0 curl_pid current_bytes=0 current_percent
    partial="$(/usr/bin/mktemp "${destination}.part.XXXXXX")"
    CURRENT_PART="$partial"
    total_bytes="$(/usr/bin/curl --connect-timeout 20 --max-time 30 --fail --silent --show-error --location --head "$url" 2>/dev/null \
      | /usr/bin/awk 'tolower($1) == "content-length:" { value=$2 } END { gsub("\\r", "", value); print value+0 }' || true)"
    if (( total_bytes > 0 )); then
      local free_kb
      free_kb="$(/bin/df -k "$(dirname "$destination")" 2>/dev/null | /usr/bin/awk 'NR==2 {print $4+0}' || true)"
      [[ "$free_kb" =~ ^[0-9]+$ ]] || free_kb=999999999999  # df failed: skip the check
      if (( free_kb < total_bytes / 1024 + 1024 )); then
        /bin/rm -f "$partial"
        fail_key not_enough_space_download "$label"
      fi
    fi
    /usr/bin/curl --connect-timeout 20 --speed-limit 1024 --speed-time 60 --fail --location --retry 3 --silent --show-error --output "$partial" "$url" &
    curl_pid=$!; CURL_PID="$curl_pid"
    while /bin/kill -0 "$curl_pid" 2>/dev/null; do
      current_bytes="$(/usr/bin/stat -f %z "$partial" 2>/dev/null || printf '0')"
      if (( total_bytes > 0 )); then
        current_percent=$(( base_percent + (current_bytes * span_percent / total_bytes) ))
        (( current_percent > base_percent + span_percent )) && current_percent=$(( base_percent + span_percent ))
      else
        current_percent="$base_percent"
      fi
      progress "$current_percent" "$label"
      printf '@@DOWNLOAD|%s|%s|%s\n' "$label" "$current_bytes" "$total_bytes"
      /bin/sleep 0.25
    done
    if ! wait "$curl_pid"; then
      /bin/rm -f "$partial"
      fail_key download_failed "$label"
    fi
    /usr/bin/tar -tf "$partial" >/dev/null 2>&1 \
      || { /bin/rm -f "$partial"; fail_key download_validation_failed "$(basename "$destination")"; }
    [[ "$(/usr/bin/shasum -a 256 "$partial" | /usr/bin/awk '{print $1}')" == "$expected_sha" ]] \
      || { /bin/rm -f "$partial"; fail_key pinned_download_mismatch "$(basename "$destination")"; }
    /bin/mv -n "$partial" "$destination"
    CURRENT_PART=""; CURL_PID=""
  fi
  /usr/bin/tar -tf "$destination" >/dev/null 2>&1 \
    || fail_key download_validation_failed "$(basename "$destination")"
  [[ "$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')" == "$expected_sha" ]] \
    || fail_key cached_download_mismatch "$(basename "$destination")"
  progress "$((base_percent + span_percent))" "$label"
  printf '@@DOWNLOAD|%s|%s|%s\n' "$label" "$(/usr/bin/stat -f %z "$destination")" "$(/usr/bin/stat -f %z "$destination")"
}


prepare_engine() {
  phase "checking"
  message_key checking_requirements
  [[ "$(uname -m)" == "arm64" ]] || fail_key apple_silicon_required
  MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
  (( MACOS_MAJOR >= 14 )) || fail_key macos_14_required
  if ! /usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
    phase "rosetta"
    message_key installing_rosetta
    /usr/sbin/softwareupdate --install-rosetta --agree-to-license \
      || fail_key rosetta_install_failed
  fi
  /usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1 \
    || fail_key rosetta_verify_failed
  FREE_GB="$(df -g "$HOME" | awk 'NR==2 {print $4}')"
  (( FREE_GB >= 5 )) || fail_key disk_space_required

  phase "downloading"
  message_key downloading_components
  mkdir -p "$CACHE/Engines" "$CACHE/Template" "$APP_CACHE" "$HOME/Applications/Sikarugir"

  fetch "$ENGINE_URL" "$ENGINE_ARCHIVE" "$ENGINE_SHA256" "$(ui_text runtime_engine)" 15 20
  fetch "$TEMPLATE_URL" "$TEMPLATE_ARCHIVE" "$TEMPLATE_SHA256" "$(ui_text app_template)" 35 10
}

if [[ "${1:-setup}" == "create-bottle" ]]; then
  bottle_name="${2:-}"
  name_re='^[A-Za-z0-9 _.-]{1,40}$'
  [[ "$bottle_name" =~ $name_re && "$bottle_name" != .* ]] || fail "Invalid bottle name."
  # Bottles always appear in ~/Applications/Sikarugir; STEAMY_BOTTLE_DIR (e.g. a folder on an
  # external SSD) stores the real bottle there and leaves a symlink here.
  bottle_link="$HOME/Applications/Sikarugir/${bottle_name}.app"
  bottle="$bottle_link"
  if [[ -n "${STEAMY_BOTTLE_DIR:-}" ]]; then
    /bin/mkdir -p "$STEAMY_BOTTLE_DIR" || fail "Could not create ${STEAMY_BOTTLE_DIR}."
    bottle="$STEAMY_BOTTLE_DIR/${bottle_name}.app"
  fi
  [[ ! -e "$bottle_link" && ! -L "$bottle_link" && ! -e "$bottle" && ! -L "$bottle" ]] \
    || fail "A bottle named ${bottle_name} already exists."
  acquire_setup_lock
  prepare_engine  # downloads Wine + template on a fresh Mac (checks the pinned SHA-256 either way)
  install_wrapper_atomically "$TEMPLATE_ARCHIVE" "$ENGINE_ARCHIVE" "$TEMPLATE" "$bottle" "$APP_CACHE" \
    || fail "Could not create the bottle."
  bottle_plist="$bottle/Contents/Info.plist"
  plist_set "$bottle_plist" D3DMETAL integer 1
  plist_set "$bottle_plist" SteamyAutoGraphics integer 1
  plist_set "$bottle_plist" LSUIElement bool true
  plist_set "$bottle_plist" CFBundleName string "$bottle_name"
  plist_set "$bottle_plist" CFBundleIdentifier string "local.macsteam.bottle.$(/usr/bin/uuidgen)"
  # The launcher sometimes stays open after creating the prefix (seen on external drives), so
  # wait for the prefix and for Wine to go idle, then close it ourselves.
  "$bottle/Contents/MacOS/Sikarugir" WSS-wineprefixcreate >/dev/null 2>&1 &
  prefix_pid=$!
  for _ in {1..600}; do
    /bin/kill -0 "$prefix_pid" 2>/dev/null || break
    if [[ -f "$bottle/Contents/SharedSupport/prefix/system.reg" && -d "$bottle/Contents/drive_c/windows" ]] \
      && ! /bin/ps -axo command= | /usr/bin/awk -v p="$bottle/Contents/SharedSupport/wine" 'index($0, p) && !/awk/ { f = 1 } END { exit !f }'; then  # awk reads all input (no SIGPIPE) and skips its own argv
      /bin/sleep 2
      /bin/kill -TERM "$prefix_pid" 2>/dev/null || true
      break
    fi
    /bin/sleep 1
  done
  /bin/kill -TERM "$prefix_pid" 2>/dev/null || true  # still open after 10 min: don't wait on it forever
  wait "$prefix_pid" 2>/dev/null || true
  [[ -d "$bottle/Contents/drive_c/windows" ]] || fail "The Windows environment could not be created."
  "$bottle/Contents/MacOS/Sikarugir" WSS-wineserverkill >/dev/null 2>&1 || true
  if [[ "$bottle" != "$bottle_link" ]]; then
    /bin/mkdir -p "${bottle_link%/*}"
    /bin/ln -s "$bottle" "$bottle_link" || fail "Could not link the bottle into Applications."
  fi
  printf '@@BOTTLE|%s\n' "$bottle_link"
  exit 0
fi

acquire_setup_lock

prepare_engine

phase "wrapper"
message_key creating_wrapper
[[ ! -L "$WRAPPER" ]] || fail_key unsafe_wrapper_path
if [[ -d "$WRAPPER" && ! -f "$OWNER_MARKER" ]]; then
  fail_key unowned_wrapper
fi
if [[ ! -d "$WRAPPER" ]]; then
  install_wrapper_atomically \
    "$TEMPLATE_ARCHIVE" "$ENGINE_ARCHIVE" "$TEMPLATE" "$WRAPPER" "$APP_CACHE" \
    || fail_key wrapper_create_failed
fi
progress 55 wrapper

LAUNCHER="$WRAPPER/Contents/MacOS/Sikarugir"
[[ -x "$LAUNCHER" ]] || fail_key generated_launcher_missing

phase "windows"
message_key preparing_windows
if [[ ! -d "$WRAPPER/Contents/drive_c/windows" ]]; then
  if ! with_timeout 900 "$LAUNCHER" WSS-wineprefixcreate; then  # the launcher can stay open after creating the prefix
    "$LAUNCHER" WSS-wineserverkill >/dev/null 2>&1 || true
  fi
fi
[[ -d "$WRAPPER/Contents/drive_c/Program Files (x86)" ]] || fail_key windows_environment_failed

progress 70 windows

phase "steam"
message_key steam_installer_instruction
if ! steam_install_is_complete; then
  [[ ! -L "$STEAM_SETUP" ]] || fail_key unsafe_steam_setup_symlink
  [[ ! -d "$STEAM_SETUP" ]] || fail_key unsafe_steam_setup_directory
  if ! steam_setup_is_valid "$STEAM_SETUP"; then
    partial_setup="$(/usr/bin/mktemp "${STEAM_SETUP}.part.XXXXXX")"
    /usr/bin/curl --connect-timeout 20 --speed-limit 1024 --speed-time 60 --fail --location --retry 3 --silent --show-error --output "$partial_setup" "$STEAM_URL" \
      || { /bin/rm -f "$partial_setup"; fail_key download_failed "Steam"; }
    steam_setup_is_valid "$partial_setup" || { /bin/rm -f "$partial_setup"; fail_key steam_setup_validation_failed; }
    /bin/mv "$partial_setup" "$STEAM_SETUP"
  fi
  printf '@@ACTION|steam_installer\n'
  "$LAUNCHER" WSS-installer "$STEAM_SETUP" &
  installer_launcher_pid=$!
  installer_deadline=$((SECONDS + 1800))
  while /bin/kill -0 "$installer_launcher_pid" 2>/dev/null; do
    steam_exists=0
    installer_running=0
    steam_install_is_complete && steam_exists=1
    steam_installer_is_running && installer_running=1
    if [[ "$(installer_decision "$steam_exists" "$installer_running")" == "finish" ]]; then
      progress 88 steam
      message_key steam_install_confirmed
      "$LAUNCHER" WSS-wineserverkill >/dev/null 2>&1 || true
      break
    fi
    (( SECONDS < installer_deadline )) || fail_key steam_install_timeout
    /bin/sleep 1
  done
  for _ in {1..40}; do
    /bin/kill -0 "$installer_launcher_pid" 2>/dev/null || break
    /bin/sleep 0.25
  done
  if /bin/kill -0 "$installer_launcher_pid" 2>/dev/null; then
    /bin/kill -TERM "$installer_launcher_pid" 2>/dev/null || true
  fi
  wait "$installer_launcher_pid" 2>/dev/null || true
  steam_install_is_complete \
    || fail_key steam_install_failed
fi

phase "configuring"
message_key applying_configuration
[[ -f "$PLIST" ]] || fail_key steam_plist_missing
if [[ ! -f "$PLIST.original" ]]; then
  /usr/bin/ditto "$PLIST" "$PLIST.original"
fi
configure_wrapper_plist "$PLIST"
configure_steam_english
steam_disable_autorun "$PREFIX_ROOT/user.reg"

is_configured || fail_key d3dmetal_verify_failed

phase "ready"
message_key ready_to_launch
open_wrapper
printf '@@STATE|running\n'
