-- The station-centred list the crafting hooks feed the game: tools\lua\lua54\lua.exe wax\tests\offline\quickstash_nearby_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local DIR = (arg and arg[1]) or "luamods/QuickStash/"
local nearby = dofile(DIR .. "nearby.lua")

local function at(x) return { X = x * 100, Y = 0, Z = 0 } end
local ME, OTHER = 1001, 1002       -- two players' states
local records = {
    { addr = 1, owner_addr = 10, at = at(2), kind = "bench" },               -- the station itself, excluded
    { addr = 2, owner_addr = 20, at = at(5), kind = "storage" },
    { addr = 3, owner_addr = 30, at = at(3), kind = "bench" },
    { addr = 4, owner_addr = 40, at = at(1), kind = "character" },           -- another player's backpack: never
    { addr = 5, owner_addr = 50, at = at(4), kind = "cargo", owner_state = ME },
    { addr = 6, owner_addr = 60, at = at(2), kind = "cargo", owner_state = OTHER },
    { addr = 7, owner_addr = 70, at = at(40), kind = "storage" },            -- too far
    { addr = 8, owner_addr = 80, at = at(9), kind = "storage" },
}

t.test("around the station: storages first by distance, then benches, then the crafting player's own cargo", function()
    local list = nearby.for_station(records, at(2), 10, ME, 30)
    local order = {}
    for _, record in ipairs(list) do order[#order + 1] = record.addr end
    t.eq(table.concat(order, " "), "2 8 3 5")
    t.ok(list[1].storage and not list[3].storage)
end)

t.test("another player's animal and any character are never in it, nor the station's own inventory", function()
    local list = nearby.for_station(records, at(2), 10, OTHER, 30)
    local order = {}
    for _, record in ipairs(list) do order[#order + 1] = record.addr end
    t.eq(table.concat(order, " "), "2 8 3 6")
    local none = nearby.for_station(records, at(2), 10, nil, 30)
    order = {}
    for _, record in ipairs(none) do order[#order + 1] = record.addr end
    t.eq(table.concat(order, " "), "2 8 3", "no player state: no animals at all")
end)

t.test("the list is cut to the most the game's checks take", function()
    t.eq(#nearby.for_station(records, at(2), 10, ME, 30, 2), 2)
    t.eq(#nearby.for_station(records, nil, 10, ME, 30), 0, "no place to measure from")
end)

t.finish("quickstash-nearby")
