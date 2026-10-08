-- A stand-in for the game's creatures: fake_world, fake_values and fake_tables under one set of globals, the creature classes
-- with the members the game's index gives them, the creature tables with rows copied from the game's own, and makers.
-- Actors are fake_world's: one that was freed raises on any use. Tables are fake_tables': what they hand out raises in the next
-- frame, a map or an object field raises when read, a name the table lacks is counted.
--   local zoo = dofile("wax/tests/offline/fake_creatures.lua").install()
--   zoo.world, zoo.values, zoo.tables, zoo.kit (fake_world's characters), zoo.classes
--   zoo.rows.Tames, zoo.order.Tames: what a table holds and the names of its rows in order, for tables.set_rows
--   local deer = zoo.make("Deer", { at = { 100, 0, 0 }, level = 6 })     deer.actor, deer.store, deer.state_store,
--                                                                        deer.controller, deer.controller_store
--   zoo.team(deer, "FriendlyAll")   zoo.act(deer, "FindFood")   zoo.act(deer, nil)   zoo.aim(deer, actor)   zoo.aim(deer, nil)
--   zoo.remove(deer)
-- The engine spells a few names in another letter case than the tables' rows, as the game does.

local zoo = {}

-- What each variant is made of. A variant without `pawn` is an IcarusNPCGOAPCharacter.
local SPECIES = {
    Deer = { class = "BP_NPC_Deer_Character_C", health = 155, level = 6, team = "DefaultMediumHerbivore",
             controller = "BP_NPC_Generic_Controller_C", action = "Wander", speed = 220 },
    Buffalo = { class = "BP_NPC_Buffalo_Character_C", health = 420, level = 9, team = "NeutralMediumHerbivore",
                controller = "BP_NPC_Generic_Controller_C", action = "Wander", speed = 300 },
    Juvenile_Buffalo = { class = "BP_NPC_Buffalo_Juvenile_Character_C", health = 80, level = 1, team = "DefaultSmallHerbivore",
                         controller = "BP_NPC_Juvenile_Controller_C", action = "Wander", speed = 200, row = "Juvenile_buffalo" },
    Mount_Buffalo = { class = "BP_Mount_Buffalo_C", health = 600, level = 12, team = "Player", controller = "BP_MountAIController_C",
                      state = "SurvivalCharacterState", speed = 350 },
    Alpha_Wolf_Boss = { class = "BP_NPC_Alpha_Wolf_Character_C", health = 2523, level = 1, team = "DefaultLargeCarnivore",
                        controller = "BP_NPC_Generic_Controller_C", action = "EmergeFromRetreat", epic = "AlphaWolf_Boss", speed = 150 },
    Tamed_Forest_Wolf = { class = "BP_Tamed_Wolf_C", health = 200, level = 4, team = "Player", controller = "BP_MountAIController_C",
                          state = "SurvivalCharacterState", speed = 440 },
    Cow = { class = "BP_Tame_Cow_C", health = 300, level = 2, team = "Player", controller = "BP_MountAIController_C",
            state = "SurvivalCharacterState", speed = 200 },
    Chick = { class = "BP_NPC_Chick_Juvenile_Character_C", health = 20, level = 1, team = "Player",
              controller = "BP_NPC_Juvenile_Controller_C", action = "Wander", speed = 120 },
    SandWorm = { class = "BP_FactionBoss_SandWorm_C", pawn = true, state = "ActorState", health = 90000, level = 60,
                 team = "DefaultLargeCarnivore", controller = "BP_FactionBoss_Controller_SandWorm_C", epic = "Sandworm_Boss" },
    -- a creature of a class no row of D_AISetup names, whose own row is empty: the game does not say what it is
    Nameless = { class = "BP_IcarusNPCGOAPCharacter_C", health = 10, level = 1, team = "DefaultSmallHerbivore",
                 controller = "BP_NPC_Generic_Controller_C", action = "Wander", row = "None", speed = 100 },
}

function zoo.install()
    local world = dofile("wax/tests/offline/fake_world.lua")
    world.install()
    local values = dofile("wax/tests/offline/fake_values.lua")
    values.install(world)
    local world_find, world_all, make_name = StaticFindObject, FindAllOf, FName
    local tables = dofile("wax/tests/offline/fake_tables.lua")
    tables.install()
    local table_find, table_all = StaticFindObject, FindAllOf
    local declared = {}         -- the structs the tables are made of: found through fake_tables, whatever else has their path

    function StaticFindObject(path)
        if declared[path] or (type(path) == "string" and path:find("^/Engine/Transient%.D_")) then return table_find(path) end
        return world_find(path)
    end
    function FindAllOf(class_name)
        if class_name == "IcarusDataTable" then return table_all(class_name) end
        return world_all(class_name)
    end
    FName = make_name

    local kit = world.icarus(values)
    local classes = kit.classes
    zoo.world, zoo.values, zoo.tables, zoo.kit, zoo.classes = world, values, tables, kit, classes

    -- classes

    local S, U, G = "/Script/Icarus.", "/Script/IcarusUtilities.", "/Script/GameplayTags."
    local HANDLE, SETUP = U .. "RowHandle", S .. "AISetupRowHandle"
    local EPIC, TEAM = S .. "EpicCreaturesRowHandle", S .. "AIRelationshipsRowHandle"
    local OBJECT, STRUCT = "ObjectProperty", "StructProperty"
    values.struct(EPIC, HANDLE, {})
    values.struct(TEAM, HANDLE, {})

    local function class(path, super, members, functions)
        local made = values.class(path, super and classes[super], members, functions)
        classes[path:match("([^%.:/]+)$")] = made
        return made
    end
    -- the index puts these on classes fake_world made without them
    local function give(class_name, members)
        local held = rawget(classes[class_name], "__members")
        for name, spec in pairs(members) do held[name] = spec end
    end
    give("IcarusCharacter", { AIRelationshipTableRowNew = { STRUCT, struct = TEAM } })
    give("IcarusPawn", { EpicCreature = { STRUCT, struct = EPIC }, AIRelationshipTableRowNew = { STRUCT, struct = TEAM } })

    local GOAP, MOUNTS = "/Game/BP/AI/GOAP/AI/", "/Game/BP/Mounts/"
    class(S .. "IcarusNPCGOAPCharacter", "IcarusNPCCharacter", {
        AISetup = { STRUCT, struct = SETUP }, EpicCreature = { STRUCT, struct = EPIC }, CurrentStance = "EnumProperty", LastTarget = OBJECT,
    })
    class(GOAP .. "BP_IcarusNPCGOAPCharacter.BP_IcarusNPCGOAPCharacter_C", "IcarusNPCGOAPCharacter")
    class(GOAP .. "BP_NPC_Deer_Character.BP_NPC_Deer_Character_C", "BP_IcarusNPCGOAPCharacter_C")
    class(GOAP .. "BP_NPC_Buffalo_Character.BP_NPC_Buffalo_Character_C", "BP_IcarusNPCGOAPCharacter_C")
    class(GOAP .. "BP_NPC_Alpha_Wolf_Character.BP_NPC_Alpha_Wolf_Character_C", "BP_IcarusNPCGOAPCharacter_C")
    class(GOAP .. "BP_IcarusNPCGOAPCharacter_Juvenile.BP_IcarusNPCGOAPCharacter_Juvenile_C", "BP_IcarusNPCGOAPCharacter_C")
    class(GOAP .. "BP_NPC_Buffalo_Juvenile_Character.BP_NPC_Buffalo_Juvenile_Character_C", "BP_IcarusNPCGOAPCharacter_Juvenile_C")
    class(GOAP .. "BP_NPC_Chick_Juvenile_Character.BP_NPC_Chick_Juvenile_Character_C", "BP_IcarusNPCGOAPCharacter_Juvenile_C")
    class(S .. "IcarusMountCharacter", "IcarusNPCGOAPCharacter", { MountName = "StrProperty", OwnerName = "StrProperty" })
    class(MOUNTS .. "BP_Mount_Base.BP_Mount_Base_C", "IcarusMountCharacter")
    class(MOUNTS .. "BP_Mount_Buffalo.BP_Mount_Buffalo_C", "BP_Mount_Base_C")
    class(MOUNTS .. "BP_Tame_Base.BP_Tame_Base_C", "BP_Mount_Base_C")
    class(MOUNTS .. "BP_Tame_Cow.BP_Tame_Cow_C", "BP_Tame_Base_C")
    class(MOUNTS .. "BP_Tamed_Wolf.BP_Tamed_Wolf_C", "BP_Mount_Base_C")
    class("/Game/BP/AI/Bosses/BP_FactionBoss_SandWorm.BP_FactionBoss_SandWorm_C", "IcarusPawn")

    class("/Script/Engine.Controller", "Actor", { Pawn = OBJECT })
    class("/Script/AIModule.AIController", "Controller")
    class(S .. "IcarusNPCController", "AIController")
    class(S .. "IcarusNPCGOAPController", "IcarusNPCController", { CurrentAction = OBJECT, CurrentGoal = OBJECT })
    class(GOAP .. "BP_NPC_Generic_Controller.BP_NPC_Generic_Controller_C", "IcarusNPCGOAPController")
    class(GOAP .. "BP_NPC_Juvenile_Controller.BP_NPC_Juvenile_Controller_C", "IcarusNPCGOAPController")
    class(MOUNTS .. "BP_MountAIController.BP_MountAIController_C", "IcarusNPCController")
    class("/Game/BP/AI/Bosses/BP_FactionBoss_Controller_SandWorm.BP_FactionBoss_Controller_SandWorm_C", "AIController")
    class(S .. "IcarusGOAPAction", "Object")

    -- tables

    local function struct(path, super, fields, options)
        declared[path] = true
        return tables.struct(path, super, fields, options)
    end
    zoo.struct = struct     -- for a stand-in that adds tables of its own
    local function handle_field(name, table_name) return { name, STRUCT, struct = S .. table_name .. "RowHandle" } end
    local function handles(name, table_name) return { name, "ArrayProperty", inner = STRUCT, struct = S .. table_name .. "RowHandle" } end

    struct("/Script/Engine.TableRowBase", nil, {}, { lead = 8 })
    struct(U .. "IcarusTableRowBase", "/Script/Engine.TableRowBase", { { "CachedHardReferences", "ArrayProperty", inner = OBJECT } })
    struct("/Script/IcarusEngineUtilities.RowHandleInternal", nil, {})
    struct(HANDLE, "/Script/IcarusEngineUtilities.RowHandleInternal",
        { { "DataTablePtr", "WeakObjectProperty" }, { "RowName", "NameProperty" }, { "DataTableName", "NameProperty" } })
    for _, name in ipairs({ "AISetup", "AICreatureType", "AIDescriptors", "ItemsStatic", "GOAPSetup", "AIRelationships", "AIGrowth",
                            "ItemRewards", "ModifierStates", "Mounts", "TagQueries", "CharacterGrowth", "Saddles", "Stats",
                            "TalentArchetypes", "EpicCreatures" }) do
        struct(S .. name .. "RowHandle", HANDLE, {})
    end
    struct(U .. "RowEnum", nil, { { "Value", "NameProperty" } }, { lead = 8 })
    struct(S .. "VirtualStatsEnum", U .. "RowEnum", {})
    struct(S .. "AtmospheresEnum", U .. "RowEnum", {})
    struct(G .. "GameplayTag", nil, { { "TagName", "NameProperty" } })
    struct("/Script/CoreUObject.Vector2D", nil, { { "X", "FloatProperty" }, { "Y", "FloatProperty" } })
    struct(S .. "MountVariation", nil,
        { { "bCanBeSelected", "BoolProperty" }, { "MeshMaterials", "MapProperty" }, { "Weighting", "IntProperty" } })

    struct(S .. "AICreatureType", U .. "IcarusTableRowBase", {
        { "CreatureName", "TextProperty" }, { "Tag", STRUCT, struct = G .. "GameplayTag" },
        { "SpawnStat", STRUCT, struct = S .. "VirtualStatsEnum" }, { "ParentCreatureTag", STRUCT, struct = G .. "GameplayTag" },
    })
    struct(S .. "AISetup", U .. "IcarusTableRowBase", {
        { "ActorClass", "SoftClassProperty" }, { "ControllerClass", "SoftClassProperty" }, handle_field("CreatureType", "AICreatureType"),
        handles("Descriptors", "AIDescriptors"), handle_field("DeadItem", "ItemsStatic"), handle_field("GOAPSetup", "GOAPSetup"),
        { "DefaultNavigationFilter", "ClassProperty" }, handle_field("Relationships", "AIRelationships"),
        handle_field("AIGrowth", "AIGrowth"), { "MovementMapping", "MapProperty" }, { "LatentDeathDuration", "IntProperty" },
        handle_field("Trophy", "ItemRewards"), handle_field("Loot", "ItemRewards"), { "bUseSurvivalCharacterState", "BoolProperty" },
        handles("AdditionalAIToSpawn", "AISetup"),
    })
    struct(S .. "IcarusTamingData", U .. "IcarusTableRowBase", {
        { "Behaviour", "SoftClassProperty" }, { "TameDurationInSeconds", "IntProperty" },
        { "DesiredTemperatureRange", STRUCT, struct = "/Script/CoreUObject.Vector2D" }, { "DesiredShelterPercentage", "IntProperty" },
        { "DesiredNutritionPercentage", "IntProperty" }, handles("RequiredTamingModifiers", "ModifierStates"),
        handles("ProhibitedTamingModifiers", "ModifierStates"), handle_field("TamedAI", "AISetup"), { "TamedAIOverride", "MapProperty" },
        handle_field("MatureCreatureType", "AISetup"), handle_field("JuvenileCreatureType", "AISetup"),
        { "bAutomaticallySpawnJuvenileWithParent", "BoolProperty" }, { "PercentChanceToSpawnJuvenile", "IntProperty" },
        { "TrappingSupportedAtmospheres", "ArrayProperty", inner = STRUCT, struct = S .. "AtmospheresEnum" },
        { "GestationPeriodSeconds", "IntProperty" },
    })
    struct(S .. "IcarusMount", U .. "IcarusTableRowBase", {
        handle_field("AISetup", "AISetup"), { "Icon", "SoftObjectProperty" },
        { "Variations", "ArrayProperty", inner = STRUCT, struct = S .. "MountVariation" }, handle_field("RelevantSaddleQuery", "TagQueries"),
        { "SupportedCombatStates", "ArrayProperty", inner = "EnumProperty",
          enum = { "Invalid", "DoNotEngage", "NeutralEngagement", "AggressiveEngagement" } },
        { "SupportedMovementStates", "ArrayProperty", inner = "EnumProperty",
          enum = { "Invalid", "Follow", "IdleWander", "IdleStanding", "IdleLying" } },
        { "Animations", "MapProperty" }, { "DefaultNames", "ArrayProperty", inner = "TextProperty" },
        handle_field("MountTalentArchetype", "TalentArchetypes"), handle_field("GrowthCurve", "CharacterGrowth"),
        { "bUseTemperature", "BoolProperty" }, { "ComfortableTemperatureRange", STRUCT, struct = "/Script/CoreUObject.Vector2D" },
    })
    struct(S .. "SaddleData", U .. "IcarusTableRowBase", {
        { "SaddleTag", STRUCT, struct = G .. "GameplayTag" }, handles("SupportedMount", "Mounts"), { "SkeletalMesh", "SoftObjectProperty" },
        { "SaddleBlueprint", "ClassProperty" }, { "AttachSocket", "NameProperty" },
        { "PassengerSaddleSockets", "ArrayProperty", inner = "NameProperty" }, handle_field("RequiredStat", "Stats"),
    })

    local function to(row, table_name) return { RowName = row, DataTableName = "D_" .. table_name } end
    local function list(table_name, ...)
        local out = {}
        for i, row in ipairs({ ... }) do out[i] = to(row, table_name) end
        return out
    end
    local function kind(shown, tag) return { CreatureName = shown, Tag = { TagName = tag } } end
    local rows, order = {}, {}
    zoo.rows, zoo.order = rows, order

    rows.AICreatureType = {
        MediumDeer = kind("Deer", "NPC.MediumDeer"), Wolf = kind("Wolf", "NPC.Wolf"), Alpha_Wolf = kind("Black Wolf", "NPC.Wolf.Alpha"),
        Buffalo = kind("Buffalo", "NPC.Buffalo"), Juvenile_Buffalo = kind("Juvenile Buffalo", "NPC.Juvenile.Buffalo"),
        Cow = kind("Cow", "NPC.Cow"), Calf = kind("Calf", "NPC.Juvenile.Calf"), Chick = kind("Chick", "NPC.Juvenile.Chick"),
        Chicken = kind("Chicken", "NPC.Chicken"), BlueBack = kind("Blueback", "NPC.Blueback"), Dog = kind("Dog", "NPC.Dog"),
        CaveWorm = kind("Cave Worm", "NPC.CaveWorm"), SandWorm = kind("Sandworm", "NPC.SandWorm"), Bear = kind("Bear", "NPC.Bear"),
    }
    order.AICreatureType = { "MediumDeer", "Wolf", "Alpha_Wolf", "Buffalo", "Juvenile_Buffalo", "Cow", "Calf", "Chick", "Chicken",
                             "BlueBack", "Dog", "CaveWorm", "SandWorm", "Bear" }
    tables.table("AICreatureType", S .. "AICreatureType", rows.AICreatureType, order.AICreatureType)

    local function setup(class_path, controller, its_kind, team, described, carcass, loot)
        return { ActorClass = class_path, ControllerClass = "/Game/BP/AI/" .. controller .. "." .. controller .. "_C",
                 CreatureType = to(its_kind, "AICreatureType"), Relationships = to(team, "AIRelationships"),
                 Descriptors = list("AIDescriptors", table.unpack(described)), DeadItem = to(carcass, "ItemsStatic"),
                 Loot = to(loot, "ItemRewards"), AIGrowth = to(its_kind, "AIGrowth"), LatentDeathDuration = 10 }
    end
    local wild, tame, young = "BP_NPC_Generic_Controller", "BP_MountAIController", "BP_NPC_Juvenile_Controller"
    rows.AISetup = {
        Mount_Buffalo = setup(MOUNTS .. "BP_Mount_Buffalo.BP_Mount_Buffalo_C", tame, "Buffalo", "Player", {},
            "AnimalCarcass_Buffalo_Mount", "Buffalo_Carcass_Loot"),
        Buffalo = setup(GOAP .. "BP_NPC_Buffalo_Character.BP_NPC_Buffalo_Character_C", wild, "Buffalo", "NeutralMediumHerbivore",
            { "Neutral", "Herbivore" }, "AnimalCarcass_Buffalo", "Buffalo_Carcass_Loot"),
        Juvenile_Buffalo = setup(GOAP .. "BP_NPC_Buffalo_Juvenile_Character.BP_NPC_Buffalo_Juvenile_Character_C", young,
            "Juvenile_Buffalo", "DefaultSmallHerbivore", { "Passive", "Herbivore" }, "AnimalCarcass_Buffalo_Juvenile", "BabyBuffalo_Carcass_Loot"),
        Deer = setup(GOAP .. "BP_NPC_Deer_Character.BP_NPC_Deer_Character_C", wild, "MediumDeer", "DefaultMediumHerbivore",
            { "Passive", "Herbivore" }, "AnimalCarcass_Deer", "Deer_Carcass_Loot"),
        Conifer_Wolf = setup("/Game/BP/AI/BP_NPC_Wolf_Conifer_Character.BP_NPC_Wolf_Conifer_Character_C", wild, "Wolf",
            "NeutralMediumCarnivore", { "Neutral", "Carnivore" }, "AnimalCarcass_Conifer_Wolf", "Wolf_Carcass_Loot"),
        Juvenile_Forest_Wolf = setup(GOAP .. "BP_NPC_Wolf_Conifier_Juvenile.BP_NPC_Wolf_Conifier_Juvenile_C", young, "Wolf",
            "DefaultSmallHerbivore", { "Passive", "Herbivore" }, "AnimalCarcass_Conifer_Wolf_Juvenile", "Juvenile_Wolf_Carcass_Loot"),
        Tamed_Forest_Wolf = setup(MOUNTS .. "BP_Tamed_Wolf.BP_Tamed_Wolf_C", tame, "Wolf", "Player", {},
            "AnimalCarcass_Conifer_Wolf_Tame", "Wolf_Carcass_Loot"),
        Alpha_Wolf_Boss = setup(GOAP .. "BP_NPC_Alpha_Wolf_Character.BP_NPC_Alpha_Wolf_Character_C", wild, "Alpha_Wolf",
            "DefaultLargeCarnivore", { "Neutral", "Carnivore" }, "AnimalCarcass_Alpha_Wolf", "AlphaWolfBoss_Loot"),
        Cow = setup(MOUNTS .. "BP_Tame_Cow.BP_Tame_Cow_C", tame, "Cow", "Player", { "Passive", "Herbivore" }, "AnimalCarcass_Cow",
            "Cow_Carcass_Loot"),
        Calf = setup(GOAP .. "BP_NPC_Calf_Juvenile_Character.BP_NPC_Calf_Juvenile_Character_C", young, "Calf", "Player",
            { "Neutral", "Herbivore" }, "AnimalCarcass_Calf", "Calf_Carcass_Loot"),
        Chick = setup(GOAP .. "BP_NPC_Chick_Juvenile_Character.BP_NPC_Chick_Juvenile_Character_C", young, "Chick", "Player",
            { "Passive", "Herbivore" }, "AnimalCarcass_Chick", "Chick_Loot"),
        Chicken = setup(MOUNTS .. "BP_Tame_Chicken.BP_Tame_Chicken_C", tame, "Chicken", "Player", { "Passive", "Herbivore" },
            "AnimalCarcass_Chicken", "Chicken_Loot"),
        Chicken_A2 = setup(MOUNTS .. "BP_Tame_Chicken_A2.BP_Tame_Chicken_A2_C", tame, "Chicken", "Player", { "Passive", "Herbivore" },
            "AnimalCarcass_Chicken", "Chicken_Loot"),
        BlueBack = setup(GOAP .. "BP_NPC_BlueBack_Character.BP_NPC_BlueBack_Character_C", wild, "BlueBack", "NeutralMediumHerbivore",
            { "Neutral", "Herbivore" }, "AnimalCarcass_BlueBack", "Blueback_Carcass_Loot"),
        Tame_Dog_A1 = setup(MOUNTS .. "BP_Tame_Dog_A1.BP_Tame_Dog_A1_C", tame, "Dog", "Player", {}, "AnimalCarcass_Tame_Dog_A",
            "Dog_Carcass_Loot"),
        CaveWorm = setup("/Game/BP/AI/BP_CRE_CaveWorm.BP_CRE_CaveWorm_C", "BP_CRE_CaveWorm_Controller", "CaveWorm",
            "DefaultLargeCarnivore", { "Aggressive" }, "None", "Caveworm_Loot"),
        SandWorm = setup("/Game/BP/AI/Bosses/BP_FactionBoss_SandWorm.BP_FactionBoss_SandWorm_C", "BP_FactionBoss_Controller_SandWorm",
            "SandWorm", "DefaultLargeCarnivore", { "Aggressive" }, "None", "Sandworm_Loot"),
    }
    -- the tamed buffalo comes first, so that a kind asked by name is seen to give the variant named like it
    order.AISetup = { "Mount_Buffalo", "Buffalo", "Juvenile_Buffalo", "Deer", "Conifer_Wolf", "Juvenile_Forest_Wolf",
                      "Tamed_Forest_Wolf", "Alpha_Wolf_Boss", "Cow", "Calf", "Chick", "Chicken", "Chicken_A2", "BlueBack", "Tame_Dog_A1",
                      "CaveWorm", "SandWorm" }
    tables.table("AISetup", S .. "AISetup", rows.AISetup, order.AISetup)

    local function rule(seconds, nutrition, range, tamed, grown, juvenile, prohibited)
        return { Behaviour = "/Game/BP/AI/Taming/BP_TamingComponent.BP_TamingComponent_C", TameDurationInSeconds = seconds,
                 DesiredTemperatureRange = { X = range[1], Y = range[2] }, DesiredShelterPercentage = 0,
                 DesiredNutritionPercentage = nutrition, RequiredTamingModifiers = {},
                 ProhibitedTamingModifiers = list("ModifierStates", table.unpack(prohibited or {})), TamedAI = to(tamed, "AISetup"),
                 MatureCreatureType = to(grown, "AISetup"), JuvenileCreatureType = to(juvenile, "AISetup"),
                 PercentChanceToSpawnJuvenile = 33, GestationPeriodSeconds = 3000 }
    end
    local soaked = { "Wet", "Sleepy" }
    rows.Tames = {
        -- the grown buffalo is spelled as the engine first saw the name, not as its row is
        Buffalo = rule(900, 25, { 15, 45 }, "Mount_Buffalo", "buffalo", "Juvenile_Buffalo", soaked),
        Forest_Wolf = rule(600, 25, { 10, 40 }, "Tamed_Forest_Wolf", "Conifer_Wolf", "Juvenile_Forest_Wolf"),
        Calf = rule(900, 25, { 10, 40 }, "Cow", "Cow", "Calf", soaked),
        Chick = rule(900, 25, { 10, 40 }, "Chicken", "Chicken", "Chick", soaked),
        Chick1 = rule(900, 25, { 10, 40 }, "Chicken_A2", "Chicken_A2", "Chick", soaked),
        -- the game's own table names two variants here that it does not have
        Blueback = rule(900, 50, { 10, 40 }, "Mount_BlueBack", "BlueBack", "Juvenile_Blueback", soaked),
        Dog = rule(600, 25, { 10, 40 }, "Tame_Dog_A1", "None", "None"),
    }
    order.Tames = { "Buffalo", "Forest_Wolf", "Calf", "Chick", "Chick1", "Blueback", "Dog" }
    tables.table("Tames", S .. "IcarusTamingData", rows.Tames, order.Tames)

    local function mount(variant, growth, moves, fights)
        return { AISetup = to(variant, "AISetup"), Icon = "/Game/Assets/2DArt/UI/Talents/Companion/T_Talent_Base.T_Talent_Base",
                 Variations = { { bCanBeSelected = true, Weighting = 2000 } }, SupportedMovementStates = moves,
                 SupportedCombatStates = fights, DefaultNames = { "Daisy", "Bruce" }, GrowthCurve = to(growth, "CharacterGrowth"),
                 bUseTemperature = true, ComfortableTemperatureRange = { X = 8, Y = 42 } }
    end
    rows.Mounts = {
        Buffalo = mount("Mount_Buffalo", "AI_Mounts", { 1, 2, 3, 4 }, { 1, 2, 3 }),
        Wolf = mount("tamed_forest_wolf", "AI_Pets", { 1, 2 }, { 1, 2, 3 }),
        Cow = mount("Cow", "AI_Pets", { 1, 2 }, { 1 }),
        Blueback = mount("Mount_BlueBack", "AI_Mounts", { 1, 2, 3, 4 }, { 1, 2, 3 }),
    }
    order.Mounts = { "Buffalo", "Wolf", "Cow", "Blueback" }
    tables.table("Mounts", S .. "IcarusMount", rows.Mounts, order.Mounts)

    local function saddle(tag, ...)
        return { SaddleTag = { TagName = tag }, SupportedMount = list("Mounts", ...), SkeletalMesh = "/Game/ASS/ITM/SK_ITM_Harness.SK_ITM_Harness",
                 AttachSocket = "RigRoot" }
    end
    rows.Saddles = {
        Saddle_Buffalo_Standard = saddle("Item.Mount.Saddle.Standard", "Buffalo"),
        Saddle_Buffalo_Cargo = saddle("Item.Mount.Saddle.Cargo", "buffalo"),
        Saddle_Moa_Standard = saddle("Item.Mount.Saddle.Standard", "Moa", "Swamp_Bird"),
        Saddle_Buffalo_Cart = saddle("Item.Mount.Saddle.Cart", "Buffalo", "Tusker"),
    }
    order.Saddles = { "Saddle_Buffalo_Standard", "Saddle_Buffalo_Cargo", "Saddle_Moa_Standard", "Saddle_Buffalo_Cart" }
    tables.table("Saddles", S .. "SaddleData", rows.Saddles, order.Saddles)
    tables.fill(250)

    -- makers

    local INVALID = world.INVALID
    local serial = 0

    local function handle(row, table_name) return { RowName = values.name(row), DataTableName = values.name(table_name) } end
    zoo.handle = handle

    -- An action object whose class is BP_IcarusGOAPAction_<name>_C, or the bare IcarusGOAPAction for the name "".
    local function action_object(name)
        local class_name = name == "" and "IcarusGOAPAction" or ("BP_IcarusGOAPAction_" .. name .. "_C")
        if not classes[class_name] then
            class("/Game/BP/AI/GOAP/Actions/BP_IcarusGOAPAction_" .. name .. "." .. class_name, "IcarusGOAPAction")
        end
        serial = serial + 1
        return (values.part(classes[class_name], class_name .. "_" .. serial, {}))
    end

    -- One creature of a variant. `over` may give at, level, team, row (what its own row handle says), stance, action,
    -- and quiet = true for one that begins play without anyone being told.
    function zoo.make(variant, over)
        over = over or {}
        local spec = SPECIES[variant] or error("fake_creatures: no variant named " .. tostring(variant), 2)
        serial = serial + 1
        local who, parts = { variant = variant, name = spec.class .. "_" .. serial }, {}
        local at, level = over.at or { 0, 0, 0 }, over.level or spec.level
        local actor_values = { Location = { at[1], at[2], at[3] }, Rotation = { 0, 0, 0 }, CurrentLevel = level, bIsCrouched = false }
        local function part(key, kept_as, class_name, name, initial)
            local object, store = values.part(classes[class_name], name, initial)
            who[key], who[key .. "_store"] = object, store
            parts[#parts + 1] = object
            actor_values[kept_as] = object
        end
        part("root", "RootComponent", "CapsuleComponent", "CollisionCylinder", {
            RelativeLocation = { X = at[1], Y = at[2], Z = at[3] }, RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 }, AttachParent = INVALID,
        })
        part("state", "ActorState", spec.state or "CharacterState", "ActorState", {
            Health = over.health or spec.health, MaxHealth = spec.health, Armor = 0, MaxArmor = 0, CurrentAliveState = 0, Stamina = 100,
            MaxStamina = 100, Level = level, TotalExperience = 0, CurrentBiome = handle("Conifer", "D_Biomes"),
        })
        if not spec.pawn then
            part("movement", "CharacterMovement", "IcarusPlayerMovementComponent", "CharMoveComp",
                { Velocity = { X = 0, Y = 0, Z = 0 }, MaxWalkSpeed = spec.speed, MovementMode = 1 })
            actor_values.CurrentTarget, actor_values.LastTarget, actor_values.CurrentStance = INVALID, INVALID, over.stance or 0
        end
        actor_values.AISetup = handle(over.row or spec.row or variant, "D_AISetup")
        actor_values.EpicCreature = handle(spec.epic or "None", "D_EpicCreatures")
        actor_values.AIRelationshipTableRowNew = handle(over.team or spec.team, "D_AIRelationships")
        local doing = over.action or spec.action
        who.controller, who.controller_store = values.actor(classes[spec.controller], spec.controller .. "_" .. serial,
            { CurrentAction = doing and action_object(doing) or INVALID, CurrentGoal = INVALID, Location = { 0, 0, 0 } })
        actor_values.Controller = who.controller
        who.actor, who.store = values.actor(classes[spec.class], who.name, actor_values, parts)
        who.controller_store.Pawn = who.actor
        if world.began and not over.quiet then world.began({ get = function() return who.actor end }) end
        return who
    end

    -- Puts the creature on another team: a row of D_AIRelationships, spelled as given.
    function zoo.team(who, row) who.store.AIRelationshipTableRowNew = handle(row, "D_AIRelationships") end

    -- What its controller is doing: the name inside BP_IcarusGOAPAction_<name>_C, "" for the bare class, nil for nothing.
    function zoo.act(who, name) who.controller_store.CurrentAction = name and action_object(name) or INVALID end

    -- What it is after: an actor, or nil for nothing.
    function zoo.aim(who, target) who.store.CurrentTarget = target or INVALID end

    -- Ends its play and frees it and its controller, as when the game destroys a creature and collects it.
    function zoo.remove(who)
        world.destroy(who.actor)
        if who.controller then world.destroy(who.controller) end
        world.free(who.actor)
        if who.controller then world.free(who.controller) end
    end

    return zoo
end

return zoo
