# Wax for ICARUS

Wax lets you write mods for ICARUS in Lua. A mod is a folder with one Lua file. Save the file while the game
runs and the mod reloads in place.

This is an early version. It is for ICARUS on Steam, on Windows.

- Documentation: https://wax-icarus.duckdns.org/
- Mods: https://wax-icarus.duckdns.org/mods/
- Editor support for VS Code: https://marketplace.visualstudio.com/items?itemName=RobertCincotta.wax-icarus

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

## Source

Wax is MIT licensed. The code in this repository is the code that ships in the release zip.

```
runtime/     Wax itself, in Lua. Scripts/wax holds the framework: core, gui, engine, world, mods, data.
editor/      The VS Code extension, in plain JavaScript, with the Lua type definitions it bundles.
installer/   The .cmd files and the PowerShell script that put Wax into the game folder.
mods/        Mods written on top of Wax. Hello is the example in the zip; Entity ESP is on the mods page.
licenses/    The licences of the pieces Wax bundles but did not write.
```

To work on Wax, copy `runtime` over `ue4ss\Mods\Wax` in an installed game, keeping your own `mods` and
`saved` folders. Saving a file reloads it in the running game, so there is nothing to build. The extension
runs the same way: open `editor` in VS Code and press F5.

Three things in the release zip are not in this repository:

- `bin/waxco.dll`, the small native helper. Its source is not published yet.
- UE4SS and `dwmapi.dll`. They are [someone else's project](https://github.com/UE4SS-RE/RE-UE4SS) and the zip
  carries them so you install nothing else.
- `assets/lucide`, 1573 icon images generated from the Lucide set.

## Help

The documentation starts at https://wax-icarus.duckdns.org/docs/. Problems and ideas go in this
repository's Issues.

## Licences

Wax is under the MIT licence, in `LICENSE`. Wax also includes UE4SS and the Lucide icons; their licences are
in the `licenses` folder, both here and in the zip.
