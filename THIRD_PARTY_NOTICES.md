# Third-party notices

WYNIX's source code and small installer application do not contain Steam, Windows games, Sikarugir engines/templates, Wine, or D3DMetal. The installer downloads fixed upstream releases directly to the user's Mac.

WYNIX is an independent, unofficial community project. It is not affiliated with, endorsed by, sponsored by, or approved by Valve Corporation, Apple Inc., or the Sikarugir project. Steam and the Steam logo are trademarks and/or registered trademarks of Valve Corporation in the United States and/or other countries. This project does not use the Steam logo or Valve's official design assets.

- The setup orchestration was informed by `mirpo/windows-steam-on-apple-silicon`, released under CC0-1.0. The CC0 grant covers that repository's files only; see its [`LICENSE`](https://github.com/mirpo/windows-steam-on-apple-silicon/blob/main/LICENSE).
- **Wine (Sikarugir Wine 10.0):** GNU LGPL-2.1. The license text checked at the Wine 10.0 source tag is [`LICENSE`](https://github.com/Sikarugir-App/wine/blob/wine-10.0/LICENSE). The Sikarugir engine release is [`v1.0`](https://github.com/Sikarugir-App/Engines/releases/tag/v1.0).
- **DXMT 0.74:** MIT License. The exact release license is [`LICENSE`](https://github.com/Sikarugir-App/dxmt/blob/v0.74/LICENSE); source release: [`v0.74`](https://github.com/Sikarugir-App/dxmt/releases/tag/v0.74).
- **DXVK 2.3:** zlib/libpng License. The exact release license is [`LICENSE`](https://github.com/Sikarugir-App/dxvk/blob/v2.3/LICENSE); source release: [`v2.3`](https://github.com/Sikarugir-App/dxvk/releases/tag/v2.3).
- **MoltenVK 1.2.10:** Apache License 2.0. The exact release license is [`LICENSE`](https://github.com/Sikarugir-App/MoltenVK/blob/v1.2.10/LICENSE); source release: [`v1.2.10`](https://github.com/Sikarugir-App/MoltenVK/releases/tag/v1.2.10).
- **Sikarugir v1.0:** mixed upstream licensing. The wrapper's Configure component is LGPL-2.1; the launcher, creator, master wrapper, engines, and renderer payloads retain the terms provided by their respective upstream projects. Sikarugir itself has no `v1.0` source tag; its tagged component manifests are [`Template v1.0`](https://github.com/Sikarugir-App/Template/releases/tag/v1.0) and [`Engines v1.0`](https://github.com/Sikarugir-App/Engines/releases/tag/v1.0), with the wrapper source at [`Sikarugir`](https://github.com/Sikarugir-App/Sikarugir). They are not relicensed by this project.
- **Whisky Libraries 4.8.3:** Wine libraries distributed under the GNU LGPL-2.1 and the component licenses included in the archive. The exact tagged release and source archive are [`v4.8.3`](https://github.com/frankea/Whisky/releases/tag/v4.8.3) and [`Libraries.tar.gz`](https://github.com/frankea/Whisky/releases/download/v4.8.3/Libraries.tar.gz); the Wine license at the corresponding upstream source tag is [`LICENSE`](https://github.com/frankea/Whisky/blob/v4.8.3/LICENSE).
- **D3DMetal 4.0b3 / Apple Game Porting Toolkit:** proprietary Apple software under Apple's included license, not MIT or LGPL. WYNIX redistributes it unmodified for non-commercial use with Apple's License, Acknowledgements, and Read Me files. The Apple toolkit license is [`LICENSE`](https://github.com/apple/game-porting-toolkit/blob/main/LICENSE); the D3DMetal archive is downloaded on demand and verified by SHA-256. This project's MIT license grants no rights to D3DMetal.
- Steam and games are proprietary to Valve and their respective publishers. They are not redistributed. Users download Steam from Valve and must own or otherwise be licensed to use each game.

Upstream references:

- https://github.com/mirpo/windows-steam-on-apple-silicon
- https://github.com/Sikarugir-App/Sikarugir
- https://store.steampowered.com/subscriber_agreement/
