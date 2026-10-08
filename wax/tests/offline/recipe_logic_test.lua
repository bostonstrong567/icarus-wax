-- Offline tests for the Recipe Browser's search, favourites, history and texts.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\recipe_logic_test.lua luamods\RecipeBrowser

local t = dofile("wax/tests/offline/harness.lua")

local FILES = { "search", "favourites", "history", "text" }
local folder = arg and arg[1]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end

local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
end

local present = 0
for _, name in ipairs(FILES) do
    if folder and exists(folder .. "/" .. name .. ".lua") then present = present + 1 end
end
if present == 0 then
    print("recipe-logic: 0 passed (skipped: Recipe Browser is not here)")
    os.exit(0)
end

-- The files are given the standard library and nothing else, so a use of Wax or the engine fails here.
local function part(name)
    local env = { string = string, table = table, math = math, select = select, type = type, pairs = pairs,
        ipairs = ipairs, next = next, tostring = tostring, tonumber = tonumber, setmetatable = setmetatable, error = error }
    setmetatable(env, { __index = function(_, key) error(name .. ".lua reads the global '" .. tostring(key) .. "'", 2) end })
    local chunk = assert(loadfile(folder .. "/" .. name .. ".lua", "t", env))
    local value = chunk()
    assert(type(value) == "table", name .. ".lua must return a table")
    return value
end

local search = part("search")
local favourites = part("favourites")
local history = part("history")
local text = part("text")

local function keys_of(list)
    local out = {}
    for index, item in ipairs(list) do out[index] = type(item) == "table" and (item.key or item.id) or item end
    return table.concat(out, " ")
end

-- A small made-up model in the shapes the plan gives. Keys are folded row names.
local function make_model()
    local model = { items = {}, list = {}, recipes = {}, sets = {}, made_by = {}, used_in = {}, made_at = {} }
    local function item(key, name, cats, extra)
        local entry = { key = key, static = key, name = name, lower = search.lower(name), cats = cats, hidden = false,
            order = #model.list + 1 }
        for field, value in pairs(extra or {}) do entry[field] = value end
        model.items[key] = entry
        model.list[#model.list + 1] = entry
        return entry
    end
    local function set(id, name, benches, group)
        local list = {}
        for index, bench in ipairs(benches) do list[index] = { item = bench, mw = 1000 * index } end
        model.sets[id] = { id = id, name = name, benches = list, group = group or id }
    end
    local function recipe(id, outputs, inputs, sets, extra)
        local entry = { id = id, inputs = {}, outputs = {}, tags_in = {}, res_in = {}, sets = sets, mj = 2500 }
        for index, key in ipairs(inputs) do entry.inputs[index] = { item = key, count = index } end
        for index, key in ipairs(outputs) do entry.outputs[index] = { item = key, count = 1 } end
        for field, value in pairs(extra or {}) do entry[field] = value end
        local number = #model.recipes + 1
        model.recipes[number] = entry
        local function index_under(map, key)
            map[key] = map[key] or {}
            map[key][#map[key] + 1] = number
        end
        for _, key in ipairs(outputs) do index_under(model.made_by, key) end
        if entry.title then index_under(model.made_by, entry.title) end
        for _, key in ipairs(inputs) do index_under(model.used_in, key) end
        for _, id_of_set in ipairs(sets) do index_under(model.made_at, id_of_set) end
        return number
    end

    item("iron_ore", "Iron Ore", { "resources" })
    item("iron_ingot", "Iron Ingot", { "resources" })
    item("wood", "Wood", { "resources" })
    item("raw_meat", "Raw Meat", { "food" })
    item("iron_pickaxe", "Iron Pickaxe", { "tools" })
    item("stone_pickaxe", "Stone Pickaxe", { "tools" })
    item("wood_bow", "Wood Bow", { "tools", "ranged" })
    item("fruit_pie", "Fruit Pie", { "food" })
    item("cooked_meat", "Cooked Meat", { "food" })
    item("coffee", "Coffee", { "food" }, { title_only = true })
    item("drink_cup", "Cup", { "food" })
    item("campfire", "Campfire", { "benches" }, { bench = { "campfire" } })
    item("fireplace", "Fireplace", { "benches" }, { bench = { "campfire" } })
    item("stone_furnace", "Stone Furnace", { "benches" }, { bench = { "furnace" } })
    item("concrete_furnace", "Concrete Furnace", { "benches" }, { bench = { "furnace_two" } })
    item("anvil", "Anvil Bench", { "benches" }, { bench = { "anvil" } })
    item("marble_bench", "Marble Kitchen Bench", { "benches" }, { bench = { "advanced_kitchen" } })
    item("prototype_bench", "Prototype Kitchen Bench", { "hidden" }, { bench = { "advanced_kitchen" }, hidden = true })
    item("fieldguide_character", "Character", { "benches" }, { bench = { "character" } })
    item("debug_cube", "Debug Cube", { "hidden" }, { hidden = true })
    item("iron_ore_ru", "Железная руда", { "resources" })
    item("oil", "Öl", { "resources" })
    item("sword", "Épée", { "tools" })

    set("character", "Character", { "fieldguide_character" })
    set("campfire", "Campfire", { "campfire", "fireplace" })
    set("furnace", "Furnace", { "stone_furnace" }, "furnace")
    set("furnace_two", "Furnace", { "concrete_furnace" }, "furnace")
    set("anvil", "Anvil", { "anvil" })
    set("advanced_kitchen", "Advanced Kitchen Bench", { "marble_bench", "prototype_bench" })
    set("empty_set", "Smoker", {})

    recipe("iron_ingot", { "iron_ingot" }, { "iron_ore" }, { "furnace" })
    recipe("iron_ingot_fast", { "iron_ingot" }, { "iron_ore", "wood" }, { "furnace_two" })
    recipe("iron_pickaxe", { "iron_pickaxe" }, { "iron_ingot", "wood" }, { "anvil" })
    recipe("stone_pickaxe", { "stone_pickaxe" }, { "wood" }, { "character" })
    recipe("wood_bow", { "wood_bow" }, { "wood" }, { "character", "anvil" })
    recipe("fruit_pie", { "fruit_pie" }, {}, { "advanced_kitchen" },
        { tags_in = { { tag = "any_fruit", count = 3 } }, res_in = { { res = "water", units = 100 } } })
    recipe("cooked_meat", { "cooked_meat" }, { "raw_meat" }, { "campfire" })
    recipe("coffee_drink", { "drink_cup" }, {}, { "advanced_kitchen" }, { title = "coffee" })
    recipe("marble_bench", { "marble_bench" }, { "iron_ingot" }, { "anvil" })

    model.tags = { any_fruit = { name = "Fruit" } }
    model.resources = { water = { name = "Water" } }
    return model
end

local model = make_model()
local CATEGORY_NAMES = { resources = "Resources", tools = "Tools", food = "Food", benches = "Benches",
    ranged = "Ranged Weapons", hidden = "Hidden", res_raw = "Raw Materials" }
local index = search.index(model, { stations = { character = "By hand" }, categories = CATEGORY_NAMES,
    member = function(item, key) return key == "res_raw" and item.key == "wood" end })

local function find(query, options)
    return keys_of(index.filter(model.list, query, options))
end

-- lower
t.test("this file reached Lua as UTF-8", function()
    t.eq("Ö", utf8.char(0xD6))
    t.eq("Ж", utf8.char(0x416))
end)

t.test("lower folds ASCII, Latin-1, Latin Extended-A and Cyrillic", function()
    t.eq(search.lower("Железо"), "железо")
    t.eq(search.lower("Öl"), "öl")
    t.eq(search.lower("Épée"), "épée")
    t.eq(search.lower("Iron ORE 42"), "iron ore 42")
    t.eq(search.lower("ŁÓDŹ ŻÓŁĆ"), "łódź żółć")
    t.eq(search.lower("ČŘŽ ŠŤ ĎŇ"), "čřž šť ďň")
    t.eq(search.lower("ÀÂÇÈÊËÎÏÔÙÛÜŸŒ"), "àâçèêëîïôùûüÿœ")
    t.eq(search.lower("ЁЖИК ЇЖАК ҐАНОК"), "ёжик їжак ґанок")
    t.eq(search.lower("İstanbul"), "istanbul")
    t.eq(search.lower("IRON Руда Épée"), "iron руда épée")
end)

t.test("lower leaves everything else alone", function()
    for _, same in ipairs({ "", "iron ore", "straße", "3 × 4", "鉄鉱石", "철광석", "铁矿石", "ÿ ß ĸ ŉ ſ", utf8.char(0x1F600) }) do
        t.eq(search.lower(same), same)
    end
    t.eq(search.lower("鉄 IRON 鉱石"), "鉄 iron 鉱石")
    t.eq(search.lower(search.lower("ÉPÉE Железо")), search.lower("ÉPÉE Железо"), "lowering twice changes nothing")
    t.eq(search.lower(nil), "")
    t.eq(search.lower(12), "")
end)

t.test("lower and parse give the same under the system's locale", function()
    local sample = "ÖL À LA Épée ЖЕЛЕЗО"
    local wanted = "öl|à|la|épée|железо"
    local set = os.setlocale("")
    local ok, problem = pcall(function()
        t.eq(search.lower(sample), "öl à la épée железо")
        t.eq(table.concat(search.parse(sample).words, "|"), wanted)
        t.eq(table.concat(search.parse("-ÖL @À #Épée").excluded, "|"), "öl")
    end)
    os.setlocale("C")
    if not ok then error(("under the locale %s: %s"):format(tostring(set), tostring(problem)), 0) end
end)

-- parse
t.test("parse sorts a query into words, stations, categories and excluded words", function()
    local query = search.parse("  Pick @Marble #Tools -Wood  IRON ")
    t.eq(table.concat(query.words, "|"), "pick|iron")
    t.eq(table.concat(query.stations, "|"), "marble")
    t.eq(table.concat(query.categories, "|"), "tools")
    t.eq(table.concat(query.excluded, "|"), "wood")
    t.eq(query.text, "Pick @Marble #Tools -Wood  IRON")
    t.eq(query.empty, false)
end)

t.test("parse ignores a mark with nothing after it, and an empty text", function()
    local query = search.parse("iron - @ #")
    t.eq(table.concat(query.words, "|"), "iron")
    t.eq(#query.stations + #query.categories + #query.excluded, 0)
    for _, nothing in ipairs({ "", "   ", "-", "@ #", "\t\r\n" }) do
        t.eq(search.parse(nothing).empty, true, ("%q"):format(nothing))
    end
    t.eq(search.parse(nil).empty, true)
    t.eq(search.parse(nil).text, "")
end)

t.test("parse keeps a hyphen inside a word and lowers other alphabets", function()
    t.eq(table.concat(search.parse("Bolt-Action").words, "|"), "bolt-action")
    t.eq(table.concat(search.parse("ЖЕЛЕЗНАЯ Руда").words, "|"), "железная|руда")
    t.eq(table.concat(search.parse("-ÉPÉE @ÖL").excluded, "|"), "épée")
    t.eq(table.concat(search.parse("-ÉPÉE @ÖL").stations, "|"), "öl")
end)

t.test("parse splits on the wide spaces other keyboards type", function()
    t.eq(table.concat(search.parse("鉄" .. utf8.char(0x3000) .. "鉱石").words, "|"), "鉄|鉱石")
    t.eq(table.concat(search.parse("iron" .. utf8.char(0xA0) .. "ore").words, "|"), "iron|ore")
    t.eq(table.concat(search.parse("à la carte").words, "|"), "à|la|carte")
end)

-- filter
t.test("every word must be found, in the order the list has", function()
    t.eq(find("iron"), "iron_ore iron_ingot iron_pickaxe")
    t.eq(find("iron pick"), "iron_pickaxe")
    t.eq(find("PICK"), "iron_pickaxe stone_pickaxe")
    t.eq(find("pick iron"), "iron_pickaxe")
    t.eq(find("iron gold"), "")
    t.eq(find("( % [ . *"), "", "marks that mean something in a pattern are plain letters here")
    t.eq(find("e"), "iron_ore raw_meat iron_pickaxe stone_pickaxe fruit_pie cooked_meat coffee campfire fireplace"
        .. " stone_furnace concrete_furnace anvil marble_bench fieldguide_character sword")
end)

t.test("an empty query gives every shown item", function()
    local all = index.filter(model.list, "", {})
    t.eq(#all, #model.list - 2)
    for _, item in ipairs(all) do t.ok(not item.hidden, item.key) end
    t.eq(keys_of(index.filter(model.list, search.parse("  "), {})), keys_of(all))
    t.ok(all ~= model.list, "a new list is returned")
end)

t.test("a word after a hyphen must not be found", function()
    t.eq(find("iron -pick"), "iron_ore iron_ingot")
    t.eq(find("pick -iron -zzz"), "stone_pickaxe")
    t.eq(find("-e -o"), "drink_cup iron_ore_ru oil")
end)

t.test("names in the player's language are found whatever the case", function()
    t.eq(find("ЖЕЛЕЗНАЯ"), "iron_ore_ru")
    t.eq(find("руда"), "iron_ore_ru")
    t.eq(find("ÖL"), "oil")
    t.eq(find("épée"), "sword")
    t.eq(find("ÉPÉE"), "sword")
end)

t.test("@ finds what a station makes, by the set's name and by each shown bench's name", function()
    t.eq(find("@marble"), "fruit_pie coffee drink_cup", "a bench of the set")
    t.eq(find("@advanced"), "fruit_pie coffee drink_cup", "the set's own name")
    t.eq(find("@prototype"), "", "a hidden bench does not count")
    t.eq(find("@fireplace"), "cooked_meat")
    t.eq(find("@campfire"), "cooked_meat")
    t.eq(find("@furnace"), "iron_ingot")
    t.eq(find("@concrete"), "iron_ingot")
    t.eq(find("@hand"), "stone_pickaxe wood_bow", "another name given for a set")
    t.eq(find("@character"), "stone_pickaxe wood_bow")
    t.eq(find("@anvil"), "iron_pickaxe wood_bow marble_bench")
    t.eq(find("@anvil @hand"), "wood_bow", "every station term must fit")
    t.eq(find("@anvil pick"), "iron_pickaxe")
    t.eq(find("@anvil -pick"), "wood_bow marble_bench")
    t.eq(find("@smoker"), "")
    t.eq(find("@zzz"), "")
end)

t.test("# finds by the name of a category or a subcategory", function()
    t.eq(find("#tools"), "iron_pickaxe stone_pickaxe wood_bow sword")
    t.eq(find("#TOOL iron"), "iron_pickaxe")
    t.eq(find("#weapons"), "wood_bow", "a word of the display name")
    t.eq(find("#materials"), "wood", "a subcategory, asked through member")
    t.eq(find("#tools #ranged"), "wood_bow")
    t.eq(find("#zzz"), "")
    local german = search.index(model, { categories = { tools = "Werkzeuge", food = "Nahrung" } })
    t.eq(keys_of(german.filter(model.list, "#WERKZEUG", {})), "iron_pickaxe stone_pickaxe wood_bow sword")
    local plain = search.index(model)
    t.eq(keys_of(plain.filter(model.list, "#tools", {})), "iron_pickaxe stone_pickaxe wood_bow sword", "by key when no names are given")
    local listed = search.index(model, { categories = {
        { key = "tools", name = "Tools", lower = "tools" }, { key = "food", name = "Food" },
        { key = "res_raw", name = "Raw Materials", items = { wood = true, iron_ore = true } } } })
    t.eq(keys_of(listed.filter(model.list, "#tools", {})), "iron_pickaxe stone_pickaxe wood_bow sword", "names given as a list")
    t.eq(keys_of(listed.filter(model.list, "#FOOD pie", {})), "fruit_pie")
    t.eq(keys_of(listed.filter(model.list, "#raw", {})), "iron_ore wood", "a subcategory that lists its items")
    t.eq(keys_of(listed.filter(model.list, "#raw -ore", {})), "wood")
    local own = search.index({ items = model.items, categories = { { key = "tools", name = "Werkzeuge", lower = "werkzeuge" } } })
    t.eq(keys_of(own.filter(model.list, "#werk", {})), "iron_pickaxe stone_pickaxe wood_bow sword", "the model's own list of categories")
end)

t.test("each show choice", function()
    t.eq(table.concat(search.SHOWS, " "), "all recipe favourites hidden")
    local kept = { iron_ore = true, debug_cube = true, sword = true }
    local options = { is_favourite = function(item) return kept[item.key] == true end }
    options.show = "all"
    t.eq(find("cube", options), "", "hidden items are not in All items")
    t.eq(find("bench", options), "anvil marble_bench")
    options.show = "recipe"
    t.eq(find("", options), "iron_ingot iron_pickaxe stone_pickaxe wood_bow fruit_pie cooked_meat coffee drink_cup marble_bench")
    t.eq(find("iron", options), "iron_ingot iron_pickaxe")
    options.show = "favourites"
    t.eq(find("", options), "iron_ore debug_cube sword", "a hidden favourite is still a favourite")
    t.eq(find("-cube", options), "iron_ore sword")
    options.show = "hidden"
    t.eq(find("", options), "prototype_bench debug_cube")
    t.eq(find("bench", options), "prototype_bench")
    options.show = nil
    t.eq(find("cube", options), "", "no choice is All items")
end)

t.test("the category choice", function()
    t.eq(find("", { category = "tools" }), "iron_pickaxe stone_pickaxe wood_bow sword")
    t.eq(find("wood", { category = "tools" }), "wood_bow")
    t.eq(find("", { category = "ranged" }), "wood_bow")
    t.eq(find("", { category = "food", show = "recipe" }), "fruit_pie cooked_meat coffee drink_cup")
    t.eq(find("", { category = "nothing" }), "")
    t.eq(find("", { category = "raw", in_category = function(item, key) return key == "raw" and item.key == "raw_meat" end }),
        "raw_meat", "a lookup for keys the items do not carry")
    t.eq(keys_of(search.filter({ { key = "bare", lower = "bare" } }, "", { category = "food" })), "", "an item with no categories")
end)

t.test("a lookup that was not given matches nothing", function()
    t.eq(keys_of(search.filter(model.list, "iron", {})), "iron_ore iron_ingot iron_pickaxe")
    t.eq(keys_of(search.filter(model.list, "iron")), "iron_ore iron_ingot iron_pickaxe")
    t.eq(keys_of(search.filter(model.list, "@anvil", {})), "")
    t.eq(keys_of(search.filter(model.list, "#tools", {})), "")
    t.eq(keys_of(search.filter(model.list, "", { show = "recipe" })), "")
    t.eq(keys_of(search.filter(model.list, "", { show = "favourites" })), "")
    t.eq(keys_of(search.filter({ { key = "nameless" } }, "", {})), "nameless")
    t.eq(keys_of(search.filter({ { key = "nameless" } }, "x", {})), "")
end)

t.test("a model whose recipes are not read yet", function()
    local early = search.index({ items = model.items })
    t.eq(early.has_recipe(model.items.iron_ingot), false)
    t.eq(keys_of(early.filter(model.list, "@anvil", {})), "")
    t.eq(keys_of(early.filter(model.list, "iron", {})), "iron_ore iron_ingot iron_pickaxe")
    t.eq(#early.filter_recipes({ 1, 2 }, "", nil), 0)
end)

t.test("the filter pauses when it is given a pause", function()
    local many = {}
    for number = 1, 1050 do many[number] = { key = "k" .. number, lower = "item " .. number } end
    local pauses = 0
    local found = search.filter(many, "item", { pause = function() pauses = pauses + 1 end, every = 100 })
    t.eq(pauses, 10)
    t.eq(#found, 1050)
    pauses = 0
    search.filter(many, "item", { pause = function() pauses = pauses + 1 end })
    t.eq(pauses, 2, "every 500 items unless told otherwise")
    local resumes, result = 0, nil
    local routine = coroutine.create(function() result = search.filter(many, "7", { pause = coroutine.yield, every = 200 }) end)
    while coroutine.status(routine) ~= "dead" do
        assert(coroutine.resume(routine))
        resumes = resumes + 1
    end
    t.eq(resumes, 6)
    t.eq(keys_of(result), keys_of(search.filter(many, "7", {})))
end)

-- the right list
t.test("the right list is filtered by words, stations and the station choice", function()
    local all = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }
    local function ids(list)
        local out = {}
        for position, number in ipairs(list) do out[position] = model.recipes[number].id end
        return table.concat(out, " ")
    end
    t.eq(ids(index.filter_recipes(all, "", nil)), ids(all))
    t.ok(index.filter_recipes(all, "", nil) ~= all, "a new list is returned")
    t.eq(ids(index.filter_recipes(all, "pickaxe", nil)), "iron_pickaxe stone_pickaxe", "what it makes")
    t.eq(ids(index.filter_recipes(all, "ORE", nil)), "iron_ingot iron_ingot_fast", "what goes in")
    t.eq(ids(index.filter_recipes(all, "ore wood", nil)), "iron_ingot_fast", "words may be in different names")
    t.eq(ids(index.filter_recipes(all, "coffee", nil)), "coffee_drink", "the title")
    t.eq(ids(index.filter_recipes(all, "cup", nil)), "coffee_drink")
    t.eq(ids(index.filter_recipes(all, "fruit", nil)), "fruit_pie")
    t.eq(ids(index.filter_recipes(all, "water", nil)), "fruit_pie", "a resource")
    t.eq(ids(index.filter_recipes(all, "wood -bow", nil)), "iron_ingot_fast iron_pickaxe stone_pickaxe")
    t.eq(ids(index.filter_recipes(all, "@marble", nil)), "fruit_pie coffee_drink")
    t.eq(ids(index.filter_recipes(all, "@hand", nil)), "stone_pickaxe wood_bow")
    t.eq(ids(index.filter_recipes(all, "@anvil @hand", nil)), "wood_bow")
    t.eq(ids(index.filter_recipes(all, "#tools", nil)), "iron_pickaxe stone_pickaxe wood_bow")
    t.eq(ids(index.filter_recipes(all, "#food @kitchen", nil)), "fruit_pie coffee_drink")
    t.eq(ids(index.filter_recipes(all, "", "furnace")), "iron_ingot iron_ingot_fast", "sets with one name are one choice")
    t.eq(ids(index.filter_recipes(all, "", "furnace_two")), "iron_ingot_fast", "a set's own id works too")
    t.eq(ids(index.filter_recipes(all, "wood", "anvil")), "iron_pickaxe wood_bow")
    t.eq(ids(index.filter_recipes(all, "", "nowhere")), "")
    t.eq(ids(index.filter_recipes(all, search.parse("meat"), nil)), "cooked_meat", "a parsed query is taken as it is")
    t.eq(ids(index.filter_recipes(model.made_at.anvil, "bench", nil)), "marble_bench")
    t.eq(ids(search.filter_recipes(all, "meat", nil, index)), "cooked_meat")
    t.raises(function() search.filter_recipes(all, "meat", nil) end, "index")
end)

t.test("the right list takes recipes as well as their numbers and gives back what it was given", function()
    local as_tables = { model.recipes[3], model.recipes[4], model.recipes[7] }
    local found = index.filter_recipes(as_tables, "pickaxe", nil)
    t.eq(#found, 2)
    t.ok(found[1] == model.recipes[3] and found[2] == model.recipes[4])
    local numbers = index.filter_recipes({ 7, 99, 3 }, "", nil)
    t.eq(table.concat(numbers, " "), "7 3", "a number the model does not have is left out")
end)

-- speed
local function big_model(count)
    local first = { "Iron", "Steel", "Stone", "Wood", "Copper", "Gold", "Titanium", "Platinum", "Carbon", "Composite",
        "Leather", "Fur", "Bone", "Glass", "Concrete", "Thatch", "Aluminium", "Obsidian", "Clay", "Marble", "Железная",
        "Каменный", "Épée de", "Ölige", "Cured", "Polar Bear", "Wolf", "Mammoth", "Scorpion", "Biofuel", "Electric" }
    local second = { "Pickaxe", "Axe", "Knife", "Spear", "Bow", "Arrow", "Wall", "Floor", "Roof", "Door", "Bench", "Table",
        "Chair", "Bed", "Chest Armor", "Head Armor", "Boots", "Gloves", "Ingot", "Ore", "руда", "Trophy", "Carcass",
        "Statue", "Fireplace", "Stove", "Furnace", "Generator", "Canteen", "Bandage", "Rifle", "Shotgun", "Round" }
    local third = { "", "", "", "Frame", "Kit", "Module", "(Damaged)", "Corner", "Attachment", "Vestige", "Mk II" }
    local categories = { "deployable", "creatures", "decorations", "food", "resources", "buildings", "ranged", "tools",
        "corpses", "armor", "attachments", "trophies", "husbandry", "benches", "ammo", "equipment" }
    local big = { items = {}, list = {}, recipes = {}, sets = {}, made_by = {}, used_in = {}, made_at = {} }
    for number = 1, count do
        local name = first[number % #first + 1] .. " " .. second[(number // #first) % #second + 1]
        local tail = third[(number * 7) % #third + 1]
        if tail ~= "" then name = name .. " " .. tail end
        local key = "item_" .. number
        local item = { key = key, static = key, name = name, lower = search.lower(name), hidden = number % 9 == 0,
            cats = { categories[number % #categories + 1], categories[(number * 5) % #categories + 1] } }
        big.items[key], big.list[number] = item, item
    end
    local set_ids = {}
    for number = 1, 68 do
        local id = "set_" .. number
        local benches = {}
        for bench = 0, number % 3 do benches[#benches + 1] = { item = "item_" .. (number * 31 + bench), mw = 1000 } end
        big.sets[id] = { id = id, name = second[number % #second + 1] .. " Station " .. number, benches = benches, group = id }
        set_ids[number] = id
    end
    for number = 1, 2215 do
        local output = "item_" .. ((number * 7) % count + 1)
        local sets = { set_ids[number % 68 + 1] }
        if number % 4 == 0 then sets[2] = set_ids[(number * 3) % 68 + 1] end
        big.recipes[number] = { id = "recipe_" .. number, sets = sets, mj = 2500,
            outputs = { { item = output, count = 1 } },
            inputs = { { item = "item_" .. (number % count + 1), count = 2 }, { item = "item_" .. ((number * 11) % count + 1), count = 1 } } }
        big.made_by[output] = big.made_by[output] or {}
        big.made_by[output][#big.made_by[output] + 1] = number
    end
    return big, categories
end

local SIZE = 2700

t.test("a search of 2,700 items is fast enough to run on every key press", function()
    local big, categories = big_model(SIZE)
    local names = {}
    for _, key in ipairs(categories) do names[key] = key:sub(1, 1):upper() .. key:sub(2) end
    local finder = search.index(big, { categories = names })
    local kept = {}
    for number = 1, SIZE, 40 do kept["item_" .. number] = true end
    local options = { is_favourite = function(item) return kept[item.key] == true end }
    local queries = { "", "a", "iron", "iron ore", "bench -wood", "железная руда", "@station", "@furn #too pick", "#armor -head", "zzzz" }
    local runs, slowest, slowest_query, total = 200, 0, "", 0
    local counts = {}
    for _, typed in ipairs(queries) do
        local found
        local started = os.clock()
        for _ = 1, runs do found = finder.filter(big.list, search.parse(typed), options) end
        local each = (os.clock() - started) * 1000 / runs
        counts[typed] = #found
        total = total + each
        if each > slowest then slowest, slowest_query = each, typed:gsub("[\128-\255]+", "?") end
    end
    local average = total / #queries
    t.eq(counts[""], SIZE - SIZE // 9)
    t.eq(counts["zzzz"], 0)
    for _, typed in ipairs(queries) do t.ok(typed == "zzzz" or counts[typed] > 0, "nothing found for " .. typed) end
    t.ok(counts["iron ore"] < counts["iron"] and counts["iron"] < counts["a"], "more words find less")

    -- The first station search on a new index also works out where every item is made.
    local started = os.clock()
    for _ = 1, 20 do
        t.ok(#search.index(big, { categories = names }).filter(big.list, search.parse("@pickaxe"), options) > 0)
    end
    local first_search = (os.clock() - started) * 1000 / 20

    -- Each letter typed after @ is a word not seen before, which is looked up in every set.
    local fresh, seen = {}, {}
    for _, set in pairs(big.sets) do
        local name = search.lower(set.name)
        for from = 1, 6 do
            for length = 1, 3 do
                local word = name:sub(from, from + length - 1)
                if #word == length and not word:find(" ", 1, true) and not seen[word] then
                    seen[word] = true
                    fresh[#fresh + 1] = search.parse("@" .. word)
                end
            end
        end
    end
    t.ok(#fresh > 100, "enough station words (" .. #fresh .. ")")
    started = os.clock()
    for _, query in ipairs(fresh) do finder.filter(big.list, query, options) end
    local new_word = (os.clock() - started) * 1000 / #fresh

    local recipes = {}
    for number = 1, #big.recipes do recipes[number] = number end
    started = os.clock()
    local some
    for _ = 1, 50 do some = finder.filter_recipes(recipes, "iron @station", nil) end
    local right = (os.clock() - started) * 1000 / 50
    t.ok(#some > 0 and #some < #recipes, "the right list was narrowed")

    print(("recipe-logic: one search of %d items takes %.2f ms on average and %.2f ms at most (query %q)")
        :format(SIZE, average, slowest, slowest_query))
    print(("recipe-logic: a station word not typed before %.2f ms, the first station search on a new model %.2f ms, "
        .. "the right list over %d recipes %.2f ms"):format(new_word, first_search, #recipes, right))
    t.ok(slowest < 5, ("the slowest query took %.2f ms"):format(slowest))
    t.ok(new_word < 5, ("a new station word took %.2f ms"):format(new_word))
    t.ok(first_search < 15, ("the first station search took %.2f ms"):format(first_search))
    t.ok(right < 5, ("the right list took %.2f ms"):format(right))
end)

t.test("the search makes no string per item", function()
    local big, categories = big_model(SIZE)
    local names = {}
    for _, key in ipairs(categories) do names[key] = key end
    local finder = search.index(big, { categories = names })
    local options = { has_recipe = finder.has_recipe, station_match = finder.station_match,
        category_match = finder.category_match, show = "all" }
    local nothing, everything = search.parse("zzzz @station #tools -iron"), search.parse("")
    local narrow = search.parse("@station #tools -iron")
    search.filter(big.list, narrow, options)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    local none = search.filter(big.list, nothing, options)
    local after_none = collectgarbage("count")
    local some = search.filter(big.list, narrow, options)
    local after_some = collectgarbage("count")
    local all = search.filter(big.list, everything, options)
    local after_all = collectgarbage("count")
    collectgarbage("restart")
    t.eq(#none, 0)
    t.ok(#some > 0 and #some < 1000, "the narrow query finds some (" .. #some .. ")")
    t.eq(#all, SIZE - SIZE // 9)
    t.ok(after_none - before < 1, ("a query that finds nothing used %.1f KB"):format(after_none - before))
    t.ok(after_some - after_none < 20, ("a query that finds %d used %.1f KB"):format(#some, after_some - after_none))
    t.ok(after_all - after_some < 80, ("the full list used %.1f KB, more than the list itself"):format(after_all - after_some))
end)

-- favourites
t.test("favourites keep their order and save on every change", function()
    local saves, saved = 0, {}
    local kept = favourites.new(nil, function(list) saves, saved = saves + 1, list end)
    t.eq(kept:has("iron_ore"), false)
    t.eq(kept:count(), 0)
    t.eq(kept:toggle("iron_ore"), true)
    t.eq(kept:toggle("wood"), true)
    t.eq(kept:toggle("sword"), true)
    t.eq(table.concat(kept:list(), " "), "iron_ore wood sword")
    t.eq(saves, 3)
    t.eq(table.concat(saved, " "), "iron_ore wood sword")
    t.eq(kept:toggle("wood"), false, "the second press takes it off")
    t.eq(kept:has("wood"), false)
    t.eq(kept:has("sword"), true)
    t.eq(table.concat(kept:list(), " "), "iron_ore sword")
    t.eq(kept:toggle("wood"), true)
    t.eq(table.concat(kept:list(), " "), "iron_ore sword wood", "put back, it goes to the end")
    t.eq(kept:count(), 3)
    t.eq(saves, 5)
    saved[1] = "changed outside"
    t.eq(table.concat(kept:list(), " "), "iron_ore sword wood", "the saved list is a copy")
    kept:list()[1] = "changed outside"
    t.eq(kept:has("iron_ore"), true)
end)

t.test("favourites refuse what is not a key", function()
    local saves = 0
    local kept = favourites.new(nil, function() saves = saves + 1 end)
    t.eq(kept:toggle(nil), false)
    t.eq(kept:toggle(""), false)
    t.eq(kept:toggle(7), false)
    t.eq(kept:toggle({}), false)
    t.eq(kept:count(), 0)
    t.eq(saves, 0)
    t.eq(kept:has(nil), false)
end)

t.test("keys the model does not have are kept across a save", function()
    local disk = { "iron_ore", "from_a_pak_mod", "sword", "gone_this_week" }
    local function load() return disk end
    local function save(list) disk = list end
    local function known(key) return model.items[key] ~= nil end

    local kept = favourites.new(load, save)
    t.eq(table.concat(kept:list(known), " "), "iron_ore sword", "only what the model has is listed")
    t.eq(kept:count(known), 2)
    t.eq(kept:count(), 4)
    t.eq(kept:has("from_a_pak_mod"), true)
    t.eq(table.concat(kept:list(function() return false end), " "), "", "before the model is read nothing is listed")
    t.eq(kept:count(), 4, "and nothing is lost")

    kept:toggle("wood")
    kept:toggle("iron_ore")
    t.eq(table.concat(disk, " "), "from_a_pak_mod sword gone_this_week wood", "the save still holds them")

    local again = favourites.new(load, save)
    t.eq(table.concat(again:list(known), " "), "sword wood")
    model.items.from_a_pak_mod = { key = "from_a_pak_mod" }
    t.eq(table.concat(again:list(known), " "), "from_a_pak_mod sword wood", "back in its old place when the mod is on again")
    model.items.from_a_pak_mod = nil
    t.eq(table.concat(again:list(), " "), "from_a_pak_mod sword gone_this_week wood")
end)

t.test("a saved list with holes, repeats or other values is read as far as it makes sense", function()
    local kept = favourites.new(function() return { "a", "b", "a", 5, "", false, [9] = "c", name = "d" } end)
    t.eq(table.concat(kept:list(), " "), "a b c")
    t.eq(kept:toggle("e"), true, "works with nothing to save to")
    for _, nothing in ipairs({ false, 3, "text" }) do
        t.eq(favourites.new(function() return nothing end):count(), 0)
    end
    t.eq(favourites.new(function() return nil end):count(), 0)
    t.eq(favourites.new():count(), 0)
end)

t.test("clearing favourites removes the unknown ones too and saves", function()
    local disk = { "iron_ore", "from_a_pak_mod" }
    local kept = favourites.new(function() return disk end, function(list) disk = list end)
    kept:clear()
    t.eq(#disk, 0)
    t.eq(kept:count(), 0)
    t.eq(kept:has("iron_ore"), false)
    t.eq(kept:toggle("iron_ore"), true)
    t.eq(table.concat(disk, " "), "iron_ore")
end)

-- history
t.test("history goes back through the picks", function()
    local past = history.new()
    t.eq(past:can_back(), false)
    t.eq(past:back(), nil)
    t.eq(past:top(), nil)
    t.eq(past:push({ item = "iron_ore", mode = "make" }), true)
    t.eq(past:can_back(), false, "one pick is where we are, not somewhere to go back to")
    t.eq(past:back(), nil)
    t.eq(past:count(), 1, "going back from the first pick keeps it")
    past:push({ item = "iron_ingot", mode = "make" })
    past:push({ item = "iron_ingot", mode = "used" })
    past:push({ item = "iron_pickaxe", mode = "make" })
    t.eq(past:can_back(), true)
    t.eq(past:top().item, "iron_pickaxe")
    local entry = past:back()
    t.eq(entry.item, "iron_ingot")
    t.eq(entry.mode, "used")
    t.ok(past:top() == entry, "the pick gone back to is the one showing")
    t.eq(past:back().mode, "make")
    t.eq(past:back().item, "iron_ore")
    t.eq(past:can_back(), false)
    t.eq(past:back(), nil)
end)

t.test("pushing what is already on top does nothing", function()
    local past = history.new()
    past:push({ item = "iron_ore", mode = "make" })
    t.eq(past:push({ item = "iron_ore", mode = "make" }), false)
    t.eq(past:count(), 1)
    past:push({ item = "wood", mode = "used" })
    local entry = past:back()
    t.eq(past:push(entry), false, "showing the pick gone back to does not add it again")
    t.eq(past:push({ item = entry.item, mode = entry.mode }), false)
    t.eq(past:count(), 1)
    t.eq(past:push({ item = "iron_ore", mode = "used" }), true, "another mode is another pick")
    t.eq(past:push({ item = "wood", mode = "used" }), true)
    t.eq(past:push({ item = "iron_ore", mode = "used" }), true, "the same pick again later is kept")
    t.eq(past:count(), 4)
end)

t.test("history keeps the last 20 picks, or the number it was given", function()
    local past = history.new()
    for number = 1, 50 do past:push({ item = "item_" .. number, mode = "make" }) end
    t.eq(past:count(), 20)
    t.eq(past:top().item, "item_50")
    local steps, last = 0, nil
    while past:can_back() do
        last = past:back()
        steps = steps + 1
    end
    t.eq(steps, 19)
    t.eq(last and last.item, "item_31")
    local short = history.new(3)
    for number = 1, 5 do short:push({ item = number, mode = "make" }) end
    t.eq(short:count(), 3)
    t.eq(short:back().item, 4)
    t.eq(short:back().item, 3)
    t.eq(short:back(), nil)
    t.eq(history.new(0):push({ item = "a" }), true, "a limit under 1 is 1")
    t.eq(history.new("x").limit, 20)
end)

t.test("history takes a pick in other forms and keeps what else it is given", function()
    local past = history.new()
    t.eq(past:push("iron_ore", "make"), true)
    t.eq(past:top().item, "iron_ore")
    t.eq(past:top().mode, "make")
    t.eq(past:push({ "iron_ore", "make" }), false, "the same pick, written as a pair")
    t.eq(past:push({ "wood", "used" }), true)
    t.eq(past:top().item, "wood")
    t.eq(past:top()[1], nil)
    local given = { item = "sword", mode = "make", filter = "iron", station = "anvil" }
    past:push(given)
    given.filter = "changed afterwards"
    t.eq(past:top().filter, "iron", "a copy is kept")
    t.eq(past:top().station, "anvil")
    t.eq(past:push({ mode = "make" }), false, "a pick needs an item")
    t.eq(past:push(nil), false)
    t.eq(past:count(), 3)
    past:clear()
    t.eq(past:count(), 0)
    t.eq(past:can_back(), false)
end)

-- text
local calls, written = {}, {}

local function note(value)
    if type(value) == "string" then
        written[#written + 1] = value
    elseif type(value) == "table" then
        for _, inner in ipairs(value) do note(inner) end
    end
end

local function watch(node, path)
    for key, value in pairs(node) do
        local where = path .. "." .. key
        if type(value) == "function" then
            calls[where] = 0
            node[key] = function(...)
                calls[where] = calls[where] + 1
                local result = value(...)
                note(result)
                return result
            end
        elseif type(value) == "table" then
            watch(value, where)
        elseif type(value) == "string" then
            written[#written + 1] = value
        else
            error(where .. " is neither text nor a function")
        end
    end
end
watch(text, "text")

t.test("numbers get thousands separators", function()
    t.eq(text.number(0), "0")
    if text.pair then t.eq(text.pair("Turns into", "Spoiled Plants"), "Turns into: Spoiled Plants") end
    -- a count on a slot has room for four characters
    for value, shown in pairs({ [0] = "0", [7] = "7", [301] = "301", [999] = "999", [1000] = "1k", [1800] = "1.8k", [2240] = "2.2k",
            [5600] = "5.6k", [9940] = "9.9k", [9960] = "10k", [12345] = "12k", [600000] = "600k", [999600] = "1M", [1300000] = "1.3M" }) do
        t.eq(text.short(value), shown, tostring(value))
        t.ok(#text.short(value) <= 4, shown)
    end
    t.eq(text.number(7), "7")
    t.eq(text.number(999), "999")
    t.eq(text.number(1000), "1,000")
    t.eq(text.number(2668), "2,668")
    t.eq(text.number(123456), "123,456")
    t.eq(text.number(1234567), "1,234,567")
    t.eq(text.number(-1500), "-1,500")
    t.eq(text.number(12.9), "12")
    t.eq(text.number(2668.0), "2,668")
    t.eq(text.number("4200"), "4,200")
    t.eq(text.number(nil), "0")
    t.eq(text.number(0 / 0), "0")
end)

t.test("parts are joined with a plain hyphen and empty ones are left out", function()
    t.eq(text.join("Tier 3", "Electronics", "level 20"), "Tier 3 - Electronics - level 20")
    t.eq(text.join("a", "", nil, false, "b"), "a - b")
    t.eq(text.join(nil, nil), "")
    t.eq(text.join(), "")
    t.eq(text.join({ "Mined from rock", "", "Bought in the Workshop" }), "Mined from rock - Bought in the Workshop")
    t.eq(text.join("a", { "b", "c" }, 4), "a - b - c - 4")
end)

t.test("the fixed texts of the window", function()
    t.eq(text.title, "Prospector's Codex")
    t.eq(text.tabs.browse, "Browse")
    t.eq(text.tabs.settings, "Settings")
    t.eq(text.left.heading, "Items")
    t.eq(text.left.hint, "Search items")
    t.eq(text.left.all_categories, "All categories")
    t.eq(text.left.show.all, "All items")
    t.eq(text.left.show.recipe, "Has a recipe")
    t.eq(text.left.show.favourites, "Favourites")
    t.eq(text.left.show.hidden, "Hidden by the game")
    for _, choice in ipairs(search.SHOWS) do t.ok(text.left.show[choice], "a text for the show choice " .. choice) end
    t.eq(text.right.none, "Nothing picked")
    t.eq(text.right.none_hint, "Click an item to see how it is made.")
    t.eq(text.right.hint, "Search this list")
    t.eq(text.right.all_stations, "All stations")
    t.eq(text.right.no_recipe, "No recipe makes this. Drops, mining, farming and fishing are not listed yet.")
    t.eq(text.right.no_use, "Nothing uses this.")
    t.eq(text.right.nothing_here, "Nothing is made here.")
    t.eq(text.right.by_hand, "By hand")
    t.eq(text.right.one_of, "one of")
    t.eq(text.right.sources, "Where it comes from")
    t.eq(text.right.workshop, "Bought in the Workshop")
    t.eq(text.status.amounts, "Amounts are before talents.")
    t.eq(text.tip.no_recipe, "No recipe")
    t.eq(text.tip.favourite, "In favourites")
    t.eq(text.tip.list_them, "Click to list them")
    t.eq(text.tip.what_uses, "Click for what uses it")
end)

t.test("the item count at 0, 1 and many", function()
    t.eq(text.left.count(0, 0), "0 items")
    t.eq(text.left.count(1, 1), "1 item")
    t.eq(text.left.count(2668, 2668), "2,668 items")
    t.eq(text.left.count(2668), "2,668 items")
    t.eq(text.left.count(42, 2668), "42 of 2,668 items")
    t.eq(text.left.count(1, 2668), "1 of 2,668 items")
    t.eq(text.left.count(1234, 2668, "iron"), "1,234 of 2,668 items")
    t.eq(text.left.count(0, 2668), "0 of 2,668 items")
    t.eq(text.left.count(0, 2668, ""), "0 of 2,668 items")
    t.eq(text.left.count(0, 2668, "xyz"), 'Nothing matches "xyz".')
    t.eq(text.left.count(0, 1), "0 of 1 item")
    t.eq(text.no_match("iron -ore"), 'Nothing matches "iron -ore".')
end)

t.test("the modes with their counts at 0, 1 and many", function()
    t.eq(text.right.mode("make"), "How to make it")
    t.eq(text.right.mode("used"), "Used in")
    t.eq(text.right.mode("here"), "Made here")
    t.eq(text.right.mode("make", 0), "How to make it (0)")
    t.eq(text.right.mode("make", 1), "How to make it (1)")
    t.eq(text.right.mode("make", 2), "How to make it (2)")
    t.eq(text.right.mode("used", 184), "Used in (184)")
    t.eq(text.right.mode("here", 241), "Made here (241)")
    t.eq(text.right.mode("used", 1234), "Used in (1,234)")
    t.eq(text.right.modes.make, "How to make it")
end)

t.test("the line about the picked item", function()
    t.eq(text.right.about(100, "10 g", "Dangerous Horizons"), "stacks to 100 - 10 g - Dangerous Horizons")
    t.eq(text.right.about(1, "1.5 kg", nil), "1.5 kg")
    t.eq(text.right.about(1, "", nil), "")
    t.eq(text.right.about(nil, "", "New Frontiers"), "New Frontiers")
    t.eq(text.right.about(5000, "", ""), "stacks to 5,000")
    t.eq(text.right.stacks(0), "")
    t.eq(text.right.stacks(1), "")
    t.eq(text.right.stacks(2), "stacks to 2")
    t.eq(text.right.stacks(100), "stacks to 100")
    t.eq(text.right.stacks(nil), "")
end)

t.test("the texts of a recipe's lines at 0, 1 and many", function()
    t.eq(text.right.stations(0), "")
    t.eq(text.right.stations(1), "1 station")
    t.eq(text.right.stations(3), "3 stations")
    t.eq(text.right.times(0), "x0")
    t.eq(text.right.times(1), "x1")
    t.eq(text.right.times(5), "x5")
    t.eq(text.right.times(1500), "x1,500")
    t.eq(text.plus(0), "")
    t.eq(text.plus(1), "+1")
    t.eq(text.plus(11), "+11")
    t.eq(text.plus(1200), "+1,200")
    t.eq(text.right.any("Raw Meat"), "any Raw Meat")
    t.eq(text.right.amount("0.1", "L"), "0.1 L")
    t.eq(text.right.amount(12, nil), "12")
    t.eq(text.right.amount("0.5", ""), "0.5")
    t.eq(text.and_more(0), "")
    t.eq(text.and_more(1), "and 1 more")
    t.eq(text.and_more(2), "and 2 more")
    t.eq(text.and_more(5), "and 5 more")
    t.eq(text.and_more(1500), "and 1,500 more")
end)

t.test("the keys line is made from the binds in use", function()
    t.eq(text.right.keys({ make = "R", used = "U", favourite = "A" }), "R make - U uses - A favourite")
    t.eq(text.right.keys({ make = "F", used = "MiddleMouseButton", favourite = "BackSpace" }),
        "F make - MiddleMouseButton uses - BackSpace favourite")
    t.eq(text.right.keys({ used = "U" }), "U uses")
    t.eq(text.right.keys({ make = "R", used = "", favourite = "A" }), "R make - A favourite")
    -- one line of the column: it says no more, whatever else it is handed
    t.eq(text.right.keys({ make = "R", used = "U", favourite = "A" }, true, true), "R make - U uses - A favourite")
    t.eq(text.right.keys({}), "")
    t.eq(text.right.keys(nil), "")
end)

t.test("the favourites strip at 0, 1 and many", function()
    t.eq(text.strip.caption(0), "Favourites (0)")
    t.eq(text.strip.caption(1), "Favourites (1)")
    t.eq(text.strip.caption(23), "Favourites (23)")
    t.eq(text.strip.caption(1023), "Favourites (1,023)")
    t.eq(text.strip.empty("A"), "Press A over an item to keep it here.")
    t.eq(text.strip.empty("K"), "Press K over an item to keep it here.")
    t.eq(text.strip.empty("A", true), "Press A over an item to keep it here. Hold A and move over several to keep them all.")
    t.eq(text.strip.empty(nil, true), "Use the star to keep an item here.")
    t.eq(text.strip.empty(), "Use the star to keep an item here.")
    t.eq(text.strip.empty(""), "Use the star to keep an item here.")
end)

t.test("the status bar and the first notice", function()
    t.eq(text.status.reading(), "Reading the game's items...")
    t.eq(text.status.reading(0), "Reading the game's items...")
    t.eq(text.status.reading(1), "Reading the game's items... 1")
    t.eq(text.status.reading(1250), "Reading the game's items... 1,250")
    t.eq(text.status.counts(0, 0), "0 items, 0 recipes")
    t.eq(text.status.counts(1, 1), "1 item, 1 recipe")
    t.eq(text.status.counts(2668, 2215), "2,668 items, 2,215 recipes")
    t.eq(text.status.opens("F7"), "F7 opens this")
    t.eq(text.status.opens(nil), "")
    t.eq(text.first_load("F7"), "Press F7 to open the Prospector's Codex.")
    t.eq(text.first_load("F6"), "Press F6 to open the Prospector's Codex.")
    t.eq(text.first_load(nil), "")
    t.eq(text.panel.page(2, 1234), "Page 2 of 1,234")
    t.eq(text.panel.ready(12), "12 can be made now")
    t.eq(text.panel.ready(0), "None can be made now")
    t.eq(text.tree.title(1500), "Everything for 1,500")
    t.eq(text.tree.crafts(1, "Anvil Bench"), "Make once at Anvil Bench")
    t.eq(text.tree.crafts(12, ""), "Make 12 times")
    t.eq(text.tree.makes(15, 5), "Makes 15, 5 left over")
    t.eq(text.tree.makes(1000, 0), "Makes 1,000")
    t.eq(text.tip.takes("2.5 s"), "Takes 2.5 s")
    t.eq(text.tip.takes("Campfire 30 s, Fireplace 23 s"), "Campfire 30 s, Fireplace 23 s")
    t.eq(text.tip.takes(""), "")
    t.eq(text.duration(2.5), "2.5 s")
    t.eq(text.duration(3), "3 s")
    t.eq(text.duration(40.4), "40 s")
    t.eq(text.duration(200), "3 min 20 s")
    t.eq(text.duration(180), "3 min")
    t.eq(text.duration(7500), "2 h 5 min")
    t.eq(text.duration(7200), "2 h")
    t.eq(text.tree.step("Stick", 10, "25 s", "Anvil Bench"), "Stick x10 - 25 s at Anvil Bench")
    t.eq(text.tree.step("Stick", 10, "25 s", ""), "Stick x10 - 25 s")
    t.eq(text.tree.step("Coin", 5, "", ""), "Coin x5")
    t.eq(text.tree.each("2.5 s", "25 s"), "2.5 s each, 25 s in all")
    t.eq(text.tree.each("2.5 s", "2.5 s"), "Takes 2.5 s")
    t.eq(text.tree.total("3 min"), "Making it all takes 3 min, before talents and upgrades.")
end)

t.test("the needs line is made of these pieces", function()
    local needs = text.needs
    t.eq(text.join(needs.tier(3), "Electronics", needs.level(20)), "Tier 3 - Electronics - level 20")
    t.eq(text.join(needs.tier(1), "Stone Pickaxe", needs.known), "Tier 1 - Stone Pickaxe - known from the start")
    t.eq(needs.tier(2), "Tier 2")
    t.eq(needs.level(0), "level 0")
    t.eq(needs.level(1), "level 1")
    t.eq(needs.pack("Art Deco Pack"), "needs Art Deco Pack")
    t.eq(needs.mission("Dry Run"), "needs Dry Run finished")
    t.eq(needs.mission_only, "only during a mission")
    t.eq(needs.talent("Rifle Reduction"), "needs talent Rifle Reduction")
    t.eq(needs.no_talent, "cannot be made in this version of the game")
    t.eq(needs.no_station, "cannot be made")
end)

t.test("the tooltip lines at 0, 1 and many", function()
    local tip = text.tip
    t.eq(tip.made_at({}), "")
    t.eq(tip.made_at({ "Anvil Bench" }), "Made at Anvil Bench")
    t.eq(tip.made_at({ "Machining Bench", "Fabricator" }), "Made at Machining Bench, Fabricator")
    t.eq(tip.made_at({ "Machining Bench", "Fabricator", "Crafting Bench" }), "Made at Machining Bench, Fabricator, +1")
    t.eq(tip.made_at({ "a", "b", "c", "d", "e" }, 3), "Made at a, b, c, +2")
    t.eq(tip.used_in(0), "")
    t.eq(tip.used_in(1), "Used in 1 recipe")
    t.eq(tip.used_in(153), "Used in 153 recipes")
    t.eq(tip.used_in(1530), "Used in 1,530 recipes")
    t.eq(tip.amount(15, "Copper Wire"), "15 x Copper Wire")
    t.eq(tip.amount(1, "Rope"), "1 x Rope")
    t.eq(tip.amount("12k", "Stone"), "12k x Stone")
    t.eq(tip.amount(3, text.right.any("Raw Meat")), "3 x any Raw Meat")
    t.eq(tip.made("Electronics", 1), "Electronics x1")
    t.eq(tip.made("Iron Nail", 50), "Iron Nail x50")
    t.eq(tip.resource("Water", "0.1", "L"), "Water 0.1 L")
    t.eq(tip.one_of(), "one of")
    t.eq(tip.one_of(0), "one of")
    t.eq(tip.one_of(1), "one of 1")
    t.eq(tip.one_of(10), "one of 10")
    t.eq(tip.bench("Campfire", "30 s"), "Campfire 30 s")
    t.eq(tip.bench("Fireplace", "23 s"), "Fireplace 23 s")
    t.eq(tip.bench("Smoker", ""), "Smoker")
end)

t.test("a long list of names is cut with a count of the rest", function()
    t.eq(table.concat(text.some({}), "|"), "")
    t.eq(table.concat(text.some({ "a" }), "|"), "a")
    t.eq(table.concat(text.some({ "a", "b", "c", "d", "e", "f" }), "|"), "a|b|c|d|e|f")
    t.eq(table.concat(text.some({ "a", "b", "c", "d", "e", "f", "g" }), "|"), "a|b|c|d|e|f|and 1 more")
    t.eq(table.concat(text.some({ "a", "b", "c", "d", "e", "f", "g", "h" }), "|"), "a|b|c|d|e|f|and 2 more")
    t.eq(table.concat(text.some({ "a", "b", "c" }, 1), "|"), "a|and 2 more")
    local names = { "a", "b" }
    t.ok(text.some(names) ~= names, "a new list is returned")
end)

t.test("the settings page", function()
    local settings = text.settings
    t.eq(settings.keys.open, "Open the browser")
    t.eq(settings.keys.make, "How to make it")
    t.eq(settings.keys.used, "Used in")
    t.eq(settings.keys.favourite, "Favourite")
    t.eq(settings.keys.back, "Back")
    t.eq(settings.key_is_menu, "This key opens the Wax menu.")
    t.eq(settings.key_taken, "Another action uses this key.")
    t.eq(settings.cell_size, "Cell size")
    t.eq(settings.sizes.small, "Small")
    t.eq(settings.sizes.normal, "Normal")
    t.eq(settings.sizes.large, "Large")
    t.eq(settings.as_list, "Show as a list")
    t.eq(settings.as_lines, "Show recipes as lines")
    t.eq(settings.internal_names, "Show internal names")
    t.eq(settings.with_menu("F8"), "Show with the Wax menu (F8)")
    t.eq(settings.with_menu("Insert"), "Show with the Wax menu (Insert)")
    t.eq(settings.with_menu(nil), "Show with the Wax menu")
    t.eq(settings.read_at_start, "Read the game's data when the game starts")
    t.eq(settings.read_again, "Read the game's data again")
    t.eq(settings.clear, "Clear favourites")
    t.eq(settings.remove, "Remove")
    t.eq(settings.keep, "Keep")
    t.eq(settings.clear_question(0), "There are no favourites.")
    t.eq(settings.clear_question(1), "Remove 1 favourite?")
    t.eq(settings.clear_question(12), "Remove all 12 favourites?")
    t.eq(settings.clear_question(1200), "Remove all 1,200 favourites?")
    t.eq(settings.read(2668, 2215, 6.24), "2,668 items, 2,215 recipes, read in 6.2 s")
    t.eq(settings.read(1, 1, 0.04), "1 item, 1 recipe, read in 0.0 s")
    t.eq(settings.read(2668, 2215), "2,668 items, 2,215 recipes")
    t.eq(settings.read(0, 0, 0), "0 items, 0 recipes")
    t.eq(settings.skipped(0), "")
    t.eq(settings.skipped(1), "1 recipe could not be read")
    t.eq(settings.skipped(3), "3 recipes could not be read")
end)

t.test("the problems", function()
    t.eq(text.problem.needs_wax("0.2.0"), "Prospector's Codex needs Wax 0.2.0 or newer.")
    t.eq(text.problem.needs_wax(), "Prospector's Codex needs a newer Wax.")
    t.eq(text.problem.changed("D_RecipeSets", "Character"),
        "This version of the game changed D_RecipeSets.Character. Recipes cannot be shown until Prospector's Codex is updated.")
    t.eq(text.problem.changed("D_ProcessorRecipes", "Inputs.Count"),
        "This version of the game changed D_ProcessorRecipes.Inputs.Count. Recipes cannot be shown until Prospector's Codex is updated.")
    t.eq(text.problem.changed("D_Talents"),
        "This version of the game changed D_Talents. Recipes cannot be shown until Prospector's Codex is updated.")
end)

-- a copy of the mod from before it had a research line has none of these
if text.research then
    t.test("the research line of a recipe", function()
        local research = text.research
        t.eq(research.done, "Researched")
        t.eq(research.all, "Research all")
        t.eq(research.cancel, "Cancel")
        t.eq(research.button(1), "Research (1 point)")
        if research.ask_one then
            t.eq(research.one, "Research")
            t.eq(research.ask_one(1, 11), "This spends 1 point.")
            t.eq(research.have(10), "Research points: 10")
        end
        t.eq(research.button(3), "Research (3 points)")
        t.eq(research.ask({ "Machining Bench" }, 2, 11), "Researches Machining Bench first. 2 points in all.")
        t.eq(research.ask({ "Machining Bench", "Cement Mixer" }, 3, 11),
            "Researches Machining Bench and Cement Mixer first. 3 points in all.")
        t.eq(research.ask({ "A", "B", "C" }, 4, 4), "Researches A, B and C first. 4 points in all.")
        t.eq(research.ask({ "A", "B", "C", "D", "E" }, 6, 1200), "Researches A, B, C and 2 more first. 6 points in all.")
        t.eq(research.level(25), "Unlocks at level 25")
        t.eq(research.points(3, 1), "Needs 3 points")
        t.eq(research.points(1, 0), "Needs 1 point")
        t.eq(research.researched("Shotgun"), "Shotgun researched.")
        t.eq(research.refused("Cement Mixer"), "The game did not research Cement Mixer.")
    end)
end

-- a copy of the mod from before it said what a craft gives has none of these
if text.xp then
    t.test("the XP of a craft: one amount, a range, a tip's line, a step of Materials and the sum", function()
        t.eq(text.xp(52), "52 XP")
        t.eq(text.xp(240, 2160), "240 to 2,160 XP")
        t.eq(text.xp(0), "")
        t.eq(text.tip.gives("52 XP"), "Gives 52 XP")
        t.eq(text.tip.gives(""), "")
        t.eq(text.tree.gives("52 XP", "52 XP"), "Gives 52 XP")
        t.eq(text.tree.gives("52 XP", "520 XP"), "52 XP each, 520 XP in all")
        t.eq(text.tree.step("Stick", 10, "25 s", "", "520 XP"), "Stick x10 - 25 s - 520 XP")
        t.eq(text.tree.total("", "1,240 XP"), "Making it all gives 1,240 XP, before bonuses.")
        t.eq(text.tree.total("2 min 5 s", "1,240 XP"),
            "Making it all takes 2 min 5 s and gives 1,240 XP, before talents, upgrades and bonuses.")
    end)
end

t.test("every counted text was tried", function()
    local missed = {}
    for where, count in pairs(calls) do
        if count == 0 then missed[#missed + 1] = where end
    end
    table.sort(missed)
    t.eq(table.concat(missed, ", "), "", "functions of text.lua no test called")
    t.ok(#written > 150, "the texts were collected (" .. #written .. ")")
end)

-- The owner's list of unwanted words is kept in one file, which is not part of the public copy.
local function unwanted()
    local file = io.open("wax/vscode/test/wording.test.mjs", "rb")
    if not file then return nil end
    local source = file:read("a")
    file:close()
    local listed = source:match("BANNED = /(.-)/i;")
    local words, phrases = (listed or ""):match("^\\b%((.-)%)\\b|(.*)$")
    local out = { words = {}, phrases = {}, initials = source:match("INITIALS = /\\b(%u+)\\b/") }
    for term in (words or ""):gmatch("[^|]+") do
        local base, ending = term:match("^(.-)%((%a+)%)%?$")
        if not base then base, ending = term:match("^(.-)(%a)%?$") end
        if base then
            out.words[#out.words + 1] = base
            out.words[#out.words + 1] = base .. ending
        else
            out.words[#out.words + 1] = term
        end
    end
    for phrase in (phrases or ""):gmatch("[^|]+") do out.phrases[#out.phrases + 1] = phrase end
    return out
end

local function wrong_with(line, list)
    if line:find("[\128-\255]") then return "a character that is not plain ASCII (a dash, an ellipsis, a picture)" end
    if line:find("!", 1, true) then return "an exclamation mark" end
    if line:find(";", 1, true) then return "a semicolon" end
    if line:find("%-%-") or line:find("%.%.%.%.") then return "a dash or dots that are not plain" end
    if not list then return nil end
    local lowered = line:lower()
    local spaced = " " .. lowered:gsub("%A", " ") .. " "
    for _, word in ipairs(list.words) do
        if spaced:find(" " .. word .. " ", 1, true) then return "the word '" .. word .. "'" end
    end
    for _, phrase in ipairs(list.phrases) do
        if lowered:find(phrase, 1, true) then return "'" .. phrase .. "'" end
    end
    if list.initials and (" " .. line:gsub("%A", " ") .. " "):find(" " .. list.initials .. " ", 1, true) then
        return "the initials " .. list.initials
    end
    return nil
end

t.test("every text is in plain words", function()
    local list = unwanted()
    if list then
        t.ok(#list.words > 20 and #list.phrases > 3 and list.initials, "the owner's list was read from wording.test.mjs")
        t.eq(wrong_with("Simply press the key", list), "the word 'simply'", "the check finds a listed word")
        t.eq(wrong_with("Seamlessly done", list), "the word 'seamlessly'", "and a listed ending")
        t.eq(wrong_with("Keep in mind the key", list), "'keep in mind'", "and a listed phrase")
        t.eq(wrong_with("It adjusts the richness", list), nil, "but not a part of a longer word")
    end
    t.eq(wrong_with("Done!"), "an exclamation mark")
    t.eq(wrong_with("One; two"), "a semicolon")
    t.ok(wrong_with("Reading" .. utf8.char(0x2026)), "the ellipsis character is found")
    t.ok(wrong_with("a " .. utf8.char(0x2014) .. " b"), "a long dash is found")
    t.eq(wrong_with("Reading the game's items..."), nil)
    t.eq(wrong_with("Tier 3 - Electronics - level 20"), nil)
    local problems = {}
    for _, line in ipairs(written) do
        local wrong = wrong_with(line, list)
        if wrong then problems[#problems + 1] = ("%q has %s"):format(line, wrong) end
    end
    t.eq(table.concat(problems, "\n"), "")
    if not list then print("recipe-logic: the list of unwanted words is not here, so only the marks were checked") end
end)

t.finish("recipe-logic")
