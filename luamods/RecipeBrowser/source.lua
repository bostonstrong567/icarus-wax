-- Every table and field the mod reads, in three load stages, over a provider shaped like game.Data.

local source = {}

local QUERY = { "Query.TagDictionary.TagName", "Query.QueryTokenStream" }
local LEVEL = { "RequiredFeatureLevel.RowName" }

-- rows: "all" (the default), "named" (only rows other tables name), "request" (read when asked), "names" (row names only)
local LISTS = {
    { table = "ItemsStatic", stage = 1, fields = { "Itemable.RowName", "Processing.RowName",
        "Manual_Tags.GameplayTags.TagName", "Generated_Tags.GameplayTags.TagName" }, maybe = { "CraftingExperience" } },
    { table = "Itemable", stage = 1, fields = { "DisplayName", "Icon", "Weight", "MaxStack" } },
    { table = "ItemTemplate", stage = 1, fields = { "ItemStaticData.RowName", "ItemCustomStats.Stat.Value", "ItemCustomStats.Value" } },
    { table = "FarmingSeeds", stage = 1, fields = { "Itemable.RowName" } },
    { table = "NationalFlags", stage = 1, fields = { "Item.RowName" } },
    { table = "FieldGuideCategories", stage = 1, fields = { "DisplayName", "DisplayOrder", "DisplayIcon", "TagQuery.RowName",
        "Subcategories.RowName" } },
    { table = "FieldGuideSubcategories", stage = 1, rows = "request", fields = { "DisplayName", "DisplayOrder", "TagQuery.RowName" } },
    { table = "TagQueries", stage = 1, rows = "named", fields = QUERY, always = { "FieldGuide_Hide" },
        from = { { "FieldGuideCategories", "TagQuery.RowName" } } },

    { table = "ProcessorRecipes", stage = 2, fields = { "Inputs.Element.RowName", "Inputs.Count", "Outputs.Element.RowName",
        "Outputs.Count", "QueryInputs.Query.RowName", "QueryInputs.Count", "ResourceInputs.Type.Value",
        "ResourceInputs.RequiredUnits", "ResourceOutputs.Type.Value", "ResourceOutputs.RequiredUnits", "RecipeSets.RowName",
        "Requirement.RowName", "CharacterRequirement.RowName", "SessionRequirement.RowName", "RequiredMillijoules",
        "bSelectOutputItemRandomly", "bForceDisableRecipe", "ItemIconOverride.ItemStaticData.RowName" },
        maybe = { "ExperienceMultiplier" } },
    { table = "RecipeSets", stage = 2, fields = { "RecipeSetName", "RecipeSetIcon" }, maybe = { "ExperienceMultiplier" } },
    { table = "Processing", stage = 2, fields = { "DefaultRecipeSet.RowName", "MaxMilliwattage", "AutoSelectRecipe" } },
    { table = "CraftingTags", stage = 2, fields = { "TagName", "TagIcon", "Query.RowName" } },
    { table = "TagQueries", stage = 2, rows = "named", fields = QUERY, from = { { "CraftingTags", "Query.RowName" } } },
    { table = "IcarusResources", stage = 2, fields = { "DisplayName", "Units", "Recipe_Icon" }, maybe = { "CraftingExperience" } },
    { table = "FieldGuideMetaData", stage = 2, fields = { "Item.RowName", "Description1", "Description2", "Description3" } },
    { table = "WorkshopItems", stage = 2, fields = { "Item.RowName" } },
    { table = "FieldGuideRedirect", stage = 2, fields = { "DisplayItem.RowName", "HiddenItems.RowName" } },

    { table = "Talents", stage = 3, fields = { "DisplayName", "ExtraData.RowName", "TalentTree.RowName", "RequiredLevel",
        "bDefaultUnlocked", "RequiredFlags.RowName", "Rewards.GrantedFlags.RowName" } },
    { table = "TalentTrees", stage = 3, fields = { "Archetype.RowName" } },
    { table = "TalentArchetypes", stage = 3, fields = { "DisplayName", "RequiredLevel" } },
    { table = "DLCPackageData", stage = 3, fields = { "DLCName" } },
    { table = "AccountFlags", stage = 3, fields = { "RewardedFromMissions.RowName" } },
    { table = "ProspectList", stage = 3, fields = { "DropName" } },
    { table = "CharacterFlags", stage = 3, rows = "names", fields = {} },
    { table = "SessionFlags", stage = 3, rows = "names", fields = {} },
    { table = "FeatureLevels", stage = 3, fields = { "DisplayName", "Icon" } },
    { table = "ItemsStatic", stage = 3, meta = true, fields = LEVEL },
    { table = "ProcessorRecipes", stage = 3, meta = true, fields = LEVEL },

    -- stage 4 is never read ahead: stats.lua asks for one row at a time with detail()
    { table = "Itemable", stage = 4, rows = "request", fields = { "Description", "FlavorText" } },
    { table = "ItemsStatic", stage = 4, rows = "request", fields = { "Itemable.RowName", "Durable.RowName", "Decayable.RowName",
        "ToolDamage.RowName", "FirearmData.RowName", "AmmoType.RowName", "Ballistic.RowName", "Armour.RowName",
        "Equippable.RowName", "Consumable.RowName", "Buildable.RowName", "Inventory.RowName", "Fillable.RowName",
        "AdditionalStats" } },
    { table = "Durable", stage = 4, rows = "request", fields = { "Max_Durability", "ItemsForRepair.Item.RowName",
        "ItemsForRepair.Amount" } },
    { table = "Decayable", stage = 4, rows = "request", fields = { "SpoilTime", "SpoiledItem.RowName" } },
    { table = "ToolDamage", stage = 4, rows = "request", fields = { "Melee_Damage", "DamageVariationPercentage", "Felling_Damage",
        "Felling_Efficiency", "Mining_Radius", "Mining_Efficiency", "Skinning_Efficiency", "Reaping_Efficiency",
        "Shattering_Damage", "Shattering_Efficiency" } },
    { table = "FirearmData", stage = 4, rows = "request", fields = { "ValidAmmoTypes.RowName", "AmmoCapacity", "RoundsPerMinute",
        "ReloadTime", "DamageMultiplier", "LaunchForce" } },
    { table = "ValidAmmoTypes", stage = 4, rows = "request", fields = { "Description" } },
    { table = "AmmoTypes", stage = 4, rows = "request", fields = { "ProjectileDamage", "ProjectileCount", "Stats" } },
    { table = "Ballistic", stage = 4, rows = "request", fields = { "Damage", "DamageVariationPercentage", "BreakChance" } },
    { table = "Armour", stage = 4, rows = "request", fields = { "ArmourStats", "ArmourSet.RowName" } },
    { table = "ArmourSets", stage = 4, rows = "request", fields = { "SetBonus.RowName" } },
    { table = "ArmourSetBonus", stage = 4, rows = "request", fields = { "RequiredGear", "Description", "StatsGranted" } },
    { table = "Equippable", stage = 4, rows = "request", fields = { "GrantedStats" } },
    { table = "Consumable", stage = 4, rows = "request", fields = { "Stats", "Modifier.Modifier.RowName",
        "Modifier.ModifierLifetime", "Byproducts.RowName" } },
    { table = "ModifierStates", stage = 4, rows = "request", fields = { "ModifierName", "ModifierDescription", "GrantedStats" } },
    { table = "Buildable", stage = 4, rows = "request", fields = { "Type.RowName" } },
    { table = "BuildingTypes", stage = 4, rows = "request", fields = { "Stats" } },
    { table = "Inventory", stage = 4, rows = "request", fields = { "Inventories.RowName" } },
    { table = "InventoryInfo", stage = 4, rows = "request", fields = { "StartingSlots" } },
    { table = "Fillable", stage = 4, rows = "request", fields = { "ResourceTypes.Value", "MaximumStoredUnits" } },
    { table = "Stats", stage = 4, rows = "request", fields = { "PositiveDescription", "NegativeDescription",
        "DisplayOperations.Operation", "DisplayOperations.Value", "bHideStatInUserInterface", "bShowStatOnModifiers" } },
}

source.STAGES = 3

function source.fold(name)
    if type(name) ~= "string" then return nil end
    return name:lower()
end

local fold = source.fold

-- The row a handle names, or nil for an empty one. Takes the handle or its RowName.
function source.ref(handle)
    local name = handle
    if type(handle) == "table" then name = handle.RowName end
    if type(name) ~= "string" or name == "" or name:lower() == "none" then return nil end
    return name
end

local ref = source.ref

-- The lists of the load stages. With `asked`, those of stage 4 as well. maybe: fields read only while the game has them.
function source.lists(asked)
    local out = {}
    for _, entry in ipairs(LISTS) do
        if asked or entry.stage <= source.STAGES then
            local copy = { table = entry.table, stage = entry.stage, rows = entry.rows or "all", meta = entry.meta or false, fields = {},
                maybe = {} }
            for position, field in ipairs(entry.fields) do copy.fields[position] = field end
            for position, field in ipairs(entry.maybe or {}) do copy.maybe[position] = field end
            out[#out + 1] = copy
        end
    end
    return out
end

local function gather(value, parts, depth, out)
    if type(value) ~= "table" then return end
    if depth > #parts then return end
    local inner = value[parts[depth]]
    if depth == #parts then
        if inner ~= nil then out[#out + 1] = inner end
        return
    end
    if type(inner) ~= "table" or next(inner) == nil then return end
    if #inner > 0 then
        for position = 1, #inner do gather(inner[position], parts, depth + 1, out) end
    else
        gather(inner, parts, depth + 1, out)
    end
end

-- Every value a dotted path leads to in one row, passing through lists.
function source.values(row, path)
    local parts = {}
    for part in path:gmatch("[^.]+") do parts[#parts + 1] = part end
    local out = {}
    gather(row, parts, 1, out)
    return out
end

-- lists: a list like LISTS to read in its place. An entry's maybe = { fields } are read only while the provider serves them.
function source.new(provider, lists)
    lists = lists or LISTS
    local self = { problems = {}, broken = {} }
    local tables, names, index, rows, whole, levels, noted, checked = {}, {}, {}, {}, {}, {}, {}, {}
    local details, asked, ready, serving = {}, {}, {}, {}
    local FIELDS, DETAIL = {}, {}
    for _, entry in ipairs(lists) do
        if entry.stage > source.STAGES then
            DETAIL[entry.table] = entry
        elseif not entry.meta then
            FIELDS[entry.table] = entry
        end
    end

    -- A table is broken when it is missing or lost a field. A MetaTable that fails does not break its table.
    local function problem(name, field, message, beside)
        local key = name .. "." .. (field or "")
        if not beside then self.broken[name] = true end
        if noted[key] then return end
        noted[key] = true
        self.problems[#self.problems + 1] = { table = name, field = field, message = tostring(message or "") }
    end

    local function open(name)
        local known = tables[name]
        if known ~= nil then return known or nil end
        local ok, found = pcall(function()
            if provider.Has and not provider:Has(name) then return nil end
            return provider:Table(name)
        end)
        if not ok or not found then
            problem(name, nil, ok and "the table is missing" or found)
            tables[name] = false
            return nil
        end
        tables[name] = found
        return found
    end

    function self.names(name)
        local list = names[name]
        if list then return list end
        list = {}
        local opened = open(name)
        if opened then
            local ok, got = pcall(opened.GetNames, opened)
            if ok and type(got) == "table" then list = got else problem(name, nil, got) end
        end
        local map = {}
        for position = 1, #list do map[fold(list[position])] = position end
        names[name], index[name] = list, map
        return list
    end

    function self.has(name, row)
        local key = fold(row)
        if not key then return false end
        self.names(name)
        return index[name][key] ~= nil
    end

    function self.position(name, row)
        local key = fold(row)
        if not key then return nil end
        self.names(name)
        return index[name][key]
    end

    -- The fields the table still has. Each one it lost is noted once.
    local function usable(opened, name, fields, beside)
        local known = checked[name]
        if known and known.asked == fields then return known.good end
        local first = self.names(name)[1]
        if not first or #fields == 0 then return fields end
        local good = fields
        if not pcall(opened.Row, opened, first, fields) then
            good = {}
            for _, field in ipairs(fields) do
                local ok, message = pcall(opened.Row, opened, first, { field })
                if ok then good[#good + 1] = field else problem(name, field, message, beside) end
            end
            if #good == #fields then good = fields end
        end
        checked[name] = { asked = fields, good = good }
        return good
    end

    -- What one list entry reads: its usable fields, and each maybe field the provider gave when it was tried alone.
    local function fields_of(opened, name, entry, beside)
        local known = ready[entry]
        if known then return known end
        local good = usable(opened, name, entry.fields, beside)
        local first = entry.maybe and self.names(name)[1]
        if first then
            local all = {}
            for position = 1, #good do all[position] = good[position] end
            for _, field in ipairs(entry.maybe) do
                if pcall(opened.Row, opened, first, { field }) then
                    all[#all + 1] = field
                    serving[name .. "." .. field] = true
                end
            end
            good = all
        end
        ready[entry] = good
        return good
    end

    -- True when a maybe field of a table is being read.
    function self.serves(name, field)
        for _, entry in ipairs({ DETAIL[name] or false, FIELDS[name] or false }) do
            local opened = entry and entry.maybe and open(name)
            if opened then fields_of(opened, name, entry, entry == DETAIL[name]) end
        end
        return serving[name .. "." .. field] == true
    end

    local function keep(name, got)
        local store = rows[name]
        if not store then
            store = {}
            rows[name] = store
        end
        for row, value in pairs(got) do store[fold(row)] = value end
    end

    -- entry: the list entry the fields are from, when read() asks.
    function self.load(name, fields, wanted, budget, entry)
        local opened = open(name)
        if not opened then return {} end
        self.names(name)
        if not fields then entry = FIELDS[name] end
        if entry then
            fields = fields_of(opened, name, entry)
        else
            fields = usable(opened, name, fields or {})
        end
        local ok, got = pcall(opened.Load, opened, { fields = fields, names = wanted, budget = budget })
        if not ok or type(got) ~= "table" then
            problem(name, nil, got)
            return {}
        end
        keep(name, got)
        if not wanted then whole[name] = true end
        return got
    end

    function self.row(name, row)
        local key = fold(row)
        if not key then return nil end
        local store = rows[name]
        local found = store and store[key]
        if found ~= nil then return found or nil end
        if whole[name] or not self.has(name, row) then return nil end
        local opened = open(name)
        if not opened then return nil end
        local entry = FIELDS[name]
        local fields = entry and fields_of(opened, name, entry) or {}
        local ok, got = pcall(opened.Row, opened, row, fields)
        if not ok then
            problem(name, nil, got)
            got = nil
        end
        if not store then
            store = {}
            rows[name] = store
        end
        store[key] = got or false
        return got
    end

    -- One row of a stage 4 table with that stage's fields, read the first time it is asked for.
    function self.detail(name, row)
        local key = fold(row)
        if not key or not DETAIL[name] then return nil end
        local store = details[name]
        if not store then
            store = {}
            details[name] = store
        end
        local found = store[key]
        if found ~= nil then return found or nil end
        local opened = open(name)
        if opened and self.has(name, row) then
            if not asked[name] then asked[name] = fields_of(opened, name, DETAIL[name], true) end
            -- an entry of maybe fields alone, all refused, reads nothing
            if #asked[name] > 0 or #DETAIL[name].fields > 0 then
                local ok, got = pcall(opened.Row, opened, row, asked[name])
                if ok then found = got else problem(name, nil, got, true) end
            end
        end
        store[key] = found or false
        return found or nil
    end

    -- The feature level a row asks for: from the table's MetaTable, or from the row's own Metadata block.
    function self.level(name, row)
        local key = fold(row)
        if not key then return nil end
        local found
        local store = levels[name]
        if store then
            found = store[key]
        else
            local plain = self.row(name, row)
            found = plain and rawget(plain, "Metadata")
        end
        return found and ref(found.RequiredFeatureLevel) or nil
    end

    function self.stamp(name)
        local opened = open(name)
        if not opened then return "" end
        local ok, stamp = pcall(opened.Stamp, opened)
        return ok and tostring(stamp) or ""
    end

    function self.stamps()
        local seen, parts = {}, {}
        for _, entry in ipairs(lists) do
            if entry.stage <= source.STAGES and not seen[entry.table] then
                seen[entry.table] = true
                parts[#parts + 1] = entry.table .. "=" .. self.stamp(entry.table)
            end
        end
        return table.concat(parts, ";")
    end

    local function wanted(entry)
        local list, seen = {}, {}
        local function add(row)
            local key = fold(ref(row))
            if key and not seen[key] and self.has(entry.table, row) then
                seen[key] = true
                list[#list + 1] = row
            end
        end
        for _, row in ipairs(entry.always or {}) do add(row) end
        for _, pair in ipairs(entry.from or {}) do
            for _, name in ipairs(self.names(pair[1])) do
                for _, row in ipairs(source.values(self.row(pair[1], name), pair[2])) do add(row) end
            end
        end
        return list
    end

    local function load_levels(entry, budget)
        local opened = open(entry.table)
        if not opened then return end
        local ok, meta = pcall(function() return opened:Meta() end)
        if not ok or not meta then return end
        local loaded, got = pcall(meta.Load, meta, { fields = entry.fields, budget = budget })
        if not loaded or type(got) ~= "table" then
            problem(entry.table, "MetaTable", got, true)
            return
        end
        local store = {}
        for row, value in pairs(got) do store[fold(row)] = value end
        levels[entry.table] = store
    end

    -- Reads one stage. The budget is milliseconds a frame, or a function that gives them. between() runs after each table.
    function self.read(stage, budget, between)
        for _, entry in ipairs(lists) do
            if entry.stage == stage then
                local ms = budget
                if type(budget) == "function" then ms = budget() end
                local mode = entry.rows or "all"
                if entry.meta then
                    load_levels(entry, ms)
                elseif mode == "names" then
                    self.names(entry.table)
                elseif mode == "request" then
                    local opened = open(entry.table)
                    if opened then fields_of(opened, entry.table, entry) end
                elseif mode == "named" then
                    local list = wanted(entry)
                    if #list > 0 then self.load(entry.table, entry.fields, list, ms, entry) end
                else
                    self.load(entry.table, entry.fields, nil, ms, entry)
                end
                if between then between() end
            end
        end
        return self
    end

    function self.read_all(budget)
        for stage = 1, source.STAGES do self.read(stage, budget) end
        return self
    end

    return self
end

return source
