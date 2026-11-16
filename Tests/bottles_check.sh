#!/bin/bash
# Parses shortcuts/icons/registry of a real bottle (default: the Steam bottle).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/bottles_check"
/usr/bin/swiftc -swift-version 5 -parse-as-library -framework SwiftUI -framework AppKit \
  "$ROOT/Bottles.swift" "$ROOT/Tests/bottles_check.swift" -o "$OUT"
"$OUT" "${1:-$HOME/Applications/Sikarugir/Steam.app}" "$ROOT/MacSteamSetupApp.swift" "$ROOT/Bottles.swift"
