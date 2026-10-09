-- Offline tests for what the Recipe Browser shows and how it gets there, over the invented tables of recipe_fixture.lua:
-- rows.lua (a recipe as a view shows it, and as lines of text), load.lua (the read of the tables) and init.lua with a
-- view of the test's own in the place of view.lua.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\recipe_app_test.lua luamods\RecipeBrowser

local t = dofile("wax/tests/offline/harness.lua")

local folder = arg and arg[1]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end

local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
end

local FILES = { "mod", "init", "load", "rows", "view", "layout", "text", "source", "tags", "model", "tree", "gather", "stats",
    "unlock", "format", "search", "favourites", "history" }

if not folder or not exists(folder .. "/init.lua") or not exists(folder .. "/rows.lua") then
    print("recipe-app: 0 passed (skipped: Recipe Browser is not here)")
    os.exit(0)
end

t.test("every Lua file of the mod is there and compiles", function()
    for _, name in ipairs(FILES) do
        local chunk, problem = loadfile(folder .. "/" .. name .. ".lua", "t", {})
        t.ok(chunk, tostring(problem))
    end
end)

-- ---------------------------------------------------------------- rows.lua, on its own

-- The pure files get the standard library and nothing else, so a use of Wax or the engine fails here.
local function part(name, more)
    local env = { string = string, table = table, math = math, select = select, type = type, pairs = pairs, ipairs = ipairs,
        next = next, tostring = tostring, tonumber = tonumber, setmetatable = setmetatable, getmetatable = getmetatable,
        error = error, pcall = pcall, rawget = rawget, rawset = rawset }
    for key, value in pairs(more or {}) do env[key] = value end
    setmetatable(env, { __index = function(_, key) error(name .. ".lua reads the global '" .. tostring(key) .. "'", 2) end })
    local chunk = assert(loadfile(folder .. "/" .. name .. ".lua", "t", env))
    local value = chunk()
    assert(type(value) == "table", name .. ".lua must return a table")
    return value
end

local source, tags, model, unlock = part("source"), part("tags"), part("model"), part("unlock")
local format, search, text, rows = part("format"), part("search"), part("text"), part("rows")
rows.SHOW_TIMES = false     -- the text browser's tests were written before times were shown
local fixture = dofile("wax/tests/offline/recipe_fixture.lua")

local src = source.new(fixture.provider())
src.read_all(1)
local m = model.build(src, nil, search.lower, tags)
local needs = unlock.index(src, nil, text)
local r = rows.new({ text = text, format = format, unlock = unlock })

-- One line as text: kind, name, [count], {note}, +the pack or mission part, >the item a click goes to, the tone.
local function short(line)
    return line.kind .. " " .. line.text .. (line.value and line.value ~= "" and (" [" .. line.value .. "]") or "")
        .. (line.note and line.note ~= "" and (" {" .. line.note .. "}") or "") .. (line.more and line.more ~= "" and (" +" .. line.more) or "")
        .. (line.pick and (" >" .. line.pick) or "") .. (line.tone and (" " .. line.tone) or "")
end

local function listed(lines)
    local out = {}
    for position, line in ipairs(lines) do out[position] = short(line) end
    return out
end

local function same(got, want, what)
    for position = 1, math.max(#got, #want) do
        t.eq(got[position], want[position], (what or "line") .. " " .. position)
    end
end

local function block(name, picked, mode, options)
    local lines = {}
    r.block(lines, m, needs, assert(m.recipe[name], "the fixture has no recipe " .. name), picked and m.items[picked] or nil,
        mode or "here", options or {})
    return listed(lines), lines
end

local function lines_of(key, mode, options)
    return listed(r.lines(m, needs, assert(m.items[key], "the fixture has no item " .. key), mode, options))
end

t.test("rows: a plain recipe is a heading with its station, a line for each input with its count, and what it needs", function()
    same(block("stone_knife"), { "heading Stone Knife {By hand} >fieldguide_character", "input Pebble [2] >pebble", "input Twig [1] >twig",
        "needs Tier 1 - Stone Knife - known from the start" })
    local _, lines = block("stone_knife")
    t.eq(lines[1].recipe, m.recipe.stone_knife, "every line knows its recipe")
    t.eq(lines[2].indent, 1, "what goes in is set in under the heading")
    t.eq(lines[4].faint, true, "the needs line is faint")
end)

t.test("rows: more than one made shows as x5, several stations are counted by name, and a heading goes to the first bench", function()
    same(block("gear"), { "heading Gear [x2] {3 stations} >work_table", "input Pebble [4] >pebble", "needs Tier 3 - Gear - level 20" })
    same(block("seed_mash"), { "heading Mash {2 stations} >press", "input Seed [3] >seed", "needs Tier 1" })
    same(block("nails"), { "heading Nails [x10] {Work Table} >work_table", "input Pebble [1] >pebble", "needs Tier 2 - Nails - level 10" })
    -- two sets with one name are one station, and a set nothing provides is none
    t.eq(block("banner_north")[1], "heading North Banner {Loom} >loom")
    same(block("banner_south"), { "heading South Banner", "input Cloth [2] >cloth", "needs cannot be made" })
    -- a station only a hidden item provides is named but leads nowhere
    same(block("trade_ruby"), { "heading Coin [x5] {Trader}", "input Ruby [1] >ruby" })
end)

t.test("rows: an input by tag reads 'any', a resource shows its amount in litres and leads to its guide entry", function()
    same(block("baked_fish"), { "heading Baked Fish {Hearth} >hearth", "input any Fish [2]", "needs Tier 1" })
    same(block("dough"), { "heading Dough {Work Table} >work_table", "input Flour [2] >flour", "input Water [0.1 L] >fieldguide_water" })
    same(block("pump_water"), { "heading Water [0.5 L] {Work Table} >work_table", "input Bucket [1] >bucket" })
end)

t.test("rows: several outputs get a line each with a plus, and a random recipe says 'one of' first", function()
    same(block("butcher_trout"), { "heading Fish Meat {By hand} >fieldguide_character", "input River Trout [1] >river_trout",
        "output Fish Meat [+2] >fish_meat good", "output Fish Bone [+1] >fish_bone good" })
    same(block("crack_geode"), { "heading Pebble {Work Table} >work_table", "input Geode [1] >geode", "label one of",
        "output Pebble [+1] >pebble good", "output Ruby [+1] >ruby good", "output Opal [+1] >opal good" })
    -- under "How to make it" the heading is the picked item, not the first thing the recipe makes
    t.eq(block("crack_geode", "ruby", "make")[1], "heading Ruby {Work Table} >work_table")
    t.eq(block("butcher_trout", "fish_bone", "make")[1], "heading Fish Bone {By hand} >fieldguide_character")
    t.eq(block("butcher_trout", "fish_bone", "used")[1], "heading Fish Meat {By hand} >fieldguide_character")
end)

t.test("rows: a seed kind, a flag and a drink are headed by their own names", function()
    same(block("oat_seeds"), { "heading Oat Seed [x2] {By hand} >fieldguide_character", "input Oat [1] >oat" })
    t.eq(block("oat_seeds", "seed", "make")[1], "heading Oat Seed [x2] {By hand} >fieldguide_character", "the plain seed lists its kinds")
    same(block("mint_tea"), { "heading Mint Tea {Hearth} >hearth", "input Mint [1] >mint", "input Water [0.25 L] >fieldguide_water",
        "needs Tier 1" })
    same(lines_of("drink_mint_tea", "make"), block("mint_tea"), "the drink is found by its own name")
    t.eq(lines_of("banner:north", "make")[1], "heading North Banner {Loom} >loom")
end)

t.test("rows: the needs line names a pack once, a mission, a talent, and says when a recipe cannot be made", function()
    t.eq(block("rug")[3], "needs Tier 2 - level 10 +needs Harvest Decor Pack")
    t.eq(block("bone_saw")[3], "needs Tier 2 - Bone Saw - level 10 +needs DEEP DIVE finished")
    t.eq(block("bulk_nails")[3], "needs Tier 2 - Nails - level 10 +needs talent Nail Saver")
    t.eq(block("signal_fire")[3], "needs  +only during a mission")
    t.eq(block("old_charm")[3], "needs cannot be made in this version of the game")
    t.eq(block("brick")[3], "needs cannot be made")
    t.eq(#block("plum_juice"), 2, "a recipe that needs nothing has no needs line")
    -- before the third load stage there is no index, and so no needs line yet
    local lines = {}
    r.block(lines, m, nil, m.recipe.gear, nil, "here", {})
    same(listed(lines), { "heading Gear [x2] {3 stations} >work_table", "input Pebble [4] >pebble" })
end)

t.test("rows: the three modes, their counts, and the mode an item starts in", function()
    local pebble = m.items.pebble
    local counts = r.counts(m, pebble)
    t.eq(counts.make, 2)
    t.eq(counts.used, 7, "a recipe that only makes hidden things is left out")
    t.eq(counts.here, 0)
    t.eq(r.counts(m, pebble, true).used, 8, "and is listed when the hidden items are")
    t.eq(#r.recipes(m, m.items.work_table, "here"), 14)
    t.eq(#r.recipes(m, m.items.fieldguide_character, "here"), 7, "by hand is a station like any other")
    t.eq(r.first_mode(m, pebble), "make")
    t.eq(r.first_mode(m, m.items.bucket), "used", "nothing makes a bucket, so it starts at what it is used in")
    t.eq(r.first_mode(m, m.items.work_table), "here")
    t.eq(r.first_mode(m, m.items.steel_knife), "make", "it is sold, which is a way to get it")
    t.eq(r.first_mode(m, m.items.odd_spoon), "make")
    same(lines_of("fieldguide_water", "used"), { "heading Dough {Work Table} >work_table", "input Flour [2] >flour",
        "input Water [0.1 L] >fieldguide_water", "heading Mint Tea {Hearth} >hearth", "input Mint [1] >mint",
        "input Water [0.25 L] >fieldguide_water", "needs Tier 1" }, "a resource's entry lists what uses the resource")
    t.eq(lines_of("ore_crust", "used")[1], "heading Pebble [x2] {Work Table} >work_table", "the uses of the hidden items it stands for")
end)

t.test("rows: where it comes from is listed first, and each empty list says what is empty", function()
    local pebble = lines_of("pebble", "make")
    same({ pebble[1], pebble[2], pebble[3], pebble[4] }, { "heading Where it comes from", "source Pick up", "source Break rocks",
        "heading Pebble {Work Table} >work_table" })
    same(lines_of("steel_knife", "make"), { "heading Where it comes from", "source Bought in the Workshop" })
    same(lines_of("odd_spoon", "make"), { "message " .. text.right.no_recipe })
    same(lines_of("odd_spoon", "used"), { "message " .. text.right.no_use })
    same(lines_of("odd_spoon", "here"), { "message " .. text.right.nothing_here })
    same(lines_of("pebble", "make", { numbers = {}, filtered = "zz" }), { "message " .. text.no_match("zz") })
    t.eq(r.nothing("make"), text.right.no_recipe)
end)

t.test("rows: internal names and times are there when asked for, and times are off until they have been checked", function()
    t.eq(block("stone_knife", nil, "here", { internal = true })[4], "row Stone_Knife")
    rows.SHOW_TIMES = true
    local ok, problem = pcall(function()
        t.eq(block("stone_knife")[1], "heading Stone Knife {By hand - 2.5 s} >fieldguide_character")
        t.eq(block("bulk_nails")[1], "heading Nails [x100] {Lathe - 1 s} >lathe")
        t.eq(block("gear")[1], "heading Gear [x2] {3 stations} >work_table", "benches that differ give no one figure")
        t.eq(block("baked_fish")[1], "heading Baked Fish {Hearth} >hearth", "nor do two benches of one set at different speeds")
        t.eq(block("trade_ruby")[1], "heading Coin [x5] {Trader}", "a trade takes no time")
    end)
    rows.SHOW_TIMES = false
    if not ok then error(problem, 0) end
end)

t.test("rows: nothing is listed before the recipes have been joined", function()
    local early = source.new(fixture.provider())
    early.read(1, 1)
    local b = model.begin(early, search.lower, tags)
    model.items(b)
    t.eq(b.model.stage, 1)
    t.eq(r.ready(b.model), false)
    t.eq(#r.recipes(b.model, b.model.items.pebble, "used"), 0)
    t.eq(#r.lines(b.model, nil, b.model.items.pebble, "make"), 0)
    t.eq(r.first_mode(b.model, b.model.items.work_table), "make")
    t.eq(r.ready(m), true)
end)

t.test("rows: a text is measured, shortened with dots and wrapped between words, also in another alphabet", function()
    t.ok(rows.measure("Wood") < rows.measure("Refined Wood"))
    t.ok(math.abs(rows.measure("These are remembered the next time you play.") - 314) < 12, "close to what the game draws")
    t.eq(rows.measure("Wood", 22), rows.measure("Wood") * 2)
    t.eq(rows.shorten("Wood", 200), "Wood")
    local cut = rows.shorten("Cryogenically Frozen Tortoise Shell Ragdoll Cat", 200)
    t.ok(cut:sub(-3) == "..." and #cut < 47, cut)
    t.ok(rows.measure(cut) * rows.SAFETY <= 200, "what is left fits")
    t.ok(not cut:find(" %.%.%.$"), "no space before the dots: " .. cut)
    local pieces = rows.wrap("No recipe makes this. Drops, mining, farming and fishing are not listed yet.", 220)
    t.ok(#pieces >= 3, "wrapped into " .. #pieces)
    t.eq(table.concat(pieces, " "), "No recipe makes this. Drops, mining, farming and fishing are not listed yet.")
    for _, piece in ipairs(pieces) do t.ok(rows.measure(piece) * rows.SAFETY <= 220, piece) end
    local russian = "\208\148\208\181\209\128\208\181\208\178\208\190 \208\184 \208\186\208\176\208\188\208\181\208\189\209\140"
    for _, piece in ipairs(rows.wrap(russian, 40)) do t.ok(utf8.len(piece), "no letter is cut in half") end
    t.ok(utf8.len(rows.shorten(russian, 60)), "nor by the dots")
    t.eq(#rows.wrap("Supercalifragilisticexpialidocious", 60) > 1, true, "a word too long for a line is broken")
end)

local PAD, INDENT, GAPS = 26, 12, 18

-- Every row keeps inside a list that is `width` wide: the name in its box, and box, count and note in the row.
local function inside(row, width, what)
    local room = width - PAD - (row.indent or 0) * INDENT
    local value_px = row.value ~= "" and #row.value * 8 or 0
    local note_px = row.note ~= "" and rows.measure(row.note, 10) * rows.SAFETY or 0
    t.ok(rows.measure(row.text) * rows.SAFETY <= row.name_width + 1, what .. ": the name '" .. row.text .. "' is wider than its box")
    t.ok(row.name_width + GAPS + value_px + note_px <= room + 1, what .. ": '" .. row.text .. "' is wider than the list")
end

t.test("rows: laid out for a width, counts start at one place and what does not fit goes on to the next row", function()
    local _, lines = block("gear")
    local wide = r.flow({}, lines, 409)
    t.eq(#wide, 3)
    t.eq(wide[1].name_width, 229, "the heading's x2 starts in the column of the counts")
    t.eq(wide[2].name_width + wide[2].indent * INDENT, 229, "and so does the count of a line that is set in")
    t.eq(wide[1].note, "3 stations")
    t.eq(wide[2].pick, "pebble")
    -- too narrow for name and station side by side: the station goes under the name, faint, and still leads to the bench
    local _, long = block("timber_wall")
    long[1].text, long[1].note = "Reinforced Timber Wall With A Window", "Advanced Alteration Bench"
    local narrow = r.flow({}, long, 280)
    t.eq(narrow[1].text, "Reinforced Timber Wall With A")
    t.eq(narrow[2].text, "Window")
    t.eq(narrow[3].text, "Advanced Alteration Bench")
    t.eq(narrow[3].faint, true)
    t.eq(narrow[3].pick, "work_table")
    t.eq(narrow[3].note, "")
    -- the needs line breaks where its parts join
    local _, saw = block("bone_saw")
    t.eq(r.flow({}, saw, 480)[3].text, "Tier 2 - Bone Saw - level 10 - needs DEEP DIVE finished")
    local split = r.flow({}, saw, 280)
    t.eq(split[3].text, "Tier 2 - Bone Saw - level 10")
    t.eq(split[4].text, "needs DEEP DIVE finished")
    t.eq(split[4].faint, true)
    local _, fire = block("signal_fire")
    t.eq(r.flow({}, fire, 409)[3].text, "only during a mission")
    -- only the rows from a line onwards, for a list that is laid out a part at a time
    local out = r.flow({}, lines, 409, 3)
    t.eq(#out, 1)
    t.eq(out[1].text, "Tier 3 - Gear - level 20")
end)

t.test("rows: at every width no row of any recipe is wider than the list", function()
    for _, width in ipairs({ 230, 280, 349, 409, 478, 800 }) do
        for number, recipe in ipairs(m.recipes) do
            local lines = {}
            r.block(lines, m, needs, number, nil, "here", { internal = true })
            for _, row in ipairs(r.flow({}, lines, width)) do inside(row, width, recipe.id .. " at " .. width) end
        end
        for _, row in ipairs(r.notice({}, text.problem.changed("TagQueries", "FieldGuide_Hide"), width)) do
            inside(row, width, "a notice at " .. width)
            t.eq(row.faint, true)
        end
    end
end)

t.test("rows: a line of the item list keeps its category when both fit, then drops it, then shortens the name", function()
    local name, note, box = r.entry("Wood", "Resources", 400)
    t.eq(name, "Wood")
    t.eq(note, "Resources")
    t.ok(box + rows.measure("Resources", 10) <= 400 - PAD - GAPS)
    name, note, box = r.entry("Advanced Supplemental Respiration Attachment", "Attachments", 400)
    t.eq(name, "Advanced Supplemental Respiration Attachment")
    t.eq(note, "", "the name is worth more than the category")
    t.eq(box, 400 - PAD - GAPS)
    name, note = r.entry("Advanced Supplemental Respiration Attachment", "Attachments", 280)
    t.ok(name:sub(-3) == "..." and note == "", name)
    t.ok(rows.measure(name) * rows.SAFETY <= 280 - PAD - GAPS)
end)

t.test("rows: the small lines fit on one line: about the item, the counts of the modes, how many items match", function()
    local pebble = m.items.pebble
    t.eq(r.about(m, pebble, {}, 400, 10), "stacks to 100 - 300 g")
    t.eq(r.about(m, pebble, { internal = true, favourite = true }, 400, 10), "Pebble - stacks to 100 - 300 g - In favourites")
    t.eq(r.about(m, pebble, { internal = true, favourite = true }, 150, 10), "Pebble - stacks to 100", "what does not fit is left off the end")
    t.eq(r.about(m, m.items.lathe, {}, 400, 10), "20 kg - Far Lands Expansion")
    t.eq(r.about(m, m.items.fieldguide_character, {}, 400, 10), "")
    local counts = r.counts(m, pebble)
    t.eq(r.modes(counts, "make", 400, 10), "How to make it (2) - Used in (7) - Made here (0)")
    t.eq(r.modes(counts, "make", 250, 10), "How to make it (2) - Used in (7)")
    t.eq(r.modes(counts, "used", 110, 10), "Used in (7)")
    t.eq(r.count(42, 2668, "", 300, 10), "42 of 2,668 items")
    t.eq(r.count(0, 2668, "xyz", 300, 10), 'Nothing matches "xyz".')
    local long = r.count(0, 2668, "a very long thing somebody typed into the search box", 300, 10)
    t.ok(long:find('%.%.%."%.$') and rows.measure(long, 10) * rows.SAFETY <= 300, long)
end)

-- ---------------------------------------------------------------- rows.lua: one recipe as a view shows it

t.test("recipe: what heads it, each thing that goes in with its picture and count, where it is made and what it needs", function()
    local card = r.recipe(m, needs, m.recipe.stone_knife)
    t.eq(card.name, "Stone Knife")
    t.eq(card.item, "stone_knife")
    t.eq(card.icon, "/Game/Fixture/ITEM_Stone_Knife.ITEM_Stone_Knife")
    t.eq(card.made, "")
    t.eq(card.several, false)
    t.eq(card.random, false)
    t.eq(card.row, "Stone_Knife")
    t.eq(card.number, m.recipe.stone_knife)
    t.eq(card.mj, 2500)
    t.eq(#card.inputs, 2)
    local pebble = card.inputs[1]
    t.eq(pebble.kind, "item")
    t.eq(pebble.name, "Pebble")
    t.eq(pebble.item, "pebble")
    t.eq(pebble.count, 2)
    t.eq(pebble.amount, "2")
    t.eq(pebble.icon, "/Game/Fixture/ITEM_Pebble.ITEM_Pebble")
    t.eq(#card.outputs, 1)
    t.eq(card.outputs[1].item, "stone_knife")
    t.eq(card.outputs[1].amount, "1")
    t.eq(card.station, "By hand")
    t.eq(card.bench, "fieldguide_character")
    t.eq(#card.stations, 1)
    local hand = card.stations[1]
    t.eq(hand.hand, true)
    t.eq(hand.name, "By hand")
    t.eq(hand.id, "character")
    t.eq(hand.item, "fieldguide_character")
    t.eq(hand.icon, "/Game/Fixture/SET_Hand.SET_Hand")
    t.eq(hand.benches[1].name .. ", " .. hand.benches[2].name, "Field Kit, Character Crafting")
    t.eq(hand.benches[1].item, "field_kit")
    t.eq(card.needs.short, "Tier 1 - Stone Knife - known from the start")
    t.eq(card.needs.tone, "dim")
    t.eq(card.time, "")
    t.eq(card.level, nil)
    t.eq(r.recipe(m, needs, 9999), nil, "a number no recipe has")
    t.eq(r.recipe(m, nil, m.recipe.stone_knife).needs, nil, "no needs before the third load stage")
end)

t.test("recipe: an input by tag, a resource, a resource as the thing made, several outputs, a random one, a drink", function()
    local fish = r.recipe(m, needs, m.recipe.baked_fish).inputs[1]
    t.eq(fish.kind, "tag")
    t.eq(fish.name, "Fish")
    t.eq(fish.tag, "any_fish")
    t.eq(fish.item, nil)
    t.eq(fish.amount, "2")
    t.eq(fish.icon, "/Game/Fixture/QUERY_Fish.QUERY_Fish")
    t.eq(table.concat(m.tag_items[fish.tag], " "), "river_trout sea_bass", "the items the tag stands for are in the model")
    local water = r.recipe(m, needs, m.recipe.dough).inputs[2]
    t.eq(water.kind, "resource")
    t.eq(water.name, "Water")
    t.eq(water.resource, "water")
    t.eq(water.amount, "0.1 L")
    t.eq(water.count, 100)
    t.eq(water.item, "fieldguide_water", "its entry in the game's guide")
    t.eq(water.icon, "/Game/Fixture/RES_Water.RES_Water")
    local pump = r.recipe(m, needs, m.recipe.pump_water)
    t.eq(pump.name, "Water")
    t.eq(pump.made, "0.5 L")
    t.eq(pump.item, "fieldguide_water")
    t.eq(pump.outputs[1].kind, "resource")
    t.eq(pump.several, false)
    local trout = r.recipe(m, needs, m.recipe.butcher_trout)
    t.eq(trout.several, true)
    t.eq(trout.random, false)
    t.eq(trout.made, "")
    t.eq(trout.name, "Fish Meat")
    t.eq(trout.outputs[1].amount .. " " .. trout.outputs[2].amount, "2 1")
    local bone = r.recipe(m, needs, m.recipe.butcher_trout, m.items.fish_bone, "make")
    t.eq(bone.name, "Fish Bone", "under How to make it, headed by the picked item")
    t.eq(bone.item, "fish_bone")
    t.eq(r.recipe(m, needs, m.recipe.butcher_trout, m.items.fish_bone, "used").name, "Fish Meat")
    local geode = r.recipe(m, needs, m.recipe.crack_geode)
    t.eq(geode.random, true)
    t.eq(#geode.outputs, 3)
    local tea = r.recipe(m, needs, m.recipe.mint_tea)
    t.eq(tea.name, "Mint Tea")
    t.eq(tea.item, "drink_mint_tea")
    t.eq(tea.icon, "/Game/Fixture/ITEM_Drink_Mint_Tea.ITEM_Drink_Mint_Tea")
    t.eq(tea.outputs[1].item, "cup", "what is really made is the cup")
    local gear = r.recipe(m, needs, m.recipe.gear)
    t.eq(gear.made, "x2")
    t.eq(gear.level, "Far Lands Expansion")
    t.eq(r.recipe(m, needs, m.recipe.oat_seeds).item, "seed:oat")
end)

t.test("recipe: its stations, one for each name, with the benches that show and, once switched on, the time at each", function()
    local function names(list)
        local out = {}
        for position, entry in ipairs(list) do out[position] = entry.name .. (entry.time ~= nil and entry.time ~= "" and (" " .. entry.time) or "") end
        return table.concat(out, ", ")
    end
    local gear = r.recipe(m, needs, m.recipe.gear)
    t.eq(gear.station, "3 stations")
    t.eq(names(gear.stations), "Work Table, Lathe, Press")
    t.eq(gear.bench, "work_table")
    t.eq(gear.stations[2].item, "lathe")
    local mash = r.recipe(m, needs, m.recipe.seed_mash)
    t.eq(names(mash.stations), "Press, Hearth")
    t.eq(names(mash.stations[2].benches), "Big Hearth, Hearth", "the bench the game's guide hides is left out")
    local south = r.recipe(m, needs, m.recipe.banner_south)
    t.eq(#south.stations, 0)
    t.eq(south.station, "")
    t.eq(south.bench, nil)
    t.eq(south.needs.short, "cannot be made")
    t.eq(south.needs.tone, "bad")
    local trade = r.recipe(m, needs, m.recipe.trade_ruby)
    t.eq(trade.station, "Trader")
    t.eq(trade.stations[1].item, nil, "a station only a hidden item provides leads nowhere")
    t.eq(names(trade.stations[1].benches), "Trader Hollis")
    t.eq(names(r.recipe(m, needs, m.recipe.rug).stations), "Loom")
    t.eq(r.recipe(m, needs, m.recipe.rug).needs.extra, "needs Harvest Decor Pack")
    rows.SHOW_TIMES = true
    local ok, problem = pcall(function()
        local timed = r.recipe(m, needs, m.recipe.seed_mash)
        t.eq(names(timed.stations[1].benches), "Press 1 s")
        t.eq(names(timed.stations[2].benches), "Big Hearth 5 s, Hearth 10 s")
        t.eq(timed.time, "", "no one figure when benches differ")
        t.eq(r.recipe(m, needs, m.recipe.stone_knife).time, "2.5 s")
        t.eq(r.recipe(m, needs, m.recipe.trade_ruby).time, "")
    end)
    rows.SHOW_TIMES = false
    if not ok then error(problem, 0) end
end)

t.test("recipe: two sets the game calls the same are one station, with the benches of both", function()
    local twin = fixture.copy()
    local function add(name, row) twin[name].rows[#twin[name].rows + 1] = row end
    add("ItemsStatic", { Name = "Loom_Two", Itemable = { RowName = "Item_Loom_Two" }, Processing = { RowName = "Loom_Two" },
        Manual_Tags = { GameplayTags = { { TagName = "Trait.Bench" } } }, Generated_Tags = { GameplayTags = {} } })
    add("Itemable", { Name = "Item_Loom_Two", DisplayName = "Second Loom", Icon = "/Game/Fixture/ITEM_Loom_Two.ITEM_Loom_Two",
        Weight = 1, MaxStack = 1 })
    add("Processing", { Name = "Loom_Two", DefaultRecipeSet = { RowName = "Loom_B" } })
    add("ProcessorRecipes", { Name = "Both_Looms", Inputs = { { Element = { RowName = "Cloth" }, Count = 1 } },
        Outputs = { { Element = { RowName = "Rug" }, Count = 1 } }, RecipeSets = { { RowName = "Loom_A" }, { RowName = "Loom_B" } } })
    local twin_source = source.new(fixture.serve(twin))
    twin_source.read_all(1)
    local built = model.build(twin_source, nil, search.lower, tags)
    local card = r.recipe(built, nil, built.recipe.both_looms)
    t.eq(#card.stations, 1)
    t.eq(card.station, "Loom")
    t.eq(card.stations[1].benches[1].name .. ", " .. card.stations[1].benches[2].name, "Loom, Second Loom")
    t.eq(card.bench, "loom")
    local lines = {}
    r.block(lines, built, nil, built.recipe.both_looms, nil, "here", {})
    t.eq(short(lines[1]), "heading Rug {Loom} >loom", "and the text form names it once")
end)

-- ---------------------------------------------------------------- the scheduler, and game.Data over the fixture

local fake = dofile("wax/tests/offline/fake_engine.lua")
fake.install()
fake.scroll_end = 0             -- nothing is scrolled: a list shows as many rows as its height holds

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local log = Wax.import("core.log")
local sched = Wax.import("core.sched")
Wax.log, Wax.guard, Wax.sched = log, guard, sched

local now = 0
sched.clock = function() return now end
local function ticks(count)
    for _ = 1, count or 1 do
        now = now + 1 / 60
        sched.step()
    end
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, inner in pairs(value) do out[key] = copy(inner) end
    return out
end

-- game.Data over the fixture's tables. Load only works in a task and pauses once, as the real one pauses when its time
-- for the frame is used up. What was asked of it is counted.
local function new_data(served)
    local world = { tables = served or fixture.copy(), changed = sched.Signal.new("Data.Changed"),
        stats = { loads = 0, outside = 0, flushes = 0, read_frame = -1, budgets = {} } }
    world.provider = fixture.serve(world.tables)
    local stats = world.stats
    local function wrap(object)
        return setmetatable({}, { __index = function(_, key)
            if key == "Load" then
                return function(_, request)
                    if not coroutine.isyieldable() then
                        stats.outside = stats.outside + 1
                        error("Load can only be used inside a task", 2)
                    end
                    stats.loads = stats.loads + 1
                    stats.budgets[#stats.budgets + 1] = request and request.budget or -1
                    sched.task.wait()
                    stats.read_frame = sched.stats.frame
                    return object:Load(request)
                end
            elseif key == "Meta" then
                return function()
                    local meta = object:Meta()
                    return meta and wrap(meta) or nil
                end
            end
            local value = object[key]
            if type(value) ~= "function" then return value end
            return function(_, ...) return value(object, ...) end
        end })
    end
    local api = { Changed = world.changed }
    function api:Table(name) return wrap(world.provider:Table(name)) end
    function api:Has(name) return world.provider:Has(name) end
    function api:GetTables() return world.provider:GetTables() end
    function api:Flush()
        stats.flushes = stats.flushes + 1
        world.provider:Flush()
        sched.task.defer(function() world.changed:Fire() end)
    end
    world.api = api
    function world.serve(changed_tables)
        world.tables = changed_tables
        world.provider = fixture.serve(changed_tables)
    end
    return world
end

local function without(table_name, row_name)
    local changed = fixture.copy()
    for position, row in ipairs(changed[table_name].rows) do
        if row.Name == row_name then
            table.remove(changed[table_name].rows, position)
            break
        end
    end
    return changed
end

local function without_field(table_name, field)
    local changed = fixture.copy()
    changed[table_name].defaults[field] = nil
    for _, row in ipairs(changed[table_name].rows) do row[field] = nil end
    return changed
end

-- ---------------------------------------------------------------- load.lua, with the scheduler and nothing else of Wax

local loading = part("load", { os = os, debug = debug, xpcall = xpcall })

-- A read over its own game.Data. `told` is what the view was told: the stage and whether a read is under way, each time.
local function new_job(options)
    options = options or {}
    local world = options.world or new_data(options.tables)
    local told, on, job = {}, { showing = options.showing == true }, nil
    job = loading.new({ data = world.api, source = source, model = options.model or model, tags = tags, search = search,
        unlock = unlock, text = options.text or text, task = sched.task, kept = options.kept or {},
        showing = function() return on.showing end,
        changed = function() told[#told + 1] = { stage = job and job.stage() or 0, reading = job ~= nil and job.reading } end })
    return job, world, told, on
end

local function until_read(job)
    for _ = 1, 5000 do
        if not job.reading then return ticks(2) end
        ticks(1)
    end
    error("the read did not end", 2)
end

t.test("load: nothing is read until it is wanted, and wanting it twice is one read", function()
    local job, world, told = new_job()
    ticks(5)
    t.eq(job.reading, false)
    t.eq(job.model, nil)
    t.eq(job.stage(), 0)
    t.eq(job.progress(), 0)
    t.eq(#job.problems(), 0)
    t.eq(world.provider.calls, 0, "game.Data was not asked anything")
    t.eq(#told, 0)
    job.want()
    t.eq(job.reading, true)
    t.eq(job.runs, 1)
    job.want()
    t.eq(job.runs, 1, "a read is under way")
    until_read(job)
    job.want()
    t.eq(job.runs, 1, "and with a model there is nothing left to want")
    t.eq(job.stage(), 3)
    t.eq(job.progress(), 1)
    t.eq(job.count(), 51)
end)

t.test("load: three stages, each told to the view as it ends, and reading never shares a frame with joining", function()
    local world, joined_while_reading = new_data(), 0
    local watched = setmetatable({}, { __index = model })
    for _, stage in ipairs({ "items", "recipes", "levels" }) do
        watched[stage] = function(...)
            if world.stats.read_frame == sched.stats.frame then joined_while_reading = joined_while_reading + 1 end
            return model[stage](...)
        end
    end
    local job, _, told = new_job({ world = world, model = watched })
    job.want()
    t.eq(#told, 1, "the view is told at once that a read began")
    t.eq(told[1].reading, true)
    local last, between, steps = -1, false, 0
    t.ok(job.progress() < 0.2, "a read that has only begun")
    for _ = 1, 5000 do
        if not job.reading then break end
        local progress = job.progress()
        t.ok(progress >= last and progress < 1, "progress only goes up: " .. progress)
        if progress > last then steps = steps + 1 end
        last = progress
        -- with the items joined and the recipes still to come, the list can already be filled and searched
        if job.stage() == 1 and not between then
            between = true
            t.eq(job.model.counts.shown > 40, true)
            t.eq(#job.find.filter(job.model.list, "knife", {}), 2)
            t.eq(job.needs, nil)
            t.eq(job.count(), job.model.counts.shown)
        end
        ticks(1)
    end
    ticks(2)
    t.ok(between, "the first stage was there on its own for a while")
    t.ok(steps >= 5 and last > 0.8, "progress went up a step at a time: " .. steps .. " steps to " .. last)
    local stages = {}
    for position, entry in ipairs(told) do stages[position] = entry.stage .. (entry.reading and " reading" or "") end
    t.eq(table.concat(stages, ", "), "0 reading, 1 reading, 2 reading, 3")
    t.eq(joined_while_reading, 0)
    t.eq(world.stats.outside, 0, "Load was only ever called in a task")
    t.ok(world.stats.loads > 20, "every table was read: " .. world.stats.loads)
    t.eq(job.model.stage, 3)
    t.ok(job.needs ~= nil and job.needs.off == false, "the needs index came with the third stage")
    t.eq(r.recipe(job.model, job.needs, job.model.recipe.gear).needs.short, "Tier 3 - Gear - level 20")
    t.eq(job.progress(), 1)
    t.ok(job.seconds >= 0)
    t.eq(job.failed, false)
end)

t.test("load: a frame's share for reading is 1 ms with the browser closed and 4 ms while it shows, and the join follows", function()
    local function run(showing)
        local job, world = new_job({ showing = showing })
        local started = sched.stats.frame
        job.want()
        until_read(job)
        return world.stats.budgets, sched.stats.frame - started
    end
    for _, budget in ipairs((run(false))) do t.eq(budget, 1) end
    for _, budget in ipairs((run(true))) do t.eq(budget, 4) end
    -- a pause after every row: the join then takes many frames, and a quarter of them while the browser shows
    local rows_before, needs_before = model.PAUSE_ROWS, unlock.PAUSE_ROWS
    model.PAUSE_ROWS, unlock.PAUSE_ROWS = 1, 1
    local ok, problem = pcall(function()
        local _, closed = run(false)
        local _, showing = run(true)
        t.ok(closed > 200, "the join paused: " .. closed .. " frames")
        t.ok(showing * 2 < closed, "showing: " .. showing .. " frames, closed: " .. closed)
    end)
    model.PAUSE_ROWS, unlock.PAUSE_ROWS = rows_before, needs_before
    if not ok then error(problem, 0) end
end)

t.test("load: the model is kept with its version and the stamps of its tables, and used again only while both hold", function()
    local kept = {}
    local job, world = new_job({ kept = kept })
    job.want()
    until_read(job)
    t.eq(kept.version, model.version)
    t.eq(kept.model, job.model)
    t.eq(kept.needs, job.needs)
    t.ok(type(kept.stamp) == "string" and #kept.stamp > 20)
    t.eq(kept.wanted, true)
    -- as after a reload of the mod: the same kept table, a new job
    local loads = world.stats.loads
    local again = new_job({ kept = kept, world = world })
    t.eq(again.model, job.model)
    t.eq(again.needs, job.needs)
    t.eq(again.reading, false)
    t.eq(again.stage(), 3)
    t.eq(#again.find.filter(again.model.list, "knife", {}), 2, "with a search index of its own")
    t.eq(world.stats.loads, loads, "nothing was read")
    -- the reloaded mod has a text table of its own: the kept needs lines are worded with it
    local reworded = setmetatable({ needs = setmetatable({ known = "KNOWN" }, { __index = text.needs }) }, { __index = text })
    local other = new_job({ kept = kept, world = world, text = reworded })
    t.eq(unlock.describe(other.needs, other.model, other.model.recipes[other.model.recipe.stone_knife]).short, "Tier 1 - Stone Knife - KNOWN")
    unlock.rebind(kept.needs, text)
    kept.version = kept.version + 1
    local newer = new_job({ kept = kept, world = world })
    t.eq(newer.reading, true, "another version of the model's shape: read again at once")
    until_read(newer)
    t.ok(newer.model ~= job.model)
    t.eq(kept.version, model.version)
    world.tables.Itemable.stamp = "0x2"
    local renewed = new_job({ kept = kept, world = world })
    t.eq(renewed.reading, true, "the game made a table again")
    until_read(renewed)
    t.eq(new_job({ kept = kept, world = world }).reading, false)
    -- a read that was under way when the mod reloaded is taken up again
    local half = {}
    local first = new_job({ kept = half })
    first.want()
    ticks(4)
    first.stop()
    t.eq(first.reading, false)
    t.eq(half.wanted, true)
    t.eq(half.model, nil)
    local second = new_job({ kept = half })
    t.eq(second.reading, true)
    until_read(second)
    t.eq(second.stage(), 3)
end)

t.test("load: a change of the game's data reads again, for the tables the mod reads and once something was read", function()
    local job = new_job()
    job.data_changed(nil)
    t.eq(job.runs, 0, "nothing was read yet")
    job.want()
    until_read(job)
    local before = job.model
    job.data_changed("Weather")
    t.eq(job.runs, 1, "not one of its tables")
    job.data_changed("D_ProcessorRecipes")
    t.eq(job.runs, 2)
    t.eq(job.reading, true)
    t.eq(job.model, before, "what was read stays until the new model is there")
    t.eq(job.stage(), 3)
    until_read(job)
    t.ok(job.model ~= before)
    job.data_changed("ItemsStatic_METATABLE")
    t.eq(job.runs, 3)
    until_read(job)
    job.data_changed(nil)
    t.eq(job.runs, 4, "everything was dropped")
    until_read(job)
    job.again()
    t.eq(job.runs, 5)
    until_read(job)
end)

t.test("load: a newer read stops the one under way, which joins and tells nothing more", function()
    local joins = 0
    local counted = setmetatable({ items = function(...)
        joins = joins + 1
        return model.items(...)
    end }, { __index = model })
    local job, _, told = new_job({ model = counted })
    job.want()
    ticks(2)
    t.eq(job.reading, true)
    t.eq(joins, 0, "the first read is still reading its first tables")
    job.again()
    until_read(job)
    t.eq(joins, 1, "only the second read got as far as joining")
    t.eq(#told, 5, "two starts, then the three stages of the second read")
    t.eq(told[#told].stage, 3)
    t.eq(told[#told].reading, false)
    t.eq(job.runs, 2)
    -- stopped later, between two stages: again nothing more comes of the first read
    local late, _, heard = new_job()
    late.want()
    for _ = 1, 5000 do
        if late.stage() >= 1 then break end
        ticks(1)
    end
    local so_far = #heard
    late.again()
    until_read(late)
    t.eq(#heard - so_far, 4, "a start and three stages, all of the second read")
end)

t.test("load: a row or a field the game no longer has is named, and what can still be read is", function()
    local kept = {}
    local hidden, world = new_job({ tables = without("TagQueries", "FieldGuide_Hide"), kept = kept })
    hidden.want()
    until_read(hidden)
    t.eq(hidden.stage(), 0, "no rule for what the guide hides, so no list")
    t.eq(hidden.problems()[1].table, "TagQueries")
    t.eq(hidden.problems()[1].row, "FieldGuide_Hide")
    t.eq(hidden.failed, false)
    t.eq(kept.model, hidden.model, "kept, so a view can say why there is nothing")
    t.ok(world.stats.loads < 12, "the later stages were not read for nothing: " .. world.stats.loads)
    local hand = new_job({ tables = without("RecipeSets", "Character") })
    hand.want()
    until_read(hand)
    t.eq(hand.stage(), 3)
    t.eq(hand.problems()[1].table .. "." .. hand.problems()[1].row, "RecipeSets.Character")
    t.eq(r.ready(hand.model), true, "recipes are still there")
    local field = new_job({ tables = without_field("ProcessorRecipes", "RequiredMillijoules") })
    field.want()
    until_read(field)
    t.eq(field.problems()[1].table .. "." .. field.problems()[1].field, "ProcessorRecipes.RequiredMillijoules")
    t.eq(r.ready(field.model), false, "recipes are off")
    t.ok(field.model.counts.shown > 40, "the items are not")
end)

t.test("load: a read that breaks says so, reports the error once, and can be asked for again", function()
    guard.clear_errors()
    local broken = setmetatable({ items = function() error("the join broke on purpose") end }, { __index = model })
    local job, _, told = new_job({ model = broken })
    job.want()
    ticks(10)
    t.eq(job.reading, false)
    t.eq(job.failed, true)
    t.eq(job.model, nil)
    t.eq(job.progress(), 0)
    t.eq(told[#told].reading, false, "the view was told")
    t.eq(#guard.errors(), 1)
    t.ok(guard.errors()[1].trace:find("the join broke on purpose", 1, true), guard.errors()[1].trace)
    t.ok(type(loading.FAILED) == "string" and #loading.FAILED > 20, "there is a text for it")
    broken.items = nil
    job.again()
    t.eq(job.failed, false)
    until_read(job)
    t.eq(job.stage(), 3)
    guard.clear_errors()
end)

-- ---------------------------------------------------------------- init.lua, with a view of the test's own plugged in

-- Runs init.lua with a stand-in for what the loader gives a mod. `got` is what the mod did with it.
-- options: view = false (no file named view.lua), no_data, saved (settings from before), kept
local function start_mod(options)
    options = options or {}
    local world = new_data()
    local got = { started = 0, refreshed = {}, toggled = 0, keys = {}, hotkeys = {}, notices = {}, saved = options.saved or {},
        kept = options.kept or {}, showing = false, menu_key = "F8", world = world, key_changed = sched.Signal.new("KeyChanged") }
    local stand_in = {
        Notify = function(message) got.notices[#got.notices + 1] = tostring(message) end,
        TextWidth = not options.old_wax and function() return 0 end or nil,
        GetToggleKey = function() return got.menu_key end,
        KeyChanged = got.key_changed,
        Hotkey = function(key, callback, how)
            local entry = { key = key, press = callback, in_menu = how ~= nil and how.in_menu == true, on = true }
            got.hotkeys[#got.hotkeys + 1] = entry
            return { Disconnect = function() entry.on = false end }
        end,
    }
    local plugged = { start = function(app)
        got.started, got.in_task, got.given = got.started + 1, coroutine.isyieldable(), app
        sched.task.wait()       -- a view may take some frames to build itself
        return {
            refresh = function() got.refreshed[#got.refreshed + 1] = app.job.stage() .. (app.job.reading and " reading" or "") end,
            toggle = function() got.toggled = got.toggled + 1 end,
            showing = function() return got.showing end,
            key = function(key, refused) got.keys[#got.keys + 1] = tostring(key) .. (refused and " refused" or "") end,
        }
    end }
    local modules, env = {}, nil
    env = setmetatable({
        ui = stand_in,
        game = options.no_data and {} or { Data = world.api },
        task = sched.task,
        storage = {
            Load = function(name, defaults)
                local out = copy(defaults or {})
                for key, value in pairs(got.saved[name] or {}) do out[key] = copy(value) end
                return out
            end,
            Save = function(name, value) got.saved[name] = copy(value) end,
        },
        persist = function(key, default)
            if got.kept[key] == nil then got.kept[key] = default == nil and {} or default end
            return got.kept[key]
        end,
        -- mod.text stands for the file text.lua. mod.view is nil unless there is a file of that name
        mod = setmetatable({ id = "RecipeBrowser", name = "Prospector's Codex", version = "0.9.0", dir = folder }, { __index = function(_, key)
            if key == "view" and options.view == false then return nil end
            return key
        end }),
        require = function(name)
            if name == "view" then return plugged end
            if modules[name] == nil then
                modules[name] = assert(loadfile(folder .. "/" .. name .. ".lua", "t", env))()
                if name == "rows" then modules[name].SHOW_TIMES = false end
            end
            return modules[name]
        end,
    }, { __index = _G })
    got.owner = scope.new("plugged")
    scope.run(got.owner, function() got.app = assert(loadfile(folder .. "/init.lua", "t", env))() end)
    return got
end

t.test("init: a view plugged in is started once, in a task, with what any view needs, and nothing is read until it asks", function()
    local got = start_mod()
    t.eq(got.started, 1)
    t.eq(got.in_task, true)
    t.eq(got.given, got.app, "it is given what the mod gives other mods")
    ticks(5)
    local app = got.app
    for _, name in ipairs({ "text", "settings", "save", "job", "rows", "search", "format", "favourites", "history",
        "read_at_start", "failed" }) do
        t.ok(app[name] ~= nil, "the view is given " .. name)
    end
    t.eq(app.window, nil, "the text browser was not built beside it")
    t.eq(got.world.provider.calls, 0, "game.Data was not asked anything")
    t.eq(#got.refreshed, 0)
    t.eq(app.job.stage(), 0)
    t.eq(#got.hotkeys, 1)
    t.eq(got.hotkeys[1].key, "F10")
    t.eq(got.hotkeys[1].in_menu, true, "the key also closes, so it works while the menu is open")
    t.eq(got.notices[1], "Press F10 to open the Prospector's Codex.")
    t.eq(got.saved.settings.welcomed, true, "said once")
    -- the view asks for the tables, as it would when it first shows
    app.job.want()
    for _ = 1, 5000 do
        if not app.job.reading then break end
        ticks(1)
    end
    ticks(2)
    t.eq(table.concat(got.refreshed, ", "), "0 reading, 1 reading, 2 reading, 3", "told at each stage")
    for _, budget in ipairs(got.world.stats.budgets) do t.eq(budget, 1) end
    t.eq(app.rows.recipe(app.job.model, app.job.needs, app.job.model.recipe.gear).station, "3 stations")
    -- the open key is the view's to act on
    got.hotkeys[1].press()
    t.eq(got.toggled, 1)
    -- while the view says it is showing, a read gets the larger share of each frame
    got.showing = true
    local asked = #got.world.stats.budgets
    app.job.again()
    for _ = 1, 5000 do
        if not app.job.reading then break end
        ticks(1)
    end
    t.eq(got.world.stats.budgets[asked + 1], 4)
    got.owner:destroy()
    t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
end)

t.test("init: the read starts by itself when the setting says so, and again when game.Data says it changed", function()
    local got = start_mod({ saved = { settings = { welcomed = true, read_at_start = true } } })
    ticks(60)
    local app = got.app
    t.eq(app.read_at_start(), true)
    t.eq(app.job.reading, false, "not in the first seconds")
    ticks(60 * loading.START_DELAY)
    t.ok(app.job.reading or app.job.stage() == 3, "then it reads without being asked")
    for _ = 1, 5000 do
        if not app.job.reading then break end
        ticks(1)
    end
    t.eq(app.job.stage(), 3)
    local runs = app.job.runs
    got.world.changed:Fire("Weather")
    ticks(2)
    t.eq(app.job.runs, runs)
    got.world.api:Flush()
    ticks(2)
    t.eq(app.job.runs, runs + 1)
    for _ = 1, 5000 do
        if not app.job.reading then break end
        ticks(1)
    end
    t.eq(got.refreshed[#got.refreshed], "3")
    got.owner:destroy()
    -- and it is off unless the player switched it on
    local plain = start_mod({ saved = { settings = { welcomed = true } } })
    t.eq(plain.app.read_at_start(), loading.READ_AT_START)
    ticks(60 * loading.START_DELAY + 60)
    t.eq(plain.app.job.reading, false)
    t.eq(plain.app.job.stage(), 0)
    plain.owner:destroy()
end)

t.test("init: on a Wax older than the one it is made for the mod says what it needs and starts no view", function()
    local got = start_mod({ old_wax = true })
    ticks(3)
    t.eq(got.notices[1], "Prospector's Codex needs Wax 0.3.0 or newer.")
    t.eq(got.started, 0)
    got.owner:destroy()
end)

t.test("init: on a Wax without game.Data the mod says what it needs and starts no view", function()
    local got = start_mod({ no_data = true })
    ticks(3)
    t.eq(got.notices[1], "Prospector's Codex needs Wax 0.3.0 or newer.")
    t.eq(got.started, 0)
    t.eq(got.app, nil)
    t.eq(#got.hotkeys, 0)
    got.owner:destroy()
    t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
end)

-- ---------------------------------------------------------------- the two sides of the column: the real view.lua over the fake engine
-- The Bestiary side is not in every copy of the mod: without creature_view.lua these are left out.

if exists(folder .. "/creature_view.lua") then
    local creature_fixture = dofile("wax/tests/offline/creature_fixture.lua")
    Wax.mods = { list = function() return {} end, request_reload = function() end, request_sync = function() end }
    Wax.import("core.storage").directory = nil      -- the tests must not read or write the player's saved settings
    local ui = Wax.import("gui.init")
    local events = Wax.import("gui.events")
    ui.start()
    Wax.ui = ui
    ui.Theme().animation = 0
    fake.set_screen(1920, 1080, 1)
    Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
    -- none of the game's own screens is open: the open key brings the column up by itself
    fake.props.bShowMouseCursor = false
    fake.react.GetChildrenCount = function() return 0 end

    local function frames(count)
        for _ = 1, count or 1 do
            now = now + 1 / 60
            sched.step()
            ui.step()
        end
    end
    local function click(control) events.simulate(control.source, "OnClicked") end
    local function type_in(control, typed) events.simulate(control.source, "OnTextChanged", typed) end
    local function text_of(control)
        local last = fake.last(control.widget, "SetText")
        return last and rawget(last[2], "__text") or nil
    end
    local function shows(control)
        local last = fake.last(control.cell or control.widget, "SetVisibility")
        return last == nil or last[2] ~= 1
    end

    -- Runs init.lua with the mod's own view.lua and the real interface, over the creature fixture's tables.
    -- options: saved, kept, tables, maps (the game serves map and curve fields, so pages have their numbers)
    local function start_real(options)
        options = options or {}
        local world = new_data(options.tables or creature_fixture.copy())
        world.provider = creature_fixture.serve(world.tables, { maps = options.maps })
        function world.serve(changed_tables)
            world.tables = changed_tables
            world.provider = creature_fixture.serve(changed_tables)
        end
        local got = { saved = options.saved or { settings = { welcomed = true } }, kept = options.kept or {}, world = world }
        local modules, env = {}, nil
        -- options.model: what a panel has as its Model (a stand-in, or false for a Wax from before the control)
        local shown_ui = ui
        if options.model ~= nil then
            shown_ui = setmetatable({ Panel = function(given)
                local panel = ui.Panel(given)
                panel.Model = options.model
                return panel
            end }, { __index = ui })
        end
        got.game = { Data = world.api, InProspect = true, Creatures = options.creatures }
        for key, value in pairs(options.game or {}) do got.game[key] = value end
        env = setmetatable({
            ui = shown_ui,
            game = got.game,
            task = sched.task,
            log = log.channel("RecipeBrowser"),
            storage = {
                Load = function(name, defaults)
                    local out = copy(defaults or {})
                    for key, value in pairs(got.saved[name] or {}) do out[key] = copy(value) end
                    return out
                end,
                Save = function(name, value) got.saved[name] = copy(value) end,
            },
            persist = function(key, default)
                if got.kept[key] == nil then got.kept[key] = default == nil and {} or default end
                return got.kept[key]
            end,
            mod = setmetatable({ id = "RecipeBrowser", name = "Prospector's Codex", version = "0.9.2", dir = folder },
                { __index = function(_, key) return key end }),
            require = function(name)
                if modules[name] == nil then modules[name] = assert(loadfile(folder .. "/" .. name .. ".lua", "t", env))() end
                return modules[name]
            end,
        }, { __index = _G })
        got.owner = scope.new("real view")
        scope.run(got.owner, function() got.app = assert(loadfile(folder .. "/init.lua", "t", env))() end)
        frames(3)
        got.view = got.app.view
        got.beasts = got.view.beasts
        -- the open key brings the column up on its own, and the item tables are read
        got.view.toggle()
        for _ = 1, 20000 do
            frames(1)
            if got.app.job.stage() >= 2 and not got.app.job.reading then break end
        end
        frames(3)
        return got
    end
    local function until_creatures(got)
        for _ = 1, 20000 do
            frames(1)
            if got.app.beasts.model and not got.app.beasts.reading and not got.app.job.reading then break end
        end
        frames(3)
    end

    -- The cell of a block of slots whose value fits, pressed as the mouse would press it.
    local function cell_of(block, fits)
        for index = 1, block:Capacity() do
            local look = block:GetLook(index)
            if look and fits(look.value, look) then return look, index end
        end
        return nil
    end
    local function press(block, fits, signal)
        local look, index = cell_of(block, fits)
        assert(look, "no such slot")
        block[signal or "Activated"]:Fire(look.value, index, look)
        frames(2)
        return look
    end
    local function creature(id) return function(value) return type(value) == "table" and value.creature == id end end
    local function item(key) return function(value) return value == key end end
    local function tile(key) return function(value) return type(value) == "table" and value.filter == key end end
    local function listed(block)
        local out = {}
        for index = 1, block:Capacity() do
            local look = block:GetLook(index)
            if look and type(look.value) == "table" and look.value.creature then out[#out + 1] = look.value.creature end
        end
        return out
    end
    -- What a section of the page that shows says: its title, then every text of it, as the labels hold them.
    local function slots_of(part)
        local out = {}
        for _, line in ipairs(part.slots) do
            if shows(line) then
                for index = 1, line:Capacity() do
                    local look = line:GetLook(index)
                    if look then out[#out + 1] = look end
                end
            end
        end
        return out
    end

    local got = start_real()
    local app, view, beasts = got.app, got.view, got.beasts

    t.test("bestiary: every Lua file of the Bestiary is there and compiles", function()
        for _, name in ipairs({ "creatures", "creature_load", "creature_page", "creature_view", "text_creatures" }) do
            local chunk, problem = loadfile(folder .. "/" .. name .. ".lua", "t", {})
            t.ok(chunk, tostring(problem))
        end
    end)

    t.test("bestiary: the column starts on the items, and nothing of the Bestiary is built until it is asked for", function()
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
        t.eq(view.showing(), true, "the open key brought the column up")
        t.eq(beasts.parts(), nil, "no panel, no control")
        t.eq(beasts.active(), false)
        t.eq(beasts.visible(), false)
        t.eq(beasts.page(), nil)
        -- the fixture has no tech tree, so the items stop a stage short and the creatures are not read by themselves
        t.eq(app.job.stage(), 2)
        t.eq(app.beasts.model, nil, "the creature tables are not read before they are wanted")
        t.eq(app.beasts.reading, false)
        t.eq(shows(view.sides.row), true, "the row of the two sides heads the list")
    end)

    local p

    t.test("bestiary: its tab builds the panel over some frames, the items stay until the list is there, then the column is the Bestiary", function()
        local panels = #Wax.import("gui.overlay").overlays
        click(view.sides.beasts)
        t.ok(beasts.parts(), "the panel is being made")
        t.eq(beasts.active(), false, "but the items are still what the column shows")
        t.eq(beasts.visible(), false)
        t.ok(app.beasts.reading, "and the creature tables are being read")
        for _ = 1, 600 do
            if beasts.parts().ready.list then break end
            t.eq(beasts.visible(), false)
            frames(1)
        end
        p = beasts.parts()
        frames(2)
        t.eq(beasts.active(), true, "the list is there: the column is the Bestiary")
        t.eq(beasts.visible(), true)
        t.eq(p.ready.page, nil, "the page's controls are still being made")
        t.eq(text_of(p.count), "Reading the game's creatures...")
        t.eq(#Wax.import("gui.overlay").overlays, panels + 1, "one panel more, in the place of the item panel")
        t.eq(p.panel.width, 224)
        t.eq(p.panel.anchor, "right")
        t.eq(p.panel:IsVisible(), true)
        t.eq(view.showing(), true)
        local built = 0
        for _ = 1, 600 do
            if p.ready.page then break end
            built = built + 1
            frames(1)
        end
        t.ok(p.ready.page, "then the page")
        t.ok(built >= 5, "over " .. built .. " frames, a few controls each")
        until_creatures(got)
        t.eq(#app.beasts.model.list, 7)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: the list is the creatures in the game's order, with a line, a mark and a tip each, and the line says how many", function()
        local order = {}
        for position, entry in ipairs(app.beasts.model.list) do order[position] = entry.id end
        t.eq(table.concat(listed(p.grid), " "), table.concat(order, " "))
        t.eq(text_of(p.count), "7 creatures")
        t.eq(p.grid:Capacity(), 40, "four across, ten down")
        local deer = cell_of(p.grid, creature("forest_deer"))
        t.eq(deer.tone, "good", "passive: the line under the picture")
        t.ok(deer.image, "the head, from its trophy's icon")
        t.eq(deer.tip.title, "Deer")
        t.eq(deer.tip.lines[1][1], "Passive")
        t.eq(deer.mark, nil, "nothing is kept yet, so nothing is starred")
        local wolf = cell_of(p.grid, creature("forest_wolf"))
        t.eq(wolf.tone, "warn")
        t.eq(wolf.tip.lines[1][1], "Neutral - Can attack")
        t.eq(cell_of(p.grid, creature("alpha_wolf_boss")).mark, "skull", "a boss")
        t.eq(text_of(p.keys), "R open - U drops - A favourite", "the short form: the long one would take two lines of the column")
        t.eq(#app.rows.wrap(text_of(p.keys), 212 * 0.94, 10), 1, "one line")
        t.eq(shows(p.pager.row), true)
        t.eq(text_of(p.pager.label), "Page 1 of 1")
    end)

    t.test("bestiary: the category tiles stand where the item side has its own, each with its count, and choose what is listed", function()
        local names = {}
        for index = 1, p.filters:Capacity() do
            local look = p.filters:GetLook(index)
            if look then names[#names + 1] = look.tip.title .. " " .. look.tip.lines[1] end
        end
        local c = app.beasts.model
        local function count(fits)
            local found = 0
            for _, entry in ipairs(c.list) do
                if fits(entry) then found = found + 1 end
            end
            return found
        end
        t.eq(table.concat(names, ", "), "All creatures 7 creatures, Hostile 1 creature, Neutral 4 creatures, Passive 1 creature, "
            .. "Friendly 1 creature, Boss 1 creature, Can be tamed 2 creatures, Can be ridden 1 creature, Meat eater 4 creatures, "
            .. "Plant eater 2 creatures")
        t.eq(count(function(entry) return entry.temper == "neutral" end), 4, "a tile's count is what it lists")
        t.eq(p.filters:Capacity(), 12, "two rows of six")
        t.eq(p.filters:GetLook(2).image, "/Game/Assets/2DArt/UI/Icons/Icon_AggressiveCreature", "the game's own glyphs, as the item side's tiles have")
        -- one family for the whole row: every tile a filled picture of the game's own, none an outline icon of the library
        for index = 1, 10 do
            local look = p.filters:GetLook(index)
            t.ok(type(look.image) == "string" and look.image:find("^/Game/Assets/2DArt/UI/"), "tile " .. index .. " has no game picture")
            t.eq(look.icon, nil, "tile " .. index .. " still has a library icon")
        end
        t.eq(p.filters:GetLook(1).image, "/Game/Assets/2DArt/UI/Icons/T_ICON_Classification_ALL")
        t.eq(view.sides.categories:GetLook(1).image, p.filters:GetLook(1).image, "and the first tile is the item side's")
        t.eq(view.sides.categories:GetLook(1).icon, nil)
        t.eq(cell_of(p.filters, tile(false)).selected, true, "all of them, to start with")
        press(p.filters, tile("ridden"))
        t.eq(table.concat(listed(p.grid), " "), "horse")
        t.eq(text_of(p.count), "Can be ridden - 1 creature")
        t.eq(cell_of(p.filters, tile("ridden")).selected, true)
        t.eq(cell_of(p.filters, tile(false)).selected, false)
        press(p.filters, tile("passive"))
        t.eq(text_of(p.count), "Passive - 1 creature")
        t.eq(table.concat(listed(p.grid), " "), "forest_deer")
        press(p.filters, tile("meat"))
        t.eq(text_of(p.count), "Meat eater - 4 creatures")
        t.eq(#listed(p.grid), 4)
        press(p.filters, tile("passive"))
        -- the chosen tile pressed again is all of them
        press(p.filters, tile("passive"))
        t.eq(#listed(p.grid), 7)
        t.eq(text_of(p.count), "7 creatures")
        press(p.filters, tile("boss"))
        t.eq(table.concat(listed(p.grid), " "), "alpha_wolf_boss")
        press(p.filters, tile(false))
        t.eq(#listed(p.grid), 7)
    end)

    t.test("bestiary: each side has its own search box and text, and a tab says how many its own text found", function()
        type_in(p.find, "wolf")
        frames(3)
        t.eq(table.concat(listed(p.grid), " "), "forest_wolf alpha_wolf_boss")
        t.eq(text_of(p.count), "2 creatures")
        local items_found = #app.job.find.filter(app.job.model.list, app.search.parse("wolf"), { show = "all" })
        t.ok(items_found > 0, "the fixture has items with wolf in their names")
        t.eq(p.sides.beasts_caption, "Bestiary (2)")
        t.eq(p.sides.items_caption, "Items", "nothing is typed on the item side: its tab counts nothing")
        t.eq(view.sides.beasts_caption, "Bestiary (2)", "the item side's row says the same")
        -- a word of the page finds what the page says: the black wolf is the boss
        type_in(p.find, "boss")
        frames(3)
        t.eq(table.concat(listed(p.grid), " "), "alpha_wolf_boss")
        type_in(p.find, "zzz")
        frames(3)
        t.eq(#listed(p.grid), 0)
        t.eq(text_of(p.count), 'Nothing matches "zzz".')
        t.eq(p.sides.beasts_caption, "Bestiary (0)")
        -- over on the item side the box is empty and the list is whole
        type_in(p.find, "wolf")
        frames(3)
        local function items_shown()
            local count = 0
            for index = 1, view.sides.grid:Capacity() do
                if view.sides.grid:GetLook(index) then count = count + 1 end
            end
            return count
        end
        click(p.sides.items)
        frames(2)
        t.eq(beasts.visible(), false)
        t.eq(view.showing(), true)
        t.eq(view.sides.items_caption, "Items")
        t.eq(view.sides.beasts_caption, "Bestiary (2)", "the Bestiary's own text still counts on its tab")
        t.eq(fake.last(view.sides.find.source, "SetText"), nil, "nothing was put into the item side's box")
        local every = items_shown()
        t.ok(every > items_found, "every item is listed, not only those with wolf in their names")
        -- text typed here stays here
        type_in(view.sides.find, "wolf")
        frames(3)
        t.eq(items_shown(), items_found)
        t.eq(view.sides.items_caption, "Items (" .. items_found .. ")")
        click(view.sides.beasts)
        frames(2)
        t.eq(beasts.visible(), true)
        t.eq(#listed(p.grid), 2, "the Bestiary kept its own text")
        type_in(p.find, "")
        frames(3)
        t.eq(#listed(p.grid), 7, "cleared here: the whole list")
        t.eq(p.sides.beasts_caption, "Bestiary")
        t.eq(p.sides.items_caption, "Items (" .. items_found .. ")", "and the item side still has its text")
        click(p.sides.items)
        frames(2)
        t.eq(items_shown(), items_found, "wolf is still typed on the item side")
        type_in(view.sides.find, "")
        frames(3)
        t.eq(view.sides.items_caption, "Items")
        click(view.sides.beasts)
        frames(2)
        t.eq(#listed(p.grid), 7)
    end)

    t.test("bestiary: a click opens a creature's page in the same column: head, word, facts, variants, four tabs", function()
        press(p.grid, creature("horse"))
        t.eq(beasts.page(), "horse")
        t.eq(beasts.visible(), true)
        for _, control in ipairs(p.list) do t.eq(shows(control), false, "the list's bands give way to the page") end
        t.eq(shows(p.top), true)
        t.eq(text_of(p.title), "Terrenus")
        t.eq(text_of(p.word), "Neutral")
        t.eq(text_of(p.facts), "Plant eater - Can attack - Can be tamed - Can be ridden")
        t.eq(p.set[p.back].caption, "Bestiary", "the back button reads the list it goes to")
        local head = p.head:GetLook(1)
        t.eq(head.tip.title, "Terrenus")
        t.eq(head.tip.lines[1][1], "Neutral")
        t.eq(head.tip.lines[2], "The game lists it as Neutral.", "the picture's tip says what the word stands on")
        t.eq(shows(p.variants[1]), true, "wild, tamed and young on one line")
        t.eq(shows(p.variants[2]), false)
        t.eq(p.variants[1]:GetLook(1).selected, true)
        t.eq(p.variants[1]:GetLook(3).tip.title, "Juvenile Terrenus - Young")
        t.eq(shows(p.star), true, "the star keeps it on the shelf")
        t.eq(app.history:top().creature, "horse")
        t.eq(app.history:top().mode, "about")
        t.eq(p.previous.disabled, true, "nothing was looked at before it")
        -- a group no taming row names has that tab switched off
        click(p.back)
        frames(2)
        t.eq(beasts.page(), nil)
        t.eq(shows(p.grid), true, "one press and the list is back")
        t.eq(app.history:count(), 0)
        press(p.grid, creature("forest_deer"))
        t.eq(p.tabs.taming.disabled, true)
        t.eq(shows(p.variants[1]), true, "the deer and the large deer")
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: the Drops tab draws what the page gives: loot with counts, the trophy faint, the carcass, the note", function()
        click(p.tabs.drops)
        frames(2)
        t.eq(app.history:top().mode, "drops", "stepping back to it later shows this tab")
        local c, m = app.beasts.model, app.job.model
        local given = app.page.sections("drops", c, m, c.entries.forest_deer, 1, function(position) return app.beasts.detail("forest_deer", position) end, {})
        local drawn = {}
        for _, part in ipairs(p.sections) do
            if shows(part.title) or shows(part.text) or #slots_of(part) > 0 then drawn[#drawn + 1] = part end
        end
        t.ok(#drawn >= 3, #drawn .. " sections")
        t.eq(text_of(drawn[1].title), "Loot")
        local loot = slots_of(drawn[1])
        t.eq(#loot, #given[1].slots)
        local leather = nil
        for index, look in ipairs(loot) do
            t.eq(look.value, given[1].slots[index].item, "each slot is the item it gives, to be clicked")
            -- a count that fits its slot is the page's own; a range too wide for it shows where it starts
            local wanted = given[1].slots[index].count
            if wanted and app.rows.measure(wanted, 10) > 40.79 - 12 then wanted = wanted:match("^([^-]+)-") .. "+" end
            t.eq(look.count, wanted)
            if look.value == "leather" then leather = look end
        end
        t.ok(leather, "a deer gives leather")
        t.eq(leather.count, "10+", "10-16 was cut at the slot's edge in the game: the tip has both ends")
        t.eq(leather.dim, nil)
        local told = leather.tip()
        t.eq(told.title, "Leather")
        t.eq(told.lines[1], "10 to 16", "what the page says of it comes first, then what the item's own tip says")
        t.ok(#told.lines > 1, "the item's own lines follow")
        local meat = loot[5].tip()
        t.eq(meat.lines[1] .. ", " .. meat.lines[2], "3 to 5, 10% chance")
        local parts, bench, gained = nil, nil, nil
        for _, part in ipairs(drawn) do
            local title = shows(part.title) and text_of(part.title) or ""
            if title == "Trophy and bones" then parts = part end
            if title == "Carcass at the Skinning Bench" then bench = part end
            if title == "Experience" then gained = part end
        end
        t.ok(parts, "the trophy and the bones")
        local trophy = slots_of(parts)[1]
        t.eq(trophy.dim, true, "a trophy comes by a chance: it is drawn faint")
        t.eq(trophy.mark, "trophy")
        local trophy_tip = trophy.tip()
        t.eq(trophy_tip.lines[1] .. " / " .. trophy_tip.lines[2] .. " / " .. trophy_tip.lines[3], "Trophy / 1 / By a skinning chance that tools add")
        t.eq(slots_of(parts)[2].mark, "bone")
        t.eq(text_of(parts.note), "Skinning gives a trophy by a chance that tools add, such as the Taxidermy Knife.")
        t.eq(shows(parts.tail), false, "a note under the slots is their gap")
        t.eq(shows(drawn[1].tail), true, "slots that end a section keep a gap under them")
        -- the carcass at its bench is drawn as a recipe: the carcass, the arrow straight after it, then what it gives
        t.ok(bench, "the carcass at the bench")
        local made = slots_of(bench)
        t.eq(made[1].value, "animalcarcass_deer")
        t.eq(made[2].icon, "arrow-right")
        t.eq(made[2].plain, true, "the arrow is a picture, not a slot")
        t.eq(made[4].value, "leather")
        t.eq(made[4].count, "30")
        t.eq(shows(bench.slots[2]), true, "seven things are two lines of five")
        t.ok(gained, "the experience")
        local pair = nil
        for _, row in ipairs(gained.pairs) do
            if shows(row.control) then pair = row end
        end
        t.eq(text_of(pair.names), "Skinning")
        t.eq(text_of(pair.values), "260 XP")
        t.eq(text_of(gained.note), "Amounts and chances are before tools and talents.")
        -- everything the page gave is on the column: nothing is lost between the pages
        local wanted = 0
        for _, section in ipairs(given) do wanted = wanted + #(section.slots or {}) end
        local found, turned = 0, 0
        repeat
            for _, part in ipairs(p.sections) do found = found + #slots_of(part) end
            turned = turned + 1
            local more = p.turn.forth.disabled == false and shows(p.turn.row)
            if more then
                click(p.turn.forth)
                frames(2)
            end
        until not more or turned > 10
        t.eq(found, wanted)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: a slot is an item slot: a click shows its recipe in the item panel, and Backspace is the deer again", function()
        click(p.tabs.drops)
        local loot = nil
        for _, part in ipairs(p.sections) do
            if shows(part.title) and text_of(part.title) == "Loot" then loot = part end
        end
        local line = nil
        for _, block in ipairs(loot.slots) do
            if shows(block) and cell_of(block, item("leather")) then line = block end
        end
        press(line, item("leather"))
        t.eq(beasts.page(), nil, "the creature's page gave way")
        t.eq(beasts.visible(), false)
        t.eq(view.showing(), true, "to the item panel, in the same place")
        t.eq(app.history:top().item, "leather")
        t.eq(app.history:top().mode, "make")
        t.eq(app.history:count(), 2, "the deer, then the leather")
        t.eq(shows(view.sides.row), false, "an item's page has its back row where the two tabs were")
        t.eq(view.sides.back_to, "Bestiary", "and its back button reads the list it goes to")
        t.eq(view.sides.previous.disabled, false, "the deer can be stepped back to")
        -- Backspace: the thing looked at before, item or creature
        fake.keys.BackSpace = true
        frames(1)
        fake.keys.BackSpace = nil
        frames(2)
        t.eq(beasts.page(), "forest_deer")
        t.eq(beasts.visible(), true)
        t.eq(app.history:count(), 1)
        local shown = nil
        for _, part in ipairs(p.sections) do
            if shows(part.title) and text_of(part.title) == "Loot" then shown = true end
        end
        t.eq(shown, true, "on the tab it was left on")
        -- right click is what uses it
        press(line, item("leather"), "RightClicked")
        t.eq(app.history:top().mode, "used")
        t.eq(beasts.visible(), false)
        -- the item's own back button lands on the Bestiary's list in one press
        click(view.sides.back)
        frames(2)
        t.eq(beasts.page(), nil)
        t.eq(beasts.visible(), true, "the Bestiary's list: the side that was showing")
        t.eq(shows(p.grid), true)
        t.eq(shows(p.top), false)
        t.eq(app.history:count(), 0)
        -- from the item side an item's back button reads Items again
        click(p.sides.items)
        frames(2)
        press(view.sides.grid, item("leather"))
        t.eq(view.sides.back_to, "Items")
        t.eq(beasts.visible(), false)
        click(view.sides.back)
        frames(2)
        t.eq(shows(view.sides.row), true)
        click(view.sides.beasts)
        frames(2)
        t.eq(beasts.visible(), true)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: a group with more than five variants has two lines of them, and its Taming tab opens", function()
        press(p.grid, creature("dog"))
        t.eq(shows(p.variants[1]), false)
        t.eq(shows(p.variants[2]), true, "nine dogs on two lines")
        t.eq(p.variants[2]:GetLook(9) ~= nil, true)
        t.eq(text_of(p.word), "Friendly")
        t.eq(text_of(p.facts), "From the Workshop")
        t.eq(p.tabs.taming.disabled, false)
        click(p.tabs.taming)
        frames(2)
        t.eq(text_of(p.sections[1].text), "It comes tamed from the Workshop.")
        t.eq(shows(p.sections[1].title), false, "a section that carries on has no title")
        click(p.back)
        frames(2)
        t.eq(beasts.page(), nil)
        -- R and U on a creature under the mouse are a click and a right click on it
        local real = ui.Hovered
        local function key(name, over)
            ui.Hovered = function() return over end
            fake.keys[name] = true
            frames(1)
            fake.keys[name] = nil
            frames(2)
            ui.Hovered = real
        end
        key("U", cell_of(p.grid, creature("bear")).value)
        t.eq(beasts.page(), "bear")
        t.eq(app.history:top().mode, "drops", "U: its drops")
        click(p.back)
        frames(2)
        key("R", cell_of(p.grid, creature("bear")).value)
        t.eq(beasts.page(), "bear")
        t.eq(app.history:top().mode, "about", "R: its page")
        -- the favourite key over a value no slot shows keeps nothing (kept creatures have tests of their own further down)
        key("A", { creature = "bear" })
        t.eq(#app.kept:list(), 0)
        t.eq(got.saved.creatures, nil)
        click(p.back)
        frames(2)
        t.eq(beasts.page(), nil)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: one history for items and creatures, and stepping back passes over a creature the game no longer has", function()
        press(p.grid, creature("forest_wolf"))
        press(p.variants[1], function(value) return type(value) == "table" and value.variant == 2 end)
        t.eq(app.history:top().variant, 2, "the variant that shows is remembered with it")
        t.eq(p.variants[1]:GetLook(2).selected, true)
        -- from the wolf to an item, on to the bear by the history's own way in, then to another item
        local wolf_item = app.beasts.model.entries.forest_wolf.variants[1].skin[1].item
        view.beasts.leave()
        app.history:push(wolf_item, "make")
        t.eq(beasts.open("bear", "drops"), true)
        frames(2)
        t.eq(beasts.page(), "bear")
        t.eq(app.history:count(), 3)
        t.eq(p.previous.disabled, false)
        -- the game changes and the bear is gone from the creatures
        local c = app.beasts.model
        local bear = c.entries.bear
        c.entries.bear = nil
        app.history:push({ item = "c:forest_deer", creature = "forest_deer", mode = "where" })
        app.history:push({ item = "c:bear", creature = "bear", mode = "about" })
        app.history:push({ item = "c:horse", creature = "horse", mode = "about" })
        beasts.open("horse", "about", true)
        frames(2)
        click(p.previous)
        frames(2)
        t.eq(beasts.page(), "forest_deer", "the bear is passed over")
        t.eq(app.history:top().mode, "where")
        click(p.previous)
        frames(2)
        t.eq(beasts.page(), nil, "the bear's own entry is passed over too, and the item before it shows")
        t.eq(app.history:top().item, wolf_item)
        t.eq(beasts.visible(), false)
        fake.keys.BackSpace = true
        frames(1)
        fake.keys.BackSpace = nil
        frames(2)
        t.eq(beasts.page(), "forest_wolf")
        t.eq(p.variants[1]:GetLook(2).selected, true, "with the variant it was left on")
        fake.keys.BackSpace = true
        frames(1)
        fake.keys.BackSpace = nil
        frames(2)
        t.eq(beasts.page(), nil, "nothing before it: the list")
        t.eq(beasts.visible(), true)
        c.entries.bear = bear
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: every tab of every creature and variant is drawn within the column, with no blank and nothing lost", function()
        local c, m = app.beasts.model, app.job.model
        local L = dofile(folder .. "/layout.lua").compute(1920, 1080)
        local pages = dofile(folder .. "/creature_page.lua")
        local drawn = 0
        for _, entry in ipairs(c.list) do
            for position = 1, #entry.variants do
                for _, tab in ipairs(pages.TABS) do
                    if app.page.tabs(entry)[tab] then
                        t.eq(beasts.open(entry.id, tab, true, position), true)
                        frames(1)
                        local page = 0
                        repeat
                            page = page + 1
                            local where = entry.id .. " " .. position .. " " .. tab .. " page " .. page
                            -- what shows, added up as layout.lua says each thing is tall
                            local tall, any = 0, false
                            for _, part in ipairs(p.sections) do
                                for _, name in ipairs({ "title", "text", "after", "note" }) do
                                    if shows(part[name]) then
                                        local said = text_of(part[name])
                                        t.ok(type(said) == "string" and said:find("%S") and not said:find("nil", 1, true)
                                            and not said:find("table: ", 1, true), where .. ": " .. tostring(said))
                                        local small = name == "title" or name == "note"
                                        local lines = 0
                                        for piece in (said .. "\n"):gmatch("(.-)\n") do
                                            lines = lines + #app.rows.wrap(piece, L.inner * 0.94, small and 10 or 11)
                                        end
                                        tall = tall + lines * (small and L.beast_heights.small or L.beast_heights.line) + 8
                                        any = true
                                    end
                                end
                                for _, pair in ipairs(part.pairs) do
                                    if shows(pair.control) then
                                        local names, values = text_of(pair.names), text_of(pair.values)
                                        local count = select(2, names:gsub("\n", "\n")) + 1
                                        t.eq(select(2, values:gsub("\n", "\n")) + 1, count, where .. ": a figure for every name")
                                        tall = tall + count * L.beast_heights.line + 8
                                        any = true
                                    end
                                end
                                for _, line in ipairs(part.slots) do
                                    if shows(line) then tall, any = tall + 42.79, true end
                                end
                                if shows(part.tail) then tall = tall + 6 end
                            end
                            t.ok(any, where .. ": something shows")
                            local variants = (shows(p.variants[1]) and 1 or 0) + (shows(p.variants[2]) and 2 or 0)
                            local pager = shows(p.turn.row)
                            t.ok(L.beast_head + L.beast_extra(false, variants, pager) + tall <= L.room,
                                where .. ": " .. tall .. " units of sections with " .. variants .. " lines of variants")
                            drawn = drawn + 1
                            local more = pager and p.turn.forth.disabled == false
                            if more then
                                click(p.turn.forth)
                                frames(1)
                            end
                        until not more or page > 20
                    end
                end
            end
        end
        t.ok(drawn > 60, drawn .. " pages drawn")
        beasts.close()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: an item the item list hides is drawn on a page and takes no click", function()
        local c, m = app.beasts.model, app.job.model
        local hidden = nil
        for _, entry in ipairs(c.list) do
            for position, variant in ipairs(entry.variants) do
                for _, key in ipairs(variant.carcass) do
                    if m.items[key] and m.items[key].hidden and not hidden then hidden = { id = entry.id, position = position, key = key } end
                end
            end
        end
        t.ok(hidden, "the fixture has a carcass the item list hides")
        beasts.open(hidden.id, "drops", true, hidden.position)
        frames(2)
        local found, turned = nil, 0
        repeat
            for _, part in ipairs(p.sections) do
                for _, look in ipairs(slots_of(part)) do
                    if look.image == m.items[hidden.key].icon and look.value == nil then found = look end
                end
            end
            turned = turned + 1
            local more = not found and shows(p.turn.row) and p.turn.forth.disabled == false
            if more then
                click(p.turn.forth)
                frames(1)
            end
        until not more or turned > 10
        t.ok(found, "its slot is there, with its picture")
        t.eq(found.tip.title, m.items[hidden.key].name)
        beasts.close()
        frames(2)
    end)

    -- ---------------------------------------------------------------- the other tabs, the cards on an item's page, the shelf

    local sides = view.sides
    local real_hovered = ui.Hovered
    -- The mouse over a slot of a block, as the library reports it: the value, the look and the control. Nothing puts it back.
    local function hover(block, index)
        if not block then
            ui.Hovered = real_hovered
            return
        end
        ui.Hovered = function()
            local look = block:GetLook(index)
            if not look then return nil end
            return look.value, look, block
        end
    end
    -- A key pressed with the mouse over a value that no slot shows.
    local function key_over(name, over)
        ui.Hovered = function() return over end
        fake.keys[name] = true
        frames(1)
        fake.keys[name] = nil
        frames(2)
        ui.Hovered = real_hovered
    end
    local function tap(name)
        fake.keys[name] = true
        frames(1)
        fake.keys[name] = nil
        frames(2)
    end
    local function turned_on(button) return button.disabled == false end

    -- What the tab of the open creature says over all its pages: a table a section, as the controls hold it.
    local function tab_drawn()
        local out, turned = {}, 0
        repeat
            for _, part in ipairs(p.sections) do
                local section = { slots = slots_of(part) }
                if shows(part.title) then section.title = text_of(part.title) end
                if shows(part.text) then section.text = text_of(part.text) end
                for _, row in ipairs(part.pairs) do
                    if shows(row.control) then section.names, section.values = text_of(row.names), text_of(row.values) end
                end
                if shows(part.after) then section.after = text_of(part.after) end
                if shows(part.note) then section.note = text_of(part.note) end
                if section.title or section.text or section.names or section.after or section.note or #section.slots > 0 then
                    out[#out + 1] = section
                end
            end
            turned = turned + 1
            local more = shows(p.turn.row) and turned_on(p.turn.forth)
            if more then
                click(p.turn.forth)
                frames(2)
            end
        until not more or turned > 10
        return out
    end
    local function titled(sections, title)
        for at, section in ipairs(sections) do
            if section.title == title then return section, at end
        end
        return nil
    end
    local function lines_in(said)
        local out = {}
        for line in ((said or "") .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
        return out
    end
    -- The figure beside a name, or after it where the pair is written out as a sentence under the others.
    local function figure(section, name)
        local names, values = lines_in(section.names), lines_in(section.values)
        for at, known in ipairs(names) do
            if known == name then return values[at] end
        end
        for _, line in ipairs(lines_in(section.after)) do
            if line:sub(1, #name + 2) == name .. ": " then return line:sub(#name + 3) end
        end
        return nil
    end
    local function squeezed(said) return (said:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end
    -- What the page gives for a tab is what is drawn: every title, text, pair, slot and note, in order, none twice.
    local function same_as_given(id, tab, position)
        local c, m = app.beasts.model, app.job.model
        local given = app.page.sections(tab, c, m, c.entries[id], position or 1,
            function(at) return app.beasts.detail(id, at) end, {})
        local drawn = tab_drawn()
        local where = id .. " " .. tab
        local want, have = { titles = {}, texts = {}, notes = {}, slots = {}, pairs = 0 }, { titles = {}, texts = {}, notes = {}, slots = {}, pairs = 0 }
        for _, section in ipairs(given) do
            want.titles[#want.titles + 1] = section.title
            for _, said in ipairs(section.text or {}) do want.texts[#want.texts + 1] = said end
            for _, said in ipairs(section.note or {}) do want.notes[#want.notes + 1] = said end
            for _, slot in ipairs(section.slots or {}) do want.slots[#want.slots + 1] = slot.arrow and "->" or slot.item end
            for _, pair in ipairs(section.pairs or {}) do
                want.pairs = want.pairs + 1
                local found = nil
                for _, shown in ipairs(drawn) do found = found or figure(shown, pair.name) == pair.value end
                t.ok(found, where .. ": " .. pair.name .. " " .. pair.value)
            end
            want.pairs = want.pairs + #(section.after or {})
        end
        for _, section in ipairs(drawn) do
            have.titles[#have.titles + 1] = section.title
            if section.text then have.texts[#have.texts + 1] = section.text end
            if section.note then have.notes[#have.notes + 1] = section.note end
            for _, look in ipairs(section.slots) do
                have.slots[#have.slots + 1] = look.icon == "arrow-right" and "->" or look.value or (look.tip and look.tip.title and "(no click)") or "?"
            end
            have.pairs = have.pairs + (section.names and #lines_in(section.names) or 0) + (section.after and #lines_in(section.after) or 0)
        end
        t.eq(table.concat(have.titles, " | "), table.concat(want.titles, " | "), where .. ": the titles")
        t.eq(squeezed(table.concat(have.texts, " ")), squeezed(table.concat(want.texts, " ")), where .. ": the texts")
        t.eq(squeezed(table.concat(have.notes, " ")), squeezed(table.concat(want.notes, " ")), where .. ": the notes")
        t.eq(have.pairs, want.pairs, where .. ": a line for every pair")
        t.eq(#have.slots, #want.slots, where .. ": the slots")
        for at, wanted in ipairs(want.slots) do
            if have.slots[at] ~= "(no click)" then t.eq(have.slots[at], wanted, where .. ": slot " .. at) end
        end
        return drawn, given
    end
    local function open_on(id, tab, position)
        t.eq(beasts.open(id, tab, true, position), true)
        frames(2)
    end

    t.test("bestiary: the Taming tab draws what the page gives: a mount's saddles as item slots, the trap and the bait, the pairs", function()
        local c = app.beasts.model
        open_on("horse", "taming", 1)
        local drawn = same_as_given("horse", "taming", 1)
        t.eq(drawn[1].title, nil, "the opening sentence has no title")
        t.eq(drawn[1].text, "It can be tamed and ridden.")
        t.eq(titled(drawn, "A young one").text, "A wild adult has a 50% chance of a young one with it.")
        t.ok(figure(titled(drawn, "What taming takes"), "Taming time"), "the time is there")
        t.eq(figure(titled(drawn, "Once tamed"), "Top level"), "50")
        t.ok(figure(titled(drawn, "Once tamed"), "Movement orders"), "a pair too long for the line is written out under the others")
        -- fourteen things for its saddle slot: ten, and the rest in a section that carries on without a title
        local saddles, at = titled(drawn, "For its saddle slot")
        local found = {}
        for _, look in ipairs(saddles.slots) do found[#found + 1] = look.value end
        t.eq(#found, 10)
        t.eq(drawn[at + 1].title, nil)
        for _, look in ipairs(drawn[at + 1].slots) do found[#found + 1] = look.value end
        local mount = c.entries.horse.variants[2].mount
        t.eq(#found, 14)
        t.eq(table.concat(found, " "), table.concat(mount.saddles, " "), "each a slot of the item itself")
        local feed = titled(drawn, "Animal feed")
        t.ok(feed and #feed.slots > 0, "the feed")
        local last = drawn[#drawn]
        t.eq(last.note, "Items the game tags as animal feed.")
        -- a click on a saddle shows how it is made, and stepping back is the Terrenus on Taming again
        app.history:clear()
        t.eq(beasts.open("horse", "taming"), true)
        frames(2)
        local line, turned = nil, 0
        repeat
            for _, part in ipairs(p.sections) do
                for _, block in ipairs(part.slots) do
                    if shows(block) and cell_of(block, item(mount.saddles[1])) then line = block end
                end
            end
            turned = turned + 1
            local more = not line and shows(p.turn.row) and turned_on(p.turn.forth)
            if more then
                click(p.turn.forth)
                frames(2)
            end
        until not more or turned > 10
        t.ok(line, "the first saddle is on a page of the tab")
        press(line, item(mount.saddles[1]))
        t.eq(beasts.page(), nil)
        t.eq(app.history:top().item, mount.saddles[1])
        t.eq(app.history:top().mode, "make")
        tap("BackSpace")
        t.eq(beasts.page(), "horse")
        t.eq(titled(tab_drawn(), "For its saddle slot") ~= nil, true, "on the tab it was left on")

        -- the wolf: a wild one in a trap with its bait, and breeding with its serum
        open_on("forest_wolf", "taming", 1)
        drawn = same_as_given("forest_wolf", "taming", 1)
        t.eq(drawn[1].text, "It can be tamed.")
        local wild = titled(drawn, "Taming a wild one")
        t.eq(wild.text, "A wild one is caught with a trap and its bait, in Forest or Grasslands.")
        t.eq(#wild.slots, 2)
        t.eq(wild.slots[1].value, "snare_trap")
        t.eq(wild.slots[1].tip().title, "Snare Trap")
        t.eq(wild.slots[2].value, "creaturebait_wolf")
        t.eq(wild.slots[2].tip().title, "Wolf Bait")
        local breeding = titled(drawn, "Breeding")
        t.eq(breeding.slots[1].value, "fertility_serum_wolf")
        t.ok(figure(breeding, "Gestation"), "the time it takes")
        t.eq(titled(drawn, "For its saddle slot").text, "No saddle fits it.")
        -- the dog comes from the Workshop
        open_on("dog", "taming", 1)
        drawn = same_as_given("dog", "taming", 1)
        t.eq(drawn[1].text, "It comes tamed from the Workshop.")
        t.eq(titled(drawn, "For its saddle slot").slots[1].value, "dog_accessory_d")
        beasts.close()
        app.history:clear()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: the Where tab draws biomes and maps, a block a map with its note, and the other sources as sentences", function()
        open_on("forest_deer", "where", 1)
        local drawn = same_as_given("forest_deer", "where", 1)
        local found = titled(drawn, "Found in")
        t.eq(figure(found, "Biomes"), "Forest, Arctic")
        t.eq(figure(found, "Maps"), "Olympus, Styx, Prometheus")
        local olympus = titled(drawn, "Olympus")
        t.eq(figure(olympus, "Area levels"), "1 to 120")
        t.eq(figure(olympus, "Areas"), "4")
        t.eq(figure(olympus, "Share"), "10 to 21%")
        t.eq(olympus.after, nil, "a short name: it stands beside its figure like the others")
        t.eq(olympus.note, "Share is its weight in an area's spawn list.", "under the first block only")
        t.eq(titled(drawn, "Styx").note, nil)
        t.eq(figure(titled(drawn, "Outposts"), "Areas"), "3")
        -- a world boss says so, with its respawn time, and the wild one of its group is in the horde waves
        open_on("alpha_wolf_boss", "where", 1)
        drawn = same_as_given("alpha_wolf_boss", "where", 1)
        t.eq(drawn[#drawn].text, "World boss. Its respawn time is 1 h.")
        open_on("alpha_wolf_boss", "where", 2)
        drawn = same_as_given("alpha_wolf_boss", "where", 2)
        t.eq(drawn[#drawn].text, "It is in the game's horde waves.")
        -- the Workshop's animals come from there, and one no list names says so
        open_on("dog", "where", 1)
        t.eq(same_as_given("dog", "where", 1)[1].text, "It comes from the Workshop.")
        open_on("bee", "where", 1)
        drawn = same_as_given("bee", "where", 1)
        t.eq(drawn[#drawn].text, "The game's spawn lists do not name it.")
        beasts.close()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: the About tab without numbers: traits a line each, the named ones, the field guide's texts", function()
        local c = app.beasts.model
        open_on("forest_deer", "about", 1)
        local drawn = same_as_given("forest_deer", "about", 1)
        local traits = titled(drawn, "Traits")
        t.eq(#lines_in(traits.text), #c.entries.forest_deer.traits, "a trait a line")
        t.eq(lines_in(traits.text)[1], c.entries.forest_deer.traits[1].name)
        t.ok(titled(drawn, "From the Field Guide"), "the field guide's text")
        for _, section in ipairs(drawn) do
            t.eq(section.names, nil, "no numbers while the game serves no maps")
            t.ok(section.title ~= "At level 15" and section.title ~= "Numbers" and section.title ~= "Resistances")
        end
        t.eq(titled(drawn, "Named ones"), nil, "the deer has none")
        open_on("bear", "about", 1)
        drawn = same_as_given("bear", "about", 1)
        local named = titled(drawn, "Named ones")
        t.eq(#lines_in(named.text), #c.entries.bear.variants[1].epics, "a line for each row of named ones")
        t.eq(lines_in(named.text)[1], table.concat(c.entries.bear.variants[1].epics[1].names, ", "))
        -- every variant of the dog: its page is drawn from its own rows
        for position = 1, #c.entries.dog.variants do
            open_on("dog", "about", position)
            same_as_given("dog", "about", position)
        end
        beasts.close()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    -- The cards of an item's page that show, and the slots of one in order: its lines of inputs, then its output line.
    local function shown_cards()
        local out = {}
        for _, card in ipairs(sides.cards) do
            if shows(card.rule) then out[#out + 1] = card end
        end
        return out
    end
    local function card_cells(card)
        local out = {}
        for _, line in ipairs({ card.inputs[1], card.inputs[2], card.output[1] }) do
            if shows(line) then
                for index = 1, line:Capacity() do
                    local look = line:GetLook(index)
                    if look then out[#out + 1] = look end
                end
            end
        end
        return out
    end
    local function station_tabs()
        local out = {}
        for _, line in ipairs(sides.stations) do
            if shows(line) then
                for index = 1, line:Capacity() do
                    local look = line:GetLook(index)
                    if look then out[#out + 1] = { look = look, line = line, index = index } end
                end
            end
        end
        return out
    end
    local function pick_station(fits)
        for _, tab in ipairs(station_tabs()) do
            if fits(tab.look) then
                tab.line.Activated:Fire(tab.look.value, tab.index, tab.look)
                frames(2)
                return true
            end
        end
        return false
    end
    -- the creatures' tab and the cell for the rest: the game's own filled paws, not an outline icon of the library
    local function paw(look) return look.image == "/Game/Assets/2DArt/UI/Icons/T_ICON_Paws" and look.icon == nil end

    t.test("bestiary: an item's Recipe tab ends with the card of the creatures that give it, with a tab of its own among the stations", function()
        local c, m = app.beasts.model, app.job.model
        click(p.sides.items)
        frames(2)
        key_over("R", "leather")
        t.eq(app.history:top().item, "leather")
        t.eq(view.showing(), true)
        local tabs = station_tabs()
        t.eq(tabs[1].look.image, "/Game/Assets/2DArt/UI/Icons/T_ICON_Classification_ALL", "all stations first, with the tiles' own picture for everything")
        t.eq(tabs[1].look.icon, nil)
        t.eq(paw(tabs[#tabs].look), true, "the creatures last")
        t.eq(tabs[#tabs].look.tip.title, "Creatures")
        -- under all stations the card comes after the last recipe
        local recipes, last, turned = 0, nil, 0
        repeat
            for _, card in ipairs(shown_cards()) do
                recipes = recipes + 1
                last = card_cells(card)
            end
            turned = turned + 1
            local more = shows(sides.turn.row) and turned_on(sides.turn.forth)
            if more then
                click(sides.turn.forth)
                frames(2)
            end
        until not more or turned > 10
        t.eq(recipes, #m.made_by.leather + 1, "every recipe, and one card more")
        t.eq(last[1].value.creature, c.drops.leather[1].entry, "the last card is the creatures'")
        -- its own tab shows the card alone
        t.eq(pick_station(paw), true)
        local cards = shown_cards()
        t.eq(#cards, 1)
        local cells = card_cells(cards[1])
        t.eq(#cells, #c.drops.leather + 2, "the creatures, the arrow, the item")
        for at, line in ipairs(c.drops.leather) do
            t.eq(cells[at].value.creature, line.entry, "who gives most comes first")
            local boss = c.entries[line.entry].boss and "skull" or nil
            t.eq(cells[at].mark, boss, "the card says they are creatures: a paw on every cell was loud. A boss keeps its skull")
        end
        t.eq(cells[1].tone, "good", "with the line of its behaviour")
        t.eq(cells[1].tip.lines[#cells[1].tip.lines], "Loot: 12 to 18")
        t.eq(cells[#cells - 1].icon, "arrow-right")
        t.eq(cells[#cells - 1].plain, true)
        t.eq(cells[#cells].value, nil, "the item is what is open: it takes no click")
        t.eq(cells[#cells].tip.title, "Leather")
        t.eq(shows(cards[1].output[1]), true, "the arrow and the item on a line of their own, as a recipe has what it makes")
        t.eq(text_of(cards[1].needs), "Dropped by 5 creatures")
        t.eq(shows(sides.message), false)
        t.eq(shows(sides.turn.row), false)
        -- a click on a creature is its page, a right click its drops, and stepping back is the item again
        press(cards[1].inputs[1], creature("forest_deer"))
        t.eq(beasts.page(), "forest_deer")
        t.eq(beasts.visible(), true)
        t.eq(app.history:top().mode, "about")
        t.eq(p.set[p.back].caption, "Items", "the back button reads the side the column was on")
        tap("BackSpace")
        t.eq(beasts.page(), nil)
        t.eq(app.history:top().item, "leather")
        t.eq(beasts.visible(), false)
        pick_station(paw)
        press(shown_cards()[1].inputs[1], creature("forest_wolf"), "RightClicked")
        t.eq(beasts.page(), "forest_wolf")
        t.eq(app.history:top().mode, "drops")
        tap("BackSpace")
        t.eq(app.history:top().item, "leather")
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: more creatures than the card holds end in a cell that lists them all in the Bestiary, and a tile clears that", function()
        local c = app.beasts.model
        local lines = c.drops.leather
        local given = #lines
        for _ = 1, 6 do lines[#lines + 1] = lines[1] end
        -- the item was found by typing its name, and the Bestiary's own box holds a text that would leave fewer
        type_in(p.find, "wolf")
        type_in(sides.find, "leather")
        frames(3)
        key_over("R", "leather")
        pick_station(paw)
        local card = shown_cards()[1]
        local cells = card_cells(card)
        t.eq(#cells, 12, "nine creatures, the cell for the rest, the arrow, the item")
        t.eq(text_of(card.needs), "Dropped by 11 creatures")
        local rest = cells[10]
        t.eq(rest.count, "+2")
        t.eq(paw(rest), true)
        t.eq(rest.tip.title, "and 2 more")
        t.eq(rest.tip.lines[1], "Click to list them in the Bestiary")
        t.eq(rest.value.droppers, "leather")
        press(card.inputs[2], function(value) return type(value) == "table" and value.droppers == "leather" end)
        for at = #lines, given + 1, -1 do lines[at] = nil end
        frames(3)
        t.eq(beasts.visible(), true, "the Bestiary's list, from the item side")
        t.eq(beasts.page(), nil)
        t.eq(#listed(p.grid), given, "exactly those: the text of this side is put away, or it would leave fewer")
        t.eq(text_of(p.count), "Drops Leather - " .. given .. " creatures")
        t.eq(p.sides.beasts_caption, "Bestiary")
        local set = fake.last(p.find.source, "SetText")
        t.eq(set and set[2]:ToString() or "", "", "the box of this side is empty")
        t.ok(p.sides.items_caption:find("^Items %(%d+%)$"), "the item side keeps its own text: " .. p.sides.items_caption)
        t.eq(app.history:count(), 0, "a list is where the history starts again")
        press(p.filters, tile("hostile"))
        t.eq(text_of(p.count), "Hostile - 1 creature", "any tile clears it")
        press(p.filters, tile(false))
        t.eq(#listed(p.grid), 7)
        click(p.sides.items)
        frames(2)
        t.eq(fake.last(sides.find.source, "SetText"), nil, "nothing is put into the item side's box by the other side")
        type_in(sides.find, "")
        frames(3)
        t.eq(sides.items_caption, "Items")
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: what only creatures give has the card and no apology, and what nothing gives says what is not listed", function()
        key_over("R", "deer_head")
        t.eq(app.history:top().item, "deer_head")
        local tabs = station_tabs()
        t.eq(#tabs, 1, "no station makes it: the creatures are its one tab")
        t.eq(paw(tabs[1].look), true)
        local cards = shown_cards()
        t.eq(#cards, 1)
        t.eq(card_cells(cards[1])[1].value.creature, "forest_deer")
        t.eq(card_cells(cards[1])[1].tip.lines[#card_cells(cards[1])[1].tip.lines], "Trophy: 1")
        t.eq(text_of(cards[1].needs), "Dropped by 1 creature")
        t.eq(shows(sides.message), false, "nothing says there is no recipe")
        key_over("R", "taxidermy_knife")
        t.eq(#station_tabs(), 0)
        t.eq(#shown_cards(), 0)
        t.eq(shows(sides.message), true)
        t.eq(text_of(sides.message), "No recipe makes this. Mining, farming and fishing are not listed yet.", "drops are listed now")
        t.eq(app.text.right.no_recipe, "No recipe makes this. Drops, mining, farming and fishing are not listed yet.",
            "the older sentence stays for a game whose creatures cannot be listed")
        -- an item's tooltip names the creatures where it would say that no recipe makes it
        sides.grid.MiddleClicked:Fire("deer_head", 1, {})
        frames(2)
        local kept = nil
        for _, line in ipairs(sides.shelf) do
            kept = kept or cell_of(line, item("deer_head"))
        end
        t.ok(kept, "the vestige is a favourite on the shelf")
        t.eq(kept.tip().lines[1], "Dropped by 1 creature")
        sides.grid.MiddleClicked:Fire("deer_head", 1, {})
        frames(2)
        click(sides.back)
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: an item's Uses tab has the card the other way round: the item, an arrow, the creatures it is used on", function()
        local c = app.beasts.model
        key_over("U", "saddle_standard")
        t.eq(app.history:top().mode, "used")
        local tabs = station_tabs()
        t.eq(#tabs, 1)
        t.eq(paw(tabs[1].look), true)
        local cards = shown_cards()
        t.eq(#cards, 1)
        local cells = card_cells(cards[1])
        t.eq(#cells, 3)
        t.eq(cells[1].value, nil)
        t.eq(cells[1].tip.title, "Basic Riding Saddle")
        t.eq(cells[2].icon, "arrow-right", "the arrow straight after the item")
        t.eq(cells[3].value.creature, "horse")
        t.eq(cells[3].mark, nil, "no paw on a card of creatures")
        t.eq(cells[3].tip.lines[#cells[3].tip.lines], "For its saddle slot", "its tip says what the item is to it")
        t.eq(shows(cards[1].inputs[2]), false)
        t.eq(shows(cards[1].output[1]), false, "one line holds it")
        t.eq(text_of(cards[1].needs), "Used on 1 creature")
        t.eq(shows(sides.message), false, "nothing says that nothing uses it")
        -- on its Recipe tab the saddle has no such card: no creature gives it
        click(sides.views.make)
        frames(2)
        t.eq(#shown_cards(), 0)
        key_over("U", "creaturebait_wolf")
        cells = card_cells(shown_cards()[1])
        t.eq(cells[3].value.creature, "forest_wolf")
        t.eq(cells[3].tip.lines[#cells[3].tip.lines], "Its bait")
        key_over("U", "fertility_serum_wolf")
        cells = card_cells(shown_cards()[1])
        t.eq(cells[3].tip.lines[#cells[3].tip.lines], "For breeding")
        -- a saddle that fits more mounts than the card holds: twelve of them and a cell for the rest
        local lines = c.uses.saddle_standard
        for _ = 1, 13 do lines[#lines + 1] = lines[1] end
        key_over("U", "saddle_standard")
        local card = shown_cards()[1]
        cells = card_cells(card)
        t.eq(#cells, 15, "three lines of five")
        t.eq(text_of(card.needs), "Used on 14 creatures")
        t.eq(cells[15].count, "+2")
        t.eq(cells[15].value.users, "saddle_standard")
        t.eq(cells[14].value.creature, "horse")
        press(card.output[1], function(value) return type(value) == "table" and value.users == "saddle_standard" end)
        for at = #lines, 2, -1 do lines[at] = nil end
        t.eq(beasts.visible(), true)
        t.eq(table.concat(listed(p.grid), " "), "horse")
        t.eq(text_of(p.count), "Uses Basic Riding Saddle - 1 creature")
        press(p.filters, tile(false))
        t.eq(#listed(p.grid), 7)
        -- an item no creature has to do with still says so
        key_over("U", "taxidermy_knife")
        t.eq(text_of(sides.message), "Nothing uses this.")
        click(sides.back)
        frames(2)
        t.eq(beasts.visible(), true, "back on the Bestiary's list: the side that was showing")
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    -- What stands on the shelf, by the ids the mod keeps their order with: "f:<item>", "o:<item>", "c:<creature>".
    local function shelf(which)
        local out, looks = {}, {}
        for _, line in ipairs((which or sides).shelf) do
            for index = 1, line:Capacity() do
                local look = line:GetLook(index)
                if look then
                    out[#out + 1] = look.id
                    looks[look.id] = { look = look, line = line, index = index }
                end
            end
        end
        return out, looks
    end

    t.test("bestiary: a creature is kept with the star of its page, stands on the shelf among the favourites, and opens from there", function()
        t.eq(#shelf(), 0, "nothing is kept to start with")
        press(p.grid, creature("horse"))
        t.eq(shows(p.star), true)
        click(p.star)
        frames(2)
        t.eq(app.kept:has("horse"), true)
        t.eq(table.concat(got.saved.creatures, " "), "horse", "kept in a list of its own, as the favourites are")
        local ids, looks = shelf()
        t.eq(table.concat(ids, " "), "c:horse")
        local kept = looks["c:horse"].look
        t.eq(kept.value.creature, "horse")
        t.eq(kept.mark, "paw-print", "a creature outside the Bestiary's grid carries the paw")
        t.eq(kept.tone, "warn", "and the line of its behaviour")
        t.eq(kept.tip.title, "Terrenus")
        t.eq(kept.tip.lines[#kept.tip.lines][1], "In favourites")
        -- back on the list its cell is starred, and the star again lets it go
        click(p.back)
        frames(2)
        t.eq(cell_of(p.grid, creature("horse")).mark, "star")
        t.eq(cell_of(p.grid, creature("bear")).mark, nil)
        press(p.grid, creature("horse"))
        click(p.star)
        frames(2)
        t.eq(app.kept:has("horse"), false)
        t.eq(#shelf(), 0)
        click(p.star)
        frames(2)
        click(p.back)
        frames(2)
        -- a middle click keeps one too, in the list and on a card alike
        press(p.grid, creature("bear"), "MiddleClicked")
        t.eq(cell_of(p.grid, creature("bear")).mark, "star")
        t.eq(table.concat(got.saved.creatures, " "), "horse bear")
        -- with an item among them: one shelf, in the order things were kept by kind until it is changed
        sides.grid.MiddleClicked:Fire("leather", 1, {})
        frames(2)
        ids, looks = shelf()
        t.eq(table.concat(ids, " "), "f:leather c:horse c:bear")
        -- from the shelf a click is its page and a right click its drops, from either side of the column
        click(p.sides.items)
        frames(2)
        local bear = looks["c:bear"]
        bear.line.Activated:Fire(bear.look.value, bear.index, bear.look)
        frames(2)
        t.eq(beasts.page(), "bear")
        t.eq(beasts.visible(), true)
        t.eq(app.history:top().mode, "about")
        t.eq(p.set[p.back].caption, "Items")
        bear.line.RightClicked:Fire(bear.look.value, bear.index, bear.look)
        frames(2)
        t.eq(app.history:top().mode, "drops")
        click(p.back)
        frames(2)
        t.eq(beasts.visible(), false, "back on the items")
        -- on an item's card a kept creature says so in its tip
        key_over("R", "leather")
        pick_station(paw)
        local cells = card_cells(shown_cards()[1])
        local said = false
        for _, look in ipairs(cells) do
            if type(look.value) == "table" and look.value.creature == "bear" then
                said = look.tip.lines[#look.tip.lines][1] == "In favourites"
            end
        end
        t.eq(said, true)
        click(sides.back)
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: on the shelf a creature is dragged among the favourites, and the order is kept with its id", function()
        local L = dofile(folder .. "/layout.lua").compute(1920, 1080)
        local pitch = L.shelf_cell + 2
        local ids, looks = shelf()
        t.eq(table.concat(ids, " "), "f:leather c:horse c:bear")
        -- the bear, third, is dragged two places to the left
        local bear = looks["c:bear"]
        bear.line.DragStarted:Fire(bear.look.value, bear.index)
        bear.line.DragMoved:Fire(-2 * pitch, 0)
        bear.line.DragEnded:Fire()
        frames(2)
        t.eq(table.concat(shelf(), " "), "c:bear f:leather c:horse")
        t.eq(table.concat(got.saved.shelf, " "), "c:bear f:leather c:horse", "one order for all three kinds")
        -- an item dragged past a creature
        ids, looks = shelf()
        local leather = looks["f:leather"]
        leather.line.DragStarted:Fire(leather.look.value, leather.index)
        leather.line.DragMoved:Fire(pitch, 0)
        leather.line.DragEnded:Fire()
        frames(2)
        t.eq(table.concat(got.saved.shelf, " "), "c:bear c:horse f:leather")
        t.eq(table.concat(shelf(), " "), "c:bear c:horse f:leather")
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: the favourite key keeps the creature under the mouse, and held it sweeps over the list, four across", function()
        click(sides.beasts)
        frames(2)
        t.eq(beasts.visible(), true)
        local order = listed(p.grid)
        t.eq(#order, 7)
        local function kept()
            local out = {}
            for at, id in ipairs(order) do
                if app.kept:has(id) then out[#out + 1] = at end
            end
            return table.concat(out, " ")
        end
        -- start with nothing kept
        for _, id in ipairs(app.kept:list()) do app.kept:toggle(id) end
        view.creatures()
        frames(2)
        t.eq(kept(), "")
        -- one press over a creature keeps it
        hover(p.grid, 2)
        tap("A")
        t.eq(kept(), "2")
        t.eq(p.grid:GetLook(2).mark, "star", "its cell shows it at once")
        t.eq(shelf()[#shelf()], "c:" .. order[2])
        -- held: from the first to the third in a frame takes the second on the way, and down a row takes that one only
        tap("A")
        t.eq(kept(), "", "a press on a kept one lets it go when the key comes up")
        fake.react.IsInputKeyDown = function(_, pressed) return pressed.KeyName == "A" end
        hover(p.grid, 1)
        fake.keys.A = true
        frames(1)
        fake.keys.A = nil
        frames(1)
        t.eq(kept(), "1")
        hover(p.grid, 3)
        frames(1)
        t.eq(kept(), "1 2 3", "a fast mouse skips none")
        hover(p.grid, 7)
        frames(1)
        t.eq(kept(), "1 2 3 7", "the list is four across: straight down is one creature, not the row between")
        fake.react.IsInputKeyDown = nil
        frames(2)
        t.eq(kept(), "1 2 3 7")
        t.eq(#got.saved.creatures, 4)
        for _, at in ipairs({ 1, 2, 3, 7 }) do t.eq(p.grid:GetLook(at).mark, "star") end
        t.eq(p.grid:GetLook(4).mark, nil)
        -- a hold that starts on a kept one takes off: marked until the key comes up, and Escape keeps them
        fake.react.IsInputKeyDown = function(_, pressed) return pressed.KeyName == "A" end
        hover(p.grid, 1)
        fake.keys.A = true
        frames(1)
        fake.keys.A = nil
        frames(1)
        hover(p.grid, 2)
        frames(1)
        t.eq(kept(), "1 2 3 7", "nothing is gone yet")
        t.eq(p.grid:GetLook(1).mark, nil, "but its star is")
        local _, looks = shelf()
        t.eq(looks["c:" .. order[1]].look.dim, true, "on the shelf it is faint")
        t.eq(looks["c:" .. order[1]].look.mark, "x")
        t.eq(looks["c:" .. order[1]].look.tip().lines[1][1], "Goes when you let go - Esc keeps it")
        fake.react.IsInputKeyDown = function(_, pressed) return pressed.KeyName == "A" or pressed.KeyName == "Escape" end
        frames(2)
        fake.react.IsInputKeyDown = nil
        frames(2)
        t.eq(kept(), "1 2 3 7", "Escape: nothing went")
        t.eq(p.grid:GetLook(1).mark, "star")
        fake.react.IsInputKeyDown = function(_, pressed) return pressed.KeyName == "A" end
        hover(p.grid, 1)
        fake.keys.A = true
        frames(1)
        fake.keys.A = nil
        frames(1)
        hover(p.grid, 2)
        frames(1)
        fake.react.IsInputKeyDown = nil
        frames(2)
        t.eq(kept(), "3 7", "let go: both went at once")
        t.eq(#got.saved.creatures, 2)
        hover(nil)
        -- the key over a creature on an item's card keeps it too
        for _, id in ipairs(app.kept:list()) do app.kept:toggle(id) end
        view.creatures()
        key_over("R", "leather")
        pick_station(paw)
        local card = shown_cards()[1]
        hover(card.inputs[1], 1)
        tap("A")
        hover(nil)
        t.eq(table.concat(app.kept:list(), " "), card.inputs[1]:GetLook(1).value.creature)
        t.eq(shelf()[#shelf()], "c:" .. card.inputs[1]:GetLook(1).value.creature)
        click(sides.back)
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: while the creatures are read the list says so, a game that lost their tables switches the tab off, and nothing costs anything hidden", function()
        -- the creatures that give an item can be listed, and any tile clears that
        t.eq(beasts.list_drops("leather"), true)
        frames(2)
        local givers = #app.beasts.model.drops.leather
        t.eq(#listed(p.grid), givers)
        t.eq(text_of(p.count), "Drops Leather - " .. givers .. " creatures")
        t.eq(cell_of(p.filters, tile(false)).selected, false)
        press(p.filters, tile(false))
        t.eq(#listed(p.grid), 7)
        -- back on the items, the Bestiary's controls are not touched from frame to frame
        click(p.sides.items)
        frames(2)
        t.eq(beasts.visible(), false)
        local touches = fake.touches
        local sets = fake.count(p.grid.widget, "SetVisibility") + fake.count(p.count.widget, "SetText")
        frames(30)
        t.eq(fake.count(p.grid.widget, "SetVisibility") + fake.count(p.count.widget, "SetText"), sets)
        t.ok(touches <= fake.touches)
        -- the game makes its tables again without the bestiary's own
        local changed = creature_fixture.copy()
        changed.BestiaryData = nil
        got.world.serve(changed)
        got.world.api:Flush()
        for _ = 1, 20000 do
            frames(1)
            if got.app.job.stage() == 3 and not got.app.job.reading and not got.app.beasts.reading and got.app.beasts.model then break end
        end
        frames(3)
        t.eq(app.beasts.off(), true)
        t.eq(view.sides.beasts.disabled, true, "the tab is switched off")
        click(view.sides.beasts)
        frames(2)
        t.eq(beasts.visible(), false, "and pressing it changes nothing")
        t.eq(view.showing(), true, "the item side is untouched")
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: reloading the mod takes the panel and every control of it away", function()
        local overlays = Wax.import("gui.overlay").overlays
        local before = #overlays
        got.owner:destroy()
        frames(2)
        t.ok(#overlays < before, "the panels are gone")
        t.eq(p.panel.destroyed, true)
        t.eq(fake.dead_touches, 0, tostring(fake.dead_last))
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("bestiary: creatures kept before stand on the shelf at the next start, in the kept order, with no Bestiary opened", function()
        ui.Hovered = real_hovered
        local again = start_real({ maps = true, saved = { settings = { welcomed = true }, creatures = { "horse", "gone_beast", "bear" },
            favourites = { "leather" }, orders = { { key = "fur", amount = 10 } },
            shelf = { "c:bear", "o:fur", "f:leather", "c:gone_beast", "c:horse" } } })
        t.ok(again.app.beasts.reading or again.app.beasts.model, "the creatures are read without being asked for: the shelf needs them")
        until_creatures(again)
        t.eq(again.beasts.parts(), nil, "no panel of the Bestiary is made for that")
        local ids, looks = shelf(again.view.sides)
        t.eq(table.concat(ids, " "), "c:bear o:fur f:leather c:horse", "one order for items, orders and creatures; one the game lacks is left out")
        t.eq(looks["c:bear"].look.tip.title, "Bear")
        t.eq(looks["o:fur"].look.count, "x10")
        t.eq(again.app.kept:has("gone_beast"), true, "and stays kept for a game that has it again")
        -- a click on it builds the Bestiary's panel and shows its page
        local horse = looks["c:horse"]
        -- the menu the first run opened closed with it: the open key brings the column up again
        if not again.view.showing() then
            again.view.toggle()
            frames(3)
        end
        t.eq(again.view.showing(), true)
        horse.line.Activated:Fire(horse.look.value, horse.index, horse.look)
        for _ = 1, 600 do
            if again.beasts.page() == "horse" and again.beasts.visible() then break end
            frames(1)
        end
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
        t.eq(again.beasts.page(), "horse")
        t.eq(again.beasts.visible(), true)
        t.eq(shows(again.beasts.parts().star), true)
        -- this game serves map and curve fields: About has its numbers, at the level the creature is first met at
        p = again.beasts.parts()
        t.eq(again.beasts.open("forest_deer", "about", true, 1), true)
        frames(2)
        local drawn = tab_drawn()
        local numbers = titled(drawn, "At level 15")
        t.ok(numbers, "the numbers lead the tab")
        t.eq(figure(numbers, "Health"), "325")
        t.eq(numbers.note, "A prospect can change health, damage and speed.")
        t.eq(figure(titled(drawn, "Speed"), "Walking"), "2.2 m/s")
        t.eq(figure(titled(drawn, "Speed"), "While attacking"), "4.4 m/s", "a speed, under the heading that says so")
        t.eq(figure(titled(drawn, "Senses"), "Sight"), "50 m")
        local traits = titled(drawn, "Traits")
        t.ok(traits.text:find("Weak to Poison: -50%", 1, true), "a trait with the figure a stat of the creature stands behind: " .. traits.text)
        t.ok(titled(drawn, "Other stats"), "and the rest of its stats, in the game's own words")

        -- the level row: a row to step and a row of four quick levels, under the title of the numbers on the tab's first page
        local function back_to_first()
            for _ = 1, 10 do
                if not turned_on(p.turn.back) then break end
                click(p.turn.back)
                frames(2)
            end
        end
        local function first_title() return text_of(p.sections[1].title) end
        local function level_now() return tonumber(first_title():match("%d+")) end
        local function health()
            for _, row in ipairs(p.sections[1].pairs) do
                if shows(row.control) then return figure({ names = text_of(row.names), values = text_of(row.values) }, "Health") end
            end
            return nil
        end
        back_to_first()
        local picker = p.sections[1].level
        t.eq(shows(picker.row), true, "the level row shows with the numbers")
        t.eq(shows(picker.quick_row), true)
        t.eq(text_of(picker.label), "Level 15")
        t.eq(table.concat(picker.levels, " "), "1 30 60 120", "the quick levels of a creature whose levels end at 120")
        t.eq(#picker.quick, 4, "four quick levels in a row of their own: with the minus and the plus in one row no caption had room")
        local shown_quick = 0
        for _, button in ipairs(picker.quick) do
            if shows(button) then shown_quick = shown_quick + 1 end
        end
        t.eq(shown_quick, 4)
        click(picker.quick[3])
        frames(2)
        t.eq(first_title(), "At level 60", "a quick level, and the figures follow at once")
        t.eq(text_of(picker.label), "Level 60")
        t.eq(health(), "400")
        click(picker.minus)
        frames(2)
        t.eq(first_title(), "At level 59", "one a press: a creature met in the world has any level")
        click(picker.plus)
        click(picker.plus)
        frames(2)
        t.eq(first_title(), "At level 61", "two presses in one frame are two levels")
        click(picker.quick[4])
        frames(2)
        t.eq(first_title(), "At level 120")
        t.eq(turned_on(picker.plus), false, "nothing past its last level")
        t.eq(turned_on(picker.minus), true)
        click(picker.quick[1])
        frames(2)
        t.eq(first_title(), "At level 1")
        t.eq(turned_on(picker.minus), false, "and nothing under 1")
        t.eq(health(), "302")
        -- from the lowest to the highest and back, the row is whole at both ends: its label, and its four quick levels
        for _, at in ipairs({ 4, 1, 4, 1 }) do
            click(picker.quick[at])
            frames(2)
            t.eq(text_of(picker.label), "Level " .. picker.levels[at])
            for index, button in ipairs(picker.quick) do t.eq(shows(button), true, "quick level " .. index .. " at level " .. picker.levels[at]) end
        end
        -- a held minus goes on stepping after a moment, and the press that ends the hold is not one step more
        click(picker.quick[2])
        frames(2)
        fake.pressed = true
        frames(3)
        t.eq(level_now(), 30, "not at once: a press is a press")
        local started = os.clock()
        while os.clock() - started < 0.7 do frames(1) end
        local held_to = level_now()
        t.ok(held_to < 29 and held_to >= 1, "held for 0.7 s it went on: " .. tostring(held_to))
        fake.pressed = false
        click(picker.minus)
        frames(2)
        t.eq(level_now(), held_to, "letting go is not another step")
        click(picker.minus)
        frames(2)
        t.eq(level_now(), math.max(1, held_to - 1), "and the next press counts again")
        -- the level stays for the next creature, pulled into that one's own levels
        click(picker.quick[2])
        click(picker.minus)
        click(picker.minus)
        frames(2)
        t.eq(first_title(), "At level 28")
        t.eq(health(), "347", "the deer at level 28")
        t.eq(again.beasts.open("forest_wolf", "about", true, 1), true)
        frames(2)
        t.eq(first_title(), "At level 28", "two animals at one level is one step")
        t.eq(again.beasts.open("forest_wolf", "about", true, 2), true)
        frames(2)
        t.eq(first_title(), "At level 25", "the tamed wolf's levels end at 25")
        t.eq(table.concat(picker.levels, " "), "1 10 20 25")
        t.eq(again.beasts.open("forest_deer", "about", true, 1), true)
        frames(2)
        t.eq(first_title(), "At level 28", "and back on the deer it is the level that was picked")
        -- a tab without numbers has no level row
        t.eq(again.beasts.open("forest_wolf", "drops", true, 1), true)
        frames(2)
        t.eq(shows(picker.row), false, "no level row on Drops")
        t.eq(shows(picker.quick_row), false)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
        again.owner:destroy()
        frames(2)
        t.eq(fake.dead_touches, 0, tostring(fake.dead_last))
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    -- ---------------------------------------------------------------- the 3D view on About

    -- A stand-in for Container:Model: a control of the library that notes what the page asks of it.
    local function stand_in(record)
        record.calls, record.made = {}, 0
        return function(panel, options)
            local control = panel:Spacer(options.height)
            record.made, record.options, record.control = record.made + 1, options, control
            for _, name in ipairs({ "Loaded", "Failed", "Turned", "Clicked" }) do control[name] = sched.Signal.new(name) end
            function control:Show(look)
                if look.mesh == "/Game/Broken" then error("Show: the mesh is not one", 2) end
                -- a Wax whose control is from before a model could be shown against another
                if record.old and look.against then error("Show has no option 'against'.", 2) end
                record.calls[#record.calls + 1] = "Show " .. look.mesh
                record.look = look
            end
            function control:Clear()
                record.calls[#record.calls + 1] = "Clear"
                record.look = nil
            end
            function control:SetAnimation(animation) record.calls[#record.calls + 1] = "SetAnimation " .. tostring(animation) end
            return control
        end
    end
    -- game.Creatures of a Wax with the list of models: a look for every set-up but those a test names.
    local function models(special)
        local asked = {}
        return { asked = asked, GetModel = function(_, name)
            asked[#asked + 1] = name
            local given = special and special[name]
            if given == "error" then error("'" .. name .. "' is not a creature set-up.", 2) end
            if given == "none" then return nil, "Wax has no model for " .. name end
            if given then return given end
            return { mesh = "/Game/" .. name, facing = -90, walk = "/Game/" .. name .. "_Walk", idle = "/Game/" .. name .. "_Idle", walks = true }
        end }
    end
    -- The Bestiary opened in a run of its own, with its page's controls made and the creatures read.
    local function with_bestiary(options)
        local run = start_real(options)
        -- the menu an earlier run opened closed with it: the open key brings the column up again
        if not run.view.showing() then
            run.view.toggle()
            frames(3)
        end
        click(run.view.sides.beasts)
        for _ = 1, 2000 do
            local made = run.beasts.parts()
            if made and made.ready.page then break end
            frames(1)
        end
        until_creatures(run)
        return run, run.beasts.parts()
    end
    -- How tall what a creature's page shows of its tab is, added up as layout.lua says each thing is.
    local function sections_tall(q, L)
        local tall = 0
        for _, part in ipairs(q.sections) do
            for _, name in ipairs({ "title", "text", "after", "note" }) do
                if shows(part[name]) then
                    local small = name == "title" or name == "note"
                    local lines = 0
                    for piece in (text_of(part[name]) .. "\n"):gmatch("(.-)\n") do
                        lines = lines + #app.rows.wrap(piece, L.inner * 0.94, small and 10 or 11)
                    end
                    tall = tall + lines * (small and L.beast_heights.small or L.beast_heights.line) + 8
                end
            end
            for _, pair in ipairs(part.pairs) do
                if shows(pair.control) then
                    tall = tall + (select(2, text_of(pair.names):gsub("\n", "\n")) + 1) * L.beast_heights.line + 8
                end
            end
            for _, line in ipairs(part.slots) do
                if shows(line) then tall = tall + 42.79 end
            end
            if shows(part.tail) then tall = tall + 6 end
        end
        return tall
    end

    t.test("3D view: a creature's About shows its model at once, a click stops and starts its walk, and nothing is left when the page goes", function()
        local record = {}
        local special = {}
        local creatures_api = models(special)
        local run, q = with_bestiary({ maps = true, model = stand_in(record), creatures = creatures_api })
        local c = run.app.beasts.model
        local horse = c.entries.horse
        t.ok(#horse.variants >= 2, "the fixture's Terrenus has more than one variant")
        special[horse.variants[2].setup] = { mesh = "/Game/Still", facing = -90, idle = "/Game/Still_Idle", walks = false }
        t.eq(record.made, 1, "one view in the whole mod, made with the page")
        t.eq(record.options.width, 212, "the column's inner width")
        t.eq(record.options.height, 150)
        t.eq(record.options.backdrop, ui.Theme().raised, "on the colour of the page's buttons, which sets the animal off from the page")
        t.ok(record.options.light > 1, "and lit a little brighter than the control lights by itself")
        t.eq(shows(q.model), false, "hidden while the list shows")
        t.eq(#record.calls, 0, "and nothing was asked of it")
        t.eq(#creatures_api.asked, 0, "no model is asked for before a page shows")

        press(q.grid, creature("forest_deer"))
        local deer = c.entries.forest_deer
        t.eq(record.calls[1], "Show /Game/" .. deer.variants[1].setup, "the first variant's set-up, with nothing pressed")
        t.eq(#record.calls, 1)
        t.eq(shows(q.model), true)
        t.eq(shows(q.view_keys), true)
        t.eq(text_of(q.view_keys), "Drag to turn - wheel to zoom\nClick to stop it")
        t.eq(#app.rows.wrap("Drag to turn - wheel to zoom", 212 * 0.94, 10), 1, "each of its lines is one line of the column")
        t.eq(#app.rows.wrap("Click to make it walk", 212 * 0.94, 10), 1)
        -- the rest of About stands under it, inside the column
        local L = dofile(folder .. "/layout.lua").compute(1920, 1080)
        local variants = (shows(q.variants[1]) and 1 or 0) + (shows(q.variants[2]) and 2 or 0)
        local tall = sections_tall(q, L)
        t.ok(tall > 0, "something of About shows under the view")
        t.ok(L.beast_head + L.beast_extra(true, variants, shows(q.turn.row)) + L.beast_heights.small + tall <= L.room,
            tall .. " units of sections under the view")

        -- a press that did not turn it
        record.control.Clicked:Fire()
        t.eq(record.calls[2], "SetAnimation idle", "it stands and breathes")
        t.eq(text_of(q.view_keys), "Drag to turn - wheel to zoom\nClick to make it walk")
        record.control.Clicked:Fire()
        t.eq(record.calls[3], "SetAnimation walk")
        t.eq(text_of(q.view_keys), "Drag to turn - wheel to zoom\nClick to stop it")

        -- another tab hides it and keeps it; About again asks for nothing new
        click(q.tabs.drops)
        frames(2)
        t.eq(shows(q.model), false)
        t.eq(shows(q.view_keys), false)
        click(q.tabs.about)
        frames(2)
        t.eq(shows(q.model), true)
        t.eq(#record.calls, 3, "the same model: not shown anew")

        -- the variant line changes the model
        press(q.variants[1], function(value) return type(value) == "table" and value.variant == 2 end)
        t.eq(record.calls[4], "Show /Game/" .. deer.variants[2].setup)
        t.eq(text_of(q.view_keys), "Drag to turn - wheel to zoom\nClick to stop it", "a model shown anew walks")
        -- a variant that is not the group's first is shown against the first: a young one is smaller in the box
        t.eq(record.look.against.mesh, "/Game/" .. deer.variants[1].setup)
        t.eq(record.look.walk, "/Game/" .. deer.variants[2].setup .. "_Walk", "with everything else of its own look")
        press(q.variants[1], function(value) return type(value) == "table" and value.variant == 1 end)
        t.eq(record.look.against, nil, "the first is shown alone")
        t.eq(record.calls[#record.calls], "Show /Game/" .. deer.variants[1].setup)
        local asked_of_model = #record.calls

        -- a model with no walk: the line leaves the click out, and a click changes nothing
        press(q.variants[1], function(value) return type(value) == "table" and value.variant == 1 end)
        t.eq(run.beasts.open("horse", "about", false, 2), true)
        frames(2)
        t.eq(record.calls[#record.calls], "Show /Game/Still")
        t.eq(text_of(q.view_keys), "Drag to turn - wheel to zoom")
        local before = #record.calls
        record.control.Clicked:Fire()
        t.eq(#record.calls, before)

        -- back to the list: the model is taken out of the world
        click(q.back)
        frames(2)
        t.eq(record.calls[#record.calls], "Clear")
        t.eq(shows(q.model), false)
        -- the column hidden with a page open leaves no model either: the page closes with it, and the list comes back
        press(q.grid, creature("forest_deer"))
        t.eq(record.calls[#record.calls], "Show /Game/" .. deer.variants[1].setup)
        local shown_before = #record.calls
        run.view.toggle()
        frames(2)
        t.eq(run.beasts.visible(), false)
        t.eq(record.calls[#record.calls], "Clear")
        t.eq(#record.calls, shown_before + 1, "taken out once")
        run.view.toggle()
        frames(2)
        t.eq(run.beasts.visible(), true)
        t.eq(run.beasts.page(), nil)
        t.eq(shows(q.model), false)
        t.eq(#record.calls, shown_before + 1)
        press(q.grid, creature("forest_deer"))
        t.eq(record.calls[#record.calls], "Show /Game/" .. deer.variants[1].setup)
        t.eq(shows(q.model), true)
        -- an item opened from the page takes the column, and the model with it
        click(q.tabs.drops)
        frames(2)
        local line = nil
        for _, part in ipairs(q.sections) do
            for _, block in ipairs(part.slots) do
                if shows(block) and cell_of(block, item("leather")) then line = line or block end
            end
        end
        press(line, item("leather"))
        t.eq(run.beasts.visible(), false)
        t.eq(record.calls[#record.calls], "Clear")
        -- each set-up was asked for once
        local times = {}
        for _, name in ipairs(creatures_api.asked) do times[name] = (times[name] or 0) + 1 end
        for name, count in pairs(times) do t.eq(count, 1, name) end
        -- a reload of the mod destroys the control, which is what takes its actor out of the world
        run.owner:destroy()
        frames(2)
        t.eq(record.control.destroyed, true)
        t.eq(fake.dead_touches, 0, tostring(fake.dead_last))
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("3D view: a creature Wax has no model for, one whose model fails and one with nothing to play have no band", function()
        local record = {}
        local special = {}
        local creatures_api = models(special)
        local run, q = with_bestiary({ model = stand_in(record), creatures = creatures_api })
        local c = run.app.beasts.model
        local function setup_of(id) return c.entries[id].variants[1].setup end
        special[setup_of("forest_deer")] = "none"
        special[setup_of("forest_wolf")] = "error"
        special[setup_of("bear")] = { mesh = "/Game/Broken", facing = -90, walk = "/Game/W", walks = true }
        special[setup_of("horse")] = { mesh = "/Game/Swarm", facing = -90, walks = false }
        for _, id in ipairs({ "forest_deer", "forest_wolf", "bear", "horse" }) do
            t.eq(run.beasts.open(id, "about", true, 1), true)
            frames(2)
            t.eq(shows(q.model), false, setup_of(id) .. ": no band")
            t.eq(shows(q.view_keys), false)
            t.ok(sections_tall(q, dofile(folder .. "/layout.lua").compute(1920, 1080)) > 0, "the page is whole without it")
        end
        t.eq(#record.calls, 0, "nothing was shown: a model that cannot be shown is not tried a second time")
        t.eq(run.beasts.open("bear", "about", true, 1), true)
        frames(2)
        t.eq(#record.calls, 0)
        -- a model the game could not load: the control says so, and the page closes up
        local other = nil
        for _, entry in ipairs(c.list) do
            if not other and not ({ forest_deer = true, forest_wolf = true, bear = true, horse = true })[entry.id] then other = entry end
        end
        t.eq(run.beasts.open(other.id, "about", true, 1), true)
        frames(2)
        t.eq(shows(q.model), true)
        local shown_calls = #record.calls
        record.control.Failed:Fire("the mesh could not be loaded")
        frames(2)
        t.eq(shows(q.model), false, "the band is gone")
        t.eq(shows(q.view_keys), false)
        run.beasts.close()
        frames(2)
        t.eq(run.beasts.open(other.id, "about", true, 1), true)
        frames(2)
        t.eq(shows(q.model), false, "and it is not tried again")
        t.eq(#record.calls, shown_calls)
        run.owner:destroy()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("3D view: a control from before a young one could be shown against its adult still shows every variant", function()
        local record = { old = true }
        local make = stand_in(record)
        record.old = true
        local run, q = with_bestiary({ model = make, creatures = models() })
        local deer = run.app.beasts.model.entries.forest_deer
        t.eq(run.beasts.open("forest_deer", "about", true, 2), true)
        frames(2)
        t.eq(record.calls[#record.calls], "Show /Game/" .. deer.variants[2].setup, "shown as it would be alone")
        t.eq(record.look.against, nil)
        t.eq(shows(q.model), true)
        run.owner:destroy()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("3D view: on a Wax without the control, or without its list of models, the page is the page it was", function()
        for _, case in ipairs({ { model = false, creatures = models() }, { model = stand_in({}) }, {} }) do
            local run, q = with_bestiary({ model = case.model, creatures = case.creatures })
            t.eq(q.model, nil, "no control is made")
            t.eq(q.view_keys, nil)
            t.eq(run.beasts.open("forest_deer", "about", true, 1), true)
            frames(2)
            t.eq(run.beasts.page(), "forest_deer")
            t.ok(shows(q.sections[1].title) or shows(q.sections[1].text), "About starts straight under the tabs")
            if case.creatures then t.eq(#case.creatures.asked, 0, "no model is asked for") end
            run.owner:destroy()
            frames(2)
        end
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    -- game.Creatures of a Wax that can put saddles on: every saddle item of a mount by its row, but those a test leaves out.
    local function saddlery(run_of, without)
        local api = models()
        local plain = api.GetModel
        api.worn = {}
        function api.GetSaddles(_, name)
            local c, m = run_of().app.beasts.model, run_of().app.job.model
            local out = {}
            for _, entry in ipairs(c.list) do
                for _, variant in ipairs(entry.variants) do
                    if variant.setup == name and variant.mount then
                        for _, key in ipairs(variant.mount.saddles) do
                            local row = m.items[key].row
                            if not (without and without[key]) then out[#out + 1] = { Row = "Saddle_" .. name .. "_" .. row, Items = { row } } end
                        end
                    end
                end
            end
            return out
        end
        function api.GetModel(self, name, options)
            local look = plain(self, name)
            if options and options.saddle then
                api.worn[#api.worn + 1] = name .. " " .. options.saddle
                look.parts = { { mesh = "/Game/Saddles/" .. options.saddle } }
            end
            return look
        end
        return api
    end

    t.test("3D view: Taming shows a mount wearing its first saddle, a click on another puts that one on, and a click on the worn one takes it off", function()
        local record, run = {}, nil
        local api = saddlery(function() return run end)
        local q
        run, q = with_bestiary({ maps = true, model = stand_in(record), creatures = api })
        local c, m = run.app.beasts.model, run.app.job.model
        local horse = c.entries.horse
        local tamed = run.app.page.tamed_of(horse, 1)
        local mount = tamed.mount
        t.ok(#mount.saddles >= 3, "the fixture's Terrenus has saddles")
        local function row_of(key) return m.items[key].row end
        local function slot(key)
            for _, part in ipairs(q.sections) do
                for _, block in ipairs(part.slots) do
                    local cell = shows(block) and cell_of(block, item(key))
                    if cell then return block, cell end
                end
            end
        end
        -- the page that lists a saddle, turned to from the first
        local function find(key)
            for _ = 1, 12 do
                local block, cell = slot(key)
                if block then return block, cell end
                click(q.turn.forth)
                frames(1)
            end
        end
        t.eq(run.beasts.open("horse", "taming", true, 1), true)
        frames(2)
        t.eq(shows(q.model), true, "the view is on Taming")
        t.eq(record.calls[#record.calls], "Show /Game/" .. tamed.setup)
        t.eq(record.look.parts[1].mesh, "/Game/Saddles/" .. row_of(mount.saddles[1]), "with the first saddle on")
        local name = m.items[mount.saddles[1]].name
        t.eq(text_of(q.view_keys), "Drag to turn - wheel to zoom\nWearing: " .. name .. "\nClick one below to try it on")
        for piece in (text_of(q.view_keys) .. "\n"):gmatch("(.-)\n") do
            t.eq(#app.rows.wrap(piece, 212 * 0.94, 10), 1, piece .. " is one line of the column")
        end
        -- what it can wear stands straight under the tab's opening, on the page the player is on
        t.ok(slot(mount.saddles[1]), "the first saddle is on the first page")
        t.eq(text_of(q.sections[1].text), "It can be tamed and ridden.")
        t.eq(text_of(q.sections[2].title), "For its saddle slot")
        -- the view stays while the tab's pages are turned, and each page fits under it
        local L = dofile(folder .. "/layout.lua").compute(1920, 1080)
        local pages_seen = 0
        repeat
            pages_seen = pages_seen + 1
            t.eq(shows(q.model), true, "page " .. pages_seen .. " has the view")
            local variants = (shows(q.variants[1]) and 1 or 0) + (shows(q.variants[2]) and 2 or 0)
            local used = L.beast_head + L.beast_extra(true, variants, shows(q.turn.row)) + 2 * L.beast_heights.small + sections_tall(q, L)
            t.ok(used <= L.room, "page " .. pages_seen .. ": " .. used .. " of " .. L.room)
            local more = shows(q.turn.row) and q.turn.forth.disabled == false
            if more then
                click(q.turn.forth)
                frames(1)
            end
        until not more or pages_seen > 12
        t.ok(pages_seen > 1, "the Terrenus' Taming has more than one page with the view on each")
        t.eq(run.beasts.open("horse", "taming", true, 1), true)
        frames(2)

        -- the worn one is marked, and the tips say what a click does
        local block, cell = find(mount.saddles[1])
        t.eq(cell.selected, true)
        local tip = cell.tip()
        t.eq(tip.lines[1], "Click to take it off the model")
        t.eq(tip.lines[2], "Double click for its recipe")
        local other, other_cell = find(mount.saddles[2])
        t.eq(other_cell.selected, nil)
        t.eq(other_cell.tip().lines[1], "Click to put it on the model")

        -- a click on another saddle puts that one on, and the page stays
        local shows_before = #record.calls
        press(other, item(mount.saddles[2]))
        frames(1)
        t.eq(run.beasts.page(), "horse", "the creature's page is still up")
        t.eq(run.beasts.visible(), true)
        t.eq(#record.calls, shows_before + 1)
        t.eq(record.look.parts[1].mesh, "/Game/Saddles/" .. row_of(mount.saddles[2]))
        t.eq(record.look.mesh, "/Game/" .. tamed.setup, "the same body, so the control keeps the player's view of it")
        t.ok(text_of(q.view_keys):find("Wearing: " .. m.items[mount.saddles[2]].name, 1, true), text_of(q.view_keys))
        other, other_cell = find(mount.saddles[2])
        t.eq(other_cell.selected, true)

        -- a click on the worn one takes it off; the mount stands bare
        local wait = os.clock() + 0.45
        while os.clock() < wait do end
        press(other, item(mount.saddles[2]))
        frames(1)
        t.eq(record.look.parts, nil, "nothing on")
        t.eq(text_of(q.view_keys), "Drag to turn - wheel to zoom\nNothing on\nClick one below to try it on")
        t.eq(shows(q.model), true)
        other, other_cell = find(mount.saddles[2])
        t.eq(other_cell.selected, nil)

        -- two clicks in a row open the saddle's recipe, as on every slot
        press(other, item(mount.saddles[2]))
        press(other, item(mount.saddles[2]))
        frames(2)
        t.eq(run.beasts.visible(), false, "the item has the column")
        t.eq(run.app.history:top().item, mount.saddles[2])
        t.eq(record.calls[#record.calls], "Clear")

        -- each saddled look was asked of Wax once
        local times = {}
        for _, asked in ipairs(api.worn) do times[asked] = (times[asked] or 0) + 1 end
        for asked, count in pairs(times) do t.eq(count, 1, asked) end
        -- About of the same creature shows it as it is
        t.eq(run.beasts.open("horse", "about", true, 1), true)
        frames(2)
        t.eq(record.look.parts, nil)
        t.eq(text_of(q.view_keys):find("Wearing", 1, true), nil)
        run.owner:destroy()
        frames(2)
        t.eq(fake.dead_touches, 0, tostring(fake.dead_last))
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("3D view: a saddle Wax has no model of is a slot like any other, and a mount it can dress in nothing has no view on Taming", function()
        local record, run = {}, nil
        local left = {}
        local api = saddlery(function() return run end, left)
        local q
        run, q = with_bestiary({ maps = true, model = stand_in(record), creatures = api })
        local horse = run.app.beasts.model.entries.horse
        local mount = run.app.page.tamed_of(horse, 1).mount
        left[mount.saddles[1]] = true
        t.eq(run.beasts.open("horse", "taming", true, 1), true)
        frames(2)
        t.eq(record.look.parts[1].mesh, "/Game/Saddles/" .. run.app.job.model.items[mount.saddles[2]].row, "the first that Wax can put on")
        local line, cell = nil, nil
        for _ = 1, 12 do
            for _, part in ipairs(q.sections) do
                for _, block in ipairs(part.slots) do
                    local found = shows(block) and cell_of(block, item(mount.saddles[1]))
                    if found then line, cell = block, found end
                end
            end
            if line then break end
            click(q.turn.forth)
            frames(1)
        end
        t.eq(cell.selected, nil)
        press(line, item(mount.saddles[1]))
        frames(2)
        t.eq(run.beasts.visible(), false, "a click on it shows how it is made, as before")
        run.owner:destroy()
        frames(2)

        -- a Wax whose list has no saddles: Taming is the page it was
        local older = models()
        local second, p = with_bestiary({ maps = true, model = stand_in({}), creatures = older })
        t.eq(second.beasts.open("horse", "taming", true, 1), true)
        frames(2)
        t.eq(shows(p.model), false)
        t.eq(shows(p.view_keys), false)
        second.owner:destroy()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("3D view: every About of the fixture packs around the view, and the pages after the first have the whole room", function()
        local record = {}
        local run, q = with_bestiary({ maps = true, model = stand_in(record), creatures = models() })
        local c = run.app.beasts.model
        local L = dofile(folder .. "/layout.lua").compute(1920, 1080)
        local drawn, later = 0, 0
        for _, entry in ipairs(c.list) do
            for position = 1, #entry.variants do
                t.eq(run.beasts.open(entry.id, "about", true, position), true)
                frames(1)
                local page = 0
                repeat
                    page = page + 1
                    local where = entry.id .. " " .. position .. " page " .. page
                    local viewed = shows(q.model)
                    t.eq(viewed, page == 1, where .. ": the view stands on the first page only")
                    local key_lines = viewed and select(2, text_of(q.view_keys):gsub("\n", "\n")) + 1 or 0
                    local variants = (shows(q.variants[1]) and 1 or 0) + (shows(q.variants[2]) and 2 or 0)
                    local pager = shows(q.turn.row)
                    local tall = sections_tall(q, L)
                    local used = L.beast_head + L.beast_extra(viewed, variants, pager) + math.max(0, key_lines - 1) * L.beast_heights.small + tall
                    t.ok(used <= L.room, where .. ": " .. used .. " of " .. L.room)
                    drawn = drawn + 1
                    if page > 1 then later = later + 1 end
                    local more = pager and q.turn.forth.disabled == false
                    if more then
                        click(q.turn.forth)
                        frames(1)
                    end
                until not more or page > 20
            end
        end
        t.ok(drawn >= #c.list, drawn .. " pages drawn")
        t.ok(later > 0, "the fixture has an About of more than one page")
        run.owner:destroy()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("3D view: sections are packed with less room on the first page, and one that fits a later page whole is not cut", function()
        local pages = dofile(folder .. "/creature_page.lua")
        local high = { line = 10, small = 10, space = 0, row = 30, slot = 42, under = 0 }
        local function lines(count)
            local out = {}
            for at = 1, count do out[at] = "line " .. at end
            return { text = out }
        end
        local function sizes(packed)
            local out = {}
            for at, held in ipairs(packed) do
                local total = 0
                for _, section in ipairs(held) do total = total + pages.height(section, high) end
                out[at] = #held .. ":" .. total
            end
            return table.concat(out, " ")
        end
        local list = { lines(3), lines(4), lines(6), lines(2) }
        t.eq(sizes(pages.pack(list, 100, high)), "2:70 2:80", "as before without a first page of its own")
        t.eq(sizes(pages.pack(list, 100, high, 100)), sizes(pages.pack(list, 100, high)), "a first page as large as the others changes nothing")
        -- 50 units on the first page: the first section stands there, the second goes whole to the next page
        t.eq(sizes(pages.pack(list, 100, high, 50)), "1:30 2:100 1:20")
        -- a first page too small for the first section's start: it is cut to what fits there
        local long = pages.pack({ lines(8) }, 100, high, 50)
        t.eq(#long, 2)
        t.eq(#long[1][1].text, 5, "five lines under the view")
        t.eq(#long[2][1].text, 3, "the rest on the next page")
        -- no page is over its room
        for _, first in ipairs({ 20, 50, 80 }) do
            for at, held in ipairs(pages.pack(list, 100, high, first)) do
                local total = 0
                for _, section in ipairs(held) do total = total + pages.height(section, high) end
                t.ok(total <= (at == 1 and first or 100), "first " .. first .. ", page " .. at .. ": " .. total)
            end
        end
    end)

    -- ---------------------------------------------------------------- "This map only" and the order of the list

    local function ids_of(c, place)
        local out = {}
        for _, entry in ipairs(c.list) do
            if place.has[entry.id] then out[#out + 1] = entry.id end
        end
        return table.concat(out, " ")
    end
    local function tiles_of(q)
        local out = {}
        for index = 1, q.filters:Capacity() do
            local look = q.filters:GetLook(index)
            if look then out[look.tip.title] = look end
        end
        return out
    end

    t.test("map: the model knows what each map and each outpost can have, from the game's own rows", function()
        local run = with_bestiary({})
        local c = run.app.beasts.model
        local creatures = dofile(folder .. "/creatures.lua")
        local olympus, elysium = creatures.place(c, "Terrain_016"), creatures.place(c, "terrain_021")
        t.eq(olympus.name, "Olympus")
        t.eq(ids_of(c, olympus), "forest_wolf forest_deer horse bear bee dog alpha_wolf_boss")
        t.eq(olympus.count, 7)
        t.eq(ids_of(c, elysium), "bee dog", "what its spawn lists name, and what comes from the Workshop")
        t.eq(olympus.has.alpha_wolf_boss, true, "a boss is in no spawn list: its own page names the map")
        t.eq(elysium.has.alpha_wolf_boss, nil)
        -- an outpost is a place of its own, not all of them as one
        t.eq(ids_of(c, creatures.place(c, "Outpost_003")), "forest_deer dog")
        t.eq(ids_of(c, creatures.place(c, "Outpost_002")), "forest_wolf forest_deer horse bear dog")
        -- what the tables do not place is nothing: the station, the dev outpost, no map at all
        t.eq(creatures.place(c, "Station_MAS"), nil)
        t.eq(creatures.place(c, "Outpost_DEV"), nil)
        t.eq(creatures.place(c, nil), nil)
        run.owner:destroy()
        frames(2)
    end)

    t.test("map: the switch is there while a map is loaded, cuts the list to what that map can have, and follows a change of map", function()
        local changed_map = sched.Signal.new("MapChanged")
        local run, q = with_bestiary({ game = { MapName = "Terrain_021", MapChanged = changed_map } })
        local c = run.app.beasts.model
        t.eq(shows(q.map_row), true, "a map is loaded: the switch is there")
        t.eq(shows(q.no_map), false)
        t.eq(shows(q.keys), true)
        t.eq(q.map_only:Get(), false, "off until it is switched on")
        t.eq(#listed(q.grid), 7, "the whole list")
        t.eq(tiles_of(q)["Hostile"].dim, nil)
        -- switched on: what Elysium can have
        click(q.map_only)
        frames(3)
        t.eq(q.map_only:Get(), true)
        t.eq(run.saved.settings.map_only, true, "kept in the mod's settings")
        t.eq(table.concat(listed(q.grid), " "), "bee dog")
        t.eq(text_of(q.count), "2 creatures")
        local tiles = tiles_of(q)
        t.eq(tiles["All creatures"].tip.lines[1], "2 creatures", "the tiles count what the map has")
        t.eq(tiles["Friendly"].tip.lines[1], "1 creature")
        t.eq(tiles["Friendly"].dim, nil)
        t.eq(tiles["Passive"].tip.lines[1], "0 creatures")
        t.eq(tiles["Passive"].dim, true, "and one the map has nothing of is faint")
        t.eq(tiles["Boss"].dim, true)
        -- the count on the tab follows, with the search and a tile
        type_in(q.find, "dog")
        frames(3)
        t.eq(q.sides.beasts_caption, "Bestiary (1)")
        type_in(q.find, "wolf")
        frames(3)
        t.eq(q.sides.beasts_caption, "Bestiary (0)", "no wolf on Elysium")
        type_in(q.find, "")
        frames(3)
        press(q.filters, tile("friendly"))
        t.eq(table.concat(listed(q.grid), " "), "dog")
        press(q.filters, tile(false))
        -- the game loads another map while the column is up
        run.game.MapName = "Terrain_016"
        changed_map:Fire("Terrain_016")
        frames(3)
        t.eq(#listed(q.grid), 7, "Olympus has them all")
        t.eq(tiles_of(q)["Passive"].dim, nil)
        -- an outpost is matched by its own row
        run.game.MapName = "Outpost_003"
        changed_map:Fire("Outpost_003")
        frames(3)
        t.eq(table.concat(listed(q.grid), " "), "forest_deer dog")
        -- a map the tables do not place: the switch is off with one line under it, and the list is whole
        run.game.MapName = "Outpost_DEV"
        changed_map:Fire("Outpost_DEV")
        frames(3)
        t.eq(shows(q.map_row), true)
        t.eq(q.map_only.disabled, true, "switched off")
        t.eq(shows(q.no_map), true)
        t.eq(text_of(q.no_map), "No creature list for this map.")
        t.eq(#app.rows.wrap(text_of(q.no_map), 212 * 0.94, 10), 1, "one line")
        t.eq(shows(q.keys), false, "the line takes the room of the keys")
        t.eq(#listed(q.grid), 7, "never a wrong list")
        -- no map at all: the station
        run.game.InProspect = false
        run.game.MapName = "Station_MAS"
        changed_map:Fire("Station_MAS")
        frames(3)
        t.eq(shows(q.map_row), false, "not there at all")
        t.eq(shows(q.no_map), false)
        t.eq(shows(q.keys), true)
        t.eq(#listed(q.grid), 7)
        -- back in a map the switch is on as it was left
        run.game.InProspect = true
        run.game.MapName = "Terrain_021"
        changed_map:Fire("Terrain_021")
        frames(3)
        t.eq(shows(q.map_row), true)
        t.eq(q.map_only.disabled, false)
        t.eq(table.concat(listed(q.grid), " "), "bee dog")
        -- a creature's page hides the band, the list brings it back
        press(q.grid, creature("bee"))
        t.eq(shows(q.map_row), false)
        t.eq(shows(q.order), false)
        click(q.back)
        frames(2)
        t.eq(shows(q.map_row), true)
        t.eq(shows(q.order), true)
        run.owner:destroy()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("map: the setting is kept, a Wax that does not say when the map changes is asked when the column shows, and a long line stays one line", function()
        local run, q = with_bestiary({ game = { MapName = "Terrain_021" }, saved = { settings = { welcomed = true, map_only = true } } })
        t.eq(q.map_only:Get(), true, "on from the start")
        t.eq(table.concat(listed(q.grid), " "), "bee dog")
        -- another map while the column is away
        run.view.toggle()
        frames(2)
        run.game.MapName = "Outpost_003"
        run.view.toggle()
        frames(3)
        t.eq(run.beasts.visible(), true)
        t.eq(table.concat(listed(q.grid), " "), "forest_deer dog")
        -- what gives an item, cut to the map: with the switch showing the line has one line. The count always stays
        run.game.MapName = "Terrain_016"
        t.eq(run.beasts.list_drops("leather"), true)
        frames(3)
        local line = text_of(q.count)
        t.eq(#app.rows.wrap(line, 212 * 0.94, 10), 1, line)
        t.ok(line:find("^Drops Leather"), line)
        local m = run.app.job.model
        local real = m.items.leather.name
        m.items.leather.name = "Leather Of A Very Long And Winding Name"
        run.beasts.refresh()
        frames(3)
        line = text_of(q.count)
        t.eq(#app.rows.wrap(line, 212 * 0.94, 10), 1, line)
        t.ok(line:find("^Drops Leather") and line:find("%.%.%. %- %d+ creatures?$"), "a long name is cut, the count stays: " .. line)
        m.items.leather.name = real
        run.owner:destroy()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("order: the list from the most of a figure to the least, the figure on each cell, and creatures without one last", function()
        local run, q = with_bestiary({ maps = true })
        local function choose(name)
            events.simulate(q.order.items[name], "OnClicked")
            for _ = 1, 200 do
                frames(1)
                if cell_of(q.grid, function(_, look) return look.count ~= nil end) or name == "Game order" then break end
            end
            frames(2)
        end
        local game_order = "forest_wolf forest_deer horse bear bee dog alpha_wolf_boss"
        t.eq(shows(q.order), true)
        t.eq(q.order:Get(), "Game order")
        t.eq(table.concat(listed(q.grid), " "), game_order)
        t.eq(cell_of(q.grid, creature("horse")).count, nil, "no figure on a cell in the game's order")
        -- the figures are read a few creatures a frame, and the list is in the game's order until they are there
        events.simulate(q.order.items["Fastest"], "OnClicked")
        frames(1)
        t.eq(table.concat(listed(q.grid), " "), game_order, "not all read yet")
        choose("Fastest")
        t.eq(run.saved.settings.beast_order, "speed", "kept in the mod's settings")
        t.eq(table.concat(listed(q.grid), " "), "horse bear forest_deer dog forest_wolf alpha_wolf_boss bee",
            "two as fast as each other stay in the game's order")
        local horse = cell_of(q.grid, creature("horse"))
        t.eq(horse.count, "23m/s", "a speed always says its unit: in a shorter form where the whole one is too wide for a cell")
        t.eq(horse.tip.lines[2], "Fastest it moves: 22.5 m/s", "its fastest movement state, whole in the tip")
        t.eq(cell_of(q.grid, creature("forest_deer")).count, "12m/s", "and every cell of a page in the same form")
        choose("Most health")
        t.eq(table.concat(listed(q.grid), " "), "alpha_wolf_boss dog bear horse forest_deer forest_wolf bee")
        t.eq(cell_of(q.grid, creature("bear")).count, "1.1k")
        t.eq(cell_of(q.grid, creature("bear")).tip.lines[2], "Health at level 30: 1,123", "one level for all")
        t.eq(cell_of(q.grid, creature("dog")).tip.lines[2], "Health at level 25: 1,150", "but never past where its own levels end")
        choose("Most damage")
        t.eq(table.concat(listed(q.grid), " "), "bear dog forest_wolf alpha_wolf_boss horse bee forest_deer", "the deer has no damage: last")
        t.eq(cell_of(q.grid, creature("forest_deer")).count, nil, "and no number is made up for it")
        choose("Sees furthest")
        t.eq(table.concat(listed(q.grid), " "), "forest_deer alpha_wolf_boss forest_wolf horse bear bee dog")
        t.eq(cell_of(q.grid, creature("forest_deer")).count, "50 m")
        choose("Hears furthest")
        t.eq(listed(q.grid)[7], "bear", "the bear hears least")
        choose("Most XP")
        t.eq(table.concat(listed(q.grid), " "), "bear alpha_wolf_boss forest_wolf horse forest_deer dog bee")
        t.eq(cell_of(q.grid, creature("bear")).tip.lines[2], "Kill XP: 2,000 XP")
        -- it works with a tile and the search
        press(q.filters, tile("meat"))
        t.eq(table.concat(listed(q.grid), " "), "bear alpha_wolf_boss forest_wolf bee")
        press(q.filters, tile(false))
        type_in(q.find, "wolf")
        frames(3)
        t.eq(table.concat(listed(q.grid), " "), "alpha_wolf_boss forest_wolf")
        type_in(q.find, "")
        frames(3)
        choose("Game order")
        t.eq(table.concat(listed(q.grid), " "), game_order)
        t.eq(cell_of(q.grid, creature("horse")).count, nil)
        t.eq(run.saved.settings.beast_order, "game")
        run.owner:destroy()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("order: with the map switch, kept across a start, and switched off where the game does not serve the figures", function()
        local run, q = with_bestiary({ maps = true, game = { MapName = "Outpost_002" },
            saved = { settings = { welcomed = true, map_only = true, beast_order = "health" } } })
        for _ = 1, 200 do
            frames(1)
            if cell_of(q.grid, function(_, look) return look.count ~= nil end) then break end
        end
        t.eq(q.order:Get(), "Most health", "the order chosen before")
        t.eq(table.concat(listed(q.grid), " "), "dog bear horse forest_deer forest_wolf", "what the outpost has, the most health first")
        t.eq(q.order.disabled, false, "the order can be chosen")
        run.owner:destroy()
        frames(2)
        -- a game that refuses map and curve fields: the game's order, and the dropdown cannot be opened
        local plain, r = with_bestiary({ saved = { settings = { welcomed = true, beast_order = "health" } } })
        frames(30)
        t.eq(r.order:Get(), "Game order")
        t.eq(r.order.disabled, true)
        t.eq(table.concat(listed(r.grid), " "), "forest_wolf forest_deer horse bear bee dog alpha_wolf_boss")
        t.eq(cell_of(r.grid, creature("bear")).count, nil)
        t.eq(plain.saved.settings.beast_order, "health", "what was chosen is kept for a game that serves them")
        plain.owner:destroy()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    -- ---------------------------------------------------------------- the XP of a craft, on the item side

    -- The cards of a run's item page that show, and the first slot of its shelf that holds an item.
    local function cards_of(run)
        local out = {}
        for _, card in ipairs(run.view.sides.cards) do
            if shows(card.rule) then out[#out + 1] = card end
        end
        return out
    end
    local function on_shelf(run, key)
        for _, line in ipairs(run.view.sides.shelf) do
            local look = cell_of(line, item(key))
            if look then return look end
        end
        return nil
    end
    local function has(lines, wanted)
        for _, line in ipairs(lines) do
            if (type(line) == "table" and line[1] or line) == wanted then return true end
        end
        return false
    end

    t.test("xp: the recipe line, the item's tip and Materials say what a craft gives, a fifth of what it takes times nine at the skinning bench", function()
        local function single(value) return (string.unpack("<f", string.pack("<f", value))) end
        local tables = creature_fixture.copy()
        for name, pair in pairs({ ItemsStatic = { "CraftingExperience", 5 }, RecipeSets = { "ExperienceMultiplier", single(0.2) },
            ProcessorRecipes = { "ExperienceMultiplier", 1 }, IcarusResources = { "CraftingExperience", 100 } }) do
            tables[name].defaults = tables[name].defaults or {}
            tables[name].defaults[pair[1]] = pair[2]
        end
        creature_fixture.find(tables, "RecipeSets", "Skinning_Bench").ExperienceMultiplier = single(1.8)
        creature_fixture.find(tables, "ItemsStatic", "AnimalCarcass_Deer").CraftingExperience = 400
        creature_fixture.find(tables, "ItemsStatic", "Leather").CraftingExperience = 40
        creature_fixture.find(tables, "ItemsStatic", "Fur").CraftingExperience = 40
        -- a trap made of 3 leather and 2 fur: 200, and nine fifths of it
        local snare = copy(creature_fixture.find(tables, "ProcessorRecipes", "Carcass_Deer"))
        snare.Name = "Xp_Snare"
        snare.Inputs = { { Element = { RowName = "Leather", DataTableName = "D_ItemsStatic" }, Count = 3 },
            { Element = { RowName = "Fur", DataTableName = "D_ItemsStatic" }, Count = 2 } }
        snare.Outputs = { { Element = { RowName = "Snare_Trap", DataTableName = "D_ItemTemplate" }, Count = 1 } }
        table.insert(tables.ProcessorRecipes.rows, snare)
        local trap = creature_fixture.find(tables, "ItemTemplate", "Snare_Trap").ItemStaticData.RowName:lower()

        local run = start_real({ tables = tables, saved = { settings = { welcomed = true }, favourites = { trap } } })
        if not run.view.showing() then
            run.view.toggle()
            frames(3)
        end
        local s, m = run.view.sides, run.app.job.model
        t.eq(m.xp, true)
        t.eq(m.recipes[m.recipe.xp_snare].xp.skinning_bench, 360)
        t.eq(m.recipes[m.recipe.carcass_deer].xp.skinning_bench, 720, "a carcass worth 400")

        -- the recipe line: the time, then the XP
        key_over("R", trap)
        t.eq(run.app.history:top().item, trap)
        local cards = cards_of(run)
        t.eq(#cards, 1)
        local line = text_of(cards[1].needs)
        t.ok(line:find("5 s - 360 XP", 1, true), line)

        -- the tip of the item, on the shelf here: after how long it takes
        local look = on_shelf(run, trap)
        t.ok(look, "a favourite from before stands on the shelf")
        local tip = look.tip()
        t.eq(has(tip.lines, "Takes 5 s"), true)
        t.eq(has(tip.lines, "Gives 360 XP"), true)

        -- Materials: each step in the list of times, in its tip, and the sum under them
        click(s.views.tree)
        frames(2)
        local sum, steps = 0, run.app.tree.steps(run.app.tree.build(m, trap, 1, { choice = run.app.gather.choice(m) }))
        for _, step in ipairs(steps) do sum = sum + step.xp end
        t.ok(sum >= 360, "the trap's own craft is in the sum")
        local total = text_of(s.tree.total)
        t.ok(total:find(" and gives " .. text.xp(sum) .. ", before talents, upgrades and bonuses.", 1, true), total)
        t.ok(text_of(s.tree.times):find("x1 - 5 s - 360 XP", 1, true), text_of(s.tree.times))
        local step = cell_of(s.tree.steps[1], item(trap)) or cell_of(s.tree.steps[2], item(trap))
        t.ok(step, "the trap is a step")
        t.eq(has(step.tip.lines, "Gives 360 XP"), true)

        -- a carcass gives what it is worth, and the line of a recipe that makes several things says it too
        key_over("R", "leather")
        local said = false
        for _, card in ipairs(cards_of(run)) do said = said or text_of(card.needs):find("720 XP", 1, true) ~= nil end
        t.eq(said, true, "skinning a deer")
        run.owner:destroy()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)

    t.test("xp: a game without the figures shows recipes as before, with no XP anywhere", function()
        local run = start_real({ saved = { settings = { welcomed = true }, favourites = { "leather" } } })
        if not run.view.showing() then
            run.view.toggle()
            frames(3)
        end
        t.eq(run.app.job.model.xp, nil)
        key_over("R", "leather")
        t.ok(#cards_of(run) > 0)
        for _, card in ipairs(cards_of(run)) do
            t.eq(text_of(card.needs):find("XP", 1, true), nil, text_of(card.needs))
        end
        for _, said in ipairs(on_shelf(run, "leather").tip().lines) do
            t.eq(tostring(type(said) == "table" and said[1] or said):find("Gives", 1, true), nil)
        end
        run.owner:destroy()
        frames(2)
        t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    end)
end

t.finish("recipe-app")
