-- Offline tests for engine.mode: the kind of game read from stand-ins, what a dedicated server looks like, and Changed.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\mode_test.lua

local t = dofile("wax/tests/offline/harness.lua")

-- A fresh core with a made-up engine: `screen` says whether there is a viewport, `answers` what the library says of the world.
local function fresh(screen, answers, world)
    local Wax = t.new_wax()
    rawset(_G, "Wax", Wax)
    local sched = Wax.import("core.sched")
    local game = { MapChanged = sched.Signal.new("MapChanged") }
    Wax.game = game
    local module = Wax.import("engine.mode")
    local state = { screen = screen, answers = answers or {}, world = world, asked = 0 }
    local library = { IsValid = function() return true end }
    for _, name in ipairs({ "IsDedicatedServer", "IsStandalone", "IsServer" }) do
        library[name] = function(_, given)
            t.eq(given, state.world, name .. " is asked about the world")
            state.asked = state.asked + 1
            return state.answers[name] == true
        end
    end
    module.engine.viewport = function() return state.screen and {} or nil end
    module.engine.world = function() return state.world end
    module.engine.library = function() return library end
    return Wax, module, state, game
end

t.test("a game with a screen and no world is alone", function()
    local _, module = fresh(true, {}, nil)
    local mode = module.start()
    t.eq(mode.kind, "single")
    t.eq(mode.HasScreen, true)
    t.eq(mode.IsServer, false)
    t.eq(mode.IsAuthority, true)
end)

t.test("no viewport is a dedicated server, with or without a world", function()
    local _, module = fresh(false, {}, nil)
    local mode = module.start()
    t.eq(mode.kind, "server")
    t.eq(mode.HasScreen, false)
    t.eq(mode.IsServer, true)
    t.eq(mode.IsAuthority, true)
    local _, with_world = fresh(false, { IsDedicatedServer = true, IsServer = true }, { name = "Terrain_019" })
    t.eq(with_world.start().kind, "server")
end)

t.test("the library's answers give host, client and single", function()
    local _, host = fresh(true, { IsServer = true }, { name = "w" })
    t.eq(host.start().kind, "host")
    t.eq(host.mode.IsAuthority, true)
    local _, client = fresh(true, {}, { name = "w" })
    t.eq(client.start().kind, "client")
    t.eq(client.mode.IsAuthority, false)
    t.eq(client.mode.IsServer, false)
    local _, alone = fresh(true, { IsStandalone = true, IsServer = true }, { name = "w" })
    t.eq(alone.start().kind, "single")
end)

t.test("a dedicated server that says so through the library stays a server even with a screen", function()
    local _, module = fresh(true, { IsDedicatedServer = true, IsServer = true }, { name = "w" })
    t.eq(module.start().kind, "server")
end)

t.test("Changed fires on a map change only when the kind differs", function()
    local Wax, module, state, game = fresh(true, {}, nil)
    local mode = module.start()
    t.eq(mode.kind, "single")
    local fired = {}
    mode.Changed:Connect(function(kind, before) fired[#fired + 1] = kind .. "<" .. before end)
    -- the title screen gives way to someone else's world
    state.world = { name = "Terrain_019" }
    game.MapChanged:Fire("Terrain_019")
    Wax.import("core.sched").step()
    t.eq(#fired, 1)
    t.eq(fired[1], "client<single")
    t.eq(mode.kind, "client")
    -- another map of the same kind changes nothing
    state.world = { name = "Terrain_020" }
    game.MapChanged:Fire("Terrain_020")
    Wax.import("core.sched").step()
    t.eq(#fired, 1)
    -- back to the title screen
    state.world = nil
    game.MapChanged:Fire("MainMenu")
    Wax.import("core.sched").step()
    t.eq(#fired, 2)
    t.eq(fired[2], "single<client")
end)

t.test("game.Mode is the same table, and start runs once", function()
    local Wax, module = fresh(false, {}, nil)
    local mode = module.start()
    t.eq(Wax.game.Mode, mode)
    t.eq(module.start(), mode)
    t.eq(module.refresh(), mode)
end)

t.test("a library that cannot answer leaves the kind at the screen's default", function()
    local _, module, state = fresh(true, {}, { name = "w" })
    module.engine.library = function() return nil end
    t.eq(module.start().kind, "single")
    state.screen = false
    local _, server = fresh(false, {}, { name = "w" })
    server.engine.library = function() return nil end
    t.eq(server.start().kind, "server")
end)

t.finish("mode")
