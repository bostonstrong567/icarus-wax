-- The station-centred list the crafting hooks draw on: tools\lua\lua54\lua.exe wax\tests\offline\quickstash_nearby_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local DIR = (arg and arg[1]) or "luamods/QuickStash/"
local nearby = dofile(DIR .. "nearby.lua")

local function actor(address) return { Raw = { GetAddress = function() return address end } } end
local function inv(name, used) return { Name = name, Used = used } end
local records = {
    { Kind = "station", Distance = 0, Row = "Kit_Stone_Furnace", Actor = actor(10), Inventories = {}, Inputs = inv("own", 3) },
    { Kind = "storage", Distance = 5, Row = "Storage_Crate", Actor = actor(20), Inventories = { inv("crate", 8) }, Inputs = nil },
    { Kind = "station", Distance = 3, Row = "Crafting_Bench", Actor = actor(30), Inventories = {}, Inputs = inv("bench", 5) },
    { Kind = "cargo", Distance = 4, Row = "cargo:Mount_Moa", Actor = actor(50), Inventories = { inv("moa", 3) }, Inputs = nil },
    { Kind = "storage", Distance = 9, Row = "Storage_Cupboard", Actor = actor(80), Inventories = { inv("cupboard", 2), inv("empty", 0) }, Inputs = nil },
    { Kind = "storage", Distance = 2, Row = "Storage_Box", Actor = actor(90), Inventories = { inv("box", 1) }, Inputs = nil },
}

local function names(list)
    local out = {}
    for _, entry in ipairs(list) do out[#out + 1] = entry.inventory.Name end
    return table.concat(out, " ")
end

t.test("storages first by distance, then other stations' inputs; never the station's own, nor animals while they are off", function()
    local list = nearby.from_records(records, 10, {}, 24, false)
    t.eq(names(list), "box crate cupboard bench")
    t.ok(list[1].storage and not list[4].storage)
    t.eq(list[4].metres, 3)
end)

t.test("an unticked kind is left out, an empty inventory too, and animals count when they are on", function()
    t.eq(names(nearby.from_records(records, 10, { storage_crate = true }, 24, false)), "box cupboard bench")
    t.eq(names(nearby.from_records(records, 10, {}, 24, true)), "box moa crate cupboard bench")
end)

t.test("the list is cut to the most the checks take", function()
    t.eq(#nearby.from_records(records, 10, {}, 2, false), 2)
    t.eq(#nearby.from_records(nil, 10, {}, 2, false), 0)
end)

t.finish("quickstash-nearby")
