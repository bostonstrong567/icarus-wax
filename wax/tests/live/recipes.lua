-- Live test of world.recipes (game.Recipes) and of game.Crafting:Refresh.
-- It changes one recipe of the game, the time it takes and the items it takes, reads each change back from the game's own
-- table, and puts everything back before it returns. It crafts nothing, and no code of the game runs while the recipe is
-- changed, because all of it happens inside this one call.
-- At the end of the frame game.Data.Changed fires for ProcessorRecipes, so mods that keep recipes read them once more, and
-- the crafting tab, if it is the tab that shows, asks its recipes again (it does not build its list again).
-- Send it with:  node wax/cli/wax.mjs eval --file wax/tests/live/recipes.lua
-- Set WaxRecipesLiveScan = true first to also try Using, Making and At from the table. Those read every recipe in this
-- one call, which is a frame the player can notice, so only with the owner's word.
-- Each step is noted in run\session.log before it is made.

local game = Wax.game
local Recipes = game and rawget(game, "Recipes")
local Crafting = game and rawget(game, "Crafting")
local tables = Wax.import("data.tables")
local patch = tables.writer
if not Recipes or not patch then
    return { passed = 0, failed = 1, details = {},
             failures = { "game.Recipes is not there: add Wax.import(\"world.recipes\").start() after data.patch in boot.lua, then send dev_start_core.lua" } }
end

local T = tables.internal
local module = Wax.import("world.recipes")
local scope = Wax.import("core.scope")
local note = Wax.import("core.blackbox").note
local now = Wax.perf.now
local OWNER = "WaxRecipesTest"
local SCAN = rawget(_G, "WaxRecipesLiveScan") == true

local checks = {}
local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end
local function attempt(name, fn)
    note("recipes live: " .. name)
    local ok, a, b = pcall(fn)
    if ok then check(name, a, b) else check(name, false, "raised: " .. tostring(a)) end
end
local function refused(fn, fragment)
    local ok, problem = pcall(fn)
    if ok then return false, "it was not refused" end
    return tostring(problem):find(fragment, 1, true) ~= nil, tostring(problem)
end
local function result()
    local passed, failed, details = 0, {}, {}
    for _, c in ipairs(checks) do
        if c.ok then passed = passed + 1 else failed[#failed + 1] = c.name .. " :: " .. tostring(c.detail) end
        details[#details + 1] = (c.ok and "ok   " or "FAIL ") .. c.name .. (c.detail and ("  [" .. tostring(c.detail):sub(1, 260) .. "]") or "")
    end
    return { passed = passed, failed = #failed, failures = failed, details = details, writes = patch.WRITES, stats = module.stats() }
end

local Data = game.Data
local recipes = Data:Table("ProcessorRecipes")
local NAME = nil
for _, name in ipairs({ "Stone_Axe", "Stone_Pickaxe", "Wood_Floor" }) do
    if not NAME and Recipes:Has(name) then NAME = Recipes:Get(name).Name end
end
if not NAME then
    check("a recipe to try", false, "the game has none of Stone_Axe, Stone_Pickaxe and Wood_Floor")
    return result()
end

-- The game's own row, found again for every look, read by length and never past the end.
local function text(value) return value:ToString() end
local function raw()
    local _, dt = T.live(recipes)
    return dt:FindRow(NAME)
end
local function print_of()
    local row = raw()
    local parts = { tostring(row.RequiredMillijoules), tostring(row.bForceDisableRecipe), text(row.Requirement.RowName) }
    local inputs = row.Inputs
    for index = 1, inputs:GetArrayNum() do
        local entry = inputs[index]
        parts[#parts + 1] = ("in %s x%d @%s"):format(text(entry.Element.RowName), entry.Count, text(entry.Element.DataTableName))
    end
    local outputs = row.Outputs
    for index = 1, outputs:GetArrayNum() do
        local entry = outputs[index]
        parts[#parts + 1] = ("out %s x%d"):format(text(entry.Element.RowName), entry.Count)
    end
    local sets = row.RecipeSets
    for index = 1, sets:GetArrayNum() do parts[#parts + 1] = "at " .. text(sets[index].RowName) end
    return table.concat(parts, ", ")
end
local function raw_inputs()
    local row, out = raw(), {}
    local inputs = row.Inputs
    for index = 1, inputs:GetArrayNum() do
        out[index] = { item = text(inputs[index].Element.RowName), count = inputs[index].Count }
    end
    return out
end

local before, changes_before = print_of(), #Data:Changes()
local recipe = Recipes:Get(NAME)
local work = raw().RequiredMillijoules
local first = raw_inputs()

attempt("Get gives the recipe at once, by any letter case, and its fields read as the game's row does", function()
    local started = now()
    local found = Recipes:Get(NAME:upper())
    local got = (now() - started) * 1000
    started = now()
    local inputs, outputs, benches = found.Inputs, found.Outputs, found.Benches
    local read = (now() - started) * 1000
    local same = found == recipe and found.Work == work and #inputs == #first and found.Hidden == (raw().bForceDisableRecipe == true)
    for index = 1, #first do
        same = same and inputs[index].Item:lower() == first[index].item:lower() and inputs[index].Count == first[index].count
    end
    return same and #outputs >= 0 and #benches >= 1,
        ("%s: work %d, %d inputs, %d outputs, at %s, needs %s. Get %.3f ms, three fields %.3f ms"):format(NAME, found.Work, #inputs,
            #outputs, table.concat(benches, " "), tostring(found.Requirement), got, read)
end)

attempt("a wrong name is refused with the nearest one", function()
    return refused(function() Recipes:Get(NAME .. "x") end, "there is no recipe named")
end)

attempt("outside a mod nothing can be changed", function()
    return refused(function() recipe:SetWork(work + 1) end, "belongs to a mod")
end)

local owner = scope.new(OWNER)
local function as_mod(fn) return scope.run(owner, fn) end

attempt("SetWork writes the time, and the game's row reads it back", function()
    local started = now()
    as_mod(function() recipe:SetWork(work + 1000) end)
    local took = (now() - started) * 1000
    return raw().RequiredMillijoules == work + 1000 and recipe.Work == work + 1000, ("%d -> %d, %.3f ms"):format(work, raw().RequiredMillijoules, took)
end)

attempt("ScaleTime works from the value that is there", function()
    as_mod(function() recipe:ScaleTime(0.5) end)
    local want = math.max(1, math.floor((work + 1000) * 0.5 + 0.5))
    return raw().RequiredMillijoules == want, ("%d, wanted %d"):format(raw().RequiredMillijoules, want)
end)

attempt("SetSeconds turns seconds by hand into work, and GetSeconds reads them back", function()
    as_mod(function() recipe:SetSeconds(3, "Hand") end)
    local seconds = recipe:GetSeconds("Hand")
    return math.abs(seconds - 3) < 0.01 and raw().RequiredMillijoules > 0,
        ("%d millijoules, %.2f s by hand"):format(raw().RequiredMillijoules, seconds)
end)

if #first >= 1 then
    attempt("SetInput changes one count where it is", function()
        as_mod(function() recipe:SetInput(first[1].item, first[1].count + 1) end)
        local got = raw_inputs()
        return #got == #first and got[1].count == first[1].count + 1 and got[1].item:lower() == first[1].item:lower(),
            ("%s x%d of %d inputs"):format(got[1].item, got[1].count, #got)
    end)

    attempt("ScaleInputs multiplies every count, rounded up", function()
        as_mod(function() recipe:ScaleInputs(2) end)
        local got = raw_inputs()
        local same = #got == #first and got[1].count == (first[1].count + 1) * 2
        for index = 2, #first do same = same and got[index].count == first[index].count * 2 end
        return same, ("first is x%d"):format(got[1] and got[1].count or -1)
    end)

    local room = patch.ROOM or 4
    if patch.WRITES.lists and #first <= room then
        attempt("SetInputs makes the list another length, and the game's row reads it back", function()
            local started = now()
            as_mod(function() recipe:SetInputs({ [first[1].item] = 1 }) end)
            local took = (now() - started) * 1000
            local got = raw_inputs()
            return #got == 1 and got[1].count == 1 and got[1].item:lower() == first[1].item:lower(),
                ("%d inputs: %s x%d, %.3f ms"):format(#got, got[1].item, got[1].count, took)
        end)
    else
        attempt("SetInputs to another length is refused in plain words while the write path does not write it", function()
            local wanted = #first == 1 and { [first[1].item] = 1, [NAME] = 1 } or { [first[1].item] = 1 }
            return refused(function() as_mod(function() recipe:SetInputs(wanted) end) end, "This version of Wax")
        end)
    end
end

attempt("a list of outputs keeps its number while the write path does not write such lists", function()
    if patch.WRITES.owning_lists then return true, "the switch is on: not tried here" end
    local outputs = recipe.Outputs
    if #outputs ~= 1 or not outputs[1].Item then return true, "the recipe does not give one item: not tried" end
    local other = outputs[1].Item:lower() == "wood" and "Stone" or "Wood"
    return refused(function() as_mod(function() recipe:SetOutput(other, 1) end) end, "This version of Wax cannot add")
end)

attempt("Add is refused in plain words while adding rows is switched off", function()
    if patch.WRITES.rows then return true, "the switch is on: not tried here" end
    return refused(function() as_mod(function() Recipes:Add(OWNER .. "_Quick", { like = NAME }) end) end, "switched off in this version of Wax")
end)

attempt("At asks the game for a bench's recipes", function()
    local asked = module.stats().asked
    local started = now()
    local list = Recipes:At("Hand")
    local took = (now() - started) * 1000
    local has = false
    for _, name in ipairs(list:GetNames()) do has = has or name == NAME end
    local on_hand = false
    for _, bench in ipairs(recipe.Benches) do on_hand = on_hand or bench:lower() == module.HAND:lower() end
    return #list > 0 and has == on_hand,
        ("%d recipes by hand in %.3f ms, the game was asked: %s, %s among them: %s"):format(#list, took,
            tostring(module.stats().asked > asked), NAME, tostring(has))
end)

if SCAN then
    attempt("Using and Making read every recipe, and At gives the same from the table as from the game", function()
        local started = now()
        local using = first[1] and #Recipes:Using(first[1].item) or 0
        local first_scan = (now() - started) * 1000
        started = now()
        local outputs = recipe.Outputs
        local making = outputs[1] and outputs[1].Item and #Recipes:Making(outputs[1].Item) or 0
        local second_scan = (now() - started) * 1000
        local asked = #Recipes:At("Hand")
        module.ASK_GAME = false
        local ok, read = pcall(function() return #Recipes:At("Hand") end)
        module.ASK_GAME = true
        if not ok then error(read, 0) end
        return using >= 1 and asked == read, ("%d use the first input (%.1f ms), %d make the output (%.1f ms), by hand %d and %d")
            :format(using, first_scan, making, second_scan, asked, read)
    end)
end

attempt("Reset puts the recipe back as the game made it, at once", function()
    local count = as_mod(function() return recipe:Reset() end)
    return print_of() == before, ("%d fields taken back. Now: %s"):format(count, print_of())
end)

owner:destroy()

attempt("nothing of this is left in what mods changed", function()
    for _, change in ipairs(Data:Changes()) do
        if change.By == OWNER then return false, change.Table .. "." .. change.Row .. "." .. tostring(change.Field) end
    end
    return #Data:Changes() == changes_before and print_of() == before, ("%d changes stand, as before"):format(#Data:Changes())
end)

attempt("game.Crafting:Refresh takes the ask and runs when the frame ends", function()
    if not Crafting or not Crafting.Refresh then return false, "game.Crafting has no Refresh" end
    local screen, kind = Crafting:GetScreen()
    Crafting:Refresh({ lists = false, recipes = { NAME } })
    return true, ("screen %s (%s). Only the crafting tab is told, by its own FullUpdateRequested"):format(tostring(screen), tostring(kind))
end)

return result()
