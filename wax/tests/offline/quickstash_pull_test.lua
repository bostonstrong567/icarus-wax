-- Quick Stash's pull sums: tools\lua\lua54\lua.exe wax\tests\offline\quickstash_pull_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local pull = dofile((arg and arg[1] or "luamods/QuickStash/") .. "pull.lua")
local share = assert(loadfile("wax/runtime/Scripts/wax/world/share.lua"))({})

local RECIPES = {
    { Name = "Refined_Metal", RecipeSets = { { RowName = "Stone_Furnace" }, { RowName = "Concrete_Furnace" } }, Inputs = { { Element = { RowName = "Metal_Ore" }, Count = 2 } } },
    { Name = "Refined_Copper", RecipeSets = { { RowName = "Stone_Furnace" } }, Inputs = { { Element = { RowName = "Copper_Ore" }, Count = 2 } } },
    { Name = "Aluminium", RecipeSets = { { RowName = "Concrete_Furnace" } }, Inputs = { { Element = { RowName = "Aluminium_Ore" }, Count = 2 } } },
    { Name = "Steel_Ingot", RecipeSets = { { RowName = "Stone_Furnace" } }, Inputs = { { Element = { RowName = "Steel_Bloom" }, Count = 1 }, { Element = { RowName = "Charcoal" }, Count = 1 } } },
}
local FACTS = { metal_ore = { MaxStack = 50, DisplayName = "Iron Ore" }, copper_ore = { MaxStack = 50, DisplayName = "Copper Ore" },
    steel_bloom = { MaxStack = 100, DisplayName = "Steel Bloom" }, charcoal = { MaxStack = 500, DisplayName = "Charcoal" } }
local function facts(item) return FACTS[item:lower()] end
local function spread(total, item, stations) return share.spread(total, item, stations, facts) end

t.test("a station accepts the inputs of its recipe set only", function()
    local stone = pull.accepted("Stone_Furnace", RECIPES)
    t.eq(stone.metal_ore, "Metal_Ore")
    t.eq(stone.copper_ore, "Copper_Ore")
    t.eq(stone.aluminium_ore, nil, "the stone furnace cannot smelt aluminium")
    t.eq(stone.charcoal, "Charcoal")
    t.eq(next(pull.accepted("", RECIPES)), nil)
    t.eq(next(pull.accepted("Nothing", RECIPES)), nil)
end)

t.test("choices are sorted by the names players see", function()
    local choices = pull.choices(pull.accepted("Stone_Furnace", RECIPES), facts)
    t.eq(#choices, 4)
    t.eq(choices[1].name, "Charcoal")
    t.eq(choices[2].name, "Copper Ore")
    t.eq(choices[3].name, "Iron Ore")
end)

t.test("what is available comes nearest source first, with totals", function()
    local sources = { { name = "Crate", metres = 3, stacks = { { Item = "Metal_Ore", Count = 20, Slot = 1 }, { Item = "Wood", Count = 5, Slot = 2 } } },
        { name = "Cupboard", metres = 9, stacks = { { Item = "metal_ore", Count = 30, Slot = 4 } } } }
    local stacks, totals = pull.available(sources, { metal_ore = "Metal_Ore" })
    t.eq(totals.metal_ore, 50)
    t.eq(#stacks.metal_ore, 2)
    t.eq(stacks.metal_ore[1].source, 1)
    t.eq(stacks.metal_ore[2].stack.Slot, 4)
    t.eq(totals.wood, nil)
end)

t.test("an amount caps a pull: less than available, more, zero, empty, and half", function()
    local sources = { { name = "Backpack", metres = 0, stacks = { { Item = "Metal_Ore", Count = 15, Slot = 1 } } },
        { name = "Crate", metres = 3, stacks = { { Item = "Metal_Ore", Count = 40, Slot = 1 } } },
        { name = "Cupboard", metres = 9, stacks = { { Item = "Metal_Ore", Count = 30, Slot = 2 } } } }
    local function stations() return { { name = "Stone Furnace", metres = 5, stacks = {}, size = 4, used = 0 } } end
    local function total(moves)
        local sum = 0
        for _, move in ipairs(moves) do sum = sum + move.count end
        return sum
    end
    local less = pull.plan({ metal_ore = "Metal_Ore" }, sources, stations(), facts, spread, nil, { metal_ore = 50 })
    t.eq(total(less), 50, "less than the 85 available: exactly the amount")
    t.eq(less[1].source, 1, "the backpack first")
    t.eq(less[1].count, 15)
    t.eq(less[2].source, 2, "then the nearest source")
    t.eq(less[2].count, 35, "the rest of the amount out of the crate's stack")
    t.eq(#less, 2)
    local more = pull.plan({ metal_ore = "Metal_Ore" }, sources, stations(), facts, spread, nil, { metal_ore = 500 })
    t.eq(total(more), 85, "more than available: everything")
    t.eq(#pull.plan({ metal_ore = "Metal_Ore" }, sources, stations(), facts, spread, nil, { metal_ore = 0 }), 0, "zero: nothing")
    t.eq(total(pull.plan({ metal_ore = "Metal_Ore" }, sources, stations(), facts, spread, nil, nil)), 85, "no limits: everything")
    t.eq(total(pull.plan({ metal_ore = "Metal_Ore" }, sources, stations(), facts, spread, nil, {})), 85, "an empty box: everything")
    local DIR = (arg and arg[1]) or "luamods/QuickStash/"
    local env = setmetatable({ require = function(name) return dofile(DIR .. name .. ".lua") end }, { __index = _G })
    local picker = assert(loadfile(DIR .. "picker.lua", "t", env))()
    t.eq(picker.limit_for({ count = 85 }, "", false), nil, "empty means all")
    t.eq(picker.limit_for({ count = 85 }, "12a3", false), 123, "digits only")
    t.eq(picker.limit_for({ count = 85 }, "0", false), 0)
    t.eq(picker.limit_for({ count = 85 }, "", true), 43, "Shift: half of what is available, rounded up")
    t.eq(picker.limit_for({ count = 1 }, "", true), 1)
    t.eq(picker.limit_for({}, "", true), 1, "no count known: one")
    t.eq(picker.digits("1234567890"), "123456", "at most six digits")
    t.eq(picker.top_padding(0, 50), 100, "a measured height of 0: a row plus the header's known height")
    t.eq(picker.top_padding(20, 50), 100, "too small to be the header: the same")
    t.eq(picker.top_padding(58, 50), 58, "a sensible measured height is used as it is")
    t.eq(picker.top_padding(500, 50), 100, "an absurd one is not")
    t.eq(picker.top_padding(nil, nil), 100, "nothing known: two rows")
    t.eq(picker.top_padding(0, 75), 125)
end)

t.test("one station gets whole stacks up to its room", function()
    local sources = { { name = "Crate", metres = 3, stacks = { { Item = "Metal_Ore", Count = 20, Slot = 1 }, { Item = "Metal_Ore", Count = 30, Slot = 2 } } } }
    local stations = { { name = "Stone Furnace", metres = 5, stacks = {}, size = 1, used = 0 } }
    local moves = pull.plan({ metal_ore = "Metal_Ore" }, sources, stations, facts, spread)
    t.eq(#moves, 2)
    t.eq(moves[1].count, 20)
    t.eq(moves[1].slot, 1)
    t.eq(moves[2].count, 30, "one slot of 50 takes both")
    t.eq(moves[2].station, 1)
end)

t.test("two stations share a stack: the second gets the part the first did not", function()
    local sources = { { name = "Crate", metres = 3, stacks = { { Item = "Metal_Ore", Count = 40, Slot = 1 } } } }
    local stations = { { name = "Furnace A", metres = 5, stacks = {}, size = 4, used = 0 }, { name = "Furnace B", metres = 8, stacks = {}, size = 4, used = 0 } }
    local moves = pull.plan({ metal_ore = "Metal_Ore" }, sources, stations, facts, spread)
    t.eq(#moves, 2)
    t.eq(moves[1].station, 1)
    t.eq(moves[1].count, 20)
    t.eq(moves[2].station, 2)
    t.eq(moves[2].count, 20)
    t.eq(moves[2].slot, 1, "the same source stack")
end)

t.test("a station that does not accept an item is passed over", function()
    local sources = { { name = "Crate", metres = 3, stacks = { { Item = "Metal_Ore", Count = 10, Slot = 1 } } } }
    local stations = { { name = "Mortar", metres = 2, stacks = {}, size = 4, used = 0, accepts = function() return false end },
        { name = "Furnace", metres = 8, stacks = {}, size = 4, used = 0 } }
    local moves = pull.plan({ metal_ore = "Metal_Ore" }, sources, stations, facts, spread)
    t.eq(#moves, 1)
    t.eq(moves[1].station, 2)
end)

t.test("the words", function()
    local sources = { { name = "Storage Crate", metres = 6.2 }, { name = "Cupboard", metres = 9 } }
    local stations = { { name = "Stone Furnace", metres = 4 }, { name = "Stone Furnace", metres = 7.6 } }
    local one = { { station = 1, source = 1, slot = 1, item = "Metal_Ore", count = 40 }, { station = 1, source = 1, slot = 2, item = "Metal_Ore", count = 10 },
        { station = 1, source = 2, slot = 1, item = "Copper_Ore", count = 8 } }
    t.eq(pull.describe(one, sources, stations, facts), "50 Iron Ore <- Storage Crate (6 m)\n8 Copper Ore <- Cupboard (9 m)")
    local two = { { station = 1, source = 1, slot = 1, item = "Metal_Ore", count = 20 }, { station = 2, source = 1, slot = 1, item = "Metal_Ore", count = 20 } }
    t.eq(pull.describe(two, sources, stations, facts), "20 Iron Ore <- Storage Crate (6 m) -> Stone Furnace (4 m)\n20 Iron Ore <- Storage Crate (6 m) -> Stone Furnace (8 m)")
    t.eq(pull.describe({}, sources, stations, facts), nil)
    t.eq(pull.nothing("ore", 30, 3), "Nothing in range (30 m) holds ore this station can use.")
    t.eq(pull.nothing("ore", 30, 0), "This station takes nothing that can be pulled.")
end)

t.test("fuels rank by the game's value, then fuel-only before materials, then by amount", function()
    local totals = { fiber = 500, wood = 100, charcoal = 20, coal_ore = 5, stick = 100 }
    local spelling = { fiber = "Fiber", wood = "Wood", charcoal = "Charcoal", coal_ore = "Coal_Ore", stick = "Stick" }
    local values = { Fiber = { units = 5000 }, Wood = { units = 150000, material = true }, Charcoal = { units = 150000 }, Coal_Ore = { units = 600000 }, Stick = { units = 10000, material = true } }
    local order = pull.rank_fuels(totals, spelling, function(item) return values[item] end)
    t.eq(table.concat(order, " "), "coal_ore charcoal wood stick fiber")
end)

t.test("the plan deals the keys out in the given order, and the room one takes is gone for the next", function()
    local sources = { { name = "Pack", metres = 0, stacks = { { Item = "Fiber", Count = 50, Slot = 1 }, { Item = "Coal_Ore", Count = 30, Slot = 2 } } } }
    local slot = { name = "Furnace fuel", metres = 4, stacks = {}, size = 1, used = 0 }
    local wanted = { fiber = "Fiber", coal_ore = "Coal_Ore" }
    local function spread_fuel(total, item, stations) return share.spread(total, item, stations, function(row) return { MaxStack = row:lower() == "coal_ore" and 50 or 200 } end) end
    local moves = pull.plan(wanted, sources, { slot }, function(row) return { MaxStack = row:lower() == "coal_ore" and 50 or 200 } end, spread_fuel, { "coal_ore", "fiber" })
    t.eq(#moves, 1, "the one slot took the coal, so no fiber")
    t.eq(moves[1].item, "Coal_Ore")
    t.eq(moves[1].count, 30)
end)

t.test("the fuel slot: the same fuel tops a half stack up first, a full stack is full, an empty slot takes the best", function()
    local values = { Coal_Ore = { units = 600000 }, Charcoal = { units = 150000 }, Wood = { units = 150000, material = true } }
    local function fuel_facts(item) return values[item] end
    local function stack(item) return { MaxStack = item:lower() == "coal_ore" and 50 or 200, DisplayName = item == "Coal_Ore" and "Coal Ore" or item } end
    local function spread_fuel(total, item, slots) return share.spread(total, item, slots, stack) end
    local sources = { { name = "Pack", metres = 0, stacks = { { Item = "Charcoal", Count = 30, Slot = 1 }, { Item = "Coal_Ore", Count = 40, Slot = 2 } } } }
    local wanted = { charcoal = "Charcoal", coal_ore = "Coal_Ore" }
    -- a half stack of charcoal: charcoal first, although coal burns better, and coal has no slot
    local half = { name = "Furnace fuel", metres = 4, stacks = { { Item = "Charcoal", Count = 120, Slot = 1 } }, size = 1, used = 1 }
    local _, totals = pull.available(sources, wanted)
    local order = pull.rank_fuels(totals, wanted, fuel_facts, pull.held_in({ half }))
    t.eq(order[1], "charcoal")
    local moves = pull.plan(wanted, sources, { half }, stack, spread_fuel, order)
    t.eq(#moves, 1)
    t.eq(moves[1].item, "Charcoal")
    t.eq(moves[1].count, 30)
    -- a full stack: nothing fits, and the words say full
    local full = { name = "Furnace fuel", metres = 4, stacks = { { Item = "Coal_Ore", Count = 50, Slot = 1 } }, size = 1, used = 1 }
    t.eq(#pull.plan(wanted, sources, { full }, stack, spread_fuel, order), 0)
    t.eq(pull.fuel_why({ full }, totals, stack, order, wanted), "The fuel slot is full.")
    -- 28 coal of 50 is room: more coal goes in
    local part = { name = "Furnace fuel", metres = 4, stacks = { { Item = "Coal_Ore", Count = 28, Slot = 1 } }, size = 1, used = 1 }
    local order2 = pull.rank_fuels(totals, wanted, fuel_facts, pull.held_in({ part }))
    local moves2 = pull.plan(wanted, sources, { part }, stack, spread_fuel, order2)
    t.eq(#moves2, 1)
    t.eq(moves2[1].item, "Coal_Ore")
    t.eq(moves2[1].count, 22)
    -- an empty slot takes the best fuel
    local empty = { name = "Furnace fuel", metres = 4, stacks = {}, size = 1, used = 0 }
    local order3 = pull.rank_fuels(totals, wanted, fuel_facts, pull.held_in({ empty }))
    t.eq(order3[1], "coal_ore")
    -- no sources: the words name what to find
    t.eq(pull.fuel_why({ empty }, {}, stack, order3, wanted), "No Coal Ore, Charcoal in range to add.")
    t.eq(pull.fuel_why({ part }, {}, stack, order2, wanted), "No Coal Ore in range to top the slot up with.")
    t.eq(pull.fuel_why({ part }, { charcoal = 30 }, stack, order2, wanted), "The slot holds Coal Ore, and only more of it goes in.")
end)

t.test("the stack size is asked each time: another mod may have changed it between two pulls", function()
    local most = 50
    local function facts() return { MaxStack = most } end
    local function spread_live(total, item, stations) return share.spread(total, item, stations, facts) end
    local sources = { { name = "Crate", metres = 3, stacks = { { Item = "Metal_Ore", Count = 120, Slot = 1 } } } }
    local station = { name = "Furnace", metres = 5, stacks = {}, size = 1, used = 0 }
    local first = pull.plan({ metal_ore = "Metal_Ore" }, sources, { station }, facts, spread_live)
    t.eq(first[1].count, 50, "one slot of 50")
    most = 200
    local second = pull.plan({ metal_ore = "Metal_Ore" }, sources, { station }, facts, spread_live)
    t.eq(second[1].count, 120, "the same slot takes all 120 once stacks are 200")
end)

t.test("which stations get PULL: materials over time yes, crafting benches no", function()
    local rows = {
        { RecipeSets = { { RowName = "Crafting_Bench" } }, Outputs = { { Element = { RowName = "Stone_Pickaxe" } } } },
        { RecipeSets = { { RowName = "Crafting_Bench" } }, Outputs = { { Element = { RowName = "Wood_Floor" } } } },
        { RecipeSets = { { RowName = "Crafting_Bench" } }, Outputs = { { Element = { RowName = "Rope" } } } },
        { RecipeSets = { { RowName = "Mortar_And_Pestle" } }, Outputs = { { Element = { RowName = "Epoxy" } } } },
        { RecipeSets = { { RowName = "Mortar_And_Pestle" } }, Outputs = { { Element = { RowName = "Flour" } } } },
        { RecipeSets = { { RowName = "Stone_Furnace" } }, Outputs = { { Element = { RowName = "Refined_Metal" } } } },
        { RecipeSets = { { RowName = "Campfire" } }, Outputs = { { Element = { RowName = "Cooked_Meat" } } } },
    }
    local kinds = { Stone_Pickaxe = "made", Wood_Floor = "made", Rope = "material", Epoxy = "material", Flour = "material", Refined_Metal = "material", Cooked_Meat = "material" }
    local function kind_of(row) return kinds[row] end
    t.eq(pull.material_share("Crafting_Bench", rows, kind_of) < 0.5, true)
    t.eq(pull.material_share("Mortar_And_Pestle", rows, kind_of), 1)
    t.eq(pull.material_share("Nothing", rows, kind_of), -1)
    t.ok(not pull.station_pulls(false, false, pull.material_share("Crafting_Bench", rows, kind_of)), "Crafting Bench")
    t.ok(pull.station_pulls(false, false, pull.material_share("Mortar_And_Pestle", rows, kind_of)), "Mortar and Pestle")
    t.ok(pull.station_pulls(true, true, pull.material_share("Stone_Furnace", rows, kind_of)), "Stone Furnace")
    t.ok(pull.station_pulls(true, true, pull.material_share("Campfire", rows, kind_of)), "Campfire")
    t.ok(pull.station_pulls(false, true, -1), "a fuel slot alone is enough")
    t.ok(not pull.station_pulls(false, false, -1), "no outputs known and nothing else: no PULL")
    local crate = pull.screen_buttons("storage", false, false, -1)
    t.ok(crate.pull and not crate.fuel, "a storage container's screen gets PULL and no FUEL")
    local bench = pull.screen_buttons("station", false, false, 0.17)
    t.ok(not bench.pull and not bench.fuel, "a crafting bench gets neither")
    local furnace = pull.screen_buttons("station", true, true, 1)
    t.ok(furnace.pull and furnace.fuel, "a furnace gets both")
    local mortar = pull.screen_buttons("station", false, false, 0.98)
    t.ok(mortar.pull and not mortar.fuel, "the mortar gets PULL only")
end)

t.finish("quickstash-pull")
