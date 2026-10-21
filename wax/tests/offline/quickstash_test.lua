-- The sums of Quick Stash: tools\lua\lua54\lua.exe wax\tests\offline\quickstash_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local push = dofile("luamods/QuickStash/push.lua")

local FACTS = {
    wood = { MaxStack = 100, DisplayName = "Wood" },
    fiber = { MaxStack = 200, DisplayName = "Fiber" },
    stone = { MaxStack = 100, DisplayName = "Stone" },
    stone_pickaxe = { MaxStack = 1, DisplayName = "Stone Pickaxe" },
    odd_thing = { DisplayName = "Odd Thing" },
}
local function facts(item) return FACTS[push.fold(item)] end

t.test("kinds that take a push, and those left alone", function()
    for _, kind in ipairs({ "Storage_Metal_Cupboard", "Processor", "Processor_T3", "Firepit", "Container_Small" }) do
        t.ok(push.takes(kind), kind)
    end
    for _, kind in ipairs({ "Fuel_Combustible", "Rain_Reservoir_Ice", "Player_Grave", "Mission_Communicator", "Animal_Corpse",
        "Dropship_RemoveOnly", "Quickbar", "Equipment", "Backpack", "", nil }) do
        t.ok(not push.takes(kind), tostring(kind))
    end
end)

t.test("a stack tops up what the container holds, then takes free slots", function()
    local carried = { { Item = "Wood", Count = 150 } }
    local crate = { name = "Crate", metres = 5, size = 10, used = 1, stacks = { { Item = "wood", Count = 60 } } }
    local moves = push.plan(carried, { crate }, facts)
    t.eq(#moves, 1)
    t.eq(moves[1].container, 1)
    t.eq(moves[1].item, "Wood", "the backpack's spelling, not the container's")
    t.eq(moves[1].count, 150, "40 onto the stack, 110 into two free slots")
end)

t.test("a full container passes the rest to the next one", function()
    local carried = { { Item = "Wood", Count = 150 }, { Item = "Fiber", Count = 30 } }
    local full = { name = "Full", metres = 2, size = 2, used = 2, stacks = { { Item = "Wood", Count = 100 }, { Item = "Wood", Count = 90 } } }
    local crate = { name = "Crate", metres = 8, size = 4, used = 2, stacks = { { Item = "Wood", Count = 10 }, { Item = "Fiber", Count = 100 } } }
    local moves = push.plan(carried, { full, crate }, facts)
    t.eq(#moves, 3)
    t.eq(moves[1].container, 1)
    t.eq(moves[1].count, 10, "only the room on the full one's stacks")
    t.eq(moves[2].container, 2)
    t.eq(moves[2].item, "Wood")
    t.eq(moves[2].count, 140, "90 onto the stack, 50 into a free slot")
    t.eq(moves[3].item, "Fiber")
    t.eq(moves[3].count, 30)
end)

t.test("free slots run out", function()
    local carried = { { Item = "Wood", Count = 500 } }
    local crate = { name = "Crate", metres = 5, size = 3, used = 1, stacks = { { Item = "Wood", Count = 100 } } }
    local moves = push.plan(carried, { crate }, facts)
    t.eq(moves[1].count, 200, "two free slots of 100")
end)

t.test("nothing goes where nothing matches, and tools stay with the player", function()
    local carried = { { Item = "Stone", Count = 20 }, { Item = "Stone_Pickaxe", Count = 1 }, { Item = "Odd_Thing", Count = 3 } }
    local crate = { name = "Crate", metres = 5, size = 10, used = 3,
        stacks = { { Item = "Wood", Count = 1 }, { Item = "Stone_Pickaxe", Count = 1 }, { Item = "Odd_Thing", Count = 1 } } }
    t.eq(#push.plan(carried, { crate }, facts), 0)
    t.eq(#push.plan({}, { crate }, facts), 0)
    t.eq(#push.plan(carried, {}, facts), 0)
end)

t.test("several stacks of one item are one sum, and names compare folded", function()
    local carried = { { Item = "Wood", Count = 100 }, { Item = "WOOD", Count = 20 } }
    local crate = { name = "Crate", metres = 5, size = 5, used = 1, stacks = { { Item = "wood", Count = 50 } } }
    local moves = push.plan(carried, { crate }, facts)
    t.eq(#moves, 1)
    t.eq(moves[1].count, 120)
end)

t.test("what the game moved is laid over the plan in order", function()
    local moves = { { container = 1, item = "Wood", count = 10 }, { container = 2, item = "Wood", count = 140 }, { container = 2, item = "Fiber", count = 30 } }
    local done = push.actual(moves, { wood = 100, fiber = 0 })
    t.eq(#done, 2)
    t.eq(done[1].count, 10)
    t.eq(done[2].count, 90)
    t.eq(done[2].container, 2)
    t.eq(#push.actual(moves, {}), 0)
end)

t.test("counts, what left, and what was asked", function()
    local before = push.counts({ { Item = "Wood", Count = 100 }, { Item = "wood", Count = 50 }, { Item = "Fiber", Count = 12 } })
    t.eq(before.wood, 150)
    local moved = push.moved(before, { wood = 10, fiber = 12 })
    t.eq(moved.wood, 140)
    t.eq(moved.fiber, nil, "nothing left of it")
    t.eq(push.moved(before, { wood = 200 }).wood, nil, "more than before is not a move")
    local asked = push.asked({ { item = "Wood", count = 10 }, { item = "wood", count = 5 } })
    t.eq(asked.wood, 15)
end)

t.test("the words say what went where, one container a line", function()
    local containers = { { name = "Storage Crate", metres = 6.2 }, { name = "Stone Furnace", metres = 8.7 } }
    local moves = { { container = 1, item = "Wood", count = 40 }, { container = 1, item = "Fiber", count = 12 }, { container = 2, item = "Stone", count = 8 } }
    t.eq(push.describe(moves, containers, facts), "40 Wood, 12 Fiber -> Storage Crate (6 m)\n8 Stone -> Stone Furnace (9 m)")
    t.eq(push.describe({ { container = 2, item = "Stone", count = 8 } }, containers, facts), "8 Stone -> Stone Furnace (9 m)")
    t.eq(push.describe({}, containers, facts), push.NOTHING)
    t.eq(push.describe(nil, containers, facts), push.NOTHING)
end)

t.test("an unknown item reads by its row, and two moves of one item to one place are one sum", function()
    local containers = { { name = "Crate", metres = 3 } }
    local moves = { { container = 1, item = "Wood", count = 1 }, { container = 1, item = "Metal_Ore", count = 3 }, { container = 1, item = "wood", count = 2 } }
    t.eq(push.describe(moves, containers, facts), "3 Wood, 3 Metal Ore -> Crate (3 m)")
end)

t.test("past the limit of lines it says how many more", function()
    local containers, moves = {}, {}
    for i = 1, 8 do
        containers[i] = { name = "Crate " .. i, metres = i }
        moves[i] = { container = i, item = "Wood", count = i }
    end
    local text = push.describe(moves, containers, facts)
    local lines = select(2, text:gsub("\n", "")) + 1
    t.eq(lines, 6, "five containers and the line that counts the rest")
    t.ok(text:sub(-8) == "\n+3 more", text)
    t.ok(text:find("Crate 5", 1, true) and not text:find("Crate 6", 1, true), text)
end)

t.test("storages and benches are told apart", function()
    t.eq(push.class("Storage_Metal_Cupboard", false), "storage")
    t.eq(push.class("Processor_T3", true), "storage", "a deployable container actor is a storage whatever its kind")
    t.eq(push.class("Processor", false), "bench")
    t.eq(push.class("Firepit", false), "bench")
    t.eq(push.class("Pouch_Generic", false), "storage")
    t.eq(push.class("Container_Small", false), "storage")
end)

t.test("the where setting, then the kinds the player unticked", function()
    local W = push.WHERE
    t.eq(#W, 3)
    t.ok(push.allowed(W[1], "storage", "Storage_Wood_Crate", nil))
    t.ok(push.allowed(W[1], "bench", "Cooking_Station", nil))
    t.ok(push.allowed(W[2], "storage", "Storage_Wood_Crate", nil))
    t.ok(not push.allowed(W[2], "bench", "Cooking_Station", nil))
    t.ok(not push.allowed(W[3], "storage", "Storage_Wood_Crate", nil))
    t.ok(push.allowed(W[3], "bench", "Cooking_Station", nil))
    t.ok(not push.allowed(W[1], "bench", "Cooking_Station", { cooking_station = true }), "unticked")
    t.ok(push.allowed(W[1], "bench", "Cooking_Station", { storage_wood_crate = true }), "another kind unticked")
    t.ok(not push.allowed(W[3], "bench", "Cooking_Station", { cooking_station = true }))
    t.ok(push.allowed("something else", "bench", "x", {}), "an unknown choice stashes everywhere")
end)

t.test("why nothing moved", function()
    local W = push.WHERE
    local carried = { { Item = "Wood", Count = 5 }, { Item = "Fiber", Count = 1 }, { Item = "Stone", Count = 2 }, { Item = "Stone_Pickaxe", Count = 1 } }
    local some = { { name = "Crate" } }
    t.eq(push.unmatched(carried, some, facts, 30, W[1]), "No container within 30 m holds Wood, Fiber or Stone.")
    t.eq(push.unmatched(carried, some, facts, 30, W[2]), "No storage within 30 m holds Wood, Fiber or Stone.")
    t.eq(push.unmatched(carried, some, facts, 45, W[3]), "No crafting station within 45 m holds Wood, Fiber or Stone.")
    t.eq(push.unmatched(carried, {}, facts, 30, W[1]), "No container within 30 m holds anything.")
    t.eq(push.unmatched({ { Item = "Wood", Count = 5 } }, some, facts, 30, W[1]), "No container within 30 m holds Wood.")
    t.eq(push.unmatched({ { Item = "Stone_Pickaxe", Count = 1 } }, some, facts, 30, W[1]), "Nothing in your backpack to stash.")
    local many = {}
    for i = 1, 7 do many[i] = { Item = "Wood" .. i, Count = 1 } end
    local text = push.unmatched(many, some, function() return { MaxStack = 10 } end, 30, W[1])
    t.ok(text:find("(and 2 more)", 1, true), text)
end)

t.finish("quickstash")
