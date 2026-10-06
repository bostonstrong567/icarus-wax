-- Development aid: restart the core in a running game. Send with:  node wax/cli/wax.mjs eval --file <this>
local stage = rawget(_G, "WaxStage0")
if not stage then error("this game was started with an older bridge; restart the game once") end

local previous = rawget(_G, "Wax")
if previous and previous.debug_panel then pcall(previous.debug_panel.stop) end
if previous and previous.ui then pcall(previous.ui.stop) end
if previous and previous.mods then previous.mods.unload_all() end
if previous and previous.storage then previous.storage.flush() end
if previous and previous.sched then previous.sched.reset() end

-- The frame loop in main.lua follows whatever Wax is current, so nothing else has to be registered.
local root = previous and previous.root
if not root then error("no previous core to take the install path from") end
Wax = dofile(root .. "/Scripts/wax/loader.lua")(root)
Wax.import("boot").start()

return { restarted = true, nativeCoroutines = Wax.import("core.co").native, preciseClock = Wax.perf.precise }
