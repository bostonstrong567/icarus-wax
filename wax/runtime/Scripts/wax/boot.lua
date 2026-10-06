-- Starts the Wax core

local Wax = ...

local boot = {}

function boot.start()
    local log = Wax.import("core.log")
    local guard = Wax.import("core.guard")
    guard.arm()     -- starting takes a while, so the clock for runaway scripts starts here
    local co = Wax.import("core.co")
    local perf = Wax.import("core.perf")
    local sched = Wax.import("core.sched")
    local storage = Wax.import("core.storage")
    local blackbox = Wax.import("core.blackbox")
    Wax.blackbox = blackbox

    -- Everything logged also goes to UE4SS.log, where it survives a crash.
    log.add_sink(function(entry, repeated)
        if not repeated and entry.level ~= "debug" and entry.level ~= "trace" then
            blackbox.note(("[%s] [%s] %s"):format(entry.level, entry.channel, (tostring(entry.message):match("^[^\r\n]*"))))
        end
        if repeated then
            -- A repeated message is printed at 10, 100 and every 1000 repeats.
            local n = entry.count
            if n ~= 10 and n ~= 100 and n % 1000 ~= 0 then return end
            print(("[Wax] [%s] [%s] (x%d) %s\n"):format(entry.level, entry.channel, n, entry.message))
        else
            print(("[Wax] [%s] [%s] %s\n"):format(entry.level, entry.channel, entry.message))
        end
    end)

    local core_log = log.channel("wax")
    if co.native then
        core_log:info("coroutine helper loaded: tasks can call the engine")
    else
        core_log:warn("coroutine helper not loaded (%s): engine calls inside tasks will fail", tostring(co.native_error))
    end

    Wax.log = log
    Wax.storage = storage
    Wax.perf = perf
    Wax.guard = guard
    Wax.sched = sched
    Wax.task = sched.task
    Wax.Signal = sched.Signal

    local mods = Wax.import("mods.loader")
    Wax.mods = mods

    -- The object model. If it cannot start (a game update broke an assumption), mods still load with raw access.
    local game = nil
    local ok, err = xpcall(function()
        game = Wax.import("engine.game")
        game.start()
    end, debug.traceback)
    local track, highlight = nil, nil
    if ok then
        Wax.game = game.root
        Wax.instance = Wax.import("engine.instance")
        mods.provide("game", game.root)
        local world_ok, world_err = xpcall(function()
            Wax.import("engine.actors").start()
            track = Wax.import("engine.track")
            track.start()
            Wax.import("world.creatures").start()
            Wax.import("world.players").start()
            Wax.import("world.crafting").start()
            highlight = Wax.import("world.highlight")
            highlight.start()
        end, debug.traceback)
        if not world_ok then
            track, highlight = nil, nil
            core_log:error("the world helpers failed to start: %s", tostring(world_err))
        end
        local data_ok, data_err = xpcall(function() Wax.import("data.tables").start() end, debug.traceback)
        if not data_ok then core_log:error("game.Data failed to start: %s", tostring(data_err)) end
    else
        game = nil
        core_log:error("the game object model failed to start: %s", tostring(err))
    end

    local ui = nil
    local gui_ok, gui_err = xpcall(function()
        ui = Wax.import("gui.init")
        ui.start()
    end, debug.traceback)
    if gui_ok then
        Wax.ui = ui
        mods.provide("ui", ui)
        local panel_ok, panel_err = xpcall(function()
            local panel = Wax.import("gui.debug")
            panel.start()
            Wax.debug_panel = panel
            ui.Debug = panel
        end, debug.traceback)
        if not panel_ok then core_log:error("the debug panel failed to start: %s", tostring(panel_err)) end
    else
        ui = nil
        core_log:error("the GUI failed to start: %s", tostring(gui_err))
    end

    -- Stage 0 runs the bridge. Time it with everything else.
    local stage = rawget(_G, "WaxStage0")
    if stage then
        stage.raw_poll = stage.raw_poll or stage.poll
        local raw_poll = stage.raw_poll
        stage.poll = function() return perf.run("bridge", raw_poll) end
    end

    -- Reloads requested during a frame run at the start of the next one, never while mod code is on the stack.
    local function world_step()
        track.step()
        highlight.step()
    end

    Wax.frame = function()
        perf.frame()
        local current_ui = Wax.ui
        if current_ui and current_ui.check then guard.call("gui.check", current_ui.check) end
        if game then perf.run("game", guard.call, "game.step", game.step) end
        if highlight then perf.run("world", guard.call, "world.step", world_step) end
        perf.run("mods", mods.step)
        storage.step()
        perf.run("tasks", sched.step)
        if current_ui then perf.run("gui", guard.call, "gui.step", current_ui.step) end
        local panel = Wax.debug_panel
        if panel then perf.run("debug", guard.call, "debug.step", panel.step) end
    end
    Wax.gui_step_wired = true
    core_log:info("core started")
    mods.sync()
end

return boot
