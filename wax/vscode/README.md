# Wax for Icarus

Write Lua mods for ICARUS in VS Code. Wax is the scripting framework that runs your mods inside the game. This
extension is the editor side of it.

- Docs: https://wax-icarus.duckdns.org/
- Download Wax: https://wax-icarus.duckdns.org/docs/install/

Wax is for ICARUS on Steam, on Windows.

## What it does

- New Mod asks for a name, a description and a starting point, then creates the mod. New Script adds a file to it.
- `mod.` lists the files and folders of your mod, so `require(mod.extras.Utils)` completes and what the file returns is known.
- You get completion, hover help and checking for everything Wax gives a mod (`ui`, `game`, `task`, `storage`,
  `persist` and the rest). Inside `require("...")` it offers your mod's own files and the other mods as `@Id`.
- The game's own classes are known too. `game.Character.` lists what a player character has, and
  `game:Find("IcarusPlayerState")` gives you an object the editor knows the members of.
- The play button sends the open file, or the selection, to the running game and shows what it returned.
- Reload Mod reloads a mod in the running game.
- The game's log shows in the Output panel. The game's errors show in the Problems panel, on the file and line they
  happened.
- A Mods view in the activity bar lists every mod with its state. Its buttons reload a mod, switch it off or on, and
  open it.
- Type `wax-` in a Lua file for snippets.
- Hover a Wax name such as `ui.Window` for a link to its page in the docs.

## Get Wax

The extension needs Wax in your game. Wax comes as one zip.

1. Open the [install page](https://wax-icarus.duckdns.org/docs/install/) and download the zip. Its name carries
   the version, for example `Wax-0.3.2.zip`.
2. Close ICARUS and unzip the whole file.
3. Double-click `Install Wax.cmd`. It finds the game through Steam and copies the files.
4. Start ICARUS and press **F8**. The Wax menu opens.

You can also install by hand. Copy the contents of the zip's `game` folder into
`...\steamapps\common\Icarus\Icarus\Binaries\Win64\`.

| In the zip | What it is |
|---|---|
| `Install Wax.cmd` | Copies Wax into your game. |
| `Update Wax.cmd` | Looks for a newer Wax and installs it. |
| `Uninstall Wax.cmd` | Takes Wax out of your game. |
| `README.txt` | The steps for installing, updating and removing Wax. |
| `licenses` | The licences of UE4SS and of the Lucide icons. |
| `game` | Everything that goes into `Binaries\Win64`: `dwmapi.dll` and the `ue4ss` folder. |

UE4SS, the script loader Wax runs on, is in the zip, so you install nothing else. Wax itself is at
`ue4ss\Mods\Wax`, and the mod that comes with it, Prospector's Codex, is at `ue4ss\Mods\Wax\mods\RecipeBrowser`.

Installing again over an old copy updates Wax. It keeps your own mods (`Wax\mods`) and your settings (`Wax\saved`).

## Install the extension

- From the Marketplace: open the Extensions view and search for `Wax for Icarus`. Its id is
  `RobertCincotta.wax-icarus`. It may not be listed there yet.
- From the file: the [install page](https://wax-icarus.duckdns.org/docs/install/) has the `.vsix` too. In the
  Extensions view open the `...` menu, pick **Install from VSIX...**, and choose the file. From a terminal:
  `code --install-extension wax-icarus-<version>.vsix`.

VS Code installs the Lua language server (`sumneko.lua`) with it, because the extension builds on it.

The extension only runs in a folder you trust. In VS Code's Restricted Mode it stays off, because it sends Lua from
the open folder into your game.

## Developer mode

The game does not run Lua that another program sends it. Run File, Run Selection, Reload Mod, the log, the Problems
panel and the Mods view all work by sending Lua, so they need developer mode.

Developer mode is one file: `dev.txt` in the Wax folder, beside `Scripts`. Run **Wax: Switch Developer Mode On**
and the extension asks once, then writes that file. **Wax: Switch Developer Mode Off** removes it. Both take effect
at once, also in a game that is already running.

While developer mode is on:

- Any program on this PC can run Lua in the game, and Lua in the game can do what a program can.
- The game reads `run\mods.index.lua`, which lets mods live in folders outside the game.
- Wax does not update itself. `Update Wax.cmd` still updates it.

Switch it off when you are done writing mods. While it is off the status bar says `Wax: developer mode is off`.
Completion, checking, snippets, New Mod and New Script work without it.

A mod the game has not seen before is listed switched off, with or without developer mode. Switch it on in the Mods
view, or on the Mods page of the Wax menu in the game.

## Your first mod

1. Press `Ctrl+Shift+P` and run **Wax: New Mod**.
2. Type a name. The mod's folder gets the name without spaces.
3. Type one line that says what the mod does. You can leave it empty.
4. Pick what `init.lua` starts as:

   | Starting point | What you get |
   |---|---|
   | Empty | One line that prints to the log. |
   | Window with a button | A window in the menu. The button shows a message. |
   | Overlay | A panel that stays on screen while you play. It shows the map you are on. |

5. `init.lua` opens. Start the game. It lists a mod it has not seen before switched off, so switch yours on: press
   **F8**, open the Mods page and switch on Enabled on its card. With developer mode on, the check button beside the
   mod in the Mods view here does the same.
6. A window shows in the menu. An overlay is on screen without the menu.
7. Change the file and save. The mod reloads in the running game. Errors show under the line that caused them.

The name and the description go into the mod's `mod.lua`. New Mod never writes into a folder that already exists.

Open the mods folder, or one mod's folder, in VS Code to get completion and checking. If the new mod is outside the
folders you have open, the extension offers to add it.

The docs take it from here: [Your first mod](https://wax-icarus.duckdns.org/docs/first-mod/) and
[How a mod is built](https://wax-icarus.duckdns.org/docs/mods/).

## Commands

All of them are in the command palette under **Wax**.

| Command | What it does |
|---|---|
| New Mod | Asks for a name, a description and a starting point. Creates `<mods>\<Id>\mod.lua` and `init.lua`. |
| New Script | Adds a script to a mod. A dot in the name puts it in a folder: `extras.Utils` makes `extras\Utils.lua`, loaded with `require(mod.extras.Utils)`. Also the new-file button on each mod in the Mods view. |
| Run File in Game | Sends the open file as it is in the editor, saved or not. Also the play button in the editor title, **Run in ICARUS** in the status bar, and `Ctrl+Alt+Enter`. |
| Run Selection in Game | Sends the selection, or the line the cursor is on. An expression shows its value. `Ctrl+Alt+Enter` does this when text is selected. |
| Stop Scripts Run from the Editor | Removes the windows, tasks and connections that runs left in the game. |
| Reload Mod | Saves the mod's files and reloads it. Also the refresh button in the editor title. |
| Show Log | Opens the **Wax** output channel. Clicking the status bar item does the same. |
| Refresh Mods | Has the game look at its mods folder again. |
| Enable Mod / Disable Mod | Switches a mod on or off in the game. It stays that way after a restart. |
| Open Mod | Opens a mod's `init.lua`. |
| Open Mod Folder in the Explorer | Shows the mod's folder in the Explorer, adding it to the workspace when it is not in it. Use it to add folders, pictures and other files. |
| Set Up Editor Support | Writes the `.luarc.json` files again. The extension also does this by itself. |
| Choose the ICARUS Folder | Opens a folder picker and saves the folder you pick in your settings. |
| Switch Developer Mode On | Asks first, then writes `dev.txt` into the Wax folder. From then on the game runs Lua sent from the editor. |
| Switch Developer Mode Off | Removes `dev.txt`. The game goes back to running no Lua from outside it. |
| Open the Download Page | Opens the page Wax is downloaded from. |
| Open Documentation | Opens the docs. |

## Running code in the game

A file that belongs to a loaded mod runs as that mod. It sees the mod's globals, `require` finds the mod's files,
and `print` writes to the mod's log channel. Any other file runs like a line typed into the in-game console, with
`mods.<Id>` and `exports.<Id>` to reach loaded mods.

What a run sets up (a window, a task loop, a connection) stays in the game until you run the same file again.
The new run removes it first, the way reloading a mod does. **Stop Scripts Run from the Editor** removes all of it.
Code that waits (`task.wait`) keeps running after the result is shown. What it prints later appears in the log.

## The log and the Problems panel

While the game is running, the status bar shows `Wax: 3 mods` and the **Wax** output channel follows the game's
log, one line per entry with its time, level and source. When the game is not running the status bar says so, and
nothing is sent anywhere. When the game runs with developer mode off the status bar says that, and a click on it
asks whether to switch it on.

Errors that name a file and line of a mod become entries in the Problems panel:

| The game logs | Problem on |
|---|---|
| `loading Hello: Hello/init.lua:19: attempt to index a nil value` | `Hello/init.lua`, line 19 |
| `task: Hello/sub/util.lua:7: ...` (an error in a task, a callback or a signal handler) | `Hello/sub/util.lua`, line 7 |
| an error raised inside Wax's own code, with `Hello/init.lua:25:` in its traceback | `Hello/init.lua`, line 25 |
| `Hello: mod.lua: ...mods/Hello/mod.lua:3: '}' expected` | `Hello/mod.lua`, line 3 |

They are cleared when that mod next loads cleanly (`Hello 0.1.0 loaded in 5.0 ms`).

A `require("@Other")` that the game would refuse, because `Other` is not listed under `dependencies` in `mod.lua`,
is marked while you type. A quick fix adds it. A `require` of a file the mod does not have is marked too. Each of
these problems links to the docs page that explains it.

## How it finds the game

The extension needs the Wax folder the game loads (the one holding `Scripts` and `mods`). It looks in this order:

1. The `wax.runtimePath` setting, then the `wax.gamePath` setting. Each takes the ICARUS folder or the Wax folder.
2. An open folder that contains `wax/runtime/Scripts/main.lua` (the Wax development workspace).
3. An open folder that is the Wax folder itself, its `mods` folder, or one mod inside it.
4. Steam. It reads Steam's install path from the registry, tries the default folders, and looks in every library
   that `libraryfolders.vdf` lists.

When it finds no game, or a game without Wax in it, it shows one message with two buttons.

| Button | What it does |
|---|---|
| Choose the ICARUS folder | Opens a folder picker. The folder you pick is saved as `wax.gamePath` in your user settings. |
| Get Wax | Opens the download page. |

The message shows once by itself. After that it shows only when you run a command that needs the game. Once you
have installed Wax, go back to VS Code and the extension finds it.

Mods are created in `luamods` when an open folder has one, otherwise in the Wax folder's `mods`.

## Settings

| Setting | Meaning |
|---|---|
| `wax.gamePath` | The folder ICARUS is installed in. Empty means the extension looks for it. |
| `wax.runtimePath` | The Wax folder, when it is somewhere other than in the game folder. It is tried first. |
| `wax.docsUrl` | The address of the docs. |

## What it writes

- A `.luarc.json` in each mod folder, and one in the mods folder when you have that open and it has none. They
  point the Lua language server at the type definitions and the `require` plugin that come with the extension
  (or at `wax/types` and `wax/lsp` when you work in the Wax development workspace). A `.luarc.json` you wrote
  yourself for a folder of mods is left alone.
- Requests to the game go through small files in the Wax folder's `run` folder, one per second while the game is
  running. The game answers them on its own thread between frames. If the extension has to make `run\in` and
  `run\out`, it leaves them to your Windows account, the system and the administrators, so no other account on the
  PC can put a request there.
- `dev.txt` in the Wax folder, when you switch developer mode on. Switching it off removes the file.
- The folder you choose with **Wax: Choose the ICARUS Folder** goes into your user settings.

## Building it

From the Wax development workspace:

```powershell
pwsh -NoProfile -File scripts\Build-WaxExtension.ps1     # writes build\wax-icarus-<version>.vsix
pwsh -NoProfile -File scripts\Install-WaxExtension.ps1   # installs that file with the "code" command
node --test "wax/vscode/test/*.test.mjs"                 # the tests, which need neither VS Code nor the game
```
