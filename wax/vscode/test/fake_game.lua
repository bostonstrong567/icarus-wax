-- A stand-in for the game: the real bridge (main.lua) and the real Wax core modules under plain Lua, no engine.
-- Run from the workspace root: tools\lua\lua54\lua.exe wax\vscode\test\fake_game.lua <scratch dir>
-- The scratch dir holds run/in, run/out, saved and run/mods.index.lua. Each line on stdin is one frame; "quit" ends it.

local scratch = assert(arg[1], "usage: fake_game.lua <scratch dir>"):gsub("\\", "/")

local frame_loop
function ExecuteInGameThread(fn) fn() end
function LoopInGameThreadAfterFrames(_, fn) frame_loop = fn end
function StaticFindObject() return {} end

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
