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
        mod = setmetatable({ id = "RecipeBrowser", name = "Recipe Browser", version = "0.9.0", dir = folder }, { __index = function(_, key)
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
    for _, name in ipairs({ "text", "settings", "save", "job", "rows", "search", "format", "favourites", "history", "set_key",
        "read_at_start", "failed" }) do
        t.ok(app[name] ~= nil, "the view is given " .. name)
    end
    t.eq(app.window, nil, "the text browser was not built beside it")
    t.eq(got.world.provider.calls, 0, "game.Data was not asked anything")
    t.eq(#got.refreshed, 0)
    t.eq(app.job.stage(), 0)
    t.eq(#got.hotkeys, 1)
    t.eq(got.hotkeys[1].key, "F7")
    t.eq(got.hotkeys[1].in_menu, true, "the key also closes, so it works while the menu is open")
    t.eq(got.keys[1], "F7", "the view is told the key, to show it")
    t.eq(got.notices[1], "Press F7 to open the Recipe Browser.")
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

t.test("init: the open key is kept in the settings, the key of the Wax menu is refused, and the view is told each time", function()
    local got = start_mod({ saved = { settings = { welcomed = true } } })
    ticks(3)
    local app = got.app
    t.eq(#got.notices, 0, "the welcome was said before")
    t.eq(app.set_key("F8"), false, "the menu's own key")
    t.eq(app.settings.key, "F7")
    t.eq(got.keys[#got.keys], "F7 refused")
    t.eq(#got.hotkeys, 1)
    t.eq(app.set_key("F9"), true)
    t.eq(got.saved.settings.key, "F9")
    t.eq(got.hotkeys[1].on, false, "the old key is let go")
    t.eq(got.hotkeys[2].key, "F9")
    t.eq(got.keys[#got.keys], "F9")
    -- the player gives the Wax menu that key afterwards: the mod's key is off until one of the two changes
    got.menu_key = "F9"
    got.key_changed:Fire("F9")
    t.eq(got.hotkeys[2].on, false)
    t.eq(#got.hotkeys, 2)
    t.eq(app.hotkey, nil)
    t.eq(got.keys[#got.keys], "F9 refused")
    got.menu_key = "F8"
    got.key_changed:Fire("F8")
    t.eq(got.hotkeys[3].key, "F9")
    t.eq(got.hotkeys[3].on, true)
    t.eq(got.keys[#got.keys], "F9")
    got.owner:destroy()
    -- the key from the settings is the one bound the next time
    local later = start_mod({ saved = got.saved })
    ticks(3)
    t.eq(later.hotkeys[1].key, "F9")
    later.owner:destroy()
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

t.test("init: on a Wax without game.Data the mod says what it needs and starts no view", function()
    local got = start_mod({ no_data = true })
    ticks(3)
    t.eq(got.notices[1], "Recipe Browser needs Wax 0.2.0 or newer.")
    t.eq(got.started, 0)
    t.eq(got.app, nil)
    t.eq(#got.hotkeys, 0)
    got.owner:destroy()
    t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
end)

t.finish("recipe-app")
