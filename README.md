# WYNIX

<p align="center">
  <img src="Assets/AppIcon.png" width="128" alt="WYNIX icon">
</p>

Play your Windows Steam games on an Apple Silicon Mac. Free, no VM, no CrossOver sub. You hit Play and it just goes.

[Download](https://wynix.app/) · [Report a bug or a game](https://github.com/yoske7062/wynix/issues/new/choose)

## Get it running

1. Grab the DMG from [wynix.app](https://wynix.app/) and drag WYNIX into Applications.
2. Open it once. If macOS complains, go to **System Settings → Privacy & Security → Open Anyway** (one time only, the app isn't notarized yet).
3. Hit **Set Up Steam**, log in, install your games, play.

## What you get

- One-click Steam setup, no terminal stuff
- Auto settings per game (DX11 vs DX12)
- Boost: MetalFX upscaling so heavy games run smoother
- Our own in-game HUD: FPS, CPU, GPU, RAM and temp with green/yellow/red dots
- Games get top priority, Steam downloads stay on the efficiency cores so your Mac doesn't cook
- Built-in benchmark and Mac shortcuts for each game

## Heads up

- Apple Silicon + macOS 14 or newer. No Intel.
- It's Wine under the hood, not Windows. Most games work, anti-cheat games usually don't.
- You need your own Steam account and games.

## For devs

```sh
./build.command          # build
bash scripts/check-all.sh  # build + every test
```

## Credits

Started as a fork of [Mac Steam Setup](https://github.com/heung115/mac-steam-setup) by heung115 (MIT). Runs on Sikarugir/Wine, Apple's D3DMetal and DXMT. Not affiliated with Valve or Apple; Steam is a Valve trademark. Code is [MIT](LICENSE), third-party stuff in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
