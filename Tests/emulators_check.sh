#!/bin/bash
# Emulator settings logic. --install also downloads both emulators into a throwaway HOME.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/emulators_check"
/usr/bin/swiftc -swift-version 5 -parse-as-library -framework SwiftUI -framework AppKit \
  "$ROOT/Emulators.swift" "$ROOT/Tests/emulators_check.swift" -o "$OUT" 2>&1 | grep -v warning || true
if [[ "${1:-}" == --install ]]; then
  HOMEDIR="$(mktemp -d)"; trap 'rm -rf "$HOMEDIR"' EXIT
  "$OUT" --install "$HOMEDIR"
else
  "$OUT"
fi
