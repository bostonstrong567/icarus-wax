-- Starts the Wax core

local Wax = ...

local boot = {}

-- off until one start of the game with handles has been watched
boot.HANDLES = false

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
    local track, highlight, watch, hooks, animations, effects = nil, nil, nil, nil, nil, nil
    if ok then
        Wax.game = game.root
        Wax.instance = Wax.import("engine.instance")
        local handle_ok, handle_err = xpcall(function()
            if not boot.HANDLES then return end
            Wax.handle = Wax.import("engine.handle")
            if Wax.handle.start() then Wax.instance.use_handles(Wax.handle) end
        end, debug.traceback)
        if not handle_ok then
            Wax.handle = nil
            core_log:error("handles failed to start: %s", tostring(handle_err))
        end
        mods.provide("game", game.root)
        local needs_ok, needs_err = xpcall(function()
            Wax.needs = Wax.import("engine.needs")
            Wax.needs.start()
        end, debug.traceback)
        if not needs_ok then
            Wax.needs = nil
            core_log:error("the check against game updates failed to start: %s", tostring(needs_err))
        end
        local world_ok, world_err = xpcall(function()
            Wax.import("engine.actors").start()
            track = Wax.import("engine.track")
            track.start()
            Wax.import("world.creatures").start()
            Wax.import("world.players").start()
            Wax.import("world.crafting").start()
            Wax.import("world.research").start()
            highlight = Wax.import("world.highlight")
            highlight.start()
        end, debug.traceback)
        if not world_ok then
            track, highlight = nil, nil
            core_log:error("the world helpers failed to start: %s", tostring(world_err))
        end
        local watch_ok, watch_err = xpcall(function()
            watch = Wax.import("engine.watch")
            watch.start()
        end, debug.traceback)
        if not watch_ok then
            watch = nil
            core_log:error("watching values failed to start: %s", tostring(watch_err))
        end
        local hooks_ok, hooks_err = xpcall(function()
            hooks = Wax.import("engine.hooks")
            hooks.start()
        end, debug.traceback)
        if not hooks_ok then
            hooks = nil
            core_log:error("listening to the game's own events failed to start: %s", tostring(hooks_err))
        end
        local character_ok, character_err = xpcall(function() Wax.import("world.character").start() end, debug.traceback)
        if not character_ok then core_log:error("game.Me and the character fields failed to start: %s", tostring(character_err)) end
        local stats_ok, stats_err = xpcall(function() Wax.import("world.stats").start() end, debug.traceback)
        if not stats_ok then core_log:error("stats and modifiers failed to start: %s", tostring(stats_err)) end
        local session_ok, session_err = xpcall(function() Wax.import("world.session").start() end, debug.traceback)
        if not session_ok then core_log:error("game.Time, game.Weather and game.Prospect failed to start: %s", tostring(session_err)) end
        local items_ok, items_err = xpcall(function() Wax.import("world.items").start() end, debug.traceback)
        if not items_ok then core_log:error("game.Items failed to start: %s", tostring(items_err)) end
        local creature_ok, creature_err = xpcall(function() Wax.import("world.creature").start() end, debug.traceback)
        if not creature_ok then core_log:error("the creature fields failed to start: %s", tostring(creature_err)) end
        local models_ok, models_err = xpcall(function() Wax.import("world.creature_models").start() end, debug.traceback)
        if not models_ok then core_log:error("the creature models failed to start: %s", tostring(models_err)) end
        local mounts_ok, mounts_err = xpcall(function() Wax.import("world.mounts").start() end, debug.traceback)
        if not mounts_ok then core_log:error("mounts and creature models failed to start: %s", tostring(mounts_err)) end
        local data_ok, data_err = xpcall(function() Wax.import("data.tables").start() end, debug.traceback)
        if not data_ok then core_log:error("game.Data failed to start: %s", tostring(data_err)) end
        local patch_ok, patch_err = xpcall(function() Wax.import("data.patch").start() end, debug.traceback)
        if not patch_ok then core_log:error("changing game tables failed to start: %s", tostring(patch_err)) end
        local recipes_ok, recipes_err = xpcall(function() Wax.import("world.recipes").start() end, debug.traceback)
        if not recipes_ok then core_log:error("game.Recipes failed to start: %s", tostring(recipes_err)) end
        local workshop_ok, workshop_err = xpcall(function() Wax.import("world.workshop").start() end, debug.traceback)
        if not workshop_ok then core_log:error("game.Workshop failed to start: %s", tostring(workshop_err)) end
        local store_ok, store_err = xpcall(function() Wax.import("world.workshop_rows").start() end, debug.traceback)
        if not store_ok then core_log:error("changing the store failed to start: %s", tostring(store_err)) end
        local assets_ok, assets_err = xpcall(function() Wax.import("world.assets").start() end, debug.traceback)
        if not assets_ok then core_log:error("game.Assets failed to start: %s", tostring(assets_err)) end
        local blueprints_ok, blueprints_err = xpcall(function() Wax.import("world.blueprints").start() end, debug.traceback)
        if not blueprints_ok then core_log:error("game.Blueprints failed to start: %s", tostring(blueprints_err)) end
        local animations_ok, animations_err = xpcall(function()
            animations = Wax.import("world.animations")
            animations.start()
        end, debug.traceback)
        if not animations_ok then
            animations = nil
            core_log:error("game.Animations failed to start: %s", tostring(animations_err))
        end
        local effects_ok, effects_err = xpcall(function()
            effects = Wax.import("world.effects")
            effects.start()
        end, debug.traceback)
        if not effects_ok then
            effects = nil
            core_log:error("game.Effects failed to start: %s", tostring(effects_err))
        end
    else
        game = nil
        core_log:error("the game object model failed to start: %s", tostring(err))
    end

    local content_ok, content_err = xpcall(function() Wax.import("mods.content").start() end, debug.traceback)
    if not content_ok then core_log:error("mods' game content failed to start: %s", tostring(content_err)) end
    local update_ok, update_err = xpcall(function()
        Wax.update = Wax.import("mods.update")
        Wax.update.start()
    end, debug.traceback)
    if not update_ok then
        Wax.update = nil
        core_log:error("the mod updater failed to start: %s", tostring(update_err))
    end
    local self_ok, self_err = xpcall(function()
        Wax.selfupdate = Wax.import("mods.selfupdate")
        Wax.selfupdate.start()
    end, debug.traceback)
    if not self_ok then
        Wax.selfupdate = nil
        core_log:error("the Wax updater failed to start: %s", tostring(self_err))
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
        if hooks then hooks.step() end
        if highlight then
            track.step()
            highlight.step()
        end
        if watch then watch.step() end
        if animations then animations.step() end
        if effects then effects.step() end
    end

    -- a version put in at this start is kept once it has run for a while
    local settle = Wax.selfupdate and Wax.selfupdate.settle
    Wax.frame = function()
        perf.frame()
        local current_ui = Wax.ui
        if current_ui and current_ui.check then guard.call("gui.check", current_ui.check) end
        if game then perf.run("game", guard.call, "game.step", game.step) end
        if highlight or watch or hooks or animations or effects then perf.run("world", guard.call, "world.step", world_step) end
        perf.run("mods", mods.step)
        storage.step()
        perf.run("tasks", sched.step)
        if current_ui then perf.run("gui", guard.call, "gui.step", current_ui.step) end
        local panel = Wax.debug_panel
        if panel then perf.run("debug", guard.call, "debug.step", panel.step) end
        if settle and not settle() then settle = nil end
    end
    if Wax.handle then Wax.frame = Wax.handle.framed(Wax.frame) end
    Wax.gui_step_wired = true
    core_log:info("core started")
    -- a mod the player has not seen before is listed switched off, and stays off until they switch it on
    mods.sync()
end

return boot
