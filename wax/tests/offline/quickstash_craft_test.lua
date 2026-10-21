-- Quick Stash's crafting sums: tools\lua\lua54\lua.exe wax\tests\offline\quickstash_craft_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local DIR = (arg and arg[1]) or "luamods/QuickStash/"
local craft = dofile(DIR .. "craft.lua")

local inputs = { { item = "Wood", count = 20 }, { item = "Fiber", count = 3 }, { item = "wood", count = 5 } }

t.test("what a number of crafts needs, by item, the same item added up", function()
    local need = craft.need(inputs, 3)
    t.eq(need.wood.count, 75)
    t.eq(need.fiber.count, 9)
    t.eq(need.wood.item, "Wood")
    t.eq(next(craft.need({}, 2)), nil)
    t.eq(craft.need(inputs, 0).wood.count, 25, "at least one craft")
end)

t.test("how many crafts the counts allow is the least input", function()
    local have = function(_, key) return ({ wood = 100, fiber = 7 })[key] end
    t.eq(craft.max_crafts(inputs, have), 2, "7 fiber allows 2, 100 wood allows 4")
    t.eq(craft.max_crafts(inputs, function() return 0 end), 0)
    t.eq(craft.max_crafts({}, have), nil, "no item inputs: nothing to say")
end)

t.test("what the backpack is short of, in the inputs' order", function()
    local have = function(_, key) return ({ wood = 30, fiber = 10 })[key] end
    local short = craft.missing(inputs, 2, have)
    t.eq(#short, 1)
    t.eq(short[1].item, "Wood")
    t.eq(short[1].count, 20, "50 needed, 30 held")
    t.eq(#craft.missing(inputs, 1, have), 0, "one craft is covered")
end)

t.test("the game's check is satisfied when what was counted plus what is nearby reaches the need", function()
    local ok, need = craft.satisfied(20, 2, 15, 30)
    t.ok(ok)
    t.eq(need, 40)
    t.ok(not craft.satisfied(20, 2, 15, 20))
    t.ok(craft.satisfied(3, 1, 0, 3))
end)

t.test("a moved stack goes to a stack of its own kind with room, else the first empty slot", function()
    local stacks = { { Item = "Wood", Count = 90, Slot = 1 }, { Item = "Stone", Count = 10, Slot = 2 }, { Item = "wood", Count = 100, Slot = 4 } }
    local slot, room = craft.destination(stacks, 6, "Wood", 100)
    t.eq(slot, 1, "the fuller stack with room")
    t.eq(room, 10)
    slot, room = craft.destination(stacks, 6, "Fiber", 200)
    t.eq(slot, 3, "the first empty slot")
    t.eq(room, 200)
    t.eq(craft.destination({ { Item = "A", Count = 1, Slot = 1 }, { Item = "B", Count = 1, Slot = 2 } }, 2, "Fiber", 200), nil, "no room at all")
end)

t.test("the moves bring the shortfall in from the nearest source, stack by stack, into fitting slots", function()
    local sources = {
        { name = "Far crate", metres = 9, stacks = { { Item = "Wood", Count = 100, Slot = 1 } } },
        { name = "Near bench", metres = 3, stacks = { { Item = "Fiber", Count = 50, Slot = 1 }, { Item = "Wood", Count = 15, Slot = 2 } } },
    }
    local backpack = { size = 3, stacks = { { Item = "Wood", Count = 95, Slot = 1 }, { Item = "Stone", Count = 1, Slot = 2 } } }
    local moves = craft.moves(40, "Wood", sources, backpack, 100)
    t.eq(#moves, 3)
    t.eq(moves[1].source, 2, "the near bench first")
    t.eq(moves[1].count, 5, "tops the backpack's stack up to 100")
    t.eq(moves[1].to_slot, 1)
    t.eq(moves[2].source, 2)
    t.eq(moves[2].count, 10, "the rest of the bench's stack into the empty slot")
    t.eq(moves[2].to_slot, 3)
    t.eq(moves[3].source, 1)
    t.eq(moves[3].count, 25, "the last 25 out of the far crate, into the same new stack")
    t.eq(moves[3].to_slot, 3)
    t.eq(#craft.moves(0, "Wood", sources, backpack, 100), 0)
    local full = { size = 2, stacks = { { Item = "A", Count = 1, Slot = 1 }, { Item = "B", Count = 1, Slot = 2 } } }
    t.eq(#craft.moves(10, "Wood", sources, full, 100), 0, "a full backpack takes nothing")
end)

t.test("a thing is due once per gap", function()
    local last = {}
    t.ok(craft.due(last, "a", 10, 2))
    t.ok(not craft.due(last, "a", 11, 2))
    t.ok(craft.due(last, "b", 11, 2))
    t.ok(craft.due(last, "a", 12, 2))
end)

t.finish("quickstash-craft")
