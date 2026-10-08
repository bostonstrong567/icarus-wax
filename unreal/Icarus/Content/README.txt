Put assets here at the same path the game uses.

The game's /Game/... is this Content folder. For example, to add or replace
  Icarus/Content/Assets/2DArt/UI/Fonts/MyFont.uasset
create the asset at Content/Assets/2DArt/UI/Fonts/MyFont in the editor's Content Browser.

Then:  .\scripts\Cook-UnrealProject.ps1 -Mod <ModName>
copies the cooked files into mods\<ModName>\content\, ready for Build-Mod.ps1.
