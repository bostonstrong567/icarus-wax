-- Offline tests for world.creature (what Wax adds to a creature) and for game.Creatures:GetInfo and GetTamed.
-- The engine is a stand-in: an object that was freed raises on any use, what a table hands out raises in the next frame,
-- and a name asked of a table that lacks it, a map that is read and a lookup that misses are counted.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\creature_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local zoo = dofile("wax/tests/offline/fake_creatures.lua").install()
local wording = dofile("wax/tests/offline/wording.lua")
local world, values, tables, kit = zoo.world, zoo.values, zoo.tables, zoo.kit

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)

local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local sched = Wax.import("core.sched")
local log = Wax.import("core.log")
local perf = Wax.import("core.perf")
local easy = Wax.import("engine.easy")
local instance = Wax.import("engine.instance")
local game_module = Wax.import("engine.game")
world.possess(nil)
game_module.start()
Wax.game = game_module.root
Wax.import("engine.actors").start()
local track = Wax.import("engine.track")
track.start()
Wax.import("world.creatures").start()
local data = Wax.import("data.tables")
local game = game_module.root
local Creatures = game.Creatures

-- Frames of 16 ms on a clock the tests own. In each, what the tables handed out before must not be used again.
local now, FRAME = 1000, 0.016
sched.clock = function() return now end
data.clock = function() return now end
data.start()
local Data = game.Data
local function frames(count)
    for _ = 1, count or 1 do
        now = now + FRAME
        tables.next_frame()
        game_module.step()
        track.step()
        sched.step()
    end
end
local function pass(seconds) frames(math.ceil(seconds / FRAME) + 2) end

Wax.import("world.character").start()

local warnings, said = {}, {}
log.add_sink(function(entry, repeated)
    if not repeated and entry.level == "warn" and (entry.channel == "wax.creature" or entry.channel == "wax.easy") then
        warnings[#warnings + 1] = entry.message
    end
end)

local before = { world = world.touches, finds = values.finds, tables = tables.touches }
local creature = Wax.import("world.creature")
creature.start()
local misses = values.misses

-- A creature with its Instance.
local function animal(variant, over)
    local who = zoo.make(variant, over)
    who.instance = instance.wrap(who.actor)
    return who
end

-- Runs fn, which must raise with `fragment`, and checks that the error names the line of the call inside fn.
local function raises_here(fn, fragment, what)
    local err = t.raises(fn, fragment, what)
    local line = debug.getinfo(fn, "S").linedefined
    local named = tonumber(tostring(err):match("creature_test%.lua:(%d+):"))
    t.ok(named and named >= line and named <= debug.getinfo(fn, "S").lastlinedefined,
        (what or "the error") .. " should name the mod's line: " .. tostring(err))
    said[#said + 1] = (tostring(err):gsub("^.-%.lua:%d+: ", ""))
    return err
end

local function is_plain(value)
    local kind = type(value)
    if kind == "table" then
        if getmetatable(value) then return false end
        for key, item in pairs(value) do
            if not (is_plain(key) and is_plain(item)) then return false end
        end
        return true
    end
    return kind == "string" or kind == "number" or kind == "boolean"
end

local function list(values_of) return table.concat(values_of, ",") end

-- ------------------------------------------------------------------------------------------------------ starting

t.test("starting asks the engine nothing and puts nothing on the frame", function()
    t.eq(world.touches, before.world, "no engine object was touched")
    t.eq(values.finds, before.finds, "nothing was looked up by path")
    t.eq(tables.touches, before.tables, "no table was touched")
    t.eq(sched.Frame.count, 0)
    t.eq(creature.UNPROVEN, false, "the switch is off as it ships")
    t.eq(creature.stats().linked, false)
end)

local deer = animal("Deer", { at = { 1000, 0, 0 } })

t.test("a field read does not start the list of creatures: kind and variant come from the creature's own row", function()
    world.watch = {}
    t.eq(deer.instance.Kind, "MediumDeer")
    t.eq(deer.instance.Variant, "Deer")
    t.eq(deer.instance.DisplayName, "Deer")
    t.eq(world.watch.AISetup, 3, "its own row was read for each")
    world.watch = nil
    t.eq(track.stats().sets.creatures.tracking, false)
    t.eq(track.stats().hooks.listening, false)
    t.eq(creature.stats().linked, false, "and no table of taming rules was asked for")
end)

t.test("the tables are first asked for inside a mod, and what links to them stays when that mod unloads", function()
    local changed, moved = Data.Changed.count, game.MapChanged.count
    local mod = scope.new("mod")
    local info = scope.run(mod, function() return Creatures:GetInfo("Deer") end)
    t.eq(info.Team, "DefaultMediumHerbivore")
    t.eq(creature.stats().linked, true)
    t.eq(Data.Changed.count, changed + 1)
    t.eq(game.MapChanged.count, moved + 1)
    mod:destroy()
    t.eq(Data.Changed.count, changed + 1, "the link to game.Data belongs to no mod")
    t.eq(game.MapChanged.count, moved + 1)
end)

-- ------------------------------------------------------------------------------------------------------- fields

t.test("a wild animal says what it is, whose side it is on, what it is doing and how it holds itself", function()
    local me = deer.instance
    t.eq(me.Kind, "MediumDeer")
    t.eq(me.Variant, "Deer")
    t.eq(me.DisplayName, "Deer")
    t.eq(me.Epic, nil)
    t.eq(me.Behaviour, "Default")
    t.eq(me.Action, "Wander")
    t.eq(me.Target, nil)
    t.eq(me.Stance, "Standing")
    t.eq(me.IsJuvenile, false)
    t.eq(me.IsTamed, false)
    t.eq(me.CanBeTamed, false)
end)

t.test("a named boss has the row that makes it one", function()
    local boss = animal("Alpha_Wolf_Boss").instance
    t.eq(boss.Kind, "Alpha_Wolf")
    t.eq(boss.Variant, "Alpha_Wolf_Boss")
    t.eq(boss.DisplayName, "Black Wolf")
    t.eq(boss.Epic, "AlphaWolf_Boss")
    t.eq(boss.Action, "EmergeFromRetreat")
    t.eq(boss.Behaviour, "Default")
    t.eq(boss.CanBeTamed, false)
end)

t.test("behaviour is a word for four teams, Default for the team the variant starts on, else the team's own name", function()
    local me = deer.instance
    zoo.team(deer, "FriendlyAll")
    t.eq(me.Behaviour, "Friendly")
    zoo.team(deer, "friendlyall")
    t.eq(me.Behaviour, "Friendly", "the engine does not spell a name one way")
    zoo.team(deer, "Player")
    t.eq(me.Behaviour, "Tame")
    zoo.team(deer, "EnemyPlayerOnly")
    t.eq(me.Behaviour, "HostileToPlayers")
    zoo.team(deer, "EnemyAll")
    t.eq(me.Behaviour, "HostileToAll")
    zoo.team(deer, "DefaultLargeCarnivore")
    t.eq(me.Behaviour, "DefaultLargeCarnivore")
    zoo.team(deer, "None")
    t.eq(me.Behaviour, nil)
    zoo.team(deer, "defaultmediumherbivore")
    t.eq(me.Behaviour, "Default")
    zoo.team(deer, "DefaultMediumHerbivore")
    t.eq(animal("Mount_Buffalo").instance.Behaviour, "Tame", "a tamed animal starts on the players' team")
end)

t.test("action is read from the controller each time, and is nil where the game names none", function()
    local me = deer.instance
    zoo.act(deer, "FindFood")
    t.eq(me.Action, "FindFood")
    zoo.act(deer, nil)
    t.eq(me.Action, nil, "doing nothing")
    zoo.act(deer, "")
    t.eq(me.Action, nil, "an action of the bare class has no name")
    zoo.act(deer, "Wander")
    local controller = deer.store.Controller
    deer.store.Controller = world.INVALID
    t.eq(me.Action, nil, "no controller")
    deer.store.Controller = controller
    t.eq(me.Action, "Wander")
    local mount = animal("Mount_Buffalo")
    world.watch = {}
    t.eq(mount.instance.Action, nil)
    t.eq(world.watch.CurrentAction, nil, "a controller that has no such member is not asked for it")
    world.watch = nil
end)

local hero = kit.player({ at = { 0, 0, 0 } })
hero.instance = instance.wrap(hero.actor)

t.test("target is the Instance of what it is after, and nothing once that is being destroyed", function()
    local me = deer.instance
    zoo.aim(deer, hero.actor)
    t.ok(rawequal(me.Target, hero.instance), "the player's character, as the Instance everyone has for it")
    local prey = animal("Deer")
    zoo.aim(deer, prey.actor)
    t.ok(rawequal(me.Target, prey.instance))
    t.eq(me.Target.Kind, "MediumDeer")
    world.destroy(prey.actor)
    t.eq(me.Target, nil, "ended play and waiting to be collected")
    zoo.aim(deer, nil)
    world.destroy(prey.controller)
    world.free(prey.actor)
    world.free(prey.controller)
    t.eq(me.Target, nil)
    t.eq(world.dead_touches, 0)
end)

t.test("stance is a word, and nil for a number Wax has no word for", function()
    local me = deer.instance
    deer.store.CurrentStance = 1
    t.eq(me.Stance, "Sitting")
    deer.store.CurrentStance = 2
    t.eq(me.Stance, "Lying")
    deer.store.CurrentStance = 7
    t.eq(me.Stance, nil)
    deer.store.CurrentStance = 0
    t.eq(me.Stance, "Standing")
end)

t.test("young, tamed and able to be tamed, by the game's taming rules and its classes", function()
    local function facts(variant)
        local me = animal(variant).instance
        return ("%s %s %s"):format(tostring(me.IsJuvenile), tostring(me.IsTamed), tostring(me.CanBeTamed))
    end
    t.eq(facts("Juvenile_Buffalo"), "true false true")
    t.eq(facts("Buffalo"), "false false true", "a rule names it as the grown animal")
    t.eq(facts("Mount_Buffalo"), "false true false")
    t.eq(facts("Tamed_Forest_Wolf"), "false true false")
    t.eq(facts("Cow"), "false true false", "livestock: tamed already, though a rule names it as the grown animal")
    t.eq(facts("Chick"), "true false true", "three rules name the chick")
    t.eq(facts("Deer"), "false false false")
    t.eq(facts("Alpha_Wolf_Boss"), "false false false")
    t.eq(animal("Juvenile_Buffalo").instance.Variant, "Juvenile_Buffalo", "spelled as the table spells it, not as its own row does")
end)

t.test("a creature the game's data says nothing about is Unknown, and what needs its variant is nil", function()
    local stray = animal("Nameless").instance
    t.eq(stray.Kind, "Unknown")
    t.eq(stray.Variant, nil)
    t.eq(stray.DisplayName, "Unknown")
    t.eq(stray.IsJuvenile, nil)
    t.eq(stray.CanBeTamed, nil)
    t.eq(stray.IsTamed, false)
    t.eq(stray.Behaviour, "DefaultSmallHerbivore", "no variant to say what its own team is")
    t.eq(stray.Action, "Wander")
    local named = animal("Deer", { row = "Mystery_Beast" }).instance
    t.eq(named.Kind, "Mystery_Beast", "a row the tables lack is given as it is")
    t.eq(named.Variant, "Mystery_Beast")
    t.eq(named.IsJuvenile, false)
    t.eq(named.Behaviour, "DefaultMediumHerbivore")
    local by_class = animal("Deer", { row = "None" }).instance
    t.eq(by_class.Kind, "MediumDeer", "an empty row: the class says what it is")
    t.eq(by_class.Variant, "Deer")
    t.eq(tables.unknown_names, 0, "the engine was never asked for a row it does not have")
end)

t.test("a class that lacks a member reads nil, and the engine is never asked for that member", function()
    local wolf = kit.creature()
    local me = instance.wrap(wolf.actor)
    world.watch = {}
    t.eq(me.Kind, "Wolf")
    t.eq(me.Variant, "Conifer_Wolf")
    t.eq(me.Epic, nil)
    t.eq(me.Stance, nil)
    t.eq(me.Target, nil)
    t.eq(me.Action, nil, "no controller")
    t.eq(me.Behaviour, nil, "the game hands back nothing readable for its team")
    t.eq(world.watch.EpicCreature, nil)
    t.eq(world.watch.CurrentStance, nil)
    world.watch = nil
    t.eq(me.IsJuvenile, false)
    t.eq(me.CanBeTamed, true)
    wolf.store.AIRelationshipTableRowNew = zoo.handle("NeutralMediumCarnivore", "D_AIRelationships")
    t.eq(me.Behaviour, "Default")
end)

t.test("a creature that is an IcarusPawn is asked nothing of its own unless the switch is on", function()
    local worm = animal("SandWorm")
    local me = worm.instance
    world.watch = {}
    t.eq(me.Kind, "SandWorm")
    t.eq(me.Variant, "SandWorm")
    t.eq(me.DisplayName, "Sandworm")
    t.eq(me.Epic, nil)
    t.eq(me.Behaviour, nil)
    t.eq(me.Action, nil)
    t.eq(me.Target, nil)
    t.eq(me.Stance, nil)
    t.eq(me.IsTamed, false)
    t.eq(me.IsJuvenile, false)
    t.eq(me.CanBeTamed, false)
    t.eq(world.watch.EpicCreature, nil)
    t.eq(world.watch.AIRelationshipTableRowNew, nil)
    t.eq(world.watch.Controller, nil)
    world.watch = nil
    local cave = instance.wrap(kit.worm().actor)
    t.eq(cave.Kind, "CaveWorm")
    t.eq(cave.DisplayName, "Cave Worm")

    creature.UNPROVEN = true
    creature.flush()
    t.eq(me.Epic, "Sandworm_Boss")
    t.eq(me.Behaviour, "Default")
    t.eq(me.Action, nil, "its controller has no action to name")
    t.eq(me.Target, nil)
    t.eq(me.Stance, nil)
    creature.UNPROVEN = false
    creature.flush()
    t.eq(me.Epic, nil)
end)

t.test("a creature keeps the fields every character has, and a player's character has none of a creature's", function()
    local me = deer.instance
    t.eq(me.Health, 155)
    t.eq(me.MaxHealth, 155)
    t.eq(me.Level, 6)
    t.eq(me.Alive, true)
    t.eq(me.MoveSpeed, 220)
    t.eq(me:DistanceTo(hero.instance), 10)
    t.eq(hero.instance.Health, 300)
    for _, name in ipairs({ "Kind", "Variant", "Epic", "Behaviour", "IsTamed" }) do
        t.raises(function() return hero.instance[name] end, name .. " is not a member of")
    end
end)

t.test("a wrong name suggests the right one, a field cannot be assigned, and the fields are listed", function()
    local me = deer.instance
    local err = raises_here(function()
        return me.Varient
    end, "Varient is not a member of BP_NPC_Deer_Character_C")
    t.ok(tostring(err):find("Variant", 1, true), "suggests Variant: " .. tostring(err))
    raises_here(function()
        me.Kind = "Wolf"
    end, "Kind is read-only")
    local listed = {}
    for _, name in ipairs(me:GetMembers()) do listed[name] = true end
    for name in pairs(creature.fields) do t.ok(listed[name], name .. " is among the members") end
    t.ok(listed.Health and listed.AISetup, "beside the character's fields and the game's own members")
end)

t.test("a field can be watched for a change", function()
    local seen = {}
    local signal = deer.instance:GetPropertyChangedSignal("Stance")
    local connection = signal:Connect(function(value, previous) seen[#seen + 1] = tostring(value) .. " after " .. tostring(previous) end)
    pass(0.3)
    t.eq(#seen, 0)
    deer.store.CurrentStance = 1
    pass(0.3)
    t.eq(list(seen), "Sitting after Standing")
    connection:Disconnect()
    deer.store.CurrentStance = 0
    pass(0.3)
    t.eq(#seen, 1)
    t.eq(sched.Frame.count, 0, "nothing is left on the frame signal")
end)

t.test("once the list of creatures is kept, kind and variant come from it and the creature is not asked", function()
    t.ok(Creatures:Count() > 10)
    t.eq(track.stats().sets.creatures.tracking, true)
    world.watch = {}
    t.eq(deer.instance.Kind, "MediumDeer")
    t.eq(deer.instance.Variant, "Deer")
    t.eq(deer.instance.DisplayName, "Deer")
    t.eq(world.watch.AISetup, nil)
    world.watch = nil
    local late = animal("Buffalo")
    t.eq(Creatures:GetKind(late.instance), nil, "not in the list until the next frame")
    t.eq(late.instance.Kind, "Buffalo", "so it is asked itself")
    frames(1)
    t.eq((Creatures:GetKind(late.instance)), "Buffalo")
    t.eq(late.instance.Variant, "Buffalo")
end)

t.test("a creature that ended play raises at the mod's line, and its freed object is never touched", function()
    local doomed = animal("Deer")
    frames(1)
    t.eq(doomed.instance.Behaviour, "Default")
    zoo.remove(doomed)
    raises_here(function()
        return doomed.instance.Kind
    end, "no longer exists")
    raises_here(function()
        return doomed.instance.IsTamed
    end, "no longer exists")
    raises_here(function()
        return doomed.instance.Action
    end, "no longer exists")
    raises_here(function()
        Creatures:GetInfo(doomed.instance)
    end, "GetInfo was given a creature that no longer exists")
    frames(2)
    t.eq(world.dead_touches, 0)
end)

-- ------------------------------------------------------------------------------------------------------ GetInfo

t.test("GetInfo gives a variant's team, diet, carcass and loot, its taming rule and what it is like tamed", function()
    local info = Creatures:GetInfo("Buffalo")
    t.eq(info.Kind, "Buffalo")
    t.eq(info.Variant, "Buffalo", "the variant named like the kind, though the table lists another first")
    t.eq(info.DisplayName, "Buffalo")
    t.eq(info.Tag, "NPC.Buffalo")
    t.eq(list(info.Variants), "Mount_Buffalo,Buffalo")
    t.eq(info.Team, "NeutralMediumHerbivore")
    t.eq(info.Diet, "Herbivore")
    t.eq(list(info.Descriptors), "Neutral,Herbivore")
    t.eq(info.Carcass, "AnimalCarcass_Buffalo")
    t.eq(info.Loot, "Buffalo_Carcass_Loot")
    local tame = info.Tame
    t.eq(tame.Rule, "Buffalo")
    t.eq(tame.As, "Grown")
    t.eq(tame.Seconds, 900)
    t.eq(tame.Nutrition, 25)
    t.eq(tame.Shelter, 0)
    t.eq(tame.Temperature.Min, 15)
    t.eq(tame.Temperature.Max, 45)
    t.eq(tame.Tamed, "Mount_Buffalo")
    t.eq(tame.Young, "Juvenile_Buffalo")
    t.eq(tame.Grown, "Buffalo", "as the table of variants spells it")
    t.eq(#tame.Required, 0)
    t.eq(list(tame.Prohibited), "Wet,Sleepy")
    local mount = info.Mount
    t.eq(mount.Name, "Buffalo")
    t.eq(mount.Variant, "Mount_Buffalo", "about the variant it becomes")
    t.eq(list(mount.Orders), "Follow,Wander,Stay,Rest")
    t.eq(list(mount.Combat), "Passive,Defensive,Aggressive")
    t.eq(mount.Growth, "AI_Mounts")
    t.eq(#mount.Saddles, 3)
    t.eq(mount.Saddles[1].Name, "Saddle_Buffalo_Standard")
    t.eq(mount.Saddles[1].Tag, "Item.Mount.Saddle.Standard")
    t.eq(mount.Saddles[2].Name, "Saddle_Buffalo_Cargo", "its mount is spelled another way in that row")
    t.eq(mount.Saddles[3].Name, "Saddle_Buffalo_Cart", "a saddle that fits two animals")

    local young = Creatures:GetInfo("Juvenile_Buffalo")
    t.eq(young.Kind, "Juvenile_Buffalo")
    t.eq(young.Tame.As, "Young")
    t.eq(young.Tame.Rule, "Buffalo")
    t.eq(young.Mount.Variant, "Mount_Buffalo")
    local tamed = Creatures:GetInfo("Mount_Buffalo")
    t.eq(tamed.Kind, "Buffalo")
    t.eq(tamed.Variant, "Mount_Buffalo")
    t.eq(tamed.Team, "Player")
    t.eq(tamed.Diet, nil)
    t.eq(#tamed.Descriptors, 0)
    t.eq(tamed.Tame.As, "Tamed")
    t.eq(tamed.Mount.Variant, "Mount_Buffalo")
    t.eq(#tamed.Mount.Saddles, 3)
end)

t.test("GetInfo takes a kind, the name the game shows, any spelling, and a creature", function()
    local wolf = Creatures:GetInfo("Wolf")
    t.eq(wolf.Variant, "Conifer_Wolf", "no variant is named like the kind, so its first")
    t.eq(list(wolf.Variants), "Conifer_Wolf,Juvenile_Forest_Wolf,Tamed_Forest_Wolf")
    t.eq(wolf.Diet, "Carnivore")
    t.eq(wolf.Tame.Rule, "Forest_Wolf")
    t.eq(wolf.Tame.As, "Grown")
    t.eq(wolf.Tame.Seconds, 600)
    t.eq(#wolf.Tame.Prohibited, 0)
    t.eq(wolf.Mount.Name, "Wolf")
    t.eq(wolf.Mount.Variant, "Tamed_Forest_Wolf")
    t.eq(list(wolf.Mount.Orders), "Follow,Wander")
    t.eq(wolf.Mount.Growth, "AI_Pets")
    t.eq(#wolf.Mount.Saddles, 0, "no saddle fits a pet")
    t.eq(Creatures:GetInfo("Juvenile_Forest_Wolf").Tame.As, "Young")
    t.eq(Creatures:GetInfo("Cave Worm").Variant, "CaveWorm")
    t.eq(Creatures:GetInfo("juvenile buffalo").Variant, "Juvenile_Buffalo")
    t.eq(Creatures:GetInfo("MOUNT_BUFFALO").Variant, "Mount_Buffalo")
    local mount = animal("Mount_Buffalo")
    local from_creature = Creatures:GetInfo(mount.instance)
    t.eq(from_creature.Variant, "Mount_Buffalo")
    t.eq(from_creature.Tame.As, "Tamed")
    t.eq(Creatures:GetInfo(deer.instance).Variant, "Deer")
    t.eq(Creatures:GetInfo(mount.instance.Variant).Mount.Name, "Buffalo")
end)

t.test("GetInfo says nothing where the tables say nothing, and never names a variant the game does not have", function()
    local plain = Creatures:GetInfo("Deer")
    t.eq(plain.Kind, "MediumDeer")
    t.eq(plain.Tame, nil)
    t.eq(plain.Mount, nil)
    t.eq(plain.Carcass, "AnimalCarcass_Deer")
    local worm = Creatures:GetInfo("CaveWorm")
    t.eq(worm.Carcass, nil, "its row names no carcass")
    t.eq(worm.Diet, nil)
    t.eq(list(worm.Descriptors), "Aggressive")
    local bear = Creatures:GetInfo("Bear")
    t.eq(bear.Kind, "Bear")
    t.eq(bear.Variant, nil, "a kind without a variant")
    t.eq(#bear.Variants, 0)
    t.eq(bear.Team, nil)
    t.eq(bear.Tame, nil)
    local cow = Creatures:GetInfo("Cow")
    t.eq(cow.Tame.Rule, "Calf")
    t.eq(cow.Tame.As, "Grown")
    t.eq(cow.Tame.Young, "Calf")
    t.eq(cow.Mount.Name, "Cow")
    t.eq(list(cow.Mount.Combat), "Passive")
    t.eq(Creatures:GetInfo("Chick").Tame.Rule, "Chick", "the first of the rules that name it")
    t.eq(Creatures:GetInfo("Chicken").Mount, nil)
    local dog = Creatures:GetInfo("Tame_Dog_A1")
    t.eq(dog.Tame.As, "Tamed")
    t.eq(dog.Tame.Young, nil)
    t.eq(dog.Tame.Grown, nil)
    local blueback = Creatures:GetInfo("BlueBack")
    t.eq(blueback.Tame.Rule, "Blueback")
    t.eq(blueback.Tame.Grown, "BlueBack")
    t.eq(blueback.Tame.Tamed, nil, "the game's rule names a variant the game does not have")
    t.eq(blueback.Tame.Young, nil)
    t.eq(blueback.Mount, nil)
    t.eq(tables.unknown_names, 0, "and the engine was not asked for it")
end)

t.test("what GetInfo gives is plain and new each time", function()
    local first = Creatures:GetInfo("Buffalo")
    t.ok(is_plain(first), "plain values all the way down")
    first.Team, first.Tame.Seconds, first.Variants[1], first.Descriptors[1] = "x", 1, "x", "x"
    first.Tame.Prohibited[1], first.Tame.Temperature.Min, first.Mount.Orders[1], first.Mount.Saddles[1].Tag = "x", -1, "x", "x"
    local second = Creatures:GetInfo("Buffalo")
    t.eq(second.Team, "NeutralMediumHerbivore")
    t.eq(second.Tame.Seconds, 900)
    t.eq(second.Variants[1], "Mount_Buffalo")
    t.eq(second.Descriptors[1], "Neutral")
    t.eq(second.Tame.Prohibited[1], "Wet")
    t.eq(second.Tame.Temperature.Min, 15)
    t.eq(second.Mount.Orders[1], "Follow")
    t.eq(second.Mount.Saddles[1].Tag, "Item.Mount.Saddle.Standard")
    t.eq(list(Creatures:GetKinds()[1].Variants), list(Creatures:GetInfo(Creatures:GetKinds()[1].Name).Variants))
end)

t.test("GetInfo refuses what is no kind, with the nearest name and at the mod's line", function()
    local err = raises_here(function()
        Creatures:GetInfo("Wolff")
    end, "'Wolff' is not a creature kind")
    t.ok(tostring(err):find("'Wolf'", 1, true), "suggests Wolf: " .. tostring(err))
    raises_here(function()
        Creatures:GetInfo()
    end, "GetInfo expects a kind such as \"Wolf\", a variant such as \"Conifer_Wolf\" or a creature")
    raises_here(function()
        Creatures:GetInfo(12)
    end, "a creature kind is a name")
    raises_here(function()
        Creatures:GetInfo("BP_Mount_Buffalo_C")
    end, "and 'BP_Mount_Buffalo_C' is the name of a class")
    raises_here(function()
        Creatures:GetInfo(hero.instance)
    end, "and the game's tables have nothing on this BP_IcarusPlayerCharacterSurvival_C")
    raises_here(function()
        Creatures:GetInfo(animal("Nameless").instance)
    end, "and the game's tables have nothing on this BP_IcarusNPCGOAPCharacter_C")
    local names = {}
    for _, name in ipairs(getmetatable(Creatures).__names()) do names[name] = true end
    t.ok(names.GetInfo and names.GetTamed, "both are among the names of game.Creatures")
end)

t.test("a table is walked once, no row is asked of the engine twice, and nothing of the engine's is kept over a frame", function()
    local calf = animal("Buffalo")
    Creatures:GetInfo("Buffalo")
    Creatures:GetInfo("Wolf")
    local scans, asked, finds = creature.stats().scans, tables.rows_asked, tables.finds
    frames(3)
    for _ = 1, 5 do
        t.eq(Creatures:GetInfo("Buffalo").Mount.Saddles[2].Tag, "Item.Mount.Saddle.Cargo")
        t.eq(Creatures:GetInfo("Wolf").Tame.Seconds, 600)
        t.eq(calf.instance.CanBeTamed, true)
        t.eq(calf.instance.Behaviour, "Default")
        frames(1)
    end
    t.eq(creature.stats().scans, scans)
    t.eq(tables.rows_asked, asked)
    t.eq(tables.finds, finds, "and nothing is looked up by path for a value already read")
    t.eq(tables.stale, 0)
end)

t.test("what is kept is dropped when one of its tables changes, and only then", function()
    Creatures:GetInfo("Buffalo")
    t.eq(creature.stats().rules, true)
    Data.Changed:Fire("ItemsStatic")
    t.eq(creature.stats().rules, true, "another table")
    Data.Changed:Fire("Tames")
    t.eq(creature.stats().rules, nil)
    t.eq(Creatures:GetInfo("Buffalo").Tame.Seconds, 900)

    local changed = {}
    for name, row in pairs(zoo.rows.Tames) do changed[name] = row end
    changed.Buffalo = {}
    for key, value in pairs(zoo.rows.Tames.Buffalo) do changed.Buffalo[key] = value end
    changed.Buffalo.TameDurationInSeconds = 60
    changed.Buffalo.JuvenileCreatureType = { RowName = "Deer", DataTableName = "D_AISetup" }
    tables.set_rows("Tames", changed, zoo.order.Tames)
    tables.move("Tames")
    Data:Flush()
    frames(1)
    t.eq(Creatures:GetInfo("Buffalo").Tame.Seconds, 60)
    t.eq(deer.instance.IsJuvenile, true, "the fields follow the table too")
    t.eq(deer.instance.CanBeTamed, true)
    tables.set_rows("Tames", zoo.rows.Tames, zoo.order.Tames)
    tables.move("Tames")
    Data:Flush()
    frames(1)
    t.eq(Creatures:GetInfo("Buffalo").Tame.Seconds, 900)
    t.eq(deer.instance.IsJuvenile, false)
end)

t.test("a table the game does not have costs one warning, is not asked for again, and the rest goes on", function()
    local buffalo = animal("Buffalo")
    tables.hide("Tames")
    Data:Flush()
    frames(1)
    local warned, lists = #warnings, tables.lists
    t.eq(buffalo.instance.IsJuvenile, nil)
    t.eq(buffalo.instance.CanBeTamed, nil)
    t.eq(buffalo.instance.IsTamed, false)
    t.eq(buffalo.instance.Behaviour, "Default")
    t.eq(#warnings, warned + 1)
    t.ok(warnings[#warnings]:find("the table Tames could not be read", 1, true), warnings[#warnings])
    said[#said + 1] = warnings[#warnings]
    local listed = tables.lists
    t.ok(listed <= lists + 2, "the list of tables was taken again, not once per table")
    for _ = 1, 20 do
        t.eq(buffalo.instance.IsJuvenile, nil)
        t.eq(buffalo.instance.CanBeTamed, nil)
    end
    local info = Creatures:GetInfo("Buffalo")
    t.eq(info.Tame, nil)
    t.eq(info.Mount, nil, "what it becomes is not known without the rule")
    t.eq(info.Team, "NeutralMediumHerbivore")
    t.eq(Creatures:GetInfo("Mount_Buffalo").Mount.Name, "Buffalo")
    t.eq(tables.lists, listed, "not asked for again")
    t.eq(#warnings, warned + 1, "and said once")
    t.eq(creature.stats().rules, false)
    t.eq(list(creature.stats().down), "Tames")
    t.eq(tables.misses, 0, "no lookup by a path the game lacks, which is the slow kind")

    tables.hide("Tames", false)
    Data:Flush()
    frames(1)
    t.eq(buffalo.instance.CanBeTamed, true)
    t.eq(Creatures:GetInfo("Buffalo").Tame.Seconds, 900)
    t.eq(#creature.stats().down, 0)
end)

t.test("a row the engine cannot read is left out, and the others stay", function()
    tables.poison("Tames", "Forest_Wolf", "TamedAI")
    Data:Flush()
    frames(1)
    t.eq(Creatures:GetInfo("Conifer_Wolf").Tame, nil)
    t.eq(Creatures:GetInfo("Conifer_Wolf").Team, "NeutralMediumCarnivore")
    t.eq(Creatures:GetInfo("Buffalo").Tame.Seconds, 900)
    tables.poison("Tames", "Forest_Wolf", nil)
    Data:Flush()
    frames(1)
    t.eq(Creatures:GetInfo("Conifer_Wolf").Tame.Rule, "Forest_Wolf")
end)

-- --------------------------------------------------------------------------------------------- map change, GetTamed

t.test("after a map change an old creature raises, a new one reads, and nothing of the old world is touched", function()
    local old = animal("Deer")
    frames(1)
    t.eq(old.instance.Kind, "MediumDeer")
    world.travel("Terrain_New")
    frames(1)
    raises_here(function()
        return old.instance.Kind
    end, "no longer exists")
    t.eq(creature.stats().rules, nil, "what the tables said is asked again in the new world")
    local fresh = animal("Deer")
    t.eq(fresh.instance.Kind, "MediumDeer")
    t.eq(fresh.instance.Behaviour, "Default")
    t.eq(fresh.instance.Action, "Wander")
    t.eq(fresh.instance.CanBeTamed, false)
    frames(1)
    t.eq(Creatures:Count("Deer"), 1)

    local kept = animal("Buffalo")
    frames(1)
    t.eq(kept.instance.CanBeTamed, true)
    world.travel("Terrain_Next", true)
    frames(1)
    raises_here(function()
        return kept.instance.Variant
    end, "before the last map change")
    raises_here(function()
        return fresh.instance.IsTamed
    end, "before the last map change")
    frames(2)
    t.eq(Creatures:Count(), 0)
    t.eq(world.dead_touches, 0)
end)

t.test("GetTamed gives the tamed animals of the list, narrowed like GetAll", function()
    t.eq(#Creatures:GetTamed(), 0)
    local mount = animal("Mount_Buffalo", { at = { 500, 0, 0 } })
    local cow = animal("Cow", { at = { 3000, 0, 0 } })
    animal("Buffalo", { at = { 100, 0, 0 } })
    animal("Juvenile_Buffalo", { at = { 200, 0, 0 } })
    animal("Deer", { at = { 300, 0, 0 } })
    frames(1)
    t.eq(Creatures:Count(), 5)
    local origin = { X = 0, Y = 0, Z = 0 }
    local tamed = Creatures:GetTamed({ sort = "nearest", from = origin })
    t.eq(#tamed, 2)
    t.ok(rawequal(tamed[1], mount.instance), "nearest first")
    t.ok(rawequal(tamed[2], cow.instance))
    t.eq(#Creatures:GetTamed(), 2)
    t.eq(#Creatures:GetTamed("Buffalo"), 1, "the kind has a wild one and a tamed one")
    t.ok(rawequal(Creatures:GetTamed("Buffalo")[1], mount.instance))
    t.eq(#Creatures:GetTamed("Mount_Buffalo"), 1)
    t.eq(#Creatures:GetTamed("Cow"), 1)
    t.eq(#Creatures:GetTamed("Deer"), 0)
    t.eq(#Creatures:GetTamed({ within = 10, from = origin }), 1)
    t.eq(#Creatures:GetTamed("Cow", { within = 10, from = origin }), 0)
    cow.state_store.CurrentAliveState = 1
    t.eq(#Creatures:GetTamed(), 1, "the dead are left out")
    t.eq(#Creatures:GetTamed({ dead = true }), 2)
    zoo.remove(mount)
    frames(1)
    t.eq(#Creatures:GetTamed({ dead = true }), 1)
    raises_here(function()
        Creatures:GetTamed("Wolff")
    end, "'Wolff' is not a creature kind")
    raises_here(function()
        Creatures:GetTamed({ within = "far", from = origin })
    end, "number of metres")
    t.eq(world.dead_touches, 0)
end)

-- ---------------------------------------------------------------------------------------------------------- the rest

t.test("what a mod author reads is plain", function()
    local unwanted = wording.unwanted()
    if unwanted then t.ok(wording.complete(unwanted), "the owner's list was read whole from " .. wording.SOURCE) end
    local file = assert(io.open("wax/types/creature.lua", "rb"))
    local text = file:read("a")
    file:close()
    local lines = 0
    for line in text:gmatch("[^\r\n]+") do
        if line:sub(1, 3) == "---" then
            lines = lines + 1
            t.eq(wording.wrong_with(line:sub(4), unwanted), nil, "wax/types/creature.lua: " .. line:sub(1, 70))
        end
    end
    t.ok(lines > 40, "the type file was read")
    t.ok(#said > 10, "the messages of this suite were gathered")
    for _, message in ipairs(said) do t.eq(wording.wrong_with(message, unwanted), nil, message) end
    for name in pairs(creature.fields) do
        t.ok(text:find("---@field " .. name .. " ", 1, true), name .. " is described in wax/types/creature.lua")
    end
end)

t.test("what a read costs on the stand-in", function()
    local wild, tame = animal("Buffalo"), animal("Mount_Buffalo")
    frames(1)
    local was = guard.suspend_watchdog(true)
    local function cost(fn, rounds)
        rounds = rounds or 20000
        local started = perf.now()
        for _ = 1, rounds do fn() end
        return (perf.now() - started) / rounds * 1e6
    end
    local me, raw = wild.instance, wild.actor
    local base = cost(function() return me.CurrentLevel end)
    local line = ("a game property %.2f | Kind %.2f | Epic %.2f | Behaviour %.2f | Action %.2f | Stance %.2f | IsJuvenile %.2f | IsTamed %.2f"
        .. " | CanBeTamed %.2f | GetInfo %.1f | GetTamed of 5 %.1f"):format(base,
        cost(function() return me.Kind end), cost(function() return me.Epic end), cost(function() return me.Behaviour end),
        cost(function() return me.Action end), cost(function() return me.Stance end), cost(function() return me.IsJuvenile end),
        cost(function() return me.IsTamed end), cost(function() return me.CanBeTamed end),
        cost(function() return Creatures:GetInfo("Buffalo") end, 4000), cost(function() return Creatures:GetTamed() end, 4000))
    guard.suspend_watchdog(was)
    print("creature: microseconds a read on the stand-in: " .. line)
    t.ok(raw and tame and base >= 0)
end)

t.test("nothing was read that must not be, no name of Wax hides one of the game's, and no error was reported", function()
    t.eq(world.dead_touches, 0, "a freed object was touched: " .. tostring(world.dead_where))
    t.eq(values.crashes, 0)
    t.eq(values.misses, misses, "no lookup by path missed")
    for _, name in ipairs({ "stale", "grown", "crashes", "misuse", "unknown_names", "never_reads", "misses" }) do
        t.eq(tables[name], 0, "fake_tables." .. name)
    end
    t.eq(#easy.clashes(), 0)
    t.eq(list(easy.stats().unseen), "", "every class that was given members has been met")
    t.eq(#guard.errors(), 0, guard.errors()[1] and tostring(guard.errors()[1].message or guard.errors()[1].trace) or nil)
    t.eq(sched.Frame.count, 0)
end)

t.finish("creature")
