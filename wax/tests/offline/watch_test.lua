-- Offline tests for engine.watch: signals fed by looking, Instance:GetPropertyChangedSignal, game.Frame, and the lines
-- proposed for task.every. The engine is a stand-in in which an object that was freed raises on any use.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\watch_test.lua
-- Add the word cost to print what a frame and a look take on the stand-in.

local t = dofile("wax/tests/offline/harness.lua")
local world = dofile("wax/tests/offline/fake_world.lua")
world.install()
local values = dofile("wax/tests/offline/fake_values.lua")
values.install(world)

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)

local PENDING_KILL = 0x20000000
local object_class = world.class("/Script/CoreUObject.Object")
local actor_class = values.class("/Script/Engine.Actor", object_class)
world.class("/Script/Engine.World", object_class)
local component_class = world.class("/Script/Engine.ActorComponent", object_class)
world.class("/Script/Engine.SceneComponent", component_class)
local state_class = values.class("/Script/Icarus.ActorState", component_class, {
    Health = "IntProperty", MaxHealth = "IntProperty", CurrentAliveState = "EnumProperty", Shelter = "FloatProperty",
    bHasHealthRegen = "BoolProperty",
})
local stats_class = values.class("/Script/Icarus.IcarusStatContainer", component_class, { Total = "IntProperty" })
local modifier_class = values.class("/Script/Icarus.ModifierStateComponent", component_class, { RemainingTime = "FloatProperty" })
local pawn_class = values.class("/Script/Engine.Pawn", actor_class)
local character_class = values.class("/Script/Icarus.IcarusCharacter", pawn_class, {
    ActorState = "ObjectProperty", StatContainer = "ObjectProperty", CurrentTarget = "ObjectProperty", CurrentLevel = "IntProperty",
    Biome = "NameProperty", Title = "TextProperty", PlayerName = "StrProperty",
    Spot = { "StructProperty", struct = "/Script/CoreUObject.Vector" }, Marks = { "ArrayProperty", inner = "IntProperty" },
    Precise = "DoubleProperty", OnHit = "MulticastInlineDelegateProperty", Keeper = "WeakObjectProperty",
}, { IsAlive = { returns = "BoolProperty", call = function() return true end } })
local wolf_class = values.class("/Game/BP/AI/BP_Wolf.BP_Wolf_C", character_class)
local subsystem_class = values.class("/Script/Icarus.TimeOfDaySubsystem", object_class, { TimeScale = "FloatProperty" })

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
local task = sched.task

-- Frames of 16 ms on a clock the tests own. Seven of them pass one look at the usual pace, 63 pass a second.
local now, FRAME = 1000, 0.016
sched.clock = function() return now end
local function frames(count)
    for _ = 1, count or 1 do
        now = now + FRAME
        game_module.step()
        sched.step()
    end
end

local function quiet() t.eq(sched.Frame.count, 0, "nothing is left on the frame signal") end

local function recorder()
    local seen = {}
    return seen, function(value, previous) seen[#seen + 1] = { value, previous } end
end

local function at(err, line, what)
    t.ok(tostring(err):find("watch_test.lua:" .. line .. ":", 1, true), (what or "the error") .. " should name line " .. line .. ": " .. tostring(err))
end

local serial = 0
-- A creature with a state component its ActorState property keeps, and a stat container kept under another name than its own.
local function character(health, extra)
    serial = serial + 1
    local state, state_store = values.part(state_class, "ActorState",
        { Health = health or 100, MaxHealth = 100, CurrentAliveState = 0, Shelter = 0.5, bHasHealthRegen = true })
    local stats, stats_store = values.part(stats_class, "Stat Container", { Total = 78 })
    local parts = { state, stats }
    for _, part in ipairs(extra or {}) do parts[#parts + 1] = part end
    local actor, store = values.actor(wolf_class, "Wolf_" .. serial, {
        ActorState = state, StatContainer = stats, CurrentLevel = 5, Location = { 0, 0, 0 },
        Biome = values.name("Conifer"), Title = values.text("Alpha"), PlayerName = "Bob",
    }, parts)
    return { actor = actor, store = store, state = state, state_store = state_store, stats = stats, stats_store = stats_store,
             wolf = instance.wrap(actor) }
end

local function handle_module()
    local module = { taken = 0, dead = {} }
    function module.take(object)
        module.taken = module.taken + 1
        return { id = module.taken, address = object:GetAddress() }
    end
    function module.alive(handle) return not module.dead[handle.id] end
    return module
end

t.test("engine.watch is not loaded by the files the game starts with", function()
    t.eq(Wax.modules["engine.watch"], nil)
    quiet()
end)

local watch = Wax.import("engine.watch")

-- ----------------------------------------------------------------------------------------------- signals fed by looking

t.test("a signal nobody is connected to reads nothing and leaves nothing on the frame signal", function()
    local reads = 0
    local signal = watch.signal("Test.Idle", { read = function()
        reads = reads + 1
        return 1
    end })
    frames(30)
    t.eq(reads, 0)
    quiet()
    t.eq(watch.stats().watching, 0)
    t.eq(watch.stats().linked, false)
    t.eq(signal.count, 0)
end)

t.test("the first handler starts the looking, a change fires with the value and the one before, the last to leave ends it", function()
    quiet()
    local value, reads = 1, 0
    local signal = watch.signal("Test.Value", { read = function()
        reads = reads + 1
        return value
    end })
    local seen, note = recorder()
    local connection = signal:Connect(note)
    t.eq(reads, 1, "it is read once when the first handler connects")
    t.eq(sched.Frame.count, 1)
    frames(7)
    t.eq(reads, 2)
    t.eq(#seen, 0, "nothing changed")
    value = 2
    frames(3)
    t.eq(#seen, 0, "a change waits for the next look")
    frames(3)
    t.eq(#seen, 1)
    t.eq(seen[1][1], 2)
    t.eq(seen[1][2], 1)
    value = 3
    value = 4
    frames(7)
    t.eq(#seen, 2, "what happened between two looks is one change")
    t.eq(seen[2][1], 4)
    t.eq(seen[2][2], 2)
    connection:Disconnect()
    t.eq(connection.Connected, false)
    quiet()
    local had = reads
    value = 9
    frames(20)
    t.eq(reads, had, "nothing is read once nobody listens")
    t.eq(#seen, 2)
    t.eq(watch.stats().watching, 0)
end)

t.test("a value is looked at ten times a second, however many handlers there are", function()
    quiet()
    local reads = 0
    local signal = watch.signal("Test.Pace", { read = function()
        reads = reads + 1
        return 1
    end })
    local first = signal:Connect(function() end)
    local second = signal:Connect(function() end)
    t.eq(reads, 1, "the second handler adds no read")
    frames(63)
    t.eq(reads, 11)
    first:Disconnect()
    frames(7)
    t.ok(reads > 11, "one handler is left, so it is still looked at")
    second:Disconnect()
    quiet()
end)

t.test("every = seconds sets the pace, and no pace is faster than twenty looks a second", function()
    quiet()
    local slow, fast = 0, 0
    local a = watch.signal("Test.Slow", { every = 0.5, read = function()
        slow = slow + 1
        return 1
    end })
    local b = watch.signal("Test.Fast", { every = 0.001, read = function()
        fast = fast + 1
        return 1
    end })
    local one, two = a:Connect(function() end), b:Connect(function() end)
    frames(63)
    t.eq(slow, 1 + 2)
    t.eq(fast, 1 + 20)
    local paces = watch.stats().paces
    t.eq(#paces, 2)
    t.eq(paces[1].every, 0.05)
    t.eq(paces[2].every, 0.5)
    one:Disconnect()
    two:Disconnect()
    quiet()
    t.eq(#watch.stats().paces, 0)
end)

t.test("one frame that takes two seconds is one look, not twenty", function()
    quiet()
    local reads = 0
    local signal = watch.signal("Test.Hitch", { read = function()
        reads = reads + 1
        return 1
    end })
    local connection = signal:Connect(function() end)
    now = now + 2
    sched.step()
    t.eq(reads, 2)
    connection:Disconnect()
end)

t.test("Once and Wait start the looking too, and end it when they are done", function()
    quiet()
    local value = 1
    local signal = watch.signal("Test.Once", { read = function() return value end })
    local got
    signal:Once(function(new, old) got = new .. " after " .. old end)
    t.eq(sched.Frame.count, 1)
    value = 5
    frames(7)
    t.eq(got, "5 after 1")
    quiet()
    local waited
    task.spawn(function() waited = table.pack(signal:Wait()) end)
    t.eq(sched.Frame.count, 1)
    value = 6
    frames(7)
    t.eq(waited[1], 6)
    t.eq(waited[2], 5, "a new first look took note of what was there")
    quiet()
end)

t.test("a mod's handler is its own: unloading the mod disconnects it and ends the looking, and the frame link is no mod's", function()
    quiet()
    local reads = 0
    local signal = watch.signal("Test.Owned", { read = function()
        reads = reads + 1
        return 1
    end })
    local mod = scope.new("TestMod")
    local connection = scope.run(mod, function() return signal:Connect(function() end) end)
    t.eq(mod:size(), 1, "the mod owns its connection and nothing else")
    t.eq(sched.Frame.count, 1)
    mod:destroy()
    t.eq(connection.Connected, false)
    quiet()
    frames(7)
    t.eq(reads, 1)
end)

t.test("watchers of different paces look in the same frames and share what one of them found", function()
    quiet()
    local finds = 0
    local find = watch.shared(function()
        finds = finds + 1
        return finds
    end)
    local a = watch.signal("Test.A", { every = 0.1, read = function() return find() end })
    local b = watch.signal("Test.B", { every = 0.5, read = function() return find() end })
    local c = watch.signal("Test.C", { every = 0.1, read = function()
        find()
        return find()
    end })
    local connections = { a:Connect(function() end), b:Connect(function() end), c:Connect(function() end) }
    t.eq(finds, 3, "each first look is a round of its own")
    finds = 0
    frames(63)
    t.eq(finds, 10, "one find a round, for three watchers of two paces")
    find()
    find()
    t.eq(finds, 12, "outside a round nothing is kept")
    for _, connection in ipairs(connections) do connection:Disconnect() end
    quiet()
    t.raises(function() watch.shared("find") end, "watch.shared expects a function")
end)

t.test("watch.character finds the local player's character once for every watcher of a round", function()
    quiet()
    local who = character()
    world.possess(who.actor)
    t.ok(rawequal(watch.character(), who.wolf))
    local seen, connections = {}, {}
    for i = 1, 3 do
        local signal = watch.signal("Test.Me" .. i, { read = function()
            local me = watch.character()
            return me and me.ActorState.Health
        end })
        connections[i] = signal:Connect(function(value, previous)
            seen[#seen + 1] = ("%d: %s after %s"):format(i, tostring(value), tostring(previous))
        end)
    end
    world.watch = {}
    frames(7)
    t.eq(world.watch.Pawn, 1, "the controller was asked for its pawn once")
    who.state_store.Health = 60
    frames(6)
    table.sort(seen)
    t.eq(table.concat(seen, ", "), "1: 60 after 100, 2: 60 after 100, 3: 60 after 100")
    world.watch = nil
    world.possess(nil)
    frames(7)
    t.eq(#seen, 6, "with no character the readers gave nil, which is a change like any other")
    t.eq(watch.character(), nil)
    for _, connection in ipairs(connections) do connection:Disconnect() end
    quiet()
end)

t.test("a reader that raises is reported once, tried less often after five in a row, and picked up again when it works", function()
    quiet()
    local retry = watch.RETRY
    watch.RETRY = 1
    local broken, reads, result = true, 0, 7
    local signal = watch.signal("Test.Broken", { read = function()
        reads = reads + 1
        if broken then error("no state yet") end
        return result
    end })
    local newest, before = log.newest_id(), #guard.errors()
    local seen, note = recorder()
    local connection = signal:Connect(note)
    t.eq(#guard.errors(), before + 1)
    t.eq(guard.errors()[before + 1].label, "watching Test.Broken")
    t.ok(guard.errors()[before + 1].message:find("no state yet", 1, true))
    frames(63)
    t.eq(reads, 5, "after five failures it rests")
    t.eq(#guard.errors(), before + 1, "one report for the run of failures")
    local warnings = log.since(newest, { channel = "wax.watch", level = "warn" })
    t.eq(#warnings, 1)
    t.ok(warnings[1].message:find("Test.Broken could not be read 5 times in a row", 1, true), warnings[1].message)
    frames(63)
    t.eq(reads, 6, "one try a second while it rests")
    broken = false
    frames(63)
    t.ok(reads > 7, "it is looked at as before once it could be read: " .. reads)
    t.eq(#seen, 0, "the first value read is taken note of, not fired")
    t.eq(#log.since(newest, { channel = "wax.watch", text = "Test.Broken can be read again" }), 1)
    result = 8
    frames(7)
    t.eq(#seen, 1)
    t.eq(seen[1][1], 8)
    t.eq(seen[1][2], 7)
    connection:Disconnect()
    watch.RETRY = retry
    guard.clear_errors()
    quiet()
end)

t.test("plain tables are compared by what they hold, and a reader that changes its own table is still seen", function()
    quiet()
    local spot = { X = 1, Y = 2, Z = 3 }
    local fresh = watch.signal("Test.Spot", { read = function() return { X = spot.X, Y = spot.Y, Z = spot.Z, Tags = { "a", "b" } } end })
    local seen, note = recorder()
    local first = fresh:Connect(note)
    frames(13)
    t.eq(#seen, 0, "a new table that holds the same is no change")
    spot.X = 5
    frames(7)
    t.eq(#seen, 1)
    t.eq(seen[1][1].X, 5)
    t.eq(seen[1][2].X, 1)
    first:Disconnect()

    local own = { Count = 1, Nested = { Left = 3 } }
    local reused = watch.signal("Test.Own", { read = function() return own end })
    local seen_own, note_own = recorder()
    local second = reused:Connect(note_own)
    own.Nested.Left = 2
    frames(7)
    t.eq(#seen_own, 1, "the table is the same one, what it holds is not")
    t.eq(seen_own[1][1].Nested.Left, 2)
    t.eq(seen_own[1][2].Nested.Left, 3)
    second:Disconnect()

    local nan = watch.signal("Test.Nan", { read = function() return 0 / 0 end })
    local seen_nan, note_nan = recorder()
    local third = nan:Connect(note_nan)
    frames(13)
    t.eq(#seen_nan, 0, "not a number stays not a number")
    third:Disconnect()
    quiet()
end)

t.test("the reader is handed what it returned last, false and nil are values, and returning the same says nothing changed", function()
    quiet()
    ---@type any, any
    local source, handed = 3, "unset"
    local signal = watch.signal("Test.Keep", { read = function(previous)
        handed = previous
        if source == "same" then return previous end
        return source
    end })
    local seen, note = recorder()
    local connection = signal:Connect(note)
    t.eq(handed, nil, "the first look has nothing from before")
    source = "same"
    frames(7)
    t.eq(handed, 3)
    t.eq(#seen, 0)
    source = false
    frames(7)
    t.eq(seen[1][1], false)
    t.eq(seen[1][2], 3)
    source = nil
    frames(7)
    t.eq(handed, false)
    t.eq(seen[2][1], nil)
    t.eq(seen[2][2], false)
    source = 4
    frames(7)
    t.eq(seen[3][1], 4)
    t.eq(seen[3][2], nil)
    connection:Disconnect()
    quiet()
end)

t.test("watch.reset makes the next look take note only, and watch.check looks at once", function()
    quiet()
    local value, reads = 1, 0
    local signal = watch.signal("Test.Check", { read = function()
        reads = reads + 1
        return value
    end })
    t.eq(watch.check(signal), false, "nothing is read for a signal nobody listens to")
    t.eq(reads, 0)
    local seen, note = recorder()
    local connection = signal:Connect(note)
    value = 2
    watch.reset(signal)
    frames(7)
    t.eq(#seen, 0, "after a reset the value found is where it starts from")
    value = 3
    t.eq(watch.check(signal), true)
    t.eq(#seen, 1, "fired at once, between two looks")
    t.eq(seen[1][1], 3)
    t.eq(seen[1][2], 2)
    t.eq(watch.check(signal), false)
    frames(7)
    t.eq(#seen, 1, "the usual look finds nothing new")
    connection:Disconnect()
    quiet()
end)

t.test("handlers may disconnect, connect and pause while changes are being fired", function()
    quiet()
    local one, two = 1, 1
    local first = watch.signal("Test.First", { read = function() return one end })
    local second = watch.signal("Test.Second", { read = function() return two end })
    ---@type any, any, any
    local log_of, late, finished = {}, nil, false
    local own
    own = first:Connect(function(value)
        log_of[#log_of + 1] = "first " .. value
        own:Disconnect()
        late = second:Connect(function(new) log_of[#log_of + 1] = "second, joined late " .. new end)
    end)
    local pausing = second:Connect(function(value)
        task.wait(0.05)
        finished = value
    end)
    one, two = 2, 2
    frames(7)
    t.eq(table.concat(log_of, ", "), "first 2")
    t.eq(first.count, 0)
    frames(5)
    t.eq(finished, 2, "the handler that paused went on later")
    two = 3
    frames(7)
    t.eq(log_of[2], "second, joined late 3")
    pausing:Disconnect()
    late:Disconnect()
    frames(5)
    quiet()
    t.eq(#guard.errors(), 0)
end)

t.test("watch.signal says what it expects", function()
    local function read() return 1 end
    t.raises(function() watch.signal(5, { read = read }) end, "watch.signal expects a name for the signal")
    t.raises(function() watch.signal("Test.Bad", {}) end, "watch.signal expects { read = function, every = seconds }")
    local err = t.raises(function() watch.signal("Test.Bad", { read = read, evry = 1 }) end, "watch.signal has no option 'evry'")
    t.ok(tostring(err):find("'every'", 1, true), tostring(err))
    t.raises(function() watch.signal("Test.Bad", { read = read, every = 0 }) end, "the seconds between looks are a number above 0")
    t.raises(function() watch.signal("Test.Bad", { read = read, every = "fast" }) end, "got fast")
    local signal = watch.signal("Test.Good", { read = read })
    t.raises(function() signal:Connect("handler") end, "Connect expects a function, got string")
    quiet()
end)

-- ------------------------------------------------------------------------------- one value of an Instance, on an actor

t.test("a property of an actor fires with the new and the old value: a number, a name, text, a string", function()
    quiet()
    local who = character()
    local wolf = who.wolf
    local level = wolf:GetPropertyChangedSignal("CurrentLevel")
    t.ok(rawequal(level, wolf:GetPropertyChangedSignal("CurrentLevel")), "one signal for one value of one object")
    quiet()
    local seen = {}
    local function note(what) return function(value, previous) seen[#seen + 1] = ("%s %s after %s"):format(what, tostring(value), tostring(previous)) end end
    local connections = {
        level:Connect(note("level")), wolf:GetPropertyChangedSignal("Biome"):Connect(note("biome")),
        wolf:GetPropertyChangedSignal("Title"):Connect(note("title")), wolf:GetPropertyChangedSignal("PlayerName"):Connect(note("name")),
    }
    frames(13)
    t.eq(#seen, 0)
    who.store.CurrentLevel = 6
    who.store.Biome = values.name("Arctic")
    who.store.Title = values.text("Omega")
    who.store.PlayerName = "Rob"
    frames(7)
    table.sort(seen)
    t.eq(table.concat(seen, ", "), "biome Arctic after Conifer, level 6 after 5, name Rob after Bob, title Omega after Alpha")
    for _, connection in ipairs(connections) do connection:Disconnect() end
    quiet()
end)

t.test("an object property fires with Instances, and with nil when it holds nothing", function()
    quiet()
    local who, deer, boar = character(), character(), character()
    local seen, note = recorder()
    local connection = who.wolf:GetPropertyChangedSignal("CurrentTarget"):Connect(note)
    who.store.CurrentTarget = deer.actor
    frames(7)
    t.eq(#seen, 1)
    t.ok(rawequal(seen[1][1], deer.wolf), "the Instance of the object")
    t.eq(seen[1][2], nil)
    frames(13)
    t.eq(#seen, 1, "the same object again is no change")
    who.store.CurrentTarget = boar.actor
    frames(7)
    t.ok(rawequal(seen[2][1], boar.wolf))
    t.ok(rawequal(seen[2][2], deer.wolf))
    who.store.CurrentTarget = world.INVALID
    frames(7)
    t.eq(seen[3][1], nil)
    t.ok(rawequal(seen[3][2], boar.wolf))
    connection:Disconnect()
    quiet()
end)

t.test("a field Wax gives the class is watched like a property, and a table it returns is compared by what it holds", function()
    quiet()
    local undo = easy.class("IcarusCharacter", {
        fields = {
            Health = function(_, raw) return raw.ActorState.Health end,
            Position = function(_, raw)
                local spot = raw:K2_GetActorLocation()
                return { X = spot.X, Y = spot.Y, Z = spot.Z }
            end,
        },
        setters = { Mood = function() end },
        methods = { Heal = function() end },
    })
    local who = character(40)
    local seen = {}
    local health = who.wolf:GetPropertyChangedSignal("Health"):Connect(function(value, previous) seen[#seen + 1] = "health " .. value .. " after " .. previous end)
    local position = who.wolf:GetPropertyChangedSignal("Position"):Connect(function(value, previous) seen[#seen + 1] = "x " .. value.X .. " after " .. previous.X end)
    frames(13)
    t.eq(#seen, 0, "standing still is no change")
    who.state_store.Health = 55
    frames(7)
    who.store.Location = { 250, 0, 0 }
    frames(7)
    t.eq(table.concat(seen, ", "), "health 55 after 40, x 250 after 0")
    t.raises(function() who.wolf:GetPropertyChangedSignal("Heal") end, "Heal is a method of BP_Wolf_C, and only a value can be watched")
    t.raises(function() who.wolf:GetPropertyChangedSignal("Mood") end, "Mood of BP_Wolf_C can be set and not read")
    health:Disconnect()
    position:Disconnect()
    undo()
    quiet()
end)

t.test("a field that is taken away while it is watched is reported once, and watched again when it is given again", function()
    quiet()
    local mood = "calm"
    local spec = { fields = { Mood = function() return mood end } }
    local undo = easy.class("IcarusCharacter", spec, "watch_test")
    local who = character()
    local seen, note = recorder()
    local connection = who.wolf:GetPropertyChangedSignal("Mood"):Connect(note)
    local before = #guard.errors()
    undo()
    frames(13)
    t.eq(#guard.errors(), before + 1)
    t.ok(guard.errors()[before + 1].message:find("Mood is not a member of BP_Wolf_C", 1, true), guard.errors()[before + 1].message)
    t.eq(connection.Connected, true, "the object is still there, so the handler stays")
    undo = easy.class("IcarusCharacter", spec, "watch_test")
    mood = "angry"
    frames(7)
    t.eq(#seen, 1)
    t.eq(seen[1][1], "angry")
    t.eq(seen[1][2], "calm")
    connection:Disconnect()
    undo()
    guard.clear_errors()
    quiet()
end)

t.test("what cannot be watched is refused with the reason, at the line of the mod", function()
    local who = character()
    local wolf = who.wolf
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        wolf:GetPropertyChangedSignal("CurrentLevl")
    end, "CurrentLevl is not a property of BP_Wolf_C")
    at(err, line, "an unknown name")
    t.ok(tostring(err):find("'CurrentLevel'", 1, true), "the nearest name is suggested: " .. tostring(err))
    t.raises(function() wolf:GetPropertyChangedSignal("IsAlive") end, "IsAlive is a function of BP_Wolf_C, and only a value can be watched")
    t.raises(function() wolf:GetPropertyChangedSignal("Spot") end, "BP_Wolf_C.Spot is a struct, which Lua cannot compare, so it cannot be watched")
    t.raises(function() wolf:GetPropertyChangedSignal("Marks") end, "BP_Wolf_C.Marks is a list")
    t.raises(function() wolf:GetPropertyChangedSignal("Precise") end, "BP_Wolf_C.Precise is a double, which Wax does not read yet")
    t.raises(function() wolf:GetPropertyChangedSignal("OnHit") end, "BP_Wolf_C.OnHit is an event of the game's, not a value")
    t.raises(function() wolf:GetPropertyChangedSignal("Keeper") end, "BP_Wolf_C.Keeper is of a kind Wax does not read yet (WeakObjectProperty)")
    t.raises(function() wolf:GetPropertyChangedSignal("Name") end, "Name is one of the names Wax gives every object")
    t.raises(function() wolf:GetPropertyChangedSignal("GetChildren") end, "GetChildren is one of the names Wax gives every object")
    t.raises(function() wolf:GetPropertyChangedSignal(5) end, "expects the name of a value, such as \"Health\", got number")
    t.raises(function() wolf:GetPropertyChangedSignal() end, "expects the name of a value")
    t.raises(function() wolf:GetPropertyChangedSignal("CurrentLevel", "fast") end, "the seconds between looks are a number above 0, such as 0.5, got fast")
    t.raises(function() wolf:GetPropertyChangedSignal("CurrentLevel", 0) end, "the seconds between looks are a number above 0")
    t.raises(function() wolf:GetPropertyChangedSignal("CurrentLevel", -1) end, "the seconds between looks are a number above 0")
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        wolf.GetPropertyChangedSignal("CurrentLevel")
    end, "call GetPropertyChangedSignal with a colon")
    at(err, line, "a call with a dot")
    t.eq(watch.stats().watching, 0)
    quiet()
end)

t.test("a second argument sets the pace, and of two paces asked for one value the faster is used", function()
    quiet()
    local who = character()
    local signal = who.wolf:GetPropertyChangedSignal("CurrentLevel", 0.5)
    local connection = signal:Connect(function() end)
    world.watch = {}
    frames(63)
    t.eq(world.watch.CurrentLevel, 2)
    t.ok(rawequal(who.wolf:GetPropertyChangedSignal("CurrentLevel", 0.1), signal))
    world.watch = {}
    frames(63)
    t.eq(world.watch.CurrentLevel, 10)
    t.ok(rawequal(who.wolf:GetPropertyChangedSignal("CurrentLevel", 2), signal))
    t.ok(rawequal(who.wolf:GetPropertyChangedSignal("CurrentLevel"), signal))
    world.watch = {}
    frames(63)
    t.eq(world.watch.CurrentLevel, 10, "a slower pace asked for later changes nothing")
    world.watch = nil
    connection:Disconnect()
    quiet()
end)

t.test("when the actor leaves the world the looking stops, every handler is let go and the object is never asked again", function()
    quiet()
    local who = character()
    local signal = who.wolf:GetPropertyChangedSignal("CurrentLevel")
    local seen, note = recorder()
    local connection = signal:Connect(note)
    local mod = scope.new("TestMod")
    local owned = scope.run(mod, function() return signal:Connect(function() end) end)
    frames(7)
    who.store.CurrentLevel = 9
    world.destroy(who.actor)
    world.free(who.actor)
    world.watch = {}
    frames(13)
    t.eq(world.watch.CurrentLevel, nil, "nothing was read from it")
    world.watch = nil
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(#seen, 0, "no last change is made up")
    t.eq(connection.Connected, false)
    t.eq(owned.Connected, false)
    t.eq(mod:size(), 0, "the mod holds nothing for it any more")
    quiet()
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        signal:Connect(note)
    end, "the BP_Wolf_C this signal watched no longer exists")
    at(err, line)
    t.raises(function() who.wolf:GetPropertyChangedSignal("CurrentLevel") end, "this BP_Wolf_C no longer exists")
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(#guard.errors(), 0, "an object that is gone is not an error")
    mod:destroy()
end)

t.test("connecting to a signal whose actor left before the first look raises, and leaves nothing behind", function()
    quiet()
    local who = character()
    local signal = who.wolf:GetPropertyChangedSignal("CurrentLevel")
    world.destroy(who.actor)
    world.free(who.actor)
    t.raises(function() signal:Connect(function() end) end, "the BP_Wolf_C this signal watched no longer exists")
    t.eq(signal.count, 0)
    quiet()
    t.eq(world.dead_touches, 0, world.dead_where)
end)

t.test("after a map change nothing from the old map is asked, even when no actor was seen leaving", function()
    quiet()
    local who = character()
    local level = who.wolf:GetPropertyChangedSignal("CurrentLevel"):Connect(function() end)
    local health = who.wolf.ActorState:GetPropertyChangedSignal("Health"):Connect(function() end)
    frames(7)
    world.free(who.actor)
    local viewport = world.engine.GameViewport
    rawget(viewport, "__props").World = world.object("World_Next", {})
    world.watch = {}
    frames(13)
    t.eq(world.watch.CurrentLevel, nil)
    t.eq(world.watch.Health, nil)
    world.watch = nil
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(level.Connected, false)
    t.eq(health.Connected, false)
    quiet()
    t.eq(#guard.errors(), 0)
end)

-- ----------------------------------------------------------------------------------------- a component, through its actor

t.test("a component is watched through the property of its actor that keeps it", function()
    quiet()
    local who = character()
    local scanned = watch.stats().scanned
    local part = who.wolf.ActorState
    local signal = part:GetPropertyChangedSignal("Health")
    t.eq(watch.stats().scanned - scanned, 1, "the property named like the component was the one")
    local seen, note = recorder()
    local connections = {
        signal:Connect(note), part:GetPropertyChangedSignal("Shelter"):Connect(note),
        part:GetPropertyChangedSignal("bHasHealthRegen"):Connect(note),
    }
    world.watch = {}
    frames(7)
    t.eq(world.watch.ActorState, 1, "the actor answers for the component once a round, for three values")
    world.watch = nil
    who.state_store.Health = 80
    frames(7)
    who.state_store.Shelter = 0.75
    frames(7)
    who.state_store.bHasHealthRegen = false
    frames(7)
    t.eq(#seen, 3)
    t.eq(seen[1][1], 80)
    t.eq(seen[1][2], 100)
    t.eq(seen[2][1], 0.75)
    t.eq(seen[3][1], false)
    t.eq(seen[3][2], true)
    for _, connection in ipairs(connections) do connection:Disconnect() end
    quiet()
end)

t.test("a component kept under another name than its own is found by looking through the actor's properties once", function()
    quiet()
    local who = character()
    local scanned = watch.stats().scanned
    local container = who.wolf.StatContainer
    t.eq(container.Name, "Stat Container")
    local signal = container:GetPropertyChangedSignal("Total")
    t.ok(watch.stats().scanned - scanned > 1)
    scanned = watch.stats().scanned
    local seen, note = recorder()
    local connection = signal:Connect(note)
    who.stats_store.Total = 80
    frames(7)
    t.eq(seen[1][1], 80)
    t.eq(seen[1][2], 78)
    t.eq(watch.stats().scanned, scanned, "the looking through is done once, not at every look")
    connection:Disconnect()
    quiet()
end)

t.test("a component that is destroyed on its own, and then freed, is never asked: its actor no longer keeps it", function()
    quiet()
    local who = character()
    local part = who.wolf.ActorState
    local seen, note = recorder()
    local connection = part:GetPropertyChangedSignal("Health"):Connect(note)
    frames(7)
    -- the game destroys the component, then collects it: the actor's property is emptied and the memory freed
    rawset(who.state, "__flags", PENDING_KILL)
    who.store.ActorState = world.INVALID
    rawset(who.state, "__freed", true)
    world.watch = {}
    frames(13)
    t.eq(world.watch.Health, nil)
    world.watch = nil
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(connection.Connected, false)
    t.eq(#seen, 0)
    quiet()
    t.eq(who.wolf.CurrentLevel, 5, "the actor itself is as it was")
    t.eq(#guard.errors(), 0)
end)

t.test("a component its actor swapped for another is no longer watched", function()
    quiet()
    local who = character()
    local part = who.wolf.ActorState
    local connection = part:GetPropertyChangedSignal("Health"):Connect(function() end)
    local other = values.part(state_class, "ActorState", { Health = 1 })
    who.store.ActorState = other
    rawset(who.state, "__freed", true)
    frames(7)
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(connection.Connected, false)
    quiet()
end)

t.test("a component its actor keeps under another property now is found again when it is asked for again", function()
    quiet()
    local who = character()
    local part = who.wolf.ActorState
    local first = part:GetPropertyChangedSignal("Health")
    local connection = first:Connect(function() end)
    who.store.ActorState = world.INVALID
    who.store.CurrentTarget = who.state
    frames(7)
    t.eq(connection.Connected, false, "the property it was watched through let go of it")
    local seen, note = recorder()
    local second = part:GetPropertyChangedSignal("Health")
    t.ok(not rawequal(second, first))
    local again = second:Connect(note)
    who.state_store.Health = 70
    frames(7)
    t.eq(seen[1][1], 70)
    t.eq(seen[1][2], 100)
    again:Disconnect()
    quiet()
    t.eq(world.dead_touches, 0, world.dead_where)
end)

t.test("a component seen destroyed but not yet freed stops the looking without an error", function()
    quiet()
    local who = character()
    local connection = who.wolf.ActorState:GetPropertyChangedSignal("Health"):Connect(function() end)
    frames(7)
    rawset(who.state, "__flags", PENDING_KILL)
    frames(7)
    t.eq(connection.Connected, false)
    t.eq(#guard.errors(), 0)
    t.eq(world.dead_touches, 0, world.dead_where)
    quiet()
end)

-- ------------------------------------------------------------------------- objects whose end Wax is not told about

t.test("a component no property of its actor keeps is refused, and the switch that allows it risks asking an object that is gone", function()
    quiet()
    local modifier_object, modifier_store = values.part(modifier_class, "Modifier_Wet", { RemainingTime = 30 })
    local who = character(100, { modifier_object })
    local modifier = instance.wrap(modifier_object)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        modifier:GetPropertyChangedSignal("RemainingTime")
    end, "this ModifierStateComponent is not kept in a property of its actor")
    at(err, line)
    t.ok(tostring(err):find("Read RemainingTime yourself when you need it", 1, true), tostring(err))
    t.eq(watch.WATCH_ANY_OBJECT, false, "the switch is off as it ships")

    watch.WATCH_ANY_OBJECT = true
    local ok, problem = pcall(function()
        local seen, note = recorder()
        local connection = modifier:GetPropertyChangedSignal("RemainingTime"):Connect(note)
        modifier_store.RemainingTime = 29
        frames(7)
        t.eq(seen[1][1], 29)
        -- collected on its own while its actor lives on: nothing told Wax
        rawset(modifier_object, "__freed", true)
        frames(7)
        t.ok(world.dead_touches > 0, "the object that is gone was asked, which is what ends the real game")
        t.eq(connection.Connected, false)
    end)
    watch.WATCH_ANY_OBJECT = false
    world.dead_touches, world.dead_where = 0, nil
    if not ok then error(problem, 0) end
    t.eq(who.wolf.CurrentLevel, 5)
    quiet()
    guard.clear_errors()
end)

t.test("an object that is no actor and no part of one is refused, with what to do instead", function()
    local subsystem = instance.wrap((values.part(subsystem_class, "TimeOfDaySubsystem_0", { TimeScale = 1 })))
    t.raises(function() subsystem:GetPropertyChangedSignal("TimeScale") end,
        "a TimeOfDaySubsystem is not an actor or a part of one, so Wax is not told when it is gone")
    t.raises(function() subsystem:GetPropertyChangedSignal("TimeScale") end, "Read TimeScale yourself when you need it")
    t.eq(subsystem.TimeScale, 1, "reading it is as it was")
end)

t.test("the default object of a class, and a component of one, are refused: they never leave the world", function()
    local default_actor = values.actor(wolf_class, "Default__BP_Wolf_C", { CurrentLevel = 1, Location = { 0, 0, 0 } })
    local default_object = instance.wrap(default_actor)
    t.raises(function() default_object:GetPropertyChangedSignal("CurrentLevel") end,
        "this BP_Wolf_C is, or belongs to, the default object of a class and not something in the world")
    local state = values.part(state_class, "ActorState", { Health = 1 })
    values.actor(wolf_class, "Default__BP_Wolf_C", { ActorState = state, Location = { 0, 0, 0 } }, { state })
    local template = instance.wrap(state)
    t.raises(function() template:GetPropertyChangedSignal("Health") end,
        "this ActorState is, or belongs to, the default object of a class")
    t.eq(default_object.CurrentLevel, 1, "reading it is as it was")
end)

t.test("with a handle module any object can be watched, and one the handle says is gone is not asked", function()
    quiet()
    local module = handle_module()
    instance.use_handles(module)
    local ok, problem = pcall(function()
        local object, store = values.part(subsystem_class, "TimeOfDaySubsystem_1", { TimeScale = 1 })
        local subsystem = instance.wrap(object)
        local seen, note = recorder()
        local connection = subsystem:GetPropertyChangedSignal("TimeScale"):Connect(note)
        store.TimeScale = 2
        frames(7)
        t.eq(seen[1][1], 2)
        module.dead[module.taken] = true
        rawset(object, "__freed", true)
        frames(7)
        t.eq(world.dead_touches, 0, world.dead_where)
        t.eq(connection.Connected, false)
        quiet()

        local second_object = values.part(subsystem_class, "TimeOfDaySubsystem_2", { TimeScale = 1 })
        local second = instance.wrap(second_object):GetPropertyChangedSignal("TimeScale"):Connect(note)
        instance.use_handles(nil)
        frames(7)
        t.eq(second.Connected, false, "without the handle module nothing says when it is gone, so it is let go")
        quiet()
    end)
    instance.use_handles(nil)
    if not ok then error(problem, 0) end
    t.eq(#guard.errors(), 0)
end)

t.test("while Wax is not told when actors leave, nothing is watched", function()
    local who = character()
    local told = Wax.actor_ended
    Wax.actor_ended = nil
    local ok, err = pcall(function() return who.wolf:GetPropertyChangedSignal("CurrentLevel") end)
    Wax.actor_ended = told
    t.eq(ok, false)
    t.ok(tostring(err):find("Wax is not being told when actors leave the world", 1, true), tostring(err))
    t.ok(who.wolf:GetPropertyChangedSignal("CurrentLevel"), "with the hook in place it is watched")
end)

-- --------------------------------------------------------------------------------------- loading on first use

local function lone_core(broken)
    local lone = t.new_wax()
    if broken then
        local import = lone.import
        ---@diagnostic disable-next-line: duplicate-set-field
        lone.import = function(name)
            if name == "engine.watch" then error("wax module 'engine.watch' failed while loading:\nit is broken", 0) end
            return import(name)
        end
    end
    local lone_sched = lone.import("core.sched")
    lone_sched.clock = function() return now end
    local lone_instance = lone.import("engine.instance")
    lone_instance.start()
    lone.actor_ended = function() end
    return lone, lone_sched, lone_instance
end

t.test("loaded in the middle of one mod's call, the looking still belongs to no mod", function()
    local lone, lone_sched, lone_instance = lone_core(false)
    local lone_scope = lone.import("core.scope")
    local first, second = lone_scope.new("FirstMod"), lone_scope.new("SecondMod")
    local who = character()
    local wolf = lone_instance.wrap(who.actor)
    local seen = {}
    t.eq(lone.modules["engine.watch"], nil)
    lone_scope.run(first, function()
        wolf:GetPropertyChangedSignal("CurrentLevel"):Connect(function(value) seen[#seen + 1] = "first " .. value end)
    end)
    t.ok(lone.modules["engine.watch"], "the first call loaded it")
    lone_scope.run(second, function()
        wolf:GetPropertyChangedSignal("CurrentLevel"):Connect(function(value) seen[#seen + 1] = "second " .. value end)
    end)
    first:destroy()
    who.store.CurrentLevel = 6
    for _ = 1, 7 do
        now = now + FRAME
        lone_sched.step()
    end
    t.eq(table.concat(seen, ", "), "second 6")
    second:destroy()
    t.eq(lone_sched.Frame.count, 0)
    t.eq(#lone.import("core.guard").errors(), 0)
end)

t.test("stepped by the frame loop, nothing is put on the frame signal and the looking is the same", function()
    local lone, lone_sched = lone_core(false)
    local lone_watch = lone.import("engine.watch")
    local function stepped(count)
        for _ = 1, count do
            now = now + FRAME
            lone_watch.step()
            lone_sched.step()
        end
    end
    local value, reads = 1, 0
    local signal = lone_watch.signal("Test.Stepped", { read = function()
        reads = reads + 1
        return value
    end })
    local seen, note = recorder()
    local connection = signal:Connect(note)
    t.eq(lone_sched.Frame.count, 1, "until the frame loop has stepped it, the module links itself")
    t.eq(lone_watch.stats().driven, false)
    stepped(1)
    t.eq(lone_sched.Frame.count, 0, "the link is given up at the first step")
    t.eq(lone_watch.stats().driven, true)
    value = 2
    stepped(7)
    t.eq(#seen, 1)
    t.eq(seen[1][1], 2)
    t.eq(seen[1][2], 1)
    stepped(55)
    t.eq(reads, 11, "ten looks in the first second, as on the frame signal")
    connection:Disconnect()
    stepped(20)
    t.eq(reads, 11, "nothing is read once nobody listens")
    local again = signal:Connect(note)
    t.eq(lone_sched.Frame.count, 0, "and nothing goes on the frame signal again")
    value = 3
    stepped(7)
    t.eq(#seen, 2)
    t.eq(seen[2][1], 3)
    again:Disconnect()
    t.eq(lone_watch.stats().watching, 0)
    t.eq(#lone.import("core.guard").errors(), 0)
end)

t.test("when engine.watch cannot be loaded the method says so, and Instances work as before", function()
    local _, _, lone_instance = lone_core(true)
    local wolf = lone_instance.wrap(character().actor)
    local err = t.raises(function() wolf:GetPropertyChangedSignal("CurrentLevel") end,
        "values cannot be watched, because engine.watch did not load")
    t.ok(tostring(err):find("it is broken", 1, true), tostring(err))
    t.eq(wolf.CurrentLevel, 5)
    wolf.CurrentLevel = 6
    t.eq(wolf:Get("CurrentLevel"), 6)
end)

-- -------------------------------------------------------------------------------------------------- game.Frame

t.test("game.Frame is there once engine.watch is started, and hands each handler the seconds since the frame before", function()
    quiet()
    t.raises(function() return game.Frame end, "Frame is not a member of game")
    watch.start()
    t.eq(tostring(game.Frame), "game.Frame")
    t.ok(rawequal(game:GetService("Frame"), game.Frame))
    quiet()
    local seconds = {}
    local connection = game.Frame:Connect(function(passed) seconds[#seconds + 1] = passed end)
    t.eq(sched.Frame.count, 1)
    frames(3)
    t.eq(#seconds, 3)
    t.ok(math.abs(seconds[2] - FRAME) < 1e-9, "seconds: " .. seconds[2])
    connection:Disconnect()
    frames(3)
    t.eq(#seconds, 3)
    quiet()
end)

t.test("a mod's frame handler goes with the mod, and Once and Wait work", function()
    quiet()
    local calls, once, waited = 0, 0, nil
    local mod = scope.new("TestMod")
    scope.run(mod, function()
        game.Frame:Connect(function() calls = calls + 1 end)
        game.Frame:Once(function() once = once + 1 end)
        task.spawn(function() waited = game.Frame:Wait() end)
    end)
    frames(4)
    t.eq(calls, 4)
    t.eq(once, 1)
    t.ok(math.abs(waited - FRAME) < 1e-9)
    mod:destroy()
    frames(4)
    t.eq(calls, 4)
    quiet()
    t.raises(function() game.Frame:Wait() end, "game.Frame:Wait can only be used inside a task")
end)

t.test("a frame handler that is still paused is called again on the next frame", function()
    quiet()
    local calls, finished = 0, 0
    local connection = game.Frame:Connect(function()
        calls = calls + 1
        task.wait(0.05)
        finished = finished + 1
    end)
    frames(3)
    t.eq(calls, 3)
    t.eq(finished, 0)
    connection:Disconnect()
    frames(5)
    t.eq(finished, 3)
    quiet()
end)

t.test("a mod cannot fire game.Frame or disconnect what Wax connected to the frame", function()
    quiet()
    local value = 1
    local signal = watch.signal("Test.Kept", { read = function() return value end })
    local seen, note = recorder()
    local connection = signal:Connect(note)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        game.Frame:DisconnectAll()
    end, "game.Frame has no DisconnectAll")
    at(err, line)
    t.raises(function() game.Frame:Fire(1) end, "game.Frame has no Fire: Wax fires it once a frame")
    err = t.raises(function() game.Frame:Conect(function() end) end, "Conect is not a member of game.Frame")
    t.ok(tostring(err):find("'Connect'", 1, true), tostring(err))
    t.raises(function() game.Frame.Connect = nil end, "game.Frame.Connect cannot be assigned")
    t.raises(function() game.Frame:Connect("handler") end, "game.Frame:Connect expects a function, got string")
    t.raises(function() game.Frame:Once() end, "game.Frame:Once expects a function, got nil")
    value = 2
    frames(7)
    t.eq(#seen, 1, "Wax's own looking went on")
    connection:Disconnect()
    quiet()
end)

-- -------------------------------------------------------------------------------------------------- task.every

-- The lines proposed for core\sched.lua, as they would stand there. Used only while sched has no task.every of its own.
local EVERY_LINES = [==[
-- Runs f(...) every `seconds`, the first time after `seconds`. Returns the thread, which task.cancel stops.
function task.every(seconds, f, ...)
    if type(seconds) ~= "number" or not (seconds >= 0) then
        error("task.every expects the seconds between runs, such as 0.5, got " .. tostring(seconds), 2)
    end
    if type(f) ~= "function" then error("task.every expects a function to run, got " .. type(f), 2) end
    local args = pack(...)
    local thread = task.delay(seconds, function()
        local failures = 0
        while true do
            local ok, trace = xpcall(f, guard.handler, unpack(args, 1, args.n))
            failures = ok and 0 or failures + 1
            if not ok then
                guard.report(trace, "task.every")
                if failures >= guard.breaker_errors then
                    guard.report(("stopped after %d errors in a row"):format(failures), "task.every")
                    return
                end
            end
            task.wait(seconds)
        end
    end)
    return task.label(thread, "task.every")
end
]==]
local proposed = task.every == nil
if proposed then
    assert(load(EVERY_LINES, "=task.every as proposed", "t", {
        task = task, guard = guard, pack = table.pack, unpack = table.unpack, type = type, error = error, tostring = tostring,
        xpcall = xpcall,
    }))()
end

t.test("task.every runs a function again and again, waiting that long after each run, with the values given", function()
    local runs, handed = 0, nil
    local thread = task.every(0.5, function(a, b)
        runs = runs + 1
        handed = tostring(a) .. " " .. tostring(b)
    end, "x", nil)
    t.eq(type(thread), "thread")
    frames(31)
    t.eq(runs, 0, "the first run comes after the wait")
    frames(1)
    t.eq(runs, 1)
    t.eq(handed, "x nil")
    frames(100)
    t.eq(runs, 4, "four runs in 2.1 seconds")
    task.cancel(thread)
    frames(63)
    t.eq(runs, 4, "task.cancel stops it")
end)

t.test("task.every stops with the mod, goes on after an error, and stops after five errors in a row", function()
    local runs = 0
    local mod = scope.new("TestMod")
    scope.run(mod, function() task.every(0, function() runs = runs + 1 end) end)
    frames(5)
    t.eq(runs, 5, "0 seconds is once a frame")
    mod:destroy()
    frames(5)
    t.eq(runs, 5)

    local tries, fail_until, before = 0, 2, #guard.errors()
    local thread = task.every(0, function()
        tries = tries + 1
        if tries <= fail_until then error("not ready") end
    end)
    frames(4)
    t.eq(tries, 4, "two errors did not stop it")
    t.eq(#guard.errors(), before + 1, "the same error is one record")
    t.eq(guard.errors()[before + 1].label, "task.every")
    fail_until = 1000
    frames(20)
    t.eq(tries, 4 + 5, "five in a row did")
    t.ok(guard.errors()[#guard.errors()].message:find("stopped after 5 errors in a row", 1, true))
    task.cancel(thread)
    guard.clear_errors()
end)

t.test("task.every may pause inside its function, and says what it expects at the caller's line", function()
    local done = 0
    local thread = task.every(0.1, function()
        task.wait(0.1)
        done = done + 1
    end)
    frames(63)
    t.ok(done >= 4 and done <= 5, "a run of 0.1 s and a wait of 0.1 s: " .. done)
    task.cancel(thread)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        task.every("often", function() end)
    end, "task.every expects the seconds between runs, such as 0.5, got often")
    at(err, line)
    t.raises(function() task.every(-1, function() end) end, "task.every expects the seconds between runs")
    t.raises(function() task.every(1, "run") end, "task.every expects a function to run, got string")
end)

-- ------------------------------------------------------------------------------------------------------- the rest

t.test("nothing here touched a freed object, asked the engine for what it does not offer, or left anything behind", function()
    frames(10)
    quiet()
    t.eq(watch.stats().watching, 0)
    t.eq(watch.stats().linked, false)
    t.eq(watch.stats().off, false)
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(values.crashes + values.misuse, 0, table.concat(values.log, " | "))
    t.eq(#guard.errors(), 0)
    t.eq(easy.stats().registrations, 0, "every test took back what it registered")
end)

-- What things take on the stand-in, in a tight loop. The game takes 4 to 7 times as long once a frame.
if arg and arg[1] == "cost" then
    local function each(rounds, body)
        local started = os.clock()
        for _ = 1, rounds do body() end
        return (os.clock() - started) / rounds * 1e6
    end
    local who = character()
    local fire = function() sched.Frame:Fire(FRAME) end
    local nothing = each(200000, fire)
    local on_actor = who.wolf:GetPropertyChangedSignal("CurrentLevel"):Connect(function() end)
    local not_due = each(200000, fire)
    local due = function()
        now = now + 0.1
        sched.Frame:Fire(FRAME)
    end
    local one_actor = each(50000, due)
    on_actor:Disconnect()
    local part = who.wolf.ActorState
    local on_part = part:GetPropertyChangedSignal("Health"):Connect(function() end)
    local one_part = each(50000, due)
    local more = {}
    for _, name in ipairs({ "MaxHealth", "CurrentAliveState", "Shelter", "bHasHealthRegen" }) do
        more[#more + 1] = part:GetPropertyChangedSignal(name):Connect(function() end)
    end
    local five_part = each(50000, due)
    on_part:Disconnect()
    for _, connection in ipairs(more) do connection:Disconnect() end
    local frame_handler = game.Frame:Connect(function() end)
    local with_handler = each(200000, fire)
    frame_handler:Disconnect()
    print(("cost on the stand-in, us, on the frame signal: nothing watched %.2f, a frame with a watcher that is not due %.2f, "
        .. "a look at one property of an actor %.2f, of a component %.2f, at five of one component %.2f, one game.Frame handler %.2f")
        :format(nothing, not_due - nothing, one_actor - nothing, one_part - nothing, five_part - nothing, with_handler - nothing))

    local lone, _, lone_instance = lone_core(false)
    local lone_watch = lone.import("engine.watch")
    local empty = each(1000000, function() end)
    local idle = each(1000000, lone_watch.step)
    local lone_wolf = lone_instance.wrap(who.actor)
    local stepped = lone_wolf:GetPropertyChangedSignal("CurrentLevel"):Connect(function() end)
    local stepped_not_due = each(1000000, lone_watch.step)
    local stepped_due = each(50000, function()
        now = now + 0.1
        lone_watch.step()
    end)
    stepped:Disconnect()
    print(("cost on the stand-in, us, stepped by the frame loop: nothing watched %.3f, a frame with a watcher that is not due %.3f, "
        .. "a look at one property of an actor %.2f"):format(idle - empty, stepped_not_due - empty, stepped_due - empty))
end

t.finish("watch")
