-- Builds the Recipe Browser's model and needs lines on the game's real tables and compares them with the
-- numbers scripts\recipe_check.py worked out on its own. Each difference names the table and field behind it.
-- Run from the workspace root, after the Python:
--   tools\lua\lua54\lua.exe wax\tests\offline\recipe_data_check.lua luamods\RecipeBrowser build\recipe-browser\check

local folder, check = arg and arg[1], arg and arg[2]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end
if check then check = check:gsub("\\", "/"):gsub("/+$", "") end

local function file_exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
end

local function folder_exists(path)
    local ok, _, code = os.rename(path, path)
    return ok == true or code == 13
end

local function skip(why)
    print("recipe-data: 0 passed (skipped: " .. why .. ")")
    os.exit(0)
end

if not folder or not file_exists(folder .. "/model.lua") then skip("Recipe Browser is not here") end
if not folder_exists("game-data/data") then skip("game-data is not here") end
if not check or not file_exists(check .. "/tables.lua") or not file_exists(check .. "/expected.lua") then
    skip("run python scripts\\recipe_check.py first")
end

local function part(name) return assert(loadfile(folder .. "/" .. name .. ".lua"))() end

local source, tags, model, unlock = part("source"), part("tags"), part("model"), part("unlock")
local fixture = dofile("wax/tests/offline/recipe_fixture.lua")
local tables = dofile(check .. "/tables.lua")
local E = dofile(check .. "/expected.lua")

local passed, failed, shown = 0, 0, {}
local LIMIT = 12

local function show(value)
    if type(value) == "string" then return ("%q"):format(value) end
    return tostring(value)
end

local function differ(group, what, got, want, where)
    failed = failed + 1
    shown[group] = (shown[group] or 0) + 1
    if shown[group] <= LIMIT then
        io.stderr:write(("DIFF %s: the mod has %s, the check has %s   (%s)\n"):format(what, show(got), show(want), where))
    end
end

local function same(group, what, got, want, where)
    local equal = got == want
    if not equal and type(got) == "number" and type(want) == "number" then equal = math.abs(got - want) < 1e-9 end
    if equal then passed = passed + 1 else differ(group, what, got, want, where) end
end

-- the mod, on the same tables

local text = { needs = {} }
for _, piece in ipairs({ "known", "mission_only", "no_talent", "no_station", "level", "pack", "mission", "talent" }) do
    text.needs[piece] = E.text[piece]
end
function text.join(...)
    local parts = {}
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if type(value) == "table" then
            for _, inner in ipairs(value) do
                if inner ~= "" then parts[#parts + 1] = inner end
            end
        elseif value ~= nil and value ~= "" then
            parts[#parts + 1] = value
        end
    end
    return table.concat(parts, E.text.join)
end

local provider = fixture.serve(tables)
local src = source.new(provider)
src.read_all(1)
local built, m, b = pcall(model.build, src, nil, string.lower, tags)
if not built then
    io.stderr:write("DIFF model.build failed on the game's tables: " .. tostring(m) .. "\n")
    print("recipe-data: 0 passed, 1 failed")
    os.exit(1)
end
local index = unlock.index(src, nil, text)

for _, problem in ipairs(src.problems) do
    differ("source", "D_" .. problem.table .. (problem.field and ("." .. problem.field) or ""), "a problem", "none", problem.message)
end
for _, entry in ipairs(m.missing) do
    differ("missing", "D_" .. entry.table .. "." .. tostring(entry.row or entry.field or ""), "missing", "there",
        "an anchor row or a table the model needs")
end
same("stage", "the load stage the model reached", m.stage, 3, "every stage should join")
same("index", "the needs index", index.off, false, "D_Talents and the flag tables")
same("clashes", "row names in two flag tables", #index.clashes, 0, "D_CharacterFlags, D_SessionFlags, D_AccountFlags, D_DLCPackageData")

local function joined(list, separator) return table.concat(list or {}, separator or " ") end

local function amounts(list, key)
    local out = {}
    for position, entry in ipairs(list) do out[position] = (entry.count or entry.units) .. " " .. entry[key] end
    return table.concat(out, ", ")
end

local function size(list_index, key) return #(list_index[key] or {}) end

-- counts and the numbers the plan names

local COUNT_FROM = {
    items = "D_ItemsStatic rows, kinds from D_ItemTemplate.ItemCustomStats", shown = "D_TagQueries.FieldGuide_Hide over the tags of D_ItemsStatic",
    hidden = "D_TagQueries.FieldGuide_Hide over the tags of D_ItemsStatic", bare = "D_ItemsStatic.Itemable",
    seeds = "D_ItemTemplate.ItemCustomStats and D_FarmingSeeds", flags = "D_ItemTemplate.ItemCustomStats and D_NationalFlags",
    titles = "D_ProcessorRecipes.ItemIconOverride", dropped = "kinds of a static against D_ProcessorRecipes.Outputs and Inputs",
    recipes = "D_ProcessorRecipes rows", skipped_recipes = "handles in D_ProcessorRecipes to rows that are not there",
    made = "D_ProcessorRecipes.Outputs", used = "D_ProcessorRecipes.Inputs and QueryInputs",
}
for name, want in pairs(E.counts) do same("counts", "count " .. name, m.counts[name], want, COUNT_FROM[name] or "") end

local function bench_seconds(recipe_id, set_id, bench_key)
    local number, set = m.recipe[recipe_id], m.sets[set_id]
    if not number or not set then return nil end
    for _, bench in ipairs(set.benches) do
        if bench.item == bench_key and bench.mw > 0 then return m.recipes[number].mj / bench.mw end
    end
    return nil
end

local function recipe_of(recipe_id)
    return m.recipe[recipe_id] and m.recipes[m.recipe[recipe_id]] or nil
end

local function speeds(set_id)
    local seen, list = {}, {}
    for _, bench in ipairs(m.sets[set_id] and m.sets[set_id].benches or {}) do
        if not seen[bench.mw] then
            seen[bench.mw] = true
            list[#list + 1] = bench.mw
        end
    end
    table.sort(list)
    return joined(list)
end

local function bench_items(set_id)
    local list = {}
    for position, bench in ipairs(m.sets[set_id] and m.sets[set_id].benches or {}) do list[position] = bench.item end
    return joined(list)
end

local function needs_of(recipe_id)
    local number = m.recipe[recipe_id]
    if not number then return nil end
    local line = unlock.describe(index, m, m.recipes[number])
    return line.short .. " / " .. line.full .. " / " .. line.extra
end

local function in_order(names, list_of, make)
    local out = {}
    for _, name in ipairs(src.names(names)) do
        local entry = list_of[name:lower()]
        local value = entry and make(entry)
        if value then out[#out + 1] = value end
    end
    return out
end

-- Each kind of named number: what the mod has for it, and the table and field behind it.
local NAMED = {
    kept = function(entry) return m.items[entry.key] ~= nil, "D_ItemsStatic." .. entry.key .. " is used by recipes, so it stays an entry" end,
    dropped = function(entry) return b.dropped[entry.key] == true, "D_ItemsStatic." .. entry.key .. ": every recipe makes one of its kinds" end,
    made_by = function(entry) return size(m.made_by, entry.key), "D_ProcessorRecipes.Outputs through D_ItemTemplate" end,
    used_in = function(entry) return size(m.used_in, entry.key), "D_ProcessorRecipes.Inputs and QueryInputs" end,
    tag_items = function(entry) return joined(m.tag_items[entry.key]), "D_CraftingTags.Query over the tags of D_ItemsStatic" end,
    benches = function(entry) return bench_items(entry.key), "D_ItemsStatic.Processing and D_Processing.DefaultRecipeSet" end,
    speeds = function(entry) return speeds(entry.key), "D_Processing.MaxMilliwattage" end,
    seconds = function(entry)
        return bench_seconds(entry.key, entry.set, entry.bench), "D_ProcessorRecipes.RequiredMillijoules over D_Processing.MaxMilliwattage"
    end,
    title = function(entry)
        local recipe = recipe_of(entry.key)
        return recipe and recipe.title or "", "D_ProcessorRecipes.ItemIconOverride.ItemStaticData"
    end,
    title_name = function(entry)
        local recipe = recipe_of(entry.key)
        return recipe and recipe.title and m.items[recipe.title].name or "", "D_Itemable.DisplayName of the override"
    end,
    hints = function(entry)
        return m.items[entry.key] and joined(m.items[entry.key].hints, " | ") or "", "D_FieldGuideMetaData.Description1 to 3"
    end,
    workshop_items = function()
        local count = 0
        for _, item in ipairs(m.list) do
            if item.workshop then count = count + 1 end
        end
        return count, "D_WorkshopItems.Item through D_ItemTemplate"
    end,
    resource_links = function()
        return joined(in_order("IcarusResources", m.resources, function(resource)
            return resource.link and (resource.key .. "=" .. resource.link)
        end)), "D_IcarusResources against the FieldGuide_ rows of D_ItemsStatic"
    end,
    levels = function()
        return joined(in_order("FeatureLevels", m.levels, function(level) return level.key .. "=" .. level.name end), " | "),
            "D_FeatureLevels.Icon and D_DLCPackageData.DLCName"
    end,
    needs = function(entry) return needs_of(entry.key), "D_Talents, D_TalentTrees, D_TalentArchetypes and the flag tables" end,
    xp = function(entry)
        local recipe = recipe_of(entry.key)
        return recipe and recipe.xp and recipe.xp[entry.set],
            "D_ItemsStatic.CraftingExperience of what it takes, D_RecipeSets.ExperienceMultiplier, D_ProcessorRecipes.ExperienceMultiplier"
    end,
}
for _, entry in ipairs(E.named) do
    local what = (entry.kind .. " " .. entry.key):gsub(" $", "")
    local mine = NAMED[entry.kind]
    if mine then
        local got, where = mine(entry)
        same("named", what, got, entry.value, where)
    else
        differ("named", what, "nothing to compare", entry.value, "the check names it")
    end
end

-- every item, recipe, set, tag, resource, level, category and needs line

local function compare(group, fields, expected, record_of, where)
    local seen = {}
    for key, want in pairs(expected) do
        seen[key] = true
        local got = record_of(key)
        if not got then
            differ(group, group .. " " .. key, "nothing", "an entry", where.entry)
        else
            for position, field in ipairs(fields) do
                same(group, group .. " " .. key .. "." .. field, got[position], want[position], where[field] or where.entry)
            end
        end
    end
    return seen
end

local item_seen = compare("item", E.item_fields, E.items, function(key)
    local item = m.items[key]
    if not item then return nil end
    local marks = (item.title_only and "T" or "") .. (item.workshop and "W" or "") .. (item.bare and "B" or "")
    return { item.name, item.row, item.static, item.hidden, item.order, joined(item.cats), size(m.made_by, key), size(m.used_in, key),
        m.uses[key] or 0, item.level or "", joined(item.bench), marks, joined(item.hints, " | "), item.resource or "", item.weight,
        item.stack, item.icon or "" }
end, {
    entry = "D_ItemsStatic, and the kinds from D_ItemTemplate.ItemCustomStats",
    name = "D_Itemable.DisplayName", row = "the row name, or the template a recipe makes for a kind", static = "D_ItemTemplate.ItemStaticData",
    hidden = "D_TagQueries.FieldGuide_Hide over Manual_Tags and Generated_Tags, or no Itemable",
    order = "D_FieldGuideCategories.DisplayOrder of the category it is listed under", cats = "D_FieldGuideCategories.TagQuery",
    made = "D_ProcessorRecipes.Outputs, ResourceOutputs and ItemIconOverride", used = "D_ProcessorRecipes.Inputs, QueryInputs, ResourceInputs",
    uses = "used, without the recipes whose every output is hidden", level = "the MetaTable of D_ItemsStatic and D_FeatureLevels.Icon",
    bench = "D_ItemsStatic.Processing and D_Processing.DefaultRecipeSet", marks = "ItemIconOverride (T), D_WorkshopItems (W), no Itemable (B)",
    hints = "D_FieldGuideMetaData.Description1 to 3", resource = "D_IcarusResources", weight = "D_Itemable.Weight",
    stack = "D_Itemable.MaxStack", icon = "D_Itemable.Icon",
})
for key in pairs(m.items) do
    if not item_seen[key] then differ("item", "item " .. key, "an entry", "nothing", "D_ItemsStatic and D_ItemTemplate") end
end

-- "character=52 crafting_bench=52": what one craft gives at each set, in the recipe's order of sets
local function xp_line(recipe)
    local out = {}
    for position, id in ipairs(recipe.xp and recipe.sets or {}) do out[position] = id .. "=" .. math.tointeger(recipe.xp[id]) end
    return table.concat(out, " ")
end

local recipe_seen = compare("recipe", E.recipe_fields, E.recipes, function(key)
    local number = m.recipe[key]
    local recipe = number and m.recipes[number]
    if not recipe then return nil end
    return { recipe.row, amounts(recipe.inputs, "item"), amounts(recipe.tags_in, "tag"), amounts(recipe.res_in, "res"),
        amounts(recipe.outputs, "item"), amounts(recipe.res_out, "res"), joined(recipe.sets), joined(recipe.stations), recipe.mj,
        recipe.title or "", recipe.talent or "", recipe.char_flag or "", recipe.session or "", recipe.random, recipe.disabled,
        recipe.hidden_only, recipe.level or "", xp_line(recipe) }
end, {
    xp = "D_ItemsStatic.CraftingExperience and D_IcarusResources.CraftingExperience of what it takes, ExperienceMultiplier of the set and the recipe",
    entry = "D_ProcessorRecipes", row = "D_ProcessorRecipes row name", inputs = "D_ProcessorRecipes.Inputs",
    tags_in = "D_ProcessorRecipes.QueryInputs", res_in = "D_ProcessorRecipes.ResourceInputs", outputs = "D_ProcessorRecipes.Outputs through D_ItemTemplate",
    res_out = "D_ProcessorRecipes.ResourceOutputs", sets = "D_ProcessorRecipes.RecipeSets",
    stations = "D_ProcessorRecipes.RecipeSets that an item provides", mj = "D_ProcessorRecipes.RequiredMillijoules",
    title = "D_ProcessorRecipes.ItemIconOverride.ItemStaticData", talent = "D_ProcessorRecipes.Requirement",
    char_flag = "D_ProcessorRecipes.CharacterRequirement", session = "D_ProcessorRecipes.SessionRequirement",
    random = "D_ProcessorRecipes.bSelectOutputItemRandomly", disabled = "D_ProcessorRecipes.bForceDisableRecipe",
    hidden_only = "the hide rule over its outputs", level = "the MetaTable of D_ProcessorRecipes",
})
for _, recipe in ipairs(m.recipes) do
    if not recipe_seen[recipe.id] then differ("recipe", "recipe " .. recipe.id, "an entry", "nothing", "D_ProcessorRecipes") end
end

compare("set", E.set_fields, E.sets, function(key)
    local set = m.sets[key]
    if not set then return nil end
    local benches = {}
    for position, bench in ipairs(set.benches) do benches[position] = bench.item .. "@" .. bench.mw end
    return { set.row, set.name, set.group, set.link or "", set.icon or "", set.auto, set.hand == true, joined(benches), set.shown,
        size(m.made_at, key) }
end, {
    entry = "D_RecipeSets", name = "D_RecipeSets.RecipeSetName", group = "sets with one RecipeSetName", link = "the shown item that provides it",
    icon = "D_RecipeSets.RecipeSetIcon, none without a bench", auto = "D_Processing.AutoSelectRecipe", hand = "D_RecipeSets.Character",
    benches = "D_ItemsStatic.Processing, D_Processing.DefaultRecipeSet and MaxMilliwattage", made_at = "D_ProcessorRecipes.RecipeSets",
})

compare("tag", E.tag_fields, E.tags, function(key)
    local tag = m.tags[key]
    return tag and { tag.name, tag.icon or "", joined(m.tag_items[key]) }
end, { entry = "D_CraftingTags", name = "D_CraftingTags.TagName", icon = "D_CraftingTags.TagIcon",
    items = "D_CraftingTags.Query over the tags of D_ItemsStatic" })

compare("resource", E.resource_fields, E.resources, function(key)
    local resource = m.resources[key]
    return resource and { resource.name, resource.units, resource.link or "", resource.icon or "", size(m.res_used, key), size(m.res_made, key) }
end, { entry = "D_IcarusResources", link = "the FieldGuide_ item with its row name or display name",
    used = "D_ProcessorRecipes.ResourceInputs", made = "D_ProcessorRecipes.ResourceOutputs" })

compare("level", E.level_fields, E.levels, function(key)
    local level = m.levels[key]
    return level and { level.name, level.icon }
end, { entry = "D_FeatureLevels rows with an Icon", name = "D_DLCPackageData.DLCName, else D_FeatureLevels.DisplayName" })
for key in pairs(m.levels) do
    if not E.levels[key] then differ("level", "level " .. key, "an entry", "nothing", "D_FeatureLevels.Icon") end
end

same("category", "number of categories", #m.categories, #E.categories, "D_FieldGuideCategories")
for position, want in ipairs(E.categories) do
    local category = m.categories[position]
    local got = category and { category.key, category.name, category.order, category.count, joined(category.subs) } or {}
    for at, field in ipairs(E.category_fields) do
        same("category", "category " .. position .. "." .. field, got[at], want[at], "D_FieldGuideCategories and its TagQuery")
    end
end

compare("needs", E.needs_fields, E.needs, function(key)
    local number = m.recipe[key]
    if not number then return nil end
    local line = unlock.describe(index, m, m.recipes[number])
    return { line.short, line.full, line.extra, line.tone, line.missing }
end, { entry = "D_ProcessorRecipes.Requirement, SessionRequirement, CharacterRequirement",
    short = "D_Talents, D_TalentTrees.Archetype, D_TalentArchetypes", full = "D_Talents.DisplayName or ExtraData, D_TalentArchetypes",
    extra = "D_Talents.RequiredFlags and Rewards, D_DLCPackageData, D_AccountFlags, D_ProspectList", tone = "the parts above",
    missing = "D_ProcessorRecipes.Requirement names a row D_Talents lacks" })

same("list", "length of the item list", #m.list, #E.list, "D_ItemsStatic and D_FieldGuideCategories.DisplayOrder")
for position, key in ipairs(E.list) do
    local item = m.list[position]
    if not item or item.key ~= key then
        differ("list", "place " .. position .. " in the item list", item and item.key or "nothing", key,
            "D_FieldGuideCategories.DisplayOrder, then D_Itemable.DisplayName")
        break
    end
    passed = passed + 1
end

local skipped = {}
for position, entry in ipairs(m.skipped) do skipped[position] = entry.table .. "." .. entry.row end
table.sort(skipped)
same("skipped", "handles to rows that are not there", #skipped, #E.skipped, "every table")
for position, want in ipairs(E.skipped) do
    if skipped[position] ~= want then
        differ("skipped", "skipped handle " .. position, skipped[position] or "nothing", want, "a handle whose row is missing")
        break
    end
    passed = passed + 1
end

for group, count in pairs(shown) do
    if count > LIMIT then io.stderr:write(("     ... and %d more differences in %s\n"):format(count - LIMIT, group)) end
end
print(("model on the game's tables: %d items (%d shown), %d seed kinds, %d flags, %d recipes, %d sets"):format(
    m.counts.items, m.counts.shown, m.counts.seeds, m.counts.flags, m.counts.recipes, #m.set_list))
print(("recipe-data: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
