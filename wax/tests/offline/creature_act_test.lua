-- Offline tests for what the host does with creatures (world.creature): game.Creatures:Spawn, SetLevel, Freeze, Unfreeze,
-- Remove, Attack and assigning Behaviour on a creature, and game.Creatures.Damaged and the richer game.Creatures.Died.
-- The engine is a stand-in: a freed object raises on any use, a call with values the game was never given is counted,
-- a spawned animal gets its level a few frames after the call, and an array read past its end grows.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\creature_act_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local zoo = dofile("wax/tests/offline/fake_creatures.lua").install()
local wording = dofile("wax/tests/offline/wording.lua")
local world, values, tables, kit = zoo.world, zoo.values, zoo.tables, zoo.kit
local actions = dofile("wax/tests/offline/fake_actions.lua")
actions.install(world, values, kit, {})
local engine = dofile("wax/tests/offline/fake_hooks.lua")
engine.install(world, values, kit, nil)
local acts = dofile("wax/tests/offline/fake_creature_acts.lua").install(zoo)

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
actions.host(true)
game_module.start()
Wax.game = game_module.root
Wax.import("engine.actors").start()
local track = Wax.import("engine.track")
track.start()
local creatures = Wax.import("world.creatures")
creatures.start()
local data = Wax.import("data.tables")
local game = game_module.root
local Creatures = game.Creatures
local task = sched.task

-- Frames of 16 ms on a clock the tests own, in the order the game's frame loop has them.
local now, FRAME = 1000, 0.016
sched.clock = function() return now end
data.clock = function() return now end
data.start()
local function frames(count)
    for _ = 1, count or 1 do
        now = now + FRAME
        tables.next_frame()
        acts.next_frame(now)
        game_module.step()
        track.step()
        sched.step()
    end
end
local function pass(seconds) frames(math.ceil(seconds / FRAME) + 2) end

local character = Wax.import("world.character")
character.start()

local warnings, said = {}, {}
log.add_sink(function(entry, repeated)
    if not repeated and entry.level == "warn" and (entry.channel == "wax.creature" or entry.channel == "wax.easy") then
        warnings[#warnings + 1] = entry.message
    end
end)

local before = { world = world.touches, finds = values.finds, tables = tables.touches, hooks = engine.registrations }
local creature = Wax.import("world.creature")
creature.start()
local started = { world = world.touches, finds = values.finds, tables = tables.touches, hooks = engine.registrations }

local function animal(variant, over)
    local who = acts.make(variant, over)
    who.instance = instance.wrap(who.actor)
    return who
end

-- Runs fn, which must raise with `fragment`, and checks that the error names the line of the call inside fn.
local function raises_here(fn, fragment, what)
    local err = t.raises(fn, fragment, what)
    local info = debug.getinfo(fn, "S")
    local named = tonumber(tostring(err):match("creature_act_test%.lua:(%d+):"))
    t.ok(named and named >= info.linedefined and named <= info.lastlinedefined,
        (what or "the error") .. " should name the mod's line: " .. tostring(err))
    said[#said + 1] = (tostring(err):gsub("^.-%.lua:%d+: ", ""))
    return err
end

local function calls(name) return acts.calls[name] or 0 end
local function near(a, b, slack) return math.abs(a - b) <= (slack or 0.01) end
local function errors() return #guard.errors() end

-- What a signal fires with.
local function recorder()
    local seen = {}
    return seen, function(...) seen[#seen + 1] = { ... } end
end

-- Runs fn in a task, as a mod does that waits for Spawn. Returns a table that holds what fn returned once it has.
local function in_task(fn)
    local out = { done = false }
    task.spawn(function()
        out.values = table.pack(fn())
        out.done = true
    end)
    return out
end

local me = kit.player({ at = { 0, 0, 0 }, facing = { 0, 0, 0 } })
me.instance = instance.wrap(me.actor)

-- ------------------------------------------------------------------------------------------------------ starting

t.test("starting asks the engine nothing, hooks nothing, starts no list and puts nothing on the frame", function()
    t.eq(started.world, before.world, "no engine object was touched")
    t.eq(started.finds, before.finds, "nothing was looked up by path")
    t.eq(started.tables, before.tables, "no table was touched")
    t.eq(started.hooks, before.hooks, "no function of the game was hooked")
    t.eq(sched.Frame.count, 0)
    t.eq(track.stats().sets.creatures.tracking, false, "the list of creatures was not started")
    t.eq(creature.ACT_UNTRIED, false, "the switch is off as it ships")
    t.eq(type(rawget(Creatures, "Spawn")), "function")
    t.eq(type(rawget(Creatures, "Damaged")), "table")
    local names = table.concat(getmetatable(Creatures).__names(), ",")
    t.ok(names:find("Spawn", 1, true) and names:find("Damaged", 1, true), "the two new names are suggested: " .. names)
    t.eq(#warnings, 0, warnings[1])
end)

world.possess(me.actor)
frames(1)

local deer = animal("Deer", { at = { 1000, 0, 0 } })
local buffalo = animal("Buffalo", { at = { 2000, 0, 0 } })
local mount = animal("Mount_Buffalo", { at = { 3000, 0, 0 } })
local worm = animal("SandWorm", { at = { 9000, 0, 0 } })

t.test("in someone else's game every one of them is refused, and the game is asked for nothing", function()
    actions.host(false)
    local touched, looked = world.touches, values.finds
    local refusals = {
        function() deer.instance:SetLevel(9) end, function() deer.instance:Freeze() end, function() deer.instance:Unfreeze() end,
        function() deer.instance:Remove() end, function() buffalo.instance:Attack(game.Me) end,
        function() deer.instance.Behaviour = "Friendly" end, function() Creatures:Spawn("Deer") end,
    }
    for index, refused in ipairs(refusals) do
        local err = t.raises(refused, "only the host can", "refusal " .. index)
        t.ok(tostring(err):find("creature_act_test.lua:", 1, true), "it names the mod's line: " .. tostring(err))
        t.ok(tostring(err):find("game.IsHost says which you are", 1, true))
        said[#said + 1] = (tostring(err):gsub("^.-%.lua:%d+: ", ""))
    end
    t.eq(next(acts.calls), nil, "no function of the game was called")
    t.eq(values.finds, looked, "nothing was looked up")
    t.eq(deer.instance.IsFrozen, false, "reading stays allowed")
    t.ok(world.touches > touched)
    actions.host(true)
end)

-- --------------------------------------------------------------------------------------------------------- spawn

t.test("Spawn in a task answers once the game gave the animal its level, six metres ahead on the ground, turned to the character", function()
    local out = in_task(function() return Creatures:Spawn("Deer", { level = 12 }) end)
    t.eq(acts.spawns, 1, "the game's own spawn was called")
    t.eq(out.done, false, "the mod waits")
    local made = acts.last
    t.eq(made.store.CurrentLevel, 0, "the level is not there when the game's call returns")
    t.ok(near(made.spawned_at[1], 600) and near(made.spawned_at[2], 0), "six metres ahead of where the character looks")
    t.eq(made.spawned_at[3], 150, "a little above the ground the game named")
    frames(1)
    t.eq(out.done, false, "still waiting after one frame")
    frames(3)
    t.eq(out.done, true)
    local spawned, why = out.values[1], out.values[2]
    t.ok(instance.is_instance(spawned) and rawequal(spawned, instance.wrap(made.actor)), "the creature as an Instance")
    t.eq(why, nil)
    t.eq(spawned.Level, 12)
    t.eq(spawned.Variant, "Deer")
    t.eq(spawned.Kind, "MediumDeer")
    t.eq(spawned.Alive, true)
    t.ok(near(math.abs(spawned.Rotation.Yaw), 180, 0.5), "it looks back at the character: " .. tostring(spawned.Rotation.Yaw))
    t.eq(calls("SpawnNewAI"), 1)
    t.eq(calls("K2_ProjectPointToNavigation"), 1)
    t.eq(calls("GetZoneTextureSample"), 0, "a level that is given asks for no zone")
    t.eq(creature.act_stats().spawned, 1)
    t.ok(type(creature.act_stats().spawn_us) == "number", "what the spawn took is kept")
    t.eq(acts.fell, 0)
    t.ok(spawned:Remove())
    frames(10)
end)

t.test("outside a task Spawn answers at once, and the level follows", function()
    local spawned = Creatures:Spawn("deer", nil, { level = 3 })
    t.ok(instance.is_instance(spawned))
    t.eq(spawned.Level, 0, "the game has not finished it yet")
    frames(3)
    t.eq(spawned.Level, 3)
    spawned:Remove()
    frames(10)
    t.eq(spawned:IsValid(), false)
end)

t.test("Spawn finds the ground under a place itself, and spawns nothing where the game has none", function()
    acts.ground = function() return -500 end
    local spawned = Creatures:Spawn("Deer", { X = 4000, Y = 2000, Z = 300 }, { level = 1 })
    t.eq(acts.last.spawned_at[1], 4000)
    t.eq(acts.last.spawned_at[2], 2000)
    t.eq(acts.last.spawned_at[3], -350, "150 above the ground, not at the height that was asked for")
    t.eq(acts.fell, 0, "nothing was put under the ground")
    t.ok(near(spawned.Rotation.Yaw, 0), "a place that was given leaves it facing as the game makes it")
    spawned:Remove()
    acts.ground = function() return 0 end
    acts.no_ground = true
    local made = acts.spawns
    raises_here(function()
        Creatures:Spawn("Deer", { X = 4000, Y = 2000, Z = 300 })
    end, "the game found no ground a creature can walk on")
    t.eq(acts.spawns, made)
    t.eq(calls("SpawnNewAI"), made, "the game's spawn was not called")
    acts.no_ground = false
    frames(10)
end)

t.test("a place may be an actor or game.Me, and facing turns the animal", function()
    local beside = Creatures:Spawn("Deer", deer.instance, { level = 2, facing = { Yaw = 90 } })
    t.eq(acts.last.spawned_at[1], 1000)
    t.ok(near(beside.Rotation.Yaw, 90, 0.01), tostring(beside.Rotation.Yaw))
    local on_me = Creatures:Spawn("Deer", game.Me, { level = 2 })
    t.eq(acts.last.spawned_at[1], 0)
    t.eq(acts.last.spawned_at[2], 0)
    beside:Remove()
    on_me:Remove()
    frames(10)
end)

t.test("with no level, a spawned animal gets the middle level of the zone the place lies in", function()
    local function level_in(zone)
        acts.zone = zone
        local spawned = Creatures:Spawn("Deer")
        frames(3)
        local level = spawned.Level
        spawned:Remove()
        frames(10)
        return level
    end
    t.eq(level_in("OLY_Conifer_Easy"), 15)
    t.eq(level_in("oly_conifer_easy"), 15, "the engine may spell the zone in another letter case")
    t.eq(level_in("Arctic_Bear_Easy"), 50)
    t.eq(level_in("None"), 1, "no zone: level 1")
    t.eq(level_in("A_Zone_The_Table_Lacks"), 1)
    t.eq(level_in("Beyond"), creature.MOST_LEVEL, "never above the highest level that was tried")
    t.eq(calls("GetZoneTextureSample"), 6)
    acts.zone = "OLY_Conifer_Easy"
end)

t.test("Spawn takes a variant, or a kind that leaves no choice, and says which variants there are otherwise", function()
    local spawned = Creatures:Spawn("Buffalo", { level = 4 })
    t.eq(spawned.Variant, "Buffalo", "a name that is a kind and a variant means the variant")
    spawned:Remove()
    spawned = Creatures:Spawn("MediumDeer", { level = 4 })
    t.eq(spawned.Variant, "Deer", "a kind with one variant")
    spawned:Remove()
    spawned = Creatures:Spawn("Juvenile Buffalo", nil, { level = 4, variant = "juvenile_buffalo" })
    t.eq(spawned.Variant, "Juvenile_Buffalo", "the name the game shows, and the variant in another spelling")
    spawned:Remove()
    frames(10)
    local made, asked = acts.spawns, calls("K2_ProjectPointToNavigation")
    raises_here(function()
        Creatures:Spawn("Wolf")
    end, "Wolf comes in several variants: Conifer_Wolf, Juvenile_Forest_Wolf, Tamed_Forest_Wolf. Name one of them")
    raises_here(function()
        Creatures:Spawn("Wolf", { variant = "Deer" })
    end, "Deer is not a variant of Wolf. Its variants are Conifer_Wolf")
    raises_here(function()
        Creatures:Spawn("Wolf", { variant = "Conifer_Wolff" })
    end, "'Conifer_Wolff' is not a variant of a creature. Did you mean 'Conifer_Wolf'")
    raises_here(function()
        Creatures:Spawn("Deer", { variant = "Buffalo" })
    end, "Spawn was asked for Deer and for the variant Buffalo")
    local unknown = raises_here(function()
        Creatures:Spawn("Dear")
    end, "'Dear' is not a creature kind. Did you mean")
    t.ok(tostring(unknown):find("'Deer'", 1, true), "the nearest names are offered: " .. tostring(unknown))
    local twice = raises_here(function()
        Creatures:Spawn("Bufalo")
    end, "'Bufalo' is not a creature kind. Did you mean 'Buffalo'")
    local _, times = tostring(twice):gsub("'Buffalo'", "")
    t.eq(times, 1, "a name that is a kind and a variant is offered once: " .. tostring(twice))
    raises_here(function()
        Creatures:Spawn(nil)
    end, "Spawn expects the kind of creature as its first value")
    raises_here(function()
        Creatures.Spawn("Deer")
    end, "call Spawn with a colon")
    t.eq(acts.spawns, made)
    t.eq(calls("K2_ProjectPointToNavigation"), asked, "none of them got as far as the game")
end)

t.test("what Spawn is given wrongly is said before anything reaches the game", function()
    local made, asked = acts.spawns, calls("K2_ProjectPointToNavigation")
    raises_here(function()
        Creatures:Spawn("Deer", { levle = 3 })
    end, "Spawn has no option 'levle'. Did you mean 'level'")
    raises_here(function()
        Creatures:Spawn("Deer", { tamed = true })
    end, "the option 'tamed' of Spawn is not in this version of Wax")
    raises_here(function()
        Creatures:Spawn("Deer", { count = 3 })
    end, "the option 'count' of Spawn is not in this version of Wax")
    raises_here(function()
        Creatures:Spawn("Deer", { level = 0 })
    end, "the option level of Spawn is a level from 1 to 120")
    raises_here(function()
        Creatures:Spawn("Deer", { level = 121 })
    end, "the option level of Spawn is a level from 1 to 120")
    raises_here(function()
        Creatures:Spawn("Deer", { level = "high" })
    end, "the option level of Spawn expects a number")
    raises_here(function()
        Creatures:Spawn("Deer", { facing = 90 })
    end, "the option facing of Spawn is the way the creature looks")
    raises_here(function()
        Creatures:Spawn("Deer", { keep = "no" })
    end, "the option keep of Spawn is true or false")
    raises_here(function()
        Creatures:Spawn("Deer", { behaviour = "Freindly" })
    end, "'Freindly' is not a behaviour or a team of the game. Did you mean 'Friendly'")
    raises_here(function()
        Creatures:Spawn("Deer", "over there")
    end, "Spawn expects a place as its second value")
    raises_here(function()
        Creatures:Spawn("Deer", me.instance.ActorState)
    end, "Spawn expects an actor as its place")
    raises_here(function()
        Creatures:Spawn("Deer", { X = 0, Y = 0, Z = 0 }, 5)
    end, "the options of Spawn are a table")
    t.eq(acts.spawns, made)
    t.eq(calls("K2_ProjectPointToNavigation"), asked)
end)

t.test("a tamed variant is refused, and a row whose class the game lacks spawns nothing and says so", function()
    local made, asked = acts.spawns, calls("SpawnNewAI")
    raises_here(function()
        Creatures:Spawn("Mount_Buffalo")
    end, "Mount_Buffalo is a tamed animal, and spawning one is not in this version of Wax")
    raises_here(function()
        Creatures:Spawn("Cow")
    end, "Cow is a tamed animal")
    t.eq(calls("SpawnNewAI"), asked, "the game was not asked for a tamed animal")
    raises_here(function()
        Creatures:Spawn("Juvenile_Forest_Wolf", { level = 2 })
    end, "the game spawned nothing for Juvenile_Forest_Wolf")
    t.eq(acts.nothing, 1)
    t.eq(acts.spawns, made)
end)

t.test("without a character there is nothing to spawn beside", function()
    world.possess(nil)
    frames(1)
    raises_here(function()
        Creatures:Spawn("Deer", { X = 0, Y = 0, Z = 0 })
    end, "there is no character right now, and the game needs one to spawn a creature beside")
    world.possess(me.actor)
    frames(1)
end)

t.test("keep = false takes the animal out again when the mod that spawned it unloads", function()
    local mod = scope.new("mod")
    local kept, lent = nil, nil
    scope.run(mod, function()
        kept = Creatures:Spawn("Deer", { level = 2 })
        lent = Creatures:Spawn("Deer", { level = 2, keep = false })
    end)
    frames(3)
    local removals = calls("SetLifeSpan")
    mod:destroy()
    t.eq(calls("SetLifeSpan"), removals + 1, "only the one that was lent is taken away")
    frames(10)
    t.eq(lent:IsValid(), false)
    t.eq(kept:IsValid(), true, "what a mod spawned stays otherwise")
    kept:Remove()
    frames(10)
    local gone_first = scope.new("mod")
    local early = scope.run(gone_first, function() return Creatures:Spawn("Deer", { level = 2, keep = false }) end)
    early:Remove()
    frames(10)
    removals = calls("SetLifeSpan")
    gone_first:destroy()
    t.eq(calls("SetLifeSpan"), removals, "an animal that left by itself is not asked anything")
end)

t.test("the option behaviour puts the animal on that team once it is finished", function()
    local out = in_task(function() return Creatures:Spawn("Deer", { level = 2, behaviour = "Friendly" }) end)
    local made = acts.last
    t.eq(acts.team(made), "DefaultMediumHerbivore", "not while the game is still making it")
    frames(4)
    t.eq(out.done, true)
    t.eq(acts.team(made), "FriendlyAll")
    t.eq(out.values[1].Behaviour, "Friendly")
    out.values[1]:Remove()
    local at_once = Creatures:Spawn("Deer", { level = 2, behaviour = "EnemyPlayerOnly" })
    made = acts.last
    t.eq(acts.team(made), "DefaultMediumHerbivore")
    frames(4)
    t.eq(acts.team(made), "EnemyPlayerOnly", "outside a task it follows two frames later")
    t.eq(at_once.Behaviour, "HostileToPlayers")
    at_once:Remove()
    frames(10)
end)

t.test("a spawned animal that leaves the world before it is finished is answered as nothing, with the reason", function()
    acts.settle = 30
    local out = in_task(function() return Creatures:Spawn("Deer", { level = 9 }) end)
    local made = acts.last
    frames(2)
    zoo.remove(made)
    frames(2)
    t.eq(out.done, true)
    t.eq(out.values[1], nil)
    t.ok(tostring(out.values[2]):find("left the world before the game had finished making it", 1, true), tostring(out.values[2]))
    said[#said + 1] = out.values[2]
    acts.settle = 2
    t.eq(world.dead_touches, 0)
end)

t.test("Spawn waits two seconds at most for a level that never comes", function()
    acts.settle = 100000
    local out = in_task(function() return Creatures:Spawn("Deer", { level = 9 }) end)
    pass(1.9)
    t.eq(out.done, false)
    pass(0.2)
    t.eq(out.done, true)
    t.ok(instance.is_instance(out.values[1]), "the animal is handed over as it is")
    acts.settle = 2
    out.values[1]:Remove()
    frames(10)
end)

-- --------------------------------------------------------------------------------------------------------- level

t.test("SetLevel sets the level through the game and says whether it changed", function()
    local it = deer.instance
    t.eq(it.Level, 6)
    local health = it.MaxHealth
    t.eq(it:SetLevel(11), true)
    t.eq(it.Level, 11)
    t.eq(deer.store.CurrentLevel, 11)
    t.ok(it.MaxHealth ~= health, "its health follows the level")
    t.eq(it.Health, it.MaxHealth)
    local asked = calls("SetBaseLevel")
    t.eq(it:SetLevel(11), false, "it had that level already")
    t.eq(calls("SetBaseLevel"), asked + 1)
    t.eq(it:SetLevel(5.6), true, "a number is rounded")
    t.eq(it.Level, 6)
    raises_here(function()
        it:SetLevel(0)
    end, "SetLevel expects a level from 1 to 120")
    raises_here(function()
        it:SetLevel(121)
    end, "SetLevel expects a level from 1 to 120")
    raises_here(function()
        it:SetLevel("ten")
    end, "SetLevel expects a number")
    raises_here(function()
        it.SetLevel(9)
    end, "call SetLevel with a colon")
    t.eq(calls("SetBaseLevel"), asked + 2, "none of the wrong ones reached the game")
end)

t.test("a tamed animal and a creature that is no IcarusNPCCharacter are refused in plain words", function()
    local asked = calls("SetBaseLevel")
    raises_here(function()
        mount.instance:SetLevel(20)
    end, "SetLevel is not in this version of Wax for a tamed animal")
    raises_here(function()
        worm.instance:SetLevel(20)
    end, "SetLevel is not in this version of Wax for a BP_FactionBoss_SandWorm_C")
    raises_here(function()
        mount.instance:Freeze()
    end, "Freeze is not in this version of Wax for a tamed animal")
    raises_here(function()
        worm.instance:Remove()
    end, "Remove is not in this version of Wax for a BP_FactionBoss_SandWorm_C")
    raises_here(function()
        mount.instance.Behaviour = "HostileToAll"
    end, "Assigning Behaviour is not in this version of Wax for a tamed animal")
    raises_here(function()
        mount.instance:Attack(game.Me)
    end, "Attack is not in this version of Wax for a tamed animal")
    t.eq(calls("SetBaseLevel"), asked)
    t.eq(worm.instance.IsFrozen, nil, "a class without the flag reads as nothing")
    t.eq(acts.team(mount), "Player")
end)

-- -------------------------------------------------------------------------------------------------------- freeze

t.test("Freeze and Unfreeze hold an animal and let it go, each asked of the game once", function()
    local it = deer.instance
    t.eq(it.IsFrozen, false)
    t.eq(it:Freeze(), true)
    t.eq(it.IsFrozen, true)
    t.eq(deer.store.bIsNPCFrozen, true)
    t.eq(it:Freeze(), false, "it was frozen already")
    t.eq(calls("FreezeNPC"), 1)
    t.eq(it:Unfreeze(), true)
    t.eq(it.IsFrozen, false)
    t.eq(it:Unfreeze(), false, "it was not frozen")
    t.eq(calls("UnfreezeNPC"), 1)
end)

-- ----------------------------------------------------------------------------------------------------- behaviour

t.test("assigning Behaviour writes the team's name and leaves the rest of the handle", function()
    local it = deer.instance
    t.eq(it.Behaviour, "Default")
    it.Behaviour = "Friendly"
    t.eq(acts.team(deer), "FriendlyAll")
    t.eq(deer.store.AIRelationshipTableRowNew.DataTableName:ToString(), "D_AIRelationships", "the handle still names its table")
    t.eq(it.Behaviour, "Friendly")
    it.Behaviour = "hostile to players"
    t.eq(acts.team(deer), "EnemyPlayerOnly")
    it.Behaviour = "HostileToAll"
    t.eq(acts.team(deer), "EnemyAll")
    it.Behaviour = "Tame"
    t.eq(acts.team(deer), "Player")
    it.Behaviour = "default_large_carnivore"
    t.eq(acts.team(deer), "DefaultLargeCarnivore", "a team's own name, as the game's table spells it")
    t.eq(it.Behaviour, "DefaultLargeCarnivore")
    it.Behaviour = "Default"
    t.eq(acts.team(deer), "DefaultMediumHerbivore", "the team its variant starts on")
    t.eq(it.Behaviour, "Default")
    raises_here(function()
        it.Behaviour = "Freindly"
    end, "'Freindly' is not a behaviour or a team of the game. Did you mean 'Friendly'")
    raises_here(function()
        it.Behaviour = "EnemyAl"
    end, "Did you mean 'EnemyAll'")
    raises_here(function()
        it.Behaviour = 5
    end, "a behaviour is a word such as \"Friendly\"")
    t.eq(acts.team(deer), "DefaultMediumHerbivore", "a wrong value writes nothing")
end)

t.test("a creature the tables do not place cannot be set to Default, and an unreadable table of teams is not guessed at", function()
    local nameless = animal("Nameless", { at = { 5000, 0, 0 } })
    raises_here(function()
        nameless.instance.Behaviour = "Default"
    end, "the game's tables do not say which team this creature starts on")
    nameless.instance.Behaviour = "Friendly"
    t.eq(acts.team(nameless), "FriendlyAll")
    zoo.remove(nameless)
    tables.hide("AIRelationships")
    game.Data:Flush()
    frames(1)
    raises_here(function()
        deer.instance.Behaviour = "Friendly"
    end, "the game's table of teams cannot be read right now, so the behaviour 'Friendly' cannot be checked")
    t.eq(acts.team(deer), "DefaultMediumHerbivore")
    tables.hide("AIRelationships", false)
    game.Data:Flush()
    frames(1)
    deer.instance.Behaviour = "Friendly"
    t.eq(acts.team(deer), "FriendlyAll")
    deer.instance.Behaviour = "Default"
    t.ok(#warnings >= 1 and warnings[#warnings]:find("AIRelationships", 1, true), "one line says the table could not be read")
    warnings = {}
end)

-- -------------------------------------------------------------------------------------------------------- attack

t.test("Attack raises a hunter's aggression at a player's character, and the animal has it as its target a moment later", function()
    local it = buffalo.instance
    t.eq(acts.feels(buffalo, "Aggression"), 0)
    t.eq(it:Attack(game.Me), true)
    t.eq(acts.feels(buffalo, "Aggression"), 100)
    t.eq(calls("MakeNPCAngry"), 1)
    t.eq(it.Target, nil, "not in the frame of the call")
    frames(4)
    t.ok(rawequal(it.Target, me.instance), "the character is what it is after")
    t.eq(it:Attack(me.instance), true, "the character's Instance works as game.Me does")
    t.eq(buffalo.mind:GetArrayNum(), 7, "its motivations were read inside their length")
end)

t.test("an animal with no aggression says so, and one that does not plan is never handed to the game's call", function()
    local asked = calls("MakeNPCAngry")
    raises_here(function()
        deer.instance:Attack(game.Me)
    end, "a MediumDeer cannot be made to attack: the game gives its kind no aggression to raise")
    t.eq(deer.mind:GetArrayNum(), 6, "the list of its motivations did not grow")
    local wolf = kit.creature({ at = { 6000, 0, 0 } })
    wolf.instance = instance.wrap(wolf.actor)
    raises_here(function()
        wolf.instance:Attack(game.Me)
    end, "cannot be made to attack: the game's call is for the animals that plan what they do")
    raises_here(function()
        buffalo.instance:Attack(deer.instance)
    end, "Attack takes a player's character as its target in this version of Wax, and a BP_NPC_Deer_Character_C is not one")
    raises_here(function()
        buffalo.instance:Attack()
    end, "Attack expects whom to attack: a player's character or game.Me, got nil")
    raises_here(function()
        buffalo.instance:Attack(buffalo.instance)
    end, "a creature cannot be made to attack itself")
    t.eq(calls("MakeNPCAngry"), asked)
    t.eq(acts.crashes, 0)
    world.possess(nil)
    frames(1)
    raises_here(function()
        buffalo.instance:Attack(game.Me)
    end, "there is no character right now, so game.Me cannot be attacked")
    world.possess(me.actor)
    frames(1)
end)

-- ------------------------------------------------------------------------------------------------ remove and death

t.test("Remove takes an animal out of the world, and a dead one removed in time leaves no corpse", function()
    local gone = animal("Deer", { at = { 7000, 0, 0 } })
    t.eq(gone.instance:Remove(), true)
    frames(2)
    t.eq(gone.instance:IsValid(), true, "the game takes a moment")
    frames(10)
    t.eq(gone.instance:IsValid(), false)
    local late = t.raises(function()
        gone.instance:Remove()
    end, "no longer exists")
    said[#said + 1] = (tostring(late):gsub("^.-%.lua:%d+: ", ""))
    local killed = animal("Deer", { at = { 7000, 0, 0 } })
    t.eq(killed.instance:Kill(), true)
    pass(1)
    t.eq(killed.instance:Remove(), true, "a dead one can be removed too")
    pass(5)
    t.eq(acts.corpses, 0, "it left before the game made a corpse of it")
    local left = animal("Deer", { at = { 7000, 0, 0 } })
    left.instance:Kill()
    pass(2)
    t.eq(left.instance:IsValid(), true, "the body stays a creature for a moment")
    pass(2)
    t.eq(acts.corpses, 1, "a killed animal that stays becomes a corpse a few seconds later")
    t.eq(left.instance:IsValid(), false)
    acts.corpses = 0
end)

t.test("a dead creature cannot be frozen, levelled or made to attack", function()
    local dead = animal("Buffalo", { at = { 7500, 0, 0 } })
    dead.instance:Kill()
    local level, freeze, anger = calls("SetBaseLevel"), calls("FreezeNPC"), calls("MakeNPCAngry")
    raises_here(function()
        dead.instance:SetLevel(9)
    end, "this creature is dead, so its level cannot be set")
    raises_here(function()
        dead.instance:Freeze()
    end, "this creature is dead, so it cannot be frozen")
    raises_here(function()
        dead.instance:Unfreeze()
    end, "this creature is dead, so there is nothing to unfreeze")
    raises_here(function()
        dead.instance:Attack(game.Me)
    end, "this creature is dead, so it cannot be made to attack")
    t.eq(calls("SetBaseLevel"), level)
    t.eq(calls("FreezeNPC"), freeze)
    t.eq(calls("MakeNPCAngry"), anger)
    dead.instance:Remove()
    frames(10)
end)

-- -------------------------------------------------------------------------------------------------------- events

t.test("game.Creatures.Damaged tells of a hit on any creature, and of none on a player", function()
    local hooked = engine.registrations
    local seen, note = recorder()
    local connection = Creatures.Damaged:Connect(note)
    t.eq(engine.registrations, hooked + 1, "the game's damage call is listened to from the first handler on")
    t.eq(track.stats().sets.creatures.tracking, false, "damage needs no list of creatures")
    engine.damage(deer, 20, { by = me })
    t.eq(#seen, 0, "never inside the game's own call")
    frames(1)
    t.eq(#seen, 1)
    t.ok(rawequal(seen[1][1], deer.instance), "the creature")
    t.eq(seen[1][2], 20)
    t.ok(rawequal(seen[1][3].Causer, me.instance), "what did it")
    t.eq(seen[1][3].Health, deer.state_store.Health)
    engine.damage(me, 5)
    engine.damage(buffalo, 7, { by = deer })
    frames(1)
    t.eq(#seen, 2, "a player's damage is not a creature's")
    t.ok(rawequal(seen[2][1], buffalo.instance) and rawequal(seen[2][3].Causer, deer.instance))
    connection:Disconnect()
    engine.damage(deer, 1, { by = me })
    frames(1)
    t.eq(#seen, 2)
    t.eq(character.stats().told.listening, 0, "nothing is listened to once the handler is gone")
    deer.instance:Heal()
    buffalo.instance:Heal()
    me.state_store.Health = 300
end)

t.test("where the game's word of damage is not there, connecting says so at the mod's line", function()
    local events = character.events
    local kept = events.Damaged
    events.Damaged = nil
    raises_here(function()
        Creatures.Damaged:Connect(function() end)
    end, "damage cannot be told")
    events.Damaged = kept
    t.eq(Creatures.Damaged.count, 0)
end)

t.test("game.Creatures.Died names who ended a creature when a hit did, once, with what the list knows of it", function()
    local seen, note = recorder()
    local connection = Creatures.Died:Connect(note)
    t.eq(creature.act_stats().deaths_linked, true)
    local prey = animal("Deer", { at = { 8000, 0, 0 } })
    frames(3)
    engine.damage(prey, 999, { by = me })
    frames(1)
    t.eq(#seen, 1, "told in the frame after the hit")
    local who, info = seen[1][1], seen[1][2]
    t.ok(rawequal(who, prey.instance))
    t.ok(rawequal(info.Killer, me.instance), "the killer")
    t.eq(info.Damage, 999)
    t.eq(info.Kind, "MediumDeer")
    t.eq(info.Variant, "Deer")
    t.eq(info.ClassName, "BP_NPC_Deer_Character_C")
    t.ok(type(info.Name) == "string" and info.Name ~= "")
    pass(1)
    t.eq(#seen, 1, "looking at the list afterwards does not tell it again")
    prey.instance:Remove()
    connection:Disconnect()
    t.eq(creature.act_stats().deaths_linked, false)
    t.eq(character.stats().told.listening, 0)
    frames(10)
end)

t.test("a death with no hit is told by looking, a moment later and without a killer", function()
    local seen, note = recorder()
    local connection = Creatures.Died:Connect(note)
    local prey = animal("Deer", { at = { 8000, 0, 0 } })
    frames(3)
    t.eq(prey.instance:Kill(), true)
    frames(3)
    t.eq(#seen, 0, "it waits a moment for the game's word of who did it")
    t.eq(creature.act_stats().deaths_held, 1)
    pass(creature.HOLD + 0.2)
    t.eq(#seen, 1)
    t.ok(rawequal(seen[1][1], prey.instance))
    t.eq(seen[1][2].Killer, nil)
    t.eq(seen[1][2].Kind, "MediumDeer")
    t.eq(creature.act_stats().deaths_held, 0)
    pass(1)
    t.eq(#seen, 1)
    prey.instance:Remove()
    connection:Disconnect()
    frames(10)
end)

t.test("a death in the very frame its handler came, or of an animal that appeared a moment ago, is told all the same", function()
    local seen, note = recorder()
    local prey = animal("Deer", { at = { 8000, 0, 0 } })
    frames(3)
    local reads = world.touches
    local connection = Creatures.Died:Connect(note)
    t.ok(world.touches > reads, "the creatures that are listed were looked at once, so a death right away is not their first sight")
    t.eq(prey.instance:Kill(), true)
    pass(creature.HOLD + 0.3)
    t.eq(#seen, 1, "the animal was killed before looking had come round to it once")
    t.ok(rawequal(seen[1][1], prey.instance))
    local late = animal("Deer", { at = { 8000, 0, 0 } })
    frames(2)
    t.eq(late.instance:Kill(), true)
    pass(creature.HOLD + 0.3)
    t.eq(#seen, 2, "one that appeared after the handler counts as alive from the frame it was listed")
    t.ok(rawequal(seen[2][1], late.instance))
    prey.instance:Remove()
    late.instance:Remove()
    connection:Disconnect()
    frames(10)
    t.eq(creatures.tracked.Added.count, 0, "the list is not listened to once the handler is gone")
end)

t.test("a death that looking sees before the game's word of it is still told once, with the killer", function()
    local seen, note = recorder()
    local connection = Creatures.Died:Connect(note)
    local prey = animal("Deer", { at = { 8000, 0, 0 } })
    frames(3)
    engine.damage(prey, 999, { by = me, late = true })
    frames(2)
    t.eq(#seen, 0, "no health left, and the game has not marked it dead yet")
    kit.kill(prey)
    frames(3)
    t.eq(#seen, 0, "the list saw the death and waits")
    t.eq(creature.act_stats().deaths_held, 1)
    pass(0.3)
    t.eq(#seen, 1)
    t.ok(rawequal(seen[1][2].Killer, me.instance), "the hit that left it no health names who did it")
    t.eq(seen[1][2].Variant, "Deer")
    pass(1)
    t.eq(#seen, 1)
    prey.instance:Remove()
    connection:Disconnect()
    frames(10)
end)

t.test("a creature that is no character dies by looking alone and at once, and a player's death is not a creature's", function()
    local seen, note = recorder()
    local connection = Creatures.Died:Connect(note)
    local boss = animal("SandWorm", { at = { 8500, 0, 0 } })
    frames(3)
    kit.kill(boss)
    frames(3)
    t.eq(#seen, 1, "nothing waits for word the game never gives of it")
    t.ok(rawequal(seen[1][1], boss.instance))
    t.eq(seen[1][2].Killer, nil)
    local other = kit.player({ at = { 100, 0, 0 }, name = "Player Two" })
    engine.damage(other, 999, { by = deer })
    pass(1)
    t.eq(#seen, 1)
    zoo.remove(boss)
    world.destroy(other.actor)
    world.free(other.actor)
    connection:Disconnect()
    frames(2)
end)

t.test("a mod that unloads takes its handlers along, and nothing is listened to afterwards", function()
    local mod = scope.new("mod")
    scope.run(mod, function()
        Creatures.Died:Connect(function() end)
        Creatures.Damaged:Connect(function() end)
    end)
    t.eq(creature.act_stats().deaths_linked, true)
    t.eq(character.stats().told.listening, 2)
    mod:destroy()
    t.eq(Creatures.Died.count, 0)
    t.eq(Creatures.Damaged.count, 0)
    t.eq(creature.act_stats().deaths_linked, false)
    t.eq(character.stats().told.listening, 0, "the links belong to no mod and go with the last handler")
    t.eq(character.stats().told.hooked, false)
end)

t.test("taking the module from disk again keeps a connected handler told once, with the killer", function()
    local seen, note = recorder()
    local connection = Creatures.Died:Connect(note)
    local older = creature
    Wax.modules["world.creature"] = nil
    creature = Wax.import("world.creature")
    creature.start()
    t.ok(creature ~= older)
    t.eq(creature.act_stats().deaths_linked, true, "the new copy listens for the handler that was there")
    t.eq(older.act_stats().deaths_linked, false, "the old copy let go")
    local prey = animal("Deer", { at = { 8000, 0, 0 } })
    frames(3)
    engine.damage(prey, 999, { by = me })
    pass(1)
    t.eq(#seen, 1)
    t.ok(rawequal(seen[1][2].Killer, me.instance))
    t.eq(type(rawget(Creatures, "Spawn")), "function")
    local spawned = Creatures:Spawn("Deer", { level = 2 })
    t.eq(prey.instance.IsFrozen, false)
    spawned:Remove()
    prey.instance:Remove()
    connection:Disconnect()
    frames(10)
    t.eq(creature.act_stats().deaths_linked, false, "a handler from before lets go through the copy that listens now")
    t.eq(character.stats().told.listening, 0)
end)

-- ---------------------------------------------------------------------------------------------------------- the rest

t.test("with the switch on, what was never tried reaches the game, and the stand-in counts it", function()
    t.eq(acts.untried, 0, acts.log[1])
    creature.ACT_UNTRIED = true
    t.eq(mount.instance:SetLevel(20), true)
    t.eq(buffalo.instance:Attack(deer.instance), true)
    t.eq(acts.untried, 2, table.concat(acts.log, " | "))
    creature.ACT_UNTRIED = false
    acts.untried, acts.log = 0, {}
end)

t.test("what a mod author reads is plain, and everything a creature is given is described", function()
    local unwanted = wording.unwanted()
    if unwanted then t.ok(wording.complete(unwanted), "the owner's list was read whole from " .. wording.SOURCE) end
    local file = assert(io.open("wax/types/creature.lua", "rb"))
    local text = file:read("a")
    file:close()
    for line in text:gmatch("[^\r\n]+") do
        if line:sub(1, 3) == "---" then
            t.eq(wording.wrong_with(line:sub(4), unwanted), nil, "wax/types/creature.lua: " .. line:sub(1, 70))
        end
    end
    t.ok(#said > 50, "the messages of this suite were gathered: " .. #said)
    for _, message in ipairs(said) do t.eq(wording.wrong_with(message, unwanted), nil, message) end
    for name in pairs(creature.act_fields) do
        t.ok(text:find("---@field " .. name .. " ", 1, true), name .. " is described in wax/types/creature.lua")
    end
    for name in pairs(creature.act_methods) do
        t.ok(text:find("function Creature:" .. name .. "(", 1, true), name .. " is described in wax/types/creature.lua")
    end
    local game_types = assert(io.open("wax/types/game.lua", "rb"))
    local game_text = game_types:read("a")
    game_types:close()
    for _, name in ipairs({ "Spawn", "Damaged" }) do
        t.ok(game_text:find("---@field " .. name .. " ", 1, true), name .. " is described in wax/types/game.lua")
    end
    for line in game_text:gmatch("[^\r\n]+") do
        if line:find("---@field Spawn ", 1, true) or line:find("---@field Damaged ", 1, true) or line:find("Killer", 1, true) then
            t.eq(wording.wrong_with(line:sub(4), unwanted), nil, "wax/types/game.lua: " .. line:sub(1, 70))
        end
    end
end)

t.test("what a call costs on the stand-in", function()
    local was = guard.suspend_watchdog(true)
    local function cost(fn, rounds)
        rounds = rounds or 5000
        local started = perf.now()
        for _ = 1, rounds do fn() end
        return (perf.now() - started) / rounds * 1e6
    end
    local it, level = deer.instance, 6
    local line = ("IsFrozen %.2f | SetLevel %.1f | Freeze and Unfreeze %.1f | Behaviour = %.1f | Attack %.1f | Spawn and Remove %.1f"):format(
        cost(function() return it.IsFrozen end, 20000),
        cost(function()
            level = level == 6 and 7 or 6
            it:SetLevel(level)
        end),
        cost(function()
            it:Freeze()
            it:Unfreeze()
        end),
        cost(function() it.Behaviour = "Friendly" end),
        cost(function() buffalo.instance:Attack(game.Me) end),
        cost(function() Creatures:Spawn("Deer", { level = 2 }):Remove() end, 200))
    guard.suspend_watchdog(was)
    it.Behaviour = "Default"
    pass(1)
    print("creature_act: microseconds a call on the stand-in: " .. line)
    t.ok(it.Level == 6 or it.Level == 7)
end)

t.test("nothing untried reached the game, no freed object was touched, and no error was reported", function()
    t.eq(world.dead_touches, 0, "a freed object was touched: " .. tostring(world.dead_where))
    t.eq(values.crashes, 0, values.log[1])
    t.eq(acts.crashes, 0)
    t.eq(acts.untried, 0, acts.log[1])
    t.eq(acts.fell, 0)
    t.eq(actions.untried, 0, actions.log[1])
    t.eq(engine.returned, 0, "nothing was handed back to the game from a hook")
    for _, name in ipairs({ "stale", "grown", "crashes", "misuse", "unknown_names", "never_reads" }) do
        t.eq(tables[name], 0, "fake_tables." .. name)
    end
    t.eq(#easy.clashes(), 0)
    t.eq(errors(), 0, guard.errors()[1] and tostring(guard.errors()[1].message or guard.errors()[1].trace) or nil)
    t.eq(#warnings, 0, warnings[1])
    t.eq(sched.Frame.count, 0)
    t.eq(rawget(_G, "Enum_CurrentAliveState"), nil)
end)

t.finish("creature_act")
