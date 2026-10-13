-- Run from the workspace root: tools\lua\lua54\lua.exe build\nexus-work\BiggerStacks\tests\biggerstacks_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local filter = dofile("luamods/BiggerStacks/filter.lua")

local function tagged(...)
    local list = {}
    for _, name in ipairs({ ... }) do list[#list + 1] = { TagName = name } end
    return list
end

t.test("a tag set holds each tag and its parents, folded", function()
    local set = filter.tag_set(tagged("Item.Ammo.Bullet"))
    t.ok(set["item.ammo.bullet"]); t.ok(set["item.ammo"]); t.ok(set["item"])
    t.ok(not set["item.resource"])
end)

t.test("plain strings count as tags too", function()
    t.eq(filter.kind_of({ "Item.Resource.Ore" }), "resources")
end)

t.test("ammo", function()
    t.eq(filter.kind_of(tagged("Item.Ammo.Arrow", "Traits.Itemable")), "ammo")
end)

t.test("a building piece is anything buildable", function()
    t.eq(filter.kind_of(tagged("Building.Wood", "FieldGuide.Building.Floors", "Traits.Buildable")), "building")
end)

t.test("wood is a resource although it burns", function()
    t.eq(filter.kind_of(tagged("Item.Resource.Wood", "Item.Fuel.Combustible")), "resources")
end)

t.test("charcoal and fuel cans are fuels", function()
    t.eq(filter.kind_of(tagged("Item.Resource", "Item.Fuel.Charcoal")), "fuels")
    t.eq(filter.kind_of(tagged("Item.Fuel.Biofuel")), "fuels")
end)

t.test("ammo wins over resource, building over fuel", function()
    t.eq(filter.kind_of(tagged("Item.Resource", "Item.Ammo.Bolt")), "ammo")
    t.eq(filter.kind_of(tagged("Item.Fuel.Oil", "Traits.Buildable")), "building")
end)

t.test("food and nothing are other", function()
    t.eq(filter.kind_of(tagged("Item.Consumable.Food.Cooked")), "other")
    t.eq(filter.kind_of(nil), "other")
    t.eq(filter.kind_of({}), "other")
end)

t.test("kinds maps every Itemable row by folded name", function()
    local kinds, resources = filter.kinds({
        Wood = { Itemable = { RowName = "Item_Wood" }, Generated_Tags = { GameplayTags = tagged("Item.Resource.Wood", "Item.Fuel.Combustible") } },
        Stone_Arrow = { Itemable = { RowName = "Item_Stone_Arrow" }, Generated_Tags = { GameplayTags = tagged("Item.Ammo.Arrow") } },
        Charcoal = { Itemable = { RowName = "Item_Charcoal" }, Generated_Tags = { GameplayTags = tagged("Item.Resource", "Item.Fuel.Charcoal") } },
        Ghost = { Itemable = { RowName = "None" }, Generated_Tags = { GameplayTags = tagged("Item.Ammo.Arrow") } },
        Bare = { Generated_Tags = { GameplayTags = tagged("Item.Ammo.Arrow") } },
    })
    t.eq(kinds["item_wood"], "resources")
    t.eq(kinds["item_stone_arrow"], "ammo")
    t.eq(kinds["item_charcoal"], "fuels")
    t.eq(kinds["none"], nil)
    t.ok(resources["item_wood"], "wood is a resource")
    t.ok(resources["item_charcoal"], "charcoal is tagged a resource even as a fuel")
    t.ok(not resources["item_stone_arrow"])
end)

t.test("two static rows on one Itemable row keep the stronger kind", function()
    local kinds = filter.kinds({
        A = { Itemable = { RowName = "Item_X" }, Generated_Tags = { GameplayTags = tagged("Item.Resource") } },
        B = { Itemable = { RowName = "Item_X" }, Generated_Tags = { GameplayTags = tagged("Item.Ammo.Bullet") } },
    })
    t.eq(kinds["item_x"], "ammo")
end)

t.test("a kind's factor is its own choice or the stack multiplier", function()
    t.eq(filter.factor({ stacks = 3, ammo = "10x" }, "ammo"), 10)
    t.eq(filter.factor({ stacks = 3, ammo = filter.SAME }, "ammo"), 3)
    t.eq(filter.factor({ stacks = 3 }, "ammo"), 3)
    t.eq(filter.factor({}, "ammo"), 1)
    t.eq(filter.CHOICES[1], filter.SAME)
end)

t.test("stacks are whole numbers and only grow", function()
    t.eq(filter.stack(100, 5), 500)
    t.eq(filter.stack(20, 3), 60)
    t.eq(filter.stack(1, 50), nil, "what does not stack stays so")
    t.eq(filter.stack(100, 1), nil, "1x leaves the row alone")
    t.eq(filter.stack(nil, 2), nil)
end)

t.test("weights are whole, never below 1, and 100% leaves the row alone", function()
    t.eq(filter.weight(150, 50), 75)
    t.eq(filter.weight(1, 10), 1)
    t.eq(filter.weight(0, 50), nil)
    t.eq(filter.weight(150, 100), nil)
    t.eq(filter.weight(3, 25), 1)
end)

t.finish("biggerstacks")
