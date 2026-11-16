#!/bin/bash
# The built binary must run on the oldest macOS in Info.plist (a 26.0 minos would refuse to launch on 14/15).
cd "$(dirname "$0")/.." || exit 1
want="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw Info.plist)"
got="$(/usr/bin/otool -l build/WYNIX.app/Contents/MacOS/MacSteamSetup | /usr/bin/awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
[[ "$got" == "$want" ]] || { echo "minos $got != LSMinimumSystemVersion $want"; exit 1; }
