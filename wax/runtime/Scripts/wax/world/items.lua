-- game.Items and inventories: what a kind of item is, and what an inventory or a player's character holds

local Wax = ...
local easy = Wax.import("engine.easy")
local instance = Wax.import("engine.instance")
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local suggest = Wax.import("core.suggest")
local perf = Wax.import("core.perf")
local co = Wax.import("core.co")
local log = Wax.import("core.log").channel("wax.items")

local M = {}

M.INVENTORY = "Inventory"
M.PLAYER = "IcarusPlayerCharacter"
M.PACE = 0.25       -- seconds between two looks at one inventory, however often it is asked
M.SWEEP = 2         -- seconds in which every slot is read again while an inventory keeps being asked. math.huge: only when told
M.KEEP = 60         -- seconds the copy of an inventory nobody asks about is kept
M.MANY = 32         -- with this many copies, the ones nobody asks about are dropped
M.SLICE = 250       -- shown names made ready a frame by Load
M.GRAMS = 1000      -- the game's weights are grams, and what is handed out is kilograms
M.STACK, M.DURABILITY = 7, 6        -- EDynamicItemProperties::ItemableStack and ::Durability

-- EDynamicItemProperties, by number
local PROPERTIES = {
    [0] = "AssociatedItemInventoryId", "AssociatedItemInventorySlot", "DynamicState", "GunCurrentMagSize", "CurrentAmmoType",
    "BuildingVariation", "Durability", "ItemableStack", "MillijoulesRemaining", "TransmutableUnits", "Fillable_StoredUnits",
    "Fillable_Type", "Decayable_CurrentSpoilTime", "InventoryContainer_LinkedInventoryId",
}
-- what a player's character carries: the field Wax gives, and the game's property that keeps the inventory
local CARRIED = {
    { name = "Backpack", property = "BackpackInventory" }, { name = "Hotbar", property = "QuickbarInventory" },
    { name = "Equipment", property = "EquipmentInventory" }, { name = "Suit", property = "EnvirosuitInventory" },
    { name = "Upgrades", property = "UpgradeInventory" }, { name = "Vision", property = "VisionInventory" },
}
local HOTBAR = 2
local LEFT_BEHIND = "Enum_PropertyType"     -- the global UE4SS makes each time a stack's kind of number is read
local STATIC, ITEMABLE, DURABLE = "ItemsStatic", "Itemable", "Durable"
local STATIC_FIELDS = { "Itemable.RowName", "Durable.RowName" }
local ITEMABLE_FIELDS = { "DisplayName", "Description", "Weight", "MaxStack", "Icon" }
local SHOWN_FIELDS = { "DisplayName" }
local DURABLE_FIELDS = { "Max_Durability" }
local OURS = { itemsstatic = true, itemable = true, durable = true }

local type, pcall, error, pairs, rawequal, tostring = type, pcall, error, pairs, rawequal, tostring
local lower, find, ceil = string.lower, string.find, math.ceil
local stats = sched.stats
local wrap = instance.wrap

local function clean(problem)
    local text = tostring(problem):match("^[^\r\n]*") or ""
    return (text:gsub("^.-%.lua:%d+: ", ""))
end

-- Names are compared without letter case, spaces, underscores or hyphens.
local function fold(text) return (lower(text):gsub("[%s_%-]", "")) end

-- A part of an actor, read from the live actor each time and never kept. Nil when it has none.
local function part(raw, name)
    local found = raw[name]
    if found ~= nil and found:IsValid() then return found end
    return nil
end

-- the game's item tables

local data = nil            -- game.Data, once something asked about a kind of item
local keys, key_count = {}, 0   -- a name as a mod wrote it -> the key its stacks are counted under, or false for no such item
local kept = {}             -- key -> the facts of that item
local index = nil           -- { names, folded, by }: every item name, each one folded, and folded -> name
local shown = nil           -- the shown name of each item, folded, in the order of index.names. Made by Load

local function forget()
    keys, key_count, kept, index, shown = {}, 0, {}, nil, nil
end

local function on_changed(name)
    if name == nil or OURS[lower(tostring(name))] then forget() end
end

-- The listening belongs to no mod, whichever mod asked first.
local function table_of(name)
    if not data then
        local found = Wax.import("data.tables").api
        local previous = scope.enter(nil)
        local ok, problem = pcall(function()
            found.Changed:Connect(on_changed)
            found.Patched:Connect(on_changed)
        end)
        scope.leave(previous)
        if not ok then error(problem, 0) end
        data = found
    end
    return data:Table(name)
end

local function name_index()
    if index then return index end
    local names = table_of(STATIC):GetNames()
    local folded, by = {}, {}
    for i = 1, #names do
        local key = fold(names[i])
        folded[i] = key
        -- two names that fold to one can only be told apart by their own spelling
        if by[key] == nil then by[key] = names[i] else by[key] = false end
    end
    index = { names = names, folded = folded, by = by }
    return index
end

-- The key for a name: the item's own name in lower case. False when the game has no such item.
local function find_key(name)
    local key = keys[name]
    if key ~= nil then return key end
    local static = table_of(STATIC)
    if static:Has(name) then
        key = lower(name)
    else
        local real = name_index().by[fold(name)]
        key = real and lower(real) or false
    end
    if key_count >= 500 then keys, key_count = {}, 0 end
    keys[name], key_count = key, key_count + 1
    return key
end

local function described(value)
    if instance.is_instance(value) then return "an Instance" end
    return type(value)
end

local function name_of(item, what)
    if type(item) == "string" then return item end
    if type(item) == "table" and not instance.is_instance(item) then
        local name = rawget(item, "Item")
        if type(name) ~= "string" then name = rawget(item, "Name") end
        if type(name) == "string" then return name end
    end
    error(("%s expects an item: its name such as \"Wood\", or a record that List or game.Items:Get gave. Got %s")
        :format(what, described(item)), 0)
end

-- The key an item's stacks are counted under. A name the game does not have raises with the nearest names.
local function key_of(item, what)
    local name = name_of(item, what)
    local ok, key = pcall(find_key, name)
    -- with the item tables out of reach the name is taken as it is written
    if not ok then return lower(name) end
    if key then return key end
    error(("%s: '%s' is not an item of the game.%s"):format(what, name, suggest.phrase(name, name_index().names)), 0)
end

local function handle_row(table_name, handle, fields)
    local name = type(handle) == "table" and handle.RowName
    if type(name) ~= "string" or name == "" or name == "None" then return nil end
    return table_of(table_name):Row(name, fields)
end

local function read_facts(key)
    local row = table_of(STATIC):Row(key, STATIC_FIELDS)
    if not row then error(("the game's row for the item '%s' could not be read"):format(key), 0) end
    local facts = { Name = row.Name, DisplayName = row.Name }
    local told = handle_row(ITEMABLE, row.Itemable, ITEMABLE_FIELDS)
    if told then
        if type(told.DisplayName) == "string" and told.DisplayName ~= "" then facts.DisplayName = told.DisplayName end
        if type(told.Description) == "string" and told.Description ~= "" then facts.Description = told.Description end
        if type(told.Weight) == "number" then facts.Weight = told.Weight / M.GRAMS end
        facts.MaxStack, facts.Icon = told.MaxStack, told.Icon
    end
    local wear = handle_row(DURABLE, row.Durable, DURABLE_FIELDS)
    if wear then facts.MaxDurability = wear.Max_Durability end
    return facts
end

local Items = {}            -- game.Items itself holds nothing, so nothing of it can be replaced
local api = {}
local NAMES = { "Get", "Has", "GetNames", "Find", "Load" }

-- Wraps a function of game.Items whose errors carry no position, so they point at the mod's line.
local function public(name, fn)
    return function(self, ...)
        if not rawequal(self, Items) then error(("call %s with a colon: game.Items:%s(...)"):format(name, name), 2) end
        local ok, a = pcall(fn, ...)
        if not ok then error(clean(a), 2) end
        return a
    end
end

api.Get = public("Get", function(item)
    local key = key_of(item, "game.Items:Get")
    local facts = kept[key]
    if not facts then
        facts = read_facts(key)
        kept[key] = facts
    end
    local out = {}
    for name, value in pairs(facts) do out[name] = value end
    return out
end)

api.Has = public("Has", function(name)
    if type(name) ~= "string" then error("game.Items:Has expects an item's name such as \"Wood\", got " .. described(name), 0) end
    return find_key(name) ~= false
end)

api.GetNames = public("GetNames", function() return table_of(STATIC):GetNames() end)

api.Find = public("Find", function(text)
    if type(text) ~= "string" then error("game.Items:Find expects the text to look for, got " .. described(text), 0) end
    local wanted = fold(text)
    if wanted == "" then error("game.Items:Find expects the text to look for, and this text is empty", 0) end
    local all = name_index()
    local names, folded, looks = all.names, all.folded, shown
    local first, rest = {}, {}
    for i = 1, #names do
        local at = find(folded[i], wanted, 1, true)
        if not at and looks and looks[i] and find(looks[i], wanted, 1, true) then at = 2 end
        if at == 1 then first[#first + 1] = names[i] elseif at then rest[#rest + 1] = names[i] end
    end
    table.sort(first)
    table.sort(rest)
    for i = 1, #rest do first[#first + 1] = rest[i] end
    return first
end)

-- The reading pauses, so nothing of Wax's own catches around it.
local function load_shown(tries)
    local static = table_of(STATIC):Load({ fields = STATIC_FIELDS })
    local told = table_of(ITEMABLE):Load({ fields = SHOWN_FIELDS })
    local all, out, read = name_index(), {}, 0
    local names = all.names
    for i = 1, #names do
        local row = static[names[i]]
        local handle = row and row.Itemable and row.Itemable.RowName
        local found = nil
        if type(handle) == "string" and handle ~= "" and handle ~= "None" then
            found = told[handle] or table_of(ITEMABLE):Row(handle, SHOWN_FIELDS)
        end
        local text = found and found.DisplayName
        if type(text) == "string" and text ~= "" then
            out[i], read = fold(text), read + 1
        else
            out[i] = false
        end
        if i % M.SLICE == 0 then sched.task.wait() end
    end
    -- the tables changed while this paused: what was made ready belongs to the old ones
    if index ~= all then
        if tries >= 3 then error("the game's item tables keep changing, so the shown names cannot be read right now", 0) end
        return load_shown(tries + 1)
    end
    shown = out
    return read
end

function api.Load(self)
    if not rawequal(self, Items) then error("call Load with a colon: game.Items:Load()", 2) end
    if not co.isyieldable() then
        error("game.Items:Load can only be used inside a task. Wrap the code in task.spawn(function() ... end)", 2)
    end
    if shown then
        local read = 0
        for i = 1, #shown do
            if shown[i] then read = read + 1 end
        end
        return read
    end
    return load_shown(1)
end

setmetatable(Items, {
    __index = function(_, key)
        local found = api[key]
        if found then return found end
        error(("%s is not a member of game.Items.%s"):format(tostring(key), suggest.phrase(tostring(key), NAMES)), 2)
    end,
    __newindex = function(_, key)
        error(("game.Items.%s cannot be assigned because game.Items is read-only"):format(tostring(key)), 2)
    end,
    __tostring = function() return "Items" end,
    __names = function() return NAMES end,
})

-- inventories: a copy of each one that is asked about, made of plain values and read again a little at a time

local copies = {}           -- inventory Instance -> its copy
local by_address = {}       -- engine address -> the same copy, for touch()
local carriers = setmetatable({}, { __mode = "k" })     -- character Instance -> { frame, looked, list }
local counts = { copies = 0, looks = 0, walks = 0, slots = 0, seconds = 0 }
local last_prune, warned = 0, false

local function prune(now)
    last_prune = now
    for inventory, copy in pairs(copies) do
        if now - copy.asked > M.KEEP then
            copies[inventory] = nil
            if by_address[copy.address] == copy then by_address[copy.address] = nil end
            counts.copies = counts.copies - 1
        end
    end
end

local function new_copy(self, now)
    if counts.copies >= M.MANY and now - last_prune >= 1 then prune(now) end
    if M.follow then M.follow() end
    local copy = { slots = {}, size = -1, used = 0, by = {}, list = {}, at = {}, cursor = 1, asked = now, looked = now,
                   swept = now, behind = true, address = instance.address(self) }
    copies[self] = copy
    by_address[copy.address] = copy
    counts.copies = counts.copies + 1
    return copy
end

-- One slot as plain values, or nil for an empty one. Lists are read by index inside their length and never when empty.
local function read_slot(array, position)
    local slot = array[position]
    local held = slot.ItemData
    local row = held.ItemStaticData.RowName:ToString()
    if row == "None" or row == "" then return nil end
    local record = { Item = row, Count = 1, Slot = position }
    local location = slot.Index
    if type(location) == "number" and location >= 0 then record.Slot = location + 1 end
    local dynamic = held.ItemDynamicData
    local count = dynamic:GetArrayNum()
    if type(count) ~= "number" then error("the numbers of a stack have no length", 0) end
    if count > 0 then
        local properties = {}
        for i = 1, count do
            local pair = dynamic[i]
            local kind, value = pair.PropertyType, pair.Value
            if type(kind) ~= "number" or type(value) ~= "number" then error("a number of a stack could not be read", 0) end
            properties[PROPERTIES[kind] or kind] = value
            if kind == M.STACK then record.Count = value elseif kind == M.DURABILITY then record.Durability = value end
        end
        record.Properties = properties
    end
    return record
end

local function same(a, b)
    if not a or not b then return not a and not b end
    if a.Item ~= b.Item or a.Count ~= b.Count or a.Slot ~= b.Slot or a.Durability ~= b.Durability then return false end
    local mine, theirs = a.Properties, b.Properties
    if not mine or not theirs then return mine == theirs end
    for key, value in pairs(mine) do
        if theirs[key] ~= value then return false end
    end
    for key in pairs(theirs) do
        if mine[key] == nil then return false end
    end
    return true
end

local function by_slot(a, b) return a.Slot < b.Slot end

local function rebuild(copy)
    local slots, used, by, list, at, shifted = copy.slots, 0, {}, {}, {}, false
    for position = 1, copy.size do
        local record = slots[position]
        if record then
            used = used + 1
            local key = lower(record.Item)
            by[key] = (by[key] or 0) + record.Count
            list[used], at[record.Slot] = record, record
            if record.Slot ~= position then shifted = true end
        end
    end
    if shifted then table.sort(list, by_slot) end
    copy.used, copy.by, copy.list, copy.at, copy.shifted = used, by, list, at, shifted
end

-- Brings a copy up to date from the live inventory: all of it when its weight or its size changed, else the next few slots.
local function read(copy, raw, now)
    local weight = raw.CurrentWeight
    if type(weight) ~= "number" then error("it has no CurrentWeight", 0) end
    local array = raw.Slots.Slots
    local size = array:GetArrayNum()
    if type(size) ~= "number" then error("its slots have no length", 0) end
    local slots = copy.slots
    local full = copy.behind or weight ~= copy.weight
    if size ~= copy.size then
        for position = #slots, size + 1, -1 do slots[position] = nil end
        for position = #slots + 1, size do slots[position] = false end
        copy.size, full = size, true
    end
    local due
    if full then
        due, copy.cursor = size, 1
    else
        due = ceil(size * (now - copy.swept) / M.SWEEP)
        if due > size then due = size end
    end
    if size > 0 and (full or now - copy.swept >= M.SWEEP) then counts.walks = counts.walks + 1 end
    local cursor, moved = copy.cursor, full
    for _ = 1, due do
        local record = read_slot(array, cursor)
        if not same(slots[cursor], record) then slots[cursor], moved = record or false, true end
        cursor = cursor < size and cursor + 1 or 1
    end
    local dirty = copy.dirty
    copy.dirty = nil
    if dirty and due < size then
        for position in pairs(dirty) do
            if position >= 1 and position <= size then
                local record = read_slot(array, position)
                if not same(slots[position], record) then slots[position], moved = record or false, true end
                due = due + 1
            end
        end
    end
    counts.slots = counts.slots + due
    copy.cursor, copy.weight, copy.swept, copy.behind = cursor, weight, now, false
    if moved then rebuild(copy) end
end

-- The copy of an inventory, looked at again when it is due. `raw` is the live inventory. A copy that could not be read has `broken`.
local function look(self, raw)
    local copy, frame = copies[self], stats.frame
    if copy and copy.frame == frame then return copy end
    local now = sched.clock()
    if copy then
        copy.asked = now
        local due = copy.dirty ~= nil or (copy.behind and not copy.broken)
        if not due and now - copy.looked < M.PACE then
            copy.frame = frame
            return copy
        end
    else
        copy = new_copy(self, now)
    end
    local started = perf.now()
    local ok, problem = pcall(read, copy, raw, now)
    if rawget(_G, LEFT_BEHIND) ~= nil then rawset(_G, LEFT_BEHIND, nil) end
    copy.frame, copy.looked = frame, now
    if ok then
        copy.broken = nil
    else
        copy.broken, copy.behind = clean(problem), true
        if not warned then
            warned = true
            log:warn("an inventory could not be read, so its fields read nil and its functions raise: %s", copy.broken)
        end
    end
    counts.looks = counts.looks + 1
    counts.seconds = counts.seconds + (perf.now() - started)
    return copy
end

local function usable(self, raw, what)
    local copy = look(self, raw)
    if copy.broken then
        error(("%s: this inventory cannot be read in this version of the game (%s)"):format(what, copy.broken), 0)
    end
    return copy
end

-- Where a stack was read from, for Equip and Activate. Kept beside the table, so pairs does not see it.
local stack_methods = {}
local stack_meta = { __index = stack_methods }
local homes = setmetatable({}, { __mode = "k" })
local activated = nil       -- game.Me.Activated, once start() has made it

-- A record to hand out: the mod's own, so changing it changes nothing here.
-- `home` is { inventory = the Inventory, character = the character }, when the stack was read from one.
local function export(record, inventory, home)
    local out = { Item = record.Item, Count = record.Count, Slot = record.Slot, Durability = record.Durability, Inventory = inventory }
    local properties = record.Properties
    if properties then
        local mine = {}
        for key, value in pairs(properties) do mine[key] = value end
        out.Properties = mine
    end
    if home then homes[out] = home end
    return setmetatable(out, stack_meta)
end

local function export_all(list, inventory, into, home)
    local out = into or {}
    for i = 1, #list do out[#out + 1] = export(list[i], inventory, home) end
    return out
end

local function wanted_count(count, what)
    if count == nil then return 1 end
    if type(count) ~= "number" or count ~= count then
        error(("%s expects how many as its second value, got %s"):format(what, described(count)), 0)
    end
    return count
end

local function kind(_, raw)
    local ok, name = pcall(function() return raw.InventoryInfoRowHandle.RowName:ToString() end)
    if not ok or type(name) ~= "string" or name == "" or name == "None" then return nil end
    return name
end

local function size(self, raw)
    local copy = look(self, raw)
    if copy.broken then return nil end
    return copy.size
end

local function used(self, raw)
    local copy = look(self, raw)
    if copy.broken then return nil end
    return copy.used
end

local function weight(_, raw)
    local grams = raw.CurrentWeight
    if type(grams) ~= "number" then return nil end
    return grams / M.GRAMS
end

local function list(self, raw) return export_all(usable(self, raw, "List").list, nil, nil, { inventory = self }) end

local function slot(self, raw, number)
    local copy = usable(self, raw, "Slot")
    if math.type(number) ~= "integer" then
        error(("Slot expects a slot number from 1 to %d, got %s"):format(copy.size, described(number)), 0)
    end
    if number < 1 or number > copy.size then
        error(("this inventory has %d slots, counted from 1, so it has no slot %d"):format(copy.size, number), 0)
    end
    local record = copy.at[number]
    return record and export(record, nil, { inventory = self }) or nil
end

local function count(self, raw, item)
    local key = key_of(item, "Count")
    return usable(self, raw, "Count").by[key] or 0
end

local function has(self, raw, item, wanted)
    local key = key_of(item, "Has")
    wanted = wanted_count(wanted, "Has")
    return (usable(self, raw, "Has").by[key] or 0) >= wanted
end

local function where(self, raw, item)
    local key = key_of(item, "Where")
    local all, out = usable(self, raw, "Where").list, {}
    for i = 1, #all do
        if lower(all[i].Item) == key then out[#out + 1] = export(all[i], nil, { inventory = self }) end
    end
    return out
end

local function refresh(self, raw)
    local copy = copies[self]
    if copy then copy.frame, copy.behind, copy.broken = nil, true, nil end
    usable(self, raw, "Refresh")
end

local inventory_fields = { Kind = kind, Size = size, Used = used, Weight = weight }
local inventory_methods = { List = list, Slot = slot, Count = count, Has = has, Where = where, Refresh = refresh }

-- a player's character: its inventories, and what they hold together

local function carried_field(property)
    return function(_, raw) return wrap(part(raw, property)) end
end

-- The inventories of a character with their copies, found again on the live character once a look is due.
local function carried(self, raw)
    local held, frame = carriers[self], stats.frame
    if held and held.frame == frame then return held.list end
    local now = sched.clock()
    if held and now - held.looked < M.PACE then
        held.frame = frame
        return held.list
    end
    local found = {}
    for i = 1, #CARRIED do
        local live = part(raw, CARRIED[i].property)
        local inventory = live and wrap(live)
        if inventory then found[#found + 1] = { name = CARRIED[i].name, inventory = inventory, copy = look(inventory, live) } end
    end
    carriers[self] = { frame = frame, looked = now, list = found }
    return found
end

local function carried_count(self, raw, key)
    local all, total = carried(self, raw), 0
    for i = 1, #all do
        local copy = all[i].copy
        if not copy.broken then total = total + (copy.by[key] or 0) end
    end
    return total
end

local function character_count(self, raw, item)
    return carried_count(self, raw, key_of(item, "Count"))
end

local function character_has(self, raw, item, wanted)
    local key = key_of(item, "Has")
    return carried_count(self, raw, key) >= wanted_count(wanted, "Has")
end

local function character_list(self, raw)
    local all, out = carried(self, raw), {}
    for i = 1, #all do
        if not all[i].copy.broken then
            export_all(all[i].copy.list, all[i].name, out, { inventory = all[i].inventory, character = self })
        end
    end
    return out
end

local function hotbar_slot(_, raw)
    local focused = raw.FocusedQuickbarSlot
    if math.type(focused) ~= "integer" or focused < 0 then return nil end
    return focused + 1
end

local function held_item(self, raw)
    local number = hotbar_slot(self, raw)
    local live = number and part(raw, CARRIED[HOTBAR].property)
    local hotbar = live and wrap(live)
    if not hotbar then return nil end
    local copy = look(hotbar, live)
    local record = not copy.broken and copy.at[number]
    return record and export(record, CARRIED[HOTBAR].name, { inventory = hotbar, character = self }) or nil
end

-- The dropship whose GetAssignedPlayer is this character's controller, and its DropShip_Equipment hold.
-- FindAll searches every object, so the list is kept for a second and dropped on a map change.
local SHIP_CLASS, SHIP_KIND, SHIP_PACE = "BP_DropShip_C", "DropShip_Equipment", 1
local ship_cache = { at = -1e9, ships = nil, by = {} }

local function address_of(value)
    if value == nil then return nil end
    if instance.is_instance(value) then
        local ok, raw = pcall(function() return value.Raw end)
        if not ok then return nil end
        value = raw
    end
    if value == nil then return nil end
    local ok, address = pcall(function()
        if not value:IsValid() then return nil end
        return value:GetAddress()
    end)
    return ok and address or nil
end

local function ships_now()
    local now = sched.clock()
    if ship_cache.ships and now - ship_cache.at < SHIP_PACE then return ship_cache end
    ship_cache.at, ship_cache.by = now, {}
    local ok, found = pcall(function() return Wax.import("engine.game").root:FindAll(SHIP_CLASS) end)
    ship_cache.ships = ok and type(found) == "table" and found or {}
    return ship_cache
end

local function each_id(ids, consider)
    if type(ids) == "userdata" and type(ids.ForEach) == "function" then
        ids:ForEach(function(_, element)
            local ok, value = pcall(function() return element:get() end)
            if ok then consider(value) end
        end)
        return
    end
    if type(ids) ~= "table" then return end
    if #ids > 0 then
        for i = 1, #ids do consider(ids[i]) end
    else
        for _, id in pairs(ids) do consider(id) end
    end
end

local function equipment_of(ship)
    local ok, component = pcall(function() return ship.Inventory end)
    if not ok or not component then return nil end
    local ids_ok, ids = pcall(function() return component:GetInventoryIds() end)
    if not ids_ok then return nil end
    local found = nil
    local function consider(id)
        if found or id == nil then return end
        local got, inventory = pcall(function() return component:GetInventory(id) end)
        if not got or not inventory then return end
        local inst = instance.is_instance(inventory) and inventory or wrap(inventory)
        if not inst then return end
        local kind_ok, kind = pcall(function() return inst.Kind end)
        if kind_ok and kind == SHIP_KIND then found = inst end
    end
    pcall(each_id, ids, consider)
    return found
end

local function ship_for(controller)
    local addr = address_of(controller)
    if not addr then return nil end
    local cache = ships_now()
    local kept = cache.by[addr]
    if kept ~= nil then return kept or nil end
    local found = nil
    local ships = cache.ships
    for i = 1, #ships do
        local ship = ships[i]
        local ok, assigned = pcall(function() return ship:GetAssignedPlayer() end)
        if ok and address_of(assigned) == addr then
            found = equipment_of(ship)
            break
        end
    end
    cache.by[addr] = found or false
    return found
end

local function ship_inventory(_, raw)
    local ok, controller = pcall(function() return raw.Controller end)
    if not ok or not address_of(controller) then
        controller = nil
        local root_ok, root = pcall(function() return Wax.import("engine.game").root end)
        local who = nil
        if root_ok then
            local who_ok, found = pcall(function() return root.Character end)
            who = who_ok and found or nil
        end
        if who and rawequal(who.Raw, raw) then
            local player_ok, player = pcall(function() return root.LocalPlayer end)
            controller = player_ok and player and player.Raw or nil
        end
    end
    if not controller then return nil end
    return ship_for(controller)
end

local player_fields = { HotbarSlot = hotbar_slot, HeldItem = held_item, ShipInventory = ship_inventory }
for i = 1, #CARRIED do player_fields[CARRIED[i].name] = carried_field(CARRIED[i].property) end
player_fields.Inventory = player_fields.Backpack
local player_methods = { Count = character_count, Has = character_has, List = character_list }

-- giving and taking: the game's own calls. They are made on this machine

M.STATIC_NAME = "D_ItemsStatic"
M.MOST = 100000         -- more than this in one call is refused
local GIVE_TO = 1       -- a character is given items into its backpack
local TAKE_FROM = { 1, HOTBAR }     -- and they are taken from its backpack, then from its hotbar

-- One call of the game's own. A function this version of the game lacks is said in plain words.
local function ask(what, fn, ...)
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    error(("%s did not work in this version of the game: %s"):format(what, clean(a)), 0)
end

local function how_many(amount, what)
    if amount == nil then return 1 end
    if type(amount) ~= "number" or amount ~= amount or amount < 1 or amount > M.MOST or math.floor(amount) ~= amount then
        error(("%s expects how many as its second value, a whole number from 1 to %d, got %s"):format(what, M.MOST,
            type(amount) == "number" and tostring(amount) or described(amount)), 0)
    end
    return math.floor(amount)
end

-- The key and the facts of an item that is about to be given. The name has to be one the game's tables have.
local function facts_for(item, what)
    local name = name_of(item, what)
    local found, key = pcall(find_key, name)
    if not found then
        error(("%s: the game's item tables cannot be read right now, so '%s' cannot be checked (%s)"):format(what, name, clean(key)), 0)
    end
    if not key then
        error(("%s: '%s' is not an item of the game.%s"):format(what, name, suggest.phrase(name, name_index().names)), 0)
    end
    local facts = kept[key]
    if not facts then
        local read_ok, read_facts_or_problem = pcall(read_facts, key)
        if not read_ok then
            error(("%s: the game's facts about '%s' cannot be read right now (%s)"):format(what, name, clean(read_facts_or_problem)), 0)
        end
        facts = read_facts_or_problem
        kept[key] = facts
    end
    return key, facts
end

-- An item as the game's functions take one: only its row. A list inside this table would break the call.
local function item_value(name)
    return { ItemStaticData = { RowName = FName(name), DataTableName = FName(M.STATIC_NAME) } }
end

local function top_up(raw, name, amount) return raw:AttemptPartialStackPlacement(item_value(name), amount) end
local function accepts(raw, name, location) return raw:CanAdd(item_value(name), location) end
local function set_stack(raw, location, amount) return raw:SetItemDynamicProperty(location, M.STACK, amount) end
local function consume(raw, location, amount) return raw:ConsumeItem(location, amount, false) end
local function slot_now(raw, position) return read_slot(raw.Slots.Slots, position) end

-- After the table for the answer UE4SS hands every value over one early: the third value here is AllowStacking, the
-- fourth is never read, and DropItemAtOverFlow is always on. So this is only called when an empty slot is known.
local function place_one(raw, name)
    local out = {}
    local placed = raw:AutomaticallyPlaceItem(item_value(name), out, false, false)
    return placed, out.PlacedLocation
end

-- The copy of an inventory with every slot read now.
local function fresh(self, raw, what)
    local copy = copies[self]
    if copy then copy.frame, copy.behind, copy.broken = nil, true, nil end
    return usable(self, raw, what)
end

-- Puts `amount` of an item into one inventory: first onto its stacks, then one empty slot at a time.
-- Answers how many went in, and why not all of them when some did not.
local function put(self, raw, key, facts, amount)
    local copy = fresh(self, raw, "Give")
    local name, most = facts.Name, facts.MaxStack
    if math.type(most) ~= "integer" or most < 1 then most = 1 end
    local left, why = amount, nil
    if most > 1 and (copy.by[key] or 0) > 0 then
        local over = ask("topping up a stack", top_up, raw, name, left)
        if math.type(over) == "integer" and over >= 0 and over <= left then left = over end
    end
    local last, slots, filled, position = copy.size, copy.slots, {}, 1
    while left > 0 do
        local found = nil
        while position <= last do
            if not slots[position] and not filled[position] and ask("asking a slot", accepts, raw, name, position - 1) == true then
                found = position
                break
            end
            position = position + 1
        end
        if not found then
            why = "no room"
            break
        end
        local placed, location = ask("placing an item", place_one, raw, name)
        local landed = placed == true and math.type(location) == "integer" and location >= 0 and location < last
        local ok, record = pcall(slot_now, raw, landed and location + 1 or found)
        if not landed or not ok or not record or lower(record.Item) ~= key then
            why = "the game did not place it"
            log:warn("the game did not put %s where it was given, so giving stopped: %s", name, landed and ok and "the slot holds something else"
                or (not landed and "it named no slot" or clean(record)))
            break
        end
        local chunk = left < most and left or most
        if chunk > 1 and ask("setting a stack", set_stack, raw, location, chunk) ~= true then chunk = 1 end
        left = left - chunk
        filled[location + 1] = true
    end
    if rawget(_G, LEFT_BEHIND) ~= nil then rawset(_G, LEFT_BEHIND, nil) end
    M.touch(copy.address)
    return amount - left, why
end

-- Takes up to `amount` of an item out of one inventory, from its last stack back. Answers how many went.
local function remove(self, raw, key, amount)
    local copy = fresh(self, raw, "Take")
    local all, left = copy.list, amount
    for i = #all, 1, -1 do
        if left <= 0 then break end
        local record = all[i]
        if lower(record.Item) == key and math.type(record.Count) == "integer" and record.Count >= 1 then
            local some = record.Count < left and record.Count or left
            if ask("taking an item", consume, raw, record.Slot - 1, some) == true then left = left - some end
        end
    end
    M.touch(copy.address)
    return amount - left
end

-- What Give answers: how many went in, and in plain words why the rest did not.
local function given_answer(given, wanted, why)
    if given >= wanted then return given end
    if why == "no room" then return given, ("there was no room for %d of the %d"):format(wanted - given, wanted) end
    return given, ("the game did not place %d of the %d"):format(wanted - given, wanted)
end

local function taken_answer(taken, wanted)
    if taken >= wanted then return taken end
    return taken, ("there were only %d of the %d to take"):format(taken, wanted)
end

local function give(self, raw, item, amount)
    local key, facts = facts_for(item, "Give")
    local wanted = how_many(amount, "Give")
    local given, why = put(self, raw, key, facts, wanted)
    return given_answer(given, wanted, why)
end

local function take(self, raw, item, amount)
    local key = key_of(item, "Take")
    local wanted = how_many(amount, "Take")
    return taken_answer(remove(self, raw, key, wanted), wanted)
end

local function character_give(self, raw, item, amount)
    local key, facts = facts_for(item, "Give")
    local wanted = how_many(amount, "Give")
    local live = part(raw, CARRIED[GIVE_TO].property)
    local backpack = live and wrap(live)
    if not backpack then error("Give: this character has no backpack to put items in", 0) end
    local given, why = put(backpack, live, key, facts, wanted)
    carriers[self] = nil
    return given_answer(given, wanted, why)
end

local function character_take(self, raw, item, amount)
    local key = key_of(item, "Take")
    local wanted = how_many(amount, "Take")
    local taken = 0
    for i = 1, #TAKE_FROM do
        local live = taken < wanted and part(raw, CARRIED[TAKE_FROM[i]].property)
        local inventory = live and wrap(live)
        if inventory then taken = taken + remove(inventory, live, key, wanted - taken) end
    end
    carriers[self] = nil
    return taken_answer(taken, wanted)
end

M.MOST_SLOTS = 500      -- more slots than this in one inventory is refused

local function add_slots(raw, more) raw:AddSlots(more, {}) end
local function remove_slots(raw, fewer) raw:RemoveSlots(fewer) end

-- Slots come and go at the end. A slot that holds something is never taken, nor any slot before it.
local function resize(self, raw, wanted)
    if math.type(wanted) ~= "integer" or wanted < 1 or wanted > M.MOST_SLOTS then
        error(("Resize expects how many slots, a whole number from 1 to %d, got %s"):format(M.MOST_SLOTS,
            type(wanted) == "number" and tostring(wanted) or described(wanted)), 0)
    end
    local copy = fresh(self, raw, "Resize")
    local have, target = copy.size, wanted
    if wanted < have then
        for position = have, wanted + 1, -1 do
            if copy.slots[position] then
                target = position
                break
            end
        end
    end
    if target > have then
        ask("adding slots", add_slots, raw, target - have)
    elseif target < have then
        ask("taking slots", remove_slots, raw, have - target)
    end
    M.touch(copy.address)
    local now = fresh(self, raw, "Resize").size
    if now == wanted then return now end
    if target ~= wanted and now == target then
        return now, ("slot %d holds something, so %d slots stay"):format(target, now)
    end
    return now, ("the game left it at %d slots"):format(now)
end

inventory_methods.Give, inventory_methods.Take, inventory_methods.Resize = give, take, resize
player_methods.Give, player_methods.Take = character_give, character_take

-- For the module that hears the game's item events: the slot at `location` (counted from 0, as the game counts) of the
-- inventory at this engine address changed. Without a location all of it is read again. False when no copy is kept of it.
function M.touch(address, location)
    local copy = by_address[address]
    if not copy then return false end
    copy.frame = nil
    if math.type(location) ~= "integer" or copy.shifted then
        copy.behind = true
    else
        local dirty = copy.dirty or {}
        dirty[location + 1] = true
        copy.dirty = dirty
    end
    return true
end

-- Called after a map change: what was kept belongs to objects that are gone, and none of them is asked anything.
function M.flush()
    copies, by_address = {}, {}
    carriers = setmetatable({}, { __mode = "k" })
    counts.copies = 0
    ship_cache.at, ship_cache.ships, ship_cache.by = -1e9, nil, {}
end

-- what the game tells of its inventories: the copies follow at once, and a mod hears what was added, removed and changed

M.EVENTS = true         -- false before start(): the game's item events are not listened to, and no inventory has ItemAdded
M.TOLD = { "/Script/Icarus.InventoryComponent:ItemAddedDelagate", "/Script/Icarus.InventoryComponent:ItemRemovedDelagate",
    "/Script/Icarus.InventoryComponent:ItemChangedDelegate" }
M.REBIND = 0.5          -- seconds between two looks at whether the local player has another character
local QUIET = { Decayable_CurrentSpoilTime = true }     -- a number the game moves every second, which is no change to tell

---@type any
local hooks = nil       -- engine.hooks, once start() has it
local ears = setmetatable({}, { __mode = "k" })         -- inventory Instance -> what each slot last held, while someone listens
local voices = setmetatable({}, { __mode = "k" })       -- inventory Instance -> its ItemAdded, ItemRemoved and ItemChanged
-- undo: nil before the first try, false when the game's events cannot be listened to
local hearing = { count = 0, undo = nil, problem = nil, dirty = {}, waiting = false, me = {}, me_of = nil, me_wanted = 0, thread = nil }
local me_voice = nil    -- the three signals of game.Me

-- Two records of a slot that a mod would call the same.
local function alike(a, b)
    if not a or not b then return not a and not b end
    if a.Item ~= b.Item or a.Count ~= b.Count or a.Slot ~= b.Slot or a.Durability ~= b.Durability then return false end
    local mine, theirs = a.Properties or {}, b.Properties or {}
    for key, value in pairs(mine) do
        if not QUIET[key] and theirs[key] ~= value then return false end
    end
    for key in pairs(theirs) do
        if not QUIET[key] and mine[key] == nil then return false end
    end
    return true
end

local function seen_now(raw, position)
    local array = raw.Slots.Slots
    local length = array:GetArrayNum()
    if type(length) ~= "number" or position < 1 or position > length then return nil end
    return read_slot(array, position) or false
end

-- Inside the game's own call: an inventory and the slot of it that the game says changed.
local function caught_item(_, inventory_value, slot_value)
    local raw = inventory_value:get()
    if raw == nil or not raw:IsValid() then return nil end
    local location = slot_value:get()
    M.touch(raw:GetAddress(), location)
    if hearing.count == 0 or math.type(location) ~= "integer" then return nil end
    local inventory = wrap(raw)
    local ear = inventory and ears[inventory]
    if not ear then return nil end
    local position = location + 1
    local ok, record = pcall(seen_now, raw, position)
    if rawget(_G, LEFT_BEHIND) ~= nil then rawset(_G, LEFT_BEHIND, nil) end
    if not ok or record == nil then return nil end
    local seen = ear.seen
    local previous = seen[position] or false
    seen[position] = record
    if ear.changed[position] == nil then
        if alike(previous, record) then return nil end
        ear.changed[position] = previous
    end
    if not ear.dirty then
        ear.dirty = true
        hearing.dirty[#hearing.dirty + 1] = ear
    end
    if hearing.waiting then return nil end
    hearing.waiting = true
    return true
end

-- Adds what a slot held (sign -1) or holds (sign 1) to what its item gained in all. `name` is the inventory, for game.Me.
local function tally(gains, order, record, sign, name, inventory)
    if not record then return end
    local key = lower(record.Item)
    local gain = gains[key]
    if not gain then
        gain = { item = record.Item, amount = 0 }
        gains[key] = gain
        order[#order + 1] = gain
    end
    gain.amount = gain.amount + sign * record.Count
    if sign > 0 then
        gain.now, gain.now_name, gain.now_inventory = record, name, inventory
    else
        gain.before, gain.before_name, gain.before_inventory = record, name, inventory
    end
end

-- Tells what one frame did: each slot that holds something else now, then what went, then what came.
local function handed(record, name, inventory)
    if not record then return nil end
    return export(record, name, inventory and { inventory = inventory } or nil)
end

local function announce(voice, changes, order)
    if voice.ItemChanged.count > 0 then
        for i = 1, #changes do
            local change = changes[i]
            voice.ItemChanged:Fire(handed(change.now, change.name, change.inventory),
                handed(change.previous, change.name, change.inventory))
        end
    end
    for i = 1, #order do
        local gain = order[i]
        if gain.amount < 0 and voice.ItemRemoved.count > 0 then
            voice.ItemRemoved:Fire(gain.item, -gain.amount, handed(gain.before, gain.before_name, gain.before_inventory))
        end
    end
    for i = 1, #order do
        local gain = order[i]
        if gain.amount > 0 and voice.ItemAdded.count > 0 then
            voice.ItemAdded:Fire(gain.item, gain.amount, handed(gain.now, gain.now_name, gain.now_inventory))
        end
    end
end

-- In the frame loop: what the slots the game named hold now, against what they held before this frame.
local function settle()
    hearing.waiting = false
    local dirty = hearing.dirty
    hearing.dirty = {}
    local pool, pool_gains, pool_order = {}, {}, {}
    for i = 1, #dirty do
        local ear = dirty[i]
        local before = ear.changed
        ear.dirty, ear.changed = false, {}
        local positions = {}
        for position in pairs(before) do positions[#positions + 1] = position end
        table.sort(positions)
        -- the inventory's name when the local player's character carries it
        local name = hearing.me[ear.inventory]
        local changes, gains, order = {}, {}, {}
        for p = 1, #positions do
            local position = positions[p]
            local previous, now = before[position] or false, ear.seen[position] or false
            if not alike(previous, now) then
                changes[#changes + 1] = { now = now, previous = previous, inventory = ear.inventory }
                tally(gains, order, previous, -1, nil, ear.inventory)
                tally(gains, order, now, 1, nil, ear.inventory)
                if name then
                    pool[#pool + 1] = { now = now, previous = previous, name = name, inventory = ear.inventory }
                    tally(pool_gains, pool_order, previous, -1, name, ear.inventory)
                    tally(pool_gains, pool_order, now, 1, name, ear.inventory)
                end
            end
        end
        local voice = voices[ear.inventory]
        if voice and #changes > 0 then announce(voice, changes, order) end
    end
    if #pool > 0 and me_voice then announce(me_voice, pool, pool_order) end
end

-- Starts listening to the game's item events. False when that cannot be done in this build.
function M.follow()
    if hearing.undo ~= nil then return hearing.undo ~= false end
    if not hooks or type(RegisterHook) ~= "function" then
        hearing.undo, hearing.problem = false, "the game's item events are not listened to here"
        return false
    end
    local undo = {}
    local previous = scope.enter(nil)
    local ok, problem = pcall(function()
        for i = 1, #M.TOLD do
            undo[i] = hooks.listen(M.TOLD[i], { reach = hooks.DELEGATE, catch = caught_item, deliver = settle, label = "items" })
        end
    end)
    scope.leave(previous)
    if ok then
        hearing.undo = undo
        return true
    end
    for i = 1, #undo do undo[i]() end
    hearing.undo, hearing.problem = false, clean(problem)
    log:warn("the game's item events cannot be listened to, so inventories are only looked at: %s", hearing.problem)
    return false
end

local function must_follow()
    if M.follow() then return end
    error("what is added to and taken out of an inventory cannot be told in this version of the game: " .. tostring(hearing.problem), 0)
end

-- An ear holds what every slot of one inventory held when the game last named it. The first one reads the inventory whole.
local function open_ear(inventory, raw)
    local ear = ears[inventory]
    if not ear then
        local copy = fresh(inventory, raw, "listening")
        local seen = {}
        for position = 1, copy.size do seen[position] = copy.slots[position] or false end
        ear = { inventory = inventory, seen = seen, changed = {}, dirty = false, wanted = 0 }
        ears[inventory] = ear
        hearing.count = hearing.count + 1
    end
    ear.wanted = ear.wanted + 1
end

local function close_ear(inventory)
    local ear = ears[inventory]
    if not ear then return end
    ear.wanted = ear.wanted - 1
    if ear.wanted > 0 then return end
    ears[inventory] = nil
    hearing.count = hearing.count > 0 and hearing.count - 1 or 0
end

-- The ItemAdded, ItemRemoved and ItemChanged of one inventory, made when a mod first asks for one of them.
local function voice_of(self)
    local mine = voices[self]
    if mine then return mine end
    local function first()
        must_follow()
        open_ear(self, self.Raw)
    end
    local function last() close_ear(self) end
    mine = { ItemAdded = hooks.signal("Inventory.ItemAdded", first, last), ItemRemoved = hooks.signal("Inventory.ItemRemoved", first, last),
        ItemChanged = hooks.signal("Inventory.ItemChanged", first, last) }
    voices[self] = mine
    return mine
end

-- game.Me listens to whatever the local player's character carries, and to the next character after this one.
local function bind_me()
    local who = Wax.import("world.character").current()
    if rawequal(who, hearing.me_of) then return end
    for inventory in pairs(hearing.me) do close_ear(inventory) end
    hearing.me, hearing.me_of = {}, who
    if not who then return end
    local raw = who.Raw
    for i = 1, #CARRIED do
        local live = part(raw, CARRIED[i].property)
        local inventory = live and wrap(live)
        if inventory and pcall(open_ear, inventory, live) then hearing.me[inventory] = CARRIED[i].name end
    end
end

local function unbind_me()
    for inventory in pairs(hearing.me) do close_ear(inventory) end
    hearing.me, hearing.me_of = {}, nil
end

local function me_loop()
    while hearing.me_wanted > 0 do
        sched.task.wait(M.REBIND)
        if hearing.me_wanted > 0 then pcall(bind_me) end
    end
    hearing.thread = nil
end

local function me_first()
    must_follow()
    hearing.me_wanted = hearing.me_wanted + 1
    if hearing.me_wanted > 1 then return end
    pcall(bind_me)
    if hearing.thread then return end
    local previous = scope.enter(nil)
    local ok, thread = pcall(sched.task.spawn, me_loop)
    scope.leave(previous)
    if ok then hearing.thread = thread end
end

local function me_last()
    hearing.me_wanted = hearing.me_wanted > 0 and hearing.me_wanted - 1 or 0
    if hearing.me_wanted == 0 then unbind_me() end
end

-- After a map change every inventory that was listened to is gone, and none of them is asked anything.
local function events_flush()
    local old = voices
    ears, voices = setmetatable({}, { __mode = "k" }), setmetatable({}, { __mode = "k" })
    hearing.count, hearing.dirty, hearing.waiting, hearing.me, hearing.me_of = 0, {}, false, {}, nil
    for _, voice in pairs(old) do
        for _, signal in pairs(voice) do signal:DisconnectAll() end
    end
end

local function events_start()
    if hooks or not M.EVENTS then return end
    local loaded, module = pcall(Wax.import, "engine.hooks")
    if not loaded then
        log:warn("engine.hooks did not load, so nothing is told of what inventories gain and lose: %s", clean(module))
        return
    end
    hooks = module
    inventory_fields.ItemAdded = function(self) return voice_of(self).ItemAdded end
    inventory_fields.ItemRemoved = function(self) return voice_of(self).ItemRemoved end
    inventory_fields.ItemChanged = function(self) return voice_of(self).ItemChanged end
    local found, character = pcall(Wax.import, "world.character")
    if found and type(character.provide) == "function" then
        me_voice = { ItemAdded = hooks.signal("game.Me.ItemAdded", me_first, me_last),
            ItemRemoved = hooks.signal("game.Me.ItemRemoved", me_first, me_last),
            ItemChanged = hooks.signal("game.Me.ItemChanged", me_first, me_last) }
        for name, signal in pairs(me_voice) do character.provide(name, signal) end
    end
    local previous = scope.enter(nil)
    pcall(function() Wax.import("engine.game").root.MapChanged:Connect(events_flush) end)
    scope.leave(previous)
end

-- The character that can put this stack in its hand: the one it was read from, the inventory's owner, or the local one.
local function player_of(inventory, hint)
    if instance.is_instance(hint) and hint:IsA("IcarusPlayerCharacter") then return hint end
    if instance.is_instance(inventory) then
        local ok, parent = pcall(function() return inventory.Parent end)
        if ok and instance.is_instance(parent) and parent:IsA("IcarusPlayerCharacter") then return parent end
    end
    local ok, who = pcall(function() return Wax.import("world.character").current() end)
    if ok and instance.is_instance(who) and who:IsA("IcarusPlayerCharacter") then return who end
    return nil
end

local function controller_of(who)
    if not who then return nil end
    local ok, controller = pcall(function() return who.Raw.Controller end)
    if ok and address_of(controller) then return instance.is_instance(controller) and controller or wrap(controller) end
    local root_ok, root = pcall(function() return Wax.import("engine.game").root end)
    if not root_ok then return nil end
    local mine_ok, mine = pcall(function() return root.Character end)
    if mine_ok and mine and rawequal(mine.Raw, who.Raw) then
        local player_ok, player = pcall(function() return root.LocalPlayer end)
        if player_ok then return player end
    end
    return nil
end

-- A row of D_Uses, as the struct the game's use call takes.
local function use_struct(name)
    local ok, lib = pcall(function() return Wax.import("engine.game").root:Library("UsesLibrary") end)
    if not ok then error("Activate: the game's uses cannot be read right now (" .. clean(lib) .. ")", 0) end
    local valid_ok, valid = pcall(function() return lib:IsValidName(name) end)
    if valid_ok and valid == false then
        error(("Activate: '%s' is not a use the game has. A use is a row of D_Uses, such as \"Consume\" or \"Place\"")
            :format(name), 0)
    end
    local struct_ok, enum = pcall(function() return lib:NameToStruct(name) end)
    if not struct_ok or enum == nil then
        error(("Activate: '%s' could not be read as a use (%s)"):format(name, struct_ok and "the game gave none" or clean(enum)), 0)
    end
    return enum
end

local function prepare_stack(self, name)
    if type(self) ~= "table" or math.type(rawget(self, "Slot")) ~= "integer" then
        error(("call %s with a colon: stack:%s()"):format(name, name), 0)
    end
    local home = homes[self]
    local inventory = home and home.inventory
    if not instance.is_instance(inventory) then
        error(("%s needs a stack from an inventory, such as one that Hotbar, Slot, List or HeldItem gave"):format(name), 0)
    end
    local who = player_of(inventory, home.character)
    if not who then error(name .. " needs a player's character to put this stack in hand", 0) end
    return home, inventory, who
end

function stack_methods:Equip()
    local ok, home, inventory, who = pcall(prepare_stack, self, "Equip")
    if not ok then error(clean(home), 2) end
    local called, problem = pcall(function() who:OnServer_FocusItem(inventory, rawget(self, "Slot") - 1) end)
    if not called then error("Equip did not work in this version of the game: " .. clean(problem), 2) end
end

function stack_methods:Activate(use)
    local equipped, problem = pcall(stack_methods.Equip, self)
    if not equipped then error(clean(problem), 2) end
    if use ~= nil then
        if type(use) ~= "string" or use == "" then
            error("Activate expects the name of a use, such as \"Consume\", or no name at all", 2)
        end
        local home = homes[self]
        local controller = controller_of(player_of(home.inventory, home.character))
        if not controller then error("Activate: this character has no controller to use the item", 2) end
        local got, enum = pcall(use_struct, use)
        if not got then error(clean(enum), 2) end
        local called, failed = pcall(function() controller:OnServer_UseItemAuto(home.inventory, rawget(self, "Slot") - 1, enum) end)
        if not called then error("Activate did not work in this version of the game: " .. clean(failed), 2) end
    end
    if activated then activated:Fire(self, use) end
end

-- What is in the hotbar slot the game says is in hand: { slot, item name }. false where there is none.
local function held_key(_, raw)
    local ok, number = pcall(hotbar_slot, nil, raw)
    if not ok or type(number) ~= "number" then return { false, false } end
    local live_inv = part(raw, CARRIED[HOTBAR].property)
    local hotbar = live_inv and wrap(live_inv)
    if not hotbar then return { number, false } end
    local copy_ok, copy = pcall(look, hotbar, live_inv)
    if not copy_ok or copy.broken then return { number, false } end
    local record = copy.at[number]
    return { number, record and record.Item or false }
end

local equipped_ready = false

local function equip_signals(character)
    if equipped_ready or type(character.feed) ~= "function" or type(character.provide) ~= "function" then return end
    equipped_ready = true
    character.feed({
        name = "Equipped",
        every = 0.25,
        read = held_key,
        outlets = {
            { "Equipped", function(signal, _, previous)
                if previous == nil then return end
                local who = character.current()
                local stack = who and held_item(who, who.Raw) or nil
                local before = previous[2]
                signal:Fire(stack, before ~= false and before or nil)
            end },
        },
    })
    activated = sched.Signal.new("game.Me.Activated")
    character.provide("Activated", activated)
end

local connection = nil

function M.start()
    local events_ok, events_problem = pcall(events_start)
    if not events_ok then log:warn("what the game tells of inventories could not be set up: %s", clean(events_problem)) end
    easy.class(M.INVENTORY, { fields = inventory_fields, methods = inventory_methods }, "items")
    local spec = { fields = player_fields, methods = player_methods }
    -- through world.character, game.Me knows these names with no character too
    local loaded, character = pcall(Wax.import, "world.character")
    if loaded then
        character.extend("player", spec, "items")
        local signals_ok, signals_problem = pcall(equip_signals, character)
        if not signals_ok then log:warn("what a character holds in its hand could not be told: %s", clean(signals_problem)) end
    else
        log:warn("world.character did not load, so game.Me does not know what a character carries: %s", clean(character))
        easy.class(M.PLAYER, spec, "items")
    end
    local root = Wax.import("engine.game").root
    rawset(root, "Items", Items)
    if not connection then
        local previous = scope.enter(nil)
        local ok, made = pcall(function() return root.MapChanged:Connect(M.flush) end)
        scope.leave(previous)
        if ok then connection = made else log:warn("the map change could not be listened to: %s", clean(made)) end
    end
end

function M.stats()
    local facts = 0
    for _ in pairs(kept) do facts = facts + 1 end
    return { copies = counts.copies, looks = counts.looks, walks = counts.walks, slots = counts.slots,
        look_us = counts.looks > 0 and counts.seconds / counts.looks * 1e6 or 0, facts = facts, names = index ~= nil,
        shown = shown ~= nil, told = hearing.undo ~= nil and hearing.undo ~= false, listened = hearing.count }
end

M.api = Items
return M
