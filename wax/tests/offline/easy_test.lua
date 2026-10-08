-- Offline tests for what a class is given (engine.easy), structs written as tables (engine.convert), the place for a
-- handle module in engine.instance, and game.IsHost. The engine is a stand-in that counts what would crash the game.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\easy_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local world = dofile("wax/tests/offline/fake_world.lua")
world.install()
local values = dofile("wax/tests/offline/fake_values.lua")
values.install(world)

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)

-- the structs of the game that matter here, with the fields the game's own index gives them
local VECTOR, HIT = "/Script/CoreUObject.Vector", "/Script/Engine.HitResult"
local HANDLE, ITEM_HANDLE, ITEM = "/Script/IcarusUtilities.RowHandle", "/Script/Icarus.ItemsStaticRowHandle", "/Script/Icarus.ItemData"
local STAT_HANDLE, STAT_ENUM = "/Script/Icarus.StatsRowHandle", "/Script/Icarus.StatsEnum"
local RELATION, MODIFIER = "/Script/Icarus.AIRelationshipsRowHandle", "/Script/Icarus.Modifier"
local NOTE, TWINS = "/Script/Icarus.WaxTestNote", "/Script/Icarus.WaxTestTwins"

values.struct(VECTOR, nil, { { "X", "FloatProperty" }, { "Y", "FloatProperty" }, { "Z", "FloatProperty" } })
values.struct(HIT, nil, { { "Time", "FloatProperty" }, { "BoneName", "NameProperty" }, { "Actor", "WeakObjectProperty" } })
values.struct("/Script/IcarusEngineUtilities.RowHandleInternal", nil, {})
values.struct(HANDLE, "/Script/IcarusEngineUtilities.RowHandleInternal",
    { { "DataTablePtr", "WeakObjectProperty" }, { "RowName", "NameProperty" }, { "DataTableName", "NameProperty" } })
values.struct(ITEM_HANDLE, HANDLE, {})
values.struct(STAT_HANDLE, HANDLE, {})
values.struct(RELATION, HANDLE, {})
values.struct("/Script/Icarus.ModifierStatesRowHandle", HANDLE, {})
values.struct("/Script/IcarusEngineUtilities.IntEnum", nil, { { "Value", "NameProperty" } })
values.struct("/Script/IcarusUtilities.RowEnum", "/Script/IcarusEngineUtilities.IntEnum", {})
values.struct(STAT_ENUM, "/Script/IcarusUtilities.RowEnum", {})
values.struct("/Script/Icarus.ItemDynamicData", nil, { { "PropertyType", "EnumProperty" }, { "Value", "IntProperty" } })
values.struct("/Script/IcarusUtilities.IcarusTableRowBase", nil, {})
values.struct(ITEM, "/Script/IcarusUtilities.IcarusTableRowBase", {
    { "ItemStaticData", "StructProperty", struct = ITEM_HANDLE },
    { "ItemDynamicData", "ArrayProperty", inner = "StructProperty", struct = "/Script/Icarus.ItemDynamicData" },
    { "bIsItemInstance", "BoolProperty" }, { "DatabaseGUID", "StrProperty" }, { "ItemOwnerLookupId", "IntProperty" },
})
values.struct(MODIFIER, nil, {
    { "Modifier", "StructProperty", struct = "/Script/Icarus.ModifierStatesRowHandle" },
    { "ModifierLifetime", "FloatProperty" }, { "ModifierEffectiveness", "IntProperty" },
})
-- made up, for the kinds of field those lack
values.struct(NOTE, nil, {
    { "Title", "TextProperty" }, { "Holder", "ObjectProperty" }, { "Kind", "ClassProperty" }, { "Mood", "EnumProperty" },
    { "Flags", "ByteProperty" }, { "Label", "StrProperty" }, { "bPinned", "BoolProperty" }, { "Weight", "FloatProperty" },
    { "Spot", "StructProperty", struct = VECTOR }, { "Seen", "SetProperty" }, { "Links", "MapProperty" },
    { "Icon", "SoftObjectProperty" }, { "Watcher", "WeakObjectProperty" }, { "OnRead", "DelegateProperty" },
})
values.struct(TWINS, nil, { { "Mode", "IntProperty" }, { "mode", "IntProperty" } })

---@type any, any
local received, moved = nil, nil      -- what the engine was last handed by a call

local object_class = world.class("/Script/CoreUObject.Object")
local actor_class = values.class("/Script/Engine.Actor", object_class, {}, {
    K2_SetActorLocation = { { "NewLocation", "StructProperty", struct = VECTOR }, { "bSweep", "BoolProperty" },
        { "SweepHitResult", "StructProperty", struct = HIT, out = true }, { "bTeleport", "BoolProperty" }, returns = "BoolProperty",
        call = function(_, args)
            moved = args
            return true, { SweepHitResult = { Time = 1 } }
        end },
})
world.class("/Script/Engine.World", object_class)
local component_class = world.class("/Script/Engine.ActorComponent", object_class)
world.class("/Script/Engine.SceneComponent", component_class)
local mode_class = world.class("/Script/Engine.GameModeBase", actor_class)
local state_class = values.class("/Script/Icarus.ActorState", component_class,
    { Health = "IntProperty", MaxHealth = "IntProperty", CurrentAliveState = "EnumProperty" })
local pawn_class = values.class("/Script/Engine.Pawn", actor_class)
local character_class = values.class("/Script/Icarus.IcarusCharacter", pawn_class, { ActorState = "ObjectProperty" })
local npc_class = values.class("/Script/Icarus.IcarusNPCCharacter", character_class,
    { CurrentLevel = "IntProperty", AIRelationshipTableRowNew = { "StructProperty", struct = RELATION } })
local wolf_class = values.class("/Game/BP/AI/BP_Wolf.BP_Wolf_C", npc_class)
local mount_class = values.class("/Script/Icarus.IcarusMountCharacter", npc_class, { MountName = "StrProperty" })
local moa_class = values.class("/Game/BP/Mounts/BP_Moa.BP_Moa_C", mount_class)
-- the player's class has a function called IsAlive, which no creature class has
local player_class = values.class("/Script/Icarus.IcarusPlayerCharacterSurvival", character_class, {},
    { IsAlive = { returns = "BoolProperty", call = function() return true end } })
local hero_class = values.class("/Game/BP/Player/BP_Player.BP_Player_C", player_class)
local inventory_class = values.class("/Script/Icarus.Inventory", component_class, {}, {
    CanAdd = { { "Item", "StructProperty", struct = ITEM }, { "Count", "IntProperty" }, returns = "BoolProperty",
        call = function(_, args)
            received = args
            return true
        end },
    FindItemCountByType = { { "Item", "StructProperty", struct = ITEM_HANDLE }, { "bIncludeBags", "BoolProperty" }, returns = "IntProperty",
        call = function(_, args)
            received = args
            return 64
        end },
})
local stats_class = values.class("/Script/Icarus.IcarusStatContainer", component_class, {}, {
    GetStat = { { "Stat", "StructProperty", struct = STAT_ENUM }, returns = "IntProperty",
        call = function(_, args)
            received = args
            return 300
        end },
    GetStatByRowHandle = { { "Stat", "StructProperty", struct = STAT_HANDLE }, returns = "IntProperty",
        call = function(_, args)
            received = args
            return 300
        end },
})
local board_class = values.class("/Script/Icarus.WaxTestBoard", actor_class,
    { Note = { "StructProperty", struct = NOTE }, Lost = { "StructProperty", struct = "/Script/Icarus.NotDeclared" } },
    { Pin = { { "Note", "StructProperty", struct = NOTE }, { "Where", "StructProperty", struct = VECTOR },
        call = function(_, args) received = args end } })
-- a class whose struct property does not say which struct it holds
local old_class = world.class("/Script/Icarus.WaxTestOld", actor_class, { Spot = { "StructProperty", struct = "Vector" } })
local math_class = values.class("/Script/Engine.KismetMathLibrary", object_class, {}, {
    BreakVector = { { "InVec", "StructProperty", struct = VECTOR }, { "X", "FloatProperty", out = true },
        { "Y", "FloatProperty", out = true }, { "Z", "FloatProperty", out = true },
        call = function(_, args) return nil, { X = args.InVec.X, Y = args.InVec.Y, Z = args.InVec.Z } end },
})
local string_class = values.class("/Script/Engine.KismetStringLibrary", object_class, {}, {
    Split = { { "SourceString", "StrProperty" }, { "InStr", "StrProperty" }, { "LeftS", "StrProperty", out = true },
        { "RightS", "StrProperty", out = true }, { "SearchCase", "ByteProperty" }, { "SearchDir", "ByteProperty" }, returns = "BoolProperty",
        call = function(_, args)
            local text, mark = args.SourceString, args.InStr
            local at = args.SearchDir == 1 and text:match(".*()" .. mark) or text:find(mark, 1, true)
            return true, { LeftS = text:sub(1, at - 1), RightS = text:sub(at + #mark) }
        end },
})

local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local sched = Wax.import("core.sched")
local log = Wax.import("core.log")
local reflect = Wax.import("engine.reflect")
local easy = Wax.import("engine.easy")
local convert = Wax.import("engine.convert")
local instance = Wax.import("engine.instance")
local game_module = Wax.import("engine.game")
game_module.start()
Wax.game = game_module.root
Wax.import("engine.actors").start()
local game = game_module.root

local function frame() sched.step() end

local misused = 0
local function reset()
    misused = misused + values.misuse
    values.reset()
end

local serial = 0
local function character(class, health)
    serial = serial + 1
    local state = values.part(state_class, "ActorState", { Health = health or 100, MaxHealth = 100, CurrentAliveState = 0 })
    local actor, store = values.actor(class, rawget(class, "__name") .. "_" .. serial, {
        ActorState = state, CurrentLevel = 5, Location = { 0, 0, 0 },
        AIRelationshipTableRowNew = { RowName = values.name("Default"), DataTableName = values.name("D_AIRelationships") },
    }, { state })
    return actor, store, state
end

local function thing(class, name)
    serial = serial + 1
    return values.actor(class, name .. "_" .. serial, { Location = { 0, 0, 0 } })
end

-- The line of the test file that is two lines below the call, for "the error names the mod's line".
local function at(err, line, what)
    t.ok(tostring(err):find("easy_test.lua:" .. line .. ":", 1, true), (what or "the error") .. " should name line " .. line .. ": " .. tostring(err))
end

local function health(_, raw) return raw.ActorState.Health end

-- Runs fn with convert.CHECK_PLAIN as given and puts back what it was, so these tests hold whichever way it is set.
local function with_check(on, fn)
    local was = convert.CHECK_PLAIN
    convert.CHECK_PLAIN = on
    local ok, problem = pcall(fn)
    convert.CHECK_PLAIN = was
    if not ok then error(problem, 0) end
end

-- ------------------------------------------------------------------------------------------ what a class is given

t.test("a class is given a field, and every class built on it has it", function()
    local undo = easy.class("IcarusCharacter", { fields = { Health = health } })
    local wolf, hero = instance.wrap(character(wolf_class)), instance.wrap(character(hero_class, 80))
    t.eq(wolf.Health, 100)
    t.eq(hero.Health, 80)
    local rock = instance.wrap(thing(actor_class, "Rock"))
    t.raises(function() return rock.Health end, "Health is not a member of Actor")
    undo()
    t.raises(function() return wolf.Health end, "Health is not a member of BP_Wolf_C")
end)

t.test("a field's function is handed the Instance and its engine object", function()
    local seen_self, seen_raw
    local undo = easy.class("IcarusCharacter", { fields = { Probe = function(self, raw)
        seen_self, seen_raw = self, raw
        return "read"
    end } })
    local actor = character(wolf_class)
    local wolf = instance.wrap(actor)
    t.eq(wolf.Probe, "read")
    t.ok(rawequal(seen_self, wolf), "the Instance")
    t.ok(rawequal(seen_raw, actor), "the engine object")
    t.ok(instance.is_instance(seen_self))
    undo()
end)

t.test("a field with a setter can be assigned, and a class further down may give the name again", function()
    local wrote = {}
    local base = easy.class("IcarusCharacter", {
        fields = { Level = function() return "base" end },
        setters = { Level = function(_, _, value) wrote[#wrote + 1] = "base " .. value end },
    })
    local npc = easy.class("IcarusNPCCharacter", { setters = { Level = function(_, raw, value)
        wrote[#wrote + 1] = "npc " .. value
        raw.CurrentLevel = value
    end } })
    local mount = easy.class("IcarusMountCharacter", {
        fields = { Level = function() return "mount" end },
        setters = { Level = function(_, _, value) wrote[#wrote + 1] = "mount " .. value end },
    })
    local wolf_actor, wolf_store = character(wolf_class)
    local wolf, hero, moa = instance.wrap(wolf_actor), instance.wrap(character(hero_class)), instance.wrap(character(moa_class))
    wolf.Level = 7
    hero.Level = 3
    moa.Level = 9
    t.eq(table.concat(wrote, ", "), "npc 7, base 3, mount 9")
    t.eq(wolf_store.CurrentLevel, 7, "the setter wrote through the engine object")
    t.eq(wolf.Level, "base", "the creature class replaced the setter only")
    t.eq(moa.Level, "mount")
    mount()
    moa.Level = 2
    t.eq(wrote[#wrote], "npc 2", "without the mount's own, the next class up is used")
    npc()
    base()
end)

t.test("a field without a setter and a method cannot be assigned", function()
    local undo = easy.class("IcarusCharacter", { fields = { MaxHealth = function() return 100 end }, methods = { Heal = function() end } })
    local wolf = instance.wrap(character(wolf_class))
    t.raises(function() wolf.MaxHealth = 5 end, "MaxHealth is read-only")
    t.raises(function() wolf.Heal = 5 end, "Heal is read-only")
    undo()
end)

t.test("a method is called with a colon, is handed the engine object and returns everything", function()
    local undo = easy.class("IcarusCharacter", { methods = { Heal = function(self, raw, amount, note)
        raw.ActorState.Health = raw.ActorState.Health + amount
        return self, raw.ActorState.Health, note
    end } })
    local actor, _, state = character(wolf_class, 40)
    local wolf = instance.wrap(actor)
    local who, now, note = wolf:Heal(5, nil)
    t.ok(rawequal(who, wolf))
    t.eq(now, 45)
    t.eq(note, nil)
    t.eq(values.of(state).Health, 45)
    t.eq(select("#", wolf:Heal(1, nil)), 3, "a nil at the end is still returned")
    t.raises(function() wolf.Heal(5) end, "call Heal with a colon: instance:Heal(...)")
    undo()
end)

t.test("Wax's own names stay first: a class cannot be given one", function()
    t.raises(function() easy.class("Actor", { fields = { Name = function() end } }) end, "every Instance has 'Name' already")
    t.raises(function() easy.class("Actor", { methods = { GetChildren = function() end } }) end, "every Instance has 'GetChildren' already")
    t.raises(function() easy.class("Actor", { setters = { Raw = function() end } }) end, "every Instance has 'Raw' already")
end)

t.test("what a member raises names the line of the mod that used it", function()
    local undo = easy.class("IcarusCharacter", {
        fields = { Mood = function() error("only the host can read a mood", 0) end },
        setters = { Mood = function() error("only the host can change a mood", 0) end },
        methods = { Calm = function() error("only the host can calm a creature", 0) end },
    })
    local wolf = instance.wrap(character(wolf_class))
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        local mood = wolf.Mood
        return mood
    end, "only the host can read a mood")
    at(err, line, "a field")
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        wolf.Mood = "calm"
    end, "only the host can change a mood")
    at(err, line, "a setter")
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        wolf:Calm()
    end, "only the host can calm a creature")
    at(err, line, "a method")
    undo()
end)

t.test("nothing a class was given runs on an object that is gone, and the object is not touched", function()
    local ran = 0
    local undo = easy.class("IcarusCharacter", {
        fields = { Health = function(_, raw)
            ran = ran + 1
            return raw.ActorState.Health
        end },
        setters = { Health = function() ran = ran + 1 end },
        methods = { Heal = function() ran = ran + 1 end },
    })
    local actor = character(wolf_class)
    local wolf = instance.wrap(actor)
    t.eq(wolf.Health, 100)
    world.destroy(actor)
    world.free(actor)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        local value = wolf.Health
        return value
    end, "this BP_Wolf_C no longer exists")
    at(err, line, "a field of something gone")
    t.raises(function() wolf.Health = 1 end, "no longer exists")
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        wolf:Heal()
    end, "no longer exists")
    at(err, line, "a method of something gone")
    t.eq(ran, 1)
    t.eq(world.dead_touches, 0)
    undo()
end)

t.test("GetMembers lists what the class is given with the game's own, and a miss suggests any of them", function()
    local undo = easy.class("IcarusCharacter", { fields = { Health = health }, methods = { Heal = function() end } })
    local wolf = instance.wrap(character(wolf_class))
    local members, has = wolf:GetMembers(), {}
    for index, name in ipairs(members) do
        has[name] = true
        t.ok(index == 1 or members[index - 1] < name, "sorted, each name once: " .. name)
    end
    t.ok(has.Health and has.Heal, "what Wax gives")
    t.ok(has.CurrentLevel and has.ActorState and has.K2_SetActorLocation, "what the game has")
    local err = t.raises(function() return wolf.Helth end, "Helth is not a member of BP_Wolf_C")
    t.ok(tostring(err):find("'Health'", 1, true), tostring(err))
    err = t.raises(function() wolf.Helth = 1 end, "Helth is not a property of BP_Wolf_C")
    t.ok(tostring(err):find("'Health'", 1, true), tostring(err))
    err = t.raises(function() return wolf.GetChildrn end, "GetChildrn is not a member")
    t.ok(tostring(err):find("'GetChildren'", 1, true), "Wax's own names are suggested too: " .. tostring(err))
    err = t.raises(function() return wolf.CurrentLevl end, "CurrentLevl is not a member")
    t.ok(tostring(err):find("'CurrentLevel'", 1, true), tostring(err))
    undo()
    err = t.raises(function() return wolf.Helth end, "Helth is not a member")
    t.ok(not tostring(err):find("'Health'", 1, true), "a name that was taken back is not suggested: " .. tostring(err))
    has = {}
    for _, name in ipairs(wolf:GetMembers()) do has[name] = true end
    t.ok(not has.Health and has.CurrentLevel)
end)

t.test("Get, Set and Call reach the game's own members only, and say so when the name is one Wax gives", function()
    local undo = easy.class("IcarusCharacter", { fields = { Health = health }, setters = { Health = function() end },
        methods = { Heal = function() end } })
    local wolf = instance.wrap(character(wolf_class))
    t.eq(wolf:Get("CurrentLevel"), 5)
    local err = t.raises(function() return wolf:Get("Health") end, "Health is not a property of BP_Wolf_C")
    t.ok(tostring(err):find("Health is a member Wax gives this class. Use it as instance.Health", 1, true), tostring(err))
    err = t.raises(function() wolf:Set("Health", 1) end, "Health is not a property of BP_Wolf_C")
    t.ok(tostring(err):find("Use it as instance.Health", 1, true), tostring(err))
    err = t.raises(function() wolf:Call("Heal") end, "Heal is not a function of BP_Wolf_C")
    t.ok(tostring(err):find("Call it as instance:Heal(...)", 1, true), tostring(err))
    undo()
end)

t.test("a name the game's own class has too: Wax's is read, the game's is reached with Call, and the clash is noted once", function()
    local before, newest = #easy.clashes(), log.newest_id()
    local undo = easy.class("IcarusCharacter", { fields = { IsAlive = function() return "from Wax" end } })
    local wolf = instance.wrap(character(wolf_class))
    t.eq(wolf.IsAlive, "from Wax")
    t.eq(#easy.clashes(), before, "no creature class has that name")
    local hero = instance.wrap(character(hero_class))
    t.eq(hero.IsAlive, "from Wax")
    t.eq(hero:Call("IsAlive"), true, "the game's own function")
    local clashes = easy.clashes()
    t.eq(#clashes, before + 1)
    local found = clashes[#clashes]
    t.eq(found.Class, "IcarusCharacter")
    t.eq(found.Name, "IsAlive")
    t.eq(found.On, "BP_Player_C")
    t.eq(found.Kind, "function")
    local second = instance.wrap(character(player_class))
    t.eq(second.IsAlive, "from Wax")
    t.eq(#easy.clashes(), before + 1, "once for the name, however many classes show it")
    t.eq(#log.since(newest, { channel = "wax.easy", level = "warn" }), 1)
    t.eq(easy.stats().clashes, before + 1)
    undo()
end)

t.test("what a mod registers goes with the mod", function()
    local mod = scope.new("mod")
    scope.run(mod, function() easy.class("IcarusCharacter", { fields = { Threat = function() return 3 end } }) end)
    local wolf = instance.wrap(character(wolf_class))
    t.eq(wolf.Threat, 3)
    t.eq(mod:size(), 1)
    mod:destroy()
    t.raises(function() return wolf.Threat end, "Threat is not a member")
    t.eq(easy.taken("Threat"), false)
end)

t.test("registering again under the same source takes the place of the first, and without a source both stay", function()
    local first = easy.class("IcarusCharacter", { fields = { Armor = function() return 1 end, Shelter = function() return 1 end } }, "character")
    local second = easy.class("IcarusCharacter", { fields = { Armor = function() return 2 end } }, "character")
    local wolf = instance.wrap(character(wolf_class))
    t.eq(wolf.Armor, 2)
    t.raises(function() return wolf.Shelter end, "Shelter is not a member")
    first()
    t.eq(wolf.Armor, 2, "taking back what was already replaced changes nothing")
    second()
    t.raises(function() return wolf.Armor end, "Armor is not a member")
    local one = easy.class("IcarusCharacter", { fields = { Stamina = function() return 1 end } })
    local two = easy.class("IcarusCharacter", { fields = { Stamina = function() return 2 end } })
    t.eq(wolf.Stamina, 2, "the later one is read")
    two()
    t.eq(wolf.Stamina, 1)
    two()
    one()
    one()
    t.raises(function() return wolf.Stamina end, "Stamina is not a member")
end)

t.test("several classes at once, and a registration that is not right says what is wrong", function()
    local undo = easy.class({ "IcarusNPCCharacter", "IcarusPlayerCharacterSurvival" }, { fields = { Kind = function() return "k" end } })
    t.eq(instance.wrap(character(wolf_class)).Kind, "k")
    t.eq(instance.wrap(character(hero_class)).Kind, "k")
    undo()
    local fn = function() end
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        easy.class("Actor", { field = {} })
    end, "a class is given fields, setters and methods, not 'field'. Did you mean 'fields'?")
    at(err, line, "a registration")
    t.raises(function() easy.class("Actor", { fields = { health = fn } }) end, "'health' in fields is not a name for a member")
    t.raises(function() easy.class("Actor", { fields = { ["Max Health"] = fn } }) end, "starts with a capital letter and has no spaces")
    t.raises(function() easy.class("Actor", { fields = { Health = 5 } }) end, "fields.Health must be a function, got number")
    t.raises(function() easy.class("Actor", { fields = { Heal = fn }, methods = { Heal = fn } }) end, "as a method and as a field")
    t.raises(function() easy.class("Actor", { setters = { Heal = fn }, methods = { Heal = fn } }) end, "as a method and as a field")
    t.raises(function() easy.class("Actor", { fields = fn }) end, "fields is a table of names and functions, got function")
    t.raises(function() easy.class(5, {}) end, "expects a class name")
    t.raises(function() easy.class({}, {}) end, "expects a class name")
    t.raises(function() easy.class("Actor", "fields") end, "expects a table with fields, setters and methods, got string")
    t.raises(function() easy.class("Actor", {}, 5) end, "the source is a name")
    t.eq(easy.stats().registrations, 0, "nothing of a refused registration is kept")
end)

t.test("what a class is given is worked out once for the class, and again after anything is registered", function()
    local undo = easy.class("IcarusCharacter", { fields = { Health = health } })
    local wolf = instance.wrap(character(wolf_class))
    local info, plain = reflect.class_info(wolf_class), reflect.class_info(actor_class)
    t.eq(easy.merged[info], nil)
    t.eq(wolf.Health, 100)
    local kept = easy.merged[info]
    t.ok(kept and kept.fields.Health, "kept for the class")
    t.eq(wolf.Health, 100)
    t.ok(rawequal(easy.merged[info], kept), "and not made again")
    t.raises(function() return instance.wrap(thing(actor_class, "Rock")).Health end, "is not a member")
    t.eq(easy.merged[plain], false, "a class that is given nothing is remembered as that")
    local more = easy.class("IcarusNPCCharacter", { fields = { Target = function() return nil end } })
    t.eq(easy.merged[info], nil)
    t.eq(wolf.Target, nil, "a field may give nil")
    t.eq(table.concat(easy.merged[info].names, ","), "Health,Target")
    more()
    undo()
end)

t.test("stats name the classes no object has had yet, and taken says whether a name is given at all", function()
    local undo = easy.class({ "IcarusCharacter", "IcarusCharcter" }, { fields = { Health = health } })
    t.eq(easy.taken("Health"), true)
    t.eq(easy.taken("Mana"), false)
    t.eq(instance.wrap(character(wolf_class)).Health, 100)
    local stats = easy.stats()
    t.eq(stats.registrations, 2)
    t.eq(stats.classes, 2)
    t.eq(table.concat(stats.unseen, ","), "IcarusCharcter", "the misspelt class is the one nobody met")
    undo()
    t.eq(easy.stats().registrations, 0)
    t.eq(easy.taken("Health"), false)
end)

-- --------------------------------------------------------------------------------------- structs written as tables

t.test("the stand-in takes arguments as the game was seen to: scalar outs share one table and what follows moves up", function()
    local maths = values.part(math_class, "Default__KismetMathLibrary", {})
    local x, y, z = {}, {}, {}
    maths:BreakVector({ X = 7, Y = 8, Z = 9 }, x, y, z)
    t.eq(x.X + x.Y + x.Z, 24)
    t.eq(next(y), nil)
    t.eq(next(z), nil)
    local strings = values.part(string_class, "Default__KismetStringLibrary", {})
    local left, right = {}, {}
    strings:Split("a=b=c", "=", left, right, 0, 1)
    t.eq(left.LeftS .. " | " .. left.RightS, "a | b=c", "the search direction was read from a table and became 0")
    local both = {}
    strings:Split("a=b=c", "=", both, 1, 0, 0)
    t.eq(both.LeftS .. " | " .. both.RightS, "a=b | c", "one table and the arguments one place early is what works")
    t.ok(values.silent > 0, "the engine made numbers out of tables without a word")
    t.eq(values.crashes, 0)
    reset()
end)

t.test("a struct's fields are read with those of what it is built on, once", function()
    reset()
    local shape = convert.shape(ITEM_HANDLE)
    t.eq(shape.name, "ItemsStaticRowHandle")
    t.ok(shape.by.RowName and shape.by.DataTableName and shape.by.DataTablePtr, "the fields come from RowHandle")
    t.eq(shape.by.RowName.type, "NameProperty")
    t.eq(values.finds, 3, "the struct and the two it is built on")
    t.ok(rawequal(convert.shape(ITEM_HANDLE), shape))
    t.eq(values.finds, 3)
    t.eq(convert.shape(nil), nil)
    t.eq(values.misuse, 0, "only the struct found by its path was asked for its fields")
end)

t.test("a row handle written with strings becomes one with names, and the mod's table is left alone", function()
    reset()
    local written = { RowName = "Wood", DataTableName = "D_ItemsStatic" }
    local out = convert.struct(written, convert.shape(ITEM_HANDLE), "handle")
    t.ok(not rawequal(out, written))
    t.eq(out.RowName:type(), "FName")
    t.eq(out.RowName:ToString(), "Wood")
    t.eq(out.DataTableName:ToString(), "D_ItemsStatic")
    t.eq(written.RowName, "Wood")
    local ready = { RowName = FName("Stone") }
    t.ok(rawequal(convert.struct(ready, convert.shape(ITEM_HANDLE), "handle"), ready), "a name that is one already needs nothing")
    local enum = convert.struct({ Value = "MaximumHealth_+" }, convert.shape(STAT_ENUM), "stat")
    t.eq(enum.Value:ToString(), "MaximumHealth_+", "a row enum is the same kind of thing")
end)

t.test("a field's name is taken in any letters and sent under its own, and a wrong one is refused with the nearest", function()
    local shape = convert.shape(ITEM)
    local out = convert.struct({ itemstaticdata = { rowname = "Wood", DATATABLENAME = "D_ItemsStatic" } }, shape, "item")
    t.eq(values.plain(out).ItemStaticData.RowName, "Wood")
    t.eq(values.plain(out).ItemStaticData.DataTableName, "D_ItemsStatic")
    t.eq(out.itemstaticdata, nil)
    t.raises(function() convert.struct({ ItemStaticData = { RowNam = "Wood" } }, shape, "item") end,
        "item.ItemStaticData: ItemsStaticRowHandle has no field named 'RowNam'. Did you mean 'RowName'?")
    t.raises(function() convert.struct({ "Wood" }, convert.shape(ITEM_HANDLE), "handle") end,
        "handle: ItemsStaticRowHandle is written with the names of its fields, and this table has the key 1")
    t.raises(function() convert.struct({ RowName = "a", rowname = "b" }, convert.shape(ITEM_HANDLE), "handle") end, "handle.RowName is given twice")
    -- two fields that differ only by their letters' case are each named exactly, and nothing else is guessed
    local twins = convert.shape(TWINS)
    local both = convert.struct({ Mode = 1, mode = 2 }, twins, "twins")
    t.eq(both.Mode + both.mode * 10, 21)
    local err = t.raises(function() convert.struct({ MODE = 1 }, twins, "twins") end, "WaxTestTwins has no field named 'MODE'")
    t.ok(tostring(err):find("'Mode'", 1, true) and tostring(err):find("'mode'", 1, true), tostring(err))
end)

t.test("each kind of field takes its own kind of value, and anything else is refused by name", function()
    reset()
    local shape, handle = convert.shape(NOTE), convert.shape(ITEM_HANDLE)
    local holder_actor = thing(actor_class, "Holder")
    local holder = instance.wrap(holder_actor)
    local out = convert.struct({ Title = "Camp", Holder = holder, Kind = actor_class, Mood = 2, Flags = 255.0, Label = 12, bPinned = true,
        Weight = 1.5, Spot = { X = 1, Y = 2.5, Z = 3 } }, shape, "note")
    t.eq(out.Title:type(), "FText")
    t.eq(out.Title:ToString(), "Camp")
    t.ok(rawequal(out.Holder, holder_actor), "an Instance goes in as its engine object")
    t.ok(rawequal(out.Kind, actor_class), "an engine object goes in as it is")
    t.eq(out.Mood, 2)
    t.eq(math.type(out.Flags), "integer")
    t.eq(out.Label, "12")
    t.eq(out.bPinned, true)
    t.eq(out.Weight, 1.5)
    t.eq(out.Spot.Y, 2.5)
    t.ok(rawequal(convert.struct({ Title = FText("Camp") }, shape, "note").Title:ToString(), "Camp"))
    local function refused(value, struct, fragment) t.raises(function() convert.struct(value, struct, "note") end, fragment) end
    refused({ Mood = "happy" }, shape, "note.Mood expects a whole number, got string")
    refused({ Mood = 1.5 }, shape, "note.Mood expects a whole number, got 1.5")
    refused({ bPinned = 1 }, shape, "note.bPinned expects true or false, got number")
    refused({ Weight = "heavy" }, shape, "note.Weight expects a number, got string")
    refused({ Title = 5 }, shape, "note.Title expects text (a string), got number")
    refused({ Title = FName("Camp") }, shape, "note.Title expects text (a string), got userdata")
    refused({ Label = {} }, shape, "note.Label expects a string, got table")
    refused({ Holder = "me" }, shape, "note.Holder expects an Instance, got string")
    refused({ Holder = FName("me") }, shape, "note.Holder expects an Instance, got userdata")
    refused({ Spot = 5 }, shape, "note.Spot expects a struct written as a table of its fields, got number")
    refused({ Spot = holder }, shape, "note.Spot expects a struct written as a table of its fields, got an Instance")
    refused({ Spot = { X = "far" } }, shape, "note.Spot.X expects a number, got string")
    refused({ RowName = 5 }, handle, "note.RowName expects a name (a string), got number")
    refused({ RowName = true }, handle, "note.RowName expects a name (a string), got boolean")
    refused({ RowName = holder }, handle, "note.RowName expects a name (a string), got an Instance")
    refused({ RowName = FText("Wood") }, handle, "note.RowName expects a name (a string), got userdata")
    refused({ RowName = ("x"):rep(1024) }, handle, "note.RowName is a name, and a name has at most 1023 letters")
    world.destroy(holder_actor)
    world.free(holder_actor)
    refused({ Holder = holder }, shape, "this Actor no longer exists")
    t.eq(world.dead_touches, 0)
    t.eq(values.crashes, 0)
end)

t.test("what UE4SS cannot take inside a struct table is refused before it gets there", function()
    reset()
    local item, note = convert.shape(ITEM), convert.shape(NOTE)
    t.raises(function() convert.struct({ ItemDynamicData = { { PropertyType = 7, Value = 10 } } }, item, "item") end,
        "item.ItemDynamicData is a list inside a struct, which a struct written as a table cannot carry into the engine")
    t.raises(function() convert.struct({ ItemDynamicData = {} }, item, "item") end, "is a list inside a struct")
    local engine_list = world.array({})
    local with_list = { ItemDynamicData = engine_list }
    t.ok(rawequal(convert.struct(with_list, item, "item"), with_list), "the engine's own array may go in")
    t.raises(function() convert.struct({ ItemStaticData = values.struct_value(ITEM_HANDLE, {}) }, item, "item") end,
        "item.ItemStaticData is a struct inside a struct. Write it as a table of its fields")
    t.raises(function() convert.struct({ Seen = {} }, note, "note") end, "note.Seen is a set, which cannot be given inside a struct written as a table")
    t.raises(function() convert.struct({ Links = {} }, note, "note") end, "note.Links is a map")
    t.raises(function() convert.struct({ Icon = "/Game/Icon" }, note, "note") end, "note.Icon is a soft object reference")
    t.raises(function() convert.struct({ Watcher = engine_list }, note, "note") end, "note.Watcher is a weak object reference")
    t.raises(function() convert.struct({ OnRead = {} }, note, "note") end, "note.OnRead is a delegate")
    -- and each of those would have ended the game, which is why
    local raw = values.part(inventory_class, "Raw", {})
    for _, bad in ipairs({ { ItemDynamicData = {} }, { ItemStaticData = values.struct_value(ITEM_HANDLE, {}) },
                           { ItemStaticData = { RowName = "Wood" } } }) do
        local ok, problem = pcall(function() return raw:CanAdd(bad, 0) end)
        t.eq(ok, false)
        t.ok(tostring(problem):find("CRASH", 1, true), tostring(problem))
    end
    t.eq(values.crashes, 3)
    reset()
end)

t.test("a table that needs no change is handed over as it is", function()
    local shape = convert.shape(MODIFIER)
    local plain = { ModifierLifetime = 2.5, ModifierEffectiveness = 3 }
    t.ok(rawequal(convert.struct(plain, shape, "modifier"), plain))
    local empty = {}
    t.ok(rawequal(convert.struct(empty, shape, "modifier"), empty))
    local named = { Modifier = { RowName = "Bleed" }, ModifierLifetime = 2.5 }
    local out = convert.struct(named, shape, "modifier")
    t.ok(not rawequal(out, named))
    t.eq(out.Modifier.RowName:ToString(), "Bleed")
    t.eq(out.ModifierLifetime, 2.5)
    t.eq(named.Modifier.RowName, "Bleed")
end)

t.test("a struct the game does not have is asked for once, and again after a map change", function()
    reset()
    local newest = log.newest_id()
    t.eq(convert.shape("/Script/Icarus.NotThere"), nil)
    t.eq(values.misses, 1)
    t.eq(convert.shape("/Script/Icarus.NotThere"), nil)
    t.eq(values.misses, 1, "a miss costs the engine tens of milliseconds, so it is not repeated")
    t.eq(#log.since(newest, { channel = "wax.convert", level = "warn" }), 1)
    t.eq(convert.stats().unread, 1)
    convert.flush()
    t.eq(convert.stats().unread, 0)
    t.eq(convert.shape("/Script/Icarus.NotThere"), nil)
    t.eq(values.misses, 2)
    convert.flush()
    reset()
end)

-- ------------------------------------------------------------------------------- through Instance:Call and Instance:Set

t.test("an item written as a plain table passes Instance:Call, with names where the engine wants names", function()
    reset()
    local backpack = instance.wrap(values.part(inventory_class, "BackpackInventory", {}))
    local item = { ItemStaticData = { RowName = "Wood", DataTableName = "D_ItemsStatic" } }
    t.eq(backpack:Call("CanAdd", item, 0), true)
    t.eq(received.Item.ItemStaticData.RowName:type(), "FName")
    t.eq(values.plain(received.Item).ItemStaticData.RowName, "Wood")
    t.eq(values.plain(received.Item).ItemStaticData.DataTableName, "D_ItemsStatic")
    t.eq(received.Count, 0)
    t.eq(item.ItemStaticData.RowName, "Wood", "the mod's own table is as it was")
    t.eq(backpack:CanAdd({ itemstaticdata = { rowname = "Stone" }, bIsItemInstance = true, DatabaseGUID = 7 }, 2), true)
    local seen = values.plain(received.Item)
    t.eq(seen.ItemStaticData.RowName, "Stone")
    t.eq(seen.bIsItemInstance, true)
    t.eq(seen.DatabaseGUID, "7")
    t.eq(backpack:FindItemCountByType({ RowName = "Fiber", DataTableName = "D_ItemsStatic" }, false), 64)
    t.eq(values.plain(received.Item).RowName, "Fiber")
    t.eq(values.crashes, 0)
    t.eq(values.dropped, 0, "no field reached the engine under a name it does not know")
    t.eq(values.silent, 0, "and nothing was quietly made into something else")
end)

t.test("a row enum and a row handle pass the same way", function()
    reset()
    local stats = instance.wrap(values.part(stats_class, "Stat Container", {}))
    t.eq(stats:Call("GetStat", { Value = "MaximumHealth_+" }), 300)
    t.eq(values.plain(received.Stat).Value, "MaximumHealth_+")
    t.eq(stats:GetStatByRowHandle({ RowName = "MaximumHealth_+", DataTableName = "D_Stats" }), 300)
    t.eq(values.plain(received.Stat).RowName, "MaximumHealth_+")
    t.eq(values.crashes + values.dropped + values.silent, 0)
end)

t.test("a row handle property is written in place and keeps what was not named", function()
    reset()
    local actor, store = character(wolf_class)
    local wolf = instance.wrap(actor)
    wolf:Set("AIRelationshipTableRowNew", { RowName = "FriendlyAll" })
    t.eq(values.plain(store.AIRelationshipTableRowNew).RowName, "FriendlyAll")
    t.eq(values.plain(store.AIRelationshipTableRowNew).DataTableName, "D_AIRelationships")
    wolf.AIRelationshipTableRowNew = { rowname = "EnemyAll" }
    t.eq(values.plain(store.AIRelationshipTableRowNew).RowName, "EnemyAll")
    t.eq(values.crashes + values.dropped + values.silent, 0)
end)

t.test("which struct a property or a parameter holds is looked for once, through the classes the object is built on", function()
    local wolf, moa = instance.wrap(character(wolf_class)), instance.wrap(character(moa_class))
    local backpack = instance.wrap(values.part(inventory_class, "BackpackInventory", {}))
    local member = reflect.class_info(wolf_class).members.AIRelationshipTableRowNew
    t.ok(rawequal(member, reflect.class_info(moa_class).members.AIRelationshipTableRowNew), "one record for every class that has the property")
    member.struct = nil
    local walks = values.walks
    wolf:Set("AIRelationshipTableRowNew", { RowName = "FriendlyAll" })
    t.eq(member.struct, RELATION)
    t.eq(values.walks, walks + 2, "the wolf's own class has no such property, the class under it has")
    moa:Set("AIRelationshipTableRowNew", { RowName = "FriendlyAll" })
    wolf:Set("AIRelationshipTableRowNew", { RowName = "Default" })
    t.eq(values.walks, walks + 2)
    backpack:CanAdd({ ItemStaticData = { RowName = "Wood" } }, 0)
    local parameter = reflect.class_info(inventory_class).members.CanAdd.params[1]
    t.eq(parameter.struct, ITEM)
    walks = values.walks
    backpack:CanAdd({ ItemStaticData = { RowName = "Stone" } }, 0)
    t.eq(values.walks, walks)
end)

t.test("with CHECK_PLAIN off a table of plain numbers goes as it always did: nothing is looked up for it", function()
    reset()
    with_check(false, function()
        local rock = instance.wrap(thing(actor_class, "Rock"))
        local hit = {}
        t.eq(rock:Call("K2_SetActorLocation", { X = 1, Y = 2, Z = 3 }, false, hit, true), true)
        t.eq(moved.NewLocation.Y, 2)
        t.eq(hit.Time, 1, "an out table is filled, because it is the caller's own table that goes in")
        local walks, finds = values.walks, values.finds
        local where = { X = 4, Y = 5, Z = 6 }
        rock:K2_SetActorLocation(where, true, hit, false)
        t.eq(moved.NewLocation.X, 4)
        t.eq(values.walks, walks)
        t.eq(values.finds, finds)
        t.eq(reflect.class_info(actor_class).members.K2_SetActorLocation.params[1].struct, nil, "the struct was never asked for")
        t.eq(values.crashes + values.silent, 0)
    end)
end)

t.test("with CHECK_PLAIN off numbers and empty tables reach the engine unchecked as before, and with it on they are checked", function()
    reset()
    local backpack = instance.wrap(values.part(inventory_class, "BackpackInventory", {}))
    local rock = instance.wrap(thing(actor_class, "Rock"))
    with_check(false, function()
        local ok, problem = pcall(function() return backpack:Call("CanAdd", { ItemStaticData = { RowName = 5 } }, 0) end)
        t.eq(ok, false)
        t.ok(tostring(problem):find("CRASH", 1, true), "the engine reads the number as a name: " .. tostring(problem))
        ok, problem = pcall(function() return backpack:Call("CanAdd", { ItemDynamicData = {} }, 0) end)
        t.eq(ok, false)
        t.ok(tostring(problem):find("CRASH", 1, true), "an empty table where the struct has a list: " .. tostring(problem))
        t.eq(values.crashes, 2)
    end)
    reset()
    with_check(true, function()
        t.raises(function() backpack:Call("CanAdd", { ItemStaticData = { RowName = 5 } }, 0) end,
            "Inventory:CanAdd argument 1 (Item).ItemStaticData.RowName expects a name (a string), got number")
        t.raises(function() backpack:Call("CanAdd", { ItemDynamicData = {} }, 0) end,
            "Inventory:CanAdd argument 1 (Item).ItemDynamicData is a list inside a struct")
        t.raises(function() rock:K2_SetActorLocation({ X = 1, Y = 2, W = 3 }, false, {}, true) end, "Vector has no field named 'W'")
        t.eq(values.crashes, 0)
        local hit = {}
        t.eq(rock:K2_SetActorLocation({ X = 1, Y = 2, Z = 3 }, false, hit, true), true)
        t.eq(hit.Time, 1, "a table that is right still goes in as the caller's own table")
        t.eq(values.silent + values.dropped, 0)
    end)
end)

t.test("when the game does not say what a struct holds, plain numbers pass and anything else is refused with the reason", function()
    reset()
    local old_actor = world.place(old_class, "Old_1", { Location = { 0, 0, 0 } })
    local old = instance.wrap(old_actor)
    old:Set("Spot", { X = 1, Y = 2, Z = 3 })
    t.eq(rawget(old_actor, "__props").Spot.Z, 3)
    t.raises(function() old:Set("Spot", { X = "far" }) end,
        "WaxTestOld.Spot: the table holds more than numbers, and the game did not say what fields this struct has")
    t.raises(function() old:Set("Spot", 5) end, "WaxTestOld.Spot expects a struct: a table of its fields such as { X = 0, Y = 0, Z = 0 }")
    local board = instance.wrap(thing(board_class, "Board"))
    t.raises(function() board:Set("Lost", { RowName = "x" }) end, "the game did not say what fields this struct has")
    local misses = values.misses
    t.raises(function() board:Set("Lost", { RowName = "y" }) end, "the game did not say what fields this struct has")
    t.eq(values.misses, misses, "the struct that is not there was looked for once")
    with_check(true, function() old:Set("Spot", { X = 7, Y = 8, Z = 9 }) end)
    t.eq(rawget(old_actor, "__props").Spot.X, 7, "with the check on too, what cannot be checked goes as before")
    convert.flush()
end)

t.test("an Instance inside a struct goes in as its engine object, through a call and through a property", function()
    reset()
    local actor, store = thing(board_class, "Board")
    local board = instance.wrap(actor)
    local holder_actor = character(wolf_class)
    local holder = instance.wrap(holder_actor)
    board:Pin({ Title = "Camp", Holder = holder, Spot = { X = 1, Y = 2, Z = 3 } }, { X = 0, Y = 0, Z = 0 })
    t.ok(rawequal(received.Note.Holder, holder_actor))
    t.eq(values.plain(received.Note).Title, "Camp")
    t.eq(received.Note.Spot.Z, 3)
    board.Note = { Label = "north", Holder = holder }
    t.eq(store.Note.Label, "north")
    t.ok(rawequal(store.Note.Holder, holder_actor))
    t.eq(values.crashes + values.dropped + values.silent, 0)
end)

t.test("an error from a read, a write or a call names the mod's line", function()
    local actor = character(wolf_class)
    local wolf = instance.wrap(actor)
    local backpack = instance.wrap(values.part(inventory_class, "BackpackInventory", {}))
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        backpack:CanAdd({ ItemStaticData = { RowNam = "Wood" } }, 0)
    end, "Inventory:CanAdd argument 1 (Item).ItemStaticData: ItemsStaticRowHandle has no field named 'RowNam'. Did you mean 'RowName'?")
    at(err, line, "a struct in a call")
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        backpack:Call("CanAdd", {}, "many")
    end, "Inventory:CanAdd argument 2 (Count) expects a whole number, got string")
    at(err, line, "a plain argument through Call")
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        wolf.AIRelationshipTableRowNew = { RowName = 5, DataTableName = "x" }
    end, "BP_Wolf_C.AIRelationshipTableRowNew.RowName expects a name (a string), got number")
    at(err, line, "a struct in a property")
    world.destroy(actor)
    world.free(actor)
    for what, read in pairs({
        ["a property"] = function() return wolf.CurrentLevel end, ["Get"] = function() return wolf:Get("CurrentLevel") end,
        ["Name"] = function() return wolf.Name end, ["Raw"] = function() return wolf.Raw end,
        ["a function"] = function() return wolf:K2_SetActorLocation({}, false, {}, true) end,
    }) do
        err = t.raises(function()
            line = debug.getinfo(1, "l").currentline + 1
            local value = read()
            return value
        end, "this BP_Wolf_C no longer exists")
        t.ok(tostring(err):find("easy_test.lua:%d+: this BP_Wolf_C no longer exists"), what .. " of something gone: " .. tostring(err))
    end
    t.eq(world.dead_touches, 0)
end)

-- ------------------------------------------------------------------------------------------ the place for handles

local function handle_module()
    local module = { taken = 0, asked = 0, dead = {} }
    function module.take(object)
        module.taken = module.taken + 1
        return { id = module.taken, address = object:GetAddress() }
    end
    function module.alive(handle)
        module.asked = module.asked + 1
        return not module.dead[handle.id]
    end
    return module
end

t.test("without a handle module an object that was freed is asked, and that is what the game dies of", function()
    local actor = thing(actor_class, "Lamp")
    local lamp = instance.wrap(actor)
    frame()
    world.free(actor)
    t.eq(pcall(function() return lamp.Name end), false)
    t.eq(world.dead_touches, 1)
    world.dead_touches = 0
end)

t.test("with a handle module an object that is gone is never asked again", function()
    local module = handle_module()
    instance.use_handles(module)
    local actor = thing(actor_class, "Lamp")
    local lamp = instance.wrap(actor)
    t.eq(module.taken, 1)
    t.ok(lamp.Name:find("^Lamp_"))
    frame()
    module.dead[1] = true
    world.free(actor)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        local name = lamp.Name
        return name
    end, "this Actor no longer exists")
    at(err, line)
    t.eq(lamp:IsValid(), false)
    t.eq(tostring(lamp), "Actor (destroyed)")
    t.raises(function() lamp:AddTag("lit") end, "no longer exists")
    t.eq(world.dead_touches, 0)
    instance.use_handles(nil)
end)

t.test("a new object at the address of one that is gone, under its name, gets an Instance of its own", function()
    local module = handle_module()
    instance.use_handles(module)
    local first = values.actor(actor_class, "Lamp_Same", { Location = { 0, 0, 0 } })
    local held = instance.wrap(first)
    held:SetAttribute("Lit", true)
    frame()
    module.dead[1] = true
    world.free(first)
    local second = values.actor(actor_class, "Lamp_Same", { Location = { 0, 0, 0 } })
    rawset(second, "__address", rawget(first, "__address"))
    local fresh = instance.wrap(second)
    t.ok(not rawequal(fresh, held))
    t.eq(fresh.Name, "Lamp_Same")
    t.eq(fresh:GetAttribute("Lit"), nil, "what was kept for the old object did not pass to the new one")
    t.eq(held:IsValid(), false)
    t.ok(rawequal(instance.wrap(second), fresh))
    t.eq(world.dead_touches, 0)
    instance.use_handles(nil)
end)

t.test("a handle is asked once a frame for an Instance, and an object without one goes by the old checks", function()
    local module = handle_module()
    module.take = function() return nil end
    instance.use_handles(module)
    local plain_actor = thing(actor_class, "Rock")
    local plain = instance.wrap(plain_actor)
    frame()
    t.ok(plain.Name:find("^Rock_"))
    t.eq(module.asked, 0, "nothing was taken for it, so nothing is asked")
    local counted = handle_module()
    instance.use_handles(counted)
    local actor = thing(actor_class, "Lamp")
    local lamp = instance.wrap(actor)
    for _ = 1, 5 do t.ok(lamp.Name) end
    t.eq(counted.asked, 0, "it was handed over this frame")
    frame()
    for _ = 1, 5 do
        t.ok(lamp.Name)
        t.ok(rawequal(instance.wrap(actor), lamp))
    end
    t.eq(counted.asked, 1)
    frame()
    t.ok(rawequal(instance.wrap(actor), lamp))
    t.ok(lamp.Name)
    t.eq(counted.asked, 2)
    instance.use_handles(nil)
end)

t.test("a handle module that raises is taken out, and Instances go on as before", function()
    local newest = log.newest_id()
    instance.use_handles({ take = function() return {} end, alive = function() error("the handle module broke") end })
    local actor = thing(actor_class, "Lamp")
    local lamp = instance.wrap(actor)
    frame()
    t.ok(lamp.Name:find("^Lamp_"))
    frame()
    t.ok(lamp.Name)
    t.eq(#log.since(newest, { channel = "wax.instance", level = "error" }), 1)
    instance.use_handles({ take = function() error("no handle") end, alive = function() return true end })
    t.ok(instance.wrap(thing(actor_class, "Lamp")).Name)
    t.eq(#log.since(newest, { channel = "wax.instance", level = "error" }), 2)
    t.raises(function() instance.use_handles({}) end, "expects a table with take(object) and alive(handle)")
    t.raises(function() instance.use_handles("handles") end, "expects a table with take(object) and alive(handle)")
    instance.use_handles(nil)
end)

-- ------------------------------------------------------------------------------------------------- game.IsHost

t.test("game.IsHost is true with the authority game mode, and false for a client and with no world", function()
    world.possess(nil)
    local viewport = world.engine.GameViewport
    local level = rawget(viewport, "__props").World
    t.eq(game.IsHost, false, "a client has no game mode")
    t.eq(game.GameMode, nil)
    rawget(level, "__props").AuthorityGameMode = world.component(mode_class, "BP_IcarusGameMode_C_0", {})
    t.eq(game.IsHost, true)
    t.ok(game.GameMode ~= nil)
    rawget(viewport, "__props").World = nil
    t.eq(game.IsHost, false, "no world")
    rawget(viewport, "__props").World = level
    t.eq(game:GetService("IsHost"), true)
    local err = t.raises(function() return game.IsHots end, "IsHots is not a member of game")
    t.ok(tostring(err):find("'IsHost'", 1, true), tostring(err))
    t.raises(function() game.IsHost = true end, "game is read-only")
end)

-- ----------------------------------------------------------------------------------------------------- the rest

t.test("after a map change the classes are looked at again", function()
    local undo = easy.class("IcarusCharacter", { fields = { Health = health } })
    local actor = character(wolf_class)
    local wolf = instance.wrap(actor)
    t.eq(wolf.Health, 100)
    local before = reflect.class_info(wolf_class)
    instance.flush()
    t.raises(function() return wolf.Health end, "from before the last map change")
    local again = instance.wrap(actor)
    t.ok(not rawequal(again, wolf))
    t.eq(again.Health, 100)
    t.ok(not rawequal(reflect.class_info(wolf_class), before), "the class was read again")
    t.ok(easy.merged[reflect.class_info(wolf_class)].fields.Health)
    undo()
end)

t.test("a fault inside engine.easy is one line in the log, and the game's own members go on working", function()
    local undo = easy.class("IcarusCharacter", { fields = { Health = health } })
    local wolf = instance.wrap(character(wolf_class))
    local real, newest = easy.merge, log.newest_id()
    easy.merge = function() error("merge is broken") end
    local ok, problem = pcall(function()
        t.eq(wolf.CurrentLevel, 5)
        t.eq(wolf.CurrentLevel, 5)
        t.raises(function() return wolf.Health end, "Health is not a member of BP_Wolf_C")
        wolf.CurrentLevel = 6
        t.eq(wolf:Get("CurrentLevel"), 6)
        t.eq(#log.since(newest, { channel = "wax.instance", level = "error" }), 1)
    end)
    easy.merge = real
    undo()
    if not ok then error(problem, 0) end
    t.raises(function() return wolf.Health end, "Health is not a member of BP_Wolf_C")
end)

t.test("Instances work without engine.easy and engine.convert when neither can be loaded", function()
    local lone = t.new_wax()
    local import = lone.import
    lone.import = function(name)
        if name == "engine.easy" or name == "engine.convert" then
            error("wax module '" .. name .. "' failed while loading:\nit is broken", 0)
        end
        return import(name)
    end
    local lone_instance = lone.import("engine.instance")
    lone_instance.start()
    local warnings = lone.import("core.log").since(0, { channel = "wax.instance", level = "warn" })
    t.eq(#warnings, 2)
    t.ok(warnings[1].message:find("engine.easy did not load", 1, true), warnings[1].message)
    local actor, store = character(wolf_class)
    local wolf = lone_instance.wrap(actor)
    t.eq(wolf.CurrentLevel, 5)
    wolf.CurrentLevel = 6
    t.eq(store.CurrentLevel, 6)
    t.ok(wolf.Name:find("^BP_Wolf_C_"))
    local err = t.raises(function() return wolf.CurrentLevl end, "CurrentLevl is not a member of BP_Wolf_C")
    t.ok(tostring(err):find("'CurrentLevel'", 1, true), tostring(err))
    t.raises(function() return wolf:Get("Health") end, "Health is not a property")
    t.ok(#wolf:GetMembers() > 2)
    t.eq(wolf:K2_SetActorLocation({ X = 1, Y = 2, Z = 3 }, false, {}, true), true)
    t.raises(function() wolf:Set("AIRelationshipTableRowNew", { RowName = "FriendlyAll" }) end, "the game did not say what fields this struct has")
end)

t.test("nothing here asked the engine for what it does not offer, touched a freed object or left an error behind", function()
    reset()
    t.eq(misused, 0, table.concat(values.log, " | "))
    t.eq(world.dead_touches, 0)
    t.eq(#guard.errors(), 0)
    t.eq(easy.stats().registrations, 0, "every test took back what it registered")
end)

t.finish("easy")
