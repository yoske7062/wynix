#!/bin/bash
# One command to check WYNIX before a commit. Prints PASS/FAIL per step; exit 1 on any FAIL.
cd "$(dirname "$0")/.." || exit 1
status=0
step() { local name="$1"; shift; if "$@" >/tmp/wynix-check-$name.log 2>&1; then echo "PASS: $name"; else echo "FAIL: $name (see /tmp/wynix-check-$name.log)"; status=1; fi; }
step build env STEAMY_ADHOC=1 ./build.command
step minos bash scripts/check-minos.sh
step tests bash Tests/run.sh
step updater swift Tests/updater_check.swift
step bottles bash Tests/bottles_check.sh
step api node Tests/api_check.js
step dmgsum bash -c 'cd site/downloads && shasum -a 256 -c WYNIX.dmg.sha256'
exit $status
