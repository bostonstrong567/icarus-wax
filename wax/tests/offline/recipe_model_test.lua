-- Offline tests for the Recipe Browser's table lists, tag queries, model and number formats.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\recipe_model_test.lua luamods\RecipeBrowser

local t = dofile("wax/tests/offline/harness.lua")

local folder = arg and arg[1]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end

local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
end

if not folder or not exists(folder .. "/model.lua") then
    print("recipe-model: 0 passed (skipped: Recipe Browser is not here)")
    os.exit(0)
end

-- The files get the standard library and nothing else, so a use of Wax or the engine fails here.
local function part(name)
    local env = { string = string, table = table, math = math, select = select, type = type, pairs = pairs, ipairs = ipairs,
        next = next, tostring = tostring, tonumber = tonumber, setmetatable = setmetatable, getmetatable = getmetatable,
        error = error, pcall = pcall, rawget = rawget, rawset = rawset }
    setmetatable(env, { __index = function(_, key) error(name .. ".lua reads the global '" .. tostring(key) .. "'", 2) end })
    local chunk = assert(loadfile(folder .. "/" .. name .. ".lua", "t", env))
    local value = chunk()
    assert(type(value) == "table", name .. ".lua must return a table")
    return value
end

local source, tags, model, format = part("source"), part("tags"), part("model"), part("format")
local fixture = dofile("wax/tests/offline/recipe_fixture.lua")

local function build(provider, options)
    options = options or {}
    local src = source.new(provider)
    src.read_all(1)
    local m, b = model.build(src, options.pause, options.lower or string.lower, tags)
    return m, src, b
end

local provider = fixture.provider()
local m, src = build(provider)

local function recipe(name)
    local number = m.recipe[name]
    return number and m.recipes[number], number
end

local function joined(list) return table.concat(list or {}, " ") end

local function names_of(numbers)
    local out = {}
    for index, number in ipairs(numbers or {}) do out[index] = m.recipes[number].id end
    return table.concat(out, " ")
end

local function pairs_of(list, key)
    local out = {}
    for index, entry in ipairs(list) do out[index] = entry.count .. " " .. entry[key] end
    return table.concat(out, ", ")
end

local function has(list, value)
    for _, entry in ipairs(list or {}) do
        if entry == value then return true end
    end
    return false
end

local function missing_has(model_built, name, row, field)
    for _, entry in ipairs(model_built.missing) do
        if entry.table == name and entry.row == row and entry.field == field then return true end
    end
    return false
end

local function skipped_has(model_built, name, row)
    for _, entry in ipairs(model_built.skipped) do
        if entry.table == name and entry.row == row then return true end
    end
    return false
end

-- ---------------------------------------------------------------- source.lua

t.test("lists: three stages, every table of the plan, real field paths", function()
    local seen, stages = {}, {}
    for _, entry in ipairs(source.lists()) do
        seen[entry.table] = true
        stages[entry.stage] = (stages[entry.stage] or 0) + 1
        t.ok(entry.stage >= 1 and entry.stage <= source.STAGES, entry.table .. " has a stage")
        for _, field in ipairs(entry.fields) do
            t.ok(not field:find("DataTableName", 1, true), entry.table .. " never reads a handle's table: " .. field)
        end
    end
    for _, name in ipairs({ "ItemsStatic", "Itemable", "ItemTemplate", "FarmingSeeds", "NationalFlags", "FieldGuideCategories",
        "FieldGuideSubcategories", "TagQueries", "ProcessorRecipes", "RecipeSets", "Processing", "CraftingTags", "IcarusResources",
        "FieldGuideMetaData", "WorkshopItems", "FieldGuideRedirect", "Talents", "TalentTrees", "TalentArchetypes", "DLCPackageData",
        "AccountFlags", "ProspectList", "CharacterFlags", "SessionFlags", "FeatureLevels" }) do
        t.ok(seen[name], name .. " is listed")
    end
    t.ok(stages[1] and stages[2] and stages[3], "each stage has tables")
end)

t.test("lists: names-only tables, the MetaTables, and a copy each time", function()
    local by_table = {}
    for _, entry in ipairs(source.lists()) do
        by_table[entry.table .. (entry.meta and ":meta" or "") .. ":" .. entry.stage] = entry
    end
    t.eq(by_table["CharacterFlags:3"].rows, "names")
    t.eq(#by_table["CharacterFlags:3"].fields, 0)
    t.eq(by_table["SessionFlags:3"].rows, "names")
    t.eq(by_table["FieldGuideSubcategories:1"].rows, "request")
    t.eq(by_table["TagQueries:1"].rows, "named")
    t.eq(by_table["TagQueries:2"].rows, "named")
    t.eq(joined(by_table["TagQueries:1"].fields), "Query.TagDictionary.TagName Query.QueryTokenStream")
    t.eq(joined(by_table["ItemsStatic:meta:3"].fields), "RequiredFeatureLevel.RowName")
    t.eq(joined(by_table["ProcessorRecipes:meta:3"].fields), "RequiredFeatureLevel.RowName")
    by_table["Itemable:1"].fields[1] = "Changed"
    t.eq(source.lists()[2].fields[1], "DisplayName", "a caller cannot change the lists")
end)

t.test("source: rows in any letter case, names in table order, a miss asks nothing", function()
    t.eq(src.names("FarmingSeeds")[1], "Invalid")
    t.eq(src.names("FarmingSeeds")[3], "Plum")
    t.eq(src.position("FarmingSeeds", "plum"), 3)
    t.ok(src.has("ItemsStatic", "PEBBLE"))
    t.ok(not src.has("ItemsStatic", "Boulder"))
    t.eq(src.row("Itemable", "ITEM_PEBBLE").DisplayName, "Pebble")
    t.eq(src.row("Itemable", "item_pebble"), src.row("Itemable", "Item_Pebble"), "one table per row")
    local before = provider.calls
    t.eq(src.row("Itemable", "Item_Boulder"), nil)
    t.eq(src.row("Itemable", nil), nil)
    t.eq(src.row("Itemable", "Item_Pebble").MaxStack, 100)
    t.eq(provider.calls, before, "a loaded table answers from Lua")
end)

t.test("source: only the tag queries other tables name are loaded", function()
    local fresh = fixture.provider()
    local reader = source.new(fresh)
    reader.read(1)
    reader.read(2)
    local before = fresh.calls
    t.ok(reader.row("TagQueries", "Any_Tool"), "named by a category")
    t.ok(reader.row("TagQueries", "FieldGuide_Hide"), "always read")
    t.ok(reader.row("TagQueries", "Any_Fish"), "named by a crafting tag")
    t.eq(fresh.calls, before)
    t.ok(reader.row("TagQueries", "Never_Asked"), "read when asked")
    t.ok(fresh.calls > before, "that one was read from the provider")
    local after = fresh.calls
    reader.row("TagQueries", "Never_Asked")
    t.eq(fresh.calls, after, "and kept")
end)

t.test("source: the feature level comes from the MetaTable, or from the row's Metadata block", function()
    t.eq(src.level("ItemsStatic", "lathe"), "FarLands")
    t.eq(src.level("ItemsStatic", "Pebble"), nil)
    t.eq(src.level("ProcessorRecipes", "Gear"), "FarLands")
    local files = source.new(fixture.provider({ meta = false }))
    files.read_all(1)
    t.eq(files.level("ItemsStatic", "LATHE"), "FarLands")
    t.eq(files.level("ItemsStatic", "Press"), "Harvest")
    t.eq(files.level("ItemsStatic", "Pebble"), nil)
    t.eq(files.level("ProcessorRecipes", "Gear"), "FarLands")
end)

t.test("source: a budget function is asked for every table and passed on", function()
    local asked, given = 0, {}
    local inner = fixture.provider()
    local wrapped = {
        Has = function(_, name) return inner:Has(name) end,
        Table = function(_, name)
            local object = inner:Table(name)
            return setmetatable({ Load = function(_, request)
                given[#given + 1] = request.budget
                return object:Load(request)
            end }, { __index = object })
        end,
    }
    local reader = source.new(wrapped)
    reader.read(1, function()
        asked = asked + 1
        return 4
    end)
    t.ok(asked >= 7, "asked per table")
    t.ok(#given >= 6, "tables were loaded")
    for _, budget in ipairs(given) do t.eq(budget, 4) end
end)

t.test("source: a stamp per table and one for all of them", function()
    t.eq(src.stamp("FarmingSeeds"), "4:0x1")
    t.eq(source.new(fixture.provider()).stamp("NotATable"), "")
    local tables = fixture.copy()
    tables.Itemable.stamp = "0x2"
    local other = source.new(fixture.serve(tables))
    t.ok(other.stamps() ~= src.stamps(), "another address gives another stamp")
    t.ok(src.stamps():find("FarmingSeeds=4:0x1;NationalFlags=2:0x1;", 1, true), "tables in the order of the lists")
    t.eq(m.stamp, src.stamps())
end)

t.test("source: a missing table is named once and its part is switched off", function()
    local tables = fixture.copy()
    tables.WorkshopItems = nil
    local built, reader = build(fixture.serve(tables))
    t.eq(#reader.problems, 1)
    t.eq(reader.problems[1].table, "WorkshopItems")
    t.eq(reader.problems[1].field, nil)
    t.ok(reader.broken.WorkshopItems)
    t.ok(missing_has(built, "WorkshopItems", nil, nil))
    t.ok(built.off.workshop)
    t.eq(built.items.steel_knife.workshop, nil)
    t.eq(#built.recipes, #m.recipes, "the rest is as before")
    t.eq(built.stage, 3)
end)

t.test("source: a table that cannot be loaded is named with what the provider said", function()
    local inner = fixture.provider()
    local wrapped = {
        Has = function(_, name) return inner:Has(name) end,
        Table = function(_, name)
            local object = inner:Table(name)
            if name ~= "FieldGuideMetaData" then return object end
            return setmetatable({ Load = function() error("the table keeps changing", 0) end }, { __index = object })
        end,
    }
    local built, reader = build(wrapped)
    t.eq(#reader.problems, 1)
    t.eq(reader.problems[1].table, "FieldGuideMetaData")
    t.eq(reader.problems[1].message, "the table keeps changing")
    t.ok(built.off.hints)
    t.eq(built.items.pebble.hints, nil)
    t.eq(#built.recipes, #m.recipes)
end)

t.test("source: a MetaTable that cannot be read is named and costs only the expansion names", function()
    local inner = fixture.provider()
    local wrapped = {
        Has = function(_, name) return inner:Has(name) end,
        Table = function(_, name)
            local object = inner:Table(name)
            if name ~= "ItemsStatic" then return object end
            return setmetatable({ Meta = function()
                return { Load = function() error("RequiredFeatureLevel is not a field", 0) end }
            end }, { __index = object })
        end,
    }
    local built, reader = build(wrapped)
    t.eq(#reader.problems, 1)
    t.eq(reader.problems[1].table .. "." .. reader.problems[1].field, "ItemsStatic.MetaTable")
    t.eq(reader.broken.ItemsStatic, nil, "the table itself is fine")
    t.ok(missing_has(built, "ItemsStatic", nil, "MetaTable"))
    t.eq(built.off.list, nil)
    t.eq(#built.list, #m.list)
    t.eq(built.items.lathe.level, nil)
    t.eq(built.recipes[built.recipe.gear].level, "farlands", "the recipes' MetaTable still answers")
end)

t.test("source: a row of a table that was not loaded yet is read when asked for", function()
    local fresh = fixture.provider()
    local reader = source.new(fresh)
    local before = fresh.calls
    t.eq(reader.row("Itemable", "item_twig").DisplayName, "Twig")
    t.ok(fresh.calls > before)
    local after = fresh.calls
    t.eq(reader.row("Itemable", "ITEM_TWIG").MaxStack, 200)
    t.eq(fresh.calls, after, "the second ask is answered from Lua")
    t.eq(reader.row("Itemable", "Item_Nothing"), nil)
    t.eq(reader.row("NotATable", "Row"), nil)
    t.eq(reader.problems[1].table, "NotATable")
end)

t.test("source: a field the game dropped is named, and the part that reads it is off", function()
    local tables = fixture.copy()
    tables.ProcessorRecipes.defaults.RequiredMillijoules = nil
    for _, row in ipairs(tables.ProcessorRecipes.rows) do row.RequiredMillijoules = nil end
    local built, reader = build(fixture.serve(tables))
    t.eq(#reader.problems, 1)
    t.eq(reader.problems[1].table, "ProcessorRecipes")
    t.eq(reader.problems[1].field, "RequiredMillijoules")
    t.ok(missing_has(built, "ProcessorRecipes", nil, "RequiredMillijoules"))
    t.ok(built.off.recipes)
    t.eq(#built.recipes, 0)
    t.ok(#built.list > 40, "the item list still shows")
    t.eq(built.items.pebble.name, "Pebble")
end)

-- ---------------------------------------------------------------- tags.lua

local function q(names, stream)
    local dictionary = {}
    for index, name in ipairs(names) do dictionary[index] = { TagName = name } end
    return { TagDictionary = dictionary, QueryTokenStream = stream }
end

local function asks(query, ...)
    return tags.matches(tags.parse(query), tags.set({ ... }))
end

t.test("tags: any, all and none of a list of tags", function()
    local any = q({ "A.B", "C" }, { 0, 1, 1, 2, 0, 1 })
    t.ok(asks(any, "c"))
    t.ok(asks(any, "x", "a.b"))
    t.ok(not asks(any, "x"))
    local all = q({ "A.B", "C" }, { 0, 1, 2, 2, 0, 1 })
    t.ok(asks(all, "a.b", "c"))
    t.ok(not asks(all, "c"))
    local none = q({ "A.B", "C" }, { 0, 1, 3, 2, 0, 1 })
    t.ok(asks(none, "x"))
    t.ok(not asks(none, "c"))
    t.ok(asks(none), "nothing tagged has none of them")
end)

t.test("tags: a tag satisfies its parents and nothing that only starts alike", function()
    local fish = q({ "NPC.Fish" }, { 0, 1, 1, 1, 0 })
    t.ok(asks(fish, "NPC.Fish.Saltwater"))
    t.ok(asks(fish, "npc.fish"))
    t.ok(not asks(fish, "NPC.Fishy"))
    t.ok(not asks(fish, "NPC"))
    t.ok(asks(q({ "npc" }, { 0, 1, 1, 1, 0 }), "NPC.Fish.Saltwater"))
end)

t.test("tags: expressions inside expressions", function()
    -- all of: any(A, B), none(C)
    local hide = q({ "A", "B", "C" }, { 0, 1, 5, 2, 1, 2, 0, 1, 3, 1, 2 })
    t.ok(asks(hide, "a"))
    t.ok(asks(hide, "b.x"))
    t.ok(not asks(hide, "a", "c"))
    t.ok(not asks(hide, "d"))
    -- any of: all(A, B), all(C)
    local either = q({ "A", "B", "C" }, { 0, 1, 4, 2, 2, 2, 0, 1, 2, 1, 2 })
    t.ok(asks(either, "c"))
    t.ok(asks(either, "a", "b"))
    t.ok(not asks(either, "a"))
    -- none of: any(A)
    local neither = q({ "A" }, { 0, 1, 6, 1, 1, 1, 0 })
    t.ok(asks(neither, "b"))
    t.ok(not asks(neither, "a"))
end)

t.test("tags: a query with no root, an empty one and a broken one match nothing", function()
    t.eq(tags.parse(q({ "A" }, { 0, 0 })), nil)
    t.eq(tags.parse(q({}, {})), nil)
    t.eq(tags.parse(nil), nil)
    t.ok(not tags.matches(nil, tags.set({ "a" })))
    local tree, problem = tags.parse(q({ "A" }, { 0, 1, 1, 2, 0, 5 }))
    t.eq(tree, nil)
    t.ok(problem and problem:find("dictionary", 1, true), "says the dictionary lacks the tag")
    tree, problem = tags.parse(q({ "A" }, { 0, 1, 9, 1, 0 }))
    t.eq(tree, nil)
    t.ok(problem and problem:find("breaks", 1, true))
    tree, problem = tags.parse(q({ "A" }, { 0, 1, 4, 3, 1, 1, 0 }))
    t.eq(tree, nil, "a stream that ends early")
    tree, problem = tags.parse(q({ "A", "B" }, { 0, 1, 5, 2, 1, 6, 0, 1 }))
    t.eq(tree, nil)
    t.ok(problem and problem:find("ends early", 1, true), problem)
end)

t.test("tags: numbers that arrive as floats still parse", function()
    t.ok(asks(q({ "A" }, { 0.0, 1.0, 1.0, 1.0, 0.0 }), "a"))
end)

t.test("tags: the union of two containers, each tag once, in lower case", function()
    local list = tags.union({ GameplayTags = { { TagName = "Thing.Tool" }, { TagName = "A" } } },
        { GameplayTags = { { TagName = "thing.tool" }, { TagName = "B" }, { TagName = "None" } } })
    t.eq(joined(list), "thing.tool a b")
    t.eq(#tags.union(nil, nil), 0)
    t.eq(joined(tags.union(nil, { GameplayTags = { { TagName = "X.Y" } } })), "x.y")
end)

t.test("tags: a set is emptied before it is filled again", function()
    local scratch = {}
    tags.set({ "a.b" }, scratch)
    t.ok(scratch["a"] and scratch["a.b"])
    tags.set({ "c" }, scratch)
    t.ok(scratch["c"] and not scratch["a"] and not scratch["a.b"])
end)

-- ---------------------------------------------------------------- format.lua

t.test("format: weights", function()
    t.eq(format.weight(10), "10 g")
    t.eq(format.weight(999), "999 g")
    t.eq(format.weight(1000), "1 kg")
    t.eq(format.weight(1500), "1.5 kg")
    t.eq(format.weight(1250), "1.25 kg")
    t.eq(format.weight(12345), "12.3 kg")
    t.eq(format.weight(250000), "250 kg")
    t.eq(format.weight(0), "")
    t.eq(format.weight(nil), "")
    t.eq(format.weight(0.5), "0.5 g")
end)

t.test("format: seconds from work and power", function()
    t.eq(format.seconds(2500, 1000), "2.5 s")
    t.eq(format.seconds(7500, 250), "30 s")
    t.eq(format.seconds(7500, 325), "23 s")
    t.eq(format.seconds(2500, 3000), "0.83 s")
    t.eq(format.seconds(5000, 2500), "2 s")
    t.eq(format.seconds(200000, 250), "800 s")
    t.eq(format.seconds(1, 100000), "", "a trade")
    t.eq(format.seconds(1, 0.5), "", "nothing at one millijoule, whatever the bench")
    t.eq(format.seconds(2, 0.5), "4 s")
    t.eq(format.seconds(0, 1000), "")
    t.eq(format.seconds(2500, 0), "")
    t.eq(format.seconds(nil, 1000), "")
    t.eq(format.seconds(2500, nil), "")
end)

t.test("format: litres without the unit", function()
    t.eq(format.litres(100), "0.1")
    t.eq(format.litres(50), "0.05")
    t.eq(format.litres(250), "0.25")
    t.eq(format.litres(1500), "1.5")
    t.eq(format.litres(2000), "2")
    t.eq(format.litres(150000), "150")
    t.eq(format.litres(2500000), "2,500")
    t.eq(format.litres(0), "0")
    t.eq(format.litres(nil), "")
end)

t.test("format: counts", function()
    t.eq(format.count(1), "1")
    t.eq(format.count(12), "12")
    t.eq(format.count(9999), "9,999")
    t.eq(format.count(10000), "10k")
    t.eq(format.count(12345), "12k")
    t.eq(format.count(150000), "150k")
    t.eq(format.count(2.5), "2.5")
    t.eq(format.count(nil), "")
    t.eq(format.thousands(2668), "2,668")
    t.eq(format.thousands(1234567), "1,234,567")
    t.eq(format.thousands(0), "0")
    t.eq(format.thousands(-1500), "-1,500")
    t.eq(format.thousands(999), "999")
end)

t.test("format: the unit words can be replaced", function()
    local kept = format.units.gram
    format.units.gram = "gr"
    t.eq(format.weight(10), "10 gr")
    format.units.gram = kept
end)

-- ---------------------------------------------------------------- model.lua on the fixture

t.test("model: nothing in the fixture is missing, and the build is whole", function()
    t.eq(#src.problems, 0)
    t.eq(#m.missing, 0)
    t.eq(next(m.off), nil)
    t.eq(m.stage, 3)
    t.eq(type(model.version), "number")
    t.eq(m.version, model.version)
    t.eq(m.counts.items, #m.list)
    t.eq(m.counts.shown + m.counts.hidden, m.counts.items)
    t.eq(m.counts.recipes, #m.recipes)
end)

t.test("case: a plain hand recipe", function()
    local made, number = recipe("stone_knife")
    t.ok(made, "the recipe is there")
    t.eq(made.row, "Stone_Knife")
    t.eq(pairs_of(made.inputs, "item"), "2 pebble, 1 twig")
    t.eq(pairs_of(made.outputs, "item"), "1 stone_knife")
    t.eq(joined(made.sets), "character")
    t.eq(joined(made.stations), "character")
    t.eq(made.mj, 2500, "the table's default work")
    t.eq(made.talent, "stone_knife")
    t.ok(not made.random and not made.disabled and not made.hidden_only)
    t.eq(joined(m.made_by.stone_knife), tostring(number))
    t.ok(has(m.used_in.twig, number))
    t.ok(has(m.made_at.character, number))
    local hand = m.sets.character
    t.ok(hand.hand, "the set made by hand is marked")
    t.eq(hand.benches[1].item, "field_kit")
    t.eq(hand.link, "fieldguide_character", "it links to the guide's own entry, not to its first bench")
    t.eq(format.seconds(made.mj, hand.benches[1].mw), "2.5 s")
    t.eq(joined(m.items.fieldguide_character.bench), "character")
end)

t.test("case: three benches", function()
    local made = recipe("gear")
    t.eq(joined(made.sets), "work_table lathe press")
    t.eq(joined(made.stations), "work_table lathe press")
    t.eq(pairs_of(made.outputs, "item"), "2 gear")
    t.eq(m.sets.lathe.benches[1].item, "lathe")
    t.eq(m.sets.lathe.benches[1].mw, 2500)
    t.eq(m.sets.work_table.benches[1].mw, 1000, "the table's default power")
    t.eq(m.sets.lathe.link, "lathe")
    t.eq(joined(m.items.lathe.bench), "lathe")
end)

t.test("case: two benches of one set at different speeds", function()
    local set = m.sets.hearth
    t.eq(#set.benches, 3)
    t.eq(set.benches[1].item .. " " .. set.benches[1].mw, "big_hearth 500")
    t.eq(set.benches[2].item .. " " .. set.benches[2].mw, "hearth 250")
    t.eq(set.benches[3].item, "quest_hearth", "a hidden bench comes after the shown ones, wherever its row is")
    t.eq(set.shown, 2)
    t.eq(set.link, "hearth", "the bench named like the set, not the first one")
    t.ok(set.auto)
    t.ok(not m.sets.lathe.auto)
    local made = recipe("baked_fish")
    t.eq(format.seconds(made.mj, set.benches[1].mw), "15 s")
    t.eq(format.seconds(made.mj, set.benches[2].mw), "30 s")
end)

t.test("case: a tag input with parent tags", function()
    local made, number = recipe("baked_fish")
    t.eq(#made.inputs, 0)
    t.eq(made.tags_in[1].tag, "any_fish")
    t.eq(made.tags_in[1].count, 2)
    t.eq(joined(m.tag_items.any_fish), "river_trout sea_bass")
    t.eq(m.tags.any_fish.name, "Fish")
    t.ok(m.tags.any_fish.icon)
    t.ok(has(m.used_in.sea_bass, number), "an item that fits the tag is used in the recipe")
    t.ok(has(m.used_in.river_trout, number))
    t.eq(m.used_in.flour and has(m.used_in.flour, number) or false, false)
end)

t.test("case: a resource input", function()
    local made, number = recipe("dough")
    t.eq(made.res_in[1].res, "water")
    t.eq(made.res_in[1].units, 100)
    t.eq(format.litres(made.res_in[1].units), "0.1")
    t.ok(has(m.res_used.water, number))
    t.eq(m.resources.water.name, "Water")
    t.eq(m.resources.water.units, "L")
    t.ok(m.resources.water.icon)
end)

t.test("case: a resource is all a recipe makes", function()
    local made, number = recipe("pump_water")
    t.eq(#made.outputs, 0)
    t.eq(made.res_out[1].res .. " " .. made.res_out[1].units, "water 500")
    t.ok(not made.hidden_only)
    t.eq(joined(m.res_made.water), tostring(number))
end)

t.test("case: resources link to their guide items by row name, then by display name", function()
    t.eq(m.resources.water.link, "fieldguide_water")
    t.eq(m.items.fieldguide_water.resource, "water")
    t.eq(names_of(m.used_in.fieldguide_water), "dough mint_tea")
    t.eq(names_of(m.made_by.fieldguide_water), "pump_water")
    t.eq(m.resources.energy.link, "fieldguide_power", "Energy is called Power, like the item")
    t.eq(m.items.fieldguide_power.resource, "energy")
    t.eq(m.used_in.fieldguide_power, nil)
    t.eq(m.resources.steam.link, nil)
    t.eq(m.resources.invalid.link, nil)
end)

t.test("case: several outputs", function()
    local made, number = recipe("butcher_trout")
    t.eq(pairs_of(made.outputs, "item"), "2 fish_meat, 1 fish_bone")
    t.ok(has(m.made_by.fish_meat, number) and has(m.made_by.fish_bone, number))
    t.ok(not made.random)
end)

t.test("case: one output picked at random", function()
    local made, number = recipe("crack_geode")
    t.ok(made.random)
    t.eq(#made.outputs, 3)
    t.ok(has(m.made_by.pebble, number) and has(m.made_by.ruby, number) and has(m.made_by.opal, number))
end)

t.test("case: two seed templates with one number are one kind, and the plain seed stays because it is used", function()
    local oat = m.items["seed:oat"]
    t.ok(oat, "the kind is an entry")
    t.eq(oat.name, "Oat Seed")
    t.eq(oat.static, "seed")
    t.eq(oat.variant.stat, "SeedType_Enum")
    t.eq(oat.variant.value, 1)
    t.eq(oat.row, "Oat_Seed", "the template a recipe makes, not the first in the table")
    t.ok(oat.icon and oat.icon:find("Oat_Seed", 1, true))
    t.eq(m.items["seed:plum"].name, "Plum Seed")
    t.eq(m.counts.seeds, 2)
    local made = recipe("oat_seeds")
    t.eq(pairs_of(made.outputs, "item"), "2 seed:oat")
    t.eq(names_of(m.made_by["seed:oat"]), "oat_seeds")
    local plain = m.items.seed
    t.ok(plain, "the plain seed is kept")
    t.eq(names_of(m.made_by.seed), "oat_seeds plum_seeds", "it lists every seed recipe")
    t.eq(names_of(m.used_in.seed), "seed_mash")
    t.eq(m.used_in["seed:oat"], m.used_in.seed, "a kind is used where its static is")
    t.eq(m.uses["seed:oat"], 1)
    t.eq(joined(oat.cats), joined(plain.cats))
end)

t.test("case: seed number 0 is the row Invalid, which is no kind", function()
    t.eq(m.items["seed:invalid"], nil)
    t.eq(m.items["seed:test_seed"], nil, "a row no template names is no entry")
    t.ok(m.items.seed.workshop, "the template with number 0 leads to the plain seed")
    t.ok(not m.items["seed:oat"].workshop)
end)

t.test("case: a flag family whose plain static is dropped", function()
    t.eq(m.items.banner, nil, "nothing uses the plain banner and every recipe makes a kind")
    t.eq(m.made_by.banner, nil)
    t.eq(m.counts.dropped, 1)
    t.eq(m.counts.flags, 2)
    local north = m.items["banner:north"]
    t.eq(north.name, "North Banner")
    t.eq(north.variant.value, 0, "for flags number 0 is a real row")
    t.eq(north.variant.stat, "NationalFlag_Enum")
    t.eq(names_of(m.made_by["banner:north"]), "banner_north")
    t.eq(m.items["banner:south"].name, "South Banner")
    for _, item in ipairs(m.list) do t.ok(item.key ~= "banner", "the list does not hold it") end
    t.ok(not skipped_has(m, "ItemsStatic", "Banner"), "a dropped static is not counted as missing")
end)

t.test("case: handles that differ from their row only in letter case", function()
    t.eq(m.items.pebble.name, "Pebble", "ItemsStatic names item_pebble, the row is Item_Pebble")
    t.eq(m.items.pebble.stack, 100)
    local made = recipe("stone_knife")
    t.eq(made.inputs[1].item, "pebble", "the recipe names PEBBLE")
    t.eq(made.outputs[1].item, "stone_knife")
    t.eq(made.sets[1], "character")
    for _, entry in ipairs(m.skipped) do t.ok(entry.from ~= "ProcessorRecipes.Stone_Knife", "nothing of it was skipped") end
end)

t.test("case: a missing template or input skips the recipe and is counted", function()
    t.eq(recipe("ghost"), nil)
    t.eq(recipe("broken_in"), nil)
    t.eq(m.counts.skipped_recipes, 2)
    t.ok(skipped_has(m, "ItemTemplate", "Ghost_Template"))
    t.ok(skipped_has(m, "ItemsStatic", "Not_An_Item"))
    t.ok(skipped_has(m, "ItemsStatic", "Not_There"), "a template that names a missing static")
    for _, number in ipairs(m.used_in.pebble) do t.ok(m.recipes[number].id ~= "ghost") end
end)

t.test("case: a set that is not in the table is dropped from the recipe and counted", function()
    local made = recipe("dough")
    t.eq(joined(made.sets), "work_table")
    t.ok(skipped_has(m, "RecipeSets", "Gone_Bench"))
end)

t.test("case: a recipe that names its set twice is listed there once", function()
    local made, number = recipe("nails")
    t.eq(joined(made.sets), "work_table")
    t.eq(joined(made.stations), "work_table")
    local times = 0
    for _, listed in ipairs(m.made_at.work_table) do
        if listed == number then times = times + 1 end
    end
    t.eq(times, 1)
end)

t.test("case: an item that fits two categories is listed under the one with fewer items", function()
    local item = m.items.spork
    t.eq(joined(item.fits), "tools food")
    t.eq(joined(item.cats), "tools")
    t.eq(item.order, 1)
end)

t.test("case: a recipe at one millijoule has no time", function()
    local made = recipe("trade_ruby")
    t.eq(made.mj, 1)
    t.eq(format.seconds(made.mj, m.sets.trader.benches[1].mw), "")
end)

t.test("case: an icon override on a shared container template", function()
    local tea, tea_number = recipe("mint_tea")
    local juice, juice_number = recipe("plum_juice")
    t.eq(tea.title, "drink_mint_tea")
    t.eq(juice.title, "drink_plum_juice")
    t.eq(tea.outputs[1].item, "cup")
    t.eq(juice.outputs[1].item, "cup")
    t.eq(joined(m.made_by.cup), tea_number .. " " .. juice_number)
    local entry = m.items.drink_mint_tea
    t.ok(entry.title_only)
    t.ok(not entry.hidden, "a title can be found in the list")
    t.eq(entry.name, "Mint Tea")
    t.eq(joined(m.made_by.drink_mint_tea), tostring(tea_number))
    t.eq(m.counts.titles, 2)
    t.ok(not tea.hidden_only)
    t.ok(not m.items.cup.title_only)
end)

t.test("case: a hidden twin keeps its own recipe and stays hidden", function()
    local shown, hidden = m.items.ruby, m.items.ruby_quest
    t.eq(shown.name, hidden.name)
    t.ok(hidden.hidden and not shown.hidden)
    t.eq(names_of(m.made_by.ruby), "crack_geode")
    t.eq(names_of(m.made_by.ruby_quest), "ruby_quest")
end)

t.test("case: a recipe whose every output is hidden", function()
    local made, number = recipe("ruby_quest")
    t.ok(made.hidden_only)
    t.ok(has(m.used_in.pebble, number), "it is in the index")
    t.eq(m.uses.pebble, #m.used_in.pebble - 1, "and left out of the count")
    t.ok(not recipe("crack_geode").hidden_only)
end)

t.test("case: the hide rule is the game's query, with its exception, plus no Itemable", function()
    t.ok(m.items.trader_npc.hidden)
    t.ok(m.items.crust_red.hidden)
    t.ok(not m.items.quest_map.hidden, "Thing.Secret with Guide.Show is shown")
    local bare = m.items.ghost_mesh
    t.ok(bare.hidden and bare.bare)
    t.eq(bare.name, "Ghost_Mesh")
    t.eq(bare.icon, nil)
    t.eq(m.counts.bare, 1)
    t.eq(m.counts.hidden, 6)
end)

t.test("case: a set with no providing item has no picture and no link", function()
    local set = m.sets.kiln
    t.eq(#set.benches, 0)
    t.eq(set.icon, nil)
    t.eq(set.link, nil)
    t.eq(set.name, "Kiln")
    local made = recipe("brick")
    t.eq(joined(made.sets), "kiln")
    t.eq(#made.stations, 0)
    t.eq(joined(recipe("baked_fish").stations), "hearth", "a set with no bench is not a station")
end)

t.test("case: a set whose only provider is hidden keeps its picture and is not a link", function()
    local set = m.sets.trader
    t.eq(#set.benches, 1)
    t.eq(set.shown, 0)
    t.ok(set.icon)
    t.eq(set.link, nil)
    t.eq(joined(recipe("trade_ruby").stations), "trader")
end)

t.test("case: two sets with one display name share a group", function()
    t.eq(m.sets.loom_a.group, "loom_a")
    t.eq(m.sets.loom_b.group, "loom_a")
    t.eq(m.sets.hearth.group, "hearth")
    t.eq(m.sets.loom_a.link, "loom")
end)

t.test("case: a hint row for an item that recipes also make", function()
    t.eq(joined(m.items.pebble.hints), "Pick up Break rocks")
    t.eq(#m.items.pebble.hints, 2)
    t.ok(#m.made_by.pebble > 0)
    t.eq(m.items.twig.hints, nil)
    t.ok(skipped_has(m, "ItemsStatic", "Nowhere"), "a hint for a missing item is counted")
end)

t.test("case: a workshop row leads through its template", function()
    t.ok(m.items.steel_knife.workshop)
    t.eq(m.items.stone_knife.workshop, nil)
    t.ok(skipped_has(m, "ItemTemplate", "Gone_Template"))
end)

t.test("case: an item tagged only in Manual_Tags is still put in its category", function()
    t.eq(joined(m.items.odd_spoon.cats), "tools")
    t.eq(joined(m.items.odd_spoon.tags), "thing.tool")
    t.eq(m.items.odd_spoon.order, 1)
end)

t.test("case: only a feature level with an Icon is named, by its pack when one matches", function()
    t.eq(m.levels.farlands.name, "Far Lands Expansion", "the DLC row Far_Lands, trimmed")
    t.eq(m.levels.deepmines.name, "Deep Mines", "no DLC row: its own name")
    t.eq(m.levels.harvest, nil, "no Icon: a free update")
    t.eq(m.levels.core, nil)
    t.eq(m.items.lathe.level, "farlands")
    t.eq(m.items.big_hearth.level, "deepmines")
    t.eq(m.items.press.level, nil)
    t.eq(m.items.pebble.level, nil)
    t.eq(m.items.seed.level, "deepmines")
    t.eq(m.items["seed:oat"].level, "deepmines", "a kind has its static's level")
    t.eq(m.items["banner:north"].level, nil)
    t.eq(recipe("gear").level, "farlands")
    t.eq(recipe("dough").level, nil)
end)

t.test("case: the guide's redirect gives one item the uses of the hidden ones it stands for", function()
    t.eq(names_of(m.used_in.ore_crust), "clean_red clean_blue")
    t.eq(m.uses.ore_crust, 2)
    t.eq(names_of(m.used_in.crust_red), "clean_red")
end)

t.test("model: categories in the guide's order, without the hidden one", function()
    local keys = {}
    for index, category in ipairs(m.categories) do keys[index] = category.key end
    t.eq(joined(keys), "tools food benches other")
    t.eq(m.category.tools.name, "Tools")
    t.eq(m.category.tools.count, 7)
    t.eq(m.category.food.count, 10, "the spork fits it too and is counted with the tools")
    t.eq(m.category.benches.count, 6, "the hidden bench is not counted")
    t.eq(m.category.other.count, 0)
    t.eq(m.category.hidden, nil)
    t.eq(joined(m.category.tools.subs), "Tools_Sharp", "a subcategory that is not there is left out")
    t.ok(skipped_has(m, "FieldGuideSubcategories", "Tools_Gone"))
end)

t.test("model: the list is in category order, then by name", function()
    local first, last_tool
    for index, item in ipairs(m.list) do
        if index == 1 then first = item end
        if item.order == 1 then last_tool = index end
        if index > 1 then
            local before = m.list[index - 1]
            t.ok(before.order < item.order or (before.order == item.order and before.lower <= item.lower), item.key .. " is in order")
        end
    end
    t.eq(first.key, "bone_saw")
    t.eq(last_tool, 7)
    t.eq(m.list[5].key, "spork", "among the tools, though it is food too")
    t.eq(m.list[8].key, "baked_fish")
end)

t.test("model: subcategories are worked out on request and kept", function()
    local before = provider.calls
    local subs = model.subcategories(m, src, tags, "food")
    t.eq(#subs, 1)
    t.eq(subs[1].key, "food_fish")
    t.eq(subs[1].name, "River Fish")
    t.ok(subs[1].items.river_trout and not subs[1].items.sea_bass)
    t.eq(subs[1].count, 1)
    t.ok(provider.calls > before, "its rows were read now")
    local after = provider.calls
    t.eq(model.subcategories(m, src, tags, "food"), subs)
    t.eq(provider.calls, after)
    t.eq(#model.subcategories(m, src, tags, "nothing"), 0)
    t.eq(#model.subcategories(m, src, tags, "benches"), 0)
    local sharp = model.subcategories(m, src, tags, "tools")
    t.ok(sharp[1].items.stone_knife and not sharp[1].items.bucket)
end)

t.test("model: names are lowered with the function passed in", function()
    local built = build(fixture.provider(), { lower = function(name) return "~" .. name:upper() end })
    t.eq(built.items.pebble.lower, "~PEBBLE")
    t.eq(built.sets.hearth.link, "hearth")
    t.eq(built.sets.loom_b.group, "loom_a")
end)

t.test("model: pause is called every PAUSE_ROWS rows", function()
    local kept = model.PAUSE_ROWS
    t.eq(kept, 150)
    local function pauses_at(rows)
        local pauses = 0
        model.PAUSE_ROWS = rows
        local ok, err = pcall(build, fixture.provider(), { pause = function() pauses = pauses + 1 end })
        model.PAUSE_ROWS = kept
        t.ok(ok, err)
        return pauses
    end
    local usual, often, never = pauses_at(kept), pauses_at(5), pauses_at(1000000)
    t.eq(never, 0)
    t.ok(usual >= 1 and usual <= 4, "the fixture is a slice or two: " .. usual)
    t.ok(often > 20 * usual, "a smaller slice pauses more often: " .. often)
end)

t.test("model: the three stages can be joined one at a time", function()
    local reader = source.new(fixture.provider())
    local b = model.begin(reader, string.lower, tags)
    reader.read(1)
    model.items(b)
    t.eq(b.model.stage, 1)
    t.ok(#b.model.list > 40, "the list can show")
    t.ok(b.model.items.banner, "the plain banner is there until recipes are known")
    t.ok(b.model.items["seed:oat"])
    t.eq(#b.model.recipes, 0)
    reader.read(2)
    -- while stage 2 is being joined over many frames, the list of stage 1 stays whole
    local kept, first_list, seen = model.PAUSE_ROWS, b.model.list, 0
    model.PAUSE_ROWS = 5
    local ok, err = pcall(model.recipes, b, function()
        seen = seen + 1
        t.eq(b.model.stage, 1, "the stage only moves when the join is done")
        t.eq(b.model.list, first_list, "the list is swapped at the end, not built in place")
        t.ok(b.model.items.banner, "nothing leaves the items before the new list is in")
    end)
    model.PAUSE_ROWS = kept
    t.ok(ok, err)
    t.ok(seen > 20)
    t.ok(b.model.list ~= first_list)
    t.eq(b.model.stage, 2)
    t.eq(#b.model.recipes, #m.recipes)
    t.eq(b.model.items.banner, nil)
    t.eq(b.model.items.lathe.level, nil)
    reader.read(3)
    model.levels(b)
    t.eq(b.model.stage, 3)
    t.eq(b.model.items.lathe.level, "farlands")
    t.eq(#b.model.list, #m.list)
end)

t.test("model: build needs the tags module", function()
    t.raises(function() model.build(src, nil, string.lower) end, "tags module")
end)

t.test("model: it holds values only, so it can be kept across a reload", function()
    local seen = {}
    local function walk(value, where)
        local kind = type(value)
        t.ok(kind ~= "function" and kind ~= "userdata" and kind ~= "thread", where .. " holds a " .. kind)
        if kind ~= "table" or seen[value] then return end
        seen[value] = true
        t.eq(getmetatable(value), nil, where .. " has no metatable")
        for key, inner in pairs(value) do walk(inner, where .. "." .. tostring(key)) end
    end
    walk(m, "model")
end)

-- ---------------------------------------------------------------- anchors

t.test("anchor: without the hide query the list is not shown at all", function()
    local tables = fixture.copy()
    table.remove(tables.TagQueries.rows, 1)
    local built = build(fixture.serve(tables))
    t.ok(missing_has(built, "TagQueries", "FieldGuide_Hide"))
    t.ok(built.off.list)
    t.eq(#built.list, 0)
    t.eq(next(built.items), nil)
    t.eq(#built.recipes, 0)
    t.eq(built.stage, 0)
end)

t.test("anchor: without the category Hidden there are no categories, and the list still shows", function()
    local tables = fixture.copy()
    table.remove(tables.FieldGuideCategories.rows, 5)
    local built = build(fixture.serve(tables))
    t.ok(missing_has(built, "FieldGuideCategories", "Hidden"))
    t.ok(built.off.categories)
    t.eq(#built.categories, 0)
    t.eq(#built.items.stone_knife.cats, 0)
    t.ok(built.items.trader_npc.hidden, "the hide rule still works")
    t.eq(#built.recipes, #m.recipes)
end)

t.test("anchor: without the set Character it is named, and recipes still join", function()
    local tables = fixture.copy()
    table.remove(tables.RecipeSets.rows, 1)
    local built = build(fixture.serve(tables))
    t.ok(missing_has(built, "RecipeSets", "Character"))
    t.ok(built.off.hand)
    t.eq(#built.recipes, #m.recipes)
    t.eq(#built.recipes[built.recipe.stone_knife].sets, 0)
end)

t.test("anchor: without a template that carries SeedType_Enum it is named, and seeds are plain", function()
    local tables = fixture.copy()
    for _, row in ipairs(tables.ItemTemplate.rows) do
        local stats = row.ItemCustomStats
        if stats and stats[1].Stat.Value == "SeedType_Enum" then stats[1].Stat.Value = "SeedKind_Enum" end
    end
    local built = build(fixture.serve(tables))
    t.ok(missing_has(built, "ItemTemplate", "SeedType_Enum"))
    t.ok(built.off.seeds)
    t.eq(built.items["seed:oat"], nil)
    t.eq(built.counts.seeds, 0)
    t.eq(built.recipes[built.recipe.oat_seeds].outputs[1].item, "seed")
    t.eq(built.counts.flags, 2, "flags are as before")
end)

t.test("anchor: every anchor is in model.ANCHORS", function()
    local names = {}
    for index, anchor in ipairs(model.ANCHORS) do names[index] = anchor[1] .. "." .. anchor[2] end
    t.eq(joined(names), "TagQueries.FieldGuide_Hide FieldGuideCategories.Hidden RecipeSets.Character ItemTemplate.SeedType_Enum")
end)

-- ---------------------------------------------------------------- nothing outside the lists

t.test("strict rows: a field outside source.lua's lists raises", function()
    t.raises(function() return src.row("Itemable", "Item_Pebble").Description end, "not in source.lua's lists")
    t.raises(function() return src.row("ProcessorRecipes", "Gear").SessionRequirement.DataTableName end, "not in source.lua's lists")
    t.raises(function() return src.row("ItemsStatic", "Pebble").Metadata end, "not in source.lua's lists")
    t.eq(src.row("Itemable", "Item_Pebble").Icon ~= nil, true)
end)

t.test("strict rows: defaults are filled in, and false stays false", function()
    local gear, geode = src.row("ProcessorRecipes", "Gear"), src.row("ProcessorRecipes", "Crack_Geode")
    t.eq(gear.bSelectOutputItemRandomly, false, "from the table's default")
    t.eq(geode.bSelectOutputItemRandomly, true)
    t.eq(src.row("ProcessorRecipes", "Stone_Knife").RequiredMillijoules, 2500)
    t.eq(gear.CharacterRequirement.RowName, "None")
    t.eq(#gear.QueryInputs, 0)
    t.eq(src.row("Itemable", "Item_Pebble").Icon, "/Game/Fixture/ITEM_Pebble.ITEM_Pebble")
    t.eq(src.row("ItemsStatic", "Ghost_Mesh").Itemable.RowName, "None")
end)

t.test("strict rows: the build reads no field outside the lists, and would be caught if it did", function()
    local ok, err = pcall(build, fixture.provider())
    t.ok(ok, err)
    -- the same build over rows that lack one listed field fails, which shows the guard is live
    local inner = fixture.provider()
    local reader = source.new(inner)
    reader.read_all(1)
    local row = reader.row
    function reader.row(name, key)
        if name ~= "ProcessorRecipes" then return row(name, key) end
        return fixture.provider():Table(name):Row(key, { "Inputs.Element.RowName", "Outputs.Element.RowName" })
    end
    t.raises(function() model.build(reader, nil, string.lower, tags) end, "not in source.lua's lists")
end)

t.test("strict rows: every field the source asks the provider for is in its lists", function()
    local listed = {}
    for _, entry in ipairs(source.lists()) do
        local name = entry.table .. (entry.meta and "_METATABLE" or "")
        listed[name] = listed[name] or {}
        for _, field in ipairs(entry.fields) do listed[name][field] = true end
    end
    local inner = fixture.provider()
    local asked = 0
    local function watch(object)
        return setmetatable({
            Load = function(_, request)
                for _, field in ipairs(request.fields or {}) do
                    asked = asked + 1
                    t.ok(listed[object.Name][field], object.Name .. "." .. field .. " is listed")
                end
                return object:Load(request)
            end,
            Row = function(_, name, fields)
                t.ok(fields, "a row is never asked for whole")
                for _, field in ipairs(fields) do t.ok(listed[object.Name][field], object.Name .. "." .. field .. " is listed") end
                return object:Row(name, fields)
            end,
            Meta = function()
                local meta = object:Meta()
                return meta and watch(meta) or nil
            end,
        }, { __index = object })
    end
    local wrapped = setmetatable({ Table = function(_, name) return watch(inner:Table(name)) end,
        Has = function(_, name) return inner:Has(name) end }, { __index = inner })
    local built = build(wrapped)
    t.ok(asked > 60, "fields were asked for")
    t.eq(#built.recipes, #m.recipes)
end)

t.finish("recipe-model")
