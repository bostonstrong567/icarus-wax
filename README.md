# Wax for ICARUS

Wax lets you write mods for ICARUS in Lua. A mod is a folder with one Lua file. Save the file while the game
runs and the mod reloads in place.

This is an early version. It is for ICARUS on Steam, on Windows.

- Documentation: https://wax-icarus.duckdns.org/
- Mods: https://wax-icarus.duckdns.org/mods/
- Security: https://wax-icarus.duckdns.org/docs/security/
- Editor support for VS Code: https://marketplace.visualstudio.com/items?itemName=RobertCincotta.wax-icarus

This repository holds the downloads (under Releases) and the full source of Wax and of the VS Code extension.
You can read every file that ends up in your game, and build the download yourself.

## Install

1. Download the newest `Wax-<version>.zip` from the [latest release](https://github.com/bostonstrong567/icarus-wax/releases/latest).
2. Close ICARUS and extract the whole zip.
3. Double-click `Install Wax.cmd`. It finds the game through Steam and copies the files. It asks one question,
   about the "Add to game" button. Press Enter alone for no.
4. Start ICARUS and press **F8**. The Wax menu opens.

The zip holds everything Wax needs, including UE4SS, the script loader it runs on. `README.txt` in the zip
explains how to install by hand, how to update and how to remove Wax.

## What you get

- A menu in the game (F8) that lists your mods, shows their log and reloads them.
- A library for mods: windows, buttons, sliders, colour pickers, overlays and notifications.
- The game's objects as plain Lua values, with live lists of creatures and players.
- Outlines that show creatures and players through walls, and name tags over them.
- The "Add to game" button on the mods page. It shows you the mod and asks before it downloads anything.
- Mods from the mods page keep themselves up to date, and so does Wax. You can switch that off.

A mod is code. Once it is switched on it can do what any program on your PC can do, and Wax does not fence
it in. A mod Wax has not seen before is listed switched off until you switch it on in the Wax menu. That is
so whether it came from the button, from a zip or from a copy by hand, and whether the game was running or
closed.

If you play with other people, read
[Multiplayer and fair play](https://wax-icarus.duckdns.org/docs/multiplayer/) first.

## What it does on your computer

Nothing is hidden, and each part can be checked in this repository.

| What | Where it goes | What it is |
|---|---|---|
| `dwmapi.dll` and the `ue4ss` folder | `Icarus\Binaries\Win64` in the game folder | [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS), from its own release. The game loads `dwmapi.dll` when it starts because Windows looks for that name next to the game first. That file starts UE4SS. This is how UE4SS is installed in every game. One thing is changed: its three cheat and console mods (`CheatManagerEnablerMod`, `ConsoleCommandsMod`, `ConsoleEnablerMod`) are switched off in `mods.txt` and `mods.json`. |
| `ue4ss\Mods\Wax` | inside that `ue4ss` folder | Wax itself: Lua files, pictures, and two small helpers in `bin`. The Lua files are [`wax/runtime/Scripts`](wax/runtime/Scripts) as they are here. |
| `bin\waxco.dll` | inside `Mods\Wax` | 115 lines of C, [`wax/native/waxco.c`](wax/native/waxco.c). It lets a Lua coroutine call the game and gives Lua a precise clock. It opens no files and no connections. |
| `bin\waxnet.dll` | inside `Mods\Wax` | About 670 lines of C, [`wax/native/waxnet.c`](wax/native/waxnet.c). It downloads newer versions of Wax and of mods that came from the mods page, and checks the signature on each list of files. The one address it can ask is `wax-icarus.duckdns.org`, over HTTPS, and it writes only inside `Mods\Wax\run\net`. The address and the key are fixed in the code. |
| `Wax-Setup.ps1` | stays in the folder you extracted | The installer, [`wax/release/payload/Wax-Setup.ps1`](wax/release/payload/Wax-Setup.ps1). It copies the files above, and removes them again when you uninstall. After copying it closes Wax's folder to the other Windows accounts on the PC. `Update Wax.cmd` asks GitHub for the newest release of this repository and installs only a zip that the release's signed list names. |
| `Wax-Import.ps1` | inside `Mods\Wax` | Handles the "Add to game" button, [`wax/runtime/Wax-Import.ps1`](wax/runtime/Wax-Import.ps1). It takes the mod's id from the link and nothing else, shows you the mod's name, version and author, and asks. After a yes it downloads the mod from the mods page, checks its signature, and puts it in your mods folder, switched off. |
| The registry key `HKCU\Software\Classes\wax` | your own part of the registry | Tells Windows that `wax://` links go to `Wax-Import.ps1`, in a window you can see. It is made only when you say yes to the installer's question. Uninstalling removes it, and so does `reg delete HKCU\Software\Classes\wax /f`. |

Nothing starts with Windows. Wax runs inside the game and only while the game runs. It has no accounts and
sends no usage data.

In the game, Wax uses the network for updates and for nothing else. It asks the catalogue at
`wax-icarus.duckdns.org` whether a newer Wax is out, and, when a mod from the mods page is installed (Recipe
Browser, which comes with Wax, is one), whether that mod has a newer version. It asks shortly after the game
starts, then every six hours. A newer version is downloaded file by file. The list of its files must carry
the signature described below, and each file must match the list. Only then is anything replaced. The
version before is kept. What is sent is the name and version of what is fetched and the version of Wax,
nothing about you or your game. A mod you wrote or copied in yourself is never asked about and never
changed: Wax only updates a folder that holds a `wax.origin` file. The "Add to game" button writes that
file, and the Recipe Browser in the download comes with one.
[What Wax asks the network for](https://wax-icarus.duckdns.org/docs/security/#what-wax-asks-the-network-for)
lists every request and says how to switch it off.

The two scripts above use the network only when you run them. Outside the game folder they write three
things. One is the registry key above, if you said yes. One is `%LOCALAPPDATA%\Wax\import.log`, where
`Wax-Import.ps1` notes each link it was given and what came of it. The last is the download that
`Update Wax.cmd` checks, in your temp folder, which is deleted when the script is done.

Some virus scanners warn about UE4SS because it loads into a game the way a cheat would. Wax adds no such
technique of its own. The downloads carry no Windows code-signing certificate, so Windows may warn when you
run the installer. If you would rather not trust the zip, check it as described below, or build it from this
source.

## How downloads are checked

Every Wax release and every version of a mod on the mods page is signed with one key, ECDSA on the curve
P-256 with SHA-256. The private half is on the owner's PC and nowhere else: not in this repository and not
on the server. The public half is written into `Wax-Setup.ps1`, `Wax-Import.ps1` and `waxnet.c`, and no
setting changes it.

The fingerprint of the key is the SHA-256 of its 64 bytes:

```text
3163547c55f74f12ebf7b1d93ab42f42d3a4ecdbb99ae14e04d390f8f11ccf4c
```

The same fingerprint is in `README.txt` in the zip and on the
[Security page](https://wax-icarus.duckdns.org/docs/security/#what-is-signed). Compare them.

- A release has `Wax-<version>.manifest` beside its zip: one line `<sha256> <size> <file name>` for each
  file, under a first line `release <version>`. `Wax-<version>.manifest.sig` is the signature of that text.
  `Update Wax.cmd` installs only a zip that a signed list names.
- A mod's zip and the list of its files are signed when a person has read the version and accepted it. The
  "Add to game" button and the updater in the game put in nothing without a good signature.
- The site's address is a free dynamic-DNS name, so nothing relies on it for what gets installed. A mod or
  an update from another server would not carry the signature.

The first Wax you download is checked by nobody unless you do it. The Security page has a few lines of
PowerShell that check a zip against the list and the key:
[Check a download by hand](https://wax-icarus.duckdns.org/docs/security/#check-a-download-by-hand).

## What is in this repository

| Folder | What |
|---|---|
| [`wax/runtime`](wax/runtime) | What is copied into the game. `Scripts/main.lua` starts it, `Scripts/wax` is the framework, `assets` the pictures. |
| [`wax/native`](wax/native) | The C source of `waxco.dll` and `waxnet.dll`. |
| [`wax/types`](wax/types) | The definitions the editor reads for completion. The reference pages of the documentation are made from them. The `icarus` folder in it holds the game's own classes, generated by `scripts/gameindex.py` from an object dump of the game. |
| [`wax/lsp`](wax/lsp) | A plugin for the Lua language server, so `require` resolves the way it does in the game. |
| [`wax/vscode`](wax/vscode) | The VS Code extension "Wax for Icarus". Plain JavaScript, no bundler. |
| [`wax/cli`](wax/cli) | Command-line tools that talk to the running game: run Lua, read the log, measure frame time. They need developer mode, see below. |
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
pwsh scripts\Get-Tools.ps1                    # UE4SS, Lua 5.4 (built from lua.org) and the Lua language server, into tools\
pwsh scripts\Test-Workspace.ps1 -Wax          # the tests that need no game
pwsh scripts\Build-WaxNative.ps1              # the two helpers in wax\runtime\bin, if you want your own build of them
pwsh scripts\Build-WaxRelease.ps1 -Unsigned   # build\Wax-<version>.zip, made the same way as the one under Releases
pwsh scripts\Build-WaxExtension.ps1           # build\wax-icarus-<version>.vsix
```

`-Unsigned` is there because only the owner has the signing key. Your zip installs with `Install Wax.cmd`
like any other. `Update Wax.cmd` would not take it as an update.

Wax is tested on one exact build of UE4SS, and UE4SS's own page keeps only its newest experimental build. So
that build is kept here, as the unchanged zip, under the release named `ue4ss-v3.0.1-1152-ge3ba1016`.
`Get-Tools.ps1` takes it from there and checks it against the SHA-256 in `tools.json`.

To work on Wax with the game open, `pwsh scripts\Install-Wax.ps1` links `wax\runtime` into the game instead of
copying it, so a file you change here is the file the game runs.

### Developer mode

A normal install does not run Lua that arrives from outside the game. It does while a file named `dev.txt`
stands in Wax's folder. `wax\runtime` in this repository has that file, so a game linked to it is in
developer mode: the command-line tools and the play button of the extension work, any program that runs as
you can run code in the game, and Wax does not update itself. The download never contains `dev.txt`.

## Help

The documentation starts at https://wax-icarus.duckdns.org/docs/. Problems and ideas go in this
repository's Issues.

A security problem goes there too. An issue is public, so if what you found could be used against players
before it is fixed, write only that you found a security problem and ask how to send the details.

## Licences

Wax is under the MIT licence, see [`LICENSE`](LICENSE). The download also contains UE4SS (MIT) and the Lucide
icons (ISC). Their licences are in the `licenses` folder of the zip.
