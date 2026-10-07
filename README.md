# Wax for ICARUS

Wax lets you write mods for ICARUS in Lua. A mod is a folder with one Lua file. Save the file while the game
runs and the mod reloads in place.

This is an early version. It is for ICARUS on Steam, on Windows.

- Documentation: https://wax-icarus.duckdns.org/
- Mods: https://wax-icarus.duckdns.org/mods/
- Editor support for VS Code: https://marketplace.visualstudio.com/items?itemName=RobertCincotta.wax-icarus

This repository holds the downloads (under Releases) and the full source of Wax and of the VS Code extension.
You can read every file that ends up in your game, and build the download yourself.

## Install

1. Download the newest `Wax-<version>.zip` from the [latest release](https://github.com/bostonstrong567/icarus-wax/releases/latest).
2. Close ICARUS and extract the whole zip.
3. Double-click `Install Wax.cmd`. It finds the game through Steam and copies the files.
4. Start ICARUS and press **F8**. The Wax menu opens.

The zip holds everything Wax needs, including UE4SS, the script loader it runs on. `README.txt` in the zip
explains how to install by hand, how to update and how to remove Wax.

## What you get

- A menu in the game (F8) that lists your mods, shows their log and reloads them.
- A library for mods: windows, buttons, sliders, colour pickers, overlays and notifications.
- The game's objects as plain Lua values, with live lists of creatures and players.
- Outlines that show creatures and players through walls, and name tags over them.
- The "Add to game" button on the mods page, which puts a mod straight into your game.
- Mods from the mods page keep themselves up to date. You can switch that off.

## What it does on your computer

Nothing is hidden, and each part can be checked in this repository.

| What | Where it goes | What it is |
|---|---|---|
| `dwmapi.dll` and the `ue4ss` folder | `Icarus\Binaries\Win64` in the game folder | [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS), unchanged, from its own release. The game loads `dwmapi.dll` when it starts because Windows looks for that name next to the game first. That file starts UE4SS. This is how UE4SS is installed in every game. |
| `ue4ss\Mods\Wax` | inside that `ue4ss` folder | Wax itself: Lua files, pictures, and two small helpers in `bin`. The Lua files are [`wax/runtime/Scripts`](wax/runtime/Scripts) as they are here. |
| `bin\waxco.dll` | inside `Mods\Wax` | 115 lines of C, [`wax/native/waxco.c`](wax/native/waxco.c). It lets a Lua coroutine call the game and gives Lua a precise clock. It opens no files and no connections. |
| `bin\waxnet.dll` | inside `Mods\Wax` | About 550 lines of C, [`wax/native/waxnet.c`](wax/native/waxnet.c). It downloads newer versions of mods that came from the mods page. The one address it can ask is `wax-icarus.duckdns.org`, over HTTPS, and it writes only inside `Mods\Wax\run\net`. Both are fixed in the code. |
| `Wax-Setup.ps1` | stays in the folder you extracted | The installer, [`wax/release/payload/Wax-Setup.ps1`](wax/release/payload/Wax-Setup.ps1). It copies the files above, and removes them again when you uninstall. `Update Wax.cmd` asks GitHub for the newest release of this repository. |
| `Wax-Import.ps1` | inside `Mods\Wax` | Handles the "Add to game" button, [`wax/runtime/Wax-Import.ps1`](wax/runtime/Wax-Import.ps1). It downloads the mod you clicked from the mods page, checks the file against its SHA-256, and puts it in your mods folder. |

In the game, Wax uses the network for one thing. When a mod from the mods page is installed (Recipe Browser,
which comes with Wax, is one), it asks the catalogue at `wax-icarus.duckdns.org` whether a newer version is out:
20 seconds after the game starts, then every six hours. A newer version is downloaded file by file, each file is
checked against its SHA-256, and only then is the mod replaced. The version before stays in the mods folder
under a name that starts with `.removed-`. What is sent is the name and version of the mod being fetched and
the version of Wax, nothing about you or your game. A mod you wrote or copied in yourself is never asked about
and never changed: Wax only updates a folder that holds a `wax.origin` file. The "Add to game" button writes
that file, and the Recipe Browser in the download comes with one. The switch "Auto Update" on the
Mods page of the Wax menu turns the replacing off. Wax then only says that a newer version is out. With no such
mod installed, or without `bin\waxnet.dll`, Wax in the game does not use the network at all.

The two scripts above use the network only when you run them. Outside the game folder they write two things.
One is the registry key `HKCU\Software\Classes\wax`, so that the "Add to game" button can open Wax.
Uninstalling removes it. The other is the download itself, in your temp folder, which is deleted when the
script is done.

Some virus scanners warn about UE4SS because it loads into a game the way a cheat would. Wax adds no such
technique of its own. If you would rather not trust the zip, build it from this source as described below.

## What is in this repository

| Folder | What |
|---|---|
| [`wax/runtime`](wax/runtime) | What is copied into the game. `Scripts/main.lua` starts it, `Scripts/wax` is the framework, `assets` the pictures. |
| [`wax/native`](wax/native) | The C source of `waxco.dll` and `waxnet.dll`. |
| [`wax/types`](wax/types) | The definitions the editor reads for completion. The reference pages of the documentation are made from them. The `icarus` folder in it holds the game's own classes, generated by `scripts/gameindex.py` from an object dump of the game. |
| [`wax/lsp`](wax/lsp) | A plugin for the Lua language server, so `require` resolves the way it does in the game. |
| [`wax/vscode`](wax/vscode) | The VS Code extension "Wax for Icarus". Plain JavaScript, no bundler. |
| [`wax/cli`](wax/cli) | Command-line tools that talk to the running game: run Lua, read the log, measure frame time. |
| [`wax/release`](wax/release) | The installer and its tests. |
| [`wax/tests`](wax/tests) | Tests that run without the game (`offline`) and tests that are sent to the running game (`live`). |
| [`luamods`](luamods) | Two mods to read: `RecipeBrowser`, which comes with the download from version 0.2.0, and `EntityESP`. |
| [`wax/examples`](wax/examples) | `Hello`, a small mod to start from. |
| [`scripts`](scripts) | The build and test scripts. |

## Build it yourself

You need Windows, [PowerShell 7](https://github.com/PowerShell/PowerShell), [Node.js](https://nodejs.org/) 22 or
newer, [Python](https://www.python.org/) 3 and gcc (mingw, for example `scoop install mingw`). Everything that
is downloaded stays inside the folder you cloned.

```powershell
pwsh scripts\Get-Tools.ps1              # UE4SS, Lua 5.4 (built from lua.org) and the Lua language server, into tools\
pwsh scripts\Test-Workspace.ps1 -Wax    # the tests that need no game
pwsh scripts\Build-WaxNative.ps1        # the two helpers in wax\runtime\bin, if you want your own build of them
pwsh scripts\Build-WaxRelease.ps1       # build\Wax-<version>.zip, made the same way as the one under Releases
pwsh scripts\Build-WaxExtension.ps1     # build\wax-icarus-<version>.vsix
```

Wax is tested on one exact build of UE4SS, and UE4SS's own page keeps only its newest experimental build. So
that build is kept here, as the unchanged zip, under the release named `ue4ss-v3.0.1-1152-ge3ba1016`.
`Get-Tools.ps1` takes it from there.

To work on Wax with the game open, `pwsh scripts\Install-Wax.ps1` links `wax\runtime` into the game instead of
copying it, so a file you change here is the file the game runs.

## Help

The documentation starts at https://wax-icarus.duckdns.org/docs/. Problems and ideas go in this
repository's Issues.

## Licences

Wax is under the MIT licence, see [`LICENSE`](LICENSE). The download also contains UE4SS (MIT) and the Lucide
icons (ISC). Their licences are in the `licenses` folder of the zip.
