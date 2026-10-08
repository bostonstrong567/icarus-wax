-- Offline tests for world.session: game.Time, game.Weather, game.Prospect, the facts of a player, and Joined and Left on
-- game.Players. The engine is a stand-in in which an object that was freed raises on any use, a read outside a list is
-- counted, and a map change frees everything of the map that is left.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\session_test.lua
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

local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local sched = Wax.import("core.sched")
local log = Wax.import("core.log")
local easy = Wax.import("engine.easy")
local instance = Wax.import("engine.instance")
local game_module = Wax.import("engine.game")
world.possess(nil)
game_module.start()
Wax.game = game_module.root
Wax.import("engine.actors").start()
local game = game_module.root

local TIME, WEATHER = "/Engine/Transient.D_TimeOfDay", "/Engine/Transient.D_WeatherEvents"
local CLOCK, SUBSYSTEMS = "/Script/Icarus.TimeOfDaySubsystem", "/Script/Engine.Default__SubsystemBlueprintLibrary"

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
    t.ok(tostring(err):find("session_test.lua:" .. line .. ":", 1, true),
        (what or "the error") .. " should name line " .. line .. ": " .. tostring(err))
end

local function warnings(since)
    return log.since(since, { channel = "wax.session", level = "warn" })
end

local function weather(row) return { RowName = values.name(row), DataTableName = values.name("D_WeatherEvents") } end

local function possess(who)
    world.possess(who and who.actor or nil)
    frames(1)
end

-- Another map with a prospect on it. `setup(place)` runs before the first frame that can see the prospect.
local map = 30
local function enter(over, setup)
    map = map + 1
    more.travel("Terrain_" .. map)
    frames(1)
    local place = more.prospect(over)
    if setup then setup(place) end
    frames(1)
    return place
end

local character = Wax.import("world.character")
character.start()
local touches, finds = world.touches, values.finds
local session = Wax.import("world.session")
session.start()

-- ------------------------------------------------------------------------------------------------ before a prospect

t.test("starting asks the engine nothing and puts Time, Weather and Prospect on game, Joined and Left on game.Players", function()
    t.eq(world.touches, touches, "no engine object was touched")
    t.eq(values.finds, finds, "nothing was looked up by path")
    t.eq(Wax.modules["engine.watch"], nil)
    quiet()
    t.ok(rawequal(game.Time, session.api.Time))
    t.ok(rawequal(game.Weather, session.api.Weather))
    t.ok(rawequal(game.Prospect, session.api.Prospect))
    t.ok(rawequal(game:GetService("Prospect"), game.Prospect))
    local listed = {}
    for _, name in ipairs(game_module.names()) do listed[name] = true end
    t.ok(listed.Time and listed.Weather and listed.Prospect, "game lists them among its members")
    t.ok(rawequal(game.Players.Joined, session.api.Joined))
    t.ok(rawequal(game.Players.Left, session.api.Left))
    t.eq(tostring(game.Time), "game.Time")
    t.eq(tostring(game.Weather), "game.Weather")
    t.eq(tostring(game.Prospect), "game.Prospect")
    session.start()
    local count = {}
    for _, name in ipairs(getmetatable(game.Players).__names()) do count[name] = (count[name] or 0) + 1 end
    t.eq(count.Joined, 1, "the names of game.Players have Joined once, also after a second start")
    t.eq(count.Left, 1)
    t.eq(table.concat(getmetatable(game.Time).__names(), " "), "Hour Minute Clock Phase IsNight Scale HourChanged Set")
end)

t.test("with no game state every field reads as nothing, and nothing is looked up", function()
    for _, name in ipairs({ "Hour", "Minute", "Clock", "Phase", "IsNight", "Scale" }) do t.eq(game.Time[name], nil, "Time." .. name) end
    t.eq(game.Weather.Current, nil)
    t.eq(game.Weather.Tier, nil)
    t.eq(game.Weather.IsStorm, false)
    t.eq(game.Weather.Active, nil)
    for _, name in ipairs(getmetatable(game.Prospect).__names()) do t.eq(game.Prospect[name], nil, "Prospect." .. name) end
    t.eq(fake.calls.subsystem, 0)
    t.eq(fake.calls.names[TIME], 0)
    t.eq(values.finds, finds)
end)

t.test("at the title screen there is no clock, no prospect and no weather to list", function()
    more.title()
    frames(1)
    for _, name in ipairs({ "Hour", "Minute", "Clock", "Phase", "IsNight", "Scale" }) do t.eq(game.Time[name], nil, "Time." .. name) end
    for _, name in ipairs(getmetatable(game.Prospect).__names()) do t.eq(game.Prospect[name], nil, "Prospect." .. name) end
    t.eq(game.IsHost, true, "the title screen has a game mode of its own")
    t.eq(game.Weather.Active, nil)
    t.eq(game.Weather.Current, nil)
    t.eq(fake.calls.subsystem, 0, "the clock is not looked up outside a prospect")
    t.eq(fake.calls.names[TIME], 0)

    -- a plain player state has a name and nothing else
    local menu = values.actor(kit.classes.PlayerState, "PlayerState_0", { PlayerNamePrivate = world.string("Menu"), Location = { 0, 0, 0 } })
    local player = instance.wrap(menu)
    t.eq(player.PlayerName, "Menu")
    t.eq(player.IsHost, nil)
    t.eq(player.Character, nil)
    t.eq(#guard.errors(), 0)
end)

-- ------------------------------------------------------------------------------------------------------------ time

t.test("game.Time gives the hour, the minute, the clock and the part of the day, asked of the game on each read", function()
    local place = enter()
    local named = fake.calls.names[TIME]
    local clock = game.Time
    t.eq(clock.Hour, 11)
    t.eq(math.type(clock.Hour), "integer")
    t.eq(clock.Minute, 52)
    t.eq(math.type(clock.Minute), "integer")
    t.eq(clock.Clock, "11:52")
    t.eq(clock.Phase, "Day")
    t.eq(clock.IsNight, false)
    place.store.TimeOfDay = 1170.6022949219
    t.eq(clock.Hour, 19)
    t.eq(clock.Minute, 30)
    t.eq(clock.Clock, "19:30")
    t.eq(clock.Phase, "Night")
    t.eq(clock.IsNight, true)
    place.store.TimeOfDay = 69.754
    t.eq(clock.Clock, "1:09")
    t.eq(clock.IsNight, true)
    for _, case in ipairs({
        { 0, "0:00", "Night" }, { 359.99, "5:59", "Night" }, { 360, "6:00", "Morning" }, { 599.5, "9:59", "Morning" },
        { 600, "10:00", "Day" }, { 839.9, "13:59", "Day" }, { 840, "14:00", "Afternoon" }, { 1079.9, "17:59", "Afternoon" },
        { 1080, "18:00", "Night" }, { 1439.99, "23:59", "Night" }, { 1440, "0:00", "Night" },
    }) do
        place.store.TimeOfDay = case[1]
        t.eq(clock.Clock, case[2], "the clock at " .. case[1])
        t.eq(clock.Phase, case[3], "the part of the day at " .. case[2])
        t.eq(clock.IsNight, case[3] == "Night")
    end
    t.eq(fake.calls.names[TIME] - named, 1, "the table of the parts of the day is read once on a map")
    t.eq(#guard.errors(), 0)
end)

t.test("the parts of the day are read again on another map, and without the table Phase reads as nothing", function()
    local place = enter({ state = { TimeOfDay = 1100 } })
    t.eq(game.Time.Phase, "Night")
    more.phase_rows.Night.StartingHour = 20
    t.eq(game.Time.Phase, "Night", "what was read on this map stays")
    place = enter({ state = { TimeOfDay = 1100 } })
    t.eq(game.Time.Phase, nil, "no row of the table covers 18:20 now")
    t.eq(game.Time.IsNight, nil)
    t.eq(game.Time.Hour, 18)
    more.phase_rows.Night.StartingHour = 18

    local kept = world.static[TIME]
    world.static[TIME] = nil
    session.flush()
    local newest, misses = log.newest_id(), values.misses
    t.eq(game.Time.Phase, nil)
    t.eq(game.Time.IsNight, nil)
    t.eq(game.Time.Clock, "18:20", "the clock itself needs no table")
    t.eq(game.Time.Phase, nil)
    t.eq(values.misses - misses, 1, "what the game does not have is looked for once")
    local said = warnings(newest)
    t.eq(#said, 1)
    t.ok(said[1].message:find("the parts of the day could not be read", 1, true), said[1].message)
    world.static[TIME] = kept
    session.flush()
    t.eq(game.Time.Phase, "Night")
    t.ok(place.state)
end)

t.test("Scale is the speed the clock is set to, and the clock is looked up once on a map", function()
    local place = enter({ scale = 1 })
    local asked = fake.calls.subsystem
    t.eq(game.Time.Scale, 1)
    place.clock_store.TimeScale = 2.5
    t.eq(game.Time.Scale, 2.5, "each read asks the clock")
    frames(5)
    t.eq(game.Time.Scale, 2.5)
    t.eq(fake.calls.subsystem - asked, 1)
    place = enter({ scale = 0.5 })
    t.eq(game.Time.Scale, 0.5)
    t.eq(fake.calls.subsystem - asked, 2)
    t.eq(world.dead_touches, 0, world.dead_where)

    -- a game without the clock's class
    local kept = world.static[CLOCK]
    world.static[CLOCK] = nil
    session.flush()
    local misses = values.misses
    t.eq(game.Time.Scale, nil)
    t.eq(game.Time.Scale, nil)
    t.eq(values.misses - misses, 1, "the class is looked for once")
    world.static[CLOCK] = kept
    session.flush()
    t.eq(game.Time.Scale, 0.5)

    -- a game whose library of subsystems is not there
    local library = world.static[SUBSYSTEMS]
    world.static[SUBSYSTEMS] = nil
    place = enter()
    local newest = log.newest_id()
    t.eq(game.Time.Scale, nil)
    t.eq(game.Time.Scale, nil)
    local said = warnings(newest)
    t.eq(#said, 1)
    t.ok(said[1].message:find("the game's clock could not be found", 1, true), said[1].message)
    t.eq(game.Time.Hour, 11, "the rest of the clock works")
    world.static[SUBSYSTEMS] = library
    place = enter()
    t.eq(game.Time.Scale, 1)
    t.ok(place.clock)
    t.eq(#guard.errors(), 0)
end)

t.test("HourChanged looks at the clock only while a handler is connected, and fires with the hour and the one before", function()
    local place = enter()
    quiet()
    world.watch = {}
    frames(63)
    t.eq(world.watch.TimeOfDay, nil, "nobody looks at the clock while nobody listens")
    local seen, note = recorder()
    local connection = game.Time.HourChanged:Connect(note)
    t.ok(Wax.modules["engine.watch"], "the first handler loaded engine.watch")
    t.eq(sched.Frame.count, 1)
    t.eq(world.watch.TimeOfDay, 1, "one look when the first handler connects, to take note")
    world.watch = {}
    frames(63)
    t.eq(world.watch.TimeOfDay, 2, "two looks a second")
    t.eq(#seen, 0)
    place.store.TimeOfDay = 725
    pass(0.6)
    t.eq(#seen, 1)
    t.eq(seen[1][1], 12)
    t.eq(seen[1][2], 11)
    place.store.TimeOfDay = 739.9
    pass(0.6)
    t.eq(#seen, 1, "another minute of the same hour is no change")
    place.store.TimeOfDay = 5
    pass(0.6)
    t.eq(#seen, 2)
    t.eq(seen[2][1], 0)
    t.eq(seen[2][2], 12)
    connection:Disconnect()
    quiet()
    world.watch = {}
    place.store.TimeOfDay = 100
    frames(63)
    t.eq(world.watch.TimeOfDay, nil, "nothing is read once nobody listens")
    world.watch = nil
    t.eq(#seen, 2)
    t.eq(session.stats().signals.Hour.handlers, 0)
    t.eq(session.stats().signals.Hour.looking, false)
end)

t.test("connected at the title screen, the first hour found on each map is where HourChanged starts from", function()
    map = map + 1
    more.travel("Title_" .. map)
    frames(1)
    more.title()
    frames(1)
    quiet()
    local seen, note = recorder()
    local connection = game.Time.HourChanged:Connect(note)
    world.watch = {}
    pass(0.6)
    t.eq(#seen, 0)
    t.eq(world.watch.TimeOfDay, nil, "there is no clock to read")
    world.watch = nil
    local place = enter({ state = { TimeOfDay = 425 } })
    pass(0.6)
    t.eq(#seen, 0, "the hour found on entering is not a change")
    place.store.TimeOfDay = 480
    pass(0.6)
    t.eq(#seen, 1)
    t.eq(seen[1][1], 8)
    t.eq(seen[1][2], 7)
    place = enter({ state = { TimeOfDay = 1200 } })
    pass(0.6)
    t.eq(#seen, 1, "another map at another hour is not a change")
    place.store.TimeOfDay = 1260
    pass(0.6)
    t.eq(#seen, 2)
    t.eq(seen[2][1], 21)
    t.eq(seen[2][2], 20)
    t.eq(connection.Connected, true)
    connection:Disconnect()
    quiet()
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(#guard.errors(), 0)
end)

t.test("a mod's handler goes with the mod, the looking goes on for the others, and Once looks until it is done", function()
    local place = enter()
    quiet()
    local first, second = scope.new("FirstMod"), scope.new("SecondMod")
    local got = {}
    local mine = scope.run(first, function()
        return game.Time.HourChanged:Connect(function(hour) got[#got + 1] = "first " .. hour end)
    end)
    scope.run(second, function() game.Time.HourChanged:Connect(function(hour) got[#got + 1] = "second " .. hour end) end)
    t.eq(first:size(), 1, "a mod owns its own connection and nothing else")
    first:destroy()
    t.eq(mine.Connected, false)
    t.eq(sched.Frame.count, 1)
    place.store.TimeOfDay = 780
    pass(0.6)
    t.eq(table.concat(got, ", "), "second 13")
    second:destroy()
    quiet()
    t.eq(Wax.import("engine.watch").stats().watching, 0)

    local once
    game.Time.HourChanged:Once(function(hour, previous) once = hour .. " after " .. previous end)
    t.eq(sched.Frame.count, 1)
    place.store.TimeOfDay = 840
    pass(0.6)
    t.eq(once, "14 after 13")
    quiet()
    game.Time.HourChanged:Connect(function() end)
    game.Time.HourChanged:Connect(function() end)
    t.eq(sched.Frame.count, 1)
    game.Time.HourChanged:DisconnectAll()
    quiet()
    t.raises(function() game.Time.HourChanged:Connect("handler") end, "Connect expects a function, got string")
    quiet()
end)

-- --------------------------------------------------------------------------------------------------------- weather

t.test("game.Weather tells the weather on the local player's character, its tier and whether it is a storm", function()
    enter()
    local who = more.player()
    possess(who)
    local rows = fake.calls.rows[WEATHER]
    local sky = game.Weather
    t.eq(sky.Current, nil, "clear weather")
    t.eq(sky.Tier, nil)
    t.eq(sky.IsStorm, false)
    who.state_store.LocalWeatherEvent = weather("T3_Conifer_Rain")
    t.eq(sky.Current, "T3_Conifer_Rain")
    t.eq(sky.Tier, 3)
    t.eq(sky.IsStorm, true)
    who.state_store.LocalWeatherEvent = weather("T0_Conifer_Rain")
    t.eq(sky.Current, "T0_Conifer_Rain")
    t.eq(sky.Tier, 0)
    t.eq(sky.IsStorm, false, "tier 0 is no storm")
    who.state_store.LocalWeatherEvent = weather("T1_Conifer_Rain")
    t.eq(sky.Tier, 1)
    t.eq(sky.IsStorm, true)
    who.state_store.LocalWeatherEvent = weather("NoWeather")
    t.eq(sky.Current, "NoWeather", "a row of the game's own")
    t.eq(sky.Tier, 0)
    t.eq(sky.IsStorm, false)
    who.state_store.LocalWeatherEvent = weather("Unlisted_Weather")
    t.eq(sky.Current, "Unlisted_Weather")
    t.eq(sky.Tier, nil, "the table has no such row")
    t.eq(sky.IsStorm, false)
    t.eq(sky.Tier, nil)
    t.eq(fake.calls.rows[WEATHER] - rows, 5, "the table is asked once for each event")

    possess(nil)
    t.eq(sky.Current, nil, "no character, no weather to tell")
    t.eq(sky.IsStorm, false)
    possess(kit.station())
    t.eq(sky.Current, nil, "a character with no state")
    t.eq(sky.Tier, nil)
    possess(nil)
    t.eq(#guard.errors(), 0)
end)

t.test("Active lists every running weather event for the host, and is nothing for a client", function()
    local place = enter({ weather = { { "T2_Arctic_Snow", "Arctic", 43819 }, { "T1_Desert_Wind", "Desert", 46645 },
        { "Unlisted_Weather", "None", 5 } } })
    t.eq(game.IsHost, true)
    local reads = fake.reads
    local list = game.Weather.Active
    t.eq(#list, 3)
    t.eq(list[1].Event, "T2_Arctic_Snow")
    t.eq(list[1].Biome, "Arctic")
    t.eq(list[1].Since, 43819)
    t.eq(list[1].Tier, 2)
    t.eq(list[2].Event, "T1_Desert_Wind")
    t.eq(list[2].Biome, "Desert")
    t.eq(list[2].Tier, 1)
    t.eq(list[3].Biome, nil)
    t.eq(list[3].Tier, nil)
    t.eq(getmetatable(list[1]), nil)
    t.eq(fake.reads - reads, 3, "each entry was read once")
    t.ok(not rawequal(game.Weather.Active, list), "a new list each time")

    for i = #place.weather, 1, -1 do place.weather[i] = nil end
    reads = fake.reads
    t.eq(#game.Weather.Active, 0)
    t.eq(fake.reads, reads, "a list with nothing in it is never read into")
    t.eq(fake.strays, 0, fake.stray_where)

    local newest = log.newest_id()
    place.controller_store.CurrentWeather = nil
    t.eq(game.Weather.Active, nil, "a list that is not where it was")
    t.eq(game.Weather.Active, nil)
    local said = warnings(newest)
    t.eq(#said, 1)
    t.ok(said[1].message:find("the weather that is running could not be read", 1, true), said[1].message)

    enter({ host = false })
    t.eq(game.IsHost, false)
    t.eq(game.Weather.Active, nil, "only the host has the list")
    t.eq(game.Time.Hour, 11, "a client reads the clock all the same")
    t.eq(#guard.errors(), 0)
end)

t.test("Weather.Changed fires with the event and the one before, with nil for clear weather", function()
    enter()
    local who = more.player()
    possess(who)
    quiet()
    local seen = {}
    local connection = game.Weather.Changed:Connect(function(current, previous)
        seen[#seen + 1] = tostring(current) .. " after " .. tostring(previous)
    end)
    t.eq(sched.Frame.count, 1)
    pass(1.1)
    t.eq(#seen, 0, "the weather that is there when a handler connects is not announced")
    who.state_store.LocalWeatherEvent = weather("T1_Conifer_Rain")
    pass(1.1)
    t.eq(seen[1], "T1_Conifer_Rain after nil")
    who.state_store.LocalWeatherEvent = weather("T3_Conifer_Rain")
    pass(1.1)
    t.eq(seen[2], "T3_Conifer_Rain after T1_Conifer_Rain")
    who.state_store.LocalWeatherEvent = weather("None")
    pass(1.1)
    t.eq(seen[3], "nil after T3_Conifer_Rain")
    possess(nil)
    pass(1.1)
    t.eq(#seen, 3, "with no character there is nothing to tell")
    who.state_store.LocalWeatherEvent = weather("T6_Conifer_Rain")
    possess(who)
    pass(1.1)
    t.eq(seen[4], "T6_Conifer_Rain after nil")

    -- on another map the first weather found is where it starts from
    enter()
    local next_one = more.player({ state = { LocalWeatherEvent = weather("T2_Arctic_Snow") } })
    possess(next_one)
    pass(1.1)
    t.eq(#seen, 4)
    next_one.state_store.LocalWeatherEvent = weather("T3_Arctic_Whiteout")
    pass(1.1)
    t.eq(seen[5], "T3_Arctic_Whiteout after T2_Arctic_Snow")
    connection:Disconnect()
    quiet()
    possess(nil)
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(#guard.errors(), 0)
end)

-- -------------------------------------------------------------------------------------------------------- prospect

t.test("game.Prospect tells which prospect this is and how long it has run", function()
    local place = enter()
    local here = game.Prospect
    t.eq(here.Id, "B3BF146A43E90D4239F50A80B5D13762")
    t.eq(here.Name, "Tier1_Forest_Recon_0")
    t.eq(here.Mission, "OLY_Forest_Recon")
    local enums = fake.enums
    t.eq(here.Difficulty, "Medium")
    t.eq(fake.enums - enums, 1, "the difficulty is an enum, and reading one leaves a global behind as UE4SS does")
    t.eq(rawget(_G, "Enum_Difficulty"), nil, "and the global was taken away")
    t.eq(here.Elapsed, 44208)
    t.eq(here.Duration, 604800)
    t.eq(here.Remaining, 560592)
    t.eq(here.IsOpenWorld, false)
    t.eq(here.IsOutpost, false)
    t.eq(here.Seed, 1117682762)
    place.store.LevelTimeElapsedSec = 45706
    t.eq(here.Remaining, 559094, "what the game's own getter answered at that moment")
    place.store.LevelTimeElapsedSec = 700000
    t.eq(here.Remaining, 0, "never below 0")
    place.store.ProspectDurationSec = 0
    t.eq(here.Remaining, nil, "no length, nothing left to count")
    local info = place.store.ReplicatedActiveProspect
    info.FactionMissionDTKey = world.string("")
    t.eq(here.Mission, nil, "a prospect with no mission")
    info.Difficulty = 4
    t.eq(here.Difficulty, "Extreme")
    info.Difficulty = 1
    t.eq(here.Difficulty, "Easy")
    info.Difficulty = 0
    t.eq(here.Difficulty, nil)
    info.Difficulty = 9
    t.eq(here.Difficulty, nil)
    place.store.bIsOpenWorldProspect, place.store.bIsOutpostProspect = true, true
    t.eq(here.IsOpenWorld, true)
    t.eq(here.IsOutpost, true)

    -- members a game update took away read as nothing
    place.store.Seed, place.store.bIsOutpostProspect, place.store.ReplicatedActiveProspect = nil, nil, nil
    t.eq(here.Seed, nil)
    t.eq(here.IsOutpost, nil)
    t.eq(here.Id, nil)
    t.eq(here.Name, nil)
    t.eq(here.Difficulty, nil)
    t.eq(here.Elapsed, 700000)
    t.eq(#guard.errors(), 0)
end)

-- --------------------------------------------------------------------------------------------------------- players

t.test("a player of the session has a name, the host mark and a character", function()
    local host
    enter(nil, function(made)
        host = more.player({ name = "Bostonstrong567" })
        more.join(made, host)
    end)
    local players = game.Players:GetPlayers()
    t.eq(#players, 1)
    local player = players[1]
    t.eq(player.PlayerName, "Bostonstrong567")
    t.eq(player.IsHost, true)
    t.ok(rawequal(player.Character, instance.wrap(host.actor)), "the Instance of the character itself")
    host.player_state_store.PlayerNamePrivate = world.string("")
    t.eq(player.PlayerName, nil, "an empty name is no name yet")
    host.player_state_store.bIsHost = false
    t.eq(player.IsHost, false)
    host.player_state_store.PawnPrivate = world.INVALID
    t.eq(player.Character, nil)
    t.raises(function() player.PlayerName = "Other" end, "PlayerName is read-only")
    local names = {}
    for _, name in ipairs(player:GetMembers()) do names[name] = true end
    t.ok(names.PlayerName and names.IsHost and names.Character and names.PlayerNamePrivate)
end)

t.test("Joined and Left fire for players who come and go, and not for those who are there", function()
    local host
    local place = enter(nil, function(made)
        host = more.player({ name = "Bostonstrong567" })
        more.join(made, host)
    end)
    quiet()
    local events = {}
    local joined = game.Players.Joined:Connect(function(who) events[#events + 1] = "joined " .. tostring(who.PlayerName) end)
    local left = game.Players.Left:Connect(function(who, name)
        events[#events + 1] = ("left %s %s"):format(tostring(name), tostring(who:IsValid()))
    end)
    t.eq(sched.Frame.count, 1, "the two signals share one look")
    local reads = fake.reads
    pass(1.1)
    t.eq(#events, 0, "who is there when a handler connects is not announced")
    t.ok(fake.reads > reads, "the list of players is looked at")

    local guest = more.player({ name = "Guest" })
    guest.player_state_store.bIsHost = false
    more.join(place, guest)
    pass(1.1)
    t.eq(#events, 1)
    t.eq(events[1], "joined Guest")
    guest.player_state_store.PlayerNamePrivate = world.string("Guest Two")
    pass(1.1)
    t.eq(#events, 1, "a name that changes is no coming or going")
    more.drop(place, guest)
    pass(1.1)
    t.eq(#events, 2)
    t.eq(events[2], "left Guest Two false", "the name last seen, and an Instance that says it is gone")
    t.eq(world.dead_touches, 0, world.dead_where)

    -- a list that cannot be read tells nothing and breaks nothing
    local newest = log.newest_id()
    place.store.PlayerArray = nil
    pass(1.1)
    t.eq(#events, 2)
    local said = warnings(newest)
    t.eq(#said, 1)
    t.ok(said[1].message:find("the players of the session could not be read", 1, true), said[1].message)
    place.store.PlayerArray = fake.list(place.players, place.state)

    -- on another map the players who are there are not announced
    local second
    place = enter(nil, function(made)
        second = more.player({ name = "Second" })
        more.join(made, second)
    end)
    pass(1.1)
    t.eq(#events, 2)
    local third = more.player({ name = "Third" })
    more.join(place, third)
    pass(1.1)
    t.eq(events[3], "joined Third")
    t.eq(world.dead_touches, 0, world.dead_where)

    -- one who leaves and one who comes at the same address between two looks are both told, the leaving first
    local address = third.player_state:GetAddress()
    more.drop(place, third)
    local fourth = more.player({ name = "Fourth" })
    rawset(fourth.player_state, "__address", address)
    more.join(place, fourth)
    pass(1.1)
    t.eq(events[4], "left Third false")
    t.eq(events[5], "joined Fourth")
    t.eq(#events, 5)
    t.eq(world.dead_touches, 0, world.dead_where)

    joined:Disconnect()
    t.eq(sched.Frame.count, 1, "a handler is left")
    left:Disconnect()
    quiet()
    t.eq(fake.strays, 0, fake.stray_where)
    t.eq(#guard.errors(), 0)
end)

-- --------------------------------------------------------------------------------------------------------- the rest

t.test("a wrong name raises at the mod's line with the nearest name, and nothing can be assigned", function()
    enter()
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        return game.Time.Hours
    end, "Hours is not a member of game.Time. Did you mean 'Hour'?")
    at(err, line)
    t.raises(function() return game.Weather.Storm end, "Storm is not a member of game.Weather. Did you mean 'IsStorm'?")
    t.raises(function() return game.Prospect.Dificulty end, "Dificulty is not a member of game.Prospect. Did you mean 'Difficulty'?")
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        game.Time.Hour = 5
    end, "game.Time.Hour cannot be assigned because game.Time is read-only")
    at(err, line)
    t.raises(function() game.Time.HourChanged = nil end, "game.Time.HourChanged cannot be assigned")
    t.raises(function() game.Weather.Changed = nil end, "game.Weather.Changed cannot be assigned")
    t.raises(function() game.Prospect.Seed = 1 end, "game.Prospect.Seed cannot be assigned")
    t.eq(game.Time.HourChanged.name, "game.Time.HourChanged")
    t.eq(game.Weather.Changed.name, "game.Weather.Changed")
end)

t.test("when engine.watch cannot be loaded a signal says so at the mod's line, and the fields work as before", function()
    enter()
    local lone = t.new_wax()
    local import = lone.import
    ---@diagnostic disable-next-line: duplicate-set-field
    lone.import = function(name)
        if name == "engine.watch" then error("wax module 'engine.watch' failed while loading:\nit is broken", 0) end
        return import(name)
    end
    lone.import("engine.game").start()
    lone.import("world.session").start()
    local lone_game = lone.import("engine.game").root
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        lone_game.Time.HourChanged:Connect(function() end)
    end, "this signal needs engine.watch, which did not load")
    at(err, line)
    t.ok(tostring(err):find("it is broken", 1, true), tostring(err))
    t.eq(lone_game.Time.HourChanged.count, 0, "nothing was connected")
    t.eq(lone_game.Time.Hour, 11)
    t.eq(lone_game.Prospect.Name, "Tier1_Forest_Recon_0")
end)

-- ---------------------------------------------------------------------------------------- setting the time of day

local function sets() return actions.calls.SetTimeOfDay or 0 end

t.test("the host sets the time of day forward with the game's own call, and it reads back at once", function()
    local place = actions.prospect(enter())
    local silent, before = values.silent, sets()
    t.eq(game.IsHost, true)
    t.eq(game.Time.Clock, "11:52")
    t.eq(game.Time:Set(14, 30), true)
    t.eq(place.store.TimeOfDay, 870)
    t.eq(math.type(place.store.TimeOfDay), "float", "the game's clock is handed minutes since midnight")
    t.eq(game.Time.Clock, "14:30")
    t.eq(game.Time.Phase, "Afternoon")
    t.eq(game.Time:Set(20), true, "the minute may be left out")
    t.eq(game.Time.Hour, 20)
    t.eq(game.Time.IsNight, true)
    t.eq(sets(), before + 2)
    t.eq(game.Time:Set(20, 0), true, "the time it is already is left alone")
    t.eq(sets(), before + 2)
    t.eq(game.Time:Set(23, 59), true)
    t.eq(game.Time.Clock, "23:59")
    t.eq(actions.days, 0, "no day went by")
    t.eq(values.silent, silent)
    t.eq(table.concat(getmetatable(game.Time).__names(), " "), "Hour Minute Clock Phase IsNight Scale HourChanged Set")
end)

t.test("an earlier time is refused in plain words, because the game would count it as the next day", function()
    local place = actions.prospect(enter({ state = { TimeOfDay = 1270.5 } }))
    local before = sets()
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        game.Time:Set(6)
    end, "game.Time:Set(6, 0) is earlier than the game's clock, which says 21:10. That clock only goes forward within a day: "
        .. "the game would count an earlier time as the next day, and Wax does not do that yet")
    at(err, line)
    t.raises(function() game.Time:Set(21, 9) end, "is earlier than the game's clock, which says 21:10")
    t.eq(game.Time:Set(21, 10), true, "the minute the clock is in is no change")
    t.eq(sets(), before, "the game was not asked")
    t.eq(place.store.TimeOfDay, 1270.5)
    t.eq(actions.days, 0)
end)

t.test("wrong values, a client, a missing clock and the title screen are refused, and the game is not asked", function()
    actions.prospect(enter())
    local before = sets()
    local expects = "game.Time:Set expects an hour from 0 to 23 and, if you like, a minute from 0 to 59"
    t.raises(function() game.Time:Set() end, expects)
    t.raises(function() game.Time:Set(24) end, expects)
    t.raises(function() game.Time:Set(12.5) end, expects)
    t.raises(function() game.Time:Set("noon") end, expects)
    t.raises(function() game.Time:Set(12, 60) end, expects)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        game.Time.Set(12)
    end, "call Set with a colon: game.Time:Set(...)")
    at(err, line)
    t.raises(function() game.Time.Set = nil end, "game.Time.Set cannot be assigned")

    local kept = world.static[CLOCK]
    world.static[CLOCK] = nil
    session.flush()
    t.raises(function() game.Time:Set(23) end, "the game's clock was not found, so the time cannot be set")
    world.static[CLOCK] = kept
    session.flush()

    actions.prospect(enter({ host = false }))
    t.eq(game.IsHost, false)
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        game.Time:Set(20)
    end, "only the host can set the time of day. You are in someone else's game, where its server decides")
    at(err, line)
    t.eq(game.Time.Hour, 11, "reading goes on working")

    more.travel("TitleScreen")
    frames(1)
    more.title()
    frames(1)
    t.raises(function() game.Time:Set(20) end, "game.Time:Set only works in a prospect, and you are not in one")
    t.eq(sets(), before)
end)

t.test("what the game has a call for that was never tried says so, and the game is not asked", function()
    actions.prospect(enter())
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        game.Time:SetScale(2)
    end, "game.Time:SetScale is not in this version of Wax. The game's own call for it, SetTimeScale, has not been tried from Lua yet")
    at(err, line)
    t.raises(function() game.Weather:Start("Conifer", "T3_Conifer_Rain") end,
        "game.Weather:Start is not in this version of Wax. The game's own call for it, AddWeatherEvent, has not been tried from Lua yet")
    t.raises(function() game.Weather:StopAll() end,
        "game.Weather:StopAll is not in this version of Wax. The game's own call for it, ForceStopAllWeatherEvents, has not been tried")
    t.raises(function() game.Weather.Start("Conifer") end, "call Start with a colon: game.Weather:Start(...)")
    t.eq(actions.calls.SetTimeScale, nil)
    t.eq(actions.calls.AddWeatherEvent, nil)
    t.eq(actions.calls.ForceStopAllWeatherEvents, nil)
end)

t.test("nothing here touched a freed object, read outside a list, crashed the stand-in or left anything behind", function()
    t.eq(actions.untried, 0, table.concat(actions.log, " | "))
    t.eq(actions.days, 0, "the clock was never set back")
    frames(10)
    quiet()
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(fake.strays, 0, fake.stray_where)
    t.eq(values.crashes + values.misuse, 0, table.concat(values.log, " | "))
    t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace)
    t.eq(#easy.clashes(), 0)
    t.eq(#easy.stats().unseen, 0, table.concat(easy.stats().unseen, ", "))
    t.eq(Wax.import("engine.watch").stats().watching, 0)
    for name, signal in pairs(session.stats().signals) do
        t.eq(signal.handlers, 0, name)
        t.eq(signal.looking, false, name)
    end
end)

-- What things take on the stand-in, in a tight loop. The game takes 4 to 7 times as long once a frame.
if arg and arg[1] == "cost" then
    guard.suspend_watchdog(true)
    local function each(rounds, body)
        local started = os.clock()
        for _ = 1, rounds do body() end
        return (os.clock() - started) / rounds * 1e6
    end
    local running = {}
    for i = 1, 15 do running[i] = { "T2_Arctic_Snow", "Arctic", 43000 + i } end
    enter({ weather = running })
    local who = more.player({ state = { LocalWeatherEvent = weather("T3_Conifer_Rain") } })
    possess(who)
    local sink, frame_stats = 0, sched.stats
    local empty = each(1000000, function() sink = sink + 1 end)
    local hour = each(200000, function() sink = sink + game.Time.Hour end) - empty
    local first = each(100000, function()
        frame_stats.frame = frame_stats.frame + 1
        sink = sink + game.Time.Hour
    end) - empty
    local phase = each(200000, function() sink = sink + #game.Time.Phase end) - empty
    local scale = each(200000, function() sink = sink + game.Time.Scale end) - empty
    local current = each(200000, function() sink = sink + #game.Weather.Current end) - empty
    local storm = each(200000, function() sink = sink + (game.Weather.IsStorm and 1 or 0) end) - empty
    local active = each(20000, function() sink = sink + #game.Weather.Active end) - empty
    local remaining = each(200000, function() sink = sink + game.Prospect.Remaining end) - empty
    local name = each(200000, function() sink = sink + #game.Prospect.Name end) - empty
    print(("cost on the stand-in, us: Time.Hour %.2f, the first Time.Hour of a frame %.2f, Time.Phase %.2f, Time.Scale %.2f, "
        .. "Weather.Current %.2f, Weather.IsStorm %.2f, Weather.Active (15 events) %.2f, Prospect.Remaining %.2f, Prospect.Name %.2f")
        :format(hour, first, phase, scale, current, storm, active, remaining, name))
    assert(sink > 0)
    guard.suspend_watchdog(false)
end

t.finish("session")
