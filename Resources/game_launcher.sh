#!/bin/bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_ID="$(/usr/bin/plutil -extract SteamAppID raw "$APP_DIR/Contents/Info.plist")"
WRAPPER="$HOME/Applications/Sikarugir/Steam.app"
WRAPPER_LAUNCHER="$WRAPPER/Contents/MacOS/Sikarugir"
GAME_COMMAND="$APP_DIR/Contents/Resources/LaunchGame.bat"
# shellcheck source=localization.sh
source "$APP_DIR/Contents/Resources/localization.sh"

show_alert() {
  MACSTEAM_ALERT_TEXT="$(ui_text "$1")" /usr/bin/osascript \
    -e 'display alert (system attribute "MACSTEAM_ALERT_TEXT") as critical'
}

[[ "$APP_ID" =~ ^[0-9]+$ ]] || exit 2
[[ -x "$WRAPPER_LAUNCHER" && -f "$GAME_COMMAND" ]] || {
  show_alert shortcut_steam_missing
  exit 3
}

# LaunchGame.bat starts Steam with -silent when needed, so only the game window appears.
if ! "$WRAPPER_LAUNCHER" WSS-installer "$GAME_COMMAND" >/dev/null 2>&1; then
  show_alert shortcut_game_start_failed
  exit 5
fi
