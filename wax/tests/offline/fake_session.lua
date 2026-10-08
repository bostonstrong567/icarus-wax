-- More of the stand-in world, on top of fake_world.lua and fake_values.lua: a character's stat list and its modifiers,
-- the game state of a prospect with its clock, weather and players, and the tables and libraries they are read with.
-- The values are the ones read in the running game on 2026-10-07 (.research\easy-api\notes.md and probe-results.md).
-- A list made here is as unkind as the engine's: reading outside it is counted in `strays` (in the game that makes the
-- list longer), and a list of an object that was freed counts as a touch of that object.
--   local session = dofile("wax/tests/offline/fake_session.lua")
--   local more = session.install(world, values, world.icarus(values))
--   more.player(over)                    kit.player with the stat list of a player's character
--   more.stats(who, { name = value })    the character's stats: what the game's getter answers, and the list it replicates
--   more.modifier(who, row, { uid, lifetime, remaining, class })      more.end_modifier(who, component)
--   more.prospect(over)                  a prospect's game state on the current world: .store, .players, .weather, .clock_store
--   more.title()                         the title screen's game state: no clock, no prospect, no weather
--   more.join(place, who)   more.drop(place, who)   more.travel(name, quiet)
--   session.calls                        how often the tables and the libraries were asked

local session = { strays = 0, reads = 0, walks = 0, stray_where = nil }
session.calls = { names = {}, rows = {}, NameToInt = 0, subsystem = 0 }

---@type any
local world = nil

local ARRAY = {}
ARRAY.__index = function(self, key)
    local owner = rawget(self, "__owner")
    if owner and rawget(owner, "__freed") then
        world.dead_touches = world.dead_touches + 1
        if world.dead_touches == 1 then
            world.dead_where = "a list of " .. tostring(rawget(owner, "__name")) .. "." .. tostring(key) .. debug.traceback("", 2)
        end
        error("touched a list of a freed object (" .. tostring(key) .. ")", 2)
    end
    local items = rawget(self, "__props")
    if key == "GetArrayNum" then return function() return #items end end
    if key == "IsValid" then return function() return true end end
    if key == "type" then return function() return "TArray" end end
    if key == "ForEach" then
        return function(_, fn)
            session.walks = session.walks + 1
            for index = 1, #items do
                if fn(index, { get = function() return items[index] end, type = function() return "RemoteUnrealParam" end }) then break end
            end
        end
    end
    if type(key) == "number" then
        session.reads = session.reads + 1
        if key >= 1 and key <= #items then return items[key] end
        session.strays = session.strays + 1
        session.stray_where = session.stray_where or debug.traceback(("entry %s of a list of %d"):format(tostring(key), #items), 2)
        return {}
    end
    error("a list has no " .. tostring(key), 2)
end
ARRAY.__len = function(self) return #rawget(self, "__props") end

-- An engine list of `items`, which stays the caller's table. `owner` is the object whose property holds it.
function session.list(items, owner)
    return setmetatable({ __props = items, __kind = "TArray", __owner = owner }, ARRAY)
end

-- Makes one field of a struct read as UE4SS reads an enum: the number comes back, and a global Enum_<field> is left
-- behind in the Lua state. session.enums counts those reads.
session.enums = 0
function session.enum_field(holder, field)
    local value = rawget(holder, field)
    rawset(holder, field, nil)
    return setmetatable(holder, {
        __index = function(_, key)
            if key ~= field then return nil end
            session.enums = session.enums + 1
            rawset(_G, "Enum_" .. field, { left_by = "the stand-in" })
            return value
        end,
        __newindex = function(self, key, new)
            if key == field then value = new else rawset(self, key, new) end
        end,
    })
end

-- The first rows of D_Stats in the game's order. A stat's number in a character's list is its place here, from 0.
local STAT_ROWS = 130
local STAT_AT = {
    [0] = "MaximumHealth_+", [1] = "BaseMaximumHealth_+", [2] = "BaseMaximumHealth_+%", [3] = "MaximumStamina_+",
    [6] = "MeleeDamage_+", [33] = "WeightCapacity_+", [58] = "MovementSpeed_+", [59] = "BaseMovementSpeed_+",
    [61] = "SprintSpeed_+", [65] = "CrouchSpeed_+", [69] = "SwimSpeed_+", [88] = "MaximumOxygen_+", [94] = "MaximumFood_+",
    [100] = "MaximumWater_+", [103] = "OxygenConsumptionPerHour_+", [106] = "FoodConsumptionPerHour_+",
    [109] = "WaterConsumptionPerHour_+", [112] = "HealthRegenPerMinute_+", [115] = "StaminaRegenPerMinute_+",
    [118] = "StaminaRegenDelay_+",
}
-- the game keeps these out of the list it replicates
local STAT_UNLISTED = { ["BaseMaximumHealth_+"] = true, ["BaseMaximumHealth_+%"] = true, ["BaseMovementSpeed_+"] = true }

session.PLAYER_STATS = {
    ["MaximumHealth_+"] = 300, ["BaseMaximumHealth_+"] = 300, ["MaximumStamina_+"] = 200, ["MeleeDamage_+"] = 5,
    ["WeightCapacity_+"] = 100, ["MovementSpeed_+"] = 355, ["BaseMovementSpeed_+"] = 355, ["SprintSpeed_+"] = 710,
    ["CrouchSpeed_+"] = 198, ["SwimSpeed_+"] = 159, ["MaximumOxygen_+"] = 300, ["MaximumFood_+"] = 300, ["MaximumWater_+"] = 300,
    ["OxygenConsumptionPerHour_+"] = 480, ["FoodConsumptionPerHour_+"] = 600, ["WaterConsumptionPerHour_+"] = 900,
    ["HealthRegenPerMinute_+"] = 25, ["StaminaRegenPerMinute_+"] = 2400, ["StaminaRegenDelay_+"] = 1000,
}

session.MODIFIERS = {
    { "Health_Regen", "Health Regen", 0 }, { "Drink_Cooling", "Cooling", 0 }, { "Dirty_Water", "Tainted Water", 1 },
    { "Berry", "Berry", 0 }, { "Overburdened", "Heavy", 1 }, { "Wet", "", 2 }, { "Nameless", nil, 9 },
}

session.WEATHER = {
    T0_Conifer_Rain = 0, T1_Conifer_Rain = 1, T3_Conifer_Rain = 3, T6_Conifer_Rain = 6, T2_Arctic_Snow = 2,
    T3_Arctic_Whiteout = 3, T1_Desert_Wind = 1, NoWeather = 0,
}

session.PHASES = { { "Invalid", 0, 0 }, { "Night", 18, 6 }, { "Morning", 6, 10 }, { "Day", 10, 14 }, { "Afternoon", 14, 18 } }

-- A table whose asks are counted: session.calls.names[path] and session.calls.rows[path].
local function counted(path, rows, order)
    local data = world.table(path, rows, order)
    local get_names, find_row = data.GetRowNames, data.FindRow
    session.calls.names[path], session.calls.rows[path] = 0, 0
    function data:GetRowNames()
        session.calls.names[path] = session.calls.names[path] + 1
        return get_names(self)
    end
    function data:FindRow(name)
        session.calls.rows[path] = session.calls.rows[path] + 1
        if type(name) ~= "string" then error("CRASH: FindRow was given a " .. type(name), 0) end
        return find_row(self, name)
    end
    return data
end

function session.install(the_world, values, kit)
    world = the_world
    local classes = kit.classes
    local INT, FLOAT, BOOL, OBJECT = "IntProperty", "FloatProperty", "BoolProperty", "ObjectProperty"
    local HANDLE = "/Script/IcarusUtilities.RowHandle"
    local MODIFIER_ROW, PAIRS, PROSPECT = "/Script/Icarus.ModifierStatesRowHandle", "/Script/Icarus.StatsRepArray",
        "/Script/IcarusGenerated.ProspectInfo"
    values.struct(MODIFIER_ROW, HANDLE, {})

    local function class(path, super, members, functions)
        local made = values.class(path, super and classes[super], members, functions)
        classes[path:match("([^%.:/]+)$")] = made
        return made
    end
    local function merged(base, over)
        local out = {}
        for key, value in pairs(base) do out[key] = value end
        for key, value in pairs(over or {}) do out[key] = value end
        return out
    end
    local function row_handle(row, table_name) return { RowName = values.name(row), DataTableName = values.name(table_name) } end

    local more, serial = { classes = classes }, 0
    local subsystems = {}       -- world object -> its clock subsystem

    -- ---------------------------------------------------------------------------------------------------------- stats

    local stat_names, stat_place, stat_rows = {}, {}, {}
    for place = 0, STAT_ROWS - 1 do
        local name = STAT_AT[place] or ("Filler%03d_+"):format(place)
        stat_names[place + 1], stat_place[name:lower()] = name, place
        stat_rows[name] = { bIsReplicated = STAT_AT[place] ~= nil and not STAT_UNLISTED[name] }
    end
    more.stats_table = counted("/Engine/Transient.D_Stats", stat_rows, stat_names)
    more.stat_rows, more.stat_names = stat_rows, stat_names

    class("/Script/Icarus.StatsLibrary", "Object", {}, {
        NameToInt = { { "NameValue", "NameProperty" }, returns = INT, call = function(_, args)
            session.calls.NameToInt = session.calls.NameToInt + 1
            local place = stat_place[args.NameValue:ToString():lower()]
            return place or -1
        end },
    })
    more.stats_library = values.part(classes.StatsLibrary, "Default__StatsLibrary", {})
    world.static["/Script/Icarus.Default__StatsLibrary"] = more.stats_library
    rawget(classes.IcarusStatContainer, "__members").ReplicatedStatArray = { "StructProperty", struct = PAIRS }

    -- What the game's getter answers for each name, and the list of pairs it replicates: listed stats that have a value.
    function more.stats(who, by_name)
        local list = {}
        for place = 0, STAT_ROWS - 1 do
            local name = stat_names[place + 1]
            local value = by_name[name]
            if value and value ~= 0 and stat_rows[name].bIsReplicated then list[#list + 1] = { Stat = place, Value = value } end
        end
        who.stats_store.Stats = merged(by_name)
        who.stats_store.ReplicatedStatArray = { StatList = session.list(list, who.stats) }
        who.stat_list = list
        return list
    end

    function more.player(over)
        local who = kit.player(over)
        more.stats(who, merged(session.PLAYER_STATS, over and over.stats))
        return who
    end

    function more.creature(over)
        local who = kit.creature(over)
        more.stats(who, merged({ ["MaximumHealth_+"] = 102, ["MovementSpeed_+"] = 440, ["HealthRegenPerMinute_+"] = 12 }, over and over.stats))
        return who
    end

    -- ------------------------------------------------------------------------------------------------------ modifiers

    local modifier_rows, modifier_names = {}, {}
    for i, entry in ipairs(session.MODIFIERS) do
        modifier_names[i] = entry[1]
        modifier_rows[entry[1]] = session.enum_field({ ModifierName = entry[2] and values.text(entry[2]) or nil, Type = entry[3] }, "Type")
    end
    more.modifiers_table = counted("/Engine/Transient.D_ModifierStates", modifier_rows, modifier_names)
    class("/Script/Icarus.ModifierStateComponent", "ActorComponent", {
        DataRowHandleNew = { "StructProperty", struct = MODIFIER_ROW }, ModifierUID = INT, ModifierLifetime = FLOAT,
        RemainingTime = FLOAT, ReplicatedRemainingTime = "UInt16Property", Causer = OBJECT,
    })
    class("/Game/BP/Modifiers/BP_Modifier_Drink.BP_Modifier_Drink_C", "ModifierStateComponent")

    -- Puts a modifier on a character: a component of the character itself, as in the game.
    function more.modifier(who, row, spec)
        spec = spec or {}
        serial = serial + 1
        local remaining = spec.remaining or 300
        local component, store = values.part(classes[spec.class or "ModifierStateComponent"], row .. "_" .. serial, {
            DataRowHandleNew = row_handle(row, "D_ModifierStates"), ModifierUID = spec.uid or serial,
            ModifierLifetime = spec.lifetime or 300, RemainingTime = remaining,
            ReplicatedRemainingTime = math.floor(remaining * 10 + 0.5), Causer = world.INVALID,
        })
        rawset(component, "__outer", who.actor)
        local parts = rawget(who.actor, "__components")
        parts[#parts + 1] = component
        return component, store
    end

    -- Takes it off again and frees it, as the engine does a while after a modifier ended.
    function more.end_modifier(who, component)
        local parts = rawget(who.actor, "__components")
        for i = #parts, 1, -1 do
            if parts[i] == component then table.remove(parts, i) end
        end
        rawset(component, "__freed", true)
    end

    -- ---------------------------------------------------------------------------------------------------- the session

    local phase_rows, phase_names = {}, {}
    for i, entry in ipairs(session.PHASES) do
        phase_names[i] = entry[1]
        phase_rows[entry[1]] = { StartingHour = entry[2], EndingHour = entry[3] }
    end
    more.time_table = counted("/Engine/Transient.D_TimeOfDay", phase_rows, phase_names)
    more.phase_rows = phase_rows

    local weather_rows, weather_names = {}, {}
    for name, tier in pairs(session.WEATHER) do
        weather_names[#weather_names + 1] = name
        weather_rows[name] = { Tier = tier, DurationSeconds = 460 }
    end
    table.sort(weather_names)
    more.weather_table = counted("/Engine/Transient.D_WeatherEvents", weather_rows, weather_names)
    more.weather_rows = weather_rows

    class("/Script/Engine.GameStateBase", "Actor", { PlayerArray = { "ArrayProperty", inner = OBJECT } })
    class("/Script/Icarus.IcarusGameStateSurvival", "GameStateBase", {
        TimeOfDay = FLOAT, SecondsPerGameDay = INT, ProspectDurationSec = INT, LevelTimeElapsedSec = INT, Seed = INT,
        bIsOpenWorldProspect = BOOL, bIsOutpostProspect = BOOL, UITimeText = "TextProperty",
        ReplicatedActiveProspect = { "StructProperty", struct = PROSPECT },
    })
    class("/Game/BP/Systems/BP_IcarusGameState.BP_IcarusGameState_C", "IcarusGameStateSurvival")
    class("/Game/BP/Systems/BP_TitleScreenGameState.BP_TitleScreenGameState_C", "GameStateBase")
    class("/Script/Engine.GameModeBase", "Actor")
    class("/Script/Icarus.IcarusGameModeSurvival", "GameModeBase", { WeatherController = OBJECT })
    class("/Game/BP/Systems/BP_IcarusGameMode.BP_IcarusGameMode_C", "IcarusGameModeSurvival")
    class("/Script/Icarus.WeatherController", "Actor", { CurrentWeather = { "ArrayProperty", inner = "StructProperty" } })
    class("/Game/BP/Systems/BP_WeatherController.BP_WeatherController_C", "WeatherController")
    class("/Script/Icarus.TimeOfDaySubsystem", "Object", { TimeScale = FLOAT })
    class("/Script/Engine.SubsystemBlueprintLibrary", "Object", {}, {
        GetWorldSubsystem = { { "ContextObject", OBJECT }, { "Class", "ClassProperty" }, returns = OBJECT, call = function(_, args)
            session.calls.subsystem = session.calls.subsystem + 1
            if args.Class ~= classes.TimeOfDaySubsystem then return world.INVALID end
            return subsystems[args.ContextObject] or world.INVALID
        end },
    })
    more.subsystem_library = values.part(classes.SubsystemBlueprintLibrary, "Default__SubsystemBlueprintLibrary", {})
    world.static["/Script/Engine.Default__SubsystemBlueprintLibrary"] = more.subsystem_library

    local function level() return rawget(world.engine.GameViewport, "__props").World end
    more.level = level

    local function weather_entry(event, biome, since)
        return { WeatherEvent = row_handle(event, "D_WeatherEvents"), Biome = row_handle(biome, "D_Biomes"), StartTime = since }
    end
    more.weather_entry = weather_entry

    -- A prospect on the world the viewport shows now. over: state, prospect (tables of values), host = false, weather, scale.
    function more.prospect(over)
        over = over or {}
        serial = serial + 1
        local here = level()
        local place = { world = here, players = {}, weather = {} }
        place.state, place.store = values.actor(classes.BP_IcarusGameState_C, "BP_IcarusGameState_C_" .. serial, merged({
            TimeOfDay = 712.77508544922, SecondsPerGameDay = 4060, ProspectDurationSec = 604800, LevelTimeElapsedSec = 44208,
            Seed = 1117682762, bIsOpenWorldProspect = false, bIsOutpostProspect = false, UITimeText = values.text("11:52"),
            Location = { 0, 0, 0 },
            ReplicatedActiveProspect = session.enum_field(merged({
                ProspectID = world.string("B3BF146A43E90D4239F50A80B5D13762"), ProspectDTKey = world.string("Tier1_Forest_Recon_0"),
                FactionMissionDTKey = world.string("OLY_Forest_Recon"), LobbyName = world.string(""), Difficulty = 2,
                ProspectState = 2, ElapsedTime = 44207, Insurance = false, NoRespawns = false, SelectedDropPoint = 0,
            }, over.prospect), "Difficulty"),
        }, over.state))
        place.store.PlayerArray = session.list(place.players, place.state)
        local held = rawget(here, "__props")
        held.GameState = place.state
        held.AuthorityGameMode = nil
        if over.host ~= false then
            for i, entry in ipairs(over.weather or {}) do place.weather[i] = weather_entry(entry[1], entry[2], entry[3]) end
            place.controller, place.controller_store = values.actor(classes.BP_WeatherController_C,
                "BP_WeatherController_C_" .. serial, { Location = { 0, 0, 0 } })
            place.controller_store.CurrentWeather = session.list(place.weather, place.controller)
            place.mode, place.mode_store = values.actor(classes.BP_IcarusGameMode_C, "BP_IcarusGameMode_C_" .. serial,
                { WeatherController = place.controller, Location = { 0, 0, 0 } })
            held.AuthorityGameMode = place.mode
        end
        place.clock, place.clock_store = values.part(classes.TimeOfDaySubsystem, "TimeOfDaySubsystem_" .. serial,
            { TimeScale = over.scale or 1 })
        subsystems[here] = place.clock
        return place
    end

    -- The title screen: a game state with players and nothing else, and a game mode with no weather.
    function more.title()
        serial = serial + 1
        local here = level()
        local place = { world = here, players = {} }
        place.state, place.store = values.actor(classes.BP_TitleScreenGameState_C, "BP_TitleScreenGameState_C_" .. serial,
            { Location = { 0, 0, 0 } })
        place.store.PlayerArray = session.list(place.players, place.state)
        place.mode = values.actor(classes.GameModeBase, "GameModeBase_" .. serial, { Location = { 0, 0, 0 } })
        local held = rawget(here, "__props")
        held.GameState, held.AuthorityGameMode = place.state, place.mode
        place.clock, place.clock_store = values.part(classes.TimeOfDaySubsystem, "TimeOfDaySubsystem_" .. serial, { TimeScale = 1 })
        subsystems[here] = place.clock
        return place
    end

    -- A player of the session: `who` is a character made by kit.player, whose player state goes into the list.
    function more.join(place, who)
        place.players[#place.players + 1] = who.player_state
        return who.player_state
    end

    -- The player leaves: the player state is off the list, ends play and is freed.
    function more.drop(place, who)
        for i = #place.players, 1, -1 do
            if place.players[i] == who.player_state then table.remove(place.players, i) end
        end
        world.destroy(who.player_state)
        world.free(who.player_state)
    end

    -- A map change. The clock of the world that is left is freed with it.
    function more.travel(name, quiet)
        local clock = subsystems[level()]
        if clock then rawset(clock, "__freed", true) end
        return world.travel(name, quiet)
    end

    return more
end

return session
