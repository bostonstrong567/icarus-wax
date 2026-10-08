-- Offline tests for the XP a craft gives in the Recipe Browser: what is read, the game's own sum, and what each view says.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\recipe_xp_test.lua luamods\RecipeBrowser

local t = dofile("wax/tests/offline/harness.lua")

local folder = arg and arg[1]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end

local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
end

if not folder or not exists(folder .. "/model.lua") or not exists(folder .. "/rows.lua") then
    print("recipe-xp: 0 passed (skipped: Recipe Browser is not here)")
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

local source, tags, model, tree = part("source"), part("tags"), part("model"), part("tree")
local text, format, unlock, rows = part("text"), part("format"), part("unlock"), part("rows")
local fixture = dofile("wax/tests/offline/recipe_fixture.lua")
local r = rows.new({ text = text, format = format, unlock = unlock })

-- A number as the game's tables hold a float.
local function single(value) return (string.unpack("<f", string.pack("<f", value))) end
local FIFTH, NINE_FIFTHS, TENTH = single(0.2), single(1.8), single(0.1)

local function h(name, table_name) return { RowName = name, DataTableName = table_name } end
local function input(name, count) return { Element = h(name, "D_ItemsStatic"), Count = count } end
local function output(name, count) return { Element = h(name, "D_ItemTemplate"), Count = count } end

local function find(tables, name, row)
    for _, found in ipairs(tables[name].rows) do
        if found.Name == row then return found end
    end
    error("the fixture has no " .. name .. "." .. row)
end

-- The fixture with the four fields the XP is worked out from, as the game's tables have them: every set gives a
-- fifth, the Hearth nine fifths, an item is worth 5 unless its row says more, and water 100.
local function with_xp(change)
    local tables = fixture.copy()
    tables.ItemsStatic.defaults.CraftingExperience = 5
    tables.RecipeSets.defaults.ExperienceMultiplier = 10
    tables.ProcessorRecipes.defaults.ExperienceMultiplier = 1
    tables.IcarusResources.defaults.CraftingExperience = 5
    for _, row in ipairs(tables.RecipeSets.rows) do row.ExperienceMultiplier = row.Name == "Hearth" and NINE_FIFTHS or FIFTH end
    for name, worth in pairs({ Pebble = 20, Twig = 10, Cloth = 10, Flour = 40, Mint = 10, Seed = 400 }) do
        find(tables, "ItemsStatic", name).CraftingExperience = worth
    end
    find(tables, "IcarusResources", "Water").CraftingExperience = 100
    -- the three things crafted by hand in the game on 2026-10-07, and the pile that gave nothing
    local add = tables.ProcessorRecipes.rows
    add[#add + 1] = { Name = "Seen_Axe", Inputs = { input("Cloth", 10), input("Twig", 4), input("Pebble", 6) }, Outputs = { output("Gear", 1) },
        RecipeSets = { h("Character", "D_RecipeSets") } }
    add[#add + 1] = { Name = "Seen_Bow", Inputs = { input("Cloth", 30), input("Twig", 24) }, Outputs = { output("Gear", 1) },
        RecipeSets = { h("Character", "D_RecipeSets") } }
    add[#add + 1] = { Name = "Seen_Fire", Inputs = { input("Cloth", 8), input("Twig", 8), input("Pebble", 24) }, Outputs = { output("Gear", 1) },
        RecipeSets = { h("Character", "D_RecipeSets") }, RequiredMillijoules = 5000 }
    add[#add + 1] = { Name = "Seen_Pile", Inputs = { input("Twig", 100) }, Outputs = { output("Gear", 1) },
        RecipeSets = { h("Character", "D_RecipeSets") }, ExperienceMultiplier = 0 }
    if change then change(tables) end
    return tables
end

-- The table as a game that no longer has the field would serve it.
local function drop(tables, name, field)
    tables[name].defaults[field] = nil
    for _, row in ipairs(tables[name].rows) do row[field] = nil end
end

local function build(tables)
    local src = source.new(fixture.serve(tables))
    src.read_all(1)
    local m = model.build(src, nil, string.lower, tags)
    return m, src
end

local m = build(with_xp())

local function xp(built, recipe, set)
    local found = built.recipes[built.recipe[recipe]]
    return found.xp and found.xp[set]
end

local function card(built, recipe, picked)
    return r.recipe(built, nil, built.recipe[recipe], picked and built.items[picked] or nil, "make")
end

t.test("source: the four fields are read only while the game has them, and losing one breaks nothing", function()
    local maybe = {}
    for _, entry in ipairs(source.lists()) do
        for _, field in ipairs(entry.maybe) do maybe[#maybe + 1] = entry.table .. "." .. field end
    end
    table.sort(maybe)
    t.eq(table.concat(maybe, " "), "IcarusResources.CraftingExperience ItemsStatic.CraftingExperience "
        .. "ProcessorRecipes.ExperienceMultiplier RecipeSets.ExperienceMultiplier")
    -- the plain fixture has none of them: rows that raise on a field nobody asked for are read with no error
    local plain, src = build(fixture.copy())
    t.eq(#src.problems, 0, "a field the game lacks is no problem")
    t.eq(next(plain.off), nil, "and switches nothing off")
    t.eq(plain.xp, nil)
    t.eq(plain.recipes[plain.recipe.stone_knife].xp, nil)
    t.eq(plain.items.pebble.xp, nil)
    t.eq(src.serves("ItemsStatic", "CraftingExperience"), false)
    -- with them, the table of items says so although it also has fields that are read a row at a time
    local _, with = build(with_xp())
    t.eq(with.serves("ItemsStatic", "CraftingExperience"), true)
    t.eq(with.serves("RecipeSets", "ExperienceMultiplier"), true)
    t.eq(with.serves("ItemsStatic", "Itemable.RowName"), false, "a field that is always read is not a maybe field")
    t.eq(#with.problems, 0)
end)

t.test("model: a craft gives the worth of each item it takes times its count, a fifth of it by hand, as seen in the game", function()
    t.eq(m.xp, true)
    t.eq(m.items.pebble.xp, 20)
    t.eq(m.items.gear.xp, 5, "the table's default")
    t.eq(m.sets.character.xp, FIFTH)
    -- 10 fiber, 4 sticks and 6 stones gave 52; 30 and 24 gave 108; 8, 8 and 24 gave 128; a pile gave nothing
    t.eq(xp(m, "seen_axe", "character"), 52)
    t.eq(xp(m, "seen_bow", "character"), 108)
    t.eq(xp(m, "seen_fire", "character"), 128)
    t.eq(xp(m, "seen_pile", "character"), 0, "the recipe's own share is 0")
    t.eq(math.type(xp(m, "seen_axe", "character")), "integer")
    t.eq(xp(m, "stone_knife", "character"), 10, "2 x 20 and 1 x 10, a fifth")
end)

t.test("model: one figure for each set the recipe is in, also a set no bench provides, and nine fifths is not one short", function()
    local gear = m.recipes[m.recipe.gear].xp
    t.eq(gear.work_table, 16)
    t.eq(gear.lathe, 16)
    t.eq(gear.press, 16)
    t.eq(xp(m, "brick", "kiln"), 12, "3 x 20 at a set with no bench")
    -- 3 seeds worth 400: 240 at the press, and 1200 x 1.7999999523 is 2160 in the game's floats, not 2159
    t.eq(xp(m, "seed_mash", "press"), 240)
    t.eq(xp(m, "seed_mash", "hearth"), 2160)
    local carcass = build(with_xp(function(tables)
        find(tables, "ItemsStatic", "River_Trout").CraftingExperience = 400
        find(tables, "RecipeSets", "Character").ExperienceMultiplier = NINE_FIFTHS
    end))
    t.eq(xp(carcass, "butcher_trout", "character"), 720, "a carcass at the skinning bench")
end)

t.test("model: what is taken by tag counts nothing, and a recipe that takes nothing else gives nothing", function()
    t.eq(#m.recipes[m.recipe.baked_fish].tags_in, 1)
    t.eq(xp(m, "baked_fish", "hearth"), 0)
    t.eq(xp(m, "baked_fish", "kiln"), 0)
end)

t.test("model: water counts a hundredth of its units times its worth, rounded up, and at least 1", function()
    -- 2 flour worth 40 and 100 units of water worth 100: 80 + 100, a fifth
    t.eq(xp(m, "dough", "work_table"), 36)
    -- 1 mint worth 10 and 250 units: 260, nine fifths
    t.eq(xp(m, "mint_tea", "hearth"), 468)
    local function dough(units, worth)
        local built = build(with_xp(function(tables)
            find(tables, "ProcessorRecipes", "Dough").ResourceInputs[1].RequiredUnits = units
            find(tables, "IcarusResources", "Water").CraftingExperience = worth
            find(tables, "RecipeSets", "Work_Table").ExperienceMultiplier = 1
        end))
        return xp(built, "dough", "work_table") - 80
    end
    t.eq(dough(100, 100), 100)
    t.eq(dough(1, 100), 1)
    t.eq(dough(125, 100), 125)
    t.eq(dough(101, 5), 6, "5.05 is rounded up")
    t.eq(dough(100, 5), 5, "a whole number stays")
    t.eq(dough(1, 5), 1, "0.05 is rounded up")
    t.eq(dough(100, 0), 1, "a resource worth nothing still counts 1")
    t.eq(dough(150000, 100), 150000)
end)

t.test("model: the sum is cut to a whole number after the set's share and again after the recipe's", function()
    -- a knife takes 2 pebbles and 1 twig
    local function knife(pebble, set_share, own, twig)
        local built = build(with_xp(function(tables)
            find(tables, "ItemsStatic", "Pebble").CraftingExperience = pebble
            find(tables, "ItemsStatic", "Twig").CraftingExperience = twig or 0
            find(tables, "RecipeSets", "Character").ExperienceMultiplier = set_share
            find(tables, "ProcessorRecipes", "Stone_Knife").ExperienceMultiplier = own
        end))
        return xp(built, "stone_knife", "character")
    end
    t.eq(knife(2, FIFTH, 1), 0, "4 x 0.2 is 0.8")
    t.eq(knife(27, FIFTH, 1), 10, "54 x 0.2 is 10.8")
    t.eq(knife(27, FIFTH, TENTH), 1, "10 x 0.1")
    t.eq(knife(45, FIFTH, TENTH), 1, "18 x 0.1 is 1.8")
    t.eq(knife(3, single(0.5), single(0.5)), 1, "6 x 0.5 is 3, 3 x 0.5 is 1.5")
    t.eq(knife(3, single(0.5), 2, 1), 6, "7 x 0.5 is 3.5, cut to 3 before it is doubled: not 7")
    t.eq(knife(5, 10, 1), 100, "the table's default share of a set")
end)

t.test("model: without the worth of resources a recipe that takes one has no figure, and the others keep theirs", function()
    local function check(built)
        t.eq(built.xp, true)
        t.eq(built.recipes[built.recipe.dough].xp, nil)
        t.eq(built.recipes[built.recipe.mint_tea].xp, nil)
        t.eq(xp(built, "stone_knife", "character"), 10)
        t.eq(card(built, "dough").gives, "", "nothing is said of what is not known")
    end
    -- the game lost the field
    check(build(with_xp(function(tables) drop(tables, "IcarusResources", "CraftingExperience") end)))
    -- the switch
    model.XP_RESOURCES = false
    local ok, problem = pcall(function() check(build(with_xp())) end)
    model.XP_RESOURCES = true
    t.ok(ok, problem)
    -- a game without the worth of items has no XP at all
    local none = build(with_xp(function(tables) drop(tables, "ItemsStatic", "CraftingExperience") end))
    t.eq(none.xp, nil)
    t.eq(none.recipes[none.recipe.stone_knife].xp, nil)
    t.eq(card(none, "stone_knife").gives, "")
end)

t.test("text: an amount of XP, a range when stations differ, and nothing for none", function()
    t.eq(text.xp(52), "52 XP")
    t.eq(text.xp(52, 52), "52 XP")
    t.eq(text.xp(35590), "35,590 XP")
    t.eq(text.xp(240, 2160), "240 to 2,160 XP")
    t.eq(text.xp(0), "")
    t.eq(text.xp(0, 0), "")
    t.eq(text.xp(nil), "")
    t.eq(text.xp(0, 720), "0 to 720 XP")
    t.eq(text.tip.gives("52 XP"), "Gives 52 XP")
    t.eq(text.tip.gives(""), "")
    t.eq(text.tree.gives("52 XP", "52 XP"), "Gives 52 XP")
    t.eq(text.tree.gives("52 XP", "520 XP"), "52 XP each, 520 XP in all")
    t.eq(text.tree.step("Stick", 10, "25 s", "", "520 XP"), "Stick x10 - 25 s - 520 XP")
    t.eq(text.tree.step("Stick", 10, "", "", "520 XP"), "Stick x10 - 520 XP")
    t.eq(text.tree.step("Stick", 10, "25 s", "", ""), "Stick x10 - 25 s", "as it was")
    t.eq(text.tree.step("Stick", 10, "25 s", "Character"), "Stick x10 - 25 s at Character", "as it was")
    t.eq(text.tree.step("Stick", 10, "", "Character"), "Stick x10", "as it was")
    t.eq(text.tree.total("2 min 5 s"), "Making it all takes 2 min 5 s, before talents and upgrades.", "as it was")
    t.eq(text.tree.total("2 min 5 s", ""), "Making it all takes 2 min 5 s, before talents and upgrades.")
    t.eq(text.tree.total("", "1,240 XP"), "Making it all gives 1,240 XP, before bonuses.")
    t.eq(text.tree.total("2 min 5 s", "1,240 XP"),
        "Making it all takes 2 min 5 s and gives 1,240 XP, before talents, upgrades and bonuses.")
end)

t.test("rows: a recipe says what a craft gives, each station has its own figure, and one that gives nothing says nothing", function()
    local knife = card(m, "stone_knife")
    t.eq(knife.gives, "10 XP")
    t.eq(knife.stations[1].xp, 10)
    t.eq(knife.stations[1].xp_most, 10)
    t.eq(select("#", r.xp(knife)), 2)
    t.eq(r.xp(knife), 10)
    -- three benches that agree are one figure
    t.eq(card(m, "gear").gives, "16 XP")
    -- two that differ are a range, and each is asked by its name
    local mash = card(m, "seed_mash")
    t.eq(mash.gives, "240 to 2,160 XP")
    local low, high = r.xp(mash, "Press")
    t.eq(low, 240)
    t.eq(high, 240)
    t.eq(r.gives(r.xp(mash, "Hearth")), "2,160 XP")
    t.eq(r.gives(r.xp(mash, "No such station")), "")
    -- nothing for a tag-only recipe and for the pile; a set no bench provides is no station
    t.eq(card(m, "baked_fish").gives, "")
    t.eq(card(m, "seen_pile").gives, "")
    t.eq(#card(m, "brick").stations, 0)
    t.eq(card(m, "brick").gives, "")
end)

t.test("rows: two sets the game calls the same are one station with the least and the most of both", function()
    local built = build(with_xp(function(tables)
        find(tables, "RecipeSets", "Loom_B").ExperienceMultiplier = NINE_FIFTHS
        local banner = find(tables, "ProcessorRecipes", "Banner_North")
        banner.RecipeSets = { h("Loom_A", "D_RecipeSets"), h("Loom_B", "D_RecipeSets") }
        -- only Loom_A has a bench, so give the other one too
        tables.Processing.rows[#tables.Processing.rows + 1] = { Name = "Loom_Two", DefaultRecipeSet = h("Loom_B") }
        find(tables, "ItemsStatic", "Rug").Processing = h("Loom_Two")
    end))
    local banner = card(built, "banner_north")
    t.eq(#banner.stations, 1)
    t.eq(banner.stations[1].name, "Loom")
    t.eq(banner.stations[1].xp, 4, "2 cloth worth 10, a fifth")
    t.eq(banner.stations[1].xp_most, 36, "nine fifths")
    t.eq(banner.gives, "4 to 36 XP")
end)

t.test("rows: the heading of a recipe's lines ends with the XP, after the station and the time, and the switch takes it away", function()
    local function heading(built, recipe)
        local out = {}
        r.block(out, built, nil, built.recipe[recipe], nil, "make")
        return out[1].note
    end
    t.eq(heading(m, "stone_knife"), "By hand - 2.5 s - 10 XP")
    t.eq(heading(m, "seen_fire"), "By hand - 5 s - 128 XP")
    t.eq(heading(m, "seed_mash"), "2 stations - 240 to 2,160 XP")
    t.eq(heading(m, "baked_fish"), "Hearth")
    rows.SHOW_XP = false
    local ok, problem = pcall(function()
        t.eq(heading(m, "stone_knife"), "By hand - 2.5 s")
        t.eq(card(m, "stone_knife").gives, "")
        t.eq(r.gives(52), "")
        t.eq(r.xp(card(m, "stone_knife")), nil)
    end)
    rows.SHOW_XP = true
    t.ok(ok, problem)
    t.eq(r.gives(52), "52 XP")
end)

local function step_of(steps, key)
    for _, step in ipairs(steps) do
        if step.key == key then return step end
    end
    return nil
end

t.test("tree: every step has the XP of all its crafts at its station, and the sum scales with the number asked for", function()
    -- a press takes 4 gears; a gear recipe makes 2 from 4 pebbles
    local steps = tree.steps(tree.build(m, "press", 1))
    local gear, press = step_of(steps, "gear"), step_of(steps, "press")
    t.eq(gear.crafts, 2)
    t.eq(gear.xp, 32, "16 a craft")
    t.eq(press.crafts, 1)
    t.eq(press.xp, 4, "4 gears worth 5, a fifth")
    local ten = tree.steps(tree.build(m, "press", 10))
    t.eq(step_of(ten, "gear").crafts, 20)
    t.eq(step_of(ten, "gear").xp, 320)
    t.eq(step_of(ten, "press").xp, 40)
    -- the station is the first one with a name, as the list of times uses it
    local mash = step_of(tree.steps(tree.build(m, "mash", 2)), "mash")
    t.eq(mash.set, "press")
    t.eq(mash.xp, 480)
    -- a step that gives nothing is 0, not unknown
    local fish = step_of(tree.steps(tree.build(m, "baked_fish", 3)), "baked_fish")
    t.eq(fish.xp, 0)
end)

t.test("tree: a step whose XP is not known has none, and a tree made without XP is as it was", function()
    local plain = build(fixture.copy())
    for _, step in ipairs(tree.steps(tree.build(plain, "press", 5))) do t.eq(step.xp, nil) end
    for _, node in ipairs(tree.flatten(tree.build(plain, "press", 5))) do t.eq(node.xp, nil) end
    local some = build(with_xp(function(tables) drop(tables, "IcarusResources", "CraftingExperience") end))
    local steps = tree.steps(tree.build(some, "dough", 4))
    t.eq(step_of(steps, "dough").xp, nil, "its water has no worth to count")
end)

-- The real tables, when game-data is here: every figure is a whole number and no recipe breaks the sum.
local function folder_exists(path)
    local ok, _, code = os.rename(path, path)
    return ok == true or code == 13
end

if folder_exists("game-data/data") and exists("build/recipe-browser/check/tables.lua") then
    local line = nil
    t.test("the game's tables: the three crafts seen in play, a carcass, and every recipe's figure a whole number", function()
        local tables = dofile("build/recipe-browser/check/tables.lua")
        local has = false
        for _, field in ipairs(tables.ItemsStatic.fields) do has = has or field == "CraftingExperience" end
        if not has then
            line = "recipe-xp on the game's tables: left out, run python scripts\\recipe_check.py with this copy of the mod first"
            return
        end
        local game = build(tables)
        t.eq(game.xp, true)
        t.eq(xp(game, "stone_axe", "character"), 52)
        t.eq(xp(game, "wood_bow", "character"), 108)
        t.eq(xp(game, "campfire", "character"), 128)
        t.eq(xp(game, "resourcestack_wood", "character"), 0)
        t.eq(xp(game, "carcass_deer", "skinning_bench"), 720)
        local with, none, most, most_name, ranged = 0, 0, 0, "", 0
        for number, recipe in ipairs(game.recipes) do
            t.ok(recipe.xp, recipe.row .. " has no figure")
            for _, id in ipairs(recipe.sets) do
                local gives = recipe.xp[id]
                t.eq(math.type(gives), "integer", recipe.row .. " at " .. id)
                t.ok(gives >= 0, recipe.row .. " at " .. id)
            end
            local shown = r.recipe(game, nil, number, nil, "make")
            if shown.gives == "" then none = none + 1 else with = with + 1 end
            if shown.gives:find(" to ", 1, true) then ranged = ranged + 1 end
            local _, high = r.xp(shown)
            if high and high > most then most, most_name = high, shown.name end
        end
        line = ("recipe-xp on the game's tables: %d recipes say what they give, %d say nothing, %d differ by station; the most is %s for %s")
            :format(with, none, ranged, text.xp(most), most_name)
    end)
    if line then print(line) end
end

t.finish("recipe-xp")
