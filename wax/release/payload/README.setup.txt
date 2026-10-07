Wax @VERSION@ for ICARUS

Wax lets you write mods for ICARUS in Lua. This is an early version.

Docs:           https://wax-icarus.duckdns.org/
Newest version: https://wax-icarus.duckdns.org/docs/install/


WHAT IS IN THIS FOLDER

  Wax Setup.exe   Installs, updates, repairs and removes Wax.
  game            The same files, for copying into the game by hand.
  licenses        The licences of UE4SS and of the Lucide icons.

UE4SS is the script loader Wax runs on. It comes with Wax, so you install
nothing else.


INSTALL

Close ICARUS first.

With the program:
  Double-click "Wax Setup.exe" and press Install. It finds the game through
  Steam. If it can't find the game, it asks you for the folder: the one Steam
  opens when you right-click ICARUS and choose Manage, then Browse local files.

  The first time, Windows may show a blue box that says "Windows protected
  your PC". That is what Windows shows for a program it has not seen often.
  Choose "More info", then "Run anyway". The program never asks for
  administrator rights, and its source is public:
  https://github.com/bostonstrong567/icarus-wax

By hand:
  Copy everything inside the "game" folder into

    ...\steamapps\common\Icarus\Icarus\Binaries\Win64\

  When you are done, dwmapi.dll and the ue4ss folder sit next to
  Icarus-Win64-Shipping.exe.

Then start the game and press F8. That opens the Wax menu.


WHAT THE PROGRAM CHANGES

It writes in three places and nowhere else:

  The game's Binaries\Win64 folder     Wax and UE4SS.
  %LOCALAPPDATA%\Wax                   Its log (setup.log) and the game folder
                                       you chose.
  Your own part of the registry        One entry, so that the "Add to game"
                                       button on the Wax site opens Wax.

It checks every file it copied against a list made when it was built. If a
copy fails half way, it puts everything back as it was.


YOUR MODS

Mods go in this folder, one folder per mod:

  ...\Binaries\Win64\ue4ss\Mods\Wax\mods

A mod is a folder with an init.lua in it. One mod comes with Wax: Recipe
Browser, which shows every item and its recipes beside your inventory. The
docs explain how to write your own.

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


UPDATE

Close ICARUS first. Download the newest "Wax Setup.exe" and run it. It shows
the version in your game and offers "Update". Your mods (Wax\mods), your
settings (Wax\saved) and your UE4SS settings are kept.

The program downloads nothing by itself. If the Wax in your game is newer than
the program, it says so and changes nothing.

By hand:
  Download the newest zip and copy the contents of "game" into Win64 again.
  Say yes when Windows asks to replace files. Your own mods and your settings
  are not in the zip, so they stay. Two things are replaced by the copies from
  the zip: mods\RecipeBrowser, and the UE4SS settings files (UE4SS-settings.ini,
  mods.txt, mods.json).


REPAIR

Run "Wax Setup.exe". When Wax is installed it compares every file with its
list and tells you if one is missing or changed. "Repair" puts them back.


REMOVE

Close ICARUS first. Run "Wax Setup.exe" and choose "Uninstall". It asks once:
whether to keep your mods and settings (kept unless you say otherwise), and
whether to remove UE4SS too. It removes the files it put in and no others.

A copy of the program is also in the game, at
...\Binaries\Win64\ue4ss\Mods\Wax\Wax Setup.exe, so you can remove Wax after
you have deleted the download.

By hand:
  Delete the folder ...\Binaries\Win64\ue4ss\Mods\Wax. Your mods and settings
  are in it, so copy "mods" and "saved" somewhere else first if you want them.
  To remove UE4SS too, delete dwmapi.dll and the ue4ss folder from Win64.


IF YOU ALREADY USE UE4SS

Wax is tested on the UE4SS build that comes with it, so the program puts that
build in. If it finds a different one, it first copies the old files to a
folder inside Win64. The folder's name is ue4ss-backup- followed by the date
and time. If your game already has this build, the program leaves your UE4SS
settings files as they are. Your other UE4SS mods in ue4ss\Mods are left alone.


WITHOUT THE WINDOW

"Wax Setup.exe" --help lists the switches: --install, --uninstall, --verify,
--status, --game <folder> and a few more. It then works without a window,
ends with exit code 0 when it worked, and can write what it did to a file
(--result <file>).
