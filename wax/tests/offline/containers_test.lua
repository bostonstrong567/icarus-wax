-- The structures around the player (game.Containers): tools\lua\lua54\lua.exe wax\tests\offline\containers_test.lua
-- The module runs against stand-ins for the engine: a tracked set it fills itself, and actors with inventories.
local t = dofile("wax/tests/offline/harness.lua")

local next_address = 100
local function object(fields)
    next_address = next_address + 1
    local self = fields or {}
    self.address = next_address
    function self:IsValid() return true end
    function self:GetAddress() return self.address end
    return self
end

local function handle(row) return { RowName = { ToString = function() return row end } } end

-- a UE4SS map of inventories
local function map(list)
    return { ForEach = function(_, fn) for _, inventory in ipairs(list) do fn(nil, { get = function() return inventory end }) end end }
end

local function inventory(kind, used, remove_only)
    local self = object({ Kind = kind, Used = used or 0, Size = 10 })
    self.Raw = { IsClientSideOnlyInventory = function() return false end, IsRemoveOnly = function() return remove_only == true end }
    function self:List() return {} end
    return self
end

-- an actor: with an inventory component (inventories) and maybe a processor (input inventory)
local function actor(row, at, inventories, inputs)
    local raw = object({ ItemData = { ItemStaticData = handle(row) } })
    local parts = {}
    if inventories then parts.InventoryComponent = object({ Inventories = map(inventories) }) end
    if inputs then parts.ProcessingComponent = object({ Inventory = inputs }) end
    function raw:GetComponentByClass(class) return parts[class.name] end
    raw.Position = at
    raw.Raw = raw       -- the stand-in is its own Instance
    return raw
end

local entries = {}
local tracked = { entries = entries, count = 0, Added = { Connect = function() end }, Removed = { Connect = function() end }, Cleared = { Connect = function() end } }
function tracked:use() return self end
local defined = nil
local modules = {
    ["engine.track"] = { define = function(_, spec) defined = spec return tracked end },
    ["engine.instance"] = { wrap = function(raw) return raw end },
    ["core.sched"] = { Signal = { new = function() return { Fire = function() end, Connect = function() end } end }, clock = function() return 0 end },
    ["core.co"] = { isyieldable = function() return true end },
    ["core.log"] = { channel = function() return { warn = function() end } end },
    ["world.character"] = { current = function() return { Position = { X = 0, Y = 0, Z = 0 } } end },
    ["engine.game"] = { root = { Items = { Get = function(_, row) return { DisplayName = ({ Kit_Stone_Furnace = "Stone Furnace", Storage_Metal_Cupboard = "Iron Cupboard" })[row] } end },
        Data = { Table = function(_, name)
            if name == "ItemsStatic" then return { Row = function(_, row) return row == "Kit_Stone_Furnace" and { Processing = { RowName = "Stone_Furnace" } } or { Processing = { RowName = "None" } } end } end
            if name == "Processing" then return { Row = function() return { DefaultRecipeSet = { RowName = "Stone_Furnace" } } end } end
            return { Load = function() return {
                Refined_Metal = { RecipeSets = { { RowName = "Stone_Furnace" } }, Inputs = { { Element = { RowName = "Metal_Ore" } } } },
                Aluminium = { RecipeSets = { { RowName = "Concrete_Furnace" } }, Inputs = { { Element = { RowName = "Aluminium_Ore" } } } },
            } end }
        end } } },
}
local Wax = { import = function(name) return assert(modules[name], name) end }
function StaticFindObject(path) return object({ name = path:match("([^.]+)$") }) end

local M = assert(loadfile("wax/runtime/Scripts/wax/world/containers.lua"))(Wax)
M.start()
local Containers = modules["engine.game"].root.Containers

local function listed(raw, kind)
    entries[#entries + 1] = { ready = true, destroyed = false, instance = raw, kind = kind:lower(), variant = kind }
end

t.test("only structures with an inventory or a processor are tracked, by their item row", function()
    local crate = actor("Storage_Metal_Cupboard", { X = 0, Y = 0, Z = 0 }, { inventory("Storage_Metal_Cupboard", 3) })
    t.eq(M.classify(crate, false), "storage_metal_cupboard")
    local door = actor("Wood_Door", { X = 0, Y = 0, Z = 0 })
    t.eq(M.classify(door, false), false, "a door has no inventory")
    local unknown = actor("None", { X = 0, Y = 0, Z = 0 }, { inventory("Storage_X", 0) })
    t.eq(M.classify(unknown, false), nil, "asked again while the row is not known yet")
    t.eq(M.classify(unknown, true), false, "and dropped when it never comes")
end)

t.test("kinds of inventory that take a stash", function()
    t.ok(M.takes("Storage_Metal_Cupboard"))
    t.ok(M.takes("Processor_T3"))
    t.ok(not M.takes("Fuel_Combustible"))
    t.ok(not M.takes("Player_Grave"))
    t.ok(not M.takes("Rain_Reservoir_Ice"))
    t.ok(M.is_fuel("Fuel_Combustible"))
end)

t.test("nearby, nearest first, with the inventories sorted into takes, fuel and inputs", function()
    listed(actor("Storage_Metal_Cupboard", { X = 900, Y = 0, Z = 0 }, { inventory("Storage_Metal_Cupboard", 3) }), "Storage_Metal_Cupboard")
    local inputs = inventory("Processor_T3", 2)
    listed(actor("Kit_Stone_Furnace", { X = 300, Y = 0, Z = 0 }, { inputs, inventory("Fuel_Combustible", 1) }, inputs), "Kit_Stone_Furnace")
    listed(actor("Kit_Stone_Furnace", { X = 5000, Y = 0, Z = 0 }, { inventory("Processor_T3", 0) }, inventory("Processor_T3", 0)), "Kit_Stone_Furnace")
    listed(actor("Player_Gravestone_DBNO", { X = 100, Y = 0, Z = 0 }, { inventory("Player_Grave", 0) }), "Player_Gravestone_DBNO")
    local found = Containers:Nearby(30)
    t.eq(#found, 2, "the far furnace and the grave are out")
    t.eq(found[1].Name, "Stone Furnace")
    t.eq(found[1].Kind, "station")
    t.eq(found[1].Distance, 3)
    t.eq(#found[1].Fuel, 1)
    t.eq(found[1].Inputs, inputs)
    t.eq(found[2].Name, "Iron Cupboard")
    t.eq(found[2].Kind, "storage")
    t.eq(#found[2].Inventories, 1)
    t.eq(#Containers:Nearby(30, { kind = "storage" }), 1)
    t.eq(#Containers:Nearby(100), 3)
    t.eq(#Containers:Nearby(100, { holding = true }), 2, "the far furnace holds nothing")
end)

t.test("kinds in range with their counts, by name", function()
    local kinds = Containers:Kinds(100)
    t.eq(#kinds, 2)
    t.eq(kinds[1].Name, "Iron Cupboard")
    t.eq(kinds[2].Name, "Stone Furnace")
    t.eq(kinds[2].Count, 2)
    t.eq(kinds[2].Kind, "station")
end)

t.test("what a station accepts comes from its recipe set", function()
    local accepted, set = Containers:Accepted("Kit_Stone_Furnace")
    t.eq(set, "Stone_Furnace")
    t.eq(accepted.metal_ore, "Metal_Ore")
    t.eq(accepted.aluminium_ore, nil)
    local none, why = Containers:Accepted("Storage_Metal_Cupboard")
    t.eq(none, nil)
    t.eq(why, "not a station")
    local found = Containers:Nearby(30)
    t.ok(found[1]:Accepts("Metal_Ore"))
    t.ok(not found[1]:Accepts("Aluminium_Ore"))
    t.ok(found[2]:Accepts("Anything"), "storage takes any item")
end)

t.test("inputs_of is pure", function()
    local rows = { a = { RecipeSets = { { RowName = "X" } }, Inputs = { { Element = { RowName = "Wood" } }, { Element = { RowName = "None" } } } } }
    local out = M.inputs_of("x", rows)
    t.eq(out.wood, "Wood")
    t.eq(next(out, "wood"), nil)
end)

t.finish("containers")
