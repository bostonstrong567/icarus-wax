-- The sums of Gathering and Drills: tools\lua\lua54\lua.exe build\nexus-work\Gathering\tests\gathering_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local scale = dofile("luamods/Gathering/scale.lua")

t.test("yield is multiplied and a tool that does not do the work is left alone", function()
    t.eq(scale.yield_at(1, 2), 2)
    t.eq(scale.yield_at(1.25, 2), 2.5)
    t.eq(scale.yield_at(0, 2), nil)
end)

t.test("felling damage is a whole number", function()
    t.eq(scale.damage_at(25, 2), 50)
    t.eq(scale.damage_at(25, 1.5), 38, "rounds to the nearest")
    t.eq(scale.damage_at(0, 2), nil)
end)

t.test("a deposit's seconds", function()
    t.eq(scale.seconds_at(30, 100, 0), 30)
    t.eq(scale.seconds_at(30, 50, 0), 15)
    t.eq(scale.seconds_at(15, 5, 0), 1, "never under a second")
    t.eq(scale.seconds_at(55, 10, 0), 6, "rounds to the nearest")
    t.eq(scale.seconds_at(30, 50, 5), 5, "a fixed time wins over the share")
    t.eq(scale.seconds_at(30, 300, 0), 90)
end)

t.test("the extractor's work", function()
    t.eq(scale.work_at(2000, 50), 1000)
    t.eq(scale.work_at(2000, 5), 100)
    t.eq(scale.work_at(10, 5), 1)
end)

t.test("only the extractor's recipe set counts", function()
    t.eq(scale.is_extractor(nil, { RecipeSets = { { RowName = "Meta_Extractor", DataTableName = "D_RecipeSets" } } }), true)
    t.eq(scale.is_extractor(nil, { RecipeSets = { { RowName = "Character" } } }), false)
    t.eq(scale.is_extractor(nil, {}), false)
end)

t.finish("gathering")
