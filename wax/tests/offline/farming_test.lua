-- Run from the workspace root: tools\lua\lua54\lua.exe build\nexus-work\Farming\tests\farming_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local rules = dofile("luamods/Farming/rules.lua")

local function handle(name) return { RowName = name, DataTableName = "D_FarmingGrowthStates" } end

local seeds = {
    Corn = { Stage1 = handle("Corn_Growth_01"), Stage2 = handle("Corn_Growth_02"), Stage3 = handle("Corn_Growth_03"),
        Stage4 = handle("Corn_Growth_04"), Mature = handle("Corn_Growth_05") },
    Invalid = { Stage1 = handle("None"), Stage2 = handle("None"), Stage3 = handle("None"), Stage4 = handle("None"), Mature = handle("None") },
    Odd = { Stage1 = handle("odd_growth_01"), Mature = {} },
}

t.test("stages sorts growing rows from the ripe one", function()
    local growing, ripe = rules.stages(seeds)
    t.ok(growing["corn_growth_01"])
    t.ok(growing["corn_growth_04"])
    t.ok(not growing["corn_growth_05"])
    t.ok(ripe["corn_growth_05"])
    t.ok(not ripe["corn_growth_01"])
    t.ok(growing["odd_growth_01"])
    t.ok(not growing["none"])
    local count = 0
    for _ in pairs(growing) do count = count + 1 end
    t.eq(count, 5)
end)

t.test("a stage no seed names is known by its name", function()
    t.ok(rules.looks_growing("Fiber_Growth_04_0"))
    t.ok(rules.looks_growing("Test_Growth_01"))
    t.ok(not rules.looks_growing("Corn_Growth_05"))
    t.ok(not rules.looks_growing("Corn_Growth_Dead"))
    t.ok(not rules.looks_growing("Rhubarb_Dead"))
end)

t.test("growth time is divided and never under a second", function()
    t.eq(rules.growth_time(300, 1.5), 200)
    t.eq(rules.growth_time(1800, 2), 900)
    t.eq(rules.growth_time(10, 25), 1)
    t.eq(math.type(rules.growth_time(300, 2)), "float")
end)

t.test("a ripe crop keeps longer", function()
    t.eq(rules.ripe_time(7200, 3), 21600)
end)

t.test("fatigue is a whole share of the game's own", function()
    t.eq(rules.fatigue(10, 100), 10)
    t.eq(rules.fatigue(10, 10), 1)
    t.eq(rules.fatigue(50, 10), 5)
    t.eq(rules.fatigue(100, 10), 10)
    t.eq(rules.fatigue(10, 0), 0)
    t.eq(math.type(rules.fatigue(10, 10)), "integer")
end)

t.finish("farming")
