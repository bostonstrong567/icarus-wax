Wax @VERSION@ for ICARUS

Wax lets you write mods for ICARUS in Lua. This is an early version.

Docs:           https://wax-icarus.duckdns.org/
Newest version: https://github.com/bostonstrong567/icarus-wax/releases/latest


WHAT IS IN THIS FOLDER

  Install Wax.cmd     Copies Wax into your game.
  Update Wax.cmd      Looks for a newer Wax and installs it.
  Uninstall Wax.cmd   Removes Wax from your game.
  Wax-Setup.ps1       The script those three files run. You don't need to open it.
  game                The files that go into the game folder.
  licenses            The licences of UE4SS and of the Lucide icons.

UE4SS is the script loader Wax runs on. It is in the "game" folder, so you
install nothing else.


INSTALL

Close ICARUS first. Extract the whole zip before you run anything in it.

With the installer:
  Double-click "Install Wax.cmd". It finds the game through Steam and copies
  the files. If it can't find the game, it asks you for the folder. Windows may
  ask you to confirm first, because the file came from the internet.

By hand:
  Copy everything inside the "game" folder into

    ...\steamapps\common\Icarus\Icarus\Binaries\Win64\

  To find that folder, right-click ICARUS in Steam and choose Manage, then
  Browse local files. Open Icarus, then Binaries, then Win64. When you are done,
  dwmapi.dll and the ue4ss folder sit next to Icarus-Win64-Shipping.exe.

Then start the game and press F8. That opens the Wax menu.


YOUR MODS

Mods go in this folder, one folder per mod:

  ...\Binaries\Win64\ue4ss\Mods\Wax\mods

A mod is a folder with an init.lua in it. "Hello" is an example you can read
and change. The docs explain how to write your own.

Wax keeps its settings, and the settings of your mods, in this folder:

  ...\Binaries\Win64\ue4ss\Mods\Wax\saved

There is a VS Code extension for writing mods, "Wax for Icarus"
(id RobertCincotta.wax-icarus). The .vsix file is on the same page as this
download. You can also search for "Wax for Icarus" in the VS Code Marketplace,
but it may not be listed there yet.


UPDATE

Close ICARUS first.

With the installer:
  Double-click "Update Wax.cmd". It asks GitHub for the newest release and
  installs it if it is newer than yours. You can also download the newest zip
  and run its "Install Wax.cmd". Both keep your mods (Wax\mods), your settings
  (Wax\saved) and your UE4SS settings.

By hand:
  Download the newest zip and copy the contents of "game" into Win64 again.
  Say yes when Windows asks to replace files. Your own mods and your settings
  are not in the zip, so they stay. Two things are replaced by the copies from
  the zip: mods\Hello, and the UE4SS settings files (UE4SS-settings.ini,
  mods.txt, mods.json).


REMOVE

Close ICARUS first.

With the installer:
  Double-click "Uninstall Wax.cmd". It removes Wax. It asks before it removes
  your mods and settings, and before it removes UE4SS. Press Enter at a
  question to keep them.

By hand:
  Delete the folder ...\Binaries\Win64\ue4ss\Mods\Wax. Your mods and settings
  are in it, so copy "mods" and "saved" somewhere else first if you want them.
  To remove UE4SS too, delete dwmapi.dll and the ue4ss folder from Win64.


IF YOU ALREADY USE UE4SS

Wax is tested on the UE4SS build in this zip, so the installer puts that build
in. If it finds a different one, it first copies the old files to a folder
inside Win64. The folder's name is ue4ss-backup- followed by the date and time.
If your game already has this build, the installer leaves your UE4SS settings
files as they are. Your other UE4SS mods in ue4ss\Mods are left alone.
