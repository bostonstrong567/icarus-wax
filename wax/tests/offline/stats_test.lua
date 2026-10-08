-- Offline tests for world.stats: a character's stats read from the list the game keeps for it, the named stats, and the
-- modifiers that are on it. The engine is a stand-in in which an object that was freed raises on any use, a read
-- outside a list is counted, and a value of the wrong kind handed to the engine counts as a crash.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\stats_test.lua
-- Add the word cost to print what a read takes on the stand-in.

local t = dofile("wax/tests/offline/harness.lua")
local world = dofile("wax/tests/offline/fake_world.lua")
world.install()
local values = dofile("wax/tests/offline/fake_values.lua")
values.install(world)
local kit = world.icarus(values)
local fake = dofile("wax/tests/offline/fake_session.lua")
local more = fake.install(world, values, kit)
local actions = dofile("wax/tests/offline/fake_actions.lua")
actions.install(world, values, kit, { session = fake, more = more })

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)

local guard = Wax.import("core.guard")
local sched = Wax.import("core.sched")
local log = Wax.import("core.log")
local easy = Wax.import("engine.easy")
local instance = Wax.import("engine.instance")
local game_module = Wax.import("engine.game")
world.possess(nil)
actions.host(true)
game_module.start()
Wax.game = game_module.root
Wax.import("engine.actors").start()
local game = game_module.root

local STATS, MODIFIERS = "/Engine/Transient.D_Stats", "/Engine/Transient.D_ModifierStates"

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

local function at(err, line, what)
    t.ok(tostring(err):find("stats_test.lua:" .. line .. ":", 1, true),
        (what or "the error") .. " should name line " .. line .. ": " .. tostring(err))
end

local function merged(base, over)
    local out = {}
    for key, value in pairs(base) do out[key] = value end
    for key, value in pairs(over or {}) do out[key] = value end
    return out
end

-- A player's character with its stat list and its Instance.
local function hero(over)
    local who = more.player(over)
    who.instance = instance.wrap(who.actor)
    return who
end

local function possess(who)
    world.possess(who and who.actor or nil)
    frames(1)
end

local function warnings(since, the_log)
    return (the_log or log).since(since, { channel = "wax.stats", level = "warn" })
end

local character = Wax.import("world.character")
character.start()
local touches, finds = world.touches, values.finds
local stats = Wax.import("world.stats")
-- most of this suite looks at the list, which is what answers with the switch off
local shipped = stats.BY_CALL
stats.BY_CALL = false
stats.start()

-- ----------------------------------------------------------------------------------------------------------- stats

t.test("starting asks the engine nothing, and game.Me knows the names with no character", function()
    t.eq(world.touches, touches, "no engine object was touched")
    t.eq(values.finds, finds, "nothing was looked up by path")
    t.eq(fake.calls.NameToInt, 0)
    t.eq(fake.calls.names[STATS], 0)
    t.eq(shipped, true, "the switch is on as it ships")
    t.eq(stats.HOLD, 0.2)
    quiet()
    t.eq(game.Me.Stats, nil)
    t.eq(game.Me.HealthRegen, nil)
    t.eq(game.Me.StaminaRegen, nil)
    t.raises(function() game.Me:GetStat("MovementSpeed_+") end, "there is no character right now, so GetStat cannot be called")
    t.raises(function() game.Me:GetModifiers() end, "there is no character right now, so GetModifiers cannot be called")
    t.raises(function() game.Me:HasModifier("Berry") end, "there is no character right now, so HasModifier cannot be called")
end)

t.test("GetStat reads a stat from the character's list by its name, in any letter case", function()
    stats.flush()
    local who = hero()
    local me = who.instance
    local asked, named, walks, reads = fake.calls.NameToInt, fake.calls.names[STATS], stats.stats().walks, fake.reads
    t.eq(me:GetStat("MaximumHealth_+"), 300)
    t.eq(math.type(me:GetStat("MaximumHealth_+")), "integer")
    t.eq(me:GetStat("MaximumStamina_+"), 200)
    t.eq(me:GetStat("MovementSpeed_+"), 355)
    t.eq(me:GetStat("WeightCapacity_+"), 100)
    t.eq(me:GetStat("StaminaRegenDelay_+"), 1000)
    t.eq(me:GetStat("movementspeed_+"), 355, "letter case does not matter")
    t.eq(fake.calls.NameToInt - asked, 5, "the game is asked once where each name is")
    t.eq(fake.calls.names[STATS] - named, 0, "the names of all stats were not read")
    t.eq(stats.stats().walks - walks, 1, "one walk of the list served them all")
    t.eq(#who.stat_list, 17, "the list of a player's character as the stand-in makes it")
    t.eq(fake.reads - reads, 17, "each pair was read once")
    t.eq(fake.strays, 0, fake.stray_where)
    t.eq(fake.walks, 0, "the list is read by index inside its length, not with ForEach")
    t.eq(values.crashes, 0, table.concat(values.log, " | "))
end)

t.test("a stat of the list with no value is 0, and one the game keeps out of the list is nil", function()
    stats.flush()
    local who = hero({ stats = { ["SwimSpeed_+"] = 0 } })
    local me = who.instance
    local rows = fake.calls.rows[STATS]
    t.eq(me:GetStat("SwimSpeed_+"), 0)
    t.eq(me:GetStat("BaseMaximumHealth_+"), nil, "the game has 300 for it, and does not put it in the list")
    t.eq(me:GetStat("BaseMovementSpeed_+"), nil)
    t.eq(fake.calls.rows[STATS] - rows, 3, "the table is asked once per stat whether the list holds it")
    t.eq(me:GetStat("SwimSpeed_+"), 0)
    t.eq(me:GetStat("BaseMaximumHealth_+"), nil)
    t.eq(fake.calls.rows[STATS] - rows, 3)

    -- a list with nothing in it is never read into
    local bare = hero()
    more.stats(bare, {})
    local reads = fake.reads
    t.eq(bare.instance:GetStat("MaximumHealth_+"), 0)
    local all, count = bare.instance.Stats, 0
    for _ in pairs(all) do count = count + 1 end
    t.eq(count, 0)
    t.eq(fake.reads, reads)
    t.eq(fake.strays, 0, fake.stray_where)
end)

t.test("a name the game does not have raises at the mod's line with the nearest names, and is asked for once", function()
    stats.flush()
    local who = hero()
    local me = who.instance
    local asked, named = fake.calls.NameToInt, fake.calls.names[STATS]
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me:GetStat("MovmentSpeed_+")
    end, "'MovmentSpeed_+' is not a stat of the game. Did you mean 'MovementSpeed_+'?")
    at(err, line)
    t.ok(not tostring(err):find("stats.lua", 1, true), tostring(err))
    t.eq(fake.calls.NameToInt - asked, 1)
    t.eq(fake.calls.names[STATS] - named, 1, "the names were read for the suggestion")
    t.raises(function() me:GetStat("MovmentSpeed_+") end, "Did you mean 'MovementSpeed_+'?")
    t.raises(function() me:GetStat("MOVMENTSPEED_+") end, "is not a stat of the game")
    t.eq(fake.calls.NameToInt - asked, 1, "the game is not asked again")
    t.eq(fake.calls.names[STATS] - named, 1, "and the names are not read again")
    err = t.raises(function() me:GetStat("MaximumHealth") end, "'MaximumHealth' is not a stat of the game.")
    t.ok(tostring(err):find("'MaximumHealth_+'", 1, true), tostring(err))
    t.eq(me:GetStat("MaximumHealth_+"), 300, "a right name works after a wrong one")
    t.eq(fake.calls.NameToInt - asked, 1, "with the names read, a name is found among them")

    t.raises(function() me:GetStat() end, "GetStat expects the name of a stat, such as \"MovementSpeed_+\", got nil")
    t.raises(function() me:GetStat(58) end, "GetStat expects the name of a stat, such as \"MovementSpeed_+\", got number")
    t.raises(function() me:GetStat("") end, "GetStat expects the name of a stat")
    t.raises(function() me.GetStat("MovementSpeed_+") end, "call GetStat with a colon")
    t.eq(#guard.errors(), 0)
    t.eq(values.crashes, 0, table.concat(values.log, " | "))
end)

t.test("Stats is the whole list by name, a new plain table each time", function()
    stats.flush()
    local who = hero()
    local me = who.instance
    local asked, named = fake.calls.NameToInt, fake.calls.names[STATS]
    local all, count = me.Stats, 0
    for _ in pairs(all) do count = count + 1 end
    t.eq(count, 17)
    t.eq(all["MaximumHealth_+"], 300)
    t.eq(all["MovementSpeed_+"], 355)
    t.eq(all["SprintSpeed_+"], 710)
    t.eq(all["HealthRegenPerMinute_+"], 25)
    t.eq(all["OxygenConsumptionPerHour_+"], 480)
    t.eq(all["BaseMaximumHealth_+"], nil, "what the game keeps out of the list is not in it")
    t.eq(getmetatable(all), nil)
    all["MovementSpeed_+"] = 1
    t.eq(me.Stats["MovementSpeed_+"], 355)
    t.ok(not rawequal(me.Stats, all))
    t.eq(fake.calls.names[STATS] - named, 1, "the names of the stats are read once")
    t.eq(me:GetStat("CrouchSpeed_+"), 198)
    t.eq(fake.calls.NameToInt - asked, 0, "and then a name is found among them")
    t.eq(fake.strays, 0, fake.stray_where)
end)

t.test("a character's list is kept for a fifth of a second, and stats.forget drops it", function()
    stats.flush()
    local who = hero()
    local me = who.instance
    local walks = stats.stats().walks
    t.eq(me:GetStat("MaximumHealth_+"), 300)
    local reads = fake.reads
    t.eq(me.HealthRegen, 25)
    t.eq(me:GetStat("MovementSpeed_+"), 355)
    t.eq(me.Stats["WeightCapacity_+"], 100)
    t.eq(stats.stats().walks - walks, 1)
    t.eq(fake.reads, reads, "no pair was read again")

    more.stats(who, merged(fake.PLAYER_STATS, { ["MaximumHealth_+"] = 350 }))
    frames(3)
    t.eq(me:GetStat("MaximumHealth_+"), 300, "within a fifth of a second the last read answers")
    pass(0.2)
    t.eq(me:GetStat("MaximumHealth_+"), 350)
    t.eq(stats.stats().walks - walks, 2)

    more.stats(who, merged(fake.PLAYER_STATS, { ["MaximumHealth_+"] = 400 }))
    t.eq(me:GetStat("MaximumHealth_+"), 350)
    stats.forget(me)
    t.eq(me:GetStat("MaximumHealth_+"), 400, "a module that changed a stat has it read again")

    -- each character has its own
    local other = hero({ stats = { ["MaximumHealth_+"] = 120 } })
    t.eq(other.instance:GetStat("MaximumHealth_+"), 120)
    t.eq(me:GetStat("MaximumHealth_+"), 400)

    -- with no hold a list is read once a frame
    stats.HOLD = 0
    stats.forget()
    walks = stats.stats().walks
    t.eq(me:GetStat("MaximumHealth_+"), 400)
    more.stats(who, merged(fake.PLAYER_STATS, { ["MaximumHealth_+"] = 410 }))
    t.eq(me:GetStat("MaximumHealth_+"), 400, "in the same frame")
    frames(1)
    t.eq(me:GetStat("MaximumHealth_+"), 410)
    t.eq(stats.stats().walks - walks, 2)
    stats.HOLD = 0.2
end)

t.test("HealthRegen and StaminaRegen are the game's two stats, on a player's character and on a creature", function()
    stats.flush()
    local who = hero()
    t.eq(who.instance.HealthRegen, 25)
    t.eq(who.instance.StaminaRegen, 2400)
    t.eq(math.type(who.instance.StaminaRegen), "integer")
    local wolf_parts = more.creature()
    local wolf = instance.wrap(wolf_parts.actor)
    t.eq(wolf.HealthRegen, 12)
    t.eq(wolf.StaminaRegen, 0, "a stat of the list the creature has no value for")
    t.eq(wolf:GetStat("MaximumHealth_+"), 102)
    t.eq(wolf.Stats["MovementSpeed_+"], 440)
    local names = {}
    for _, name in ipairs(wolf:GetMembers()) do names[name] = true end
    t.ok(names.Stats and names.GetStat and names.HealthRegen and names.GetModifiers and names.HasModifier,
        "the names are among the members")
    t.raises(function() wolf.HealthRegen = 5 end, "HealthRegen is read-only")
    t.raises(function() wolf.Stats = {} end, "Stats is read-only")
end)

t.test("a character with no stat container reads nil, not an error", function()
    stats.flush()
    local station = kit.station()
    local pawn = instance.wrap(station.actor)
    t.eq(pawn.Stats, nil)
    t.eq(pawn.HealthRegen, nil)
    t.eq(pawn.StaminaRegen, nil)
    t.eq(pawn:GetStat("MaximumHealth_+"), nil)
    t.eq(#pawn:GetModifiers(), 0)
    t.eq(pawn:HasModifier("Berry"), false)
    t.raises(function() pawn:GetStat("Nope_+") end, "'Nope_+' is not a stat of the game.")
    t.eq(#guard.errors(), 0)
end)

t.test("a list that is not where it was reads as nothing, with one line in the log", function()
    stats.flush()
    local who = hero()
    local me = who.instance
    who.stats_store.ReplicatedStatArray = nil
    local newest = log.newest_id()
    t.eq(me:GetStat("MaximumHealth_+"), nil)
    t.eq(me.Stats, nil)
    t.eq(me.HealthRegen, nil)
    pass(0.25)
    t.eq(me:GetStat("MaximumHealth_+"), nil)
    local said = warnings(newest)
    t.eq(#said, 1)
    t.ok(said[1].message:find("the stat list of a BP_IcarusPlayerCharacterSurvival_C could not be read", 1, true), said[1].message)
    t.eq(#guard.errors(), 0)
end)

t.test("when the game's library cannot say where a stat is, the table of stats is read", function()
    local path = "/Script/Icarus.Default__StatsLibrary"
    local kept = world.static[path]
    world.static[path] = nil
    local lone = t.new_wax()
    lone.import("engine.game").start()
    lone.import("world.character").start()
    local lone_stats = lone.import("world.stats")
    lone_stats.start()
    local lone_log = lone.import("core.log")
    local who = more.player()
    local me = lone.import("engine.instance").wrap(who.actor)
    local asked, named, newest = fake.calls.NameToInt, fake.calls.names[STATS], lone_log.newest_id()
    t.eq(me:GetStat("MovementSpeed_+"), 355)
    t.eq(me:GetStat("MaximumHealth_+"), 300)
    t.eq(me.HealthRegen, 25)
    t.raises(function() me:GetStat("Nope_+") end, "'Nope_+' is not a stat of the game.")
    t.eq(fake.calls.NameToInt - asked, 0)
    t.eq(fake.calls.names[STATS] - named, 1)
    local said = warnings(newest, lone_log)
    t.eq(#said, 1)
    t.ok(said[1].message:find("did not say where a stat is, so the table of stats is read", 1, true), said[1].message)
    world.static[path] = kept

    -- with neither, nothing can be said and nothing is raised
    world.static[path], world.static[STATS] = nil, nil
    local bare = t.new_wax()
    bare.import("engine.game").start()
    bare.import("world.character").start()
    bare.import("world.stats").start()
    local misses = values.misses
    local it = bare.import("engine.instance").wrap(more.player().actor)
    t.eq(it:GetStat("MovementSpeed_+"), nil)
    t.eq(it.Stats, nil)
    t.eq(it.HealthRegen, nil)
    t.eq(it:GetStat("MovementSpeed_+"), nil)
    t.eq(values.misses - misses, 2, "what the game does not have is looked for once: the library and the table")
    world.static[path], world.static[STATS] = kept, more.stats_table
end)

t.test("behind the switch BY_CALL the game's own getter answers every stat, and the list is not walked", function()
    local lone = t.new_wax()
    lone.import("engine.game").start()
    lone.import("world.character").start()
    local lone_stats = lone.import("world.stats")
    lone_stats.BY_CALL = true
    lone_stats.start()
    local wrap = lone.import("engine.instance").wrap
    local who = more.player()
    local me = wrap(who.actor)
    local reads = fake.reads
    t.eq(me:GetStat("BaseMaximumHealth_+"), 300, "a stat the list does not hold")
    t.eq(me:GetStat("BaseMovementSpeed_+"), 355)
    t.eq(me:GetStat("MovementSpeed_+"), 355)
    t.eq(me.HealthRegen, 25)
    t.eq(me.StaminaRegen, 2400)
    t.eq(me:GetStat("Filler010_+"), 0, "the game answers 0 for a stat the character does not have")
    t.eq(fake.reads, reads, "the list was not read")
    t.eq(lone_stats.stats().walks, 0)
    t.raises(function() me:GetStat("Nope_+") end, "'Nope_+' is not a stat of the game.")
    t.eq(me.Stats["MovementSpeed_+"], 355, "Stats is the list all the same")
    t.eq(wrap(kit.station().actor):GetStat("MovementSpeed_+"), nil, "no stat container, no answer")
    t.eq(lone_stats.stats().by_call, true)
    t.eq(values.crashes, 0, table.concat(values.log, " | "))
end)

-- ------------------------------------------------------------------------------------------------------- modifiers

t.test("GetModifiers lists what is on the character, oldest first, as plain tables", function()
    stats.flush()
    local who = hero()
    local me = who.instance
    t.eq(#me:GetModifiers(), 0)
    more.modifier(who, "Berry", { uid = 12, lifetime = 600, remaining = 561.48364257812 })
    more.modifier(who, "Drink_Cooling", { uid = 9, lifetime = 300, remaining = 256.98831176758, class = "BP_Modifier_Drink_C" })
    more.modifier(who, "Dirty_Water", { uid = 10, lifetime = 300, remaining = 256.98831176758 })
    t.eq(#me:GetModifiers(), 0, "the character is asked once a frame")
    frames(1)
    local rows, enums = fake.calls.rows[MODIFIERS], fake.enums
    local list = me:GetModifiers()
    t.eq(#list, 3)
    t.eq(fake.enums - enums, 3, "each row's type was read, which leaves a global behind as UE4SS does")
    t.eq(rawget(_G, "Enum_Type"), nil, "and the global was taken away")
    t.eq(list[1].Name, "Drink_Cooling")
    t.eq(list[1].DisplayName, "Cooling")
    t.eq(list[1].Kind, "Buff")
    t.eq(list[1].Id, 9)
    t.eq(list[1].Duration, 300)
    t.eq(list[1].Remaining, 256.98831176758)
    t.eq(list[2].Name, "Dirty_Water")
    t.eq(list[2].DisplayName, "Tainted Water")
    t.eq(list[2].Kind, "Debuff")
    t.eq(list[2].Id, 10)
    t.eq(list[3].Name, "Berry")
    t.eq(list[3].DisplayName, "Berry")
    t.eq(list[3].Kind, "Buff")
    t.eq(list[3].Duration, 600)
    t.eq(list[3].Remaining, 561.48364257812)
    t.eq(getmetatable(list[1]), nil)
    t.eq(fake.calls.rows[MODIFIERS] - rows, 3, "the table is asked once for each row")

    world.watch = {}
    list[1].Name = "changed"
    t.eq(me:GetModifiers()[1].Name, "Drink_Cooling", "new tables each time")
    t.eq(me:HasModifier("Berry"), true)
    t.eq(world.watch.DataRowHandleNew, nil, "the components are not read again in the frame")
    frames(1)
    t.eq(#me:GetModifiers(), 3)
    t.eq(world.watch.DataRowHandleNew, 3)
    t.eq(world.watch.RemainingTime, 3)
    world.watch = nil
    t.eq(fake.calls.rows[MODIFIERS] - rows, 3, "and the table is not asked again")
    t.eq(values.crashes + values.misuse, 0, table.concat(values.log, " | "))
end)

t.test("a modifier the game gives no lifetime has no Duration and no Remaining", function()
    stats.flush()
    local who = hero()
    local me = who.instance
    -- as the game's Exposure_Conifer_Wind read in a storm: lifetime 0, remaining a hair under it
    more.modifier(who, "Berry", { uid = 20, lifetime = 0, remaining = -0.0166 })
    more.modifier(who, "Dirty_Water", { uid = 21, lifetime = 300, remaining = 12 })
    frames(1)
    local list = me:GetModifiers()
    t.eq(#list, 2)
    t.eq(list[1].Name, "Berry")
    t.eq(list[1].Duration, nil)
    t.eq(list[1].Remaining, nil)
    t.eq(list[2].Duration, 300)
    t.eq(list[2].Remaining, 12)
end)

t.test("HasModifier answers by row name in any letter case, and a wrong name raises with the nearest", function()
    stats.flush()
    local who = hero()
    local me = who.instance
    more.modifier(who, "Berry", { uid = 3 })
    more.modifier(who, "Dirty_Water", { uid = 4 })
    local named = fake.calls.names[MODIFIERS]
    t.eq(me:HasModifier("Berry"), true)
    t.eq(me:HasModifier("berry"), true)
    t.eq(me:HasModifier("DIRTY_WATER"), true)
    t.eq(me:HasModifier("Health_Regen"), false, "a modifier of the game that is not on the character")
    t.eq(me:HasModifier("overburdened"), false)
    t.eq(fake.calls.names[MODIFIERS] - named, 0, "the names of all modifiers were not read")
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me:HasModifier("Bery")
    end, "'Bery' is not a modifier of the game. Did you mean 'Berry'?")
    at(err, line)
    t.eq(fake.calls.names[MODIFIERS] - named, 1, "they are read for the suggestion")
    local rows = fake.calls.rows[MODIFIERS]
    t.raises(function() me:HasModifier("Bery") end, "Did you mean 'Berry'?")
    t.eq(fake.calls.rows[MODIFIERS], rows, "a wrong name is asked for once")
    t.eq(fake.calls.names[MODIFIERS] - named, 1)
    t.raises(function() me:HasModifier() end, "HasModifier expects the name of a modifier, such as \"Berry\", got nil")
    t.raises(function() me:HasModifier({}) end, "got table")
    t.raises(function() me.HasModifier("Berry") end, "call HasModifier with a colon")
    t.eq(#guard.errors(), 0)
end)

t.test("a modifier the table says little or nothing about is listed under its row name", function()
    stats.flush()
    local who = hero()
    local me = who.instance
    more.modifier(who, "Wet", { uid = 20 })
    more.modifier(who, "Nameless", { uid = 21 })
    more.modifier(who, "Unlisted_Row", { uid = 22 })
    local list = me:GetModifiers()
    t.eq(#list, 3)
    t.eq(list[1].DisplayName, "Wet", "the table has no shown name for it")
    t.eq(list[1].Kind, "Biome")
    t.eq(list[2].DisplayName, "Nameless")
    t.eq(list[2].Kind, nil)
    t.eq(list[3].Name, "Unlisted_Row")
    t.eq(list[3].DisplayName, "Unlisted_Row")
    t.eq(list[3].Kind, nil)
    t.eq(me:HasModifier("Unlisted_Row"), true, "what is on the character is found, whatever the table says")
    t.eq(#guard.errors(), 0)
end)

t.test("a modifier that ended is not touched again, and a creature has modifiers too", function()
    stats.flush()
    local who = hero()
    local me = who.instance
    local berry = more.modifier(who, "Berry", { uid = 30 })
    more.modifier(who, "Dirty_Water", { uid = 31 })
    t.eq(#me:GetModifiers(), 2)
    more.end_modifier(who, berry)
    t.eq(#me:GetModifiers(), 2, "what was read in this frame is what the frame gets")
    t.eq(me:HasModifier("Berry"), true)
    frames(1)
    t.eq(me:HasModifier("Berry"), false)
    local list = me:GetModifiers()
    t.eq(#list, 1)
    t.eq(list[1].Name, "Dirty_Water")
    t.eq(world.dead_touches, 0, world.dead_where)

    local wolf_parts = more.creature()
    local wolf = instance.wrap(wolf_parts.actor)
    more.modifier(wolf_parts, "Health_Regen", { uid = 32, lifetime = 20, remaining = 20 })
    t.eq(wolf:HasModifier("Health_Regen"), true)
    t.eq(wolf:GetModifiers()[1].DisplayName, "Health Regen")
end)

t.test("when the game has no modifier class or no modifier table, nothing is found and nothing is raised", function()
    stats.flush()
    local who = hero()
    local me = who.instance
    more.modifier(who, "Berry", { uid = 40 })
    local class_path = "/Script/Icarus.ModifierStateComponent"
    local class, data = world.static[class_path], world.static[MODIFIERS]
    world.static[MODIFIERS] = nil
    local misses = values.misses
    local list = me:GetModifiers()
    t.eq(#list, 1)
    t.eq(list[1].DisplayName, "Berry", "with no table the row name is what there is")
    t.eq(list[1].Kind, nil)
    t.eq(me:HasModifier("Bery"), false, "with no table a name cannot be called wrong")
    t.eq(me:HasModifier("Health_Regen"), false)
    t.eq(values.misses - misses, 1, "the table is looked for once")
    world.static[MODIFIERS] = data

    stats.flush()
    world.static[class_path] = nil
    misses = values.misses
    frames(1)
    t.eq(#me:GetModifiers(), 0)
    frames(1)
    t.eq(#me:GetModifiers(), 0)
    t.eq(values.misses - misses, 1, "the class is looked for once")
    world.static[class_path] = class
    stats.flush()
    frames(1)
    t.eq(#me:GetModifiers(), 1)
    t.eq(#guard.errors(), 0)
end)

-- ---------------------------------------------------------------------------------------------- gone, game.Me, maps

t.test("a character that left the world answers with an error and is never touched again", function()
    stats.flush()
    local who = more.creature()
    local wolf = instance.wrap(who.actor)
    more.modifier(who, "Berry", { uid = 50 })
    t.eq(wolf:GetStat("MaximumHealth_+"), 102)
    t.eq(#wolf:GetModifiers(), 1)
    world.destroy(who.actor)
    world.free(who.actor)
    t.raises(function() return wolf:GetStat("MaximumHealth_+") end, "this BP_NPC_Wolf_Conifer_Character_C no longer exists")
    t.raises(function() return wolf.Stats end, "no longer exists")
    t.raises(function() return wolf.HealthRegen end, "no longer exists")
    t.raises(function() return wolf:GetModifiers() end, "no longer exists")
    t.raises(function() return wolf:HasModifier("Berry") end, "no longer exists")
    t.eq(world.dead_touches, 0, world.dead_where)
end)

t.test("game.Me has the stats and the modifiers of the local player's character", function()
    stats.flush()
    local who = hero()
    possess(who)
    more.modifier(who, "Berry", { uid = 60 })
    local me = game.Me
    t.eq(me:GetStat("MovementSpeed_+"), 355)
    t.eq(me.HealthRegen, 25)
    t.eq(me.StaminaRegen, 2400)
    t.eq(me.Stats["MaximumHealth_+"], 300)
    t.eq(me:HasModifier("Berry"), true)
    t.eq(me:GetModifiers()[1].DisplayName, "Berry")
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me:GetStat("Helth_+")
    end, "'Helth_+' is not a stat of the game.")
    at(err, line)
    possess(nil)
    t.eq(me.HealthRegen, nil)
    t.eq(me.Stats, nil)
    t.raises(function() me:GetStat("MovementSpeed_+") end, "there is no character right now, so GetStat cannot be called")
end)

t.test("on another map the names are read again, and nothing of the old map is touched", function()
    stats.flush()
    local who = hero()
    possess(who)
    local named = fake.calls.names[STATS]
    t.eq(who.instance.Stats["MaximumHealth_+"], 300)
    t.eq(fake.calls.names[STATS] - named, 1)
    more.travel("Terrain_021")
    frames(1)
    t.raises(function() return who.instance.Stats end, "no longer exists")
    local next_one = hero({ stats = { ["MaximumHealth_+"] = 320 } })
    possess(next_one)
    t.eq(game.Me:GetStat("MaximumHealth_+"), 320)
    t.eq(next_one.instance.Stats["MaximumHealth_+"], 320)
    t.eq(fake.calls.names[STATS] - named, 2)
    t.eq(world.dead_touches, 0, world.dead_where)
    possess(nil)
end)

t.test("an IcarusPawn gets the stats only with the switch of world.character", function()
    local worm_parts = kit.worm()
    more.stats(worm_parts, { ["MaximumHealth_+"] = 450 })
    local worm = instance.wrap(worm_parts.actor)
    t.raises(function() return worm:GetStat("MaximumHealth_+") end, "GetStat is not a member of BP_CRE_CaveWorm_C")
    t.raises(function() return worm.Stats end, "Stats is not a member of BP_CRE_CaveWorm_C")

    local lone = t.new_wax()
    lone.import("engine.game").start()
    local lone_character = lone.import("world.character")
    lone_character.UNPROVEN = true
    lone_character.start()
    lone.import("world.stats").start()
    local lone_worm = lone.import("engine.instance").wrap(worm_parts.actor)
    t.eq(lone_worm:GetStat("MaximumHealth_+"), 450)
    t.eq(lone_worm.Stats["MaximumHealth_+"], 450)
    t.eq(#lone_worm:GetModifiers(), 0)
    t.eq(#lone.import("engine.easy").clashes(), 0)
end)

-- ------------------------------------------------------------------------ putting a modifier on and taking it off

-- How often the game's own functions were called so far, to see that a refusal called none.
local function asked()
    local total = 0
    for _, count in pairs(actions.calls) do total = total + count end
    return total
end

t.test("the host puts a modifier on a character with the game's own call, and it shows at once", function()
    stats.flush()
    actions.host(true)
    local silent = values.silent
    local who = hero()
    local me = who.instance
    t.eq(#me:GetModifiers(), 0)
    local id = me:AddModifier("Health_Regen", { seconds = 20 })
    t.eq(math.type(id), "integer")
    local list = me:GetModifiers()
    t.eq(#list, 1, "it is listed in the same frame")
    t.eq(list[1].Name, "Health_Regen")
    t.eq(list[1].DisplayName, "Health Regen")
    t.eq(list[1].Id, id)
    t.eq(list[1].Duration, 20)
    t.eq(me:HasModifier("health_regen"), true)
    local second = me:AddModifier("berry", 600)
    t.ok(second > id, "the time may be a plain number, and the name in any letter case")
    t.eq(#me:GetModifiers(), 2)
    local wolf_parts = more.creature()
    local wolf = instance.wrap(wolf_parts.actor)
    t.ok(wolf:AddModifier("Dirty_Water", 15), "a creature takes one too")
    t.eq(wolf:GetModifiers()[1].DisplayName, "Tainted Water")
    t.eq(actions.calls.AddModifierState, 3)
    t.eq(values.silent, silent, "every value arrived as the kind the game takes")
    t.eq(actions.untried, 0, table.concat(actions.log, " | "))
end)

t.test("a wrong name, no time and an option Wax does not have are refused at the mod's line before the game is asked", function()
    stats.flush()
    actions.host(true)
    local who = hero()
    local me = who.instance
    local before = asked()
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me:AddModifier("Helth_Regen", 20)
    end, "'Helth_Regen' is not a modifier of the game. Did you mean 'Health_Regen'?")
    at(err, line)
    local needs_time = "AddModifier expects how long the modifier stays, in seconds: character:AddModifier(\"Health_Regen\", { seconds = 60 })"
    t.raises(function() me:AddModifier("Berry") end, needs_time)
    t.raises(function() me:AddModifier("Berry", { seconds = 0 }) end, needs_time)
    t.raises(function() me:AddModifier("Berry", -5) end, needs_time)
    t.raises(function() me:AddModifier("Berry", { seconds = "long" }) end, needs_time)
    t.raises(function() me:AddModifier("Berry", { seconds = 20, strength = 50 }) end,
        "AddModifier has no option 'strength'. It takes seconds, how long the modifier stays")
    t.raises(function() me:AddModifier(5, 20) end, "AddModifier expects the name of a modifier, such as \"Health_Regen\", got number")
    t.raises(function() me:RemoveModifier("Nope") end, "'Nope' is not a modifier of the game.")
    t.raises(function() me:RemoveModifier() end, "RemoveModifier expects the name of a modifier")
    t.eq(asked(), before, "the game was asked for nothing")
    t.eq(#me:GetModifiers(), 0)
end)

t.test("RemoveModifier takes every modifier of a name off, or the one a record names, and answers how many went", function()
    stats.flush()
    actions.host(true)
    local who = hero()
    local me = who.instance
    more.modifier(who, "Berry", { uid = 5 })
    local later = me:AddModifier("Berry", 90)
    me:AddModifier("Dirty_Water", 30)
    local listed = me:GetModifiers()
    t.eq(#listed, 3)
    t.eq(listed[2].Id, later)
    t.eq(me:RemoveModifier(listed[2]), 1, "the one the record names")
    t.eq(me:HasModifier("Berry"), true, "the other one of that name stays")
    t.eq(me:GetModifiers()[1].Id, 5)
    t.eq(me:RemoveModifier("BERRY"), 1)
    t.eq(me:HasModifier("Berry"), false, "it is gone in the same frame")
    t.eq(me:RemoveModifier("Berry"), 0, "none is left to take")
    t.eq(me:RemoveModifier("Dirty_Water"), 1)
    t.eq(#me:GetModifiers(), 0)
    frames(2)
    t.eq(#me:GetModifiers(), 0)
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(actions.untried, 0, table.concat(actions.log, " | "))
end)

t.test("a client cannot put a modifier on or take one off, game.Me can, and a table that cannot be read is said", function()
    stats.flush()
    actions.host(true)
    local who = hero()
    more.modifier(who, "Berry", { uid = 300 })
    actions.host(false)
    local before = asked()
    t.raises(function() who.instance:AddModifier("Berry", 20) end, "only the host can put a modifier on a character")
    t.raises(function() who.instance:RemoveModifier("Berry") end, "only the host can take a modifier off a character")
    t.eq(asked(), before)
    t.eq(who.instance:HasModifier("Berry"), true)
    actions.host(true)

    possess(who)
    t.ok(game.Me:AddModifier("Health_Regen", 30))
    t.eq(game.Me:RemoveModifier("Health_Regen"), 1)
    possess(nil)
    t.raises(function() game.Me:AddModifier("Berry", 30) end, "there is no character right now, so AddModifier cannot be called")
    t.raises(function() game.Me:RemoveModifier("Berry") end, "there is no character right now, so RemoveModifier cannot be called")

    local data = world.static[MODIFIERS]
    world.static[MODIFIERS] = nil
    stats.flush()
    before = asked()
    t.raises(function() who.instance:AddModifier("Berry", 20) end,
        "AddModifier: the game's table of modifiers cannot be read right now, so the name 'Berry' cannot be checked")
    t.eq(asked(), before, "a name that cannot be checked is not handed to the game")
    world.static[MODIFIERS] = data
    stats.flush()
end)

-- --------------------------------------------------------------------------------------------------------- the rest

t.test("nothing here touched a freed object, read outside a list, crashed the stand-in or left anything behind", function()
    t.eq(actions.untried, 0, table.concat(actions.log, " | "))
    frames(10)
    quiet()
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(fake.strays, 0, fake.stray_where)
    t.eq(fake.walks, 0, "no list was walked with ForEach")
    t.eq(values.crashes + values.misuse, 0, table.concat(values.log, " | "))
    t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace)
    t.eq(#easy.clashes(), 0)
    t.eq(#easy.stats().unseen, 0, table.concat(easy.stats().unseen, ", "))
    t.eq(Wax.modules["engine.watch"], nil, "nothing of this needs engine.watch")
end)

-- What things take on the stand-in, in a tight loop. The game takes 4 to 7 times as long once a frame.
if arg and arg[1] == "cost" then
    guard.suspend_watchdog(true)
    local function each(rounds, body)
        local started = os.clock()
        for _ = 1, rounds do body() end
        return (os.clock() - started) / rounds * 1e6
    end
    stats.flush()
    local who = hero()
    more.modifier(who, "Berry", { uid = 70 })
    more.modifier(who, "Dirty_Water", { uid = 71 })
    more.modifier(who, "Drink_Cooling", { uid = 72 })
    local me, sink, frame_stats = who.instance, 0, sched.stats
    local empty = each(1000000, function() sink = sink + 1 end)
    local kept = each(200000, function() sink = sink + me:GetStat("MovementSpeed_+") end) - empty
    local field = each(200000, function() sink = sink + me.HealthRegen end) - empty
    local all = each(50000, function() sink = sink + me.Stats["MovementSpeed_+"] end) - empty
    stats.HOLD = 0
    local walk = each(50000, function()
        frame_stats.frame = frame_stats.frame + 1
        sink = sink + me:GetStat("MovementSpeed_+")
    end) - empty
    stats.HOLD = 0.2
    local has = each(200000, function() sink = sink + (me:HasModifier("Berry") and 1 or 0) end) - empty
    local list = each(50000, function() sink = sink + #me:GetModifiers() end) - empty
    local read = each(50000, function()
        frame_stats.frame = frame_stats.frame + 1
        sink = sink + #me:GetModifiers()
    end) - empty
    print(("cost on the stand-in, us: GetStat from the kept list %.2f, HealthRegen %.2f, Stats (17 names) %.2f, "
        .. "GetStat with a walk of 17 pairs %.2f, HasModifier in a frame already read %.2f, GetModifiers (3) in a frame already read %.2f, "
        .. "GetModifiers with the read of 3 components %.2f"):format(kept, field, all, walk, has, list, read))
    assert(sink > 0)
    guard.suspend_watchdog(false)
end

t.finish("stats")
