---@meta _

---What a mod's `mod.lua` returns. The file is optional, and so is every field.
---@class WaxManifest
---@field name? string Display name. The folder name when omitted.
---@field version? string "0.0.0" when omitted.
---@field main? string Entry file inside the mod's folder. "init.lua" when omitted.
---@field dependencies? string[] Ids of mods that load first. Each can then be reached with require("@Id").

---A file or folder of the mod, as `mod.Utils` or `mod.extras.Utils` gives it. Pass it to require.
---@class WaxFile

---What a mod knows about itself. Every Lua file and folder of the mod is a field too: `mod.Utils` is Utils.lua and
---`mod.extras.Utils` is extras/Utils.lua. A file called id, name, version, dir, Reload or OnUnload has to be required by its name instead.
---@class WaxModInfo
---@field id string The mod's folder name.
---@field name string
---@field version string
---@field dir string Path of the mod's folder.
---@field Reload fun() Loads the mod again at the start of the next frame, as a saved file does.
---@field OnUnload fun(fn: fun(why: "reload"|"off"|"removed"|"failed"|"shutdown")): fun() Runs `fn` once when the mod is about to unload, before anything of the mod is taken away: its windows, tasks, connections and table changes are all still there. `why` is "reload" when the mod loads again straight after, "off" when the player switched it off, "removed" when its folder went, "failed" when the mod raised an error while it loaded, and "shutdown" when Wax itself stops. Several run newest first, and one that raises an error is logged and stops none of the others. `fn` must return at once: it cannot wait. Use it for what Wax cannot undo for you, such as a change made to the world. It does not run when the game closes or the map changes. Returns a function that takes `fn` off again.
mod = {}

---One line of the Wax log.
---@class WaxLogEntry
---@field id integer
---@field time integer
---@field level "trace"|"debug"|"info"|"warn"|"error"
---@field channel string
---@field message string
---@field count integer How many times in a row this message was logged.

---The mod's own log channel. Values after `fmt` are put into it with string.format.
---@class WaxLogger
---@field channel string The mod's id.
log = {}

---Logs at trace level, which the default log level drops.
---@param fmt any
---@param ... any
---@return WaxLogEntry?
function log:trace(fmt, ...) end

---Logs at debug level.
---@param fmt any
---@param ... any
---@return WaxLogEntry?
function log:debug(fmt, ...) end

---Logs at info level.
---@param fmt any
---@param ... any
---@return WaxLogEntry?
function log:info(fmt, ...) end

---Logs a warning.
---@param fmt any
---@param ... any
---@return WaxLogEntry?
function log:warn(fmt, ...) end

---Logs an error, which also shows as a notification in the game.
---@param fmt any
---@param ... any
---@return WaxLogEntry?
function log:error(fmt, ...) end

---Logs the values, joined by tabs, at info level on the mod's channel.
---@param ... any
function print(...) end

---Returns the value kept under `key`, storing `default` (or a new table) on first use. The value survives reloads of the mod.
---@generic T
---@param key string
---@param default? T
---@return T
---@overload fun(key: string): table
function persist(key, default) end

---Settings that survive restarting the game, kept in one small file per name.
---@class WaxStorage
storage = {}

---Returns a copy of `defaults` with whatever was saved under `name` laid over it.
---@generic T: table
---@param name string Letters, digits, _ and - only.
---@param defaults? T
---@return T
---@overload fun(name: string): table
function storage.Load(name, defaults) end

---Queues the table to be written under `name`. Only numbers, strings, booleans and tables of them are kept.
---@param name string Letters, digits, _ and - only.
---@param value table
function storage.Save(name, value) end

---Loads a file of this mod and returns what it returned. `require(mod.Utils)` and `require("Utils")` are the same file,
---as are `require(mod.extras.Utils)` and `require("extras.Utils")`. A folder with an init.lua is loaded by the folder's name.
---`require("@Id")` gives another mod's exports.
---@param name string|WaxFile
---@return any
function require(name) end

---The real global table: unguarded access to everything UE4SS offers, including what Wax blocks.
---@type table<string, any>
raw = {}

---Blocked in Wax mods: it runs Lua on another thread, which corrupts the game's Lua state. Use task.spawn or task.delay.
---@deprecated
---@param ... any
function LoopAsync(...) end

---Blocked in Wax mods: it runs Lua on another thread, which corrupts the game's Lua state. Use task.spawn or task.delay.
---@deprecated
---@param ... any
function ExecuteAsync(...) end

---Blocked in Wax mods: it runs Lua on another thread, which corrupts the game's Lua state. Use task.spawn or task.delay.
---@deprecated
---@param ... any
function ExecuteWithDelay(...) end

---Blocked in Wax mods: it runs Lua on another thread, which corrupts the game's Lua state. Use ui.Hotkey.
---@deprecated
---@param ... any
function RegisterKeyBind(...) end

---Blocked in Wax mods: it runs Lua on another thread, which corrupts the game's Lua state. Use ui.Hotkey.
---@deprecated
---@param ... any
function RegisterKeyBindAsync(...) end

---Blocked in Wax mods: restarting a UE4SS mod destroys the Lua state Wax runs in. Reload the mod through Wax instead.
---@deprecated
---@param ... any
function RestartMod(...) end

---Blocked in Wax mods: restarting a UE4SS mod destroys the Lua state Wax runs in. Reload the mod through Wax instead.
---@deprecated
---@param ... any
function RestartCurrentMod(...) end

---Blocked in Wax mods: it destroys the Lua state Wax runs in.
---@deprecated
---@param ... any
function UninstallMod(...) end

---Blocked in Wax mods: it destroys the Lua state Wax runs in.
---@deprecated
---@param ... any
function UninstallCurrentMod(...) end

---Blocked in Wax mods: it cancels every mod's timers, and Wax's own frame loop with them.
---@deprecated
---@param ... any
function ClearAllDelayedActions(...) end
