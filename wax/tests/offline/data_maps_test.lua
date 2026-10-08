-- Offline tests for the map and curve reads of game.Data, on the stand-in that raises on what would crash the real game.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\data_maps_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_tables.lua")
fake.sample({ recipes = 5, fill = 250 })
local S, U, G = "/Script/Icarus.", "/Script/IcarusUtilities.", "/Script/GameplayTags."

-- the game's own shapes: a stat map, a movement map keyed by an enum, curves, and maps keyed by a handle, a tag, a name, a string
fake.struct(S .. "BaseStatsEnum", U .. "RowEnum", {})
fake.struct(S .. "AISetupRowHandle", U .. "RowHandle", {})
fake.struct(S .. "ExperienceEventsRowHandle", U .. "RowHandle", {})
fake.struct("/Script/CoreUObject.Vector2D", nil, { { "X", "FloatProperty" }, { "Y", "FloatProperty" } })
fake.struct("/Script/CoreUObject.IntPoint", nil, { { "X", "IntProperty" }, { "Y", "IntProperty" } })
fake.struct(S .. "GrowthStat", nil, {
    { "Stat", "StructProperty", struct = S .. "BaseStatsEnum" },
    { "Curve", "ObjectProperty", class = "CurveFloat" },
})
fake.struct(S .. "AIGrowth", U .. "IcarusTableRowBase", {
    { "Base", "MapProperty", key = { "StructProperty", struct = S .. "BaseStatsEnum" }, value = { "IntProperty" } },
    { "Health", "ObjectProperty", class = "CurveFloat" },
    { "MeleeDamage", "ObjectProperty", class = "CurveFloat" },
    { "CustomStats", "ArrayProperty", inner = "StructProperty", struct = S .. "GrowthStat" },
    { "Icon", "ObjectProperty", class = "Texture2D" },
    { "Notes", "StrProperty" },
})
local DEER = { name = "C_MediumDeerHealth", keys = { { 0, 300 }, { 120, 500 } } }
fake.table("AIGrowth", S .. "AIGrowth", {
    Deer = { Base = { { { Value = "BaseMovementSpeed_+" }, 220 }, { { Value = "BaseCharacterMass_+" }, 175 },
                      { { Value = "BasePoisonDamageResistance_%" }, -25 } },
             Health = DEER, Notes = "runs",
             CustomStats = { { Stat = { Value = "BaseWoundChance_%" }, Curve = { name = "C_Wound", keys = { { 1, 5 }, { 3, 15 } } } },
                             { Stat = { Value = "BaseStamina_+" } } } },
    Deer_Conifer = { Base = { { { Value = "BaseMovementSpeed_+" }, 230 } }, Health = DEER,
                     MeleeDamage = { name = "C_Kick", keys = { { 0.5, 10 }, { 2.25, 40 } } } },
    Rabbit = { Base = { { { Value = "BaseMaximumHealth_+" }, 25 } }, Icon = { path = "/Game/UI/T_Rabbit.T_Rabbit" } },
    Stone = { Health = { name = "C_Flat", keys = {} }, MeleeDamage = { name = "C_Long", keys = { { 0, 1 }, { 5000, 2 } } } },
}, { "Deer", "Deer_Conifer", "Rabbit", "Stone" })

fake.struct(S .. "MovementStateData", nil, {
    { "MaxWalkSpeed", "FloatProperty" }, { "GroundFriction", "FloatProperty" },
    { "Gait", "EnumProperty", enum = { "Slow", "Quick" } }, { "Name", "StrProperty" },
})
fake.struct(S .. "ExperienceInfo", nil, {
    { "ExperienceEvent", "StructProperty", struct = S .. "ExperienceEventsRowHandle" }, { "bShared", "BoolProperty" },
})
fake.struct(S .. "SpawnEntry", nil, {
    { "AISetup", "StructProperty", struct = S .. "BaseStatsEnum" }, { "SpawnWeight", "IntProperty" },
})
fake.struct(S .. "SpawnList", nil, {
    { "MinLevel", "IntProperty" },
    { "WorldStatInjection", "MapProperty", key = { "StructProperty", struct = S .. "BaseStatsEnum" },
      value = { "StructProperty", struct = S .. "SpawnEntry" } },
})
fake.struct(S .. "Reward", nil, {
    { "Amount", "IntProperty" },
    { "Extras", "MapProperty", key = { "NameProperty" }, value = { "FloatProperty" } },
})
local STATES = { "Undefined", "Stationary", "Sneak", "Walk", "Jog", "Run", "Sprint" }
fake.struct(S .. "AISetup", U .. "IcarusTableRowBase", {
    { "MovementMapping", "MapProperty", key = { "EnumProperty", enum = STATES }, value = { "StructProperty", struct = S .. "MovementStateData" } },
    { "ExperienceEvents", "MapProperty", key = { "EnumProperty", enum = { "XP_OnDeath", "XP_OnInteract" } },
      value = { "StructProperty", struct = S .. "ExperienceInfo" } },
    { "WorldBosses", "MapProperty", key = { "StructProperty", struct = S .. "AISetupRowHandle" },
      value = { "StructProperty", struct = "/Script/CoreUObject.Vector2D" } },
    { "Animations", "MapProperty", key = { "StructProperty", struct = G .. "GameplayTag" }, value = { "SoftObjectProperty" } },
    { "Materials", "MapProperty", key = { "IntProperty" }, value = { "SoftObjectProperty" } },
    { "Variables", "MapProperty", key = { "StrProperty" }, value = { "FloatProperty" } },
    { "Sounds", "MapProperty", key = { "NameProperty" }, value = { "TextProperty" } },
    { "Flags", "MapProperty", key = { "StructProperty", struct = S .. "AISetupRowHandle" }, value = { "BoolProperty" } },
    { "Chances", "MapProperty", key = { "FloatProperty" }, value = { "IntProperty" } },
    { "Genetics", "MapProperty", key = { "StructProperty", struct = S .. "BaseStatsEnum" }, value = { "ObjectProperty", class = "CurveFloat" } },
    { "Creatures", "StructProperty", struct = S .. "SpawnList" },
    { "Rewards", "ArrayProperty", inner = "StructProperty", struct = S .. "Reward" },
    { "Cells", "MapProperty", key = { "StructProperty", struct = "/Script/CoreUObject.IntPoint" }, value = { "IntProperty" } },
    { "Owners", "MapProperty", key = { "ObjectProperty", class = "Actor" }, value = { "IntProperty" } },
    { "Trees", "MapProperty", key = { "StructProperty", struct = G .. "GameplayTag" }, value = { "ObjectProperty", class = "BehaviorTree" } },
    { "Lists", "MapProperty", key = { "IntProperty" }, value = { "ArrayProperty", inner = "IntProperty" } },
    { "Level", "IntProperty" },
})
local function handle(name) return { RowName = name, DataTableName = "D_AISetup" } end
fake.table("AISetup", S .. "AISetup", {
    Deer = {
        Level = 3,
        MovementMapping = { { 1, { MaxWalkSpeed = 0 } }, { 3, { MaxWalkSpeed = 1, GroundFriction = 8, Gait = 1, Name = "walk" } },
                            { 5, { MaxWalkSpeed = 3 } }, { 6, { MaxWalkSpeed = 5.45 } } },
        ExperienceEvents = { { 0, { ExperienceEvent = { RowName = "Kill_MediumDeer", DataTableName = "D_ExperienceEvents" }, bShared = true } } },
        WorldBosses = { { handle("Sandworm"), { X = 3, Y = 3 } }, { handle("AlphaWolf"), { X = 2, Y = 4 } } },
        Animations = { { { TagName = "BT.Mount.Idle" }, "/Game/Anim/Idle.Idle" }, { { TagName = "BT.Mount.Eat" }, "None" } },
        Materials = { { 0, "/Game/Mat/Body.Body" }, { 2, "/Game/Mat/Fur.Fur" } },
        Variables = { { "DamagePercentage", 0.5 } },
        Sounds = { { "Swing", "Whoosh" } },
        Flags = { { handle("Deer"), true }, { handle("Wolf"), false } },
        Chances = { { 0.5, 10 }, { 2.0, 20 } },
        Genetics = { { { Value = "BaseMaximumHealth_+" }, { name = "C_Double", keys = { { 0, 1 }, { 2, 2 } } } },
                     { { Value = "BaseStamina_+" }, nil } },
        Creatures = { MinLevel = 5, WorldStatInjection = { { { Value = "WorldSnowSlugSpawn_?" },
            { AISetup = { Value = "Snow_Slug" }, SpawnWeight = 5 } } } },
        Rewards = { { Amount = 1, Extras = { { "Luck", 0.25 } } }, { Amount = 2 } },
        Cells = { { { X = 1, Y = 2 }, 7 } },
        Owners = { { { class = "Actor", path = "/Game/Map.Map:Deer_1" }, 1 } },
        Trees = { { { TagName = "BT.GOAP.Attack" }, { class = "BehaviorTree", path = "/Game/BT/Attack.Attack" } } },
        Lists = { { 1, { 1, 2 } } },
    },
    Wolf = { Level = 9, MovementMapping = { { 3, { MaxWalkSpeed = 1 } } } },
    Bear = { Level = 20 },
}, { "Deer", "Wolf", "Bear" })

fake.install()

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)

local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local log = Wax.import("core.log")
local game = Wax.import("engine.game")
local data = Wax.import("data.tables")
local task = sched.task

local now = 100
sched.clock = function() return now end
data.clock = function() return now end
data.start()
local Data = game.root.Data
local growth, setup = Data:Table("AIGrowth"), Data:Table("AISetup")

local function frame()
    now = now + 0.016
    fake.next_frame()
    sched.step()
end

local function in_task(fn)
    local done, ok, a = false, nil, nil
    task.spawn(function()
        ok, a = pcall(fn)
        done = true
    end)
    for _ = 1, 2000 do
        if done then break end
        frame()
    end
    if not done then error("the task did not end", 2) end
    if not ok then error(a, 0) end
    return a
end

local function count(map)
    local n = 0
    for _ in pairs(map) do n = n + 1 end
    return n
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

local function warnings()
    return #log.since(0, { level = "warn", channel = "wax.data" })
end

t.test("a map is left out until its own path is named, and so is a curve", function()
    local deer = growth:Row("Deer")
    t.eq(deer.Notes, "runs")
    t.eq(deer.Base, nil, "not read with everything")
    t.eq(deer.Health, nil)
    t.eq(#deer.CustomStats, 2)
    t.eq(deer.CustomStats[1].Stat.Value, "BaseWoundChance_%")
    t.eq(deer.CustomStats[1].Curve, nil, "nor inside a list that was read whole")
    t.eq(setup:Row("Deer", { "Creatures" }).Creatures.WorldStatInjection, nil, "naming the struct does not name its map")
    t.eq(fake.map_reads, 0)
    t.eq(fake.curve_values, 0)
end)

t.test("a stat map is a plain table from each stat's name to its number, kept with the row", function()
    local deer = growth:Row("Deer", { "Base" })
    t.eq(deer, growth:Row("Deer"), "the same table as before, with the map added")
    t.eq(count(deer.Base), 3)
    t.eq(deer.Base["BaseMovementSpeed_+"], 220)
    t.eq(deer.Base["BasePoisonDamageResistance_%"], -25)
    t.ok(is_plain(deer), "only strings, numbers, booleans and tables")
    t.eq(fake.map_reads, 1)
    t.eq(fake.map_entries, 3)
    local touches = fake.touches
    t.eq(growth:Row("deer", { "Base" }).Base, deer.Base, "asked again, it is the kept one")
    t.eq(fake.touches, touches, "and the engine is not asked")
    t.eq(growth:Row("Rabbit", { "Base" }).Base["BaseMaximumHealth_+"], 25)
    t.eq(next(growth:Row("Stone", { "Base" }).Base), nil, "an empty map is an empty table")
end)

t.test("a map keyed by an enum has the enum's numbers as keys and each struct as a table", function()
    local deer = setup:Row("Deer", { "MovementMapping" })
    local map = deer.MovementMapping
    t.eq(count(map), 4)
    t.eq(map[3].MaxWalkSpeed, 1)
    t.eq(map[3].GroundFriction, 8)
    t.eq(map[3].Name, "walk", "a field called Name is a field like any other here")
    t.eq(map[3].Gait, nil, "an enum inside is left out, as in every struct that was not named field by field")
    t.ok(math.abs(map[6].MaxWalkSpeed - 5.45) < 1e-6)
    t.eq(map[1].MaxWalkSpeed, 0)
    t.eq(map[2], nil)
    t.eq(rawget(_G, "Enum_MovementMapping_Key"), nil, "the names UE4SS leaves in a global are taken away")
    t.eq(rawget(_G, "Enum_MovementMapping"), nil)
    local events = setup:Row("Deer", { "ExperienceEvents" }).ExperienceEvents
    t.eq(events[0].ExperienceEvent.RowName, "Kill_MediumDeer", "a row handle inside a value is a table, as everywhere")
    t.eq(events[0].ExperienceEvent.DataTableName, "D_ExperienceEvents")
    t.eq(events[0].bShared, true)
    t.eq(rawget(_G, "Enum_ExperienceEvents_Key"), nil)
    t.ok(is_plain(deer))
end)

t.test("a key is a row handle's row, a tag's name, a name, a string or a number", function()
    local deer = setup:Row("Deer", { "WorldBosses", "Animations", "Materials", "Variables", "Sounds", "Flags", "Chances" })
    t.eq(deer.WorldBosses.Sandworm.X, 3)
    t.eq(deer.WorldBosses.AlphaWolf.Y, 4)
    t.eq(deer.Animations["BT.Mount.Idle"], "/Game/Anim/Idle.Idle")
    t.eq(deer.Animations["BT.Mount.Eat"], false, "a reference to nothing is false, so its key is still there")
    t.eq(deer.Materials[0], "/Game/Mat/Body.Body")
    t.eq(deer.Materials[2], "/Game/Mat/Fur.Fur")
    t.eq(deer.Variables.DamagePercentage, 0.5)
    t.eq(deer.Sounds.Swing, "Whoosh")
    t.eq(deer.Flags.Deer, true)
    t.eq(deer.Flags.Wolf, false)
    t.eq(deer.Chances[0.5], 10)
    t.eq(deer.Chances[2], 20, "a float key that is a whole number is that number")
    t.ok(is_plain(deer))
end)

t.test("a map inside a struct and inside a list of structs is read by its path", function()
    local deer = setup:Row("Deer", { "Creatures.WorldStatInjection", "Rewards.Extras", "Rewards.Amount" })
    local entry = deer.Creatures.WorldStatInjection["WorldSnowSlugSpawn_?"]
    t.eq(entry.SpawnWeight, 5)
    t.eq(entry.AISetup.Value, "Snow_Slug")
    t.eq(deer.Creatures.MinLevel, 5, "what was read of the struct before stays")
    t.eq(deer.Rewards[1].Extras.Luck, 0.25)
    t.eq(next(deer.Rewards[2].Extras), nil)
    t.eq(deer.Rewards[2].Amount, 2)
    t.raises(function() setup:Row("Deer", { "MovementMapping.MaxWalkSpeed" }) end, "'MovementMapping' is a map, which is read whole")
    t.raises(function() setup:Fields("MovementMapping") end, "so it has no fields")
end)

t.test("a curve is its value at each whole step from its first key to its last, and its keys", function()
    local deer = growth:Row("Deer", { "Health", "MeleeDamage" })
    local health = deer.Health
    t.eq(health.First, 0)
    t.eq(health.Last, 120)
    t.eq(math.type(health.First), "integer")
    t.eq(#health.Values, 121)
    t.eq(health.Values[1], 300)
    t.eq(health.Values[121], 500)
    t.ok(math.abs(health.Values[29] - 346.6667) < 0.001, "level 28 is the 29th value: " .. health.Values[29])
    t.eq(#health.Keys, 2)
    t.eq(health.Keys[2].Time, 120)
    t.eq(health.Keys[2].Value, 500)
    t.eq(deer.MeleeDamage, nil, "a reference to nothing is nil")
    t.ok(is_plain(deer))
    t.eq(fake.curve_values, 121)
    local other = growth:Row("Deer_Conifer", { "Health" }).Health
    t.eq(fake.curve_values, 121, "a curve two rows share is asked once")
    t.eq(#other.Values, 121)
    t.ok(other ~= health and other.Values ~= health.Values, "each row has its own copy")
    health.Values[1] = -1
    t.eq(growth:Row("Deer_Conifer", { "Health" }).Health.Values[1], 300)
    health.Values[1] = 300
end)

t.test("a curve between whole steps, an empty one, a long one and one with many keys", function()
    local kick = growth:Row("Deer_Conifer", { "MeleeDamage" }).MeleeDamage
    t.eq(kick.First, 1, "the first whole step at or after its first key")
    t.eq(kick.Last, 2)
    t.eq(#kick.Values, 2)
    t.ok(kick.Values[1] > 10 and kick.Values[2] < 40)
    t.eq(kick.Keys[1].Time, 0.5)
    local stone = growth:Row("Stone", { "Health", "MeleeDamage" })
    t.eq(#stone.Health.Values, 0)
    t.eq(#stone.Health.Keys, 0)
    t.ok(stone.Health.Last < stone.Health.First, "nothing lies between")
    t.eq(stone.MeleeDamage.Values, nil, "more steps than max_samples: the keys alone")
    t.eq(stone.MeleeDamage.First, 0)
    t.eq(stone.MeleeDamage.Last, 5000)
    t.eq(#stone.MeleeDamage.Keys, 2)
    data.flush()
    local kept = data.max_keys
    data.max_keys = 1
    local short = growth:Row("Deer", { "Health" }).Health
    data.max_keys = kept
    t.eq(short.Keys, nil, "more keys than max_keys: the values alone")
    t.eq(#short.Values, 121)
    data.flush()
end)

t.test("a curve inside a list of structs and curves as the values of a map", function()
    local deer = growth:Row("Deer", { "CustomStats.Curve", "CustomStats.Stat" })
    t.eq(deer.CustomStats[1].Curve.First, 1)
    t.eq(#deer.CustomStats[1].Curve.Values, 3)
    t.eq(deer.CustomStats[1].Curve.Values[2], 10)
    t.eq(deer.CustomStats[2].Curve, nil)
    t.eq(deer.CustomStats[2].Stat.Value, "BaseStamina_+")
    local genes = setup:Row("Deer", { "Genetics" }).Genetics
    t.eq(genes["BaseMaximumHealth_+"].Values[3], 2)
    t.eq(genes["BaseStamina_+"], false, "a reference to nothing is false in a map")
    t.ok(is_plain(genes))
    t.eq(data.stats().curves, 2)
end)

t.test("what can never be read raises an error that says what it is, each time, and nothing is logged", function()
    local logged = warnings()
    local cases = {
        Cells = "the keys of 'Cells' are IntPoint structs, which game.Data cannot use as keys",
        Owners = "the keys of 'Owners' are references to live objects, which game.Data cannot use as keys",
        Trees = "the values of 'Trees' are references to BehaviorTree objects, which game.Data never reads",
        Lists = "the values of 'Lists' are lists, maps or sets themselves",
    }
    for field, text in pairs(cases) do
        local err = t.raises(function() setup:Row("Deer", { field }) end, text, field)
        t.ok(tostring(err):find("data_maps_test.lua", 1, true), "points at the caller: " .. tostring(err))
        t.raises(function() setup:Row("Deer", { field }) end, text, field .. " again")
        t.raises(function() setup:Row("Wolf", { field, "Level" }) end, text, field .. " in a new list")
        t.raises(function() in_task(function() return setup:Load({ fields = { field } }) end) end, text, field .. " in Load")
    end
    t.raises(function() growth:Row("Rabbit", { "Icon" }) end,
        "'Icon' refers to a Texture2D object, which game.Data never reads. Only a CurveFloat is read, as its numbers")
    t.raises(function() growth:Row("Deer", { "Icon" }) end, "'Icon' refers to a Texture2D object")
    t.eq(warnings(), logged, "a mistake of the asker is not a failed row")
    t.eq(setup:Row("Deer", { "Level" }).Level, 3, "the row is read as before")
    t.eq(setup:Row("Wolf", { "MovementMapping" }).MovementMapping[3].MaxWalkSpeed, 1)
    -- the stand-in counts an object key and an object with no numbers as it would any other
    t.eq(fake.crashes, 0)
end)

t.test("Load reads maps and curves row by row and gives the frame back", function()
    data.flush()
    fake.reset()
    local rows = in_task(function() return growth:Load({ fields = { "Base", "Health" }, budget = 0 }) end)
    t.eq(count(rows), 4)
    t.eq(rows.Deer.Base["BaseCharacterMass_+"], 175)
    t.eq(#rows.Deer_Conifer.Health.Values, 121)
    t.eq(rows.Rabbit.Health, nil)
    t.ok(data.pauses >= 3, "a pause between rows: " .. data.pauses)
    local done, all, failed = growth:Loaded({ "Base", "Health" })
    t.eq(done, 4)
    t.eq(all, 4)
    t.eq(failed, 0)
    t.eq(fake.stale, 0, "nothing of the engine's was carried over a pause")
end)

t.test("a map with more entries than max_entries fails its row alone, with one line in the log", function()
    data.flush()
    local logged, kept = warnings(), data.max_entries
    data.max_entries = 2
    t.eq(growth:Row("Deer", { "Base" }), nil, "three entries")
    t.eq(growth:Row("Rabbit", { "Base" }).Base["BaseMaximumHealth_+"], 25, "one entry")
    data.max_entries = kept
    t.eq(warnings(), logged + 1)
    data.flush()
    t.eq(count(growth:Row("Deer", { "Base" }).Base), 3)
end)

t.test("Fields names a map and a reference to an object, and the writer does not go by either", function()
    local by = {}
    for _, field in ipairs(growth:Fields()) do by[field.Name] = field end
    t.eq(by.Base.Kind, "Map")
    t.eq(by.Health.Kind, "Object")
    local plan = data.internal.plan_of(S .. "AIGrowth")
    t.eq(plan.by.Base.how, nil, "nothing the writer reads or writes")
    t.eq(plan.by.Health.how, nil)
    t.eq(plan.by.Base.reads, "map")
    t.eq(plan.by.Health.reads, "object")
end)

t.test("with the switches off, a map and a curve are refused as they were", function()
    data.flush()
    data.MAPS, data.CURVES = false, false
    t.raises(function() growth:Row("Deer", { "Base" }) end, "'Base' is a Map field, which game.Data never reads")
    t.raises(function() growth:Row("Deer", { "Health" }) end, "'Health' is an Object field, which game.Data never reads")
    data.MAPS, data.CURVES = true, true
    data.flush()
    t.eq(growth:Row("Deer", { "Base" }).Base["BaseMovementSpeed_+"], 220)
    t.eq(data.stats().curves, 0, "Flush forgot the curves too")
    t.eq(#growth:Row("Deer", { "Health" }).Health.Values, 121)
    t.eq(data.stats().curves, 1)
end)

t.test("a row changed through the writer is read again with its map, and a map itself cannot be changed", function()
    local journal = Wax.import("data.journal")
    journal.clear()
    local patch = Wax.import("data.patch")
    patch.clock = function() return now end
    rawset(Wax, "mods", { list = function() return { { id = "ModA", name = "ModA" } } end })
    patch.start()
    fake.allow_writes(true)
    local owner = scope.new("ModA")
    local before = setup:Row("Wolf", { "MovementMapping", "Level" })
    t.eq(before.Level, 9)
    scope.run(owner, function()
        setup:Set("Wolf", "Level", 12)
        t.raises(function() setup:Set("Wolf", "MovementMapping", {}) end, "MovementMapping is a Map field, which this version of Wax cannot change")
    end)
    local after = setup:Row("Wolf", { "MovementMapping", "Level" })
    t.eq(after.Level, 12)
    t.eq(after.MovementMapping[3].MaxWalkSpeed, 1, "the map is read again with the row")
    t.eq(#setup:Changes(), 1)
    owner:destroy()
    for _ = 1, 200 do frame() end
    t.eq(setup:Row("Wolf", { "Level" }).Level, 9, "put back when the mod unloads")
    t.eq(#Data:Changes(), 0)
    fake.allow_writes(false)
end)

t.test("the engine was never used in a way that crashes or changes the game", function()
    for _, name in ipairs({ "stale", "grown", "crashes", "misuse", "unknown_names", "never_reads", "misses" }) do
        t.eq(fake[name], 0, name)
    end
end)

t.finish("data-maps")
