-- `game`: the root every mod starts from

local Wax = ...
local instance = Wax.import("engine.instance")
local suggest = Wax.import("core.suggest")
local sched = Wax.import("core.sched")
local log = Wax.import("core.log").channel("wax.game")

local M = {}

local wrap = instance.wrap
local PENDING_KILL = EInternalObjectFlags and EInternalObjectFlags.PendingKill or 0x20000000
local ACTOR_ARRAY = "WaxLevelActors"

local engine_object = nil
local survival_state_class = nil
local actor_array_ok = nil      -- nil = not tried yet, true = usable, false = fall back to a search
local library_paths = nil       -- name -> where the engine keeps the object of a function library
local libraries = {}            -- name -> Instance, or false when it is not loaded. Emptied when the map changes

-- The engine objects the rest is reached from.
local function engine()
    if not engine_object or not engine_object:IsValid() then engine_object = FindFirstOf("Engine") end
    return engine_object
end

local function viewport()
    local e = engine()
    if not e:IsValid() then return nil end
    local v = e.GameViewport
    return v:IsValid() and v or nil
end

local function world()
    local v = viewport()
    if not v then return nil end
    local w = v.World
    return w:IsValid() and w or nil
end

local function game_instance()
    local v = viewport()
    if not v then return nil end
    local g = v.GameInstance
    return g:IsValid() and g or nil
end

local function local_controller()
    local g = game_instance()
    if not g then return nil end
    local players = g.LocalPlayers
    if players:GetArrayNum() == 0 then return nil end
    local controller = players[1].PlayerController
    return controller:IsValid() and controller or nil
end

local function game_state()
    local w = world()
    if not w then return nil end
    local state = w.GameState
    return state:IsValid() and state or nil
end

-- A level's actor list is not in the engine's reflection data, so it is registered as a custom property.
local function prepare_actor_array(level)
    local function is_array()
        return level[ACTOR_ARRAY]:type() == "TArray"
    end
    local ok, found = pcall(is_array)
    if not (ok and found) then
        local registered, err = pcall(RegisterCustomProperty, {
            Name = ACTOR_ARRAY, Type = PropertyTypes.ArrayProperty, BelongsToClass = "/Script/Engine.Level",
            OffsetInternal = { Property = "OwningWorld", RelativeOffset = -0x20 },
            ArrayProperty = { Type = PropertyTypes.ObjectProperty },
        })
        if not registered then
            log:warn("could not register the level actor list (%s), so the slower search is used", tostring(err))
            return false
        end
    end
    local verified, same = pcall(function()
        local actors = level[ACTOR_ARRAY]
        if actors:GetArrayNum() < 1 then return false end
        return actors[1]:GetAddress() == level.WorldSettings:GetAddress()
    end)
    if not (verified and same) then
        log:warn("the level actor list failed its check (a game update may have moved it), so the slower search is used")
        return false
    end
    return true
end

local function world_actors(world_object)
    local out = {}
    if actor_array_ok == nil then
        local ok, result = pcall(prepare_actor_array, world_object.PersistentLevel)
        actor_array_ok = ok and result
    end
    if actor_array_ok then
        world_object.Levels:ForEach(function(_, element)
            local level = element:get()
            if level:IsValid() then
                local actors = level[ACTOR_ARRAY]
                for i = 1, actors:GetArrayNum() do
                    local actor = actors[i]
                    -- A destroyed actor stays in memory until the next collection, but it is no longer in the world.
                    if actor:IsValid() and not actor:HasAnyInternalFlags(PENDING_KILL) then out[#out + 1] = actor end
                end
            end
        end)
        return out
    end
    local found = FindAllOf("Actor")
    if found then
        for i = 1, #found do
            local actor = found[i]
            if actor:IsValid() and not actor:HasAnyInternalFlags(PENDING_KILL) then out[#out + 1] = actor end
        end
    end
    return out
end

-- The world's actors a slice at a time, as Instances. `place` is nil to start. The second result is where to go on, or nil at the end.
-- `enough()`, when given, is asked after each actor and ends the slice early by returning true.
function M.actors_from(place, count, enough)
    local out = {}
    local w = world()
    if not w then return out, nil end
    if actor_array_ok == nil then
        local ok, result = pcall(prepare_actor_array, w.PersistentLevel)
        actor_array_ok = ok and result
    end
    if not actor_array_ok then
        -- the search cannot be cut into pieces
        local found = world_actors(w)
        for i = 1, #found do out[#out + 1] = wrap(found[i]) end
        return out, nil
    end
    place = place or { level = 1, index = 1 }
    local levels = w.Levels
    local level_count, looked = levels:GetArrayNum(), 0
    while place.level <= level_count do
        local level = levels[place.level]
        local actors = level:IsValid() and level[ACTOR_ARRAY] or nil
        local last = actors and actors:GetArrayNum() or 0
        while place.index <= last do
            if looked >= count then return out, place end
            looked = looked + 1
            local actor = actors[place.index]
            place.index = place.index + 1
            if actor:IsValid() and not actor:HasAnyInternalFlags(PENDING_KILL) then
                out[#out + 1] = wrap(actor)
                if enough and enough() then return out, place end
            end
        end
        place.level, place.index = place.level + 1, 1
    end
    return out, nil
end

local game = {}

local getters = {
    World = function() return wrap(world()) end,
    GameInstance = function() return wrap(game_instance()) end,
    GameState = function() return wrap(game_state()) end,
    GameMode = function()
        local w = world()
        return w and wrap(w.AuthorityGameMode) or nil       -- nil when you are a client in someone else's game
    end,
    IsHost = function()
        local w = world()
        return w ~= nil and w.AuthorityGameMode:IsValid()
    end,
    LocalPlayer = function() return wrap(local_controller()) end,
    Character = function()
        local controller = local_controller()
        return controller and wrap(controller.Pawn) or nil
    end,
    Engine = function() return wrap(engine()) end,
    Viewport = function() return wrap(viewport()) end,
    MapName = function()
        local w = world()
        return w and w:GetFName():ToString() or nil
    end,
    InProspect = function()
        local state = game_state()
        return state ~= nil and survival_state_class ~= nil and survival_state_class:IsValid() and state:IsA(survival_state_class)
    end,
}

local Players = {}
local PLAYER_NAMES = { "GetPlayers", "GetCharacters", "LocalPlayer" }

-- One entry per player in the session (their player state). Works for the host and for clients.
function Players:GetPlayers()
    local out, state = {}, game_state()
    if state then
        state.PlayerArray:ForEach(function(_, element)
            local player = wrap(element:get())
            if player then out[#out + 1] = player end
        end)
    end
    return out
end

-- The characters those players are controlling right now.
function Players:GetCharacters()
    local out, state = {}, game_state()
    if state then
        state.PlayerArray:ForEach(function(_, element)
            local player = element:get()
            if player:IsValid() then
                local character = wrap(player.PawnPrivate)
                if character then out[#out + 1] = character end
            end
        end)
    end
    return out
end

setmetatable(Players, {
    __index = function(_, key)
        if key == "LocalPlayer" then return getters.LocalPlayer() end
        error(("%s is not a member of game.Players.%s"):format(tostring(key), suggest.phrase(tostring(key), PLAYER_NAMES)), 2)
    end,
    __tostring = function() return "Players" end,
    __names = function() return PLAYER_NAMES end,
})
M.player_names = PLAYER_NAMES

game.Players = Players
game.MapChanged = sched.Signal.new("MapChanged")
game.wrap = wrap

-- The first live object of a class ("PlayerController", "BP_IcarusPlayerCharacterSurvival_C"), or nil
function game:Find(class_name)
    if type(class_name) ~= "string" then error("game:Find expects a class name, got " .. type(class_name), 2) end
    return wrap(FindFirstOf(class_name))
end

-- Every live object of a class. It searches all objects, so never call it per frame.
function game:FindAll(class_name)
    if type(class_name) ~= "string" then error("game:FindAll expects a class name, got " .. type(class_name), 2) end
    local out, found = {}, FindAllOf(class_name)
    if found then
        for i = 1, #found do
            local object = found[i]
            if object:IsValid() and not object:HasAnyInternalFlags(PENDING_KILL) then out[#out + 1] = wrap(object) end
        end
    end
    return out
end

-- The object a function library's functions are called on ("KismetSystemLibrary", "GameplayStatics")
function game:Library(name)
    if type(name) ~= "string" then error("game:Library expects the name of a function library, got " .. type(name), 2) end
    local found = libraries[name]
    if found == nil then
        if not library_paths then
            local chunk = loadfile(Wax.root .. "/data/libraries.lua")
            library_paths = chunk and chunk() or {}
        end
        local path = library_paths[name]
        if not path then
            local names = {}
            for known in pairs(library_paths) do names[#names + 1] = known end
            error(("%s is not a function library.%s"):format(name, suggest.phrase(name, names)), 2)
        end
        found = wrap(StaticFindObject(path)) or false
        libraries[name] = found
    end
    if not found then error(name .. " is not loaded in the game right now", 2) end
    return found
end

function game:GetTagged(tag) return instance.get_tagged(tag) end

local CHILDREN = { "World", "GameInstance", "GameState", "GameMode", "LocalPlayer", "Engine", "Viewport" }

-- The top of the tree, for code that walks the whole tree.
function game:GetChildren()
    local out = {}
    for _, name in ipairs(CHILDREN) do
        local child = getters[name]()
        if child then out[#out + 1] = child end
    end
    return out
end

function game:GetService(name)
    local getter = getters[name]
    if getter then return getter() end
    local value = rawget(game, name)
    if value ~= nil then return value end
    error(("game has no service named '%s'.%s"):format(tostring(name), suggest.phrase(tostring(name), M.names())), 2)
end

function M.names()
    local names = {}
    for name in pairs(getters) do names[#names + 1] = name end
    for name in pairs(game) do names[#names + 1] = name end
    return names
end

setmetatable(game, {
    __index = function(_, key)
        local getter = getters[key]
        if getter then return getter() end
        error(("%s is not a member of game.%s"):format(tostring(key), suggest.phrase(tostring(key), M.names())), 2)
    end,
    __newindex = function(_, key)
        error(("game.%s cannot be assigned because game is read-only"):format(tostring(key)), 2)
    end,
    __tostring = function() return "game" end,
    __names = function() return M.names() end,
})

-- start-up and the per-frame check for a world change
local last_world_address = nil

function M.start()
    instance.start()
    instance.world_object = function()
        local w = world()
        if not w then error("there is no world right now", 3) end
        return w
    end
    instance.world_actors = world_actors
    local class = StaticFindObject("/Script/Icarus.IcarusGameStateSurvival")
    survival_state_class = class:IsValid() and class or nil
    local w = world()
    last_world_address = w and w:GetAddress() or nil
end

-- Called every frame. Fires MapChanged when the world is a different one.
function M.step()
    local w = world()
    local address = w and w:GetAddress() or nil
    if address ~= last_world_address then
        last_world_address = address
        instance.flush()
        libraries = {}
        if address then
            local name = w:GetFName():ToString()
            log:info("map changed: %s", name)
            game.MapChanged:Fire(name)
        end
    end
end

M.root = game
return M
