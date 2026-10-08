-- What the game lets the host do with creatures, as a stand-in on top of fake_creatures.lua: the spawn, the level, the
-- two freezes, the life span, the anger call, the ground and the zone under a place, and the tables of teams and zones.
-- Each takes its values as UE4SS hands them over and answers as the game did on 2026-10-07
-- (.research\creatures\probe-results.md 2.3 to 2.7). It is as unkind as the game:
--   a spawned animal has level 0 when the call returns and its real level a few frames later;
--   a place under the ground lets the animal fall out of the world (`fell`), the spawn does not lift it;
--   a row the game lacks, or one whose class it lacks, spawns nothing and says nothing;
--   the anger call does nothing to an animal without aggression, and crashes on one that does not plan what it does;
--   a dead animal becomes a corpse three seconds later (`corpses`): one to three were timed in the game. Not when it left the world first;
--   an array read one past its end grows by one, as in the game.
-- A call with values that were never tried in the game is counted in `untried`, with a line in `log`.
--   local acts = dofile("wax/tests/offline/fake_creature_acts.lua")
--   acts.install(zoo)                     zoo is fake_creatures, installed
--   local deer = acts.make("Deer", { at = { 0, 0, 0 } })       as zoo.make, with a mind and the freeze flag
--   acts.next_frame(now)                  once a frame, with the suite's clock
--   acts.ground = function(x, y) return 0 end       acts.no_ground = true       acts.zone = "OLY_Conifer_Easy"
--   acts.settle = 2 (frames until a spawned animal has its level)      acts.notice = 3 (frames until an angry one has its target)
--   acts.body = 3 (seconds a dead animal stays before the game makes a corpse of it)
--   acts.last                             the animal the last spawn made

local acts = { settle = 2, notice = 3, body = 3, zone = "OLY_Conifer_Easy", no_ground = false, last = nil }
---@type any
local zoo, world, values, kit = nil, nil, nil, nil
local known = setmetatable({}, { __mode = "k" })    -- actor -> the animal as fake_creatures made it
local arriving, leaving, noticing, dying = {}, {}, {}, {}
local clock = 0

acts.MINDS = {
    -- D_GOAPSetup of the game: a deer has six motivations and no aggression, a hunter has it
    Deer = { "Hunger", "Thirst", "Threat", "Cautious", "Tiredness", "Pacificity" },
    Chick = { "Hunger", "Thirst", "Threat", "Cautious", "Tiredness", "Attraction" },
    Juvenile_Buffalo = { "Hunger", "Thirst", "Threat", "Cautious", "Tiredness", "Pacificity" },
    Buffalo = { "Hunger", "Thirst", "Threat", "Cautious", "Tiredness", "Aggression", "Protective" },
    Alpha_Wolf_Boss = { "Hunger", "Thirst", "Threat", "Cautious", "Tiredness", "Aggression", "Protective" },
    Nameless = { "Hunger" },
}
acts.TEAMS = { "FriendlyAll", "Player", "DefaultLargeHerbivore", "DefaultMediumHerbivore", "DefaultSmallHerbivore",
    "DefaultLargeCarnivore", "DefaultMediumCarnivore", "DefaultSmallCarnivore", "NeutralMediumHerbivore", "NeutralMediumCarnivore",
    "NeutralLargeHerbivore", "EnemyAll", "EnemyPlayerOnly", "HuntingLargeCarnivore", "HostileDroneOrSoldier", "EnemyDronesOnly" }
acts.ZONES = { OLY_Conifer_Easy = { MinLevel = 1, MedianLevel = 15, MaxLevel = 30 },
    Arctic_Bear_Easy = { MinLevel = 20, MedianLevel = 50, MaxLevel = 80 }, Beyond = { MinLevel = 150, MedianLevel = 300, MaxLevel = 400 } }

local COUNTERS = { "untried", "crashes", "fell", "nothing", "corpses", "spawns" }

-- Every counter back to zero. What was installed and made stays.
function acts.reset()
    for _, name in ipairs(COUNTERS) do acts[name] = 0 end
    acts.calls, acts.log = {}, {}
end
acts.reset()

local function called(name) acts.calls[name] = (acts.calls[name] or 0) + 1 end

local function untried(what)
    acts.untried = acts.untried + 1
    acts.log[#acts.log + 1] = what
end

local function crash(what)
    acts.crashes = acts.crashes + 1
    acts.log[#acts.log + 1] = "CRASH: " .. what
    error("CRASH: " .. what, 0)
end

local INT, FLOAT, BOOL, OBJECT, STRUCT = "IntProperty", "FloatProperty", "BoolProperty", "ObjectProperty", "StructProperty"
local VECTOR, QUAT, TRANSFORM = "/Script/CoreUObject.Vector", "/Script/CoreUObject.Quat", "/Script/CoreUObject.Transform"
local SETUP, EPIC, ZONE = "/Script/Icarus.AISetupRowHandle", "/Script/Icarus.EpicCreaturesRowHandle", "/Script/Icarus.AISpawnZonesRowHandle"
local MOTIVATION_ROW = "/Script/Icarus.GOAPMotivationsRowHandle"

local function add(class_name, functions, members)
    local class = kit.classes[class_name]
    if not class then error("fake_creature_acts: the stand-in has no class " .. class_name, 2) end
    local held = rawget(class, "__functions")
    for name, def in pairs(functions or {}) do held[name] = def end
    held = rawget(class, "__members")
    for name, spec in pairs(members or {}) do held[name] = spec end
end

local function is_a(object, class_name) return object:IsA(kit.classes[class_name]) end
local function dead(who) return who.state_store.CurrentAliveState ~= 0 end

-- Gives an animal of fake_creatures what the calls here read: the freeze flag and the motivations of its kind.
function acts.adopt(who)
    known[who.actor] = who
    who.store.bIsNPCFrozen = false
    local names = acts.MINDS[who.variant]
    if names and who.controller_store and is_a(who.controller, "IcarusNPCGOAPController") then
        local list = {}
        for i, name in ipairs(names) do
            list[i] = values.part(kit.classes.IcarusGOAPMotivation, "Motivation_" .. name,
                { CachedRowHandle = zoo.handle(name, "D_GOAPMotivations"), CurrentValue = 0 })
        end
        who.mind = world.array(list)
        who.controller_store.Motivations = who.mind
    end
    return who
end

function acts.make(variant, over) return acts.adopt(zoo.make(variant, over)) end

-- How strong a motivation of an animal is now, or nil when its kind has none of that name.
function acts.feels(who, name)
    for _, motivation in ipairs(rawget(who.mind or {}, "__props") or {}) do
        local store = values.of(motivation)
        if store.CachedRowHandle.RowName:ToString() == name then return store.CurrentValue end
    end
    return nil
end

-- The team the engine holds for an animal, as the row's name.
function acts.team(who) return who.store.AIRelationshipTableRowNew.RowName:ToString() end

local function row_of_setup(name)
    for key in pairs(zoo.rows.AISetup) do
        if key:lower() == name:lower() then return key end
    end
    return nil
end

local function install_spawn()
    values.struct(QUAT, nil, { { "X", FLOAT }, { "Y", FLOAT }, { "Z", FLOAT }, { "W", FLOAT } })
    values.struct(TRANSFORM, nil, { { "Rotation", STRUCT, struct = QUAT }, { "Translation", STRUCT, struct = VECTOR },
        { "Scale3D", STRUCT, struct = VECTOR } })
    kit.classes.IcarusAIBlueprintFunctionLibrary = values.class("/Script/Icarus.IcarusAIBlueprintFunctionLibrary", kit.classes.Object, {}, {
        SpawnNewAI = { { "WorldContextObject", OBJECT }, { "AISetup", STRUCT, struct = SETUP }, { "EpicCreatureSetup", STRUCT, struct = EPIC },
            { "SpawnTransform", STRUCT, struct = TRANSFORM }, { "BaseLevel", INT }, { "CollisionHandlingMethod", "EnumProperty" },
            { "Owner", OBJECT }, { "Instigator", OBJECT }, { "ForcedUID", INT }, returns = OBJECT, call = function(_, args)
                called("SpawnNewAI")
                local context = args.WorldContextObject
                if not context:IsValid() or not is_a(context, "IcarusPlayerCharacter") then
                    untried("SpawnNewAI with a context that is not a player's character")
                end
                if args.CollisionHandlingMethod ~= 2 then untried("SpawnNewAI with a collision handling other than 2") end
                if args.Owner:IsValid() or args.Instigator:IsValid() then untried("SpawnNewAI with an owner or an instigator") end
                if args.ForcedUID ~= -1 then untried("SpawnNewAI with a forced id") end
                if args.EpicCreatureSetup.RowName:ToString() ~= "None" then untried("SpawnNewAI with an epic row") end
                if args.EpicCreatureSetup.DataTableName:ToString() ~= "D_EpicCreatures" or args.AISetup.DataTableName:ToString() ~= "D_AISetup" then
                    untried("SpawnNewAI with a handle that names another table")
                end
                local level = args.BaseLevel
                if level < 1 or level > 120 then untried(("SpawnNewAI at level %d"):format(level)) end
                local at, turn, size = args.SpawnTransform.Translation, args.SpawnTransform.Rotation, args.SpawnTransform.Scale3D
                if not (at and turn and size) or size.X ~= 1 or size.Y ~= 1 or size.Z ~= 1 then untried("SpawnNewAI with a scale other than 1") end
                if math.abs(turn.X) > 1e-9 or math.abs(turn.Y) > 1e-9 or math.abs(turn.Z ^ 2 + turn.W ^ 2 - 1) > 1e-6 then
                    untried("SpawnNewAI with a rotation that is not a turn about the upright axis")
                end
                local row = row_of_setup(args.AISetup.RowName:ToString())
                local made = nil
                if row then
                    local ok, who = pcall(zoo.make, row, { at = { at.X, at.Y, at.Z }, level = 0 })
                    if ok then made = who end
                end
                if not made then
                    acts.nothing = acts.nothing + 1
                    return world.INVALID
                end
                acts.adopt(made)
                acts.spawns = acts.spawns + 1
                acts.last = made
                if is_a(made.actor, "IcarusMountCharacter") then untried("SpawnNewAI of a tamed animal") end
                local floor_here = acts.ground(at.X, at.Y)
                if at.Z < floor_here - 1 then acts.fell = acts.fell + 1 end
                local yaw = math.deg(2 * math.atan(turn.Z, turn.W))
                made.store.Rotation = { 0, yaw, 0 }
                made.root_store.RelativeRotation = { Pitch = 0, Yaw = yaw, Roll = 0 }
                made.spawned_at = { at.X, at.Y, at.Z }
                arriving[#arriving + 1] = { who = made, level = level, frames = acts.settle, ground = floor_here }
                return made.actor
            end },
        SetBaseLevel = { { "Animal", OBJECT }, { "Level", INT }, returns = BOOL, call = function(_, args)
            called("SetBaseLevel")
            local who = known[args.Animal]
            if not who or not is_a(args.Animal, "IcarusNPCCharacter") then
                untried("SetBaseLevel on something that is not an animal the game was asked about")
                return false
            end
            if is_a(args.Animal, "IcarusMountCharacter") then untried("SetBaseLevel on a tamed animal") end
            if dead(who) then untried("SetBaseLevel on a dead animal") end
            if args.Level < 1 or args.Level > 120 then untried(("SetBaseLevel(%d)"):format(args.Level)) end
            if who.store.CurrentLevel == args.Level then return false end
            acts.level(who, args.Level)
            return true
        end },
    })
    acts.spawner = values.part(kit.classes.IcarusAIBlueprintFunctionLibrary, "Default__IcarusAIBlueprintFunctionLibrary", {})
    world.static["/Script/Icarus.Default__IcarusAIBlueprintFunctionLibrary"] = acts.spawner
end

-- The level as the game sets it: the level, its experience, and health that follows and stays full.
function acts.level(who, level)
    local base = who.base_health or who.state_store.MaxHealth
    who.base_health = base
    who.store.CurrentLevel, who.state_store.Level = level, level
    who.state_store.TotalExperience = level * 1000
    who.state_store.MaxHealth = base + level
    who.state_store.Health = who.state_store.MaxHealth
end

local function install_ground()
    kit.classes.NavigationSystemV1 = values.class("/Script/NavigationSystem.NavigationSystemV1", kit.classes.Object, {}, {
        K2_ProjectPointToNavigation = { { "WorldContextObject", OBJECT }, { "Point", STRUCT, struct = VECTOR },
            { "ProjectedLocation", STRUCT, struct = VECTOR, out = true }, { "NavData", OBJECT }, { "FilterClass", "ClassProperty" },
            { "QueryExtent", STRUCT, struct = VECTOR }, returns = BOOL, call = function(_, args)
                called("K2_ProjectPointToNavigation")
                local reach = args.QueryExtent
                if reach.X ~= 500 or reach.Y ~= 500 or reach.Z ~= 100000 then untried("K2_ProjectPointToNavigation with another reach") end
                if args.NavData:IsValid() or args.FilterClass ~= nil then untried("K2_ProjectPointToNavigation with navigation data or a filter") end
                if not args.WorldContextObject:IsValid() then untried("K2_ProjectPointToNavigation with no context") end
                if acts.no_ground then return false, { ProjectedLocation = { X = 0, Y = 0, Z = 0 } } end
                return true, { ProjectedLocation = { X = args.Point.X, Y = args.Point.Y, Z = acts.ground(args.Point.X, args.Point.Y) } }
            end },
    })
    acts.nav = values.part(kit.classes.NavigationSystemV1, "Default__NavigationSystemV1", {})
    world.static["/Script/NavigationSystem.Default__NavigationSystemV1"] = acts.nav
end

local function install_moods()
    values.struct(ZONE, "/Script/IcarusUtilities.RowHandle", {})
    values.struct(MOTIVATION_ROW, "/Script/IcarusUtilities.RowHandle", {})
    kit.classes.IcarusGOAPMotivation = values.class("/Script/Icarus.IcarusGOAPMotivation", kit.classes.Object,
        { CachedRowHandle = { STRUCT, struct = MOTIVATION_ROW }, CurrentValue = INT })
    add("IcarusNPCGOAPController", nil, { Motivations = { "ArrayProperty", inner = OBJECT } })
    local path = "/Game/BP/AI/GOAP/BP_AIFunctionLibrary."
    kit.classes.BP_AIFunctionLibrary_C = values.class(path .. "BP_AIFunctionLibrary_C", kit.classes.Object, {}, {
        MakeNPCAngry = { { "NPC", OBJECT }, { "TargetActor", OBJECT }, { "TargetActorKeyName", "NameProperty" }, { "__WorldContext", OBJECT },
            call = function(_, args)
                called("MakeNPCAngry")
                local npc, target = args.NPC, args.TargetActor
                if not npc:IsValid() or not is_a(npc, "IcarusNPCGOAPCharacter") then
                    crash("MakeNPCAngry was given something that is not an IcarusNPCGOAPCharacter")
                end
                local who = known[npc]
                if not target:IsValid() or not is_a(target, "IcarusPlayerCharacter") then untried("MakeNPCAngry at something that is not a player's character") end
                if not args.__WorldContext:IsValid() then untried("MakeNPCAngry with no context") end
                if not who or dead(who) then
                    untried("MakeNPCAngry on a dead animal, or one the game was not asked about")
                    return
                end
                for _, motivation in ipairs(rawget(who.mind or {}, "__props") or {}) do
                    local store = values.of(motivation)
                    if store.CachedRowHandle.RowName:ToString() == "Aggression" then
                        store.CurrentValue = 100
                        noticing[#noticing + 1] = { who = who, target = target, frames = acts.notice }
                    end
                end
            end },
        GetZoneTextureSample = { { "Context", OBJECT }, { "Location", STRUCT, struct = VECTOR }, { "__WorldContext", OBJECT },
            { "Zone", STRUCT, struct = ZONE, out = true }, call = function(_, args)
                called("GetZoneTextureSample")
                if not args.Context:IsValid() or not args.__WorldContext:IsValid() then untried("GetZoneTextureSample with no context") end
                return nil, { Zone = { RowName = values.name(acts.zone or "None"), DataTableName = values.name("D_AISpawnZones") } }
            end },
    })
    acts.moods = values.part(kit.classes.BP_AIFunctionLibrary_C, "Default__BP_AIFunctionLibrary_C", {})
    world.static[path .. "Default__BP_AIFunctionLibrary_C"] = acts.moods
end

local function install_animal()
    add("IcarusNPCCharacter", {
        FreezeNPC = { returns = BOOL, call = function(self)
            called("FreezeNPC")
            local who = known[self]
            if not who then
                untried("FreezeNPC on an animal the game was not asked about")
                return false
            end
            if dead(who) then untried("FreezeNPC on a dead animal") end
            if who.store.bIsNPCFrozen then untried("FreezeNPC on an animal that is frozen already") end
            who.store.bIsNPCFrozen = true
            return true
        end },
        UnfreezeNPC = { returns = BOOL, call = function(self)
            called("UnfreezeNPC")
            local who = known[self]
            if not who then
                untried("UnfreezeNPC on an animal the game was not asked about")
                return false
            end
            if dead(who) then untried("UnfreezeNPC on a dead animal") end
            if not who.store.bIsNPCFrozen then untried("UnfreezeNPC on an animal that is not frozen") end
            who.store.bIsNPCFrozen = false
            return true
        end },
    }, { bIsNPCFrozen = BOOL })
    add("Actor", {
        SetLifeSpan = { { "InLifespan", FLOAT }, call = function(self, args)
            called("SetLifeSpan")
            if math.abs(args.InLifespan - 0.1) > 1e-9 then untried(("SetLifeSpan(%s)"):format(tostring(args.InLifespan))) end
            leaving[#leaving + 1] = { actor = self, at = clock + args.InLifespan }
        end },
    })
end

local function install_tables()
    local tables, S, U = zoo.tables, "/Script/Icarus.", "/Script/IcarusUtilities."
    zoo.struct(S .. "AIRelationshipData", U .. "IcarusTableRowBase", { { "bHostileToUnlisted", BOOL } })
    local teams = {}
    for _, name in ipairs(acts.TEAMS) do teams[name] = { bHostileToUnlisted = name == "EnemyAll" } end
    tables.table("AIRelationships", S .. "AIRelationshipData", teams, acts.TEAMS)
    zoo.struct(S .. "AISpawnZones", U .. "IcarusTableRowBase", { { "MinLevel", INT }, { "MedianLevel", INT }, { "MaxLevel", INT } })
    tables.table("AISpawnZones", S .. "AISpawnZones", acts.ZONES, { "OLY_Conifer_Easy", "Arctic_Bear_Easy", "Beyond" })
end

local function gone(actor)
    local who = known[actor]
    if who then
        zoo.remove(who)
    else
        world.destroy(actor)
        world.free(actor)
    end
end

-- One frame of the game: spawned animals get their level, angry ones their target, life spans run out, the dead become corpses.
function acts.next_frame(now)
    clock = now or (clock + 0.016)
    local later = {}
    for _, entry in ipairs(arriving) do
        entry.frames = entry.frames - 1
        local who = entry.who
        if rawget(who.actor, "__freed") then
            -- it left before it was finished
        elseif entry.frames <= 0 then
            acts.level(who, entry.level)
            local at = who.store.Location
            if at[3] > entry.ground then kit.move(who, at[1], at[2], entry.ground) end
        else
            later[#later + 1] = entry
        end
    end
    arriving, later = later, {}
    for _, entry in ipairs(noticing) do
        entry.frames = entry.frames - 1
        if rawget(entry.who.actor, "__freed") or dead(entry.who) then
            -- nothing left to notice with
        elseif entry.frames <= 0 then
            entry.who.store.CurrentTarget = entry.target
        else
            later[#later + 1] = entry
        end
    end
    noticing, later = later, {}
    for _, entry in ipairs(leaving) do
        if rawget(entry.actor, "__freed") then
            -- gone by another way
        elseif clock >= entry.at then
            dying[entry.actor] = nil
            gone(entry.actor)
        else
            later[#later + 1] = entry
        end
    end
    leaving = later
    for actor, who in pairs(known) do
        if not rawget(actor, "__freed") and dead(who) then
            dying[actor] = dying[actor] or clock
            if clock - dying[actor] >= acts.body then
                dying[actor] = nil
                acts.corpses = acts.corpses + 1
                gone(actor)
            end
        end
    end
end

-- Call after fake_creatures is installed, and fake_actions and fake_hooks when a suite has them.
function acts.install(the_zoo)
    zoo, world, values, kit = the_zoo, the_zoo.world, the_zoo.values, the_zoo.kit
    acts.ground = function(_, _) return 0 end
    -- an engine array answers the length operator, as UE4SS's does
    getmetatable(world.array({})).__len = function(self) return #rawget(self, "__props") end
    install_spawn()
    install_ground()
    install_moods()
    install_animal()
    install_tables()
    return acts
end

return acts
