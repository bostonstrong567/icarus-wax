-- A small stand-in for the engine's world: classes, actors, components and data tables.
-- An object that was freed raises on any use, which is how the tests prove nothing touches one.

local world = { dead_touches = 0, touches = 0, static = {}, actors = {}, began = nil, ended = nil, watch = nil }

local PENDING_KILL = 0x20000000
local next_address = 0x10000
local name_indexes, name_count = {}, 0

local function name_index(text)
    local key = text:lower()
    if not name_indexes[key] then
        name_count = name_count + 1
        name_indexes[key] = name_count
    end
    return name_indexes[key]
end

function world.name(text)
    return { ToString = function() return text end, GetComparisonIndex = function() return name_index(text) end }
end

local INVALID = setmetatable({ __invalid = true }, { __index = function(_, key)
    if key == "IsValid" then return function() return false end end
    if key == "type" then return function() return "UObject" end end
    error("used an invalid object (" .. tostring(key) .. ")", 2)
end })
world.INVALID = INVALID

local methods = {}
local Object = {}
Object.__index = function(self, key)
    if rawget(self, "__freed") then
        world.dead_touches = world.dead_touches + 1
        if world.dead_touches == 1 then world.dead_where = tostring(rawget(self, "__name")) .. "." .. tostring(key) .. debug.traceback("", 2) end
        error("touched a freed object (" .. tostring(key) .. ")", 2)
    end
    world.touches = world.touches + 1
    local method = methods[key]
    if method then return method end
    local props = rawget(self, "__props")
    -- world.watch = {} counts how often each property is read
    local watch = world.watch
    if watch then watch[key] = (watch[key] or 0) + 1 end
    local value = props[key]
    if value ~= nil then return value end
    if rawget(self, "__kind") == "TArray" and key == #props + 1 then
        props[key] = { Weight = 0, Object = INVALID }
        return props[key]
    end
    return INVALID
end
Object.__newindex = function(self, key, value)
    if rawget(self, "__freed") then
        world.dead_touches = world.dead_touches + 1
        error("wrote to a freed object (" .. tostring(key) .. ")", 2)
    end
    rawget(self, "__props")[key] = value
end

local function new(class, name, props, kind)
    next_address = next_address + 0x100
    return setmetatable({ __class = class, __name = name, __address = next_address, __props = props or {},
                          __kind = kind or "UObject", __flags = 0 }, Object)
end

function methods.IsValid() return true end
function methods.GetAddress(self) return rawget(self, "__address") end
function methods.GetFName(self) return world.name(rawget(self, "__name")) end
function methods.GetClass(self) return rawget(self, "__class") end
function methods.GetOuter(self) return rawget(self, "__outer") or INVALID end
function methods.GetOwner(self) return rawget(self, "__outer") or INVALID end
function methods.type(self) return rawget(self, "__kind") end
function methods.HasAnyInternalFlags(self, flag) return rawget(self, "__flags") & flag ~= 0 end
function methods.GetFullName(self) return "Class " .. (rawget(self, "__path") or rawget(self, "__name")) end
function methods.GetSuperStruct(self) return rawget(self, "__super") or INVALID end
function methods.IsA(self, class)
    local mine = rawget(self, "__class")
    while mine do
        if mine == class then return true end
        mine = rawget(mine, "__super")
    end
    return false
end
-- A property as reflection hands it out. `spec` is a type name, or { type name, struct = "Vector" } or { type name, inner = type name }.
local function property(name, spec)
    local type_name = type(spec) == "table" and spec[1] or spec
    local detail = type(spec) == "table" and spec or {}
    local function named(text) return { GetFName = function() return world.name(text) end } end
    return {
        GetFName = function() return world.name(name) end,
        GetClass = function() return named(type_name) end,
        GetStruct = function()
            if not detail.struct then error("this property holds no struct", 2) end
            return named(detail.struct)
        end,
        GetInner = function()
            if not detail.inner then error("this property holds no array", 2) end
            return { GetClass = function() return named(detail.inner) end }
        end,
    }
end

function methods.ForEachProperty(self, fn)
    for name, spec in pairs(rawget(self, "__members") or {}) do fn(property(name, spec)) end
end
-- A class's functions: name -> a list of { parameter name, type name }.
function methods.ForEachFunction(self, fn)
    local path = rawget(self, "__path") or rawget(self, "__name")
    for name, params in pairs(rawget(self, "__functions") or {}) do
        fn({
            GetFName = function() return world.name(name) end,
            GetFullName = function() return "Function " .. tostring(path) .. ":" .. name end,
            ForEachProperty = function(_, each)
                for _, param in ipairs(params) do each(property(param[1], param[2])) end
            end,
        })
    end
end
function methods.ForEach(self, fn)
    local props = rawget(self, "__props")
    for index = 1, #props do
        if fn(index, { get = function() return props[index] end, type = function() return "RemoteUnrealParam" end }) then break end
    end
end
function methods.GetAttachedActors(self, out)
    for _, actor in ipairs(rawget(self, "__attached") or {}) do
        out[#out + 1] = { get = function() return actor end, type = function() return "RemoteUnrealParam" end }
    end
end
function methods.K2_GetActorLocation(self)
    local at = rawget(self, "__props").Location
    return { X = at[1], Y = at[2], Z = at[3] }
end
function methods.K2_GetComponentsByClass(self, class)
    local out = {}
    for _, component in ipairs(rawget(self, "__components") or {}) do
        if component:IsA(class) then
            out[#out + 1] = { get = function() return component end, type = function() return "RemoteUnrealParam" end }
        end
    end
    return out
end
function methods.SetVectorParameterValue(self, name, value) rawget(self, "__props")[name] = value end
function methods.SetScalarParameterValue(self, name, value) rawget(self, "__props")[name] = value end
function methods.CreateDynamicMaterialInstance(_, _, parent)
    world.copies = (world.copies or 0) + 1
    return new(nil, "MaterialInstanceDynamic_" .. world.copies, { Parent = parent })
end
function methods.GetArrayNum(self) return #rawget(self, "__props") end
function methods.SetRenderCustomDepth(self, on) rawget(self, "__props").bRenderCustomDepth = on end
function methods.SetCustomDepthStencilValue(self, value) rawget(self, "__props").CustomDepthStencilValue = value end

-- A class. `members` maps property names to property type names (see `property` above), `functions` maps names to parameter lists.
function world.class(path, super, members, functions)
    local name = path:match("([^%.:/]+)$")
    local class = new(nil, name, {}, "UClass")
    rawset(class, "__path", path)
    rawset(class, "__super", super)
    rawset(class, "__members", members or {})
    rawset(class, "__functions", functions or {})
    world.static[path] = class
    return class
end

-- Makes these objects answer type() with "userdata", as the engine's do, so reads through an Instance convert them.
function world.as_userdata()
    local real = type
    rawset(_G, "type", function(value)
        local kind = real(value)
        if kind == "table" and (rawget(value, "__props") ~= nil or rawget(value, "__invalid")) then return "userdata" end
        return kind
    end)
end

-- Attaches one actor to another, the way GetAttachedActors reports it.
function world.attach(child, parent)
    local list = rawget(parent, "__attached") or {}
    list[#list + 1] = child
    rawset(parent, "__attached", list)
end

function world.table(path, rows, order)
    local data = { IsValid = function() return true end }
    function data:GetRowNames() return order end
    function data:FindRow(name)
        for key, row in pairs(rows) do
            if key:lower() == name:lower() then return row end
        end
        return nil
    end
    world.static[path] = data
    return data
end

function world.handle(row) return { RowName = world.name(row) } end

-- Makes an actor without telling anyone, as one that was in the world before tracking started.
function world.place(class, name, props, components)
    local actor = new(class, name, props, "AActor")
    rawset(actor, "__components", components or {})
    for _, component in ipairs(components or {}) do rawset(component, "__outer", actor) end
    world.actors[#world.actors + 1] = actor
    return actor
end

function world.component(class, name, props)
    return new(class, name, props)
end

function world.spawn(class, name, props, components)
    local actor = world.place(class, name, props, components)
    if world.began then world.began({ get = function() return actor end }) end
    return actor
end

-- Ends play. The object stays readable until world.free, like an actor waiting for garbage collection.
function world.destroy(actor, reason)
    if world.ended then
        world.ended({ get = function() return actor end }, { get = function() return reason or 0 end })
    end
    rawset(actor, "__flags", PENDING_KILL)
end

function world.free(actor)
    rawset(actor, "__freed", true)
    for _, component in ipairs(rawget(actor, "__components") or {}) do rawset(component, "__freed", true) end
    for i = #world.actors, 1, -1 do
        if world.actors[i] == actor then table.remove(world.actors, i) end
    end
end

-- An engine array: numbered values plus GetArrayNum.
function world.array(values) return new(nil, "Array", values, "TArray") end

function world.object(name, props) return new(nil, name, props) end

-- Makes `pawn` the local player's character, the way game.Character finds it.
function world.possess(pawn)
    if world.controller then
        world.controller.Pawn = pawn or INVALID
        return
    end
    local controller = world.object("PlayerController_0", { Pawn = pawn or INVALID })
    world.controller = controller
    local player = world.object("LocalPlayer_0", { PlayerController = controller })
    local game_instance = world.object("GameInstance_0", { LocalPlayers = world.array({ player }) })
    local level = world.object("World_0", {})
    world.engine = world.object("Engine_0", { GameViewport = world.object("Viewport_0", { World = level, GameInstance = game_instance }) })
end

-- A string as a raw property read hands it out: userdata with ToString.
function world.string(text)
    return setmetatable({ __props = {}, __kind = "FString" }, { __index = function(_, key)
        if key == "ToString" then return function() return text end end
        if key == "type" then return function() return "FString" end end
        error("a string value has no " .. tostring(key), 2)
    end })
end

-- A map change: every actor ends play with reason 1 and is freed, the player has no pawn, the viewport holds another world.
-- quiet = true frees the actors without end of play being seen.
function world.travel(name, quiet)
    local leaving = {}
    for i, actor in ipairs(world.actors) do leaving[i] = actor end
    for _, actor in ipairs(leaving) do
        if not quiet then world.destroy(actor, 1) end
        world.free(actor)
    end
    if world.controller then world.controller.Pawn = INVALID end
    local next_world = world.object(name or "World_Next", {})
    if world.engine then rawget(world.engine.GameViewport, "__props").World = next_world end
    return next_world
end

-- The game's characters: classes with the members the game index gives them, and makers whose values are the ones read in
-- the running game on 2026-10-07 (.research\easy-api\notes.md 2.1 and 2.11). `values` is fake_values, already installed.
-- A value taken out of a store (store.CurrentBiome = nil) reads as a member the class does not have: an invalid object.
--   local kit = world.icarus(values)
--   local me = kit.player()          me.actor, me.store, me.state, me.state_store, me.stats_store, me.root_store, me.movement_store
--   kit.creature()   kit.worm() (an IcarusPawn)   kit.station() (the pawn in the station: no state, no stats)
--   kit.move(who, x, y, z)   kit.seat(who, on)   kit.kill(who)   kit.revive(who)
function world.icarus(values)
    local VECTOR, ROTATOR = "/Script/CoreUObject.Vector", "/Script/CoreUObject.Rotator"
    local HANDLE = "/Script/IcarusUtilities.RowHandle"
    local BIOME, STAT, WEATHER, SETUP = "/Script/Icarus.BiomesRowHandle", "/Script/Icarus.StatsRowHandle",
        "/Script/Icarus.WeatherEventsRowHandle", "/Script/Icarus.AISetupRowHandle"
    values.struct(VECTOR, nil, { { "X", "FloatProperty" }, { "Y", "FloatProperty" }, { "Z", "FloatProperty" } })
    values.struct(ROTATOR, nil, { { "Pitch", "FloatProperty" }, { "Yaw", "FloatProperty" }, { "Roll", "FloatProperty" } })
    values.struct("/Script/IcarusEngineUtilities.RowHandleInternal", nil, {})
    values.struct(HANDLE, "/Script/IcarusEngineUtilities.RowHandleInternal",
        { { "DataTablePtr", "WeakObjectProperty" }, { "RowName", "NameProperty" }, { "DataTableName", "NameProperty" } })
    for _, path in ipairs({ BIOME, STAT, WEATHER, SETUP }) do values.struct(path, HANDLE, {}) end

    local function held(self) return rawget(self, "__props") end
    local function handle(row, table_name) return { RowName = values.name(row), DataTableName = values.name(table_name) } end
    local INT, FLOAT, BOOL, OBJECT = "IntProperty", "FloatProperty", "BoolProperty", "ObjectProperty"
    local classes = {}
    local function class(path, super, members, functions)
        local made = values.class(path, super and classes[super], members, functions)
        classes[path:match("([^%.:/]+)$")] = made
        return made
    end

    class("/Script/CoreUObject.Object")
    class("/Script/Engine.Actor", "Object", { RootComponent = OBJECT }, {
        K2_GetActorLocation = { returns = { "StructProperty", struct = VECTOR } },
        K2_GetActorRotation = { returns = { "StructProperty", struct = ROTATOR }, call = function(self)
            local turn = held(self).Rotation or { 0, 0, 0 }
            return { Pitch = turn[1], Yaw = turn[2], Roll = turn[3] }
        end },
    })
    class("/Script/Engine.World", "Object")
    class("/Script/Engine.ActorComponent", "Object")
    class("/Script/Engine.SceneComponent", "ActorComponent", {
        RelativeLocation = { "StructProperty", struct = VECTOR }, RelativeRotation = { "StructProperty", struct = ROTATOR },
        AttachParent = OBJECT,
    })
    class("/Script/Engine.CapsuleComponent", "SceneComponent")
    class("/Script/Engine.MovementComponent", "ActorComponent", { Velocity = { "StructProperty", struct = VECTOR } })
    class("/Script/Engine.CharacterMovementComponent", "MovementComponent", { MaxWalkSpeed = FLOAT, MovementMode = "ByteProperty" })
    class("/Script/Icarus.IcarusPlayerMovementComponent", "CharacterMovementComponent")
    class("/Script/Engine.Pawn", "Actor", { PlayerState = OBJECT, Controller = OBJECT })
    class("/Script/Engine.SpectatorPawn", "Pawn")
    class("/Script/Engine.Character", "Pawn", { CharacterMovement = OBJECT, bIsCrouched = BOOL, JumpMaxCount = INT })
    class("/Script/Engine.PlayerState", "Actor", { PlayerNamePrivate = "StrProperty", PawnPrivate = OBJECT },
        { GetPlayerName = { returns = "StrProperty", call = function(self) return held(self).PlayerNamePrivate:ToString() end } })
    class("/Game/BP/Player/BP_IcarusPlayerState.BP_IcarusPlayerState_C", "PlayerState", { bIsHost = BOOL })

    class("/Script/Icarus.ActorState", "ActorComponent", {
        Health = INT, MaxHealth = INT, Armor = INT, MaxArmor = INT, Shelter = FLOAT, ExternalTemperature = INT,
        ModifiedExternalTemperature = INT, ModifiedInternalTemperature = INT, CurrentBiome = { "StructProperty", struct = BIOME },
        CurrentAliveState = "EnumProperty", bHasHealthRegen = BOOL,
    })
    class("/Script/Icarus.CharacterState", "ActorState",
        { Stamina = INT, MaxStamina = INT, TotalExperience = INT, Level = INT, bHasStaminaRegen = BOOL })
    class("/Script/Icarus.SurvivalCharacterState", "CharacterState", {
        OxygenLevel = INT, MinOxygen = INT, MaxOxygen = INT, WaterLevel = INT, MinWater = INT, MaxWater = INT, FoodLevel = INT,
        MinFood = INT, MaxFood = INT, InternalTemperature = INT, RadiationLevel = INT, MaxRadiation = INT,
    })
    class("/Script/Icarus.PlayerCharacterState", "SurvivalCharacterState",
        { LocalWeatherEvent = { "StructProperty", struct = WEATHER }, CurrentProspectLocation = "EnumProperty" })
    -- a stat the character does not have answers 0, as in the game
    class("/Script/Icarus.IcarusStatContainer", "ActorComponent", {}, {
        GetStatByRowHandle = { { "StatRowHandle", "StructProperty", struct = STAT }, returns = INT, call = function(self, args)
            local name = args.StatRowHandle.RowName
            return (held(self).Stats or {})[name and name:ToString() or ""] or 0
        end },
    })

    class("/Script/Icarus.IcarusCharacter", "Character", { ActorState = OBJECT, StatContainer = OBJECT, bIsSprinting = BOOL },
        { IsSprinting = { returns = BOOL, call = function(self) return held(self).bIsSprinting == true end } })
    class("/Script/Icarus.IcarusPlayerCharacter", "IcarusCharacter", { RespawnCount = INT, AttachedToSeat = OBJECT })
    class("/Script/Icarus.IcarusPlayerCharacterSurvival", "IcarusPlayerCharacter", { FocusedQuickbarSlot = INT }, {
        GetIsInCave = { returns = BOOL, call = function(self) return held(self).InCave == true end },
        IsAlive = { returns = BOOL, call = function(self) return held(self).ActorState.CurrentAliveState == 0 end },
    })
    class("/Game/BP/Player/BP_IcarusPlayerCharacterSurvival.BP_IcarusPlayerCharacterSurvival_C", "IcarusPlayerCharacterSurvival",
        { CurrentWeight = INT })
    class("/Script/Icarus.IcarusPlayerCharacterSpace", "IcarusPlayerCharacter")
    class("/Game/BP/Player/BP_IcarusPlayerCharacterSpace.BP_IcarusPlayerCharacterSpace_C", "IcarusPlayerCharacterSpace")
    class("/Script/Icarus.IcarusNPCCharacter", "IcarusCharacter",
        { AISetupRow = { "StructProperty", struct = SETUP }, CurrentLevel = INT, CurrentTarget = OBJECT })
    class("/Game/BP/AI/BP_NPC_Wolf_Conifer_Character.BP_NPC_Wolf_Conifer_Character_C", "IcarusNPCCharacter")
    class("/Script/Icarus.IcarusPawn", "Pawn",
        { ActorState = OBJECT, StatContainer = OBJECT, AISetup = { "StructProperty", struct = SETUP }, CurrentLevel = INT })
    class("/Game/BP/AI/BP_CRE_CaveWorm.BP_CRE_CaveWorm_C", "IcarusPawn")

    local kit, serial = { classes = classes }, 0

    local function merged(base, over)
        local out = {}
        for key, value in pairs(base) do out[key] = value end
        for key, value in pairs(over or {}) do out[key] = value end
        return out
    end

    -- One character: the actor, its parts, and for each what the engine holds. `spec.state_class` nil makes one without a state.
    local function make(spec)
        serial = serial + 1
        local who, parts = { name = spec.class .. "_" .. serial }, {}
        local at, facing = spec.at or { 0, 0, 0 }, spec.facing or { 0, 0, 0 }
        local actor_values = merged({ Location = { at[1], at[2], at[3] }, Rotation = { facing[1], facing[2], facing[3] } }, spec.actor)
        local function part(key, kept_as, class_name, name, initial)
            local object, store = values.part(classes[class_name], name, initial)
            who[key], who[key .. "_store"] = object, store
            parts[#parts + 1] = object
            actor_values[kept_as] = object
        end
        part("root", "RootComponent", "CapsuleComponent", "CollisionCylinder", {
            RelativeLocation = { X = at[1], Y = at[2], Z = at[3] },
            RelativeRotation = { Pitch = facing[1], Yaw = facing[2], Roll = facing[3] }, AttachParent = INVALID,
        })
        if spec.state_class then part("state", "ActorState", spec.state_class, "ActorState", spec.state) end
        if spec.stats then part("stats", "StatContainer", "IcarusStatContainer", "Stat Container", { Stats = spec.stats }) end
        if spec.movement then part("movement", "CharacterMovement", "IcarusPlayerMovementComponent", "CharMoveComp", spec.movement) end
        if spec.player then
            who.player_state, who.player_state_store = values.actor(classes.BP_IcarusPlayerState_C, "BP_IcarusPlayerState_C_" .. serial,
                { PlayerNamePrivate = world.string(spec.player), bIsHost = true, Location = { 0, 0, 0 } })
            actor_values.PlayerState = who.player_state
        end
        who.actor, who.store = values.actor(classes[spec.class], who.name, actor_values, parts)
        if who.player_state_store then who.player_state_store.PawnPrivate = who.actor end
        if world.began then world.began({ get = function() return who.actor end }) end
        return who
    end

    -- The player's character in a prospect. `over` may give at, facing, name, and tables state, actor, stats and movement.
    function kit.player(over)
        over = over or {}
        return make({
            class = "BP_IcarusPlayerCharacterSurvival_C", state_class = "PlayerCharacterState", player = over.name or "Player One",
            at = over.at or { 154511.5625, 184153.609375, -24059.841796875 }, facing = over.facing or { 0, 68.125, 0 },
            state = merged({
                Health = 300, MaxHealth = 300, Armor = 0, MaxArmor = 0, CurrentAliveState = 0, Shelter = 0.019135981798172,
                ExternalTemperature = 2541, ModifiedExternalTemperature = 2541, ModifiedInternalTemperature = 2541,
                InternalTemperature = 2541, bHasHealthRegen = true, Stamina = 200, MaxStamina = 200, Level = 3,
                TotalExperience = 25086, bHasStaminaRegen = true, OxygenLevel = 288, MinOxygen = 0, MaxOxygen = 300,
                WaterLevel = 278, MinWater = 0, MaxWater = 300, FoodLevel = 285, MinFood = 0, MaxFood = 300, RadiationLevel = 0,
                MaxRadiation = 1000, CurrentBiome = handle("Conifer", "D_Biomes"), LocalWeatherEvent = handle("None", "D_WeatherEvents"),
                CurrentProspectLocation = 2,
            }, over.state),
            stats = merged({ ["MaximumHealth_+"] = 300, ["MaximumStamina_+"] = 200, ["MovementSpeed_+"] = 355,
                ["WeightCapacity_+"] = 100 }, over.stats),
            movement = merged({ Velocity = { X = 0, Y = 0, Z = 0 }, MaxWalkSpeed = 420, MovementMode = 1 }, over.movement),
            actor = merged({ bIsCrouched = false, bIsSprinting = false, JumpMaxCount = 1, RespawnCount = 17, CurrentWeight = 1170,
                FocusedQuickbarSlot = 11, InCave = false, AttachedToSeat = INVALID }, over.actor),
        })
    end

    -- The wolf read on 2026-10-07: a creature that is an IcarusNPCCharacter.
    function kit.creature(over)
        over = over or {}
        return make({
            class = "BP_NPC_Wolf_Conifer_Character_C", state_class = "CharacterState", at = over.at, facing = over.facing,
            state = merged({ Health = 102, MaxHealth = 102, Armor = 0, MaxArmor = 0, CurrentAliveState = 0, Shelter = 0,
                ExternalTemperature = 2541, ModifiedExternalTemperature = 2541, ModifiedInternalTemperature = 2541,
                Stamina = 100, MaxStamina = 100, Level = 16, TotalExperience = 0, CurrentBiome = handle("Conifer", "D_Biomes") }, over.state),
            stats = merged({ ["MaximumHealth_+"] = 102 }, over.stats),
            movement = merged({ Velocity = { X = 0, Y = 0, Z = 0 }, MaxWalkSpeed = 440, MovementMode = 1 }, over.movement),
            actor = merged({ bIsCrouched = false, bIsSprinting = false, CurrentLevel = 16, CurrentTarget = INVALID,
                AISetupRow = handle("Conifer_Wolf", "D_AISetup") }, over.actor),
        })
    end

    -- A creature that is an IcarusPawn: a plain state with no stamina and no level, and no movement component.
    function kit.worm(over)
        over = over or {}
        return make({
            class = "BP_CRE_CaveWorm_C", state_class = "ActorState", at = over.at, facing = over.facing,
            state = merged({ Health = 450, MaxHealth = 450, Armor = 0, MaxArmor = 0, CurrentAliveState = 0, Shelter = 0,
                CurrentBiome = handle("Conifer", "D_Biomes") }, over.state),
            stats = merged({}, over.stats),
            actor = merged({ CurrentLevel = 10, AISetup = handle("CaveWorm", "D_AISetup") }, over.actor),
        })
    end

    -- The pawn the player has in the station: a player's character with no state and no stat container.
    function kit.station(over)
        over = over or {}
        return make({
            class = "BP_IcarusPlayerCharacterSpace_C", player = over.name or "Player One", at = over.at, facing = over.facing,
            movement = merged({ Velocity = { X = 0, Y = 0, Z = 0 }, MaxWalkSpeed = 300, MovementMode = 1 }, over.movement),
            actor = merged({ bIsCrouched = false, RespawnCount = 0 }, over.actor),
        })
    end

    function kit.move(who, x, y, z)
        who.store.Location = { x, y, z }
        if not who.root_store.AttachParent:IsValid() then who.root_store.RelativeLocation = { X = x, Y = y, Z = z } end
    end

    -- Attaches a character to another one's root, as when it sits on something: its root then holds a place relative to that.
    function kit.seat(who, on, offset)
        offset = offset or { 0, 0, 90 }
        who.root_store.AttachParent = on.root
        who.root_store.RelativeLocation = { X = offset[1], Y = offset[2], Z = offset[3] }
        who.root_store.RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 }
    end

    function kit.kill(who)
        who.state_store.Health, who.state_store.CurrentAliveState = 0, 1
    end

    -- Back to life as the same actor.
    function kit.revive(who)
        who.state_store.Health, who.state_store.CurrentAliveState = who.state_store.MaxHealth, 0
        if who.store.RespawnCount then who.store.RespawnCount = who.store.RespawnCount + 1 end
    end

    return kit
end

function world.install()
    function StaticFindObject(path) return world.static[path] or INVALID end
    function FindAllOf(class_name)
        local out = {}
        for _, actor in ipairs(world.actors) do
            local class = rawget(actor, "__class")
            while class do
                if rawget(class, "__name") == class_name then
                    out[#out + 1] = actor
                    break
                end
                class = rawget(class, "__super")
            end
        end
        return #out > 0 and out or nil
    end
    function FindFirstOf(name) return name == "Engine" and world.engine or INVALID end
    function RegisterBeginPlayPostHook(fn) world.began = fn end
    function RegisterEndPlayPreHook(fn) world.ended = fn end
    function FName(text) return text end
end

return world
