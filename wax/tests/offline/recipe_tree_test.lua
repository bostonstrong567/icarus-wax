-- Offline tests for the Recipe Browser's crafting tree: what an item takes from raw materials, the totals and the order.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\recipe_tree_test.lua luamods\RecipeBrowser

local t = dofile("wax/tests/offline/harness.lua")

local folder = arg and arg[1]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end

local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
end

if not folder or not exists(folder .. "/tree.lua") or not exists(folder .. "/model.lua") then
    print("recipe-tree: 0 passed (skipped: Recipe Browser is not here)")
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
local fixture = dofile("wax/tests/offline/recipe_fixture.lua")

local function build_model(provider)
    local src = source.new(provider)
    src.read_all(1)
    return (model.build(src, nil, string.lower, tags))
end

local m = build_model(fixture.provider())

-- A model by hand for what the fixture lacks. A recipe: out, from, tags, res as { { key, count } }, at (stations), mj, random, hidden.
local function tiny(recipes, names)
    local built = { items = {}, recipes = {}, made_by = {}, tags = {}, resources = {},
        sets = { bench = { id = "bench", name = "Bench" }, hand = { id = "hand", name = "Character", hand = true },
            blank = { id = "blank", name = "" } } }
    local function named(key) return names and names[key] or key end
    local function item(key)
        built.items[key] = built.items[key] or { key = key, static = key, name = named(key), icon = "/icons/" .. key }
        return key
    end
    for number, spec in ipairs(recipes) do
        local recipe = { inputs = {}, tags_in = {}, res_in = {}, outputs = {}, res_out = {}, stations = spec.at or { "bench" },
            mj = spec.mj or 100, random = spec.random == true, hidden_only = spec.hidden == true }
        for _, pair in ipairs(spec.out) do
            recipe.outputs[#recipe.outputs + 1] = { item = item(pair[1]), count = pair[2] }
            built.made_by[pair[1]] = built.made_by[pair[1]] or {}
            table.insert(built.made_by[pair[1]], number)
        end
        for _, pair in ipairs(spec.from or {}) do recipe.inputs[#recipe.inputs + 1] = { item = item(pair[1]), count = pair[2] } end
        for _, pair in ipairs(spec.tags or {}) do
            built.tags[pair[1]] = { key = pair[1], name = named(pair[1]) }
            recipe.tags_in[#recipe.tags_in + 1] = { tag = pair[1], count = pair[2] }
        end
        for _, pair in ipairs(spec.res or {}) do
            built.resources[pair[1]] = { key = pair[1], name = named(pair[1]) }
            recipe.res_in[#recipe.res_in + 1] = { res = pair[1], units = pair[2] }
        end
        built.recipes[number] = recipe
    end
    return built
end

-- "top0 a1 ore2": the nodes as an indented list shows them, each with its depth.
local function outline(root)
    local out = {}
    for position, node in ipairs(tree.flatten(root)) do out[position] = node.key .. node.depth end
    return table.concat(out, " ")
end

-- "ore=14 wood=10": a list of totals or steps, one field of each.
local function listed(list, field)
    local out = {}
    for position, entry in ipairs(list) do out[position] = entry.key .. "=" .. tostring(entry[field]) end
    return table.concat(out, " ")
end

local function count_why(root, why)
    local count = 0
    for _, node in ipairs(tree.flatten(root)) do
        if node.why == why then count = count + 1 end
    end
    return count
end

t.test("build: an item the model does not have gives nothing", function()
    t.eq(tree.build(m, "not_an_item", 1), nil)
    t.eq(tree.build(m, nil, 1), nil)
    t.eq(tree.build(m, 12, 1), nil)
    t.eq(tree.build(nil, "flour", 1), nil)
    t.eq(tree.build(m, "banner", 1), nil, "a static dropped for its kinds is not an item")
    t.eq(#tree.totals(nil), 0)
    t.eq(#tree.steps(nil), 0)
    t.eq(#tree.flatten(nil), 0)
end)

t.test("build: an item nothing makes is one raw node", function()
    local root = tree.build(m, "flour", 7)
    t.eq(root.kind, "item")
    t.eq(root.key, "flour")
    t.eq(root.name, "Flour")
    t.eq(root.icon, "/Game/Fixture/ITEM_Flour.ITEM_Flour")
    t.eq(root.need, 7)
    t.eq(root.depth, 0)
    t.eq(root.raw, true)
    t.eq(root.why, "raw")
    t.eq(root.options, 0)
    t.eq(root.recipe, nil)
    t.eq(root.children, nil)
    local totals = tree.totals(root)
    t.eq(#totals, 1, "the root is listed when it is raw")
    t.eq(totals[1].kind, "item")
    t.eq(totals[1].key, "flour")
    t.eq(totals[1].name, "Flour")
    t.eq(totals[1].icon, "/Game/Fixture/ITEM_Flour.ITEM_Flour")
    t.eq(totals[1].need, 7)
    t.eq(#tree.steps(root), 0)
    t.eq(outline(root), "flour0")
end)

t.test("build: how many is a whole number of one or more", function()
    t.eq(tree.build(m, "flour").need, 1)
    t.eq(tree.build(m, "flour", 0).need, 1)
    t.eq(tree.build(m, "flour", -3).need, 1)
    t.eq(tree.build(m, "flour", 2.9).need, 2)
    t.eq(tree.build(m, "flour", "4").need, 4)
    t.eq(tree.build(m, "flour", "many").need, 1)
    t.eq(tree.build(m, "flour", 0 / 0).need, 1)
end)

t.test("build: one level, made by hand", function()
    local root = tree.build(m, "hearth", 2)
    t.eq(root.name, "Hearth")
    t.eq(root.raw, false)
    t.eq(root.why, nil)
    t.eq(root.recipe, m.recipe.hearth)
    t.eq(root.makes, 1)
    t.eq(root.crafts, 2)
    t.eq(root.left, 0)
    t.eq(root.station, "Character")
    t.eq(root.hand, true)
    t.eq(root.set, "character")
    t.eq(root.mj, 5000)
    t.eq(root.options, 1)
    t.eq(#root.children, 1)
    local pebble = root.children[1]
    t.eq(pebble.kind, "item")
    t.eq(pebble.key, "pebble")
    t.eq(pebble.name, "Pebble")
    t.eq(pebble.need, 24)
    t.eq(pebble.depth, 1)
    t.eq(pebble.raw, true)
end)

t.test("build: two levels, each need is the amount times the crafts above", function()
    local root = tree.build(m, "press", 3)
    t.eq(root.recipe, m.recipe.press)
    t.eq(root.crafts, 3)
    t.eq(root.station, "Work Table")
    t.eq(root.hand, false)
    t.eq(root.set, "work_table")
    t.eq(root.mj, 7500)
    local gear = root.children[1]
    t.eq(gear.key, "gear")
    t.eq(gear.need, 12)
    t.eq(gear.recipe, m.recipe.gear)
    t.eq(gear.makes, 2)
    t.eq(gear.crafts, 6)
    t.eq(gear.left, 0)
    t.eq(gear.station, "Work Table", "the first of its three stations")
    t.eq(gear.mj, 30000)
    t.eq(gear.depth, 1)
    t.eq(gear.children[1].key, "pebble")
    t.eq(gear.children[1].need, 24)
    t.eq(gear.children[1].depth, 2)
    t.eq(outline(root), "press0 gear1 pebble2")
end)

t.test("build: a craft that gives several is rounded up, and the rest is left over", function()
    local gear = tree.build(m, "gear", 5)
    t.eq(gear.makes, 2)
    t.eq(gear.crafts, 3)
    t.eq(gear.left, 1)
    t.eq(gear.children[1].need, 12)
    local nails = tree.build(m, "nails", 25)
    t.eq(nails.makes, 10)
    t.eq(nails.crafts, 3)
    t.eq(nails.left, 5)
    t.eq(nails.children[1].need, 3)
    local exact = tree.build(m, "nails", 30)
    t.eq(exact.crafts, 3)
    t.eq(exact.left, 0)
end)

t.test("build: rounding happens at each level", function()
    local root = tree.build(m, "stone_knife", 3)
    t.eq(outline(root), "stone_knife0 pebble1 twig1 pebble2")
    t.eq(root.children[1].need, 6)
    local twig = root.children[2]
    t.eq(twig.need, 3)
    t.eq(twig.recipe, m.recipe.twig_split)
    t.eq(twig.makes, 2)
    t.eq(twig.crafts, 2)
    t.eq(twig.left, 1)
    t.eq(twig.hand, true)
    t.eq(twig.children[1].need, 2)
end)

t.test("build: a recipe that makes several things counts the one that is wanted", function()
    local saw = tree.build(m, "bone_saw", 3)
    local bone = saw.children[1]
    t.eq(bone.key, "fish_bone")
    t.eq(bone.need, 6)
    t.eq(bone.recipe, m.recipe.butcher_trout)
    t.eq(bone.makes, 1)
    t.eq(bone.crafts, 6)
    t.eq(bone.children[1].key, "river_trout")
    t.eq(bone.children[1].need, 6)
    local meat = tree.build(m, "fish_meat", 5)
    t.eq(meat.makes, 2)
    t.eq(meat.crafts, 3)
    t.eq(meat.left, 1)
end)

t.test("build: a recipe that picks its output at random is not broken down", function()
    local pebble = tree.build(m, "hearth", 1).children[1]
    t.eq(pebble.raw, true)
    t.eq(pebble.why, "random")
    t.eq(pebble.recipe, m.recipe.crack_geode, "the recipe it would have used")
    t.eq(pebble.options, 2)
    t.eq(pebble.children, nil)
    t.eq(pebble.crafts, nil)
    local ruby = tree.build(m, "ruby", 4)
    t.eq(ruby.why, "random")
    t.eq(listed(tree.totals(ruby), "need"), "ruby=4")
    t.eq(#tree.steps(ruby), 0)
end)

t.test("build: a random recipe with one output is an ordinary one", function()
    local one = tiny({ { out = { { "a", 1 } }, from = { { "b", 2 } }, random = true } })
    local root = tree.build(one, "a", 3)
    t.eq(root.raw, false)
    t.eq(root.children[1].need, 6)
    local two = tiny({ { out = { { "a", 1 }, { "c", 1 } }, from = { { "b", 2 } }, random = true } })
    t.eq(tree.build(two, "a", 3).why, "random")
end)

t.test("build: a tag input is a leaf", function()
    local root = tree.build(m, "baked_fish", 3)
    t.eq(root.station, "Hearth", "the set no item provides is not a station")
    t.eq(root.set, "hearth")
    t.eq(root.mj, 22500)
    t.eq(#root.children, 1)
    local fish = root.children[1]
    t.eq(fish.kind, "tag")
    t.eq(fish.key, "any_fish")
    t.eq(fish.name, "Fish")
    t.eq(fish.icon, "/Game/Fixture/QUERY_Fish.QUERY_Fish")
    t.eq(fish.need, 6)
    t.eq(fish.depth, 1)
    t.eq(fish.raw, true)
    t.eq(fish.why, nil)
    t.eq(fish.children, nil)
    local totals = tree.totals(root)
    t.eq(#totals, 1)
    t.eq(totals[1].kind, "tag")
    t.eq(totals[1].need, 6)
end)

t.test("build: a resource input is a leaf and comes after the items", function()
    local root = tree.build(m, "dough", 4)
    t.eq(#root.children, 2)
    t.eq(root.children[1].kind, "item")
    t.eq(root.children[1].key, "flour")
    t.eq(root.children[1].need, 8)
    t.eq(root.children[1].why, "raw")
    local water = root.children[2]
    t.eq(water.kind, "resource")
    t.eq(water.key, "water")
    t.eq(water.name, "Water")
    t.eq(water.icon, "/Game/Fixture/RES_Water.RES_Water")
    t.eq(water.need, 400)
    t.eq(water.raw, true)
    t.eq(water.why, nil)
    local totals = tree.totals(root)
    t.eq(listed(totals, "need"), "flour=8 water=400")
    t.eq(totals[2].kind, "resource")
end)

t.test("build: items, then tags, then resources", function()
    local mixed = tiny({ { out = { { "top", 1 } }, from = { { "ore", 2 } }, tags = { { "wood", 3 } }, res = { { "water", 50 } } } })
    local root = tree.build(mixed, "top", 2)
    t.eq(outline(root), "top0 ore1 wood1 water1")
    t.eq(root.children[1].kind, "item")
    t.eq(root.children[2].kind, "tag")
    t.eq(root.children[3].kind, "resource")
    t.eq(root.children[1].need, 4)
    t.eq(root.children[2].need, 6)
    t.eq(root.children[3].need, 100)
end)

t.test("build: recipes the browser hides, without a station or taking nothing are not picked", function()
    local quest = tree.build(m, "ruby_quest", 1)
    t.eq(quest.why, "raw", "its only recipe makes hidden things")
    t.eq(quest.options, 0)
    local hearth = tree.build(m, "big_hearth", 1)
    local brick = hearth.children[1]
    t.eq(brick.need, 20)
    t.eq(brick.why, "raw", "no item provides the Kiln")
    t.eq(brick.options, 0)

    local second = tiny({
        { out = { { "a", 1 } }, from = { { "x", 1 } }, hidden = true },
        { out = { { "a", 1 } }, from = { { "y", 1 } }, at = {} },
        { out = { { "a", 1 } } },
        { out = { { "a", 1 } }, from = { { "z", 1 } } },
        { out = { { "a", 1 } }, from = { { "w", 1 } } },
    })
    local root = tree.build(second, "a", 1)
    t.eq(root.recipe, 4)
    t.eq(root.options, 2)
    t.eq(root.children[1].key, "z")

    local nothing = tiny({ { out = { { "a", 1 } } } })
    t.eq(tree.build(nothing, "a", 5).why, "raw")
    local forced = tree.build(nothing, "a", 5, { choice = { a = 1 } })
    t.eq(forced.why, "raw", "what takes nothing breaks nothing down")
    t.eq(listed(tree.totals(forced), "need"), "a=5")
end)

t.test("build: a recipe headed by another item gives one of it a craft", function()
    local root = tree.build(m, "drink_mint_tea", 2)
    t.eq(root.name, "Mint Tea")
    t.eq(root.recipe, m.recipe.mint_tea)
    t.eq(root.makes, 1)
    t.eq(root.crafts, 2)
    t.eq(root.station, "Hearth")
    t.eq(outline(root), "drink_mint_tea0 mint1 water1")
    t.eq(root.children[1].need, 2)
    t.eq(root.children[2].need, 500)
end)

t.test("build: a kind of an item counts for the item", function()
    local root = tree.build(m, "mash", 1)
    t.eq(root.station, "Press")
    local seed = root.children[1]
    t.eq(seed.key, "seed")
    t.eq(seed.need, 3)
    t.eq(seed.recipe, m.recipe.oat_seeds)
    t.eq(seed.options, 2)
    t.eq(seed.makes, 2)
    t.eq(seed.crafts, 2)
    t.eq(seed.left, 1)
    t.eq(seed.children[1].key, "oat")
    t.eq(seed.children[1].need, 2)
    local kind = tree.build(m, "seed:oat", 5)
    t.eq(kind.name, "Oat Seed")
    t.eq(kind.makes, 2)
    t.eq(kind.crafts, 3)
    t.eq(kind.left, 1)

    local husked = tiny({ { out = { { "husk", 5 }, { "seed:oat", 2 } }, from = { { "oat", 1 } } } })
    husked.items["seed"] = { key = "seed", static = "seed", name = "Seed" }
    husked.items["seed:oat"].static = "seed"
    husked.made_by["seed"] = { 1 }
    local plain = tree.build(husked, "seed", 3)
    t.eq(plain.makes, 2, "the kind, not the first thing the recipe makes")
    t.eq(plain.crafts, 2)
    t.eq(tree.build(husked, "husk", 3).makes, 5)
end)

t.test("build: the station is the first one with a name", function()
    local named = tiny({
        { out = { { "a", 1 } }, from = { { "x", 1 } }, at = { "gone", "blank", "bench", "hand" } },
        { out = { { "b", 1 } }, from = { { "x", 1 } }, at = { "blank" } },
    })
    local a = tree.build(named, "a", 1)
    t.eq(a.station, "Bench")
    t.eq(a.set, "bench")
    t.eq(a.hand, false)
    local b = tree.build(named, "b", 1)
    t.eq(b.raw, false)
    t.eq(b.station, nil)
    t.eq(b.set, nil)
    t.eq(b.hand, false)
end)

t.test("build: an item that stands for a resource counts the units", function()
    local root = tree.build(m, "fieldguide_water", 1200)
    t.eq(root.recipe, m.recipe.pump_water)
    t.eq(root.makes, 500)
    t.eq(root.crafts, 3)
    t.eq(root.left, 300)
    t.eq(root.children[1].key, "bucket")
    t.eq(root.children[1].need, 3)
end)

t.test("choice: another recipe for an item", function()
    local plain = tree.build(m, "nails", 250)
    t.eq(plain.recipe, m.recipe.nails)
    t.eq(plain.options, 2)
    t.eq(plain.crafts, 25)
    t.eq(plain.station, "Work Table")
    t.eq(plain.children[1].need, 25)
    local bulk = tree.build(m, "nails", 250, { choice = { nails = m.recipe.bulk_nails } })
    t.eq(bulk.recipe, m.recipe.bulk_nails)
    t.eq(bulk.makes, 100)
    t.eq(bulk.crafts, 3)
    t.eq(bulk.left, 50)
    t.eq(bulk.station, "Lathe")
    t.eq(bulk.children[1].need, 15)
end)

t.test("choice: reaches items further down, and a random default can be replaced", function()
    local root = tree.build(m, "hearth", 1, { choice = { pebble = m.recipe.clean_red } })
    local pebble = root.children[1]
    t.eq(pebble.raw, false)
    t.eq(pebble.why, nil)
    t.eq(pebble.recipe, m.recipe.clean_red)
    t.eq(pebble.makes, 2)
    t.eq(pebble.crafts, 6)
    t.eq(pebble.children[1].key, "crust_red")
    t.eq(pebble.children[1].need, 6)
    t.eq(pebble.children[1].why, "raw")
end)

t.test("choice: a recipe that does not make the item is ignored", function()
    local root = tree.build(m, "hearth", 1, { choice = { pebble = m.recipe.gear, hearth = 9999 } })
    t.eq(root.recipe, m.recipe.hearth)
    t.eq(root.children[1].why, "random")
    t.eq(tree.build(m, "hearth", 1, { choice = { hearth = "hearth" } }).recipe, m.recipe.hearth)
end)

t.test("choice: false stops at an item", function()
    local root = tree.build(m, "press", 1, { choice = { gear = false } })
    local gear = root.children[1]
    t.eq(gear.raw, true)
    t.eq(gear.why, "raw")
    t.eq(gear.recipe, nil)
    t.eq(gear.options, 1, "it could still be made")
    t.eq(gear.children, nil)
    t.eq(listed(tree.totals(root), "need"), "gear=4")
    t.eq(listed(tree.steps(root), "crafts"), "press=1")
end)

t.test("choice: may name a recipe the tree would not pick by itself", function()
    local quest = tree.build(m, "ruby_quest", 2, { choice = { ruby_quest = m.recipe.ruby_quest } })
    t.eq(quest.raw, false)
    t.eq(quest.children[1].need, 18)
    local hearth = tree.build(m, "big_hearth", 1, { choice = { brick = m.recipe.brick } })
    local brick = hearth.children[1]
    t.eq(brick.raw, false)
    t.eq(brick.crafts, 20)
    t.eq(brick.station, nil)
    t.eq(brick.hand, false)
    t.eq(brick.set, nil)
    t.eq(brick.children[1].need, 60)
end)

t.test("loop: an item already on the path above is not broken down again", function()
    local loop = tiny({ { out = { { "a", 1 } }, from = { { "b", 2 } } }, { out = { { "b", 1 } }, from = { { "a", 3 } } } })
    local root = tree.build(loop, "a", 2)
    t.eq(outline(root), "a0 b1 a2")
    local b = root.children[1]
    t.eq(b.raw, false)
    t.eq(b.crafts, 4)
    local again = b.children[1]
    t.eq(again.raw, true)
    t.eq(again.why, "loop")
    t.eq(again.need, 12)
    t.eq(again.recipe, 1)
    t.eq(again.children, nil)
    t.eq(listed(tree.totals(root), "need"), "a=12")
    t.eq(listed(tree.steps(root), "crafts"), "b=4 a=2")
end)

t.test("loop: an item that takes itself, and a loop of three", function()
    local own = tiny({ { out = { { "x", 2 } }, from = { { "x", 1 }, { "y", 1 } } } })
    local root = tree.build(own, "x", 4)
    t.eq(outline(root), "x0 x1 y1")
    t.eq(root.children[1].why, "loop")
    t.eq(root.children[1].need, 2)
    t.eq(root.children[2].why, "raw")

    local three = tiny({
        { out = { { "a", 1 } }, from = { { "b", 1 } } },
        { out = { { "b", 1 } }, from = { { "c", 1 } } },
        { out = { { "c", 1 } }, from = { { "a", 1 } } },
    })
    local long = tree.build(three, "a", 1)
    t.eq(outline(long), "a0 b1 c2 a3")
    t.eq(count_why(long, "loop"), 1)
    t.eq(outline(tree.build(three, "b", 1)), "b0 c1 a2 b3")
end)

t.test("loop: the same item in two branches is not a loop", function()
    local twice = tiny({
        { out = { { "top", 1 } }, from = { { "mid", 1 }, { "part", 1 } } },
        { out = { { "mid", 1 } }, from = { { "part", 2 } } },
        { out = { { "part", 1 } }, from = { { "ore", 1 } } },
    })
    local root = tree.build(twice, "top", 1)
    t.eq(outline(root), "top0 mid1 part2 ore3 part1 ore2")
    t.eq(count_why(root, "loop"), 0)
end)

local wide = tiny({
    { out = { { "r", 1 } }, from = { { "a", 1 }, { "b", 1 } } },
    { out = { { "a", 1 } }, from = { { "c", 1 }, { "d", 1 } } },
    { out = { { "b", 1 } }, from = { { "e", 1 }, { "f", 1 } } },
    { out = { { "c", 1 } }, from = { { "g", 1 } } },
})

t.test("limit: the tree never holds more nodes than the limit", function()
    t.eq(outline(tree.build(wide, "r", 1)), "r0 a1 c2 g3 d2 b1 e2 f2")
    local root = tree.build(wide, "r", 1, { limit = 7 })
    t.eq(outline(root), "r0 a1 c2 d2 b1 e2 f2", "a level at a time: the deepest part is what is cut")
    local c = root.children[1].children[1]
    t.eq(c.raw, true)
    t.eq(c.why, "limit")
    t.eq(c.recipe, 4)
    t.eq(c.options, 1)
    t.eq(root.children[1].children[2].why, "raw")
    t.eq(count_why(root, "limit"), 1)
    t.eq(listed(tree.totals(root), "need"), "c=1 d=1 e=1 f=1")
end)

t.test("limit: once something is cut, nothing after it is broken down", function()
    local root = tree.build(wide, "r", 1, { limit = 6 })
    t.eq(outline(root), "r0 a1 c2 d2 b1")
    t.eq(root.children[2].why, "limit")
    t.eq(root.children[1].children[1].why, "limit", "it would have fitted, but b was cut first")
    t.eq(root.children[1].children[2].why, "raw")
    t.eq(listed(tree.totals(root), "need"), "b=1 c=1 d=1")
    for _, limit in ipairs({ 2, 1, 0, -5 }) do
        local alone = tree.build(wide, "r", 3, { limit = limit })
        t.eq(outline(alone), "r0")
        t.eq(alone.why, "limit")
        t.eq(alone.need, 3)
    end
end)

t.test("limit: 400 nodes when nothing else is asked for", function()
    t.eq(tree.LIMIT, 400)
    local recipes = { { out = { { "root", 1 } }, from = {} } }
    for wide_at = 1, 30 do
        recipes[1].from[wide_at] = { "p" .. wide_at, 1 }
        local from = {}
        for leaf = 1, 20 do from[leaf] = { "q" .. wide_at .. "_" .. leaf, 1 } end
        recipes[#recipes + 1] = { out = { { "p" .. wide_at, 1 } }, from = from }
    end
    local big = tiny(recipes)
    local root = tree.build(big, "root", 1)
    t.eq(#tree.flatten(root), 391)
    t.eq(count_why(root, "limit"), 12)
    t.eq(#tree.flatten(tree.build(big, "root", 1, { limit = 1000 })), 631)
end)

t.test("limit: depth", function()
    local recipes = {}
    for level = 1, 20 do recipes[level] = { out = { { "c" .. level, 1 } }, from = { { "c" .. (level + 1), 1 } } } end
    local chain = tiny(recipes)
    local short = tree.build(chain, "c1", 1, { depth = 2 })
    t.eq(outline(short), "c10 c21 c32")
    t.eq(short.children[1].children[1].why, "limit")
    t.eq(tree.DEPTH, 12)
    local flat = tree.flatten(tree.build(chain, "c1", 1))
    t.eq(#flat, 13)
    t.eq(flat[13].depth, 12)
    t.eq(flat[13].why, "limit")
    t.eq(flat[12].raw, false)
    local whole = tree.flatten(tree.build(chain, "c1", 1, { depth = 50 }))
    t.eq(#whole, 21)
    t.eq(whole[21].why, "raw")
end)

t.test("totals: the same raw thing in several branches is added up", function()
    local root = tree.build(m, "stone_knife", 3)
    local totals = tree.totals(root)
    t.eq(listed(totals, "need"), "pebble=8")
    t.eq(totals[1].kind, "item")
    t.eq(totals[1].name, "Pebble")
    t.eq(totals[1].icon, "/Game/Fixture/ITEM_Pebble.ITEM_Pebble")
end)

t.test("totals: items, then tags, then resources, each by name whatever the letter case", function()
    local names = { z_ash = "ash dust", a_ore = "Ore", wood = "Any Wood", bark = "any bark", water = "Water", power = "power" }
    local mixed = tiny({
        { out = { { "top", 1 } }, from = { { "mid", 2 }, { "a_ore", 3 }, { "z_ash", 1 } }, tags = { { "wood", 1 }, { "bark", 2 } },
            res = { { "water", 10 }, { "power", 4 } } },
        { out = { { "mid", 1 } }, from = { { "a_ore", 2 } }, tags = { { "wood", 2 } }, res = { { "water", 5 } } },
    }, names)
    local root = tree.build(mixed, "top", 2)
    t.eq(outline(root), "top0 mid1 a_ore2 wood2 water2 a_ore1 z_ash1 wood1 bark1 water1 power1")
    local totals = tree.totals(root)
    t.eq(listed(totals, "need"), "z_ash=2 a_ore=14 bark=4 wood=10 power=8 water=40")
    t.eq(listed(totals, "kind"), "z_ash=item a_ore=item bark=tag wood=tag power=resource water=resource")
    t.eq(totals[2].name, "Ore")
end)

t.test("totals: a tag and an item with one key stay apart", function()
    local same = tiny({ { out = { { "top", 1 } }, from = { { "fish", 2 } }, tags = { { "fish", 3 } } } })
    local totals = tree.totals(tree.build(same, "top", 1))
    t.eq(listed(totals, "need"), "fish=2 fish=3")
    t.eq(listed(totals, "kind"), "fish=item fish=tag")
end)

local diamond = tiny({
    { out = { { "top", 1 } }, from = { { "a", 1 }, { "b", 1 } }, at = { "hand" }, mj = 10 },
    { out = { { "a", 1 } }, from = { { "c", 2 } }, mj = 20 },
    { out = { { "b", 1 } }, from = { { "a", 1 }, { "c", 1 } }, mj = 30 },
    { out = { { "c", 4 } }, from = { { "ore", 1 } }, mj = 40 },
})

t.test("steps: deepest first, the finished item last, one entry for each crafted item", function()
    local root = tree.build(diamond, "top", 1)
    t.eq(outline(root), "top0 a1 c2 ore3 b1 a2 c3 ore4 c2 ore3")
    local steps = tree.steps(root)
    t.eq(listed(steps, "crafts"), "c=3 a=2 b=1 top=1")
    t.eq(listed(steps, "need"), "c=5 a=2 b=1 top=1")
    t.eq(listed(steps, "makes"), "c=4 a=1 b=1 top=1")
    t.eq(listed(steps, "left"), "c=7 a=0 b=0 top=0", "each branch keeps its own leftovers")
    t.eq(listed(steps, "mj"), "c=120 a=40 b=30 top=10")
    t.eq(listed(steps, "recipe"), "c=4 a=2 b=3 top=1")
    t.eq(listed(steps, "station"), "c=Bench a=Bench b=Bench top=Character")
    t.eq(listed(steps, "hand"), "c=false a=false b=false top=true")
    t.eq(listed(steps, "set"), "c=bench a=bench b=bench top=hand")
    t.eq(steps[1].name, "c")
    t.eq(steps[1].icon, "/icons/c")
    t.eq(listed(tree.totals(root), "need"), "ore=3")
end)

t.test("steps: an item met high up and again deeper is crafted before what the deeper one feeds", function()
    local deep = tiny({
        { out = { { "top", 1 } }, from = { { "z", 1 }, { "v", 1 } } },
        { out = { { "v", 1 } }, from = { { "w", 1 } } },
        { out = { { "w", 1 } }, from = { { "z", 2 } } },
        { out = { { "z", 1 } }, from = { { "ore", 1 } } },
    })
    local root = tree.build(deep, "top", 1)
    t.eq(outline(root), "top0 z1 ore2 v1 w2 z3 ore4")
    t.eq(listed(tree.steps(root), "crafts"), "z=3 w=1 v=1 top=1")
end)

t.test("steps: items at one depth keep the order of the tree", function()
    local flat = tiny({
        { out = { { "top", 1 } }, from = { { "y", 1 }, { "x", 1 } } },
        { out = { { "x", 1 } }, from = { { "ore", 1 } } },
        { out = { { "y", 1 } }, from = { { "ore", 1 } } },
    })
    t.eq(listed(tree.steps(tree.build(flat, "top", 2)), "crafts"), "y=2 x=2 top=2")
end)

t.test("steps: on the fixture, with stations and work", function()
    local steps = tree.steps(tree.build(m, "press", 3))
    t.eq(listed(steps, "crafts"), "gear=6 press=3")
    t.eq(steps[1].name, "Gear")
    t.eq(steps[1].icon, "/Game/Fixture/ITEM_Gear.ITEM_Gear")
    t.eq(steps[1].recipe, m.recipe.gear)
    t.eq(steps[1].makes, 2)
    t.eq(steps[1].need, 12)
    t.eq(steps[1].station, "Work Table")
    t.eq(steps[1].hand, false)
    t.eq(steps[1].mj, 30000)
    local knife = tree.steps(tree.build(m, "stone_knife", 3))
    t.eq(listed(knife, "crafts"), "twig=2 stone_knife=3")
    t.eq(listed(knife, "hand"), "twig=true stone_knife=true")
    t.eq(listed(knife, "left"), "twig=1 stone_knife=0")
end)

t.test("flatten: the nodes themselves, in the order of an indented list", function()
    local root = tree.build(m, "stone_knife", 3)
    local flat = tree.flatten(root)
    t.eq(#flat, 4)
    t.ok(flat[1] == root, "the root itself")
    t.ok(flat[2] == root.children[1])
    t.ok(flat[3] == root.children[2])
    t.ok(flat[4] == root.children[2].children[1])
    t.eq(flat[1].depth, 0)
    t.eq(flat[2].depth, 1)
    t.eq(flat[4].depth, 2)
    t.ok(tree.flatten(root)[4] == flat[4], "asking again gives the same nodes")
end)

t.test("build: the model is left as it was", function()
    local before = { #m.made_by.pebble, #m.recipes, m.recipes[m.recipe.gear].inputs[1].count, m.items.gear.name }
    for _, item in ipairs(m.list) do
        local root = tree.build(m, item.key, 10)
        tree.totals(root)
        tree.steps(root)
    end
    t.eq(#m.made_by.pebble, before[1])
    t.eq(#m.recipes, before[2])
    t.eq(m.recipes[m.recipe.gear].inputs[1].count, before[3])
    t.eq(m.items.gear.name, before[4])
    t.eq(m.items.gear.need, nil)
    t.eq(m.items.gear.depth, nil)
end)

-- Written by scripts\recipe_check.py. Every item the browser shows is built for ten of it.
local real = "build/recipe-browser/check/tables.lua"
if exists(real) then
    local line = nil
    t.test("the game's tables: every shown item builds, and every need is a number above nothing", function()
        local game = build_model(fixture.serve(dofile(real)))
        t.ok(game.stage >= 2 and not game.off.recipes, "the recipes joined")
        local sizes, largest, cut = {}, nil, 0
        for _, item in ipairs(game.list) do
            if not item.hidden then
                local ok, root = pcall(tree.build, game, item.key, 10)
                if not ok then error(item.key .. " did not build: " .. tostring(root), 0) end
                t.ok(root, item.key .. " gives a tree")
                local flat = tree.flatten(root)
                for _, node in ipairs(flat) do
                    if type(node.need) ~= "number" or not (node.need > 0) then
                        error(item.key .. ": " .. node.key .. " needs " .. tostring(node.need), 0)
                    end
                    if node.why == "limit" then cut = cut + 1 end
                end
                for _, entry in ipairs(tree.totals(root)) do
                    if not (entry.need > 0) then error(item.key .. ": the total of " .. entry.key .. " is " .. tostring(entry.need), 0) end
                end
                local steps = tree.steps(root)
                if not root.raw and steps[#steps].key ~= item.key then error(item.key .. " is not its own last step", 0) end
                local size = { key = item.key, name = item.name, nodes = #flat }
                sizes[#sizes + 1] = size
                if not largest or size.nodes > largest.nodes then largest = size end
            end
        end
        t.ok(largest, "the list shows items")

        -- os.clock ticks in milliseconds, so the largest trees are each built many times.
        table.sort(sizes, function(a, c) return a.nodes > c.nodes end)
        local slowest, rounds = nil, 100
        for position = 1, math.min(10, #sizes) do
            local size = sizes[position]
            local started = os.clock()
            for _ = 1, rounds do tree.build(game, size.key, 10) end
            size.ms = (os.clock() - started) * 1000 / rounds
            if not slowest or size.ms > slowest.ms then slowest = size end
        end
        line = ("recipe-tree on the game's tables: %d items, slowest build %.2f ms (%s, %d nodes), largest tree %d nodes (%s), %d cut by the limit")
            :format(#sizes, slowest.ms, slowest.name, slowest.nodes, largest.nodes, largest.name, cut)
    end)
    if line then print(line) end
end

t.finish("recipe-tree")
