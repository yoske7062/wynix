# Third-party notices

WYNIX's source code and small installer application do not contain Steam, Windows games, Sikarugir engines/templates, Wine, or D3DMetal. The installer downloads fixed upstream releases directly to the user's Mac.

WYNIX is an independent, unofficial community project. It is not affiliated with, endorsed by, sponsored by, or approved by Valve Corporation, Apple Inc., or the Sikarugir project. Steam and the Steam logo are trademarks and/or registered trademarks of Valve Corporation in the United States and/or other countries. This project does not use the Steam logo or Valve's official design assets.

- The setup orchestration was informed by `mirpo/windows-steam-on-apple-silicon`, released under CC0-1.0. The CC0 grant covers that repository's files only.
- Sikarugir components have their own mixed licensing. Its modified Configure component is described as LGPL-2.1, while its launcher, creator, master wrapper, engines, and renderer payloads are not covered by that LGPL grant. They are not relicensed by this project.
- D3DMetal is proprietary Apple software. The included Apple license in the upstream Sikarugir template restricts distribution to non-commercial purposes and limits permitted use. This project's MIT license grants no rights to D3DMetal.
- D3DMetal 4.0b3 (Apple Game Porting Toolkit) is redistributed unmodified, with Apple's License, Acknowledgements and Read Me files, for non-commercial use under Apple's license. It is downloaded on demand from the WYNIX site and verified by SHA-256.
- Wine 11 engine (Whisky Libraries v4.8.3, wine-11.19, from the frankea/Whisky release) is downloaded on demand and verified by SHA-256, never bundled. Wine is licensed under LGPL-2.1; its source is at https://gitlab.winehq.org/wine/wine and the Whisky build's source at https://github.com/frankea/Whisky. DXMT 0.74 (MIT license, source at https://github.com/3Shain/dxmt) comes from the Sikarugir template and is copied unmodified into a local clone of the engine.
- Steam and games are proprietary to Valve and their respective publishers. They are not redistributed. Users download Steam from Valve and must own or otherwise be licensed to use each game.

Upstream references:

- https://github.com/mirpo/windows-steam-on-apple-silicon
- https://github.com/Sikarugir-App/Sikarugir
- https://github.com/frankea/Whisky
- https://github.com/3Shain/dxmt
- https://store.steampowered.com/subscriber_agreement/
