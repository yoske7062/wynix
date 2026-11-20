# Developing WYNIX

## Build

Build the app for an unsigned, local test build with:

```sh
STEAMY_ADHOC=1 ./build.command
```

`build.command` compiles `MacSteamSetupApp.swift`, `Bottles.swift`, `Home.swift`,
`Tutorial.swift`, and `Updater.swift`, builds the Metal upscaler library, copies
the app resources, and writes the bundle to `build/WYNIX.app`
([`build.command`](../build.command)).
The `STEAMY_ADHOC=1` setting clears the signing identity so the build uses
ad-hoc signing instead of relying on a local keychain certificate
([`build.command:36-37`](../build.command)).

## Run checks

Run the complete local check suite with:

```sh
bash scripts/check-all.sh
```

The suite runs the ad-hoc build, the macOS minimum-version check, the setup
regression tests, the updater check, the bottle check, the upscaler harness,
the API check, and the download checksum for the site DMG
([`scripts/check-all.sh`](../scripts/check-all.sh)).
Each step logs failures under `/tmp/wynix-check-<step>.log`
([`scripts/check-all.sh:4-11`](../scripts/check-all.sh)).
The minimum-version check derives the requirement from `Info.plist`
([`scripts/check-minos.sh`](../scripts/check-minos.sh)).

Individual checks can be run from the commands in `scripts/check-all.sh`,
for example:

```sh
bash scripts/check-minos.sh
bash Tests/run.sh
bash Tests/bottles_check.sh
bash Tests/upscaler/run.sh
node Tests/api_check.js
```

The bottle check defaults to `~/Applications/Sikarugir/Steam.app`, while
accepting a bottle path as its first argument
([`Tests/bottles_check.sh`](../Tests/bottles_check.sh)).

## Engine layout

Downloaded and cached engines live under:

```text
~/Library/Application Support/Steamy/Engines/<id>/wine
```

The engine cache is `BottleStore.enginesRoot`, and an engine is discovered only
when `<id>/wine/bin/wine` is executable
([`Bottles.swift:971-986`](../Bottles.swift)).
The bundled Sikarugir Wine remains inside each bottle; switching to another
engine makes the bottle's `Contents/SharedSupport/wine` folder a symlink to the
cached engine and retains the original in `wine.sikarugir`
([`Bottles.swift:958-964`](../Bottles.swift),
[`Bottles.swift:1010-1033`](../Bottles.swift)).

Engine variants use the following layout:

```text
Engines/<id>/variants/{dxmt,d3dmetal}/wine
```

DXMT is selected for MetalFX/Boost and D3DMetal is selected for the normal
graphics configuration ([`Resources/setup_core.sh:56-64`](../Resources/setup_core.sh),
[`MacSteamSetupApp.swift:751-758`](../MacSteamSetupApp.swift)).

## Bottle locations

One bottle is a Sikarugir `.app` wrapper, and each wrapper contains
`Contents/SharedSupport/wine` and `Contents/SharedSupport/prefix`
([`Bottles.swift:8-18`](../Bottles.swift)).
Bottles normally appear under:

```text
~/Applications/Sikarugir/<name>.app
```

That directory is the bottle registry root scanned by the app
([`Bottles.swift:458-488`](../Bottles.swift)).
The managed Steam bottle is
`~/Applications/Sikarugir/Steam.app`
([`Resources/setup.sh:16-21`](../Resources/setup.sh)).

When external-volume storage is selected, a new bottle's real app is stored
under `<volume>/Steamy Bottles/<name>.app`; WYNIX leaves a symlink under
`~/Applications/Sikarugir/<name>.app`
([`Bottles.swift:1624-1639`](../Bottles.swift),
[`Resources/setup.sh:774-815`](../Resources/setup.sh)).
If no external volume is selected, the bottle remains directly under
`~/Applications/Sikarugir`
([`Bottles.swift:1624-1631`](../Bottles.swift)).
