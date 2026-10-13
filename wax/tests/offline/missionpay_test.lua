-- From the workspace root: tools\lua\lua54\lua.exe build\nexus-work\MissionPay\tests\missionpay_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local pay = dofile("luamods/MissionPay/pay.lua")

local function values(changes)
    local v = {}
    for key, value in pairs(pay.VANILLA) do v[key] = value end
    for key, value in pairs(changes or {}) do v[key] = value end
    return v
end

local function reward(currency, amount)
    return { Meta = { RowName = currency, DataTableName = "D_MetaCurrency" }, Amount = amount }
end

t.test("vanilla changes nothing", function()
    t.eq(pay.rewards({ reward("Credits", 200), reward("Exotic1", 50) }, values(), 1), nil)
    t.eq(pay.rewards({}, values({ ren = 5 }), 1), nil)
    t.eq(pay.rewards(nil, values({ ren = 5 }), 1), nil)
end)

t.test("ren and exotics take their own multipliers", function()
    local out = pay.rewards({ reward("Credits", 200), reward("Exotic1", 50), reward("Exotic_Red", 100), reward("Biomass", 5) },
        values({ ren = 2, exotics = 3 }), 1)
    t.eq(out[1].Amount, 400)
    t.eq(out[2].Amount, 150)
    t.eq(out[3].Amount, 300)
    t.eq(out[4].Amount, 5, "biomass keeps its number")
end)

t.test("biomass and licences take the other multiplier and no difficulty", function()
    local out = pay.rewards({ reward("Licence", 1), reward("Biomass", 5) }, values({ others = 5, hard = 2 }), 2)
    t.eq(out[1].Amount, 5)
    t.eq(out[2].Amount, 25)
end)

t.test("difficulty scales ren and exotics by the prospect", function()
    local list = { reward("Credits", 200), reward("Exotic1", 100) }
    local v = values({ easy = 0.5, hard = 1.5, extreme = 2 })
    t.eq(pay.rewards(list, v, 0)[1].Amount, 100)
    t.eq(pay.rewards(list, v, 2)[2].Amount, 150)
    t.eq(pay.rewards(list, v, 3)[1].Amount, 400)
    t.eq(pay.rewards(list, v, 1), nil, "normal at 1x is the game's number")
    t.eq(pay.rewards(list, v, nil), nil, "a mission no prospect carries is left alone")
end)

t.test("a reward never falls to nothing", function()
    t.eq(pay.rewards({ reward("Credits", 5) }, values({ easy = 0.25 }), 0)[1].Amount, 1)
    t.eq(pay.scale(0, 10), 0)
end)

t.test("flat base pay replaces ren only", function()
    local out = pay.rewards({ reward("Credits", 25), reward("Exotic1", 100) },
        values({ base_pay = true, base = 3500, hard = 1.5 }), 2)
    t.eq(out[1].Amount, 5250)
    t.eq(out[2].Amount, 150)
    t.eq(pay.rewards({ reward("Exotic1", 100) }, values({ base_pay = true }), 1), nil, "no ren, no base")
end)

t.test("amounts round to whole numbers", function()
    t.eq(pay.rewards({ reward("Credits", 25) }, values({ ren = 2.5 }), 1)[1].Amount, 63)
    t.eq(pay.scale(50, 2.5), 125)
    t.eq(pay.scale(10, 1.25), 13)
end)

t.test("the list given back is a new one of the same shape", function()
    local list = { reward("Credits", 200), reward("Exotic1", 50) }
    local out = pay.rewards(list, values({ ren = 2 }), 1)
    t.ok(out ~= list)
    t.ok(out[1] ~= list[1])
    t.eq(#out, 2)
    t.eq(out[2].Meta.RowName, "Exotic1")
    t.eq(out[2].Meta.DataTableName, "D_MetaCurrency")
    t.eq(list[1].Amount, 200, "the game's list is untouched")
end)

t.test("vanilla is known", function()
    t.ok(pay.vanilla(values()))
    t.ok(pay.vanilla(values({ base = 9000 })), "a base with base pay off is still vanilla")
    t.ok(not pay.vanilla(values({ base_pay = true })))
    t.ok(not pay.vanilla(values({ account_xp = 2 })))
    t.ok(pay.currency_vanilla(values({ account_xp = 2 })))
    t.ok(not pay.currency_vanilla(values({ extreme = 2 })))
end)

t.test("currencies are matched without regard to case", function()
    t.eq(pay.kind("credits"), "ren")
    t.eq(pay.kind("EXOTIC_URANIUM"), "exotics")
    t.eq(pay.kind("Licence"), "others")
    t.eq(pay.kind(nil), "others")
end)

t.finish("missionpay")
