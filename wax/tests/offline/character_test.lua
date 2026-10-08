-- Offline tests for world.character: the fields every character and every player's character are given, game.Me, and
-- the signals of game.Me that are fed by looking. The engine is a stand-in in which an object that was freed raises on any use.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\character_test.lua
-- Add the word cost to print what a read, a find and a look take on the stand-in.

local t = dofile("wax/tests/offline/harness.lua")
local world = dofile("wax/tests/offline/fake_world.lua")
world.install()
local values = dofile("wax/tests/offline/fake_values.lua")
values.install(world)
local kit = world.icarus(values)
local actions = dofile("wax/tests/offline/fake_actions.lua")
actions.install(world, values, kit)

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)

local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local sched = Wax.import("core.sched")
local easy = Wax.import("engine.easy")
local instance = Wax.import("engine.instance")
local game_module = Wax.import("engine.game")
world.possess(nil)
actions.host(true)
game_module.start()
Wax.game = game_module.root
Wax.import("engine.actors").start()
local game = game_module.root
local task = sched.task

-- Frames of 16 ms on a clock the tests own.
local now, FRAME = 1000, 0.016
sched.clock = function() return now end
local function frames(count)
    for _ = 1, count or 1 do
        now = now + FRAME
        game_module.step()
        sched.step()
    end
end
local function pass(seconds) frames(math.ceil(seconds / FRAME) + 2) end

local function quiet() t.eq(sched.Frame.count, 0, "nothing is left on the frame signal") end

local function recorder()
    local seen = {}
    return seen, function(value, previous) seen[#seen + 1] = { value, previous } end
end

local function at(err, line, what)
    t.ok(tostring(err):find("character_test.lua:" .. line .. ":", 1, true),
        (what or "the error") .. " should name line " .. line .. ": " .. tostring(err))
end

local function biome(row) return { RowName = values.name(row), DataTableName = values.name("D_Biomes") } end

-- A player's character with its Instance.
local function hero(over)
    local who = kit.player(over)
    who.instance = instance.wrap(who.actor)
    return who
end

-- What the local player controls is looked for once a frame, so a change shows on the next one.
local function possess(who)
    world.possess(who and who.actor or nil)
    frames(1)
end

local touches, finds = world.touches, values.finds
local character = Wax.import("world.character")
character.start()

-- ------------------------------------------------------------------------------------------------ before a character

t.test("starting asks the engine nothing, puts nothing on the frame and does not load engine.watch", function()
    t.eq(world.touches, touches, "no engine object was touched")
    t.eq(values.finds, finds, "nothing was looked up by path")
    quiet()
    t.eq(Wax.modules["engine.watch"], nil)
    t.ok(rawequal(game.Me, character.me))
    t.ok(rawequal(game:GetService("Me"), game.Me))
    local listed = false
    for _, name in ipairs(game_module.names()) do listed = listed or name == "Me" end
    t.ok(listed, "game lists Me among its members")
    t.eq(character.UNPROVEN, false, "the switch is off as it ships")
end)

t.test("at the title screen game.Me says there is no character: fields are nil, functions and assignments raise", function()
    local me = game.Me
    t.eq(me.Exists, false)
    t.eq(me.Character, nil)
    t.eq(me.Health, nil)
    t.eq(me.Position, nil)
    t.eq(me.Food, nil)
    t.eq(me.RespawnCount, nil, "a name of the game's own is not known before a character was seen")
    t.eq(tostring(me), "game.Me (no character)")
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me:DistanceTo({ X = 0, Y = 0, Z = 0 })
    end, "there is no character right now, so DistanceTo cannot be called. game.Me.Exists says when there is one")
    at(err, line, "a call with no character")
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me.Health = 100
    end, "there is no character right now, so Health cannot be set")
    at(err, line, "an assignment with no character")
    t.raises(function() me.Exists = true end, "game.Me.Exists cannot be assigned")
    t.raises(function() me.HealthChanged = nil end, "game.Me.HealthChanged cannot be assigned")
    t.eq(me.HealthChanged.name, "game.Me.HealthChanged", "the signals are there with no character")
end)

t.test("a pawn that is not a player's character is not game.Me", function()
    local spectator = values.actor(kit.classes.SpectatorPawn, "SpectatorPawn_0", { Location = { 0, 0, 0 } })
    possess({ actor = spectator })
    t.ok(game.Character, "game.Character is that pawn")
    t.eq(game.Me.Exists, false)
    t.eq(game.Me.Health, nil)
    local wolf = kit.creature()
    possess(wolf)
    t.eq(game.Me.Exists, false, "a creature the controller holds is not the player's character either")
    possess(nil)
    t.eq(character.stats().characters, 0)
end)

-- ---------------------------------------------------------------------------------------------------------- fields

t.test("a player's character has the fields every character has, with the values the game holds", function()
    local who = hero()
    local me = who.instance
    t.eq(me.Health, 300)
    t.eq(math.type(me.Health), "integer")
    t.eq(me.MaxHealth, 300)
    t.eq(me.Armor, 0)
    t.eq(me.MaxArmor, 0)
    t.eq(me.Alive, true)
    t.eq(me.Stamina, 200)
    t.eq(me.MaxStamina, 200)
    t.eq(me.Level, 3)
    t.eq(me.XP, 25086)
    t.eq(me.Biome, "Conifer")
    t.eq(me.Temperature, 25.41)
    t.eq(me.MoveSpeed, 420)
    t.eq(me.Crouching, false)
    t.eq(me.Swimming, false)
    local spot, turn, speed = me.Position, me.Rotation, me.Velocity
    t.eq(spot.X, 154511.5625)
    t.eq(spot.Y, 184153.609375)
    t.eq(spot.Z, -24059.841796875)
    t.eq(turn.Pitch, 0)
    t.eq(turn.Yaw, 68.125)
    t.eq(turn.Roll, 0)
    t.eq(speed.X + speed.Y + speed.Z, 0)
    t.ok(not rawequal(me.Position, spot), "a position is a new plain table each time")
    t.eq(getmetatable(spot), nil)

    -- each read asks the game
    who.state_store.Health, who.state_store.CurrentAliveState = 0, 1
    who.state_store.CurrentBiome = biome("Arctic")
    who.state_store.ModifiedExternalTemperature = -1250
    who.movement_store.MovementMode, who.movement_store.MaxWalkSpeed = 4, 159
    who.movement_store.Velocity = { X = 100, Y = -50, Z = 0 }
    who.store.bIsCrouched = true
    t.eq(me.Health, 0)
    t.eq(me.Alive, false)
    t.eq(me.Biome, "Arctic")
    t.eq(me.Temperature, -12.5)
    t.eq(me.Swimming, true)
    t.eq(me.MoveSpeed, 159)
    t.eq(me.Velocity.Y, -50)
    t.eq(me.Crouching, true)
    who.state_store.CurrentBiome = biome("None")
    t.eq(me.Biome, nil, "no row is no biome")
end)

t.test("a player's character has more: food, water, oxygen, radiation, body temperature, weight, name", function()
    local who = hero()
    local me = who.instance
    t.eq(me.Food, 285)
    t.eq(me.MaxFood, 300)
    t.eq(me.Water, 278)
    t.eq(me.MaxWater, 300)
    t.eq(me.Oxygen, 288)
    t.eq(me.MaxOxygen, 300)
    t.eq(me.Radiation, 0)
    t.eq(me.MaxRadiation, 1000)
    t.eq(me.BodyTemperature, 25.41)
    t.eq(me.Weight, 1.17, "grams in the game, kilograms here")
    t.eq(me.MaxWeight, 100)
    t.eq(math.type(me.MaxWeight), "integer")
    t.eq(me.PlayerName, "Player One")
    t.eq(me.InCave, false)
    t.eq(me.Local, false, "nobody controls this one")
    who.store.CurrentWeight, who.store.InCave = 101500, true
    who.stats_store.Stats["WeightCapacity_+"] = 150
    who.player_state_store.PlayerNamePrivate = world.string("")
    t.eq(me.Weight, 101.5)
    t.eq(me.MaxWeight, 150)
    t.eq(me.InCave, true)
    t.eq(me.PlayerName, nil, "an empty name is no name yet")
    who.stats_store.Stats["WeightCapacity_+"] = nil
    t.eq(me.MaxWeight, 0, "a stat the character does not have is 0, as the game answers")
    possess(who)
    t.eq(me.Local, true)
    possess(nil)
end)

t.test("a creature has the fields of every character and none of a player's", function()
    local who = kit.creature({ at = { 100, 200, 300 }, facing = { 0, 90, 0 } })
    local wolf = instance.wrap(who.actor)
    t.eq(wolf.Health, 102)
    t.eq(wolf.MaxHealth, 102)
    t.eq(wolf.Armor, 0)
    t.eq(wolf.Stamina, 100)
    t.eq(wolf.Level, 16)
    t.eq(wolf.XP, 0)
    t.eq(wolf.Alive, true)
    t.eq(wolf.MoveSpeed, 440)
    t.eq(wolf.Biome, "Conifer")
    t.eq(wolf.Position.Y, 200)
    t.eq(wolf.Rotation.Yaw, 90)
    local err = t.raises(function() return wolf.Food end, "Food is not a member of BP_NPC_Wolf_Conifer_Character_C")
    t.ok(not tostring(err):find("character.lua", 1, true), tostring(err))
    t.raises(function() return wolf.PlayerName end, "PlayerName is not a member of BP_NPC_Wolf_Conifer_Character_C")
    t.raises(function() return wolf.Local end, "Local is not a member")
    local names = {}
    for _, name in ipairs(wolf:GetMembers()) do names[name] = true end
    t.ok(names.Health and names.Position and names.DistanceTo, "the names Wax gives are among the members")
    t.ok(not names.Food, "a player's are not")
    t.ok(names.CurrentLevel, "the game's own stay")
end)

t.test("a field that has no setter cannot be assigned, and the error names the mod's line", function()
    local who = kit.creature()
    local wolf = instance.wrap(who.actor)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        wolf.MaxHealth = 5
    end, "MaxHealth is read-only")
    at(err, line)
    t.eq(who.state_store.MaxHealth, 102)
    t.raises(function() wolf.Position = { X = 0, Y = 0, Z = 0 } end, "Position is read-only")
    t.raises(function() wolf.DistanceTo = 1 end, "DistanceTo is read-only")
end)

t.test("a character that sits on something gives its place in the world, not its place on the seat", function()
    local who, mount = hero(), kit.creature({ at = { 154000, 184000, -24000 } })
    kit.seat(who, mount)
    t.eq(values.plain(who.root_store.RelativeLocation).Z, 90, "the root holds the place on the seat")
    local spot, turn = who.instance.Position, who.instance.Rotation
    t.eq(spot.X, 154511.5625)
    t.eq(spot.Z, -24059.841796875)
    t.eq(turn.Yaw, 68.125)
    kit.move(who, 1, 2, 3)
    t.eq(who.instance.Position.Y, 2)
end)

t.test("DistanceTo measures in metres to an actor, to game.Me and to a position", function()
    local who = hero()
    local near = kit.creature({ at = { 154511.5625 + 5300, 184153.609375, -24059.841796875 } })
    local wolf = instance.wrap(near.actor)
    t.eq(who.instance:DistanceTo(wolf), 53)
    t.eq(wolf:DistanceTo(who.instance), 53)
    t.eq(wolf:DistanceTo(wolf), 0)
    t.eq(wolf:DistanceTo({ X = 154511.5625 + 5300, Y = 184153.609375 + 300, Z = -24059.841796875 + 400 }), 5)
    possess(who)
    t.eq(wolf:DistanceTo(game.Me), 53)
    t.eq(game.Me:DistanceTo(wolf), 53)
    possess(nil)
end)

t.test("DistanceTo says what it takes, at the mod's line, and never touches a target that is gone", function()
    local who = hero()
    local near = kit.creature()
    local wolf = instance.wrap(near.actor)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        wolf:DistanceTo(5)
    end, "DistanceTo expects an actor, game.Me or a position such as { X = 0, Y = 0, Z = 0 }, got number")
    at(err, line)
    t.raises(function() wolf:DistanceTo({ X = 1, Y = 2 }) end, "DistanceTo expects an actor, game.Me or a position")
    t.raises(function() wolf:DistanceTo() end, "got nil")
    t.raises(function() wolf:DistanceTo(who.instance.ActorState) end,
        "DistanceTo expects an actor, and a PlayerCharacterState is not one. Give the actor it belongs to")
    t.raises(function() wolf:DistanceTo(game.Me) end, "DistanceTo: there is no character right now, so there is nothing to measure to")
    t.raises(function() wolf.DistanceTo({ X = 0, Y = 0, Z = 0 }) end, "call DistanceTo with a colon")
    world.destroy(who.actor)
    world.free(who.actor)
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        wolf:DistanceTo(who.instance)
    end, "DistanceTo: that BP_IcarusPlayerCharacterSurvival_C no longer exists")
    at(err, line)
    t.eq(world.dead_touches, 0, world.dead_where)
end)

t.test("a character without a state, a stat container or a member reads nil, not an error", function()
    local who = kit.station({ at = { 10, 20, 30 } })
    local pawn = instance.wrap(who.actor)
    t.ok(pawn:IsA("IcarusPlayerCharacter"))
    for _, name in ipairs({ "Health", "MaxHealth", "Armor", "Alive", "Stamina", "Level", "XP", "Biome", "Temperature",
        "Food", "Water", "Oxygen", "Radiation", "BodyTemperature", "Weight", "MaxWeight", "InCave" }) do
        t.eq(pawn[name], nil, name)
    end
    t.eq(pawn.Position.Z, 30)
    t.eq(pawn.MoveSpeed, 300)
    t.eq(pawn.Crouching, false)
    t.eq(pawn.PlayerName, "Player One")

    local full = hero()
    local me = full.instance
    full.state_store.CurrentBiome = nil
    full.state_store.FoodLevel = nil
    full.state_store.ModifiedInternalTemperature = nil
    full.store.CurrentWeight = nil
    full.store.CharacterMovement = nil
    full.store.PlayerState = nil
    full.store.bIsCrouched = nil
    t.eq(me.Biome, nil)
    t.eq(me.Food, nil)
    t.eq(me.BodyTemperature, nil)
    t.eq(me.Weight, nil)
    t.eq(me.Velocity, nil)
    t.eq(me.MoveSpeed, nil)
    t.eq(me.Swimming, nil)
    t.eq(me.PlayerName, nil)
    t.eq(me.Crouching, nil)
    t.eq(me.Health, 300, "what is there still reads")
    full.store.ActorState = world.INVALID
    t.eq(me.Health, nil)
    t.eq(me.Alive, nil)
    full.store.RootComponent = world.INVALID
    t.eq(me.Position.X, 154511.5625, "with no root the game is asked for the place")
    t.eq(#guard.errors(), 0)
end)

t.test("a character that left the world answers with an error and is never touched again", function()
    local who = kit.creature()
    local wolf = instance.wrap(who.actor)
    t.eq(wolf.Health, 102)
    world.destroy(who.actor)
    world.free(who.actor)
    t.raises(function() return wolf.Health end, "this BP_NPC_Wolf_Conifer_Character_C no longer exists")
    t.raises(function() return wolf.Position end, "no longer exists")
    t.raises(function() return wolf:DistanceTo({ X = 0, Y = 0, Z = 0 }) end, "no longer exists")
    t.eq(world.dead_touches, 0, world.dead_where)
end)

t.test("no name Wax gives hides a member of the game's own, and every class it gives to has been met", function()
    t.eq(#easy.clashes(), 0)
    t.eq(#easy.stats().unseen, 0, table.concat(easy.stats().unseen, ", "))
end)

-- --------------------------------------------------------------------------------------------------------- game.Me

t.test("with a character game.Me has its fields, its functions and the game's own members", function()
    local who = hero()
    possess(who)
    local me = game.Me
    t.eq(me.Exists, true)
    t.ok(rawequal(me.Character, who.instance), "the Instance itself")
    t.ok(rawequal(me.Character, game.Character))
    t.eq(me.Health, 300)
    t.eq(me.Food, 285)
    t.eq(me.Weight, 1.17)
    t.eq(me.Local, true)
    t.eq(me.Position.X, 154511.5625)
    t.eq(me.Name, who.name)
    t.eq(me.ClassName, "BP_IcarusPlayerCharacterSurvival_C")
    t.eq(me.RespawnCount, 17, "a property of the game's own")
    t.eq(me:GetIsInCave(), false, "a function of the game's own")
    t.eq(me:IsA("IcarusCharacter"), true, "what every Instance can do")
    t.eq(me:DistanceTo({ X = 154511.5625, Y = 184153.609375, Z = -24059.841796875 + 250 }), 2.5)
    t.ok(rawequal(me.DistanceTo, me.DistanceTo), "a function of game.Me is one function")
    t.ok(tostring(me):find("game.Me (BP_IcarusPlayerCharacterSurvival_C", 1, true), tostring(me))
    local names = {}
    for _, name in ipairs(getmetatable(me).__names()) do names[name] = true end
    t.ok(names.Exists and names.HealthChanged and names.Health and names.RespawnCount, "its names, for the command bar")
    possess(nil)
end)

t.test("a wrong name on game.Me raises at the mod's line with the nearest name, a signal's among them", function()
    local who = hero()
    possess(who)
    local me = game.Me
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        return me.Helth
    end, "Helth is not a member of game.Me.")
    at(err, line)
    t.ok(tostring(err):find("'Health'", 1, true), tostring(err))
    err = t.raises(function() return me.HelthChanged end, "HelthChanged is not a member of game.Me.")
    t.ok(tostring(err):find("'HealthChanged'", 1, true), tostring(err))
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me:DistanceTo("there")
    end, "DistanceTo expects an actor, game.Me or a position")
    at(err, line, "what a function of the character raises")
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me.MaxHealth = 5
    end, "MaxHealth is read-only")
    at(err, line, "what an assignment raises")
    t.ok(not tostring(err):find("character.lua", 1, true), tostring(err))
    t.raises(function() me.Helth = 5 end, "Helth is not a property of BP_IcarusPlayerCharacterSurvival_C")

    -- once a character was seen, its names are known with no character too
    possess(nil)
    t.eq(me.RespawnCount, nil, "a property reads nil")
    t.eq(me.Health, nil)
    t.raises(function() me:GetIsInCave() end, "there is no character right now, so GetIsInCave cannot be called")
    err = t.raises(function() return me.Helth end, "Helth is not a member of game.Me.")
    t.ok(tostring(err):find("'Health'", 1, true), tostring(err))
end)

t.test("the character is looked for once a frame, however much is read", function()
    local who = hero()
    possess(who)
    frames(1)
    local me = game.Me
    world.watch = {}
    local total = me.Health + me.Food + me.Water + me.Position.X + me:DistanceTo({ X = 0, Y = 0, Z = 0 })
    t.ok(total > 0 and me.Exists)
    t.eq(world.watch.Pawn, 1, "the controller was asked for its pawn once")
    frames(1)
    t.eq(me.Health, 300)
    t.eq(world.watch.Pawn, 2, "and once more on the next frame")
    world.watch = nil
    local had = character.stats().finds
    frames(20)
    t.eq(character.stats().finds, had, "nothing is looked for while nothing is read")
    possess(nil)
end)

t.test("game.Me goes on working after a respawn, as the same actor or as a new one", function()
    local who = hero()
    possess(who)
    local me = game.Me
    kit.kill(who)
    t.eq(me.Alive, false)
    t.eq(me.Health, 0)
    kit.revive(who)
    t.eq(me.Alive, true)
    t.eq(me.RespawnCount, 18)

    -- the engine takes a destroyed pawn off its controller before the memory goes
    kit.kill(who)
    world.destroy(who.actor)
    world.possess(nil)
    world.free(who.actor)
    t.eq(me.Exists, false, "the one that was destroyed is not asked again, in the same frame")
    local again = hero({ state = { Health = 150 } })
    possess(again)
    t.eq(me.Health, 150)
    t.ok(rawequal(me.Character, again.instance))
    t.eq(world.dead_touches, 0, world.dead_where)
    possess(nil)
end)

t.test("game.Me goes on working on another map, and nothing of the old map is touched", function()
    local who = hero()
    possess(who)
    local me = game.Me
    t.eq(me.Health, 300)
    world.travel("Terrain_017")
    t.eq(me.Exists, false)
    frames(1)
    t.eq(me.Health, nil)
    t.raises(function() me:DistanceTo({ X = 0, Y = 0, Z = 0 }) end, "there is no character right now")
    local next_one = hero({ state = { Health = 220 } })
    possess(next_one)
    t.eq(me.Health, 220)
    t.eq(me.Biome, "Conifer")

    -- a map change in which no actor was seen leaving
    world.travel("Terrain_018", true)
    frames(1)
    t.eq(me.Exists, false)
    t.eq(me.Health, nil)
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(#guard.errors(), 0)
end)

-- --------------------------------------------------------------------------------------------------------- signals

t.test("no signal is looked at until a handler connects, and the last one to leave ends the looking at once", function()
    local who = hero()
    possess(who)
    quiet()
    world.watch = {}
    frames(63)
    t.eq(world.watch.Pawn, nil, "nobody asked for the character")
    t.eq(world.watch.Health, nil)
    local seen, note = recorder()
    local connection = game.Me.HealthChanged:Connect(note)
    t.ok(Wax.modules["engine.watch"], "the first handler loaded engine.watch")
    t.eq(sched.Frame.count, 1)
    t.eq(world.watch.Health, 1, "one look when the first handler connects, to take note")
    world.watch = {}
    frames(63)
    t.eq(world.watch.Health, 10, "ten looks a second")
    t.eq(world.watch.Pawn, 10, "and one find of the character for each")
    t.eq(#seen, 0)
    who.state_store.Health = 250
    pass(0.2)
    t.eq(#seen, 1)
    t.eq(seen[1][1], 250)
    t.eq(seen[1][2], 300)
    who.state_store.Health = 260
    who.state_store.Health = 250
    pass(0.2)
    t.eq(#seen, 1, "what changed and changed back between two looks is not seen")
    connection:Disconnect()
    quiet()
    world.watch = {}
    who.state_store.Health = 100
    frames(63)
    t.eq(world.watch.Health, nil, "nothing is read once nobody listens")
    t.eq(world.watch.Pawn, nil)
    t.eq(#seen, 1)
    world.watch = nil
    local stats = character.stats().signals.Health
    t.eq(stats.handlers, 0)
    t.eq(stats.looking, false)
    possess(nil)
end)

t.test("signals looked at in the same frames share one find of the character", function()
    local who = hero()
    possess(who)
    quiet()
    local first = game.Me.HealthChanged:Connect(function() end)
    local second = game.Me.StaminaChanged:Connect(function() end)
    local third = game.Me.HealthChanged:Connect(function() end)
    world.watch = {}
    frames(63)
    t.eq(world.watch.Pawn, 10)
    t.eq(world.watch.Health, 10, "two handlers on one signal are one look")
    t.eq(world.watch.Stamina, 10)
    world.watch = nil
    t.eq(character.stats().signals.Health.handlers, 2)
    first:Disconnect()
    second:Disconnect()
    t.eq(sched.Frame.count, 1, "a handler is left")
    third:Disconnect()
    quiet()
    possess(nil)
end)

t.test("food, water, oxygen, stamina, weight and biome fire with the new value and the one before", function()
    local who = hero()
    possess(who)
    local seen, me = {}, game.Me
    local function note(what)
        return function(value, previous) seen[#seen + 1] = ("%s %s after %s"):format(what, tostring(value), tostring(previous)) end
    end
    local connections = {
        me.FoodChanged:Connect(note("food")), me.WaterChanged:Connect(note("water")), me.OxygenChanged:Connect(note("oxygen")),
        me.StaminaChanged:Connect(note("stamina")), me.WeightChanged:Connect(note("weight")), me.BiomeChanged:Connect(note("biome")),
    }
    pass(1)
    t.eq(#seen, 0, "nothing changed")
    who.state_store.FoodLevel, who.state_store.WaterLevel, who.state_store.OxygenLevel = 284, 277, 287
    who.state_store.Stamina = 150
    who.store.CurrentWeight = 1210
    who.state_store.CurrentBiome = biome("Arctic")
    pass(1)
    table.sort(seen)
    t.eq(table.concat(seen, ", "), "biome Arctic after Conifer, food 284 after 285, oxygen 287 after 288, stamina 150 after 200, "
        .. "water 277 after 278, weight 1.21 after 1.17")
    who.state_store.CurrentBiome = biome("None")
    who.state_store.FoodLevel = nil
    pass(1)
    t.eq(#seen, 6, "a value the game does not give for a moment is not a change")
    who.state_store.CurrentBiome = biome("Desert")
    who.state_store.FoodLevel = 283
    pass(1)
    table.sort(seen)
    t.eq(#seen, 8)
    t.eq(seen[2], "biome Desert after Arctic")
    t.eq(seen[3], "food 283 after 284")
    for _, connection in ipairs(connections) do connection:Disconnect() end
    quiet()
    possess(nil)
end)

t.test("LevelUp and XPGained are about one character: another one with more is not a gain", function()
    local who = hero()
    possess(who)
    local seen, me = {}, game.Me
    local level = me.LevelUp:Connect(function(new, old) seen[#seen + 1] = ("level %d after %d"):format(new, old) end)
    local gained = me.XPGained:Connect(function(amount, total) seen[#seen + 1] = ("xp %d of %d"):format(amount, total) end)
    pass(0.5)
    who.state_store.TotalExperience = 25111
    pass(0.5)
    t.eq(table.concat(seen, ", "), "xp 25 of 25111")
    who.state_store.TotalExperience, who.state_store.Level = 32600, 4
    pass(0.5)
    table.sort(seen)
    t.eq(table.concat(seen, ", "), "level 4 after 3, xp 25 of 25111, xp 7489 of 32600")
    who.state_store.TotalExperience, who.state_store.Level = 30000, 3
    pass(0.5)
    t.eq(#seen, 3, "less is not a gain")

    local veteran = hero({ state = { Level = 20, TotalExperience = 900000 } })
    possess(veteran)
    pass(0.5)
    t.eq(#seen, 3, "another character")
    veteran.state_store.Level, veteran.state_store.TotalExperience = 21, 900500
    pass(0.5)
    table.sort(seen)
    t.eq(seen[1], "level 21 after 20")
    t.eq(seen[4], "xp 500 of 900500")
    level:Disconnect()
    gained:Disconnect()
    quiet()
    possess(nil)
end)

t.test("Respawned fires when the character is alive after it was dead, as the same actor or as a new one", function()
    local who = hero()
    possess(who)
    local events, me = {}, game.Me
    local connections = {
        me.Respawned:Connect(function(one) events[#events + 1] = { "respawned", one } end),
        me.Spawned:Connect(function(one) events[#events + 1] = { "spawned", one } end),
        me.Despawned:Connect(function() events[#events + 1] = { "despawned" } end),
    }
    pass(0.5)
    t.eq(#events, 0, "the character that is there when a handler connects is not announced")
    kit.kill(who)
    pass(0.3)
    t.eq(#events, 0, "dying is not respawning")
    kit.revive(who)
    pass(0.3)
    t.eq(#events, 1)
    t.eq(events[1][1], "respawned")
    t.ok(rawequal(events[1][2], who.instance), "with the character")

    -- dead, gone for a moment, then another actor
    kit.kill(who)
    pass(0.3)
    world.destroy(who.actor)
    world.possess(nil)
    world.free(who.actor)
    pass(0.3)
    t.eq(#events, 2)
    t.eq(events[2][1], "despawned")
    local again = hero()
    possess(again)
    pass(0.3)
    t.eq(#events, 4)
    t.eq(events[3][1], "spawned")
    t.ok(rawequal(events[3][2], again.instance))
    t.eq(events[4][1], "respawned")
    t.ok(rawequal(events[4][2], again.instance))
    t.eq(world.dead_touches, 0, world.dead_where)
    for _, connection in ipairs(connections) do connection:Disconnect() end
    quiet()
    possess(nil)
end)

t.test("when another character takes the place at once, Despawned comes first and Spawned after it", function()
    local who, other = hero(), hero()
    possess(who)
    local events, me = {}, game.Me
    local spawned = me.Spawned:Connect(function(one) events[#events + 1] = "spawned " .. one.Name end)
    local despawned = me.Despawned:Connect(function() events[#events + 1] = "despawned" end)
    local respawned = me.Respawned:Connect(function() events[#events + 1] = "respawned" end)
    pass(0.3)
    possess(other)
    pass(0.3)
    t.eq(table.concat(events, ", "), "despawned, spawned " .. other.name)
    spawned:Disconnect()
    despawned:Disconnect()
    respawned:Disconnect()
    quiet()
    possess(nil)
end)

t.test("connected at the title screen, nothing fires until there is a character, and its first values are where it starts", function()
    possess(nil)
    quiet()
    local events, me = {}, game.Me
    local connections = {
        me.Spawned:Connect(function(one) events[#events + 1] = "spawned " .. one.ClassName end),
        me.Respawned:Connect(function() events[#events + 1] = "respawned" end),
        me.HealthChanged:Connect(function(value, previous) events[#events + 1] = ("health %s after %s"):format(tostring(value), tostring(previous)) end),
        me.LevelUp:Connect(function() events[#events + 1] = "level" end),
        me.BiomeChanged:Connect(function() events[#events + 1] = "biome" end),
    }
    world.watch = {}
    pass(1)
    t.eq(#events, 0)
    t.ok(world.watch.Pawn, "the controller is asked")
    t.eq(world.watch.Health, nil, "and nothing else")
    world.watch = nil
    local who = hero()
    possess(who)
    pass(1)
    t.eq(table.concat(events, ", "), "spawned BP_IcarusPlayerCharacterSurvival_C")
    who.state_store.Health = 290
    pass(0.2)
    t.eq(events[2], "health 290 after 300")
    for _, connection in ipairs(connections) do connection:Disconnect() end
    quiet()
    possess(nil)
end)

t.test("the signals stay connected across a map change, and nothing of the old map is touched", function()
    local who = hero()
    possess(who)
    local events, me = {}, game.Me
    local connections = {
        me.HealthChanged:Connect(function(value, previous) events[#events + 1] = ("health %d after %d"):format(value, previous) end),
        me.Spawned:Connect(function() events[#events + 1] = "spawned" end),
        me.Despawned:Connect(function() events[#events + 1] = "despawned" end),
        me.LevelUp:Connect(function() events[#events + 1] = "level" end),
        me.FoodChanged:Connect(function() events[#events + 1] = "food" end),
    }
    pass(0.5)
    world.travel("Terrain_019")
    pass(0.6)
    t.eq(table.concat(events, ", "), "despawned")
    t.eq(world.dead_touches, 0, world.dead_where)
    local next_one = hero({ state = { Health = 250, Level = 9 } })
    possess(next_one)
    pass(0.6)
    table.sort(events)
    t.eq(table.concat(events, ", "), "despawned, health 250 after 300, spawned", "a higher level on another character is no level up")
    for _, connection in ipairs(connections) do t.eq(connection.Connected, true) end

    world.travel("Terrain_020", true)
    pass(0.6)
    t.eq(events[#events], "despawned", "also when no actor was seen leaving")
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(#guard.errors(), 0)
    for _, connection in ipairs(connections) do connection:Disconnect() end
    quiet()
end)

t.test("a mod's handler goes with the mod, and the looking goes on for the others", function()
    local who = hero()
    possess(who)
    quiet()
    local first, second = scope.new("FirstMod"), scope.new("SecondMod")
    local got = {}
    local mine = scope.run(first, function()
        return game.Me.HealthChanged:Connect(function(value) got[#got + 1] = "first " .. value end)
    end)
    scope.run(second, function() game.Me.HealthChanged:Connect(function(value) got[#got + 1] = "second " .. value end) end)
    t.eq(first:size(), 1, "a mod owns its own connection and nothing else")
    first:destroy()
    t.eq(mine.Connected, false)
    t.eq(sched.Frame.count, 1)
    who.state_store.Health = 200
    pass(0.2)
    t.eq(table.concat(got, ", "), "second 200")
    second:destroy()
    quiet()
    t.eq(Wax.import("engine.watch").stats().watching, 0)
    possess(nil)
end)

t.test("Once and Wait look only until they are done, and DisconnectAll ends the looking", function()
    local who = hero()
    possess(who)
    quiet()
    local once
    game.Me.FoodChanged:Once(function(value, previous) once = value .. " after " .. previous end)
    t.eq(sched.Frame.count, 1)
    who.state_store.FoodLevel = 280
    pass(0.5)
    t.eq(once, "280 after 285")
    quiet()
    local waited
    task.spawn(function() waited = table.pack(game.Me.FoodChanged:Wait()) end)
    t.eq(sched.Frame.count, 1)
    who.state_store.FoodLevel = 270
    pass(0.5)
    t.eq(waited[1], 270)
    t.eq(waited[2], 280)
    quiet()
    game.Me.WaterChanged:Connect(function() end)
    game.Me.WaterChanged:Connect(function() end)
    t.eq(sched.Frame.count, 1)
    game.Me.WaterChanged:DisconnectAll()
    quiet()
    t.raises(function() game.Me.WaterChanged:Connect("handler") end, "Connect expects a function, got string")
    quiet()
    possess(nil)
end)

-- ------------------------------------------------------------------------------------------- the place for other modules

t.test("another module gives characters more through character.extend, and game.Me has it at once", function()
    actions.host(true)
    local who = hero()
    local wolf_parts = kit.creature()
    local wolf = instance.wrap(wolf_parts.actor)
    possess(who)
    local healed
    local undo = character.extend("character", {
        fields = { Mood = function(_, raw) return raw.ActorState.Health > 100 and "fine" or "hurt" end },
        setters = { Health = function(_, raw, value) raw.ActorState.Health = value end },
        methods = { Heal = function(self, _, amount)
            healed = self.ClassName .. " " .. amount
            return amount * 2
        end },
    }, "character_test")
    local undo_player = character.extend("player", { fields = { Hunger = function(self) return self.MaxFood - self.Food end } }, "character_test")
    t.eq(wolf.Mood, "fine")
    wolf.Health = 40
    t.eq(wolf_parts.state_store.Health, 40)
    t.eq(wolf.Mood, "hurt")
    t.eq(game.Me.Mood, "fine")
    game.Me.Health = 90
    t.eq(who.state_store.Health, 90)
    t.eq(game.Me:Heal(5), 10)
    t.eq(healed, "BP_IcarusPlayerCharacterSurvival_C 5")
    t.eq(game.Me.Hunger, 15)
    t.raises(function() return wolf.Hunger end, "Hunger is not a member of BP_NPC_Wolf_Conifer_Character_C")
    possess(nil)
    t.eq(game.Me.Mood, nil)
    t.raises(function() game.Me:Heal(5) end, "there is no character right now, so Heal cannot be called")
    t.raises(function() character.extend("creature", {}) end, "the kind is \"character\" or \"player\", got creature")

    undo()
    undo_player()
    possess(who)
    t.raises(function() return game.Me.Mood end, "Mood is not a member of game.Me.")
    t.eq(game.Me:Heal(1), 91, "the module's own Heal is back")
    t.eq(healed, "BP_IcarusPlayerCharacterSurvival_C 5", "and the one that was taken out is not called")
    wolf.Health = 1
    t.eq(wolf_parts.state_store.Health, 1, "the module's own setter is back")
    t.eq(game.Me.Health, 91)
    possess(nil)
end)

t.test("another module gives game.Me a signal of its own, or a value to look at with the signals it feeds", function()
    local who = hero()
    possess(who)
    local damaged = sched.Signal.new("game.Me.Damaged")
    character.provide("Damaged", damaged)
    t.ok(rawequal(game.Me.Damaged, damaged))
    t.raises(function() game.Me.Damaged = nil end, "game.Me.Damaged cannot be assigned")
    t.raises(function() character.provide("damaged", damaged) end, "a name that starts with a capital letter")
    t.raises(function() character.provide("Hit") end, "character.provide expects a value for game.Me.Hit")

    local made = character.feed({ name = "Jumps", every = 0.1, read = function(_, raw) return raw.JumpMaxCount end, outlets = {
        { "JumpsChanged", function(signal, value, previous)
            if previous then signal:Fire(value, previous) end
        end },
    } })
    t.ok(rawequal(game.Me.JumpsChanged, made.JumpsChanged))
    quiet()
    local seen, note = recorder()
    local connection = game.Me.JumpsChanged:Connect(note)
    who.store.JumpMaxCount = 3
    pass(0.2)
    t.eq(#seen, 1)
    t.eq(seen[1][1], 3)
    t.eq(seen[1][2], 1)
    connection:Disconnect()
    quiet()
    t.raises(function() character.feed({ name = "Broken" }) end, "character.feed expects")
    possess(nil)
end)

-- ------------------------------------------------------------------------------------------------------ the switch

t.test("what was never read in the game is behind the switch: the fields on an IcarusPawn, and Sprinting", function()
    local worm_parts = kit.worm({ at = { 5, 6, 7 } })
    local wolf_parts = kit.creature({ actor = { bIsSprinting = true } })
    local worm, wolf = instance.wrap(worm_parts.actor), instance.wrap(wolf_parts.actor)
    t.raises(function() return worm.Health end, "Health is not a member of BP_CRE_CaveWorm_C")
    t.raises(function() return wolf.Sprinting end, "Sprinting is not a member of BP_NPC_Wolf_Conifer_Character_C")

    local lone = t.new_wax()
    lone.import("engine.game").start()
    local lone_character = lone.import("world.character")
    lone_character.UNPROVEN = true
    lone_character.start()
    local lone_instance = lone.import("engine.instance")
    local lone_worm, lone_wolf = lone_instance.wrap(worm_parts.actor), lone_instance.wrap(wolf_parts.actor)
    t.eq(lone_worm.Health, 450)
    t.eq(lone_worm.MaxHealth, 450)
    t.eq(lone_worm.Alive, true)
    t.eq(lone_worm.Level, 10, "an IcarusPawn keeps its level on the actor")
    t.eq(lone_worm.Biome, "Conifer")
    t.eq(lone_worm.Position.Z, 7)
    t.eq(lone_worm:DistanceTo({ X = 5, Y = 6, Z = 107 }), 1)
    for _, name in ipairs({ "Stamina", "XP", "Velocity", "MoveSpeed", "Crouching", "Swimming", "Sprinting" }) do
        t.eq(lone_worm[name], nil, name .. " is something an IcarusPawn does not have")
    end
    t.eq(lone_wolf.Sprinting, true)
    t.eq(lone_wolf.Level, 16)
    t.eq(#lone.import("engine.easy").clashes(), 0)
end)

t.test("when engine.watch cannot be loaded a signal says so at the mod's line, and the fields work as before", function()
    local lone = t.new_wax()
    local import = lone.import
    ---@diagnostic disable-next-line: duplicate-set-field
    lone.import = function(name)
        if name == "engine.watch" then error("wax module 'engine.watch' failed while loading:\nit is broken", 0) end
        return import(name)
    end
    lone.import("engine.game").start()
    lone.import("world.character").start()
    local me = lone.import("engine.game").root.Me
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me.HealthChanged:Connect(function() end)
    end, "the signals of game.Me need engine.watch, which did not load")
    at(err, line)
    t.ok(tostring(err):find("it is broken", 1, true), tostring(err))
    t.eq(me.HealthChanged.count, 0, "nothing was connected")
    t.eq(lone.import("engine.instance").wrap(kit.player().actor).Health, 300)
end)

-- ------------------------------------------------------------------------------------- what the host does to a character

-- How often the game's own functions were called so far, to see that a refusal called none.
local function asked()
    local total = 0
    for _, count in pairs(actions.calls) do total = total + count end
    return total
end

t.test("the host assigns Health and Stamina on any character, and they are set with the game's own functions", function()
    actions.host(true)
    local silent, calls = values.silent, actions.calls.SetHealth or 0
    local who = kit.creature()
    local wolf = instance.wrap(who.actor)
    wolf.Health = 40
    t.eq(who.state_store.Health, 40)
    t.eq(wolf.Health, 40, "it reads back at once")
    t.eq(actions.calls.SetHealth, calls + 1)
    wolf.Health = 40
    t.eq(actions.calls.SetHealth, calls + 1, "the value it has already is not set again")
    wolf.Health = 60.4
    t.eq(who.state_store.Health, 60, "a fraction is rounded")
    t.eq(math.type(who.state_store.Health), "integer")
    wolf.Health = 5000
    t.eq(who.state_store.Health, 102, "no more than the most it can have")
    wolf.Stamina = 0
    t.eq(who.state_store.Stamina, 0)
    wolf.Stamina = -20
    t.eq(who.state_store.Stamina, 0, "and no less than nothing")
    wolf.Stamina = 55
    t.eq(wolf.Stamina, 55)
    t.eq(values.silent, silent, "every number arrived as the whole number the game takes")
end)

t.test("Health below 1, a value that is no number and a dead character are refused at the mod's line, and nothing is set", function()
    actions.host(true)
    local who = kit.creature()
    local wolf = instance.wrap(who.actor)
    local before = asked()
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        wolf.Health = 0
    end, "Health cannot be set below 1. To kill a character call Kill()")
    at(err, line)
    t.raises(function() wolf.Health = "full" end, "Health expects a number, got string")
    t.raises(function() wolf.Health = 0 / 0 end, "Health expects a number")
    t.raises(function() wolf.Health = math.huge end, "Health expects a number")
    t.raises(function() wolf.Stamina = wolf end, "Stamina expects a number, got an Instance")
    t.eq(who.state_store.Health, 102)
    kit.kill(who)
    t.raises(function() wolf.Health = 50 end, "this character is dead, so its Health cannot be set")
    t.raises(function() wolf.Stamina = 50 end, "this character is dead, so its Stamina cannot be set")
    t.eq(asked(), before, "the game was asked for nothing")
    t.eq(who.state_store.Health, 0)
    local pawn = instance.wrap(kit.station().actor)
    t.raises(function() pawn.Health = 5 end, "Health: this BP_IcarusPlayerCharacterSpace_C has no state of the kind the game keeps health in")
    t.raises(function() pawn:Heal() end, "Heal: this BP_IcarusPlayerCharacterSpace_C has no state")
    t.raises(function() pawn:Kill() end, "Kill: this BP_IcarusPlayerCharacterSpace_C has no state")
end)

t.test("a player's character also takes Food, Water and Oxygen, and game.Me sets them on whoever it is", function()
    actions.host(true)
    local silent = values.silent
    local who = hero()
    possess(who)
    local me = game.Me
    me.Food, me.Water, me.Oxygen = 100, 150.6, 9999
    t.eq(who.state_store.FoodLevel, 100)
    t.eq(who.state_store.WaterLevel, 151)
    t.eq(who.state_store.OxygenLevel, 300, "no more than the most it can have")
    me.Food = -5
    t.eq(me.Food, 0)
    me.Health = 123
    t.eq(who.instance.Health, 123)
    who.instance.Stamina = 10
    t.eq(me.Stamina, 10)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me.Health = 0
    end, "Health cannot be set below 1")
    at(err, line, "what a setter raises through game.Me")
    t.ok(not tostring(err):find("character.lua", 1, true), tostring(err))
    local wolf = instance.wrap(kit.creature().actor)
    t.raises(function() wolf.Food = 5 end, "Food is not a property of BP_NPC_Wolf_Conifer_Character_C")
    t.eq(values.silent, silent)
    possess(nil)
    t.raises(function() me.Food = 5 end, "there is no character right now, so Food cannot be set")
end)

t.test("Heal gives health back with the game's own functions, never past the most, and answers the health afterwards", function()
    actions.host(true)
    local silent, adds = values.silent, actions.calls.AddHealth or 0
    local who = kit.creature({ state = { Health = 40 } })
    local wolf = instance.wrap(who.actor)
    t.eq(wolf:Heal(10), 50)
    t.eq(actions.calls.AddHealth, adds + 1)
    t.eq(wolf:Heal(2.6), 53, "a fraction is rounded")
    t.eq(wolf:Heal(500), 102, "more than is missing fills it")
    t.eq(wolf:Heal(5), 102, "a full one is left alone")
    t.eq(actions.calls.AddHealth, adds + 2)
    who.state_store.Health = 7
    t.eq(wolf:Heal(), 102, "with no amount all of it comes back")
    t.raises(function() wolf:Heal(0) end, "Heal expects how much health to give back, a number above 0")
    t.raises(function() wolf:Heal(-5) end, "To lower health assign Health, and to kill call Kill()")
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        wolf:Heal("all")
    end, "Heal expects a number, got string")
    at(err, line)
    t.raises(function() wolf.Heal(5) end, "call Heal with a colon")
    kit.kill(who)
    t.raises(function() wolf:Heal() end, "this character is dead, and Heal does not bring it back")
    t.eq(values.silent, silent)
    t.eq(actions.untried, 0, table.concat(actions.log, " | "))
end)

t.test("Kill kills a creature at once and says whether it did, and a player's character is behind the switch", function()
    actions.host(true)
    local kills = actions.calls.Kill or 0
    local who = kit.creature()
    local wolf = instance.wrap(who.actor)
    t.eq(wolf:Kill(), true)
    t.eq(wolf.Alive, false)
    t.eq(wolf.Health, 0)
    t.eq(wolf:Kill(), false, "one that is dead already is left alone")
    t.eq(actions.calls.Kill, kills + 1)
    local player = hero()
    t.eq(character.KILL_PLAYERS, false, "the switch is off as it ships")
    t.raises(function() player.instance:Kill() end, "Kill is switched off for a player's character in this version of Wax")
    t.eq(player.instance.Alive, true)
    t.eq(actions.player_kills, 0, "the game was not asked to kill a player's character")
    character.KILL_PLAYERS = true
    local ok, killed = pcall(function() return player.instance:Kill() end)
    character.KILL_PLAYERS = false
    t.ok(ok, tostring(killed))
    t.eq(killed, true)
    t.eq(player.instance.Alive, false)
    t.eq(actions.player_kills, 1)
end)

t.test("Teleport moves a character with the engine's own call: to a place, to an actor or to game.Me", function()
    actions.host(true)
    local silent = values.silent
    local who = hero({ at = { 100, 200, 300 }, facing = { 0, 45, 0 } })
    possess(who)
    local me = who.instance
    t.eq(me:Teleport({ X = 1000, Y = 2000, Z = 3000 }), true)
    local landed = me.Position
    t.eq(landed.X, 1000)
    t.eq(landed.Y, 2000)
    t.eq(landed.Z, 3000)
    t.eq(me.Rotation.Yaw, 45, "it keeps facing the way it did")
    t.eq(me:Teleport({ X = 0, Y = 0, Z = 0 }, { Yaw = 180 }), true)
    t.eq(me.Rotation.Yaw, 180)
    t.eq(me.Rotation.Pitch, 0)
    local wolf_parts = kit.creature({ at = { 500, 600, 700 } })
    local wolf = instance.wrap(wolf_parts.actor)
    t.eq(game.Me:Teleport(wolf), true)
    t.eq(me.Position.X, 500)
    t.eq(me:DistanceTo(wolf), 0)
    t.eq(wolf:Teleport({ X = 9, Y = 9, Z = 9 }), true)
    t.eq(wolf.Position.Z, 9)
    t.eq(wolf:Teleport(game.Me), true)
    t.eq(wolf.Position.Y, 600)
    actions.blocked = true
    t.eq(me:Teleport({ X = 1, Y = 1, Z = 1 }), false, "the game found no room there and says so")
    actions.blocked = false
    t.eq(me.Position.X, 500)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me:Teleport()
    end, "Teleport expects an actor, game.Me or a position such as { X = 0, Y = 0, Z = 0 }, got nil")
    at(err, line)
    t.raises(function() me:Teleport({ X = 1, Y = 2 }) end, "Teleport expects an actor, game.Me or a position")
    t.raises(function() me:Teleport({ X = 0 / 0, Y = 0, Z = 0 }) end, "Teleport expects a place whose X, Y and Z are numbers")
    t.raises(function() me:Teleport({ X = 1, Y = 1, Z = 1 }, 90) end,
        "Teleport expects the way to face as its second value, such as { Yaw = 90 }, got 90")
    t.raises(function() me:Teleport({ X = 1, Y = 1, Z = 1 }, { Yaw = "north" }) end, "Teleport expects Pitch, Yaw and Roll in degrees")
    t.eq(me.Position.X, 500)
    t.eq(values.silent, silent)
    possess(nil)
end)

t.test("a client is told that only the host can, in plain words, and the game is asked for nothing", function()
    actions.host(true)
    local who = hero()
    possess(who)
    local wolf = instance.wrap(kit.creature().actor)
    actions.host(false)
    t.eq(game.IsHost, false)
    local before = asked()
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        game.Me.Health = 50
    end, "only the host can set Health. You are in someone else's game, where its server decides. game.IsHost says which you are")
    at(err, line)
    t.raises(function() game.Me.Food = 1 end, "only the host can set Food")
    t.raises(function() wolf.Stamina = 1 end, "only the host can set Stamina")
    t.raises(function() wolf:Heal() end, "only the host can heal a character")
    t.raises(function() wolf:Kill() end, "only the host can kill a character")
    t.raises(function() game.Me:Teleport({ X = 0, Y = 0, Z = 0 }) end, "only the host can move a character")
    t.eq(asked(), before)
    t.eq(who.state_store.Health, 300)
    t.eq(game.Me.Health, 300, "reading goes on working")
    actions.host(true)
    possess(nil)
end)

t.test("the global UE4SS leaves when the alive state is read is taken away", function()
    actions.host(true)
    local who = kit.creature()
    local wolf = instance.wrap(who.actor)
    local function left() rawset(_G, "Enum_CurrentAliveState", { left_by = "the stand-in" }) end
    left()
    t.eq(wolf.Alive, true)
    t.eq(rawget(_G, "Enum_CurrentAliveState"), nil, "after Alive")
    left()
    wolf.Health = 50
    t.eq(rawget(_G, "Enum_CurrentAliveState"), nil, "after assigning Health")
    left()
    wolf:Heal(1)
    t.eq(rawget(_G, "Enum_CurrentAliveState"), nil, "after Heal")
    left()
    wolf:Kill()
    t.eq(rawget(_G, "Enum_CurrentAliveState"), nil, "after Kill")
end)

t.test("the new names are among a character's members, and game.Me knows them with no character", function()
    possess(nil)
    t.raises(function() game.Me:Heal() end, "there is no character right now, so Heal cannot be called")
    t.raises(function() game.Me:Kill() end, "there is no character right now, so Kill cannot be called")
    t.raises(function() game.Me:Teleport({ X = 0, Y = 0, Z = 0 }) end, "there is no character right now, so Teleport cannot be called")
    local names = {}
    for _, name in ipairs(instance.wrap(kit.creature().actor):GetMembers()) do names[name] = true end
    t.ok(names.Heal and names.Kill and names.Teleport, "Heal, Kill and Teleport are listed")
end)

-- --------------------------------------------------------------------------------------------------------- the rest

t.test("nothing here touched a freed object, asked the engine for what it does not offer, or left anything behind", function()
    t.eq(actions.untried, 0, table.concat(actions.log, " | "))
    frames(10)
    quiet()
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(values.crashes + values.misuse, 0, table.concat(values.log, " | "))
    t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace)
    t.eq(#easy.clashes(), 0)
    t.eq(Wax.import("engine.watch").stats().watching, 0)
    for name, signal in pairs(character.stats().signals) do
        t.eq(signal.handlers, 0, name)
        t.eq(signal.looking, false, name)
    end
end)

-- What things take on the stand-in, in a tight loop. The game takes 4 to 7 times as long once a frame.
if arg and arg[1] == "cost" then
    guard.suspend_watchdog(true)        -- these loops run for seconds without a frame in between
    local function each(rounds, body)
        local started = os.clock()
        for _ = 1, rounds do body() end
        return (os.clock() - started) / rounds * 1e6
    end
    local who = hero()
    possess(who)
    local me, inst = game.Me, who.instance
    local sink = 0
    local empty = each(1000000, function() sink = sink + 1 end)
    local property = each(100000,function() sink = sink + inst.RespawnCount end) - empty
    local field = each(100000,function() sink = sink + inst.Health end) - empty
    local through_me = each(100000,function() sink = sink + me.Health end) - empty
    local place = each(100000,function() sink = sink + inst.Position.X end) - empty
    local distance = each(100000,function() sink = sink + inst:DistanceTo(me) end) - empty
    local capacity = each(100000,function() sink = sink + inst.MaxWeight end) - empty
    local stats = sched.stats
    local find = each(100000,function()
        stats.frame = stats.frame + 1
        sink = sink + (me.Exists and 1 or 0)
    end) - empty
    print(("cost on the stand-in, us: a property of the game's through an Instance %.2f, Health through an Instance %.2f, "
        .. "through game.Me %.2f, Position %.2f, DistanceTo %.2f, MaxWeight %.2f, finding the character on a new frame %.2f")
        :format(property, field, through_me, place, distance, capacity, find))

    local fire = function()
        now = now + 0.5
        sched.Frame:Fire(FRAME)
    end
    local idle = each(20000, fire)
    local one = me.HealthChanged:Connect(function() end)
    local health = each(20000, fire) - idle
    local all = {}
    for _, name in ipairs({ "StaminaChanged", "FoodChanged", "WaterChanged", "OxygenChanged", "WeightChanged", "BiomeChanged",
        "LevelUp", "XPGained", "Respawned", "Spawned", "Despawned" }) do
        all[#all + 1] = me[name]:Connect(function() end)
    end
    local every = each(20000, fire) - idle
    one:Disconnect()
    for _, connection in ipairs(all) do connection:Disconnect() end
    print(("cost on the stand-in, us, a frame in which every value is looked at: HealthChanged alone %.2f, all twelve signals %.2f "
        .. "(%d finds, %.2f us each by the module's own count)"):format(health, every, character.stats().finds, character.stats().find_us))
    assert(sink > 0)
    guard.suspend_watchdog(false)
end

t.finish("character")
