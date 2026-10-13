-- From the workspace root: tools\lua\lua54\lua.exe build\nexus-work\WorkshopPrices\tests\workshopprices_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local prices = dofile("luamods/WorkshopPrices/prices.lua")

local function cost(currency, amount)
    return { Meta = { RowName = currency, DataTableName = "D_MetaCurrency" }, Amount = amount }
end

t.test("no discount changes nothing", function()
    t.eq(prices.discount({ cost("Credits", 50) }, 0), nil)
    t.eq(prices.discount({}, 30), nil)
    t.eq(prices.discount(nil, 30), nil)
end)

t.test("a discount comes off every currency of a price", function()
    local out = prices.discount({ cost("Credits", 500), cost("Exotic1", 250) }, 30)
    t.eq(out[1].Amount, 350)
    t.eq(out[2].Amount, 175)
    t.eq(out[2].Meta.RowName, "Exotic1")
    t.eq(out[2].Meta.DataTableName, "D_MetaCurrency")
end)

t.test("amounts round to whole numbers and never go below nothing", function()
    t.eq(prices.discount({ cost("Credits", 25) }, 30)[1].Amount, 18)
    t.eq(prices.discount({ cost("Credits", 25) }, 100)[1].Amount, 0)
    t.eq(prices.discount({ cost("Credits", 0) }, 50), nil, "a free thing stays free")
end)

t.test("the list given back is a new one", function()
    local list = { cost("Credits", 100) }
    local out = prices.discount(list, 50)
    t.ok(out ~= list)
    t.ok(out[1] ~= list[1])
    t.eq(list[1].Amount, 100)
end)

t.test("the exchange gives the 10x Exotics Conversion numbers at 10x", function()
    t.eq(prices.exchange(5, 10), 50)
    t.eq(prices.exchange(7, 10), 70)
    t.eq(prices.exchange(10, 10), 100)
end)

t.test("the exchange rounds and never gives less than one", function()
    t.eq(prices.exchange(5, 1.5), 8)
    t.eq(prices.exchange(1, 0.25), 1)
    t.eq(prices.exchange(0, 10), 0)
end)

t.test("a deposit's density is scaled as it is", function()
    t.eq(prices.yield(0.5, 2), 1.0)
    t.eq(prices.yield(0.5, 1.5), 0.75)
end)

t.test("vanilla is known", function()
    t.ok(prices.vanilla({ research = 0, replicate = 0, conversion = 1, deposit = 1 }))
    t.ok(not prices.vanilla({ research = 30, replicate = 0, conversion = 1, deposit = 1 }))
    t.ok(not prices.vanilla({ research = 0, replicate = 0, conversion = 1, deposit = 2 }))
end)

t.finish("workshopprices")
