-- game.Recipes: finding the game's crafting recipes and changing them, through game.Data's write path

local Wax = ...
local tables = Wax.import("data.tables")
local journal = Wax.import("data.journal")
local suggest = Wax.import("core.suggest")
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local perf = Wax.import("core.perf")
local log = Wax.import("core.log").channel("wax.recipes")

local M = {}
local T = tables.internal
local task = sched.task

M.ASK_GAME = true           -- At asks the game which recipes a bench has. Off, or when the game does not answer, the table is read
M.ASK_ANYWHERE = false      -- the game was only ever asked that in a prospect, so anywhere else the table is read
M.RESOURCE_LISTS = false    -- adding a resource to a recipe or taking one away: only the game can make those entries, as far as is known
M.BUDGET = 1                -- milliseconds of a frame that work on many recipes may use inside a task before it pauses
M.PIECE = 100               -- rows of a table that are read between two looks at the clock
M.HAND = "Character"        -- the recipe set of what is made by hand
M.clock = perf.now

local RECIPES, ITEMS, TEMPLATES, SETS = "ProcessorRecipes", "ItemsStatic", "ItemTemplate", "RecipeSets"
local PROCESSING, TAGS, RESOURCES, TALENTS = "Processing", "CraftingTags", "IcarusResources", "Talents"
local LIBRARY = "/Script/Icarus.Default__ProcessingFunctionLibrary"
local INT_MAX = 2147483647
local RAISED = "the function given to Change raised: "
local SCAN = {}             -- raised when every template has to be read first, which may take frames

local WHOLE = { Inputs = { "Inputs" }, QueryInputs = { "QueryInputs" }, ResourceInputs = { "ResourceInputs" }, Outputs = { "Outputs" },
                RecipeSets = { "RecipeSets" }, RequiredMillijoules = { "RequiredMillijoules" }, Requirement = { "Requirement" },
                bForceDisableRecipe = { "bForceDisableRecipe" } }
local AT_FIELDS = { "RecipeSets.RowName", "bForceDisableRecipe" }
local OUT_FIELDS = { "Outputs.Element.RowName" }
local PROCESSING_FIELDS = { "DefaultRecipeSet.RowName", "MaxMilliwattage" }
local BENCH_FIELDS = { "Processing.RowName" }
local TEMPLATE_FIELDS = { "ItemStaticData.RowName" }
-- a change of one of these alters which recipes a list has
local LISTED = { RecipeSets = true, bForceDisableRecipe = true, Requirement = true, SessionRequirement = true, CharacterRequirement = true }

local lower, type, pcall, error, tostring, ipairs, pairs = string.lower, type, pcall, error, tostring, ipairs, pairs
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

local data = nil            -- game.Data, from start()
local stats = { sets = 0, changes = 0, scans = 0, asked = 0, ask_seconds = 0, pauses = 0, refreshes = 0 }

local function clean(problem)
    local text = tostring(problem):match("^[^\r\n]*") or ""
    local stripped = 1
    while stripped > 0 do text, stripped = text:gsub("^.-%.lua:%d+: ", "") end
    return text
end

local function shown(value)
    if type(value) == "string" then return "\"" .. value .. "\"" end
    if type(value) == "table" then return "a table" end
    return tostring(value)
end

local function listing(names)
    if #names == 0 then return "nothing" end
    if #names == 1 then return names[1] end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = copy(item) end
    return out
end

local function game_data()
    if not data then data = tables.api end
    return data
end

local function table_of(kind)
    return game_data():Table(kind)
end

-- A row's name as the game spells it, whatever letter case it was asked in. Nil when the table has no such row, or is not there.
local function spelled(kind, name)
    local index = T.rows(kind)
    if not index then return nil end
    return index[name] or index[lower(name)]
end

local function names_of(kind)
    local _, names = T.rows(kind)
    return names or {}
end

local function recipe_name(name)
    if type(name) ~= "string" then error(("a recipe is named by a string such as \"Stone_Axe\", got %s"):format(shown(name)), 0) end
    local index, names = T.rows(RECIPES)
    if not index then error("the game's recipes cannot be read right now", 0) end
    local real = index[name] or index[lower(name)]
    if not real then error(("there is no recipe named '%s'.%s"):format(name, suggest.phrase(name, names)), 0) end
    return real
end

local function count_of(value, what)
    local whole = type(value) == "number" and math.tointeger(value) or nil
    if not whole or whole < 1 then error(("%s is a whole number of 1 or more, got %s"):format(what, shown(value)), 0) end
    return whole
end

local function factor_of(value)
    if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
        error(("a factor is a number above 0, such as 0.5 for half, got %s"):format(shown(value)), 0)
    end
    return value
end

-- Counts are rounded up and never go under 1.
local function scaled(count, factor)
    return min(INT_MAX, max(1, ceil(count * factor - 1e-9)))
end

local function scaled_work(work, factor)
    return min(INT_MAX, max(1, floor(work * factor + 0.5)))
end

-- What a mod left in the table before it was loaded again must not decide what it does this time.

local stale_at = { owner = nil, frame = nil, map = nil }

-- The fields of recipes that still hold what the calling mod wrote before it was loaded again: folded row -> field -> entry.
local function stale()
    local owner = scope.current()
    if not owner or not owner.alive then return nil end
    local frame = sched.stats.frame
    if stale_at.owner == owner and stale_at.frame == frame then return stale_at.map, owner.name end
    local map = nil
    local found = journal.under(T.record_of(table_of(RECIPES)).key, "")
    for index = 1, #found do
        local entry = found[index]
        local layer = journal.layer(entry, owner.name)
        if layer and layer.leaving then
            map = map or {}
            local key = lower(entry.info.row)
            local fields = map[key]
            if not fields then
                fields = {}
                map[key] = fields
            end
            fields[entry.info.field] = entry
        end
    end
    stale_at.owner, stale_at.frame, stale_at.map = owner, frame, map
    return map, owner.name
end

-- What a field holds without the layer its owner left behind: the game's own value and everyone else's changes.
local function without(entry, owner)
    local value = copy(entry.original)
    for _, layer in ipairs(entry.layers) do
        if not (layer.owner == owner and layer.leaving) then
            for _, step in ipairs(layer.steps) do
                if step.set ~= nil then
                    value = copy(step.set)
                elseif type(step.change) == "function" then
                    local given = copy(value)
                    local ok, made = pcall(step.change, given)
                    if ok then
                        if made == nil and type(given) == "table" then made = given end
                        if made ~= nil then value = made end
                    end
                end
            end
        end
    end
    return value
end

local function left_behind(own, owner, name, field)
    local fields = own and own[lower(name)]
    local entry = fields and fields[field]
    if not entry or journal.find(entry.key) ~= entry then return nil end
    local layer = journal.layer(entry, owner)
    if layer and layer.leaving then return entry end
    return nil
end

-- One field of one recipe, as the calling mod should see it. The value is shared: never change it.
local function basis(name, field)
    local own, owner = stale()
    local entry = left_behind(own, owner, name, field)
    if entry then return without(entry, owner) end
    local row = table_of(RECIPES):Row(name, WHOLE[field])
    if not row then error(("the recipe %s could not be read from the game"):format(name), 0) end
    return row[field]
end

-- Pauses a task that has used its share of the frame. It does nothing outside a task. Never call it inside a pcall.
local function pacer()
    if not coroutine.isyieldable() then return function() end end
    local started, done = M.clock(), 0
    return function()
        if done > 0 and (M.clock() - started) * 1000 >= M.BUDGET then
            stats.pauses = stats.pauses + 1
            task.wait()
            started, done = M.clock(), 0
        end
        done = done + 1
    end
end

-- Every row of a table with these fields, by name. Inside a task the read pauses, outside one it is made at once. Never call it inside a pcall.
local function all_rows(kind, fields)
    local tbl = table_of(kind)
    stats.scans = stats.scans + 1
    local out, names = {}, tbl:GetNames()
    if coroutine.isyieldable() then
        -- in pieces: Load hands over rows that were read before without a pause, however many they are
        local pause = pacer()
        for from = 1, #names, M.PIECE do
            pause()
            local piece = table.move(names, from, min(from + M.PIECE - 1, #names), 1, {})
            for name, row in pairs(tbl:Load({ fields = fields, names = piece, budget = M.BUDGET })) do out[name] = row end
        end
        return out
    end
    for index = 1, #names do out[names[index]] = tbl:Row(names[index], fields) end
    return out
end

-- The recipes keep(name, value) says yes to, in the table's order. value(field) gives a field. Never call it inside a pcall.
local function select_rows(fields, keep)
    local rows = all_rows(RECIPES, fields)
    local names = table_of(RECIPES):GetNames()
    local own, owner = stale()
    local out = {}
    local pause = pacer()
    for index = 1, #names do
        if index % M.PIECE == 0 then pause() end
        local name = names[index]
        local row = rows[name]
        if row then
            local function value(field)
                local entry = left_behind(own, owner, name, field)
                if entry then return without(entry, owner) end
                return row[field]
            end
            if keep(name, value) then out[#out + 1] = name end
        end
    end
    return out
end

-- benches: a recipe set, and how fast the benches that work from it are

local model = nil           -- what D_Processing says: by_set[folded set] = { speeds }, by_row[folded row] = { set, speed }
local resolved = {}         -- folded bench name as a mod wrote it -> { set, speeds, label }
local told = {}

local function tell_once(id, ...)
    if told[id] then return end
    told[id] = true
    log:warn(...)
end

local function benches()
    if model then return model end
    local made = { by_set = {}, by_row = {} }
    local ok, problem = pcall(function()
        local tbl = table_of(PROCESSING)
        for _, name in ipairs(tbl:GetNames()) do
            local row = tbl:Row(name, PROCESSING_FIELDS)
            local set = row and row.DefaultRecipeSet and row.DefaultRecipeSet.RowName
            local speed = row and row.MaxMilliwattage
            if type(set) == "string" and lower(set) ~= "none" and set ~= "" then
                set = spelled(SETS, set) or set
                made.by_row[lower(name)] = { set = set, speed = speed, row = name }
                if type(speed) == "number" and speed > 0 then
                    local speeds = made.by_set[lower(set)]
                    if not speeds then
                        speeds = {}
                        made.by_set[lower(set)] = speeds
                    end
                    local known = false
                    for index = 1, #speeds do known = known or speeds[index] == speed end
                    if not known then speeds[#speeds + 1] = speed end
                end
            end
        end
        for _, speeds in pairs(made.by_set) do table.sort(speeds) end
    end)
    if not ok then tell_once("processing", "how fast benches work could not be read, so SetSeconds needs SetWork instead: %s", clean(problem)) end
    model = made
    return made
end

local function speeds_of(set)
    return benches().by_set[lower(set)] or {}
end

-- The processing row of an item that is a bench, or nil.
local function processing_of(item)
    local ok, row = pcall(function() return table_of(ITEMS):Row(item, BENCH_FIELDS) end)
    local name = ok and row and row.Processing and row.Processing.RowName
    if type(name) ~= "string" or name == "" or lower(name) == "none" then return nil end
    return name
end

-- A bench by the name a mod gives it: "Hand", the item that is the bench, a recipe set, or a row of D_Processing.
local function bench_of(name)
    if type(name) ~= "string" then
        error(("a bench is named by a string such as \"Fabricator\" or \"Hand\", got %s"):format(shown(name)), 0)
    end
    local key = lower(name)
    local known = resolved[key]
    if known then return known end
    local made = benches()
    local found = nil
    if key == "hand" then
        local set = spelled(SETS, M.HAND) or M.HAND
        found = { set = set, speeds = speeds_of(set), label = "Hand" }
    else
        local item = spelled(ITEMS, name)
        local row = item and processing_of(item)
        local by_row = row and made.by_row[lower(row)]
        if by_row then
            found = { set = by_row.set, speeds = by_row.speed and by_row.speed > 0 and { by_row.speed } or {}, label = item }
        else
            local set = spelled(SETS, name)
            by_row = made.by_row[key]
            if set then
                found = { set = set, speeds = speeds_of(set), label = set }
            elseif by_row then
                found = { set = by_row.set, speeds = by_row.speed and by_row.speed > 0 and { by_row.speed } or {}, label = by_row.row }
            end
        end
    end
    if not found then
        local sets = names_of(SETS)
        local names = table.move(sets, 1, #sets, 2, { "Hand" })
        error(("there is no bench named '%s'.%s A bench is named by its recipe set, by the item that is the bench, or \"Hand\"")
            :format(name, suggest.phrase(name, names)), 0)
    end
    resolved[key] = found
    return found
end

local function handle_of(set) return { RowName = set } end

-- templates: an output names a row of D_ItemTemplate, and that row names its item

local item_by_template = {}     -- folded template -> its item as the game spells it, or false
local templates_by_item = nil   -- folded item -> { templates }, once every template was read

local function item_of(template)
    local key = lower(template)
    local known = item_by_template[key]
    if known ~= nil then return known or nil end
    local real = spelled(TEMPLATES, template)
    local ok, row = pcall(function() return real and table_of(TEMPLATES):Row(real, TEMPLATE_FIELDS) end)
    local item = ok and row and row.ItemStaticData and row.ItemStaticData.RowName
    if type(item) ~= "string" or item == "" or lower(item) == "none" then item = false end
    if item then item = spelled(ITEMS, item) or item end
    item_by_template[key] = item
    return item or nil
end

-- Reads every template once. It may take frames inside a task, so it is never called inside a pcall.
local function load_templates()
    if templates_by_item then return end
    local rows = all_rows(TEMPLATES, TEMPLATE_FIELDS)
    local names = table_of(TEMPLATES):GetNames()
    local by = {}
    for index = 1, #names do
        local row = rows[names[index]]
        local item = row and row.ItemStaticData and row.ItemStaticData.RowName
        if type(item) == "string" and item ~= "" and lower(item) ~= "none" then
            local list = by[lower(item)]
            if not list then
                list = {}
                by[lower(item)] = list
            end
            list[#list + 1] = names[index]
        end
    end
    templates_by_item = by
end

-- Every template of an item. Raises SCAN until the templates were read.
local function templates_of(item)
    if not templates_by_item then error(SCAN, 0) end
    return templates_by_item[lower(item)] or {}
end

-- The template an item is made as: the one of its own name, else its only one.
local function template_for(item)
    local own = spelled(TEMPLATES, item)
    if own and lower(item_of(own) or "") == lower(item) then return own end
    local all = templates_of(item)
    if #all == 1 then return all[1] end
    if #all == 0 then
        error(("%s cannot come out of a recipe: the game has no template for it"):format(item), 0)
    end
    error(("%s has %d templates and none of its own name: %s. Name the one you mean, as in { Template = \"%s\", Count = 1 }")
        :format(item, #all, listing(all), all[1]), 0)
end

-- What a mod named as something that comes out: an item, or a template itself. Returns the template to write and the item, if any.
local function output_of(name, as_template)
    if type(name) ~= "string" then error(("an item is named by a string such as \"Stone_Axe\", got %s"):format(shown(name)), 0) end
    local item = not as_template and spelled(ITEMS, name) or nil
    if item then return template_for(item), item end
    local template = spelled(TEMPLATES, name)
    if template then return template, nil end
    if as_template then
        error(("there is no template named '%s'.%s"):format(name, suggest.phrase(name, names_of(TEMPLATES))), 0)
    end
    error(("there is no item named '%s'.%s"):format(name, suggest.phrase(name, names_of(ITEMS))), 0)
end

-- what a recipe takes: items, tags and resources are three lists of the row

local KINDS = {
    { word = "item", field = "Inputs", key = "Element", sub = "RowName", count = "Count", table = ITEMS },
    { word = "tag", field = "QueryInputs", key = "Query", sub = "RowName", count = "Count", table = TAGS },
    { word = "resource", field = "ResourceInputs", key = "Type", sub = "Value", count = "RequiredUnits", table = RESOURCES, fixed = true },
}
local ITEM = KINDS[1]

local function entry_of(kind, name, count)
    return { [kind.key] = { [kind.sub] = name }, [kind.count] = count }
end

local function name_in(kind, entry)
    local holder = type(entry) == "table" and entry[kind.key]
    return type(holder) == "table" and holder[kind.sub] or nil
end

local function place_of(list, kind, name)
    local wanted = lower(name)
    for index = 1, #list do
        local held = name_in(kind, list[index])
        if type(held) == "string" and lower(held) == wanted then return index end
    end
    return nil
end

-- An item, a tag or a resource by name. Returns its kind and the name as the game spells it.
local function input_of(name)
    if type(name) ~= "string" then error(("an item is named by a string such as \"Wood\", got %s"):format(shown(name)), 0) end
    for _, kind in ipairs(KINDS) do
        local real = spelled(kind.table, name)
        if real then return kind, real end
    end
    local near = suggest.suggest(name, names_of(ITEMS), 3)
    for _, kind in ipairs({ KINDS[2], KINDS[3] }) do
        local more = suggest.suggest(name, names_of(kind.table), 1)
        near[#near + 1] = more[1]
    end
    for index = 1, #near do near[index] = "'" .. near[index] .. "'" end
    local hint = ""
    if #near > 0 then
        local last = table.remove(near)
        hint = " Did you mean " .. (#near > 0 and (table.concat(near, ", ") .. " or ") or "") .. last .. "?"
    end
    error(("there is no item, tag or resource named '%s'.%s"):format(name, hint), 0)
end

-- Everything a recipe takes, by name.
local function taken(name)
    local out = {}
    for _, kind in ipairs(KINDS) do
        for _, entry in ipairs(basis(name, kind.field)) do
            local held = tostring(name_in(kind, entry))
            out[#out + 1] = spelled(kind.table, held) or held
        end
    end
    return out
end

local function takes(name, but)
    local total = 0
    for _, kind in ipairs(KINDS) do
        if kind ~= but then total = total + #basis(name, kind.field) end
    end
    return total
end

local NOTHING_IN = "%s would take nothing. A recipe has to take at least one item, tag or resource"

-- the write path: one whole field of one row. Its switches decide what is written, and say so in plain words

local SAYS = {
    Inputs = { "takes %d %s and would take %d", "item", "items", "an item it takes" },
    QueryInputs = { "takes %d %s and would take %d", "tag", "tags", "a tag it takes" },
    ResourceInputs = { "takes %d %s and would take %d", "resource", "resources", "a resource it takes" },
    Outputs = { "gives %d %s and would give %d", "item", "items", "an item it gives" },
    RecipeSets = { "is on %d %s and would be on %d", "bench", "benches", "a bench" },
}

-- Why this version does not make a list of a recipe longer or shorter, in a mod author's words. Nil when it may be tried.
local function resize_refusal(name, field, have, want)
    if have == want then return nil end
    local says = SAYS[field]
    local start = ("%s %s."):format(name, says[1]:format(have, have == 1 and says[2] or says[3], want))
    if field == "ResourceInputs" and not M.RESOURCE_LISTS then
        return start .. " This version of Wax cannot add a resource to a recipe or take one away. It can change how much of a resource a recipe takes"
    end
    local writer = tables.writer
    local writes = writer and writer.WRITES
    if not writes then return nil end
    if not writes.lists or (field == "Outputs" and not writes.owning_lists) then
        return ("%s This version of Wax cannot add %s to a recipe or take one away. It can change the ones that are there"):format(start, says[4])
    end
    local room = writer.ROOM or 4
    if (have > room or want > room) and not writes.long_lists then
        return ("%s This version of Wax only makes such a list longer or shorter while it has %d entries or fewer, before and after")
            :format(start, room)
    end
    return nil
end

local function set_field(name, field, value)
    local tbl = table_of(RECIPES)
    local ok, problem = pcall(tbl.Set, tbl, name, field, value)
    if not ok then error(name .. ": " .. clean(problem), 0) end
    stats.sets = stats.sets + 1
end

-- `fn` is kept by the write path and run again when a mod underneath changes the field, so it depends on its value alone.
local function change(name, field, fn)
    local tbl = table_of(RECIPES)
    local ok, problem = pcall(tbl.Change, tbl, name, field, fn)
    if not ok then
        local text = clean(problem)
        if text:sub(1, #RAISED) == RAISED then error(text:sub(#RAISED + 1), 0) end
        error(name .. ": " .. text, 0)
    end
    stats.changes = stats.changes + 1
end

-- { Wood = 2 }, or a list such as { { "Wood", 2 }, { Item = "Fiber", Count = 4 } }, as { name, count, template } in a fixed order.
local function pairs_of(spec, method, example)
    if type(spec) ~= "table" then error(("%s takes a table such as %s, got %s"):format(method, example, shown(spec)), 0) end
    local out = {}
    if spec[1] ~= nil then
        for key in pairs(spec) do
            if math.type(key) ~= "integer" or key < 1 or key > #spec then
                error(("%s was given a list, which has no place for the key %s"):format(method, shown(key)), 0)
            end
        end
        for index = 1, #spec do
            local entry = spec[index]
            if type(entry) ~= "table" then
                error(("%s: entry %d is a table such as { \"Wood\", 2 }, got %s"):format(method, index, shown(entry)), 0)
            end
            local name = entry.Item
            if name == nil then name = entry.Template end
            if name == nil then name = entry[1] end
            local count = entry.Count
            if count == nil then count = entry[2] end
            if type(name) ~= "string" then error(("%s: entry %d names no item"):format(method, index), 0) end
            out[index] = { name = name, count = count, template = entry.Item == nil and entry.Template ~= nil }
        end
    else
        for name, count in pairs(spec) do
            if type(name) ~= "string" then error(("%s: an item is named by a string, got %s"):format(method, shown(name)), 0) end
            out[#out + 1] = { name = name, count = count }
        end
        table.sort(out, function(a, b) return lower(a.name) < lower(b.name) end)
    end
    return out
end

-- The changes. Each checks what the mod wrote once and returns what to do to one recipe: false when it does not apply to one of a list.

local prepare = {}

function prepare.SetInputs(spec)
    local given = pairs_of(spec, "SetInputs", "{ Wood = 2, Fiber = 4 }")
    local value, seen = {}, {}
    for index, entry in ipairs(given) do
        local kind, real = input_of(entry.name)
        if kind ~= ITEM then
            error(("%s is a %s, not an item. SetInputs sets the items a recipe takes. For this one use SetInput(\"%s\", count)")
                :format(real, kind.word, real), 0)
        end
        if seen[lower(real)] then error(("SetInputs names %s twice"):format(real), 0) end
        seen[lower(real)] = true
        value[index] = entry_of(ITEM, real, count_of(entry.count, "the count of " .. real))
    end
    return function(name)
        local have = #basis(name, "Inputs")
        if #value == 0 and have > 0 and takes(name, ITEM) == 0 then error(NOTHING_IN:format(name), 0) end
        local refusal = resize_refusal(name, "Inputs", have, #value)
        if refusal then error(refusal, 0) end
        set_field(name, "Inputs", copy(value))
        return true
    end
end

function prepare.SetInput(what, count)
    local kind, real = input_of(what)
    local wanted = count_of(count, "the count of " .. real)
    return function(name)
        local have = basis(name, kind.field)
        if not place_of(have, kind, real) then
            local refusal = resize_refusal(name, kind.field, #have, #have + 1)
            if refusal then error(refusal, 0) end
        end
        change(name, kind.field, function(list)
            local at = place_of(list, kind, real)
            if at then list[at][kind.count] = wanted else list[#list + 1] = entry_of(kind, real, wanted) end
            return list
        end)
        return true
    end
end

function prepare.RemoveInput(what)
    local kind, real = input_of(what)
    return function(name, lenient)
        local have = basis(name, kind.field)
        if not place_of(have, kind, real) then
            if lenient then return false end
            error(("%s takes no %s. It takes %s"):format(name, real, listing(taken(name))), 0)
        end
        local others = takes(name, kind)
        if #have == 1 and others == 0 then error(NOTHING_IN:format(name), 0) end
        local refusal = resize_refusal(name, kind.field, #have, #have - 1)
        if refusal then error(refusal, 0) end
        change(name, kind.field, function(list)
            local at = place_of(list, kind, real)
            if not at then return list end
            if #list == 1 and others == 0 then error(NOTHING_IN:format(name), 0) end
            table.remove(list, at)
            return list
        end)
        return true
    end
end

function prepare.ScaleInputs(factor)
    factor = factor_of(factor)
    return function(name)
        local any = false
        for _, kind in ipairs(KINDS) do
            if #basis(name, kind.field) > 0 then
                any = true
                change(name, kind.field, function(list)
                    for index = 1, #list do list[index][kind.count] = scaled(list[index][kind.count], factor) end
                    return list
                end)
            end
        end
        return any
    end
end

function prepare.ScaleInput(what, factor)
    local kind, real = input_of(what)
    factor = factor_of(factor)
    return function(name, lenient)
        if not place_of(basis(name, kind.field), kind, real) then
            if lenient then return false end
            error(("%s takes no %s. It takes %s"):format(name, real, listing(taken(name))), 0)
        end
        change(name, kind.field, function(list)
            local at = place_of(list, kind, real)
            if at then list[at][kind.count] = scaled(list[at][kind.count], factor) end
            return list
        end)
        return true
    end
end

local output_lists = nil    -- the fields of an output that are lists, which a new output has empty

local function new_output(template, count)
    if not output_lists then
        local found = {}
        for _, field in ipairs(table_of(RECIPES):Fields("Outputs")) do
            if field.Kind == "Array" then found[#found + 1] = field.Name end
        end
        output_lists = found
    end
    local entry = { Element = { RowName = template }, Count = count }
    for _, field in ipairs(output_lists) do entry[field] = {} end
    return entry
end

local function template_in(entry)
    local element = type(entry) == "table" and entry.Element
    local template = type(element) == "table" and element.RowName
    return type(template) == "string" and template or ""
end

function prepare.SetOutputs(spec)
    local given = pairs_of(spec, "SetOutputs", "{ Stone_Axe = 2 }")
    if #given == 0 then error("SetOutputs was given nothing. A recipe has to give something", 0) end
    local wanted, seen = {}, {}
    for index, entry in ipairs(given) do
        local template = output_of(entry.name, entry.template)
        if seen[lower(template)] then error(("SetOutputs names %s twice"):format(entry.name), 0) end
        seen[lower(template)] = true
        wanted[index] = { template = template, count = count_of(entry.count, "the count of " .. entry.name) }
    end
    new_output(wanted[1].template, 1)
    return function(name)
        local refusal = resize_refusal(name, "Outputs", #basis(name, "Outputs"), #wanted)
        if refusal then error(refusal, 0) end
        change(name, "Outputs", function(list)
            -- an output that stays keeps its place and what else it holds. The others give their places to the new ones
            local out, used, placed = {}, {}, {}
            local same_length = #list == #wanted
            for index, want in ipairs(wanted) do
                for at = 1, #list do
                    if not used[at] and lower(template_in(list[at])) == lower(want.template) then
                        used[at], placed[index] = true, true
                        list[at].Count = want.count
                        out[same_length and at or index] = list[at]
                        break
                    end
                end
            end
            local free = 1
            for index, want in ipairs(wanted) do
                if not placed[index] then
                    local at = index
                    if same_length then
                        while used[free] do free = free + 1 end
                        at, used[free] = free, true
                    end
                    out[at] = new_output(want.template, want.count)
                end
            end
            return out
        end)
        return true
    end
end

function prepare.SetOutput(what, count)
    local template, item = output_of(what, false)
    local wanted = count_of(count, "the count of " .. tostring(what))
    local function fits(entry)
        local held = template_in(entry)
        if lower(held) == lower(template) then return true end
        return item ~= nil and lower(item_of(held) or "") == lower(item)
    end
    local function find(list)
        for index = 1, #list do
            if fits(list[index]) then return index end
        end
        return nil
    end
    new_output(template, 1)
    return function(name)
        local have = basis(name, "Outputs")
        if not find(have) then
            local refusal = resize_refusal(name, "Outputs", #have, #have + 1)
            if refusal then error(refusal, 0) end
        end
        change(name, "Outputs", function(list)
            local at = find(list)
            if at then list[at].Count = wanted else list[#list + 1] = new_output(template, wanted) end
            return list
        end)
        return true
    end
end

function prepare.ScaleOutputs(factor)
    factor = factor_of(factor)
    return function(name)
        if #basis(name, "Outputs") == 0 then return false end
        change(name, "Outputs", function(list)
            for index = 1, #list do list[index].Count = scaled(list[index].Count, factor) end
            return list
        end)
        return true
    end
end

function prepare.SetWork(work)
    local wanted = count_of(work, "the work, in millijoules,")
    return function(name)
        set_field(name, "RequiredMillijoules", wanted)
        return true
    end
end

-- How fast a recipe is made, in milliwatts: at the bench that was named, or at its own benches when they all work alike.
local function speed_for(name, bench, seconds)
    if bench then
        local speeds = bench.speeds
        if #speeds == 1 then return speeds[1] end
        if #speeds == 0 then
            error(("Wax does not know how fast %s works, so seconds cannot be turned into work for it. Use SetWork(millijoules)")
                :format(bench.label), 0)
        end
        error(("the benches of %s work at %s milliwatts. Name the bench by its item, or use SetWork(millijoules)")
            :format(bench.label, listing(speeds)), 0)
    end
    local speeds, seen, first = {}, {}, nil
    for _, entry in ipairs(basis(name, "RecipeSets")) do
        for _, speed in ipairs(speeds_of(entry.RowName)) do
            first = first or entry.RowName
            if not seen[speed] then
                seen[speed] = true
                speeds[#speeds + 1] = speed
            end
        end
    end
    if #speeds == 1 then return speeds[1] end
    if #speeds == 0 then
        error(("%s is on no bench whose speed Wax knows. Say which bench the seconds are for, or use SetWork(millijoules)"):format(name), 0)
    end
    table.sort(speeds)
    local text = seconds and tostring(seconds) or "seconds"
    error(("%s is made at benches that work at %s milliwatts. Say which bench the seconds are for, as in SetSeconds(%s, \"%s\"), or use ScaleTime")
        :format(name, listing(speeds), text, tostring(first)), 0)
end

function prepare.SetSeconds(seconds, bench)
    if type(seconds) ~= "number" or seconds ~= seconds or seconds <= 0 or seconds == math.huge then
        error(("the time is a number of seconds above 0, got %s"):format(shown(seconds)), 0)
    end
    local at = bench ~= nil and bench_of(bench) or nil
    return function(name)
        local work = seconds * speed_for(name, at, seconds)
        if work > INT_MAX then error(("%s: %s seconds is more work than the game can hold"):format(name, tostring(seconds)), 0) end
        set_field(name, "RequiredMillijoules", max(1, floor(work + 0.5)))
        return true
    end
end

function prepare.ScaleTime(factor)
    factor = factor_of(factor)
    return function(name)
        change(name, "RequiredMillijoules", function(work) return scaled_work(work, factor) end)
        return true
    end
end

local function on_bench(list, set)
    local wanted = lower(set)
    for index = 1, #list do
        local held = type(list[index]) == "table" and list[index].RowName
        if type(held) == "string" and lower(held) == wanted then return index end
    end
    return nil
end

local function bench_names(list)
    local out = {}
    for index = 1, #list do out[index] = tostring(list[index].RowName) end
    return out
end

local NO_BENCH = "%s would be on no bench. To take a recipe off every list, use Hide()"

function prepare.SetBenches(spec)
    if type(spec) == "string" then spec = { spec } end
    if type(spec) ~= "table" then
        error(("SetBenches takes a list of benches such as { \"Hand\", \"Crafting_Bench\" }, got %s"):format(shown(spec)), 0)
    end
    local value, seen = {}, {}
    for key in pairs(spec) do
        if math.type(key) ~= "integer" or key < 1 or key > #spec then
            error(("SetBenches takes a list, which has no place for the key %s"):format(shown(key)), 0)
        end
    end
    for index = 1, #spec do
        local set = bench_of(spec[index]).set
        if not seen[lower(set)] then
            seen[lower(set)] = true
            value[#value + 1] = handle_of(set)
        end
    end
    if #value == 0 then error("SetBenches was given no bench. To take a recipe off every list, use Hide()", 0) end
    return function(name)
        local refusal = resize_refusal(name, "RecipeSets", #basis(name, "RecipeSets"), #value)
        if refusal then error(refusal, 0) end
        set_field(name, "RecipeSets", copy(value))
        return true
    end
end

function prepare.MoveTo(bench)
    return prepare.SetBenches({ bench })
end

function prepare.AddBench(bench)
    local set = bench_of(bench).set
    return function(name)
        local have = basis(name, "RecipeSets")
        if on_bench(have, set) then return false end
        local refusal = resize_refusal(name, "RecipeSets", #have, #have + 1)
        if refusal then error(refusal, 0) end
        change(name, "RecipeSets", function(list)
            if not on_bench(list, set) then list[#list + 1] = handle_of(set) end
            return list
        end)
        return true
    end
end

function prepare.RemoveBench(bench)
    local set = bench_of(bench).set
    return function(name, lenient)
        local have = basis(name, "RecipeSets")
        if not on_bench(have, set) then
            if lenient then return false end
            error(("%s is not made at %s. It is made at %s"):format(name, set, listing(bench_names(have))), 0)
        end
        if #have == 1 then error(NO_BENCH:format(name), 0) end
        local refusal = resize_refusal(name, "RecipeSets", #have, #have - 1)
        if refusal then error(refusal, 0) end
        change(name, "RecipeSets", function(list)
            local at = on_bench(list, set)
            if not at then return list end
            if #list == 1 then error(NO_BENCH:format(name), 0) end
            table.remove(list, at)
            return list
        end)
        return true
    end
end

function prepare.SetRequirement(node)
    local wanted = "None"
    if node ~= nil then
        if type(node) ~= "string" then
            error(("a node of the tech tree is named by a string such as \"Stone_Axe\", or nil for no research, got %s"):format(shown(node)), 0)
        end
        if lower(node) ~= "none" and node ~= "" then
            wanted = spelled(TALENTS, node)
            if not wanted then
                error(("the tech tree has no node named '%s'.%s"):format(node, suggest.phrase(node, names_of(TALENTS))), 0)
            end
        end
    end
    return function(name)
        set_field(name, "Requirement", { RowName = wanted })
        return true
    end
end

function prepare.Hide()
    return function(name)
        set_field(name, "bForceDisableRecipe", true)
        return true
    end
end

function prepare.Show()
    return function(name)
        set_field(name, "bForceDisableRecipe", false)
        return true
    end
end

local CHANGES = { "SetInputs", "SetInput", "RemoveInput", "ScaleInputs", "ScaleInput", "SetOutputs", "SetOutput", "ScaleOutputs", "SetWork",
                  "SetSeconds", "ScaleTime", "SetBenches", "AddBench", "RemoveBench", "MoveTo", "SetRequirement", "Hide", "Show" }

-- Runs a check of what a mod wrote. When it turns out to need every template, they are read first, outside the pcall.
local function checked(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok and result == SCAN then
        load_templates()
        ok, result = pcall(fn, ...)
    end
    return ok, result
end

-- recipes and lists of recipes

local recipe_names = setmetatable({}, { __mode = "k" })    -- recipe object -> its row name
local interned = setmetatable({}, { __mode = "v" })        -- folded row name -> the one recipe object for it
local list_names = setmetatable({}, { __mode = "k" })      -- list object -> the names in it
local Recipe, List, recipe_meta, list_meta = {}, {}, nil, nil
local RECIPE_NAMES = { "Name", "Inputs", "Tags", "Resources", "Outputs", "Benches", "Work", "Requirement", "Hidden", "GetSeconds", "Reset" }
local LIST_NAMES = { "Each", "GetNames", "Reset" }
for index = 1, #CHANGES do
    RECIPE_NAMES[#RECIPE_NAMES + 1] = CHANGES[index]
    LIST_NAMES[#LIST_NAMES + 1] = CHANGES[index]
end

local function recipe_for(real)
    local key = lower(real)
    local found = interned[key]
    if not found then
        found = setmetatable({}, recipe_meta)
        recipe_names[found] = real
        interned[key] = found
    end
    return found
end

local function list_for(names)
    local found = setmetatable({}, list_meta)
    list_names[found] = names
    return found
end

for _, method in ipairs(CHANGES) do
    local make = prepare[method]
    Recipe[method] = function(self, ...)
        local real = recipe_names[self]
        if not real then error(("call %s with a colon: recipe:%s(...)"):format(method, method), 2) end
        local ok, act = checked(make, ...)
        if not ok then error(clean(act), 2) end
        local done, problem = pcall(act, real, false)
        if not done then error(clean(problem), 2) end
        return self
    end
    List[method] = function(self, ...)
        local names = list_names[self]
        if not names then error(("call %s with a colon: list:%s(...)"):format(method, method), 2) end
        local ok, act = checked(make, ...)
        if not ok then error(clean(act), 2) end
        local failed, first = 0, nil
        local pause = pacer()
        for index = 1, #names do
            pause()
            local done, problem = pcall(act, names[index], true)
            if not done then
                failed = failed + 1
                first = first or clean(problem)
            end
        end
        if failed > 0 then
            error(("%s could not change %d of %d recipes. The first: %s"):format(method, failed, #names, first), 2)
        end
        return self
    end
end

local function reset(name)
    local tbl = table_of(RECIPES)
    local ok, count = pcall(tbl.Reset, tbl, name)
    if not ok then error(name .. ": " .. clean(count), 0) end
    return count
end

function Recipe:Reset()
    local real = recipe_names[self]
    if not real then error("call Reset with a colon: recipe:Reset()", 2) end
    local ok, count = pcall(reset, real)
    if not ok then error(clean(count), 2) end
    return count
end

function List:Reset()
    local names = list_names[self]
    if not names then error("call Reset with a colon: list:Reset()", 2) end
    local total, first = 0, nil
    local pause = pacer()
    for index = 1, #names do
        pause()
        local ok, count = pcall(reset, names[index])
        if ok then total = total + count else first = first or clean(count) end
    end
    if first then error(first, 2) end
    return total
end

function Recipe:GetSeconds(bench)
    local real = recipe_names[self]
    if not real then error("call GetSeconds with a colon: recipe:GetSeconds()", 2) end
    local ok, seconds = pcall(function()
        return basis(real, "RequiredMillijoules") / speed_for(real, bench ~= nil and bench_of(bench) or nil)
    end)
    if not ok then error(clean(seconds), 2) end
    return seconds
end

local reads = {}

function reads.Name(name) return name end

function reads.Inputs(name)
    local out = {}
    for index, entry in ipairs(basis(name, "Inputs")) do
        local item = tostring(name_in(ITEM, entry))
        out[index] = { Item = spelled(ITEMS, item) or item, Count = entry.Count }
    end
    return out
end

function reads.Tags(name)
    local out = {}
    for index, entry in ipairs(basis(name, "QueryInputs")) do
        out[index] = { Tag = tostring(name_in(KINDS[2], entry)), Count = entry.Count }
    end
    return out
end

function reads.Resources(name)
    local out = {}
    for index, entry in ipairs(basis(name, "ResourceInputs")) do
        out[index] = { Resource = tostring(name_in(KINDS[3], entry)), Units = entry.RequiredUnits }
    end
    return out
end

function reads.Outputs(name)
    local out = {}
    for index, entry in ipairs(basis(name, "Outputs")) do
        local template = template_in(entry)
        out[index] = { Item = item_of(template), Count = entry.Count, Template = spelled(TEMPLATES, template) or template }
    end
    return out
end

function reads.Benches(name) return bench_names(basis(name, "RecipeSets")) end
function reads.Work(name) return basis(name, "RequiredMillijoules") end
function reads.Hidden(name) return basis(name, "bForceDisableRecipe") == true end

function reads.Requirement(name)
    local handle = basis(name, "Requirement")
    local node = type(handle) == "table" and handle.RowName
    if type(node) ~= "string" or node == "" or lower(node) == "none" then return nil end
    return node
end

recipe_meta = {
    __index = function(self, key)
        local method = Recipe[key]
        if method then return method end
        local read = reads[key]
        if read then
            local ok, value = pcall(read, recipe_names[self])
            if not ok then error(clean(value), 2) end
            return value
        end
        error(("%s is not a member of a recipe.%s"):format(tostring(key), suggest.phrase(tostring(key), RECIPE_NAMES)), 2)
    end,
    __newindex = function(_, key)
        error(("recipe.%s cannot be assigned. A recipe is changed with its functions, such as SetInputs"):format(tostring(key)), 2)
    end,
    __tostring = function(self) return "Recipe(" .. tostring(recipe_names[self]) .. ")" end,
    __names = function() return RECIPE_NAMES end,
}

-- Calls fn(recipe) for each recipe of the list, in order.
function List:Each(fn)
    local names = list_names[self]
    if not names then error("call Each with a colon: list:Each(fn)", 2) end
    if type(fn) ~= "function" then error(("Each takes a function that gets a recipe, got %s"):format(shown(fn)), 2) end
    local pause = pacer()
    for index = 1, #names do
        pause()
        fn(recipe_for(names[index]))
    end
    return self
end

function List:GetNames()
    local names = list_names[self]
    if not names then error("call GetNames with a colon: list:GetNames()", 2) end
    return table.move(names, 1, #names, 1, {})
end

list_meta = {
    __index = function(self, key)
        local method = List[key]
        if method then return method end
        if math.type(key) == "integer" then
            local name = list_names[self][key]
            return name and recipe_for(name) or nil
        end
        error(("%s is not a member of a list of recipes.%s"):format(tostring(key), suggest.phrase(tostring(key), LIST_NAMES)), 2)
    end,
    __newindex = function(_, key)
        error(("a list of recipes cannot be assigned to (%s). It holds the recipes it was made with"):format(tostring(key)), 2)
    end,
    __len = function(self) return #list_names[self] end,
    __tostring = function(self) return ("Recipes(%d)"):format(#list_names[self]) end,
    __names = function() return LIST_NAMES end,
}

-- game.Recipes

local Recipes, api = {}, {}
local NAMES = { "Get", "Has", "All", "At", "Making", "Using", "Find", "Add" }

local function colon(self, method)
    if not rawequal(self, Recipes) then error(("call %s with a colon: game.Recipes:%s(...)"):format(method, method), 3) end
end

function api.Get(self, name)
    colon(self, "Get")
    local ok, real = pcall(recipe_name, name)
    if not ok then error(clean(real), 2) end
    return recipe_for(real)
end

function api.Has(self, name)
    colon(self, "Has")
    return type(name) == "string" and spelled(RECIPES, name) ~= nil
end

function api.All(self)
    colon(self, "All")
    local ok, names = pcall(function() return table_of(RECIPES):GetNames() end)
    if not ok then error(clean(names), 2) end
    return list_for(names)
end

local library_gone = false      -- a miss is slow, so the game is asked once
local answers = {}              -- folded set -> what the game answered. UE4SS never frees the list it hands over, so a set is asked once per write

-- True in a prospect. Replaced in tests.
function M.in_prospect()
    return Wax.import("engine.game").root.InProspect == true
end

-- The game's own list of a set's recipes, or nil when the game is not asked or does not answer. It leaves hidden recipes out.
local function ask_game(set)
    if not M.ASK_GAME or library_gone then return nil end
    if not M.ASK_ANYWHERE then
        local known, there = pcall(M.in_prospect)
        if not (known and there) then return nil end
    end
    -- the journal counts every write to the table as it is made
    local counted, written = pcall(function() return journal.count(T.record_of(table_of(RECIPES)).key) end)
    local kept = counted and answers[lower(set)]
    if kept and kept.written == written then return kept.names end
    local started = M.clock()
    local ok, names = pcall(function()
        local library = StaticFindObject(LIBRARY)
        if not library:IsValid() then return nil end
        local list = library:GetAllRecipeRowsForSet({ RowName = FName(set), DataTableName = FName("D_" .. SETS) })
        if type(list) ~= "table" then return nil end
        local out = {}
        for index = 1, #list do out[index] = list[index]:get().RowName:ToString() end
        return out
    end)
    stats.asked = stats.asked + 1
    stats.ask_seconds = stats.ask_seconds + (M.clock() - started)
    if not ok or not names then
        library_gone = true
        tell_once("library", "the game did not say which recipes a bench has, so the recipe table is read for it: %s",
            ok and "its function library was not found" or clean(names))
        return nil
    end
    if counted then answers[lower(set)] = { names = names, written = written } end
    return names
end

local function listed_at(value, set)
    return value("bForceDisableRecipe") ~= true and on_bench(value("RecipeSets") or {}, set) ~= nil
end

function api.At(self, bench)
    colon(self, "At")
    local ok, at = pcall(bench_of, bench)
    if not ok then error(clean(at), 2) end
    local set = at.set
    local asked = ask_game(set)
    if not asked then
        return list_for(select_rows(AT_FIELDS, function(_, value) return listed_at(value, set) end))
    end
    local done, names = pcall(function()
        local member = {}
        for index = 1, #asked do member[lower(asked[index])] = true end
        -- the game answers from the table as it is, with what the mod left in it before it was loaded again
        local own, owner = stale()
        for key, fields in pairs(own or {}) do
            if fields.RecipeSets or fields.bForceDisableRecipe then
                local real = spelled(RECIPES, key)
                if real and (left_behind(own, owner, real, "RecipeSets") or left_behind(own, owner, real, "bForceDisableRecipe")) then
                    member[key] = listed_at(function(field) return basis(real, field) end, set) or nil
                end
            end
        end
        local out, all = {}, table_of(RECIPES):GetNames()
        for index = 1, #all do
            if member[lower(all[index])] then out[#out + 1] = all[index] end
        end
        return out
    end)
    if not done then error(clean(names), 2) end
    return list_for(names)
end

function api.Using(self, what)
    colon(self, "Using")
    local ok, kind, real = pcall(input_of, what)
    if not ok then error(clean(kind), 2) end
    local fields = { kind.field .. "." .. kind.key .. "." .. kind.sub }
    return list_for(select_rows(fields, function(_, value) return place_of(value(kind.field) or {}, kind, real) ~= nil end))
end

function api.Making(self, what)
    colon(self, "Making")
    local ok, wanted = checked(function()
        if type(what) ~= "string" then error(("an item is named by a string such as \"Rope\", got %s"):format(shown(what)), 0) end
        local set = {}
        local item = spelled(ITEMS, what)
        if item then
            for _, template in ipairs(templates_of(item)) do set[lower(template)] = true end
        else
            local template = spelled(TEMPLATES, what)
            if not template then
                error(("there is no item named '%s'.%s"):format(what, suggest.phrase(what, names_of(ITEMS))), 0)
            end
            set[lower(template)] = true
        end
        return set
    end)
    if not ok then error(clean(wanted), 2) end
    return list_for(select_rows(OUT_FIELDS, function(_, value)
        for _, entry in ipairs(value("Outputs") or {}) do
            if wanted[lower(template_in(entry))] then return true end
        end
        return false
    end))
end

function api.Find(self, fn)
    colon(self, "Find")
    if type(fn) ~= "function" then
        error(("Find takes a function that gets a recipe and returns true for the ones to keep, got %s"):format(shown(fn)), 2)
    end
    local ok, names = pcall(function() return table_of(RECIPES):GetNames() end)
    if not ok then error(clean(names), 2) end
    local out = {}
    local pause = pacer()
    for index = 1, #names do
        pause()
        if fn(recipe_for(names[index])) then out[#out + 1] = names[index] end
    end
    return list_for(out)
end

local ADD_OPTIONS = { "like", "inputs", "outputs", "benches", "seconds", "work", "requirement", "hidden" }
local ROWS_OFF = "game.Recipes:Add is switched off in this version of Wax: adding a row to the game's tables while the game runs "
    .. "has not been seen working yet. Recipes the game has can be changed, and Hide takes one off the lists"

function api.Add(self, name, options)
    colon(self, "Add")
    local writer = tables.writer
    if not (writer and writer.WRITES and writer.WRITES.rows) then error(ROWS_OFF, 2) end
    local ok, steps = checked(function()
        if type(options) ~= "table" then
            error(("Add takes the new recipe's name and a table such as { like = \"Stone_Axe\", inputs = { Stone = 1 } }, got %s")
                :format(shown(options)), 0)
        end
        for key in pairs(options) do
            local known = false
            for _, option in ipairs(ADD_OPTIONS) do known = known or option == key end
            if not known then
                error(("Add has no option named %s.%s"):format(shown(key),
                    type(key) == "string" and suggest.phrase(key, ADD_OPTIONS) or ""), 0)
            end
        end
        if type(options.like) ~= "string" then
            error("Add needs a recipe to start from, such as { like = \"Stone_Axe\" }", 0)
        end
        if options.seconds ~= nil and options.work ~= nil then error("Add takes seconds or work, not both", 0) end
        if options.hidden ~= nil and type(options.hidden) ~= "boolean" then error("hidden is true or false", 0) end
        local out = { like = recipe_name(options.like) }
        if options.inputs ~= nil then out[#out + 1] = prepare.SetInputs(options.inputs) end
        if options.outputs ~= nil then out[#out + 1] = prepare.SetOutputs(options.outputs) end
        if options.benches ~= nil then out[#out + 1] = prepare.SetBenches(options.benches) end
        if options.work ~= nil then out[#out + 1] = prepare.SetWork(options.work) end
        if options.seconds ~= nil then out[#out + 1] = prepare.SetSeconds(options.seconds) end
        if options.requirement ~= nil then
            out[#out + 1] = prepare.SetRequirement(options.requirement ~= false and options.requirement or nil)
        end
        if options.hidden ~= nil then out[#out + 1] = options.hidden and prepare.Hide() or prepare.Show() end
        return out
    end)
    if not ok then error(clean(steps), 2) end
    local tbl = table_of(RECIPES)
    local added, real = pcall(tbl.Add, tbl, name, nil, { like = steps.like })
    if not added then error(clean(real), 2) end
    for index = 1, #steps do
        local done, problem = pcall(steps[index], real, false)
        if not done then
            pcall(tbl.Reset, tbl, real)
            error(clean(problem), 2)
        end
    end
    return recipe_for(real)
end

setmetatable(Recipes, {
    __index = function(_, key)
        local found = api[key]
        if found then return found end
        error(("%s is not a member of game.Recipes.%s"):format(tostring(key), suggest.phrase(tostring(key), NAMES)), 2)
    end,
    __newindex = function(_, key)
        error(("game.Recipes.%s cannot be assigned because game.Recipes is read-only"):format(tostring(key)), 2)
    end,
    __tostring = function() return "Recipes" end,
    __names = function() return NAMES end,
})

-- what was worked out from other tables is dropped when they change

local function forget(key)
    if key == nil or key == lower(PROCESSING) or key == lower(SETS) or key == lower(ITEMS) then
        model, resolved = nil, {}
    end
    if key == nil or key == lower(TEMPLATES) or key == lower(ITEMS) then
        item_by_template, templates_by_item = {}, nil
    end
    if key == nil or key == lower(RECIPES) or key == lower(SETS) then answers = {} end
    if key == nil then library_gone, output_lists = false, nil end
end

local function on_changed(name)
    forget(name ~= nil and lower(tostring(name)) or nil)
end

local written = nil         -- the recipes written in this frame, for one word to the crafting screen: { lists, rows, frame }

local function tell_screen()
    local sent = written
    written = nil
    if not sent then return end
    local crafting = Wax.modules["world.crafting"]
    local screen = type(crafting) == "table" and crafting.api
    if type(screen) ~= "table" or not screen.Refresh then return end
    stats.refreshes = stats.refreshes + 1
    local ok, problem = pcall(screen.Refresh, screen, { lists = sent.lists, recipes = sent.rows })
    if not ok then tell_once("refresh", "the crafting screen could not be asked to show a changed recipe: %s", clean(problem)) end
end

-- A recipe was written, for a mod or because a mod unloaded: the crafting screen that shows is asked to follow, once a frame.
local function on_patched(table_name, row, field)
    local key = lower(tostring(table_name))
    forget(key)
    if key ~= lower(RECIPES) then return end
    local frame = sched.stats.frame
    if not written or frame - written.frame > 1 then
        written = { lists = false, rows = {}, frame = frame }
        local previous = scope.enter(nil)
        local ok = pcall(task.defer, tell_screen)
        scope.leave(previous)
        if not ok then written = nil return end
    end
    written.rows[#written.rows + 1] = row
    if field == nil or LISTED[field] then written.lists = true end
end

function M.start()
    data = tables.api
    local old = rawget(Wax, "recipes_live")
    if old then
        for _, connection in pairs(old) do connection:Disconnect() end
    end
    local live = {}
    rawset(Wax, "recipes_live", live)
    -- the listening belongs to no mod
    local previous = scope.enter(nil)
    local ok, problem = pcall(function()
        live.changed = data.Changed:Connect(on_changed)
        live.patched = data.Patched:Connect(on_patched)
    end)
    scope.leave(previous)
    if not ok then error(problem, 0) end
    rawset(Wax.import("engine.game").root, "Recipes", Recipes)
end

function M.stats()
    local out = {}
    for name, value in pairs(stats) do out[name] = value end
    return out
end

M.api = Recipes
return M
