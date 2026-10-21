-- How this copy of the game runs: a dedicated server, a player hosting, a client in someone's world, or alone

local Wax = ...
local sched = Wax.import("core.sched")
local log = Wax.import("core.log").channel("wax.mode")

local M = {}

local LIBRARY = "/Script/Engine.Default__KismetSystemLibrary"

-- Everything that touches the engine. The tests put a made-up game here.
local engine = {}
M.engine = engine

function engine.viewport()
    local e = FindFirstOf("Engine")
    if not e:IsValid() then return nil end
    local v = e.GameViewport
    return v:IsValid() and v or nil
end

function engine.world()
    local game = Wax.modules["engine.game"]
    if type(game) ~= "table" or not game.world then return nil end
    return game.world()
end

function engine.library()
    local found = StaticFindObject(LIBRARY)
    return found:IsValid() and found or nil
end

local mode = { kind = "single", IsServer = false, IsAuthority = true, HasScreen = true }
mode.Changed = sched.Signal.new("ModeChanged")
M.mode = mode

local library, started = nil, false

-- The kind of game this is, read from the world. With no world a copy without a screen is a server and one with a screen is alone.
local function read_kind(has_screen)
    local world = engine.world()
    if not world then return has_screen and "single" or "server" end
    if not library or not library:IsValid() then library = engine.library() end
    if not library then return has_screen and "single" or "server" end
    local ok, dedicated = pcall(function() return library:IsDedicatedServer(world) end)
    if ok and dedicated == true then return "server" end
    local alone_ok, alone = pcall(function() return library:IsStandalone(world) end)
    if alone_ok and alone == true then return "single" end
    local server_ok, server = pcall(function() return library:IsServer(world) end)
    if server_ok and server == true then return "host" end
    return has_screen and "client" or "server"
end

local function apply(kind)
    mode.kind = kind
    mode.IsServer = kind == "server"
    mode.IsAuthority = kind ~= "client"
end

-- Reads the mode again. Fires Changed when the kind is not what it was.
function M.refresh()
    local before = mode.kind
    apply(read_kind(mode.HasScreen))
    if mode.kind ~= before then
        log:info("mode: %s", mode.kind)
        mode.Changed:Fire(mode.kind, before)
    end
    return mode
end

function M.start()
    if started then return mode end
    started = true
    -- a dedicated server never gets a viewport, so this is read once
    mode.HasScreen = engine.viewport() ~= nil
    apply(read_kind(mode.HasScreen))
    log:info("mode: %s%s", mode.kind, mode.HasScreen and "" or " (no screen)")
    local game = Wax.game
    if game and game.MapChanged then game.MapChanged:Connect(function() M.refresh() end) end
    if game then rawset(game, "Mode", mode) end
    return mode
end

return M
