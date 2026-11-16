#!/bin/zsh
set -e

SCRIPT_DIR="${0:A:h}"
APP="$SCRIPT_DIR/build/WYNIX.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos14.0 \
  -framework SwiftUI -framework AppKit -framework Combine \
  "$SCRIPT_DIR/MacSteamSetupApp.swift" "$SCRIPT_DIR/Bottles.swift" "$SCRIPT_DIR/Home.swift" "$SCRIPT_DIR/Tutorial.swift" "$SCRIPT_DIR/Updater.swift" \
  -o "$APP/Contents/MacOS/MacSteamSetup"
/usr/bin/strip -x "$APP/Contents/MacOS/MacSteamSetup"
/usr/bin/ditto "$SCRIPT_DIR/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/ditto "$SCRIPT_DIR/Resources/setup.sh" "$APP/Contents/Resources/setup.sh"
/usr/bin/ditto "$SCRIPT_DIR/Resources/setup_core.sh" "$APP/Contents/Resources/setup_core.sh"
/usr/bin/ditto "$SCRIPT_DIR/Resources/localization.sh" "$APP/Contents/Resources/localization.sh"
/usr/bin/ditto "$SCRIPT_DIR/Resources/game_launcher.sh" "$APP/Contents/Resources/game_launcher.sh"
/usr/bin/ditto "$SCRIPT_DIR/Resources/game_launch.bat.template" "$APP/Contents/Resources/game_launch.bat.template"
/usr/bin/ditto "$SCRIPT_DIR/Resources/Logos" "$APP/Contents/Resources/Logos"
/usr/bin/ditto "$SCRIPT_DIR/Resources/en.lproj" "$APP/Contents/Resources/en.lproj"
/usr/bin/ditto "$SCRIPT_DIR/Resources/ko.lproj" "$APP/Contents/Resources/ko.lproj"
/usr/bin/ditto "$SCRIPT_DIR/Assets/AppIcon.icns" "$APP/Contents/Resources/WYNIXIcon.icns"
/usr/bin/ditto "$SCRIPT_DIR/LICENSE" "$APP/Contents/Resources/LICENSE"
/usr/bin/ditto "$SCRIPT_DIR/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
/bin/chmod +x "$APP/Contents/Resources/setup.sh"
# Sign with the stable local identity when it exists (scripts/make_signing_identity.sh), so
# macOS keeps privacy permissions across rebuilds; otherwise fall back to ad-hoc.
SIGN_ID="$(/usr/bin/security find-certificate -c "Steamy Local Signing" -Z 2>/dev/null | /usr/bin/awk '/SHA-1 hash/ {print $3; exit}')"
# STEAMY_ADHOC=1: unsigned test build (no keychain access, e.g. for unattended checks).
[[ "${STEAMY_ADHOC:-0}" == 1 ]] && SIGN_ID=""
/usr/bin/codesign --force --deep --sign "${SIGN_ID:--}" "$APP"
echo "Built: $APP"
