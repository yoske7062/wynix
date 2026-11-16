#!/bin/bash
# Fake game (offscreen CAMetalLayer) with the built wynix_upscale.dylib injected: the hook must
# engage (game renders at 1600x900), and every frame must complete without GPU errors.
# Also checks the default filter leaves non-Wine layers alone.
set -e
cd "$(dirname "$0")/../.."
lib="$PWD/build/WYNIX.app/Contents/Resources/wynix_upscale.dylib"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
/usr/bin/clang -arch x86_64 -fobjc-arc -framework Metal -framework QuartzCore -framework Foundation Tests/upscaler/harness.m -o "$tmp/harness"
on="$(WYNIX_UPSCALE=1 WYNIX_UPSCALE_ANY_LAYER=1 DYLD_INSERT_LIBRARIES="$lib" "$tmp/harness" 500)"
echo "$on"; [[ "$on" == "render 1600x900 frames 500 errors 0"* ]]
off="$(WYNIX_UPSCALE=1 DYLD_INSERT_LIBRARIES="$lib" "$tmp/harness" 100)"
echo "$off"; [[ "$off" == "render 2560x1440 frames 100 errors 0"* ]]
