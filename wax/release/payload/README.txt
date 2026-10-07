Wax @VERSION@ for ICARUS

Wax lets you write mods for ICARUS in Lua. This is an early version.

Docs:           https://wax-icarus.duckdns.org/
Newest version: https://wax-icarus.duckdns.org/docs/install/
Source:         https://github.com/bostonstrong567/icarus-wax


WHAT IS IN THIS FOLDER

  Install Wax.cmd     Copies Wax into your game.
  Update Wax.cmd      Looks for a newer Wax and installs it.
  Uninstall Wax.cmd   Removes Wax from your game.
  Wax-Setup.ps1       The script those three files run. It is plain text, so
                      you can read what it does before you run it.
  game                The files that go into the game folder.
  licenses            The licences of UE4SS and of the Lucide icons.

UE4SS is the script loader Wax runs on. It is in the "game" folder, so you
install nothing else.

The three .cmd files start Windows PowerShell with "-ExecutionPolicy Bypass"
for that one run. Without it Windows refuses a script that came out of a
downloaded zip. It changes no setting on your PC.


INSTALL

Close ICARUS first. Extract the whole zip before you run anything in it.

With the installer:
  Double-click "Install Wax.cmd". It finds the game through Steam and copies
  the files. If it can't find the game, it asks you for the folder. Windows may
  ask you to confirm first, because the file came from the internet.

  It asks one question: whether the "Add to game" button on the Wax site may
  open Wax on this PC. Press Enter alone for no. What a yes changes is under
  THE "ADD TO GAME" BUTTON below.

  It also sets who may change Wax's folder. That is under WHO CAN CHANGE WAX'S
  FOLDER below.

By hand:
  Copy everything inside the "game" folder into

    ...\steamapps\common\Icarus\Icarus\Binaries\Win64\

  To find that folder, right-click ICARUS in Steam and choose Manage, then
  Browse local files. Open Icarus, then Binaries, then Win64. When you are done,
  dwmapi.dll and the ue4ss folder sit next to Icarus-Win64-Shipping.exe.

  Copying by hand sets up no button and changes no permissions.

Then start the game and press F8. That opens the Wax menu.


WHAT WAX LEAVES ON YOUR PC

Three things, and nothing else:

  In the game's Binaries\Win64 folder
      dwmapi.dll and the ue4ss folder. Wax itself is ue4ss\Mods\Wax, with your
      mods and settings inside it. If another UE4SS was there before, its
      files are kept beside them in a folder named ue4ss-backup- and the date.

  %LOCALAPPDATA%\Wax\import.log
      A small text file. It gets one line each time a wax:// link is opened
      on this PC: the time, the mod and what was done. It is only there once
      such a link was opened.

  HKEY_CURRENT_USER\Software\Classes\wax
      A registry key, only if you said yes to the "Add to game" button.

"Uninstall Wax.cmd" removes them. It asks first about your mods and settings
and about UE4SS. It leaves a ue4ss-backup folder where it is, and it leaves
the folder of the log alone when you put other files into it. An update
downloads into your temporary folder and removes the download when it is done.


YOUR MODS

Mods go in this folder, one folder per mod:

  ...\Binaries\Win64\ue4ss\Mods\Wax\mods

A mod is a folder with an init.lua in it. One mod comes with Wax: Recipe
Browser, which shows every item and its recipes beside your inventory. The
docs explain how to write your own.

A mod is code. Once it is switched on it can do what any program on your PC
can do. Only add mods from people you trust.

Mods added with the "Add to game" button on the Wax site keep themselves up to
date, and so does Recipe Browser. While the game runs, Wax asks the mod
catalogue at wax-icarus.duckdns.org whether a newer version is out, downloads
it and puts it in. The version before stays in the mods folder, under a name
that starts with ".removed-". A mod you wrote or copied in yourself is never
changed. To decide for yourself when a mod is updated, open the Wax menu (F8),
go to Mods and switch off "Auto Update".

Wax keeps its settings, and the settings of your mods, in this folder:

  ...\Binaries\Win64\ue4ss\Mods\Wax\saved

There is a VS Code extension for writing mods, "Wax for Icarus"
(id RobertCincotta.wax-icarus). The .vsix file is on the same page as this
download. You can also search for "Wax for Icarus" in the VS Code Marketplace,
but it may not be listed there yet.


THE "ADD TO GAME" BUTTON

Every mod on the Wax site has an "Add to game" button. It opens a link that
starts with wax://, and Windows has to know which program gets such links.
If you say yes when the installer asks, it writes that into your own part of
the registry, under this key:

  HKEY_CURRENT_USER\Software\Classes\wax

The key holds one command: Windows PowerShell, in a window you can see, runs
...\ue4ss\Mods\Wax\Wax-Import.ps1 with the link. It needs no administrator
rights and changes nothing else on your PC.

Before you say yes:
  - A wax:// link can be on any web page, not only on the Wax site.
  - Wax-Import.ps1 shows you the mod's name, version and author, and asks
    before it downloads anything. It downloads only from the Wax catalogue
    and only puts in a mod that carries the signature of Wax's author.
  - A mod added this way stays switched off until you switch it on in the
    Wax menu.

Without the key everything else works. Download the mod as a zip from the site
and put its folder into Wax\mods.

There are two ways to remove the key:
  1. Run "Uninstall Wax.cmd". It removes the key together with Wax. A key that
     points at another copy of Wax on this PC is left alone.
  2. Keep Wax and remove only the key. Press the Windows key, type cmd, press
     Enter, then type this line and press Enter:

       reg delete HKCU\Software\Classes\wax /f

     You can also open regedit and delete the key named above.

To switch the button on later, click the address bar of this folder's window,
type cmd and press Enter. Then type this line and press Enter:

  "Install Wax.cmd" -ModLinks Yes

With No in place of Yes it removes the key and keeps Wax. An update leaves the
button the way you set it.


WHO CAN CHANGE WAX'S FOLDER

Steam lets every Windows account on a PC change the files of its games. Wax
runs the Lua code that is in its own folder, so the installer closes that one
folder to the other accounts:

  ...\Binaries\Win64\ue4ss\Mods\Wax

After an install or an update, three can change what is in it: the Windows
account that ran the installer, administrators, and Windows itself. Other
accounts can read it and no more. Your mods and settings are inside it, so
they are covered too.

This does not cover the rest of the game folder, which stays as Steam made it.
Another account on the PC can still change the game's own files and UE4SS.

If you play ICARUS from another Windows account than the one that installed
Wax, Wax cannot save its settings there. Run "Install Wax.cmd" from the account
you play on.


UE4SS'S CHEAT AND CONSOLE MODS

UE4SS comes with a few small mods of its own. Three of them open the game's
developer console and its cheat commands:

  CheatManagerEnablerMod, ConsoleCommandsMod, ConsoleEnablerMod

Wax does not need them, so they are switched off in this download. To switch
one on, open ...\Binaries\Win64\ue4ss\Mods\mods.txt in Notepad and change the
0 after its name to 1.

Wax 0.2.0 and older left the three switched on. When you install this version
over one of those and never changed mods.txt, the installer switches them off
and says so. If you changed mods.txt, it keeps your file and tells you which of
the three are on in it.


UPDATE

Close ICARUS first.

With the installer:
  Double-click "Update Wax.cmd". It asks GitHub for the newest release of Wax.
  If that is newer than yours, it downloads the release's list of files, checks
  that the list carries the signature of Wax's author, downloads the zip, and
  compares the zip with the list. Only then does it install. If any of that
  fails it changes nothing, and tells you to get Wax from the site instead.

  The signature tells you the files are the ones the author released, and no
  more than that. It is checked with a key that is written in Wax-Setup.ps1.
  The key's fingerprint is

    @FINGERPRINT@

  Compare it with the fingerprint on the Wax site.

  Use the "Update Wax.cmd" of this version or a newer one. The one that came
  with Wax 0.2.0 and older installs what it downloads without that check, so
  delete those older folders.

  You can also download the newest zip and run its "Install Wax.cmd". Both
  keep your mods (Wax\mods), your settings (Wax\saved) and your UE4SS settings.

By hand:
  Download the newest zip and copy the contents of "game" into Win64 again.
  Say yes when Windows asks to replace files. Your own mods and your settings
  are not in the zip, so they stay. Two things are replaced by the copies from
  the zip: mods\RecipeBrowser, and the UE4SS settings files (UE4SS-settings.ini,
  mods.txt, mods.json).


REMOVE

Close ICARUS first.

With the installer:
  Double-click "Uninstall Wax.cmd". It removes Wax, the registry key of the
  "Add to game" button and the log in %LOCALAPPDATA%\Wax. It asks before it
  removes your mods and settings, and before it removes UE4SS. Press Enter at
  a question to keep them.

By hand:
  Delete the folder ...\Binaries\Win64\ue4ss\Mods\Wax. Your mods and settings
  are in it, so copy "mods" and "saved" somewhere else first if you want them.
  To remove UE4SS too, delete dwmapi.dll and the ue4ss folder from Win64.
  If you said yes to the "Add to game" button, remove its registry key as well
  (way 2 under THE "ADD TO GAME" BUTTON). If a wax:// link was ever opened,
  delete the folder %LOCALAPPDATA%\Wax too: paste that into the address bar of
  any folder window to get there.


IF YOU ALREADY USE UE4SS

Wax is tested on the UE4SS build in this zip, so the installer puts that build
in. If it finds a different one, it first copies the old files to a folder
inside Win64. The folder's name is ue4ss-backup- followed by the date and time.
If your game already has this build, the installer leaves your UE4SS settings
files as they are. Your other UE4SS mods in ue4ss\Mods are left alone.
