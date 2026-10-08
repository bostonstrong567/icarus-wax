-- Inventories and the item tables as the game hands them to Lua, on top of fake_world.lua, fake_values.lua and fake_tables.lua.
-- The contents are what was read in the running game on 2026-10-07 (.research\easy-api\notes.md 2.4 and probe-results.md 2.5).
-- An engine list is read by index inside its length: one past the end makes it one longer and is counted in `grown`, and
-- ForEach is counted in `misuse`. What a read hands out is good for its frame: used in a later one it raises and is
-- counted in `stale`. A freed inventory raises on any use, as every object of fake_world does. `reads` counts every
-- value asked of an inventory's own structs and lists.
--   local items = dofile("wax/tests/offline/fake_items.lua")
--   items.install(world, values, tables, kit)      after world.install(), values.install(world) and world.icarus(values)
--   local me = items.player()                      kit.player() with its six inventories
--   me.backpack, me.hotbar, me.equipment, me.suit, me.upgrades, me.vision     each { object, store, slots, name }
--   items.put(me.backpack, 5, "Stone", 6)   items.tool(me.hotbar, 3, "Stone_Pickaxe", 20000)   items.take(me.backpack, 5)
--   items.set(me.hotbar, 3, items.DURABILITY, 19000)   items.resize(me.backpack, 30)
--   items.settle(me)                               the game's next tick: every weight follows what is held
--   items.next_frame()                             a new frame, for this file and for fake_tables

local items = { frame = 0, STACK = 7, DURABILITY = 6, TRANSMUTABLE = 9 }
---@type any
local world, values, tables, kit = nil, nil, nil, nil
local by_object = setmetatable({}, { __mode = "k" })
local serial = 0

local COUNTERS = { "reads", "stale", "grown", "misuse" }

-- Every counter back to zero. Inventories and tables stay.
function items.reset()
    for _, name in ipairs(COUNTERS) do items[name] = 0 end
end
items.reset()

local ICONS = "/Game/Assets/2DArt/UI/Items/Item_Icons/"
-- D_Itemable: row, shown name, grams, largest stack, icon, description
items.ITEMABLE = {
    { "Item_Wood", "Wood", 150, 100, ICONS .. "Resources/ITEM_Wood.ITEM_Wood", "Roughly cut wooden timber, ready for the crafting bench." },
    { "Item_Fiber", "Fiber", 10, 200, ICONS .. "Resources/ITEM_Fibre.ITEM_Fibre", "A bundle of soft fiber, highly useful." },
    { "Item_Stick", "Stick", 10, 100, ICONS .. "Resources/ITEM_Stick.ITEM_Stick", "" },
    { "Item_Stone", "Stone", 300, 100 },
    { "Item_WildTea", "Wild Tea", 50, 100 },
    { "Item_Berry", "Berry", 20, 50 },
    { "Item_Bone", "Bone", 100, 100 },
    { "Item_Stone_Pickaxe", "Stone Pickaxe", 500, 1, ICONS .. "Tools/ITEM_Stone_Pickaxe.ITEM_Stone_Pickaxe", "Break rocks with stone." },
    { "Item_Metal_Pickaxe", "Iron Pickaxe", 1500, 1 },
    { "Item_Metal_Ore", "Iron Ore", 1000, 100 },
    { "Item_Refined_Metal", "Iron Ingot", 500, 100 },
    { "Item_Player_Fist", "Fists", 10, 1 },
    { "Item_EnviroSuit", "Envirosuit", 100, 1 },
    { "Item_Skin_Head_Male_03", "", 0, 1 },
    { "Item_Spacesuit_Cap_Male", "Cap", 0, 1 },
}
-- D_ItemsStatic: row as the engine spells it, its row of D_Itemable, its row of D_Durable.
-- The game's own files spell "bone" with a capital, and one handle in another letter case than the row it names.
items.STATIC = {
    { "Wood", "Item_Wood" }, { "Fiber", "Item_Fiber" }, { "Stick", "Item_Stick" }, { "Stone", "Item_Stone" },
    { "WildTea", "Item_WildTea" }, { "Berry", "item_berry" }, { "bone", "Item_Bone" },
    { "Stone_Pickaxe", "Item_Stone_Pickaxe", "Stone_Pickaxe" }, { "Metal_Pickaxe", "Item_Metal_Pickaxe", "Metal_Pickaxe" },
    { "Metal_Ore", "Item_Metal_Ore" }, { "Refined_Metal", "Item_Refined_Metal" }, { "Player_Fist", "Item_Player_Fist" },
    { "EnviroSuit", "Item_EnviroSuit" }, { "Skin_Head_Male_03", "Item_Skin_Head_Male_03" },
    { "Spacesuit_Cap_Male", "Item_Spacesuit_Cap_Male" }, { "Dev_Marker" },
}
items.DURABLE = { { "Stone_Pickaxe", 20000 }, { "Metal_Pickaxe", 60000 } }

local grams = {}        -- item name in lower case -> what one weighs
do
    local by_row = {}
    for _, row in ipairs(items.ITEMABLE) do by_row[row[1]:lower()] = row[3] end
    for _, row in ipairs(items.STATIC) do grams[row[1]:lower()] = row[2] and by_row[row[2]:lower()] or 0 end
end

local function unknown(what, key)
    items.misuse = items.misuse + 1
    error(("MISUSE: %s was asked for %s"):format(what, tostring(key)), 3)
end

-- Something a read handed out. `lasting` is a struct that is part of its object: good for as long as the object lives.
local function handed(owner, what, read, lasting, length)
    local made = items.frame
    local function check(key)
        if rawget(owner, "__freed") then
            world.dead_touches = world.dead_touches + 1
            if world.dead_touches == 1 then world.dead_where = what .. "." .. tostring(key) .. debug.traceback("", 3) end
            error("touched a freed object (" .. what .. "." .. tostring(key) .. ")", 3)
        end
        if not lasting and made ~= items.frame then
            items.stale = items.stale + 1
            error(("STALE: %s was used after its frame (%s)"):format(what, tostring(key)), 3)
        end
        items.reads = items.reads + 1
    end
    return setmetatable({ __props = {} }, {
        __index = function(_, key)
            check(key)
            return read(key)
        end,
        __newindex = function(_, key)
            items.misuse = items.misuse + 1
            error(("MISUSE: %s.%s was written"):format(what, tostring(key)), 2)
        end,
        __len = length and function()
            check("#")
            return length()
        end or nil,
    })
end

local function handle(owner, what, row, table_name, lasting)
    return handed(owner, what, function(key)
        if key == "RowName" then return values.name(row) end
        if key == "DataTableName" then return values.name(table_name) end
        return unknown(what, key)
    end, lasting)
end

local function list_of(owner, what, list, element, blank)
    local function length() return #list end
    return handed(owner, what, function(key)
        if key == "GetArrayNum" then return length end
        if key == "ForEach" then
            items.misuse = items.misuse + 1
            error(("MISUSE: %s:ForEach was used, which UE4SS's own source says crashes on large lists. Read by index inside the length")
                :format(what), 3)
        end
        if math.type(key) ~= "integer" then return unknown(what, key) end
        if key == #list + 1 then
            -- as in the game: reading one past the end makes the list one longer
            items.grown = items.grown + 1
            list[key] = blank()
        elseif key < 1 or key > #list then
            items.misuse = items.misuse + 1
            error(("MISUSE: %s[%d] is out of range (it has %d)"):format(what, key, #list), 3)
        end
        return element(key)
    end, false, length)
end

local function pair_value(owner, pair, what)
    return handed(owner, what, function(key)
        if key == "PropertyType" then
            -- as UE4SS does on every read of an enum property
            rawset(_G, "Enum_PropertyType", { ["EDynamicItemProperties::ItemableStack"] = items.STACK })
            return pair[1]
        end
        if key == "Value" then return pair[2] end
        return unknown(what, key)
    end)
end

local function item_value(owner, slot, what)
    return handed(owner, what, function(key)
        if key == "ItemStaticData" then return handle(owner, what .. ".ItemStaticData", slot.item or "None", "D_ItemsStatic") end
        if key == "ItemDynamicData" then
            local here = what .. ".ItemDynamicData"
            return list_of(owner, here, slot.pairs, function(i) return pair_value(owner, slot.pairs[i], here .. "[" .. i .. "]") end,
                function() return { 0, 0 } end)
        end
        if key == "ItemCustomStats" then
            return list_of(owner, what .. ".ItemCustomStats", slot.stats, function() return {} end, function() return {} end)
        end
        if key == "bIsItemInstance" then return slot.item ~= nil end
        if key == "DatabaseGUID" then return world.string("") end
        return unknown(what, key)
    end)
end

local function slot_value(inv, position)
    local owner, slot = inv.object, inv.slots[position]
    local what = inv.name .. ".Slots.Slots[" .. position .. "]"
    return handed(owner, what, function(key)
        if key == "ItemData" then return item_value(owner, slot, what .. ".ItemData") end
        if key == "Index" then return slot.index end
        if key == "Locked" then return false end
        if key == "Slotable" then return true end
        if key == "LastItem" then return handle(owner, what .. ".LastItem", slot.last or "None", "D_ItemsStatic") end
        if key == "Query" then return handle(owner, what .. ".Query", "None", "D_TagQueries") end
        return unknown(what, key)
    end)
end

local function empty_slot(inv) return { pairs = {}, stats = {}, index = #inv.slots } end

-- An inventory that belongs to nothing yet. `kind` is its row of D_InventoryInfo.
function items.inventory(kind, size, name)
    serial = serial + 1
    name = name or ("Inventory_" .. (2147454590 + serial))
    local object, store = values.part(kit.classes.Inventory, name, { CurrentWeight = 0 })
    local inv = { object = object, store = store, slots = {}, kind = kind, name = name }
    for _ = 1, size do inv.slots[#inv.slots + 1] = empty_slot(inv) end
    store.Slots = handed(object, name .. ".Slots", function(key)
        if key ~= "Slots" then return unknown(name .. ".Slots", key) end
        return list_of(object, name .. ".Slots.Slots", inv.slots, function(position) return slot_value(inv, position) end,
            function() return empty_slot(inv) end)
    end, true)
    store.InventoryInfoRowHandle = handle(object, name .. ".InventoryInfoRowHandle", kind, "D_InventoryInfo", true)
    by_object[object] = inv
    return inv
end

-- The inventory an engine object stands for, as items.inventory made it. For fake_actions.
function items.of(object) return by_object[object] end

-- Makes an inventory a component of a character (one of kit's), kept in this property of it.
function items.attach(who, property, inv)
    who.store[property] = inv.object
    rawset(inv.object, "__outer", who.actor)
    local parts = rawget(who.actor, "__components")
    parts[#parts + 1] = inv.object
    who.inventories = who.inventories or {}
    who.inventories[#who.inventories + 1] = inv
    return inv
end

local function slot_of(inv, position)
    return inv.slots[position] or error(("fake_items: %s has no slot %s"):format(inv.name, tostring(position)), 3)
end

local ZEROS = { 0, 1, 5, 4, 2, 3 }     -- the six numbers the game gives many stacks, all 0

-- Puts a stack in a slot (counted from 1). `count` false is an item with no stack number, as a skin has. `more` is a list
-- of { number, value } after the stack, `zeros` puts the six numbers at 0 in front.
function items.put(inv, position, item, count, more, zeros)
    local slot = slot_of(inv, position)
    slot.item, slot.pairs = item, {}
    if zeros then
        for _, number in ipairs(ZEROS) do slot.pairs[#slot.pairs + 1] = { number, 0 } end
    end
    if count ~= false then slot.pairs[#slot.pairs + 1] = { items.STACK, count or 1 } end
    for _, pair in ipairs(more or {}) do slot.pairs[#slot.pairs + 1] = { pair[1], pair[2] } end
end

-- A tool as the game makes one from a bare item: six numbers at 0, a stack of one, its durability.
function items.tool(inv, position, item, durability)
    items.put(inv, position, item, 1, { { items.DURABILITY, durability } }, true)
end

-- Empties a slot. It remembers what it held, as the game's slots do.
function items.take(inv, position)
    local slot = slot_of(inv, position)
    slot.last, slot.item, slot.pairs = slot.item, nil, {}
end

-- One number of a stack: changed where it is, or added.
function items.set(inv, position, number, value)
    local slot = slot_of(inv, position)
    for _, pair in ipairs(slot.pairs) do
        if pair[1] == number then
            pair[2] = value
            return
        end
    end
    slot.pairs[#slot.pairs + 1] = { number, value }
end

-- More slots, or fewer.
function items.resize(inv, size)
    for position = #inv.slots, size + 1, -1 do inv.slots[position] = nil end
    for _ = #inv.slots + 1, size do inv.slots[#inv.slots + 1] = empty_slot(inv) end
end

local function weigh(inv)
    local total = 0
    for _, slot in ipairs(inv.slots) do
        if slot.item then
            local stack = 1
            for _, pair in ipairs(slot.pairs) do
                if pair[1] == items.STACK then stack = pair[2] end
            end
            total = total + (grams[slot.item:lower()] or 0) * stack
        end
    end
    inv.store.CurrentWeight = total
    return total
end

-- The game's next tick: an inventory's weight follows what it holds, and a character's weight is all of its inventories'.
function items.settle(target)
    if not target.inventories then return weigh(target) end
    local total = 0
    for _, inv in ipairs(target.inventories) do total = total + weigh(inv) end
    target.store.CurrentWeight = total
    return total
end

-- The player's character in a prospect with what it carried when it was read: `over` as kit.player takes it.
function items.player(over)
    local who = kit.player(over)
    who.backpack = items.attach(who, "BackpackInventory", items.inventory("Backpack", 24))
    who.hotbar = items.attach(who, "QuickbarInventory", items.inventory("Quickbar", 12))
    who.equipment = items.attach(who, "EquipmentInventory", items.inventory("Equipment", 10))
    who.suit = items.attach(who, "EnvirosuitInventory", items.inventory("Suit", 1))
    who.upgrades = items.attach(who, "UpgradeInventory", items.inventory("UpgradeSlots", 0))
    who.vision = items.attach(who, "VisionInventory", items.inventory("VisionSlot", 1))
    items.put(who.backpack, 1, "Fiber", 64, { { items.TRANSMUTABLE, 5000 } })
    items.put(who.backpack, 2, "Stick", 12, { { items.TRANSMUTABLE, 10000 } }, true)
    items.put(who.backpack, 3, "WildTea", 3)
    items.put(who.backpack, 4, "Wood", 1, { { items.TRANSMUTABLE, 150000 } })
    items.put(who.hotbar, 12, "Player_Fist", 1, nil, true)
    items.put(who.equipment, 6, "EnviroSuit", 1)
    items.put(who.equipment, 7, "Skin_Head_Male_03", false)
    items.put(who.equipment, 8, "Spacesuit_Cap_Male", false)
    items.settle(who)
    return who
end

-- Every value asked of the engine so far: of objects and of what inventories hand out.
function items.asked() return world.touches + items.reads end

function items.next_frame()
    items.frame = items.frame + 1
    tables.next_frame()
end

-- Call once, after world.install(), values.install(world) and world.icarus(values). It declares the inventory class and
-- the members that keep a character's inventories, puts the three item tables into fake_tables, and makes the engine's
-- global functions answer for both stand-ins.
function items.install(the_world, the_values, the_tables, the_kit)
    world, values, tables, kit = the_world, the_values, the_tables, the_kit
    local classes = kit.classes
    local S, U = "/Script/Icarus.", "/Script/IcarusUtilities."
    local INT, BOOL, OBJECT = "IntProperty", "BoolProperty", "ObjectProperty"

    local function stacks(self)
        local total = 0
        for _, slot in ipairs(by_object[self].slots) do
            if slot.item then
                local stack = 1
                for _, pair in ipairs(slot.pairs) do
                    if pair[1] == items.STACK then stack = pair[2] end
                end
                total = total + stack
            end
        end
        return total
    end

    classes.TraitBehaviour = values.class(S .. "TraitBehaviour", classes.ActorComponent)
    -- with some of the game's own functions, whose names Wax must leave alone
    classes.Inventory = values.class(S .. "Inventory", classes.TraitBehaviour, {
        CurrentWeight = INT, Slots = { "StructProperty", struct = S .. "InventorySlotsFastArray" },
        InventoryInfoRowHandle = { "StructProperty", struct = S .. "InventoryInfoRowHandle" },
        InitialItems = { "ArrayProperty", inner = "StructProperty", struct = S .. "ItemData" },
    }, {
        GetItemCount = { returns = INT, call = stacks },
        HasItems = { returns = BOOL, call = function(self) return stacks(self) > 0 end },
        Find = { { "ItemToFind", "StructProperty", struct = S .. "ItemData" }, { "Amount", INT }, returns = INT,
            call = function() return -1 end },
        GetItems = { { "Query", "StructProperty", struct = "/Script/GameplayTags.GameplayTagQuery" } },
        Empty = { call = function(self)
            items.misuse = items.misuse + 1
            error("MISUSE: " .. rawget(self, "__name") .. ":Empty() was called: that throws the player's items away", 0)
        end },
    })

    local function add(class_name, members)
        local held = rawget(classes[class_name], "__members")
        for name, spec in pairs(members) do held[name] = spec end
    end
    add("IcarusPlayerCharacter", { EquipmentInventory = OBJECT, InventoryComponent = OBJECT })
    add("IcarusPlayerCharacterSurvival", { BackpackInventory = OBJECT, QuickbarInventory = OBJECT, EnvirosuitInventory = OBJECT,
        UpgradeInventory = OBJECT, VisionInventory = OBJECT })
    add("IcarusPlayerCharacterSpace", { MainInventory = OBJECT })
    -- some creature classes of the game keep an inventory under this name
    add("BP_NPC_Wolf_Conifer_Character_C", { Inventory = OBJECT })

    local table_paths = {}
    local function struct(path, super, fields, options)
        table_paths[path] = true
        return tables.struct(path, super, fields, options)
    end
    struct("/Script/Engine.TableRowBase", nil, {}, { lead = 8 })
    struct(U .. "IcarusTableRowBase", "/Script/Engine.TableRowBase",
        { { "CachedHardReferences", "ArrayProperty", inner = "ObjectProperty" } })
    struct(U .. "RowHandle", nil,
        { { "DataTablePtr", "WeakObjectProperty" }, { "RowName", "NameProperty" }, { "DataTableName", "NameProperty" } })
    struct(S .. "ItemableRowHandle", U .. "RowHandle", {})
    struct(S .. "DurableRowHandle", U .. "RowHandle", {})
    struct(S .. "ItemStaticData", U .. "IcarusTableRowBase", {
        { "Itemable", "StructProperty", struct = S .. "ItemableRowHandle" },
        { "Durable", "StructProperty", struct = S .. "DurableRowHandle" },
        { "CraftingExperience", "IntProperty" }, { "AdditionalStats", "MapProperty" },
    })
    struct(S .. "ItemableData", U .. "IcarusTableRowBase", {
        { "Behaviour", "SoftClassProperty" }, { "DisplayName", "TextProperty" }, { "Icon", "SoftObjectProperty" },
        { "Description", "TextProperty" }, { "FlavorText", "TextProperty" }, { "Weight", "IntProperty" },
        { "bAllowZeroWeight", "BoolProperty" }, { "MaxStack", "IntProperty" },
    })
    struct(S .. "DurableData", U .. "IcarusTableRowBase", { { "Max_Durability", "IntProperty" }, { "Destroyed_At_Zero", "BoolProperty" } })

    local rows, order = {}, {}
    for i, row in ipairs(items.STATIC) do
        rows[row[1]] = {
            Itemable = row[2] and { RowName = row[2], DataTableName = "D_Itemable" } or nil,
            Durable = row[3] and { RowName = row[3], DataTableName = "D_Durable" } or nil,
        }
        order[i] = row[1]
    end
    tables.table("ItemsStatic", S .. "ItemStaticData", rows, order)
    rows, order = {}, {}
    for i, row in ipairs(items.ITEMABLE) do
        rows[row[1]] = { DisplayName = row[2], Weight = row[3], MaxStack = row[4], Icon = row[5], Description = row[6] }
        order[i] = row[1]
    end
    tables.table("Itemable", S .. "ItemableData", rows, order)
    rows, order = {}, {}
    for i, row in ipairs(items.DURABLE) do
        rows[row[1]] = { Max_Durability = row[2] }
        order[i] = row[1]
    end
    tables.table("Durable", S .. "DurableData", rows, order)

    local world_find, world_all, name, text = StaticFindObject, FindAllOf, FName, FText
    tables.install()
    local table_find, table_all = StaticFindObject, FindAllOf
    rawset(_G, "FName", name)
    rawset(_G, "FText", text)
    rawset(_G, "StaticFindObject", function(path)
        if table_paths[path] or (type(path) == "string" and path:find("^/Engine/Transient%.D_")) then return table_find(path) end
        return world_find(path)
    end)
    rawset(_G, "FindAllOf", function(class_name)
        if class_name == "IcarusDataTable" then return table_all(class_name) end
        return world_all(class_name)
    end)
end

return items
