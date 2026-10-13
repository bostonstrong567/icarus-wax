-- Run from the workspace root: tools\lua\lua54\lua.exe build\nexus-work\Tames\tests\tames_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local rules = dofile("luamods/Tames/Rules.lua")

t.test("a time is scaled, rounded and never under the least", function()
    t.eq(rules.scaled(900, 0.67, true, 1), 603)
    t.eq(rules.scaled(900, 0.5, true, 1), 450)
    t.eq(rules.scaled(25, 0.5, true, 1), 13)
    t.eq(rules.scaled(1, 0.01, true, 1), 1)
    t.eq(rules.scaled(30, 3, true), 90)
    t.eq(rules.scaled(25, 0.5, false, 1), 12.5)
    t.eq(rules.scaled(nil, 0.5, true, 1), nil)
end)

t.test("a chance is scaled within 100 and 0 stays 0", function()
    t.eq(rules.chance(75, 2), 100)
    t.eq(rules.chance(30, 2), 60)
    t.eq(rules.chance(15, 1.5), 23)
    t.eq(rules.chance(0, 3), nil)
end)

t.test("only a pet with two orders gets the full list, as a copy", function()
    local full = { 0, 1, 2, 3 }
    local got = rules.orders({ 0, 1 }, full)
    t.eq(#got, 4)
    t.ok(got ~= full, "a copy")
    t.eq(rules.orders({ 0, 1, 2, 3 }, full), nil)
    t.eq(rules.orders({ 2 }, full), nil)
    t.eq(rules.orders(nil, full), nil)
end)

t.finish("tames")
