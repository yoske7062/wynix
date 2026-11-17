#!/bin/bash
# Fake game (offscreen CAMetalLayer) with the built wynix_upscale.dylib injected: the hook must
# engage (game renders at its own 1600x900 while the layer is sized to the 2560x1440 screen, capped to 1920x1080), and every frame must complete without GPU errors.
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
# Output is capped at 1920x1080 even on a 2560x1440 "screen" (log line shows the real output).
cap="$(WYNIX_UPSCALE_LOG=1 WYNIX_UPSCALE_ANY_LAYER=1 WYNIX_UPSCALE_OUTPUT=2560x1440 "$tmp/harness" 100 1600 900 2>&1)"
echo "$cap"; [[ "$cap" == *"upscaling 1600x900 -> 1920x1080"* && "$cap" == *"render 1600x900 frames 100 errors 0"* ]]
# Game already at screen size: pure passthrough.
same="$(WYNIX_UPSCALE_ANY_LAYER=1 WYNIX_UPSCALE_OUTPUT=2560x1440 "$tmp/harness" 100 2560 1440)"
echo "$same"; [[ "$same" == "render 2560x1440 frames 100 errors 0"* ]]
# Non-Wine layer without ANY_LAYER: untouched.
off="$(WYNIX_UPSCALE_OUTPUT=2560x1440 "$tmp/harness" 100 1600 900)"
echo "$off"; [[ "$off" == "render 1600x900 frames 100 errors 0"* ]]
# Label on: same render size, no GPU errors (label blit shares the game's command buffer).
lab="$(WYNIX_UPSCALE_LABEL=1 WYNIX_UPSCALE_ANY_LAYER=1 WYNIX_UPSCALE_OUTPUT=2560x1440 "$tmp/harness" 500 1600 900)"
echo "$lab"; [[ "$lab" == "render 1600x900 frames 500 errors 0"* ]]
# Metal 4 presentation (D3DMetal 4.0): waitForDrawable / commit / signalDrawable / present on an MTL4 queue.
# Skipped when this macOS has no Metal 4 (harness exits 4).
set +e
m4="$(HARNESS_MTL4=1 WYNIX_UPSCALE_LOG=1 WYNIX_UPSCALE_ANY_LAYER=1 WYNIX_UPSCALE_OUTPUT=2560x1440 "$tmp/harness" 300 1600 900 2>&1)"; rc=$?
set -e
echo "$m4"
if [[ $rc == 4 ]]; then echo "MTL4 unavailable: skipped"
else [[ "$m4" == *"upscaling 1600x900 -> 1920x1080"* && "$m4" == *"Metal 4 scaler ready"* && "$m4" == *"render 1600x900 frames 300 errors 0"* && "$m4" != *"disabled"* ]]; fi
# Benchmark recording: header + one interval per frame, with Boost off (timing only) and on.
for up in 0 1; do
  f="$tmp/bench$up.txt"; rm -f "$f"
  if [[ $up == 1 ]]; then unset WYNIX_UPSCALE; export WYNIX_UPSCALE=1; else unset WYNIX_UPSCALE; fi
  WYNIX_BENCH_FILE="$f" WYNIX_UPSCALE_ANY_LAYER=1 WYNIX_UPSCALE_OUTPUT=2560x1440 "$tmp/harness" 300 1600 900 >/dev/null
  head -1 "$f"; [[ "$(head -1 "$f")" == "# wynix-bench v1 in="*"upscale=$up d3dmetal="* ]]
  [[ "$(wc -l < "$f")" -ge 290 ]]
done
# Folder form (trailing slash): one "<epoch>-<pid>.txt" file is created inside it.
WYNIX_BENCH_FILE="$tmp/benchdir/" WYNIX_UPSCALE_ANY_LAYER=1 WYNIX_UPSCALE_OUTPUT=2560x1440 "$tmp/harness" 200 1600 900 >/dev/null
[[ "$(head -1 "$tmp"/benchdir/*.txt)" == "# wynix-bench v1"* ]]
