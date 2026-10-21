-- The structures around the player that hold items, and what each one takes: game.Containers

local Wax = ...
local track = Wax.import("engine.track")
local instance = Wax.import("engine.instance")
local sched = Wax.import("core.sched")
local co = Wax.import("core.co")
local log = Wax.import("core.log").channel("wax.containers")

local M = {}

M.ROOT = "/Script/Icarus.Deployable"
M.ANIMALS = "/Script/Icarus.IcarusNPCCharacter"      -- tamed animals with cargo count too
M.CARGO = { "cargo", "saddle_bag", "pouch" }           -- the inventory kinds of a cargo animal
M.INVENTORY_COMPONENT = "/Script/Icarus.InventoryComponent"
M.PROCESSING_COMPONENT = "/Script/Icarus.ProcessingComponent"
M.UNIT = 100                -- engine units in a metre
M.RANGE = 30                -- metres, when none is given
M.RECHECK = 5               -- seconds before a structure whose inventories were not there yet is asked again
-- inventories that never take a stash, by a part of their kind (their row of D_InventoryInfo, in lower case)
M.SKIP = { "rain_reservoir", "water", "player_grave", "mission", "corpse", "overflow", "reward", "removeonly", "settlement", "drone",
    "dropship", "quickbar", "equipment", "envirosuit", "upgrade", "vision", "backpack", "mount_meta", "mount_saddle" }
M.FUEL = { "fuel" }
M.RECIPE_FIELDS = { "RecipeSets.RowName", "Inputs.Element.RowName" }

local Containers = { Changed = sched.Signal.new("Changed") }
local tracked = nil
local inventory_class, processing_class = nil, nil
local accepted_by_set = {}      -- recipe set name -> { [folded item] = spelling }
local recipes_loaded = nil      -- the rows of D_ProcessorRecipes, read once

local lower = string.lower
local function fold(name) return lower(tostring(name or "")) end
M.fold = fold

local function clean(problem) return (tostring(problem):gsub("^[^\n]-%.lua:%d+: ", "", 1)) end

local function address(object)
    local ok, value = pcall(function() return object:GetAddress() end)
    if ok and type(value) == "number" and value ~= 0 then return value end
    return nil
end

local function find_classes()
    if not inventory_class then
        local found = StaticFindObject(M.INVENTORY_COMPONENT)
        if found and found:IsValid() then inventory_class = found end
    end
    if not processing_class then
        local found = StaticFindObject(M.PROCESSING_COMPONENT)
        if found and found:IsValid() then processing_class = found end
    end
end

local function has_part(actor, class)
    if not class then return false end
    local ok, part = pcall(function() return actor:GetComponentByClass(class) end)
    return ok and part ~= nil and address(part) ~= nil
end

local function row_of(raw)
    local ok, row = pcall(function() return raw.ItemData.ItemStaticData.RowName:ToString() end)
    if ok and type(row) == "string" and row ~= "" and row ~= "None" then return row end
    return nil
end

-- A creature's set-up row (every IcarusNPCCharacter has one), or nil for anything else.
local function animal_row(actor)
    local ok, row = pcall(function() return actor.AISetupRow.RowName:ToString() end)
    if ok and type(row) == "string" and row ~= "" and row ~= "None" then return row end
    return nil
end

-- A tamed animal with cargo: its kind is "cargo:<set-up row>", and only one that carries an inventory of a cargo kind is
-- listed. A client is handed the inventories a moment after the creature, so it is asked again for a while.
local function classify_animal(actor, row, last)
    if not has_part(actor, inventory_class) then return false end
    local found, named = false, {}
    pcall(function()
        local component = actor:GetComponentByClass(inventory_class)
        component.Inventories:ForEach(function(_, value)
            local inventory = value:get()
            local ok, kind = pcall(function() return inventory.InventoryInfoRowHandle.RowName:ToString() end)
            if ok then
                named[#named + 1] = kind
                if kind_matches(kind, M.CARGO) then found = true end
            end
        end)
    end)
    if not found then
        if last then return false end
        return nil
    end
    log:info("cargo animal listed: %s with %s", row, table.concat(named, ", "))
    return "cargo:" .. fold(row), row
end

local function classify(actor, last)
    find_classes()
    local row = animal_row(actor)
    if row then return classify_animal(actor, row, last) end
    if not has_part(actor, inventory_class) and not has_part(actor, processing_class) then return false end
    local row = row_of(actor)
    if row then return fold(row), row end
    if last then return false end
    return nil
end

local function kind_matches(kind, parts)
    local folded = fold(kind)
    for i = 1, #parts do
        if folded:find(parts[i], 1, true) then return true end
    end
    return false
end

-- True for an inventory kind a stash may go into.
function M.takes(kind)
    if type(kind) ~= "string" or kind == "" then return false end
    return not kind_matches(kind, M.SKIP) and not kind_matches(kind, M.FUEL)
end

function M.is_fuel(kind) return type(kind) == "string" and kind_matches(kind, M.FUEL) end

local function skipped(inventory)
    local raw = inventory.Raw
    local ok, yes = pcall(function() return raw:IsClientSideOnlyInventory() end)
    if ok and yes == true then return true end
    ok, yes = pcall(function() return raw:IsRemoveOnly() end)
    return ok and yes == true
end

-- The inventories of a structure: those that take items, the fuel ones, and a station's input inventory.
local function inventories_of(entry)
    local now = sched.clock()
    local known = entry.inventories
    if known and (#known.takes > 0 or #known.fuel > 0 or known.inputs or now - known.at < M.RECHECK) then return known end
    local found = { takes = {}, fuel = {}, inputs = nil, at = now }
    local raw = entry.instance.Raw
    pcall(function()
        local component = raw:GetComponentByClass(inventory_class)
        if not component or not address(component) then return end
        component.Inventories:ForEach(function(_, value)
            local inventory = instance.wrap(value:get())
            if inventory and not skipped(inventory) then
                local kind = inventory.Kind
                if M.is_fuel(kind) then
                    found.fuel[#found.fuel + 1] = inventory
                elseif M.takes(kind) then
                    found.takes[#found.takes + 1] = inventory
                end
            end
        end)
    end)
    pcall(function()
        local processor = raw:GetComponentByClass(processing_class)
        if processor and address(processor) then
            local inventory = processor.Inventory
            if inventory and address(inventory) then found.inputs = instance.wrap(inventory) end
        end
    end)
    entry.inventories = found
    return found
end

local function metres_between(here, there)
    local dx, dy, dz = here.X - there.X, here.Y - there.Y, here.Z - there.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz) / M.UNIT
end

local function place_of(actor)
    local ok, at = pcall(function() return actor.Position end)
    if ok and type(at) == "table" and type(at.X) == "number" then return at end
    return nil
end

-- The local player's character, also while it rides: the game then controls the mount.
local function here()
    local root = Wax.import("engine.game").root
    local ok, me = pcall(function() return Wax.import("world.character").current() end)
    local at = ok and me and place_of(me) or nil
    if at then return at end
    local found, who = pcall(function() return instance.wrap(root.LocalPlayer.Raw:GetIcarusPlayerCharacter()) end)
    return found and who and place_of(who) or nil
end

local function shown_name(row, entry)
    if entry and entry.kind and entry.kind:sub(1, 6) == "cargo:" then
        local name = row
        pcall(function()
            local info = Wax.import("engine.game").root.Creatures:GetInfo(row)
            if info and type(info.DisplayName) == "string" and info.DisplayName ~= "" then name = info.DisplayName end
        end)
        return "Cargo: " .. name
    end
    local ok, facts = pcall(function() return Wax.import("engine.game").root.Items:Get(row) end)
    if ok and type(facts) == "table" and type(facts.DisplayName) == "string" and facts.DisplayName ~= "" then return facts.DisplayName end
    return (tostring(row):gsub("^Kit_", ""):gsub("_", " "))
end

local function use()
    if not tracked then
        find_classes()
        tracked = track.define("containers", { roots = { M.ROOT, M.ANIMALS }, seed = { "Deployable", "IcarusNPCCharacter" }, classify = classify })
        local function changed() Containers.Changed:Fire() end
        tracked.Added:Connect(changed)
        tracked.Removed:Connect(changed)
        tracked.Cleared:Connect(function()
            accepted_by_set = {}
            recipes_loaded = nil
            changed()
        end)
    end
    tracked:use()
    return tracked
end

-- The recipe set a station of this item row works from, through D_ItemsStatic and D_Processing. Nil for a chest.
local function set_of(row)
    local data = Wax.import("engine.game").root.Data
    local ok, static = pcall(function() return data:Table("ItemsStatic"):Row(row, { "Processing.RowName" }) end)
    local processing = ok and static and static.Processing and static.Processing.RowName or nil
    if type(processing) ~= "string" or processing == "" or processing == "None" then return nil end
    local got, setup = pcall(function() return data:Table("Processing"):Row(processing, { "DefaultRecipeSet.RowName" }) end)
    local set = got and setup and setup.DefaultRecipeSet and setup.DefaultRecipeSet.RowName or nil
    if type(set) ~= "string" or set == "" or set == "None" then return nil end
    return set
end

local function recipes()
    if recipes_loaded then return recipes_loaded end
    local data = Wax.import("engine.game").root.Data
    local rows = data:Table("ProcessorRecipes"):Load({ fields = M.RECIPE_FIELDS })
    recipes_loaded = rows
    return rows
end

-- The inputs of every recipe in a set: { [folded item] = spelling }. Pure, for the tests.
function M.inputs_of(set_name, rows)
    local wanted, out = fold(set_name), {}
    for _, recipe in pairs(rows or {}) do
        local fits = false
        for _, handle in ipairs(recipe.RecipeSets or {}) do
            if fold(handle.RowName) == wanted then fits = true break end
        end
        if fits then
            for _, input in ipairs(recipe.Inputs or {}) do
                local row = input.Element and input.Element.RowName
                if type(row) == "string" and row ~= "" and row ~= "None" then out[fold(row)] = row end
            end
        end
    end
    return out
end

-- What a station of this item row can process, as { [folded item] = spelling }, read from the game's tables once a
-- set. Reading the recipes the first time pauses the task; outside a task it answers nil and "reading".
function Containers:Accepted(row)
    if self ~= Containers then error("write game.Containers:Accepted(row) with a colon", 2) end
    if type(row) ~= "string" or row == "" then error("Accepted expects a structure's item row, such as \"Kit_Stone_Furnace\"", 2) end
    local set = set_of(row)
    if not set then return nil, "not a station" end
    local known = accepted_by_set[set]
    if known then return known, set end
    if not recipes_loaded and not co.isyieldable() then return nil, "reading" end
    local ok, rows = pcall(recipes)
    if not ok then
        log:warn("the recipes could not be read, so stations accept nothing: %s", clean(rows))
        return nil, "reading"
    end
    known = M.inputs_of(set, rows)
    accepted_by_set[set] = known
    return known, set
end

local function record_of(entry, distance)
    local parts = inventories_of(entry)
    local row = entry.variant or entry.kind
    local cargo = entry.kind and entry.kind:sub(1, 6) == "cargo:"
    local record = { Row = cargo and entry.kind or row, Name = shown_name(row, entry), Distance = distance, Actor = entry.instance,
        Inventories = parts.takes, Fuel = parts.fuel, Inputs = parts.inputs,
        Kind = parts.inputs and "station" or (cargo and "cargo" or "storage") }
    -- A cargo animal belongs to the player whose state is given (the game's own IsMountOwner); anything else is everyone's.
    function record:OwnedBy(state)
        if self.Kind ~= "cargo" then return true end
        local ok, yes = pcall(function() return self.Actor.Raw:IsMountOwner(state) end)
        return ok and yes == true
    end
    function record:Accepts(item)
        if self.Kind ~= "station" then return #self.Inventories > 0 end
        local accepted = Containers:Accepted(self.Row)
        return accepted ~= nil and accepted[fold(type(item) == "table" and item.Item or item)] ~= nil
    end
    return record
end

local function wanted_kind(options)
    local kind = options and options.kind
    if kind ~= nil and kind ~= "storage" and kind ~= "station" and kind ~= "cargo" then error("options.kind is \"storage\", \"station\" or \"cargo\"", 3) end
    return kind
end

-- The structures within `range` metres that can hold items, nearest first. options: kind = "storage" | "station",
-- holding = true for only those with something in them.
function Containers:Nearby(range, options)
    if self ~= Containers then error("write game.Containers:Nearby(range) with a colon", 2) end
    range = tonumber(range) or M.RANGE
    local kind = wanted_kind(options)
    local set = use()
    local at = here()
    if not at then return {} end
    local out = {}
    for _, entry in pairs(set.entries) do
        if entry.ready and not entry.destroyed then
            local place = place_of(entry.instance)
            local distance = place and metres_between(at, place)
            if distance and distance <= range then
                local record = record_of(entry, distance)
                local fits = (#record.Inventories > 0 or #record.Fuel > 0 or record.Inputs) and (not kind or record.Kind == kind)
                if fits and options and options.holding then
                    fits = false
                    for _, inventory in ipairs(record.Inventories) do
                        if (inventory.Used or 0) > 0 then fits = true break end
                    end
                    if not fits and record.Inputs and (record.Inputs.Used or 0) > 0 then fits = true end
                end
                if fits then out[#out + 1] = record end
            end
        end
    end
    table.sort(out, function(a, b) return a.Distance < b.Distance end)
    return out
end

-- The kinds of structure within range and how many of each: { Row, Name, Kind, Count }, by name.
function Containers:Kinds(range, options)
    if self ~= Containers then error("write game.Containers:Kinds(range) with a colon", 2) end
    local counts, first = {}, {}
    for _, record in ipairs(Containers:Nearby(range, options)) do
        local key = fold(record.Row)
        counts[key] = (counts[key] or 0) + 1
        first[key] = first[key] or record
    end
    local out = {}
    for key, count in pairs(counts) do
        local record = first[key]
        out[#out + 1] = { Row = record.Row, Name = record.Name, Kind = record.Kind, Count = count }
    end
    table.sort(out, function(a, b) return a.Name < b.Name end)
    return out
end

function Containers:Count()
    if self ~= Containers then error("write game.Containers:Count() with a colon", 2) end
    return use().count or 0
end

function M.start()
    rawset(Wax.import("engine.game").root, "Containers", Containers)
end

M.api = Containers
M.classify = classify
M.record_of = record_of
return M
