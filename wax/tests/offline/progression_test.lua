-- Run from the workspace root: tools\lua\lua54\lua.exe build\nexus-work\Progression\tests\progression_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local rules = dofile("luamods/Progression/rules.lua")

t.test("scale gives whole numbers and keeps the floor", function()
    t.eq(rules.scale(100, 3), 300)
    t.eq(rules.scale(25, 0.25), 6)
    t.eq(rules.scale(1500, 0.5), 750)
    t.eq(math.type(rules.scale(10, 2.5)), "integer")
end)

t.test("scale never drops a reward the game gives to nothing", function()
    t.eq(rules.scale(1, 0.25), 1)
    t.eq(rules.scale(0, 10), 0)
end)

t.test("caps raise MaxLevel with the cap and never lower it", function()
    t.eq(rules.caps(250, { MaxDisplayLevel = 60, MaxLevel = 1000 }).MaxLevel, 1000)
    t.eq(rules.caps(250, { MaxDisplayLevel = 60, MaxLevel = 1000 }).MaxDisplayLevel, 250)
    t.eq(rules.caps(150, { MaxDisplayLevel = 25, MaxLevel = 25 }).MaxLevel, 150)
    t.eq(rules.caps(10, { MaxDisplayLevel = 25, MaxLevel = 25 }).MaxLevel, 25)
end)

t.test("a preset lists every setting", function()
    local preset = rules.preset({ xp = 3 })
    for key in pairs(rules.VANILLA) do t.ok(preset[key] ~= nil, key) end
    t.eq(preset.xp, 3)
    t.eq(preset.player_cap, 60)
    t.eq(rules.preset({}).free_respec, false)
end)

t.finish("progression")
