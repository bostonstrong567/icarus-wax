-- Even sharing over stations (game.Items:Share): tools\lua\lua54\lua.exe wax\tests\offline\share_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local share = assert(loadfile("wax/runtime/Scripts/wax/world/share.lua"))({})

local function facts(item)
    if item:lower() == "iron_ore" then return { MaxStack = 50 } end
    return { MaxStack = 100 }
end
local function station(stacks, size, used)
    return { stacks = stacks, size = size, used = used }
end

t.test("room counts the stacks' spare and the free slots", function()
    local room, held = share.room(station({ { Item = "Iron_Ore", Count = 30 } }, 4, 1), "Iron_Ore", facts)
    t.eq(room, 20 + 3 * 50)
    t.eq(held, 30)
    t.eq(share.room(station({}, 2, 2), "Iron_Ore", facts), 0, "a full station has no room")
end)

t.test("an even split over empty stations", function()
    local given, left = share.spread(90, "Iron_Ore", { station({}, 4, 0), station({}, 4, 0), station({}, 4, 0) }, facts)
    t.eq(given[1], 30)
    t.eq(given[2], 30)
    t.eq(given[3], 30)
    t.eq(left, 0)
end)

t.test("the remainder goes to the nearest", function()
    local given = share.spread(10, "Iron_Ore", { station({}, 4, 0), station({}, 4, 0), station({}, 4, 0) }, facts)
    t.eq(given[1], 4)
    t.eq(given[2], 3)
    t.eq(given[3], 3)
end)

t.test("a station that holds more waits for the others to catch up", function()
    local given = share.spread(40, "Iron_Ore", { station({ { Item = "Iron_Ore", Count = 30 } }, 4, 1), station({}, 4, 0), station({}, 4, 0) }, facts)
    t.eq(given[1], nil, "it already holds more than its share")
    t.eq(given[2], 20)
    t.eq(given[3], 20)
    local more = share.spread(120, "Iron_Ore", { station({ { Item = "Iron_Ore", Count = 30 } }, 4, 1), station({}, 4, 0), station({}, 4, 0) }, facts)
    t.eq(more[1], 20, "once the others reach 30, all three go on together")
    t.eq(more[2], 50)
    t.eq(more[3], 50)
end)

t.test("uneven room: a nearly full station takes what it can, the rest goes on", function()
    local given, left = share.spread(100, "Iron_Ore", { station({}, 1, 0), station({}, 4, 0) }, facts)
    t.eq(given[1], 50)
    t.eq(given[2], 50)
    t.eq(left, 0)
    local more, over = share.spread(300, "Iron_Ore", { station({}, 1, 0), station({}, 4, 0) }, facts)
    t.eq(more[1], 50)
    t.eq(more[2], 200)
    t.eq(over, 50, "what no station had room for")
end)

t.test("one full station is skipped, and stations that do not accept the item too", function()
    local full = station({ { Item = "Iron_Ore", Count = 50 } }, 1, 1)
    local other = station({}, 2, 0)
    other.accepts = function(item) return item ~= "Iron_Ore" end
    local open = station({}, 2, 0)
    local given, left = share.spread(60, "Iron_Ore", { full, other, open }, facts)
    t.eq(given[1], nil)
    t.eq(given[2], nil)
    t.eq(given[3], 60)
    t.eq(left, 0)
end)

t.test("nothing to give, and nowhere to put it", function()
    local given, left = share.spread(0, "Iron_Ore", { station({}, 2, 0) }, facts)
    t.eq(next(given), nil)
    t.eq(left, 0)
    local none, rest = share.spread(25, "Iron_Ore", {}, facts)
    t.eq(next(none), nil)
    t.eq(rest, 25)
end)

t.finish("share")
