#!/bin/bash
# Fake game (offscreen CAMetalLayer) with the built wynix_upscale.dylib injected: the hook must
# engage (game renders at its own 1600x900 while the layer is sized to the 2560x1440 screen), and every frame must complete without GPU errors.
# Also checks the default filter leaves non-Wine layers alone.
set -e
cd "$(dirname "$0")/../.."
lib="$PWD/build/WYNIX.app/Contents/Resources/wynix_upscale.dylib"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
/usr/bin/clang -arch x86_64 -fobjc-arc -framework Metal -framework QuartzCore -framework Foundation Tests/upscaler/harness.m -o "$tmp/harness"
export WYNIX_UPSCALE=1 DYLD_INSERT_LIBRARIES="$lib"
# Game at 1600x900 on a 2560x1440 "screen": upscaled, game renders into a 1600x900 texture.
on="$(WYNIX_UPSCALE_ANY_LAYER=1 WYNIX_UPSCALE_OUTPUT=2560x1440 "$tmp/harness" 500 1600 900)"
echo "$on"; [[ "$on" == "render 1600x900 frames 500 errors 0"* ]]
[[ "$on" == *"layer_size 1600x900" ]]  # layer.drawableSize still reports the game size
# Game already at screen size: pure passthrough.
same="$(WYNIX_UPSCALE_ANY_LAYER=1 WYNIX_UPSCALE_OUTPUT=2560x1440 "$tmp/harness" 100 2560 1440)"
echo "$same"; [[ "$same" == "render 2560x1440 frames 100 errors 0"* ]]
# Non-Wine layer without ANY_LAYER: untouched.
off="$(WYNIX_UPSCALE_OUTPUT=2560x1440 "$tmp/harness" 100 1600 900)"
echo "$off"; [[ "$off" == "render 1600x900 frames 100 errors 0"* ]]
# Label on: same render size, no GPU errors (label blit shares the game's command buffer).
lab="$(WYNIX_UPSCALE_LABEL=1 WYNIX_UPSCALE_ANY_LAYER=1 WYNIX_UPSCALE_OUTPUT=2560x1440 "$tmp/harness" 500 1600 900)"
echo "$lab"; [[ "$lab" == "render 1600x900 frames 500 errors 0"* ]]
