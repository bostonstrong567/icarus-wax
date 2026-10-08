---@meta _

---The game content a mod brings: models, textures, materials, sounds and blueprints made in the Unreal editor and
---packed into one file, content/<Id>.pak, in the mod's folder. Wax checks the file, hands it to the game before
---the mod's code runs, and the mod then loads from it by name. `mod.Content` is nil for a mod without that file.
---
---A changed pak is taken up without a restart when the mod reloads: the game lets go of the older copy and loads
---from the newer one. An asset the game still uses at that moment keeps its older look until the game is
---restarted, and State then says "restart".
---@class WaxContent
---@field State "ready"|"restart"|"off" "ready": the content is there. "restart": it is there, and some assets still show an older copy until the game is restarted. "off": the game does not have it, and Reason says why.
---@field Reason string? Why State is "off" or "restart". Nil when it is "ready".
---@field Files string[] The files in the pak, such as "BP_Thing.uasset". A new list each time.
local Content = {}

---The game's path of an asset in this mod's content, as game.Assets:Load takes it. "Meshes/Rock" gives
---"/Game/Mods/<Id>/Meshes/Rock.Rock".
---@param name string The asset's name, with its folders inside the mod's content when it has any.
---@return string
function Content:Path(name) end

---The game's path of a blueprint's class in this mod's content: "BP_Thing" gives
---"/Game/Mods/<Id>/BP_Thing.BP_Thing_C". It is what `base` of game.Blueprints:Define takes.
---@param name string The blueprint's name.
---@return string
function Content:ClassPath(name) end

---Loads an asset of this mod's content and keeps it for the mod, as game.Assets:Load does.
---@param name string The asset's name, such as "T_Icon" or "Meshes/Rock".
---@return WaxInstance? asset Nil when it could not be loaded.
---@return string? why The reason, when it could not.
function Content:Load(name) end

---Loads the class of a blueprint of this mod's content.
---@param name string The blueprint's name, such as "BP_Thing".
---@return WaxInstance? class Nil when it could not be loaded.
---@return string? why The reason, when it could not.
function Content:LoadClass(name) end

---True when the pak holds an asset of this name. Loads nothing.
---@param name string
---@return boolean
function Content:Has(name) end
