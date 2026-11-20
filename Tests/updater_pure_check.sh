#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/wynix-updater-pure-check"

/usr/bin/swiftc -swift-version 5 -parse-as-library \
  -framework SwiftUI -framework AppKit \
  "$ROOT/Updater.swift" "$ROOT/Tests/updater_pure_check.swift" \
  -o "$OUT"
"$OUT"
