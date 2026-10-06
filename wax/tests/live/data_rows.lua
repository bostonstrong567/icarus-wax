-- Live test of game.Data. Rows read through it are compared with the same fields read straight from the engine,
-- so a balance patch cannot fail it. It only reads. Send with:  node wax/cli/wax.mjs eval --file wax/tests/live/data_rows.lua
-- Every direct read below is one the probes already made in this game. Two things are left out unless asked for,
-- because they were not: set WaxDataRowsFull = true first to also read every readable field of two rows and one enum.
-- If build\recipe-browser\check\samples.lua is found (scripts\recipe_check.py writes it), its numbers and handle names
-- are compared too: a list of { table, row, values }, where values[path] lists what that field path holds in the row.

local game = Wax.game
local Data = rawget(game, "Data")
if not Data then
    return { passed = 0, failed = 1, details = {},
             failures = { "game.Data is not there: add the data.tables line to boot.lua, then send dev_start_core.lua" } }
end

local now = Wax.perf.now
local FULL = rawget(_G, "WaxDataRowsFull") == true
local checks = {}
local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end
local function attempt(name, fn)
    local ok, a, b = pcall(fn)
    if ok then check(name, a, b) else check(name, false, "raised: " .. tostring(a)) end
end

-- the direct reads: lengths first, and only names the game itself listed
local function text(value) return value:ToString() end
local function soft(value)
    local path = value:GetObjectID():GetAssetPathName():ToString()
    if path == "None" or path == "" then return nil end
    return path
end
local function list(array, read)
    local out, count = {}, array:GetArrayNum()
    for i = 1, count do out[i] = read(array[i]) end
    return out
end
local function handle(value) return { RowName = text(value.RowName) } end
local function counted(key)
    return function(element) return { [key] = handle(element[key]), Count = element.Count } end
end

local TABLES = {
    { name = "ProcessorRecipes", rows = { "Bone_Knife", "Dough_Bread", "Gold_Bed" },
      fields = { "Inputs.Element.RowName", "Inputs.Count", "Outputs.Element.RowName", "Outputs.Count", "RecipeSets.RowName",
                 "QueryInputs.Query.RowName", "QueryInputs.Count", "ResourceInputs.Type.Value", "ResourceInputs.RequiredUnits",
                 "Requirement.RowName", "SessionRequirement.RowName", "RequiredMillijoules", "bForceDisableRecipe" },
      direct = function(row)
          return {
              Inputs = list(row.Inputs, counted("Element")), Outputs = list(row.Outputs, counted("Element")),
              QueryInputs = list(row.QueryInputs, counted("Query")), RecipeSets = list(row.RecipeSets, handle),
              ResourceInputs = list(row.ResourceInputs, function(element)
                  return { Type = { Value = text(element.Type.Value) }, RequiredUnits = element.RequiredUnits }
              end),
              Requirement = handle(row.Requirement), SessionRequirement = handle(row.SessionRequirement),
              RequiredMillijoules = row.RequiredMillijoules, bForceDisableRecipe = row.bForceDisableRecipe,
          }
      end },
    { name = "Itemable", rows = { "Item_Wood", "Item_Fiber" }, fields = { "DisplayName", "Icon", "Weight", "MaxStack" },
      direct = function(row)
          return { DisplayName = text(row.DisplayName), Icon = soft(row.Icon), Weight = row.Weight, MaxStack = row.MaxStack }
      end },
    { name = "ItemsStatic", rows = { "Wood", "Fish_03" }, fields = { "Itemable.RowName", "Generated_Tags.GameplayTags.TagName" },
      direct = function(row)
          return { Itemable = handle(row.Itemable), Generated_Tags = {
              GameplayTags = list(row.Generated_Tags.GameplayTags, function(tag) return { TagName = text(tag.TagName) } end) } }
      end },
    { name = "RecipeSets", rows = { "Character" }, fields = { "RecipeSetName", "RecipeSetIcon", "ExperienceMultiplier" },
      direct = function(row)
          return { RecipeSetName = text(row.RecipeSetName), RecipeSetIcon = soft(row.RecipeSetIcon),
                   ExperienceMultiplier = row.ExperienceMultiplier }
      end },
}

-- The first place where `got` does not hold what `expected` holds, or nil.
local function differs(expected, got, where)
    if type(expected) ~= "table" then
        if expected ~= got then return ("%s: %s directly, %s through game.Data"):format(where, tostring(expected), tostring(got)) end
        return nil
    end
    if type(got) ~= "table" then return ("%s: a table directly, %s through game.Data"):format(where, type(got)) end
    if #expected ~= #got then return ("%s: %d directly, %d through game.Data"):format(where, #expected, #got) end
    for key, value in pairs(expected) do
        local problem = differs(value, got[key], where .. "." .. tostring(key))
        if problem then return problem end
    end
    return nil
end

local function is_plain(value)
    local kind = type(value)
    if kind == "table" then
        if getmetatable(value) then return false end
        for key, item in pairs(value) do
            if not (is_plain(key) and is_plain(item)) then return false end
        end
        return true
    end
    return kind == "string" or kind == "number" or kind == "boolean"
end

local function values_in(value)
    if type(value) ~= "table" then return 1 end
    local n = 0
    for _, item in pairs(value) do n = n + values_in(item) end
    return n
end

attempt("the game's tables are listed", function()
    local started = now()
    local names = Data:GetTables()
    return #names >= 250 and Data:Has("ProcessorRecipes") and Data:Has("D_Itemable") and not Data:Has("NoSuchTable_xyz"),
        ("%d tables in %.2f ms"):format(#names, (now() - started) * 1000)
end)

local compared, opened = 0, {}
for _, spec in ipairs(TABLES) do
    attempt(spec.name .. " opens, and its count and stamp are the engine's", function()
        local started = now()
        local found = Data:Table(spec.name)
        local took = (now() - started) * 1000
        local direct = StaticFindObject("/Engine/Transient.D_" .. spec.name)
        if not direct:IsValid() then return false, "the table is not at /Engine/Transient.D_" .. spec.name end
        local count, stamp = #direct, found:Stamp()
        spec.found, spec.index = found, {}
        for _, name in ipairs(found:GetNames()) do spec.index[name:lower()] = name end
        opened[#opened + 1] = spec
        return found:Count() == count and stamp:match("^(%d+):0x%x+$") == tostring(count)
            and Data:Table("D_" .. spec.name:lower()) == found and type(found.RowStruct) == "string",
            ("%d rows, struct %s, stamp %s, opened in %.2f ms"):format(count, tostring(found.RowStruct), stamp, took)
    end)
end

for _, spec in ipairs(opened) do
    -- the rows named above when the game has them, and the first, middle and last one
    local names, wanted, taken = spec.found:GetNames(), {}, {}
    local function want(name)
        local real = name and spec.index[name:lower()]
        if real and not taken[real] then
            taken[real] = true
            wanted[#wanted + 1] = real
        end
    end
    for _, name in ipairs(spec.rows) do want(name) end
    want(names[1])
    want(names[#names // 2 + 1])
    want(names[#names])
    for _, name in ipairs(wanted) do
        attempt(("%s.%s is the same through game.Data as read directly"):format(spec.name, name), function()
            local direct = StaticFindObject("/Engine/Transient.D_" .. spec.name)
            local row = direct:FindRow(name)
            if row == nil then return false, "the engine has no such row" end
            local expected = spec.direct(row)
            local started = now()
            local got = spec.found:Row(name, spec.fields)
            local took = (now() - started) * 1000
            if got == nil then return false, "game.Data gave nil" end
            compared = compared + 1
            local problem = differs(expected, got, name)
            if problem then return false, problem end
            if not is_plain(got) then return false, "the row holds something that is not a plain value" end
            if spec.found:Row(name:upper(), spec.fields) ~= got then return false, "another letter case gave another table" end
            -- read again directly: nothing was made longer by the read
            if differs(spec.direct(direct:FindRow(name)), got, name) then return false, "the row changed while it was read" end
            return got.Name == name, ("%d values in %.3f ms"):format(values_in(got), took)
        end)
    end
end

attempt("at least ten rows were compared", function() return compared >= 10, compared .. " rows" end)

attempt("a row that is held is given again without asking the engine", function()
    local spec = opened[1]
    if not spec then return false, "no table opened" end
    local name = spec.found:GetNames()[1]
    local first = spec.found:Row(name, spec.fields)
    local started = now()
    for _ = 1, 1000 do
        if spec.found:Row(name, spec.fields) ~= first then return false, "another table" end
    end
    return true, ("%.2f us a call"):format((now() - started) / 1000 * 1e6)
end)

attempt("an unknown row is nil, and an unknown table or field is an error with a suggestion", function()
    local recipes = Data:Table("ProcessorRecipes")
    local no_table, table_problem = pcall(function() return Data:Table("ProcessorRecipez") end)
    local no_field, field_problem = pcall(function() return recipes:Row(recipes:GetNames()[1], { "Input.Count" }) end)
    return recipes:Row("NoSuchRow_xyz") == nil and not recipes:Has("NoSuchRow_xyz")
        and not no_table and tostring(table_problem):find("ProcessorRecipes", 1, true) ~= nil
        and not no_field and tostring(field_problem):find("Inputs", 1, true) ~= nil,
        tostring(table_problem) .. " | " .. tostring(field_problem)
end)

attempt("Fields says what the probes saw of a recipe", function()
    local by, count = {}, 0
    for _, field in ipairs(Data:Table("ProcessorRecipes"):Fields()) do
        by[field.Name] = field
        count = count + 1
    end
    local inputs, session, refund = by.Inputs or {}, by.SessionRequirement or {}, by.Refundable or {}
    return inputs.Kind == "Array" and inputs.Inner == "Struct" and inputs.Struct == "CraftingInput"
        and session.Struct == "FlagsMultiRowHandle" and refund.Kind == "Enum" and by.RequiredMillijoules.Kind == "Int",
        ("%d fields. Inputs: %s of %s %s. SessionRequirement: %s. Refundable: %s"):format(count, tostring(inputs.Kind),
            tostring(inputs.Inner), tostring(inputs.Struct), tostring(session.Struct), tostring(refund.Kind))
end)

local handle_names_table = false
attempt("a handle read whole names its table, and Resolve follows it", function()
    local recipes = Data:Table("ProcessorRecipes")
    local name = recipes:Has("Bone_Knife") and "Bone_Knife" or recipes:GetNames()[1]
    local row = recipes:Row(name, { "Inputs.Element" })
    local first = row.Inputs[1]
    if not first then return false, name .. " has no inputs" end
    handle_names_table = type(first.Element.DataTableName) == "string" and first.Element.DataTableName ~= "None"
    if not handle_names_table then return false, "DataTableName reads as " .. tostring(first.Element.DataTableName) end
    local target, from = Data:Resolve(first.Element, { "Itemable.RowName" })
    return target ~= nil and from ~= nil and target.Name:lower() == first.Element.RowName:lower(),
        ("%s x%s -> %s.%s"):format(first.Element.RowName, tostring(first.Count), tostring(first.Element.DataTableName),
            tostring(target and target.Name))
end)

attempt("the meta table of ItemsStatic gives the same as its MetaTable read directly", function()
    local items = Data:Table("ItemsStatic")
    local meta = items:Meta()
    local direct = StaticFindObject("/Engine/Transient.D_ItemsStatic").MetaTable
    if not direct:IsValid() then return meta == nil, "the game has no meta table for ItemsStatic" end
    if not meta then return false, "Meta() gave nil" end
    local names, seen = meta:GetNames(), 0
    for _, name in ipairs({ names[1], names[#names // 2 + 1], names[#names] }) do
        local row = direct:FindRow(name)
        if row == nil then return false, "the engine has no meta row " .. name end
        local got = meta:Row(name, { "RequiredFeatureLevel.RowName", "bIsDeprecated" })
        local problem = got == nil and (name .. ": game.Data gave nil") or differs({
            RequiredFeatureLevel = handle(row.RequiredFeatureLevel), bIsDeprecated = row.bIsDeprecated }, got, name)
        if problem then return false, problem end
        seen = seen + 1
    end
    return meta:Count() == #direct and Data:Table("ProcessorRecipes").Name == "ProcessorRecipes",
        ("%s: %d rows, %d compared, struct %s"):format(meta.Name, meta:Count(), seen, tostring(meta.RowStruct))
end)

-- numbers and handle names from the files the workspace exported, when they can be found from here
local function find_samples()
    local given = rawget(_G, "WaxDataSamples")
    if type(given) == "table" then return given, "WaxDataSamples" end
    local tail = "/../../build/recipe-browser/check/samples.lua"
    local places = { Wax.root .. tail }
    if type(given) == "string" then table.insert(places, 1, given) end
    -- the game reaches Wax through a link, so ".." from Wax.root stays in the game's folder: go by where the mods really are
    local index = loadfile(Wax.root .. "/run/mods.index.lua")
    local ok, listed = false, nil
    if index then ok, listed = pcall(index) end
    if ok and type(listed) == "table" and type(listed.mods) == "table" then
        for _, mod in ipairs(listed.mods) do
            if type(mod.dir) == "string" then places[#places + 1] = mod.dir .. tail end
        end
    end
    for _, place in ipairs(places) do
        local chunk = loadfile(place)
        if chunk then
            local fine, samples = pcall(chunk)
            if fine and type(samples) == "table" then return samples, place end
        end
    end
    return nil
end

-- Every number, boolean and name a dotted path leads to in a row, passing through lists, in order.
local function along(value, parts, at, out)
    if value == nil then return end
    if at > #parts then
        if type(value) == "table" then
            for i = 1, #value do
                if type(value[i]) == "number" then out[#out + 1] = value[i] end
            end
        else
            out[#out + 1] = value
        end
    elseif type(value) == "table" then
        if #value > 0 then
            for i = 1, #value do along(value[i], parts, at, out) end
        else
            along(value[parts[at]], parts, at + 1, out)
        end
    end
end

local function same_value(want, have)
    if type(want) == "number" and type(have) == "number" then return math.abs(want - have) <= 1e-6 * math.max(1, math.abs(want)) end
    -- names keep the letter case the engine first saw them in
    if type(want) == "string" and type(have) == "string" then return want:lower() == have:lower() end
    return want == have
end

attempt("the exported samples agree with the game", function()
    local samples, place = find_samples()
    if not samples then return true, "skipped: build/recipe-browser/check/samples.lua was not found from the game" end
    local rows, values_seen = 0, 0
    for _, entry in ipairs(samples) do
        local table_name, row_name, values = entry.table, entry.row, entry.values
        if type(table_name) ~= "string" or type(row_name) ~= "string" or type(values) ~= "table" then
            return false, "an entry of " .. tostring(place) .. " is not { table, row, values }"
        end
        local where = table_name .. "." .. row_name
        if not Data:Has(table_name) then return false, "the game has no table " .. table_name end
        local fields = {}
        for path in pairs(values) do fields[#fields + 1] = path end
        table.sort(fields)
        local got = Data:Table(table_name):Row(row_name, fields)
        if got == nil then return false, where .. " is in the samples and not in the game" end
        for _, path in ipairs(fields) do
            local parts, have, want = {}, {}, values[path]
            for part in path:gmatch("[^%.]+") do parts[#parts + 1] = part end
            along(got, parts, 1, have)
            local problem = #want ~= #have and ("%d values in the samples, %d in the game"):format(#want, #have) or nil
            for i = 1, problem and 0 or #want do
                if not same_value(want[i], have[i]) then
                    problem = ("%s in the samples, %s in the game"):format(tostring(want[i]), tostring(have[i]))
                    break
                end
            end
            if problem then
                return false, ("%s.%s: %s (was the game updated after the last Export-GameData.ps1?)"):format(where, path, problem)
            end
            values_seen = values_seen + #want
        end
        rows = rows + 1
    end
    return rows > 0, ("%d rows, %d values, from %s"):format(rows, values_seen, tostring(place))
end)

if FULL then
    for _, pick in ipairs({ { "ProcessorRecipes", "Bone_Knife" }, { "Itemable", "Item_Wood" } }) do
        attempt(("every readable field of one row of %s"):format(pick[1]), function()
            local found = Data:Table(pick[1])
            local name = found:Has(pick[2]) and pick[2] or found:GetNames()[1]
            local started = now()
            local row = found:Row(name)
            local took = (now() - started) * 1000
            if row == nil then return false, "nil: the log names the field that could not be read" end
            return is_plain(row) and found:Row(name) == row, ("%s: %d values in %.3f ms"):format(name, values_in(row), took)
        end)
    end
    attempt("an enum is read when its path is named", function()
        local recipes = Data:Table("ProcessorRecipes")
        local name = recipes:Has("Gold_Bed") and "Gold_Bed" or recipes:GetNames()[1]
        local row = recipes:Row(name, { "Refundable", "SessionRequirement.DataTableName" })
        return row ~= nil and type(row.Refundable) == "number" and type(row.SessionRequirement.DataTableName) == "number",
            ("%s: Refundable %s, SessionRequirement.DataTableName %s"):format(name, tostring(row and row.Refundable),
                tostring(row and row.SessionRequirement.DataTableName))
    end)
else
    check("every readable field of a row, and an enum by name", true,
        "skipped: these reads were not made in this game before. Set WaxDataRowsFull = true and send again")
end

local passed, failed = 0, {}
for _, c in ipairs(checks) do
    if c.ok then passed = passed + 1 else failed[#failed + 1] = c.name .. " :: " .. tostring(c.detail) end
end
local details = {}
for _, c in ipairs(checks) do
    details[#details + 1] = (c.ok and "ok   " or "FAIL ") .. c.name .. (c.detail and ("  [" .. tostring(c.detail):sub(1, 220) .. "]") or "")
end
return { passed = passed, failed = #failed, failures = failed, details = details, handles_name_their_table = handle_names_table,
         stats = Wax.import("data.tables").stats() }
