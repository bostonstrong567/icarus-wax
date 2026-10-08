-- Offline tests for engine.hooks and for what world.character and world.items build on it: Damaged and Died on game.Me
-- and on every character, the nudge the game's own calls give the values that are looked at, the modifier signals, and
-- ItemAdded, ItemRemoved and ItemChanged on game.Me and on every inventory. The engine is a stand-in: a freed object
-- raises on any use, a hook is never taken off again, and a callback that hands the game a value is counted.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\hooks_test.lua
-- Add the word cost to print what a call of a hooked function takes on the stand-in.

local t = dofile("wax/tests/offline/harness.lua")
local world = dofile("wax/tests/offline/fake_world.lua")
world.install()
local values = dofile("wax/tests/offline/fake_values.lua")
values.install(world)
local kit = world.icarus(values)
local tables = dofile("wax/tests/offline/fake_tables.lua")
local fake = dofile("wax/tests/offline/fake_items.lua")
fake.install(world, values, tables, kit)
local actions = dofile("wax/tests/offline/fake_actions.lua")
actions.install(world, values, kit, { items = fake })
local engine = dofile("wax/tests/offline/fake_hooks.lua")
engine.install(world, values, kit, fake)

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)

local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local sched = Wax.import("core.sched")
local log = Wax.import("core.log")
local instance = Wax.import("engine.instance")
local game_module = Wax.import("engine.game")
world.possess(nil)
actions.host(true)
game_module.start()
Wax.game = game_module.root
Wax.import("engine.actors").start()
local data = Wax.import("data.tables")
local game = game_module.root

local TICK, PACKET = "/Script/Engine.Actor:ReceiveTick", "/Script/Icarus.IcarusCharacter:OnCharacterDamaged"
local DAMAGED = engine.DAMAGED

-- Frames of 16 ms on a clock the tests own. `wired` is the frame loop calling hooks.step, as boot does once it is wired.
local now, FRAME, wired = 1000, 0.016, false
sched.clock = function() return now end
data.clock = function() return now end
data.min_tables = 1
data.start()
local function frames(count)
    for _ = 1, count or 1 do
        now = now + FRAME
        fake.next_frame()
        game_module.step()
        if wired then Wax.import("engine.hooks").step() end
        sched.step()
    end
end
local function pass(seconds) frames(math.ceil(seconds / FRAME) + 2) end

local function at(err, line, what)
    t.ok(tostring(err):find("hooks_test.lua:" .. line .. ":", 1, true),
        (what or "the error") .. " should name line " .. line .. ": " .. tostring(err))
end

local function errors() return #guard.errors() end
local function warnings(channel) return #log.since(0, { level = "warn", channel = channel }) end

-- Collects what a signal fires with.
local function recorder()
    local seen = {}
    return seen, function(...) seen[#seen + 1] = { ... } end
end

local function hero(over)
    local who = fake.player(over)
    who.instance = instance.wrap(who.actor)
    return who
end

local function beast(over)
    local who = kit.creature(over)
    who.instance = instance.wrap(who.actor)
    return who
end

local function possess(who)
    world.possess(who and who.actor or nil)
    frames(1)
end

local thing = world.object("Thing_0", {})

-- ------------------------------------------------------------------------------------------------- engine.hooks itself

local hooks = Wax.import("engine.hooks")

t.test("loading and starting hook nothing and put nothing on the frame", function()
    hooks.start()
    t.eq(engine.registrations, 0)
    t.eq(sched.Frame.count, 0)
    local stats = hooks.stats()
    t.eq(stats.registered, 0)
    t.eq(next(stats.hooks), nil)
    t.eq(stats.driven, false)
    t.eq(type(rawget(_G, "WaxHooks")), "table", "what is hooked is kept in a real global, so a reload does not hook again")
end)

t.test("what is asked for wrongly is said in plain words", function()
    local function nothing() end
    t.raises(function() hooks.listen("/Game/BP/Player/BP_Player.BP_Player_C:OnDied", { reach = "net", catch = nothing }) end,
        "A blueprint's function cannot be listened to")
    t.raises(function() hooks.listen(nil, { reach = "net", catch = nothing }) end, "expects the path of a function")
    t.raises(function() hooks.listen(TICK, { reach = "net", catch = nothing, delivr = nothing }) end, "has no option 'delivr'. Did you mean 'deliver'")
    t.raises(function() hooks.listen(TICK, { reach = "nett", catch = nothing }) end, "is one of \"net\", \"delegate\" and \"called\"")
    t.raises(function() hooks.listen(TICK, { catch = nothing }) end, "reach says how the game calls")
    t.raises(function() hooks.listen(TICK, { reach = "net" }) end, "catch must be a function")
    t.raises(function() hooks.listen(TICK, { reach = "net", catch = nothing, deliver = 5 }) end, "deliver must be a function")
    t.raises(function() hooks.listen("/Script/Icarus.Nothing:Here", { reach = "net", catch = nothing }) end,
        "the game has no function /Script/Icarus.Nothing:Here to listen to")
    t.eq(engine.registrations, 0, "none of them reached UE4SS with a path the game has")
end)

t.test("a function is hooked once however many listen, and every listener gets the object and the values", function()
    local seen = {}
    local first = hooks.listen(TICK, { reach = hooks.NET, catch = function(object, a, b)
        seen[#seen + 1] = { "first", object, a:get(), b:get() }
    end })
    t.eq(engine.count(TICK), 1)
    local second = hooks.listen(TICK, { reach = hooks.NET, catch = function(object) seen[#seen + 1] = { "second", object } end })
    t.eq(engine.count(TICK), 1, "the second listener did not hook the function again")
    engine.raise(TICK, thing, 5, "five")
    t.eq(#seen, 2)
    t.eq(seen[1][1], "first")
    t.ok(rawequal(seen[1][2], thing), "the object the function was called on")
    t.eq(seen[1][3], 5)
    t.eq(seen[1][4], "five")
    t.eq(seen[2][1], "second")
    first()
    engine.raise(TICK, thing, 6, "six")
    t.eq(#seen, 3)
    t.eq(seen[3][1], "second")
    second()
    second()
    local calls = hooks.stats().hooks[TICK].calls
    engine.raise(TICK, thing, 7, "seven")
    t.eq(#seen, 3, "with nobody listening the hook does nothing")
    t.eq(hooks.stats().hooks[TICK].calls, calls, "and this module is not even entered")
    local again = hooks.listen(TICK, { reach = hooks.NET, catch = function() seen[#seen + 1] = { "again" } end })
    t.eq(engine.count(TICK), 1, "listening again uses the hook that is there")
    engine.raise(TICK, thing, 8, "eight")
    t.eq(seen[4][1], "again")
    again()
    t.eq(engine.returned, 0, "nothing is ever handed back to the game")
    t.eq(engine.unregistered, 0, "and UE4SS is never asked to take a hook off")
end)

t.test("a function that blueprints call hands over the object only", function()
    local got = nil
    local undo = hooks.listen(PACKET, { reach = hooks.CALLED, catch = function(...) got = table.pack(...) end })
    engine.raise(PACKET, thing, { TotalDamage = 5 })
    t.eq(got.n, 1)
    t.ok(rawequal(got[1], thing))
    t.raises(function() hooks.listen(PACKET, { reach = hooks.DELEGATE, catch = function() end }) end,
        "is already listened to as \"called\"")
    undo()
end)

t.test("what a listener catches is told in the frame loop, in the order it came, and never inside the game's call", function()
    local told = {}
    t.eq(sched.Frame.count, 0)
    local undo = hooks.listen(TICK, { reach = hooks.NET, deliver = function(value) told[#told + 1] = value end,
        catch = function(_, number)
            local value = number:get()
            if value < 0 then return nil end
            return value
        end })
    t.eq(sched.Frame.count, 0, "listening puts nothing on the frame")
    engine.raise(TICK, thing, 1)
    engine.raise(TICK, thing, -5)
    engine.raise(TICK, thing, 2)
    t.eq(#told, 0)
    t.eq(hooks.stats().queued, 2, "nil from catch is nothing to tell")
    t.eq(sched.Frame.count, 1, "until the frame loop calls step, one handler on the frame tells what waits")
    frames(1)
    t.eq(table.concat(told, " "), "1 2")
    t.eq(sched.Frame.count, 0, "and it is gone once nothing waits")
    frames(3)
    t.eq(#told, 2)
    undo()
    t.eq(sched.Frame.count, 0)
    t.eq(engine.returned, 0)
end)

t.test("a listener belongs to the mod that made it and goes when the mod unloads", function()
    local mod = scope.new("listener")
    local caught, told = 0, 0
    scope.run(mod, function()
        hooks.listen(TICK, { reach = hooks.NET, catch = function()
            caught = caught + 1
            return true
        end, deliver = function() told = told + 1 end })
    end)
    engine.raise(TICK, thing, 1)
    t.eq(caught, 1)
    mod:destroy()
    frames(1)
    t.eq(told, 0, "what was caught for a listener that is gone is not told")
    engine.raise(TICK, thing, 1)
    t.eq(caught, 1)
    t.eq(hooks.stats().hooks[TICK].listeners, 0)
    t.eq(sched.Frame.count, 0)
end)

t.test("a listener that raises is reported once, the others go on, and five in a row switch it off", function()
    local before, calls, fine = errors(), 0, 0
    local bad = hooks.listen(TICK, { reach = hooks.NET, label = "the bad one", catch = function()
        calls = calls + 1
        error("this catch is broken")
    end })
    local good = hooks.listen(TICK, { reach = hooks.NET, catch = function() fine = fine + 1 end })
    engine.raise(TICK, thing, 1)
    t.eq(errors(), before + 1)
    t.ok(guard.errors()[errors()].message:find("this catch is broken", 1, true))
    t.eq(guard.errors()[errors()].label, "hooks: the bad one")
    for _ = 1, 3 do engine.raise(TICK, thing, 1) end
    t.eq(errors(), before + 1, "the same failure is not reported again")
    engine.raise(TICK, thing, 1)
    t.eq(hooks.stats().hooks[TICK].off, 1)
    engine.raise(TICK, thing, 1)
    t.eq(calls, 5, "switched off, it is not called again")
    t.eq(fine, 6, "the other listener heard every call")
    bad()
    good()
    local told = 0
    local undo = hooks.listen(TICK, { reach = hooks.NET, catch = function() return true end, deliver = function()
        told = told + 1
        error("this deliver is broken")
    end })
    before = errors()
    engine.raise(TICK, thing, 1)
    frames(1)
    t.eq(told, 1)
    t.ok(errors() > before, "an error in the frame loop is reported")
    undo()
    t.eq(engine.returned, 0)
end)

t.test("more than a frame can hold is dropped and counted", function()
    local most, told = hooks.MOST, 0
    hooks.MOST = 2
    local undo = hooks.listen(TICK, { reach = hooks.NET, catch = function() return true end, deliver = function() told = told + 1 end })
    for _ = 1, 5 do engine.raise(TICK, thing, 1) end
    frames(1)
    hooks.MOST = most
    t.eq(told, 2)
    t.eq(hooks.stats().dropped, 3)
    undo()
end)

t.test("a signal made here says when its first handler comes and its last one leaves", function()
    local log_of = {}
    local signal = hooks.signal("counted", function() log_of[#log_of + 1] = "first" end, function() log_of[#log_of + 1] = "last" end)
    local a = signal:Connect(function() end)
    local b = signal:Connect(function() end)
    t.eq(table.concat(log_of, " "), "first")
    a:Disconnect()
    a:Disconnect()
    t.eq(table.concat(log_of, " "), "first")
    b:Disconnect()
    t.eq(table.concat(log_of, " "), "first last")
    local mod = scope.new("counted")
    scope.run(mod, function() signal:Once(function() end) end)
    mod:destroy()
    t.eq(table.concat(log_of, " "), "first last first last", "a mod that unloads counts as leaving")
    signal:Connect(function() end)
    signal:DisconnectAll()
    t.eq(log_of[#log_of], "last")
    local refusing = hooks.signal("refusing", function() error("this cannot be listened to here", 0) end, function() log_of[#log_of + 1] = "never" end)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        refusing:Connect(function() end)
    end, "this cannot be listened to here")
    at(err, line, "what the first handler was refused with")
    t.eq(refusing.count, 0)
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        signal:Connect(5)
    end, "Connect expects a function, got number")
    at(err, line)
end)

t.test("a new copy of the module lets go of what the old one listened for and hooks nothing twice", function()
    local old_calls = 0
    hooks.listen(TICK, { reach = hooks.NET, catch = function() old_calls = old_calls + 1 end })
    engine.raise(TICK, thing, 1)
    t.eq(old_calls, 1)
    Wax.modules["engine.hooks"] = nil
    local again = Wax.import("engine.hooks")
    t.ok(not rawequal(again, hooks))
    engine.raise(TICK, thing, 1)
    t.eq(old_calls, 1, "the old copy's listener is not called any more")
    local new_calls = 0
    local undo = again.listen(TICK, { reach = again.NET, catch = function() new_calls = new_calls + 1 end })
    t.eq(engine.count(TICK), 1, "the hook from before the reload is used")
    t.eq(again.stats().registered, 2)
    engine.raise(TICK, thing, 1)
    t.eq(new_calls, 1)
    t.eq(old_calls, 1)
    undo()
    hooks = again
end)

t.test("with the list of what blueprints call, a listed function hands over the object only whatever the listener says", function()
    Wax.modules["engine.hooks"] = nil
    local listed = Wax.import("engine.hooks")
    listed.LIST = "../../tests/offline/hooks_calls_fixture"
    local before, got = warnings("wax.hooks"), nil
    local undo = listed.listen(TICK, { reach = listed.NET, catch = function(...) got = table.pack(...) end })
    engine.raise(TICK, thing, 5, "five")
    t.eq(got.n, 1, "the values of a call made by a blueprint are the caller's own variables, so none is handed over")
    t.eq(listed.stats().hooks[TICK].reach, "called")
    t.eq(listed.stats().list, true)
    t.eq(warnings("wax.hooks"), before + 1)
    undo()
    local other = listed.listen(PACKET, { reach = listed.DELEGATE, catch = function(...) got = table.pack(...) end })
    engine.raise(PACKET, thing, 5)
    t.eq(got.n, 2, "a function the list does not name keeps its values")
    other()
    Wax.modules["engine.hooks"] = nil
    hooks = Wax.import("engine.hooks")
    t.eq(hooks.stats().list, false, "this workspace's runtime has no such list of its own")
end)

t.test("once the frame loop calls step, nothing is put on the frame signal", function()
    local told = 0
    local undo = hooks.listen(TICK, { reach = hooks.NET, catch = function() return true end, deliver = function() told = told + 1 end })
    engine.raise(TICK, thing, 1)
    t.eq(sched.Frame.count, 1)
    wired = true
    frames(1)
    t.eq(told, 1, "what waited is told by the step")
    t.eq(sched.Frame.count, 0, "and the first step takes the handler off the frame")
    t.eq(hooks.stats().driven, true)
    engine.raise(TICK, thing, 1)
    t.eq(sched.Frame.count, 0)
    frames(1)
    t.eq(told, 2)
    undo()
end)

-- -------------------------------------------------------------------------------------- characters: damage and death

local registrations = engine.registrations
local character = Wax.import("world.character")
-- world.stats is not in this suite: a stand-in gives every character the list its GetModifiers would
local modifiers_of = setmetatable({}, { __mode = "k" })
character.extend("character", { methods = { GetModifiers = function(self)
    local out = {}
    for i, one in ipairs(modifiers_of[self] or {}) do
        out[i] = { Name = one.Name, DisplayName = one.DisplayName, Kind = one.Kind, Id = one.Id, Duration = one.Duration, Remaining = one.Remaining }
    end
    return out
end } }, "stats")
character.start()
local items = Wax.import("world.items")
items.start()

local me = hero()
possess(me)

t.test("starting hooks nothing, and game.Me, every character and every inventory have their signals", function()
    t.eq(engine.registrations, registrations)
    t.eq(sched.Frame.count, 0)
    for _, name in ipairs({ "Damaged", "Died", "ModifierAdded", "ModifierRemoved", "ItemAdded", "ItemRemoved", "ItemChanged" }) do
        t.eq(game.Me[name].name, "game.Me." .. name)
        t.raises(function() game.Me[name] = nil end, "cannot be assigned")
    end
    local wolf = beast()
    t.eq(wolf.instance.Damaged.name, "BP_NPC_Wolf_Conifer_Character_C.Damaged")
    t.eq(wolf.instance.Died.name, "BP_NPC_Wolf_Conifer_Character_C.Died")
    t.ok(rawequal(wolf.instance.Damaged, wolf.instance.Damaged), "one signal per character")
    t.ok(not rawequal(wolf.instance.Damaged, me.instance.Damaged))
    t.ok(not rawequal(me.instance.Damaged, game.Me.Damaged), "game.Me has its own, which stays through a respawn")
    t.eq(me.instance.Backpack.ItemAdded.name, "Inventory.ItemAdded")
    t.eq(engine.registrations, registrations, "reading a signal hooks nothing")
    t.eq(character.stats().told.listening, 0)
    t.eq(#Wax.import("engine.easy").clashes(), 0)
    t.eq(character.EVENTS, true)
    t.eq(items.EVENTS, true)
end)

t.test("game.Me.Damaged tells who, how much and what the game knows of the hit, a frame later", function()
    local seen, note = recorder()
    local connection = game.Me.Damaged:Connect(note)
    t.eq(engine.count(DAMAGED), 1, "the first handler hooks the game's own call")
    t.eq(character.stats().told.hooked, true)
    engine.damage(me, 11)
    t.eq(#seen, 0, "nothing of a mod's runs inside the game's call")
    frames(1)
    t.eq(#seen, 1)
    local who, amount, info = seen[1][1], seen[1][2], seen[1][3]
    t.ok(rawequal(who, me.instance))
    t.eq(amount, 11)
    t.eq(info.Health, 289)
    t.eq(info.Applied, 11)
    t.eq(info.Total, 11)
    t.eq(info.Radial, false)
    t.eq(info.Stealth, false)
    t.ok(rawequal(info.Causer, me.instance), "for hunger and a fall the game names the character itself")
    t.eq(info.Instigator, nil)
    local wolf = beast()
    engine.damage(wolf, 5)
    frames(1)
    t.eq(#seen, 1, "another character's damage is not game.Me's")
    local other, also = recorder()
    local second = game.Me.Damaged:Connect(also)
    engine.damage(me, 4, { by = wolf })
    frames(1)
    t.ok(rawequal(seen[2][3].Causer, wolf.instance), "the one that did it, as an Instance")
    t.eq(other[1][3].Health, 285)
    connection:Disconnect()
    second:Disconnect()
    t.eq(hooks.stats().hooks[DAMAGED].listeners, 0, "the last handler to leave lets go of the hook")
    engine.damage(me, 1)
    frames(1)
    t.eq(#seen, 2)
    me.state_store.Health = 300
    t.eq(engine.returned, 0)
    t.eq(world.dead_touches, 0)
end)

t.test("damage makes HealthChanged tell in the next frame instead of at its next look", function()
    local changes, note = recorder()
    local health = game.Me.HealthChanged:Connect(note)
    local damaged = game.Me.Damaged:Connect(function() end)
    frames(1)
    for round = 1, 3 do
        engine.damage(me, 10)
        frames(1)
        t.eq(#changes, round, "told one frame after hit " .. round)
    end
    t.eq(changes[3][1], 270)
    t.eq(changes[3][2], 280)
    health:Disconnect()
    damaged:Disconnect()
    me.state_store.Health = 300
end)

t.test("a character's own Damaged and Died: the hit, the death with who did it, a death with no hit, and a second death", function()
    local wolf = beast()
    local hits, note_hit = recorder()
    local deaths, note_death = recorder()
    local a = wolf.instance.Damaged:Connect(note_hit)
    local b = wolf.instance.Died:Connect(note_death)
    t.eq(character.stats().told.waited_for, 1, "a character whose death is asked about is looked at")
    engine.damage(wolf, 40, { by = me })
    frames(1)
    t.eq(#hits, 1)
    t.ok(rawequal(hits[1][1], wolf.instance))
    t.eq(hits[1][2], 40)
    t.eq(hits[1][3].Health, 62)
    t.ok(rawequal(hits[1][3].Causer, me.instance))
    t.eq(#deaths, 0)
    engine.damage(wolf, 100, { by = me })
    frames(1)
    t.eq(#hits, 2)
    t.eq(hits[2][2], 100)
    t.eq(hits[2][3].Applied, 62, "what the game took off, which is less than the hit when little health was left")
    t.eq(#deaths, 1, "the death is told in the frame of the hit")
    t.ok(rawequal(deaths[1][1], wolf.instance))
    t.ok(rawequal(deaths[1][2].Killer, me.instance))
    t.eq(deaths[1][2].Damage, 100)
    pass(1)
    t.eq(#deaths, 1, "once")
    kit.revive(wolf)
    pass(0.5)
    kit.kill(wolf)
    pass(0.5)
    t.eq(#deaths, 2, "a death that came with no hit is seen by looking")
    t.eq(deaths[2][2].Killer, nil, "and nobody is named for it")
    a:Disconnect()
    b:Disconnect()
    pass(0.5)
    t.eq(character.stats().told.listening, 0)
    t.eq(character.stats().told.waited_for, 0)
    t.eq(world.dead_touches, 0)
end)

t.test("a character left with no health is told dead when the game marks it so, and not when it recovers", function()
    local wolf, lucky = beast(), beast()
    local deaths, note = recorder()
    local a = wolf.instance.Died:Connect(note)
    local b = lucky.instance.Died:Connect(note)
    engine.damage(wolf, 500, { by = me, late = true })
    engine.damage(lucky, 500, { late = true })
    frames(2)
    t.eq(#deaths, 0, "no health and still alive is not a death yet")
    wolf.state_store.CurrentAliveState = 1
    lucky.state_store.Health = 50
    pass(0.4)
    t.eq(#deaths, 1)
    t.ok(rawequal(deaths[1][1], wolf.instance))
    t.ok(rawequal(deaths[1][2].Killer, me.instance), "the hit that ended it is still known")
    pass(3)
    t.eq(#deaths, 1)
    a:Disconnect()
    b:Disconnect()
end)

t.test("game.Me.Died: by a hit with what did it, and by looking when there was none", function()
    local deaths, note = recorder()
    local back, note_back = recorder()
    local a = game.Me.Died:Connect(note)
    local b = game.Me.Respawned:Connect(note_back)
    local wolf = beast()
    pass(0.3)
    engine.damage(me, 500, { by = wolf })
    frames(1)
    t.eq(#deaths, 1, "told in the frame after the hit")
    t.ok(rawequal(deaths[1][1], me.instance))
    t.ok(rawequal(deaths[1][2].Killer, wolf.instance))
    t.eq(deaths[1][2].Damage, 500)
    pass(1)
    t.eq(#deaths, 1, "the look that sees the death too does not tell it again")
    kit.revive(me)
    pass(0.5)
    t.eq(#back, 1, "Respawned still tells the return")
    kit.kill(me)
    pass(0.5)
    t.eq(#deaths, 2, "a death with no hit is seen by the look")
    t.eq(deaths[2][2].Killer, nil)
    kit.revive(me)
    pass(0.5)
    a:Disconnect()
    b:Disconnect()
    pass(0.5)
    t.eq(character.stats().told.listening, 0)
    t.eq(character.stats().told.waited_for, 0)
    t.eq(sched.Frame.count, 0)
end)

t.test("character.events tells of every character, and of nothing that is not one", function()
    local hits, note_hit = recorder()
    local deaths, note_death = recorder()
    local a = character.events.Damaged:Connect(note_hit)
    local b = character.events.Died:Connect(note_death)
    local wolf = beast()
    engine.damage(wolf, 7)
    engine.damage(me, 3)
    frames(1)
    t.eq(#hits, 2)
    t.ok(rawequal(hits[1][1], wolf.instance))
    t.ok(rawequal(hits[2][1], me.instance))
    local state, state_store = values.part(kit.classes.ActorState, "ActorState", { Health = 40, MaxHealth = 50, CurrentAliveState = 0 })
    values.actor(kit.classes.Actor, "BP_Wall_1", { Location = { 0, 0, 0 } }, { state })
    state_store.LastDamagePacket = { TotalDamage = 10, AppliedDamage = 10 }
    engine.raise(DAMAGED, state, 10, {}, nil, nil)
    frames(1)
    t.eq(#hits, 2, "a wall with a state is not a character")
    engine.damage(wolf, 500, { by = me })
    frames(1)
    t.eq(#deaths, 1)
    t.ok(rawequal(deaths[1][1], wolf.instance))
    a:Disconnect()
    b:Disconnect()
    me.state_store.Health = 300
    pass(0.5)
    t.eq(character.stats().told.listening, 0)
end)

t.test("a character that leaves the world is let go without being touched again", function()
    local wolf = beast()
    local hits, note = recorder()
    local a = wolf.instance.Damaged:Connect(note)
    local b = wolf.instance.Died:Connect(note)
    local quiet = beast()
    local c = quiet.instance.Damaged:Connect(note)
    pass(0.3)
    world.destroy(wolf.actor)
    world.free(wolf.actor)
    world.destroy(quiet.actor)
    world.free(quiet.actor)
    pass(1)
    t.eq(world.dead_touches, 0, tostring(world.dead_where))
    t.eq(character.stats().told.waited_for, 0, "nothing waits for it any more")
    t.eq(#hits, 0, "leaving the world is not a death")
    t.eq(a.Connected, false, "its handlers are disconnected")
    t.eq(b.Connected, false)
    t.eq(c.Connected, false, "also where only its damage was asked about")
    t.eq(character.stats().told.listening, 0)
    t.eq(character.stats().told.hooked, false)
    t.raises(function() return wolf.instance.Damaged end, "no longer exists")
end)

t.test("a mod that unloads takes its handlers along, and nothing is listened to or looked at afterwards", function()
    local mod, wolf = scope.new("listening"), beast()
    scope.run(mod, function()
        game.Me.Damaged:Connect(function() end)
        game.Me.Died:Connect(function() end)
        wolf.instance.Died:Connect(function() end)
        character.events.Damaged:Connect(function() end)
    end)
    t.eq(character.stats().told.listening, 4)
    t.eq(hooks.stats().hooks[DAMAGED].listeners, 1)
    mod:destroy()
    t.eq(character.stats().told.listening, 0)
    t.eq(character.stats().told.hooked, false)
    t.eq(hooks.stats().hooks[DAMAGED].listeners, 0)
    pass(0.6)
    t.eq(character.stats().told.waited_for, 0)
    t.eq(sched.Frame.count, 0)
    t.eq(mod:size(), 0)
end)

-- --------------------------------------------------------------------------- the values the game tells of by itself

t.test("the game's own word of food makes FoodChanged tell in the next frame, and the looking is slow", function()
    local watch_module = function() return Wax.import("engine.watch") end
    t.eq(character.PACE.Food, 2)
    t.eq(character.PACE.Health, 0.1, "health has no word of the game's and is looked at as before")
    local changes, note = recorder()
    local connection = game.Me.FoodChanged:Connect(note)
    local path = engine.VITALS.Food[1]
    t.eq(engine.count(path), 1)
    frames(2)
    engine.vital(me, "Food", 250)
    t.eq(#changes, 0)
    frames(1)
    t.eq(#changes, 1)
    t.eq(changes[1][1], 250)
    t.eq(changes[1][2], 285)
    local other = hero()
    local delivered, looks = hooks.stats().delivered, watch_module().stats().looks
    engine.vital(other, "Food", 100)
    frames(1)
    t.eq(hooks.stats().delivered, delivered, "another player's food is not looked into")
    t.eq(watch_module().stats().looks, looks)
    me.state_store.FoodLevel = 240
    pass(2.1)
    t.eq(#changes, 2, "a change the game did not tell of is still seen by looking")
    t.eq(changes[2][1], 240)
    connection:Disconnect()
    t.eq(hooks.stats().hooks[path].listeners, 0)
    engine.vital(me, "Food", 285)
    frames(2)
    t.eq(#changes, 2)
    t.eq(sched.Frame.count, 0)
end)

t.test("the weight the game works out a tick later makes WeightChanged tell at once", function()
    local changes, note = recorder()
    local connection = game.Me.WeightChanged:Connect(note)
    frames(2)
    fake.put(me.backpack, 5, "Stone", 6)
    engine.weight(me, me.backpack)
    frames(1)
    t.eq(#changes, 1)
    t.eq(changes[1][1], 2.97)
    t.eq(changes[1][2], 1.17)
    fake.take(me.backpack, 5)
    engine.weight(me, me.backpack)
    frames(1)
    t.eq(#changes, 2)
    connection:Disconnect()
end)

t.test("when the game no longer has the call, the value is looked at as often as before and one line says so", function()
    local path = engine.VITALS.Oxygen[1]
    engine.FUNCTIONS[path] = nil
    local before = warnings("wax.character")
    local changes, note = recorder()
    local connection = game.Me.OxygenChanged:Connect(note)
    t.eq(warnings("wax.character"), before + 1)
    t.eq(character.PACE.Oxygen, 0.5)
    me.state_store.OxygenLevel = 200
    pass(0.6)
    t.eq(#changes, 1)
    connection:Disconnect()
    connection = game.Me.OxygenChanged:Connect(note)
    t.eq(warnings("wax.character"), before + 1, "it is said once")
    connection:Disconnect()
    engine.FUNCTIONS[path] = true
end)

t.test("ModifierAdded and ModifierRemoved tell what came and went, and not what only counts down", function()
    local came, note_came = recorder()
    local went, note_went = recorder()
    local a = game.Me.ModifierAdded:Connect(note_came)
    local b = game.Me.ModifierRemoved:Connect(note_went)
    local list = { { Name = "Berry", DisplayName = "Berry", Kind = "Buff", Id = 12, Duration = 600, Remaining = 600 } }
    modifiers_of[me.instance] = list
    pass(0.6)
    t.eq(#came, 1)
    t.eq(came[1][1].Name, "Berry")
    t.eq(came[1][1].Id, 12)
    t.eq(came[1][1].Duration, 600)
    t.eq(came[1][1].Remaining, nil, "what counts down is asked of GetModifiers")
    list[1].Remaining = 500
    list[2] = { Name = "Dirty_Water", DisplayName = "Tainted Water", Kind = "Debuff", Id = 14, Duration = 300, Remaining = 300 }
    pass(0.6)
    t.eq(#came, 2)
    t.eq(came[2][1].DisplayName, "Tainted Water")
    t.eq(#went, 0)
    table.remove(list, 1)
    pass(0.6)
    t.eq(#went, 1)
    t.eq(went[1][1].Name, "Berry")
    t.eq(#came, 2)
    local other = hero()
    modifiers_of[other.instance] = { { Name = "Health_Regen", Kind = "Buff", Id = 3, Duration = 20, Remaining = 20 } }
    possess(other)
    pass(0.6)
    t.eq(#came, 2, "another character's modifiers are where they start from, not something that came")
    t.eq(#went, 1)
    possess(me)
    a:Disconnect()
    b:Disconnect()
    pass(0.6)
    t.eq(sched.Frame.count, 0)
end)

-- ------------------------------------------------------------------------------------------------------ inventories

local SLOT = engine.SLOT

t.test("the game's item events are hooked when a mod first asks about an inventory, and counts then follow at once", function()
    t.eq(engine.count(SLOT.changed), 0)
    local pack = me.instance.Backpack
    t.eq(pack:Count("Stone"), 0)
    t.eq(engine.count(SLOT.added), 1)
    t.eq(engine.count(SLOT.removed), 1)
    t.eq(engine.count(SLOT.changed), 1)
    t.eq(items.stats().told, true)
    frames(1)
    local walks = items.stats().walks
    fake.put(me.backpack, 5, "Stone", 6)
    engine.slot(me.backpack, 5, "added", "changed")
    t.eq(pack:Count("Stone"), 6, "in the frame the game told of it, though the weight has not moved yet")
    t.eq(items.stats().walks, walks, "by reading the one slot the game named")
    fake.take(me.backpack, 5)
    engine.slot(me.backpack, 5, "removed", "changed")
    t.eq(pack:Count("Stone"), 0)
    t.eq(engine.returned, 0)
    t.eq(rawget(_G, "Enum_PropertyType"), nil)
end)

t.test("an inventory's ItemAdded, ItemRemoved and ItemChanged: what one frame did to it", function()
    local pack, inv = me.instance.Backpack, me.backpack
    local added, note_added = recorder()
    local removed, note_removed = recorder()
    local changed, note_changed = recorder()
    local a, b, c = pack.ItemAdded:Connect(note_added), pack.ItemRemoved:Connect(note_removed), pack.ItemChanged:Connect(note_changed)
    t.eq(items.stats().listened, 1)

    fake.put(inv, 5, "Stone", 5)
    engine.slot(inv, 5, "added", "changed")
    t.eq(#added, 0, "nothing of a mod's runs inside the game's call")
    frames(1)
    t.eq(#added, 1)
    t.eq(added[1][1], "Stone")
    t.eq(added[1][2], 5)
    t.eq(added[1][3].Item, "Stone")
    t.eq(added[1][3].Count, 5)
    t.eq(added[1][3].Slot, 5)
    t.eq(#changed, 1)
    t.eq(changed[1][1].Count, 5)
    t.eq(changed[1][2], nil, "the slot was empty before")
    t.eq(#removed, 0)

    fake.set(inv, 5, fake.STACK, 8)
    engine.slot(inv, 5, "changed")
    frames(1)
    t.eq(#added, 2)
    t.eq(added[2][2], 3, "a stack that grew is told as what came")
    t.eq(changed[2][1].Count, 8)
    t.eq(changed[2][2].Count, 5)

    fake.set(inv, 5, fake.STACK, 6)
    engine.slot(inv, 5, "removed", "changed")
    frames(1)
    t.eq(#removed, 1)
    t.eq(removed[1][1], "Stone")
    t.eq(removed[1][2], 2)
    t.eq(removed[1][3].Count, 8, "the stack as it was")

    fake.take(inv, 5)
    engine.slot(inv, 5, "removed", "changed")
    frames(1)
    t.eq(#removed, 2)
    t.eq(removed[2][2], 6)
    t.eq(changed[4][1], nil, "the slot is empty now")
    t.eq(changed[4][2].Count, 6)
    t.eq(#added, 2)
    t.eq(#changed, 4)

    -- a stack that spoils: the game names its slot every second
    fake.put(inv, 6, "Berry", 4, { { 12, 500 } })
    engine.slot(inv, 6, "added", "changed")
    frames(1)
    t.eq(#added, 3)
    t.eq(added[3][3].Properties.Decayable_CurrentSpoilTime, 500)
    for second = 1, 3 do
        fake.set(inv, 6, 12, 500 - second)
        engine.slot(inv, 6, "changed")
        frames(1)
    end
    t.eq(#changed, 5, "a spoil timer that counts down is no change to tell")
    t.eq(#added, 3)

    -- a tool that wears
    fake.tool(inv, 7, "Stone_Pickaxe", 20000)
    engine.slot(inv, 7, "added", "changed")
    frames(1)
    t.eq(#added, 4)
    fake.set(inv, 7, fake.DURABILITY, 19990)
    engine.slot(inv, 7, "changed")
    frames(1)
    t.eq(#changed, 7)
    t.eq(changed[7][1].Durability, 19990)
    t.eq(changed[7][2].Durability, 20000)
    t.eq(#added, 4, "wear is a change and nothing that came or went")
    t.eq(#removed, 2)

    -- a stack moved to another slot within one frame
    fake.take(inv, 1)
    fake.put(inv, 9, "Fiber", 64, { { fake.TRANSMUTABLE, 5000 } })
    engine.slot(inv, 1, "removed", "changed")
    engine.slot(inv, 9, "added", "changed")
    frames(1)
    t.eq(#changed, 9)
    t.eq(changed[8][1], nil)
    t.eq(changed[8][2].Slot, 1)
    t.eq(changed[9][1].Slot, 9)
    t.eq(#added, 4, "what one frame adds and takes cancels out")
    t.eq(#removed, 2)

    -- something that came and went within one frame
    fake.put(inv, 10, "Stone", 1)
    engine.slot(inv, 10, "added", "changed")
    fake.take(inv, 10)
    engine.slot(inv, 10, "removed", "changed")
    frames(1)
    t.eq(#changed, 9)
    t.eq(#added, 4)
    t.eq(#removed, 2)

    added[4][3].Count = 99
    t.eq(pack:Count("Stone_Pickaxe"), 1, "what a handler is handed is its own")
    t.eq(rawget(_G, "Enum_PropertyType"), nil)
    a:Disconnect()
    b:Disconnect()
    t.eq(items.stats().listened, 1, "listened to while one handler is left")
    c:Disconnect()
    t.eq(items.stats().listened, 0)
    fake.take(inv, 6)
    fake.take(inv, 7)
    fake.take(inv, 9)
    fake.put(inv, 1, "Fiber", 64, { { fake.TRANSMUTABLE, 5000 } })
    for _, position in ipairs({ 1, 6, 7, 9 }) do engine.slot(inv, position, "changed") end
    frames(1)
    t.eq(#changed, 9, "with no handler nothing is worked out")
    t.eq(world.dead_touches, 0)
    t.eq(fake.grown, 0, "no list was read past its end")
    t.eq(fake.stale, 0, "nothing the engine handed out was used after its frame")
end)

t.test("game.Me.ItemAdded and its two siblings: everything the character carries, as one", function()
    local added, note_added = recorder()
    local removed, note_removed = recorder()
    local changed, note_changed = recorder()
    local a, b, c = game.Me.ItemAdded:Connect(note_added), game.Me.ItemRemoved:Connect(note_removed), game.Me.ItemChanged:Connect(note_changed)
    t.eq(items.stats().listened, 6, "the six inventories of the character")
    fake.put(me.backpack, 5, "Stone", 5)
    engine.slot(me.backpack, 5, "added", "changed")
    frames(1)
    t.eq(#added, 1)
    t.eq(added[1][1], "Stone")
    t.eq(added[1][2], 5)
    t.eq(added[1][3].Inventory, "Backpack")
    t.eq(changed[1][1].Inventory, "Backpack")

    -- from the backpack to the hotbar within one frame
    fake.take(me.backpack, 5)
    fake.put(me.hotbar, 3, "Stone", 5)
    engine.slot(me.backpack, 5, "removed", "changed")
    engine.slot(me.hotbar, 3, "added", "changed")
    frames(1)
    t.eq(#added, 1, "moved from one inventory to another, nothing came or went")
    t.eq(#removed, 0)
    t.eq(#changed, 3)
    t.eq(changed[2][2].Inventory, "Backpack")
    t.eq(changed[3][1].Inventory, "Hotbar")

    fake.take(me.hotbar, 3)
    engine.slot(me.hotbar, 3, "removed", "changed")
    frames(1)
    t.eq(#removed, 1)
    t.eq(removed[1][1], "Stone")
    t.eq(removed[1][2], 5)
    t.eq(removed[1][3].Inventory, "Hotbar")

    local other = hero()
    fake.put(other.backpack, 5, "Stone", 2)
    engine.slot(other.backpack, 5, "added", "changed")
    frames(1)
    t.eq(#added, 1, "another player's backpack is not game.Me's")

    possess(other)
    pass(0.6)
    fake.set(other.backpack, 5, fake.STACK, 3)
    engine.slot(other.backpack, 5, "changed")
    frames(1)
    t.eq(#added, 2, "the character the player has now is the one listened to")
    t.eq(added[2][2], 1)
    fake.put(me.backpack, 5, "Stone", 1)
    engine.slot(me.backpack, 5, "added", "changed")
    frames(1)
    t.eq(#added, 2, "and the one it had is not")
    fake.take(me.backpack, 5)
    possess(me)
    pass(0.6)
    a:Disconnect()
    b:Disconnect()
    c:Disconnect()
    t.eq(items.stats().listened, 0)
    pass(0.6)
    t.eq(sched.Frame.count, 0)
    t.eq(world.dead_touches, 0)
end)

t.test("an inventory that cannot be read says so when a handler is connected, at the mod's line", function()
    local other = hero()
    other.backpack.store.CurrentWeight = nil
    local pack = instance.wrap(other.backpack.object)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        pack.ItemAdded:Connect(function() end)
    end, "this inventory cannot be read in this version of the game")
    at(err, line)
    t.eq(pack.ItemAdded.count, 0)
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        game.Me.ItemAdded:Connect("no function")
    end, "Connect expects a function, got string")
    at(err, line)
end)

t.test("a map change lets go of every inventory and character without touching one, and game.Me goes on with the next", function()
    local pack = me.instance.Backpack
    local old, note_old = recorder()
    local added, note_added = recorder()
    local hits, note_hit = recorder()
    local connection = pack.ItemAdded:Connect(note_old)
    local a, b = game.Me.ItemAdded:Connect(note_added), game.Me.Damaged:Connect(note_hit)
    local c = me.instance.Died:Connect(function() end)
    local left = me
    world.travel("World_Next")
    frames(2)
    t.eq(connection.Connected, false, "the handlers of an inventory that is gone are disconnected")
    t.eq(items.stats().listened, 0)
    pass(0.6)
    t.eq(world.dead_touches, 0, tostring(world.dead_where))
    t.eq(character.stats().told.waited_for, 0)
    me = hero()
    possess(me)
    pass(0.6)
    fake.put(me.backpack, 5, "Stone", 2)
    engine.slot(me.backpack, 5, "added", "changed")
    engine.damage(me, 5)
    frames(1)
    t.eq(#added, 1, "game.Me.ItemAdded tells of the new character's backpack")
    t.eq(#hits, 1)
    t.ok(rawequal(hits[1][1], me.instance))
    t.eq(#old, 0)
    t.raises(function() return left.instance.Damaged end, "no longer exists")
    a:Disconnect()
    b:Disconnect()
    c:Disconnect()
    fake.take(me.backpack, 5)
    me.state_store.Health = 300
    pass(0.6)
    t.eq(world.dead_touches, 0, tostring(world.dead_where))
    t.eq(sched.Frame.count, 0)
end)

t.test("none of the functions Wax reads values from is called by a blueprint of the build that was last looked at", function()
    local found = nil
    local list = io.popen('dir /b /s "build\\game-model\\blueprint_calls.lua" 2>nul')
    if list then
        found = list:read("l")
        list:close()
    end
    if not found or found == "" then return end
    local chunk = loadfile(found)
    t.ok(chunk, "the list compiles")
    local called = {}
    for path in pairs(chunk()) do called[path:lower()] = true end
    local paths = { character.DAMAGED }
    for _, path in pairs(character.TOLD) do paths[#paths + 1] = path end
    for _, path in ipairs(items.TOLD) do paths[#paths + 1] = path end
    for _, path in ipairs(paths) do
        t.ok(not called[path:lower()], path .. " is called by blueprints, so its values cannot be read")
    end
    t.eq(#paths, 8)
end)

t.test("without the game's item events an inventory is only looked at, and asking for them says why", function()
    -- as in a game started anew after an update that renamed one of the three functions
    Wax.modules["world.items"], Wax.modules["engine.hooks"] = nil, nil
    rawset(_G, "WaxHooks", nil)
    hooks = Wax.import("engine.hooks")
    engine.FUNCTIONS[SLOT.removed] = nil
    local before = warnings("wax.items")
    local lacking = Wax.import("world.items")
    lacking.start()
    local pack = me.instance.Backpack
    t.eq(pack:Count("Fiber"), 64, "counting works by looking")
    t.eq(warnings("wax.items"), before + 1)
    t.eq(lacking.stats().told, false)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        game.Me.ItemAdded:Connect(function() end)
    end, "cannot be told in this version of the game")
    at(err, line)
    t.raises(function() pack.ItemRemoved:Connect(function() end) end, "cannot be told in this version of the game")
    t.eq(hooks.stats().hooks[SLOT.added].listeners, 0, "the half-made set was taken back")
    engine.FUNCTIONS[SLOT.removed] = true
end)

t.test("nothing was handed back to the game, no error was recorded, and no name hides one of the game's", function()
    t.eq(engine.returned, 0)
    t.eq(engine.unregistered, 0)
    t.eq(world.dead_touches, 0, tostring(world.dead_where))
    t.eq(#Wax.import("engine.easy").clashes(), 0)
    t.eq(rawget(_G, "Enum_PropertyType"), nil)
    t.eq(rawget(_G, "Enum_CurrentAliveState"), nil)
end)

if arg and arg[1] == "cost" then
    local clock = os.clock
    local function time(label, rounds, fn)
        local started = clock()
        for _ = 1, rounds do fn() end
        print(("  %-58s %.2f us"):format(label, (clock() - started) / rounds * 1e6))
    end
    print("cost on the stand-in, in a tight loop:")
    time("a hooked function with nobody listening", 200000, function() engine.raise(TICK, thing, 1) end)
    local undo = hooks.listen(TICK, { reach = hooks.NET, catch = function() end })
    time("with one listener that tells nothing", 200000, function() engine.raise(TICK, thing, 1) end)
    undo()
    local c = game.Me.Damaged:Connect(function() end)
    local wolf = beast()
    time("damage to a character nobody asked about", 100000, function() engine.raise(DAMAGED, wolf.state, 1, {}, nil, wolf.actor) end)
    me.state_store.LastDamagePacket = { TotalDamage = 1, AppliedDamage = 1 }
    time("damage to the local character, caught and told", 20000, function()
        engine.raise(DAMAGED, me.state, 1, {}, nil, me.actor)
        Wax.import("engine.hooks").step()
    end)
    c:Disconnect()
end

t.finish("hooks")
