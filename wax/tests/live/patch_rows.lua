-- Live test of data.patch: changing rows of the game's tables through game.Data.
-- Everything is written into one scratch row that this file adds to D_ProcessorRecipes and takes out again in the same call.
-- No row of the game is written. The scratch row is only there for the length of this call, so no code of the game runs while it is.
-- The scratch row itself is put in and taken out with AddRow and RemoveRow whatever the switches in data.patch (WRITES) say.
-- The switches decide what is then written into it: a kind of write that is off is only checked to be refused in plain words.
-- AddRow and RemoveRow were only seen at the title screen, so this file refuses to run anywhere else.
-- Send it at the title screen with:  node wax/cli/wax.mjs eval --file wax/tests/live/patch_rows.lua
-- WaxPatchRowsAnywhere = true lets it run in a prospect. Only with the owner's word for that occasion, on the test character, saves backed up.
-- Each step is noted in run\session.log before it is made.
-- game.Data.Changed fires for ProcessorRecipes at the end of the frame, so mods that keep recipes read them once more.
-- Set WaxPatchRowsAdd = true first to also add a row the way mods do: Add, then the game's own index. That row is switched
-- off again before this file returns, and it stays in the table until the game closes.

local game = Wax.game
local Data = rawget(game, "Data")
local tables = Wax.import("data.tables")
local patch = tables.writer
if not Data or not patch then
    return { passed = 0, failed = 1, details = {},
             failures = { "data.patch has not started: add its line to boot.lua, then send dev_start_core.lua" } }
end

local ANYWHERE = rawget(_G, "WaxPatchRowsAnywhere") == true
local map_known, map = pcall(function() return game.MapName end)
if not ANYWHERE and not (map_known and map == patch.TITLE) then
    return { passed = 0, failed = 1, details = {}, writes = patch.WRITES,
             failures = { ("the scratch row is put in and taken out with AddRow and RemoveRow, which the game was only seen to take "
                 .. "at the title screen, and the map is %s: send this there"):format(map_known and tostring(map) or "not known") } }
end

local T = tables.internal
local scope = Wax.import("core.scope")
local note = Wax.import("core.blackbox").note
local now = Wax.perf.now
local SCRATCH, OWNER = "WaxPatchTest_Scratch", "WaxPatchTest"
local ADD = rawget(_G, "WaxPatchRowsAdd") == true

local checks = {}
local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end
local function attempt(name, fn)
    note("patch_rows: " .. name)
    local ok, a, b = pcall(fn)
    if ok then check(name, a, b) else check(name, false, "raised: " .. tostring(a)) end
end
local function result()
    local passed, failed, details = 0, {}, {}
    for _, c in ipairs(checks) do
        if c.ok then passed = passed + 1 else failed[#failed + 1] = c.name .. " :: " .. tostring(c.detail) end
        details[#details + 1] = (c.ok and "ok   " or "FAIL ") .. c.name .. (c.detail and ("  [" .. tostring(c.detail):sub(1, 220) .. "]") or "")
    end
    return { passed = passed, failed = #failed, failures = failed, details = details, writes = patch.WRITES, stats = patch.stats() }
end

local recipes = Data:Table("ProcessorRecipes")
local record, dt = T.live(recipes)
local has = {}
for _, field in ipairs(recipes:Fields()) do has[field.Name] = field end

-- the row the scratch row is a copy of: one with a resource input, so a list the game has to make is covered too
local source = nil
for _, name in ipairs({ "Frag_Grenade", "Dough_Bread" }) do
    if not source and recipes:Has(name) then source = name end
end
source = source or recipes:GetNames()[1]
if recipes:Has(SCRATCH) or not source then
    check("a clean start", false, "the table has no row to copy, or a scratch row was left behind: " .. SCRATCH)
    return result()
end

-- direct reads, by length and only of fields the game declares
local function text(value) return value:ToString() end
local function raw() return dt:FindRow(SCRATCH) end
local function print_of(row)
    local parts = {}
    if has.RequiredMillijoules then parts[#parts + 1] = tostring(row.RequiredMillijoules) end
    if has.bForceDisableRecipe then parts[#parts + 1] = tostring(row.bForceDisableRecipe) end
    if has.Requirement then parts[#parts + 1] = text(row.Requirement.RowName) .. "@" .. text(row.Requirement.DataTableName) end
    if has.Inputs then
        local list = row.Inputs
        for index = 1, list:GetArrayNum() do
            local entry = list[index]
            parts[#parts + 1] = text(entry.Element.RowName) .. "x" .. entry.Count
        end
    end
    if has.RecipeSets then
        local list = row.RecipeSets
        for index = 1, list:GetArrayNum() do parts[#parts + 1] = "at " .. text(list[index].RowName) end
    end
    if has.ResourceInputs then
        local list = row.ResourceInputs
        for index = 1, list:GetArrayNum() do
            local entry = list[index]
            parts[#parts + 1] = text(entry.Type.Value) .. "=" .. entry.RequiredUnits
        end
    end
    return table.concat(parts, "|")
end
local function refused(fn, fragment)
    local ok, problem = pcall(fn)
    return not ok and tostring(problem):find(fragment, 1, true) ~= nil, tostring(problem)
end
-- Makes a change. False and the reason when this version has that kind of change switched off, which is no failure.
local function made(fn)
    local ok, problem = pcall(fn)
    if ok then return true end
    if tostring(problem):find("switched off", 1, true) then return false, "not tried: " .. tostring(problem) end
    error(problem, 0)
end
local function pick(table_name, avoid)
    if not Data:Has(table_name) then return nil end
    for _, name in ipairs(Data:Table(table_name):GetNames()) do
        if name:lower() ~= "none" and not avoid[name:lower()] then return name end
    end
    return nil
end

local before, source_print = #dt, print_of(dt:FindRow(source))
local count_before, changes_before, stamp_before = recipes:Count(), #recipes:Changes(), recipes:Stamp()
local owner = scope.new(OWNER)
local added = false

local function body()
    attempt("a scratch row is added as a copy of " .. source, function()
        dt:AddRow(SCRATCH, dt:FindRow(source))
        added = true
        T.row_added(record, SCRATCH, dt)
        return #dt == before + 1 and raw() ~= nil and recipes:Has(SCRATCH) and print_of(raw()) == source_print, print_of(raw())
    end)
    if not added then return end

    if patch.WRITES.plain then
        attempt("a whole number is written and read back", function()
            local started = now()
            recipes:Set(SCRATCH, "RequiredMillijoules", 4321)
            local took = (now() - started) * 1000
            return raw().RequiredMillijoules == 4321 and recipes:Row(SCRATCH, { "RequiredMillijoules" }).RequiredMillijoules == 4321,
                ("%.3f ms"):format(took)
        end)
        if has.ExperienceMultiplier then
            attempt("a float is written", function()
                recipes:Set(SCRATCH, "ExperienceMultiplier", 2.5)
                return math.abs(raw().ExperienceMultiplier - 2.5) < 0.0001, raw().ExperienceMultiplier
            end)
        end
        attempt("a switch is written and its neighbours stay", function()
            local others = {}
            for _, name in ipairs({ "bSelectOutputItemRandomly", "bContainsContainer" }) do
                if has[name] then others[name] = raw()[name] end
            end
            recipes:Set(SCRATCH, "bForceDisableRecipe", true)
            for name, value in pairs(others) do
                if raw()[name] ~= value then return false, name .. " changed too" end
            end
            return raw().bForceDisableRecipe == true and raw().RequiredMillijoules == 4321
        end)
        if has.Refundable then
            attempt("an enum is written by its number, and by its name when UE4SS gave the names", function()
                recipes:Set(SCRATCH, "Refundable", 1)
                local by_number = raw().Refundable
                rawset(_G, "Enum_Refundable", nil)
                local named, problem = pcall(function() recipes:Set(SCRATCH, "Refundable", "Allow") end)
                local by_name = raw().Refundable
                rawset(_G, "Enum_Refundable", nil)
                return by_number == 1 and (not named or by_name == 2),
                    named and ("by name: " .. tostring(by_name)) or ("names not known: " .. tostring(problem))
            end)
        end
        attempt("a value of the wrong kind is refused and nothing is written", function()
            local ok, problem = refused(function() recipes:Set(SCRATCH, "RequiredMillijoules", 1.5) end, "whole number")
            return ok and raw().RequiredMillijoules == 4321, problem
        end)
    else
        attempt("plain fields are refused while they are switched off", function()
            return refused(function() recipes:Set(SCRATCH, "RequiredMillijoules", 4321) end, "switched off")
        end)
    end

    if patch.WRITES.names then
        local talent = has.Requirement and pick("Talents", { [text(raw().Requirement.RowName):lower()] = true })
        if talent then
            attempt("a row handle gets another row and keeps its table", function()
                local table_was = text(raw().Requirement.DataTableName)
                recipes:Set(SCRATCH, "Requirement", { RowName = talent })
                return text(raw().Requirement.RowName):lower() == talent:lower() and text(raw().Requirement.DataTableName) == table_was,
                    text(raw().Requirement.RowName) .. " in " .. text(raw().Requirement.DataTableName)
            end)
            attempt("a row its table does not have is refused with the nearest name", function()
                return refused(function() recipes:Set(SCRATCH, "Requirement", { RowName = talent .. "_xyz" }) end, "has no row named")
            end)
        end
        local resource = has.Container and pick("IcarusResources", { [text(raw().Container.Value):lower()] = true })
        if resource then
            attempt("a row enum is written in place", function()
                recipes:Set(SCRATCH, "Container", { Value = resource })
                return text(raw().Container.Value):lower() == resource:lower(), text(raw().Container.Value)
            end)
        end
    elseif has.Requirement then
        attempt("names are refused while they are switched off", function()
            return refused(function() recipes:Set(SCRATCH, "Requirement", { RowName = "None" }) end, "switched off")
        end)
    end

    if has.Inputs and raw().Inputs:GetArrayNum() > 0 and patch.WRITES.plain then
        attempt("an entry of a list is changed where it is", function()
            local was = raw().Inputs[1].Count
            recipes:Change(SCRATCH, "Inputs", function(inputs)
                inputs[1].Count = inputs[1].Count + 1
                return inputs
            end)
            return raw().Inputs[1].Count == was + 1 and raw().Inputs:GetArrayNum() == dt:FindRow(source).Inputs:GetArrayNum()
        end)
    end

    local item = has.Inputs and pick("ItemsStatic", {})
    if item and patch.WRITES.lists and patch.WRITES.names and patch.WRITES.plain then
        attempt("a list of plain structs gets longer: emptied, then filled entry by entry", function()
            local count = raw().Inputs:GetArrayNum()
            local first = count > 0 and text(raw().Inputs[1].Element.RowName) or nil
            local started = now()
            local done, why = made(function()
                recipes:Change(SCRATCH, "Inputs", function(inputs)
                    inputs[#inputs + 1] = { Element = { RowName = item }, Count = 7 }
                    return inputs
                end)
            end)
            if not done then return true, why end
            local took = (now() - started) * 1000
            local list = raw().Inputs
            local last = list[count + 1]
            return list:GetArrayNum() == count + 1 and text(last.Element.RowName):lower() == item:lower() and last.Count == 7
                and text(last.Element.DataTableName) ~= "None" and (not first or text(list[1].Element.RowName) == first),
                ("%d entries, the new one names %s in %s, %.3f ms"):format(list:GetArrayNum(), text(last.Element.RowName),
                    text(last.Element.DataTableName), took)
        end)
        attempt("and shorter", function()
            local done, why = made(function() recipes:Set(SCRATCH, "Inputs", { { Element = { RowName = item }, Count = 2 } }) end)
            if not done then return true, why end
            return raw().Inputs:GetArrayNum() == 1 and raw().Inputs[1].Count == 2
        end)
        attempt("and empty, and filled again from nothing", function()
            local done, why = made(function() recipes:Set(SCRATCH, "Inputs", {}) end)
            if not done then return true, why end
            local emptied = raw().Inputs:GetArrayNum()
            recipes:Set(SCRATCH, "Inputs", { { Element = { RowName = item }, Count = 3 }, { Element = { RowName = item }, Count = 4 } })
            return emptied == 0 and raw().Inputs:GetArrayNum() == 2 and raw().Inputs[2].Count == 4
        end)
        if has.RecipeSets then
            local known = {}
            for index = 1, raw().RecipeSets:GetArrayNum() do known[text(raw().RecipeSets[index].RowName):lower()] = true end
            local bench = pick("RecipeSets", known)
            if bench then
                attempt("a list of row handles gets one more", function()
                    local count = raw().RecipeSets:GetArrayNum()
                    local done, why = made(function()
                        recipes:Change(SCRATCH, "RecipeSets", function(sets)
                            sets[#sets + 1] = { RowName = bench }
                            return sets
                        end)
                    end)
                    if not done then return true, why end
                    local list = raw().RecipeSets
                    return list:GetArrayNum() == count + 1 and text(list[count + 1].RowName):lower() == bench:lower()
                        and text(list[count + 1].DataTableName) ~= "None", text(list[count + 1].DataTableName)
                end)
            end
        end
        if has.Outputs and raw().Outputs:GetArrayNum() > 0 then
            attempt("a list of outputs is made again with one more", function()
                local count = raw().Outputs:GetArrayNum()
                local function clone(value)
                    if type(value) ~= "table" then return value end
                    local out = {}
                    for key, inner in pairs(value) do out[key] = clone(inner) end
                    return out
                end
                local done, why = made(function()
                    recipes:Change(SCRATCH, "Outputs", function(outputs)
                        local copy = clone(outputs[1])
                        copy.Count = 2
                        outputs[#outputs + 1] = copy
                        return outputs
                    end)
                end)
                if not done then return true, why end
                local list = raw().Outputs
                return list:GetArrayNum() == count + 1 and list[count + 1].Count == 2
                    and text(list[count + 1].Element.RowName) == text(list[1].Element.RowName)
            end)
        end
    elseif has.Inputs then
        attempt("a list is not made longer while that is switched off", function()
            local count = raw().Inputs:GetArrayNum()
            local ok, problem = refused(function() recipes:Set(SCRATCH, "Inputs", {}) end, count > 0 and "switched off" or "")
            return (count == 0 or ok) and raw().Inputs:GetArrayNum() == count, problem
        end)
    end

    if has.ResourceInputs and raw().ResourceInputs:GetArrayNum() > 0 then
        if patch.WRITES.plain then
            attempt("an entry the game made is changed where it is", function()
                local was = raw().ResourceInputs[1].RequiredUnits
                recipes:Change(SCRATCH, "ResourceInputs", function(list)
                    list[1].RequiredUnits = list[1].RequiredUnits + 1
                    return list
                end)
                return raw().ResourceInputs[1].RequiredUnits == was + 1
            end)
        end
        attempt("a list whose entries only the game can make keeps its length", function()
            local count = raw().ResourceInputs:GetArrayNum()
            local ok, problem = refused(function() recipes:Set(SCRATCH, "ResourceInputs", {}) end, "cannot make or remove entries")
            return ok and raw().ResourceInputs:GetArrayNum() == count, problem
        end)
    end

    attempt("the row that was copied is untouched", function()
        return print_of(dt:FindRow(source)) == source_print, print_of(dt:FindRow(source))
    end)
    attempt("Changes lists what was changed, by its owner, and the stamp counts it", function()
        local listed, wrong = recipes:Changes(), 0
        for _, change in ipairs(listed) do
            if change.Row == SCRATCH and change.By ~= OWNER then wrong = wrong + 1 end
        end
        local stamp = recipes:Stamp()
        return #listed > changes_before and wrong == 0 and stamp ~= stamp_before and stamp:match("^%d+:0x%x+:%d+$") ~= nil,
            ("%d changes, stamp %s"):format(#listed - changes_before, stamp)
    end)
    attempt("Reset puts the scratch row back to the copy it was", function()
        -- a put-back takes the same path when a mod unloads, so this is what one field costs then
        local started = now()
        local count = recipes:Reset(SCRATCH)
        local took = (now() - started) * 1000
        return count > 0 and print_of(raw()) == source_print and #recipes:Changes() == changes_before,
            ("%d changes taken back, %.3f ms each"):format(count, took / math.max(count, 1))
    end)
end

local ran, problem = pcall(scope.run, owner, body)
if not ran then check("no error outside the checks", false, problem) end

-- the scratch row goes whatever happened above
if added then
    pcall(scope.run, owner, function() recipes:Reset(SCRATCH) end)
    owner:destroy()
    attempt("the scratch row is taken out again", function()
        dt:RemoveRow(SCRATCH)
        T.row_removed(record, SCRATCH, dt)
        return #dt == before and not recipes:Has(SCRATCH) and recipes:Count() == count_before, #dt .. " rows"
    end)
else
    owner:destroy()
end

if ADD then
    local name = OWNER .. "_Added"
    local adder = scope.new(OWNER)
    if not patch.WRITES.rows then
        attempt("Add is refused while adding rows is switched off", function()
            return refused(function() scope.run(adder, function() recipes:Add(name, {}, { like = source }) end) end, "switched off")
        end)
    else
        attempt("Add makes a row the game's own index knows", function()
            local started = now()
            scope.run(adder, function() recipes:Add(name, { RequiredMillijoules = 1234 }, { like = source }) end)
            local took = (now() - started) * 1000
            local row = dt:FindRow(name)
            local library = StaticFindObject("/Script/Icarus.Default__ProcessorRecipesLibrary")
            return row ~= nil and row.RequiredMillijoules == 1234 and library:IsValid() and library:IsValidName(FName(name)) == true
                and library:NumRows() == #dt, ("%d rows, %.2f ms"):format(#dt, took)
        end)
        attempt("and Reset switches it off, as when its mod unloads", function()
            scope.run(adder, function() recipes:Reset(name) end)
            local row = dt:FindRow(name)
            local off = row ~= nil and (not has.bForceDisableRecipe or row.bForceDisableRecipe == true)
            local benches = row ~= nil and has.RecipeSets and row.RecipeSets:GetArrayNum() or 0
            return off and (benches == 0 or not patch.WRITES.lists),
                ("switched off, on %d benches. It stays in the table until the title screen or until the game closes"):format(benches)
        end)
    end
    adder:destroy()
end

return result()
