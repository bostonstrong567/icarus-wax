-- A stand-in for the game: the real bridge (main.lua) and the real Wax core modules under plain Lua, no engine.
-- Run from the workspace root: tools\lua\lua54\lua.exe wax\vscode\test\fake_game.lua <Wax folder>
-- The Wax folder lies below a folder named Binaries, as in the game, and holds run/in, run/out, saved and mods.
-- Each line on stdin is one frame; "quit" ends it.

local scratch = assert(arg[1], "usage: fake_game.lua <Wax folder>"):gsub("\\", "/")

local frame_loop
function ExecuteInGameThread(fn) fn() end
function LoopInGameThreadAfterFrames(_, fn) frame_loop = fn end
function StaticFindObject() return {} end

local function files_under(dir)
    local found, prefix = {}, #dir + 2
    local pipe = io.popen(('dir /b /s /a:-d "%s" 2>nul <nul'):format((dir:gsub("/", "\\"))))
    for line in pipe:lines() do found[(line:sub(prefix):gsub("\\", "/"))] = true end
    pipe:close()
    return found
end

-- A folder the way UE4SS lists one.
local function tree_of(dir)
    local top = { __absolute_path = (dir:gsub("/", "\\")), __files = {} }
    for relative in pairs(files_under(dir)) do
        local at, path = top, dir
        for folder in relative:gmatch("([^/]+)/") do
            path = path .. "/" .. folder
            at[folder] = at[folder] or { __absolute_path = (path:gsub("/", "\\")), __files = {} }
            at = at[folder]
        end
        at.__files[#at.__files + 1] = { __name = relative:match("[^/]+$") }
    end
    return top
end

-- The game's folders as UE4SS lists them, from Binaries down to Wax's own mods folder, read from the disk at each look.
function IterateGameDirectories()
    local node = { mods = tree_of(scratch .. "/mods") }
    local parts = {}
    for part in scratch:gmatch("[^/]+") do parts[#parts + 1] = part end
    for index = #parts, 1, -1 do
        node = { [parts[index]] = node }
        if parts[index] == "Binaries" then break end
    end
    return { Game = node }
end

-- The bridge finds its run folder from its own path, so present it as living in the scratch folder.
local real_getinfo = debug.getinfo
debug.getinfo = function() return { source = "@" .. scratch .. "/Scripts/main.lua" } end
dofile("wax/runtime/Scripts/main.lua")
debug.getinfo = real_getinfo
WaxStage0.ready = true

local core = dofile("wax/runtime/Scripts/wax/loader.lua")("wax/runtime")
core.root = scratch
core.log = core.import("core.log")
core.guard = core.import("core.guard")
core.sched = core.import("core.sched")
core.task, core.Signal = core.sched.task, core.sched.Signal
core.storage = core.import("core.storage")
core.mods = core.import("mods.loader")
core.mods.set_watching(false)
-- what the player would see as a notification goes to the log, where a test can read it
local shown = core.log.channel("notification")
core.ui = { Notify = function(text, options) shown:info("%s: %s", tostring(options and options.title), text) end }
core.mods.on_held = function(_, name) core.ui.Notify(name .. " was added. It is switched off until you enable it on the Mods page.", { title = "New mod" }) end
core.frame = function()
    core.mods.step()
    core.storage.step()
    core.sched.step()
end
Wax = core
core.mods.sync()

io.stdout:setvbuf("no")
print("ready")
for line in io.lines() do
    if line == "quit" then break end
    frame_loop()
end
