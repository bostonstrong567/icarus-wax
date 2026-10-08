-- Offline tests for what a creature's page says: its word and facts, the cells, each tab's sections with every
-- text, and the packing into pages. They run on real rows of seven creature groups (creature_rows.lua).
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\recipe_creature_page_test.lua <mod folder>

local t = dofile("wax/tests/offline/harness.lua")

local folder = arg and arg[1]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end

local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
end

if not folder or not exists(folder .. "/creature_page.lua") then
    print("recipe-creature-page: 0 passed (skipped: the Bestiary's creature_page.lua is not here)")
    os.exit(0)
end

local fixture = dofile("wax/tests/offline/creature_fixture.lua")
local part = fixture.parts(folder)
local source, creatures, pages = part("source"), part("creatures"), part("creature_page")
local text, format = part("text"), part("format")
local beasts = part("text_creatures")(text)

-- A world over the fixture: the two models, a page maker with the game's own stat wording, and the details.
local function world(options)
    options = options or {}
    local provider = fixture.provider({ tables = options.tables, maps = options.maps })
    local w = {}
    w.c, w.m, w.src, w.items = fixture.build(part, provider, { words = beasts.search_words(), stages = options.stages })
    w.page = pages.new({ beasts = beasts, text = text, creatures = creatures,
        stats = part("stats").new(source.new(provider), text, format) })
    function w.details(id)
        return function(position) return creatures.detail(w.c, w.src, id, position) end
    end
    function w.tab(tab, id, position, more)
        return w.page.sections(tab, w.c, w.m, w.c.entries[id], position or 1, w.details(id), more)
    end
    return w
end

local plain, served = world(), world({ maps = true })

local function titled(sections, title)
    for position, section in ipairs(sections) do
        if section.title == title then return section, position end
    end
    return nil
end

local function pair_of(section, name)
    for _, pair in ipairs(section and section.pairs or {}) do
        if pair.name == name then return pair.value end
    end
    return nil
end

-- A section's sentences: those above its pairs, then those under them.
local function texts(section)
    local out = {}
    for _, words in ipairs(section and section.text or {}) do out[#out + 1] = words end
    for _, words in ipairs(section and section.after or {}) do out[#out + 1] = words end
    return table.concat(out, " | ")
end

local function slot_items(section)
    local out = {}
    for position, slot in ipairs(section and section.slots or {}) do out[position] = slot.arrow and "->" or slot.item end
    return table.concat(out, " ")
end

local function slot_of(section, item)
    for _, slot in ipairs(section and section.slots or {}) do
        if slot.item == item then return slot end
    end
    return nil
end

local function all_text(sections)
    local out = {}
    for _, section in ipairs(sections) do
        out[#out + 1] = section.title
        for _, words in ipairs(section.text or {}) do out[#out + 1] = words end
        for _, pair in ipairs(section.pairs or {}) do out[#out + 1] = pair.name .. ": " .. pair.value end
        for _, words in ipairs(section.after or {}) do out[#out + 1] = words end
        for _, words in ipairs(section.note or {}) do out[#out + 1] = words end
    end
    return table.concat(out, " | ")
end

-- Fails on anything a player would see as a mistake: a blank, the word nil, a table printed, an empty section.
local function sound(sections, where, m)
    t.ok(type(sections) == "table" and #sections > 0, where .. ": no sections")
    local function good(value, what)
        t.ok(type(value) == "string", where .. ": " .. what .. " is a " .. type(value))
        t.ok(value:find("%S"), where .. ": " .. what .. " is blank")
        t.ok(not value:find("^%s") and not value:find("%s$"), where .. ": " .. what .. " has space around it: '" .. value .. "'")
        for _, bad in ipairs({ "%f[%a]nil%f[%A]", "%f[%a]nan%f[%A]", "%f[%a]inf%f[%A]", "table: ", "function: ", "%%[sd]", "  %S" }) do
            t.ok(not value:find(bad), where .. ": " .. what .. " reads '" .. value .. "'")
        end
    end
    for at, section in ipairs(sections) do
        local here, parts = where .. " section " .. at, 0
        if section.title ~= nil then good(section.title, "a title") end
        for _, key in ipairs({ "text", "pairs", "after", "slots", "note" }) do
            t.ok(section[key] == nil or #section[key] > 0, here .. ": an empty list of " .. key)
        end
        for _, key in ipairs({ "text", "after" }) do
            for _, words in ipairs(section[key] or {}) do
                good(words, "a sentence")
                parts = parts + 1
            end
        end
        for _, pair in ipairs(section.pairs or {}) do
            good(pair.name, "a pair's name")
            good(pair.value, "the figure of " .. tostring(pair.name))
            parts = parts + 1
        end
        for _, slot in ipairs(section.slots or {}) do
            t.ok(slot.arrow == true or (type(slot.item) == "string" and m.items[slot.item] ~= nil), here .. ": a slot with no item")
            if slot.count ~= nil then good(slot.count, "a slot's count") end
            for _, line in ipairs(slot.lines or {}) do good(line, "a slot's tip line") end
            parts = parts + 1
        end
        for _, words in ipairs(section.note or {}) do good(words, "a note") end
        t.ok(parts > 0, here .. ": nothing in it")
    end
end

-- ---------------------------------------------------------------- the word, the facts, the tabs

t.test("head: the word and the line under it for each kind of creature", function()
    local function head(id, position)
        local shown = plain.page.head(plain.c.entries[id], position)
        return shown.word.text .. " [" .. shown.word.tone .. "] " .. shown.facts
    end
    t.eq(head("forest_deer"), "Passive [good] Plant eater")
    t.eq(head("forest_wolf"), "Neutral [warn] Meat eater - Can attack - Can be tamed")
    t.eq(head("horse"), "Neutral [warn] Plant eater - Can attack - Can be tamed - Can be ridden")
    t.eq(head("alpha_wolf_boss"), "Neutral [warn] Meat eater - Can attack - Boss")
    t.eq(head("bear"), "Hostile [bad] Meat eater")
    t.eq(head("dog"), "Friendly [accent] From the Workshop")
    t.eq(head("bee"), "Neutral [warn] Meat eater", "its GOAP row gives no reason to say it attacks")
    t.eq(head("forest_wolf", 2), "Friendly [accent] Meat eater - Can be tamed", "the word follows the variant that shows")
    t.eq(head("forest_wolf", 3), "Passive [good] Meat eater - Can be tamed", "and the cub has the group's diet")
    local shown = plain.page.head(plain.c.entries.forest_deer)
    t.eq(shown.name, "Deer")
    t.ok(shown.image:find("Deer_Head", 1, true))
    t.eq(shown.icon, nil)
    t.eq(shown.word.tip, "The game lists it as Passive.")
    t.eq(plain.page.head(plain.c.entries.bear).word.tip, "The game lists it as Aggressive.", "Hostile is the mod's word: the tip has the row's")
    t.eq(plain.page.head(plain.c.entries.forest_wolf).word.tip, "The game lists it as Neutral.")
    t.eq(plain.page.head(plain.c.entries.dog).word.tip, "It is on the player's team.", "Friendly is read from the team row")
    t.eq(plain.page.head(plain.c.entries.bee).icon, "paw-print", "no picture: the paw")
end)

t.test("head: a creature with no word is Boss when the bestiary says so, else 'Behaviour not listed', and no line is ''", function()
    local changed = fixture.copy()
    fixture.find(changed, "AISetup", "Alpha_Wolf_Boss").Descriptors = {}
    fixture.find(changed, "AISetup", "Bee").Descriptors = {}
    local other = world({ tables = changed })
    local boss = other.page.head(other.c.entries.alpha_wolf_boss)
    t.eq(boss.word.text .. " " .. boss.word.tone, "Boss bad")
    t.eq(boss.facts, "Meat eater", "Boss is said once")
    local bee = other.page.head(other.c.entries.bee)
    t.eq(bee.word.text .. " " .. bee.word.tone, "Behaviour not listed dim")
    t.eq(bee.facts, "")
end)

t.test("tabs: Taming is off for a group no taming or mount row names, with the reason", function()
    local open, why = plain.page.tabs(plain.c.entries.forest_deer)
    t.eq(open.about and open.drops and open.where, true)
    t.eq(open.taming, false)
    t.eq(why.taming, "The game's taming tables do not name it.")
    open, why = plain.page.tabs(plain.c.entries.forest_wolf)
    t.eq(open.taming, true)
    t.eq(why.taming, nil)
    t.eq(plain.page.tabs(plain.c.entries.dog).taming, true)
    t.eq(texts(plain.tab("taming", "forest_deer")[1]), "The game's taming tables do not name it.", "and asked for anyway it says so")
end)

-- ---------------------------------------------------------------- cells

t.test("cell: the picture, the behaviour's line, the mark, and a tip that says no more than the tables", function()
    local wolf = plain.page.cell(plain.c.entries.forest_wolf)
    t.ok(wolf.image:find("Wolf_Head", 1, true))
    t.eq(wolf.tone, "warn")
    t.eq(wolf.mark, nil)
    t.eq(wolf.value.creature, "forest_wolf")
    t.eq(wolf.tip.title, "Wolf")
    t.eq(wolf.tip.lines[1][1] .. " [" .. wolf.tip.lines[1][2] .. "]", "Neutral - Can attack [warn]")
    t.eq(wolf.tip.lines[2], "Meat eater - Forest")
    t.eq(wolf.tip.lines[3], "Can be tamed")
    t.eq(#wolf.tip.lines, 3)
    local horse = plain.page.cell(plain.c.entries.horse)
    t.eq(horse.tip.lines[3], "Can be ridden", "ridden says tamed too")
    local boss = plain.page.cell(plain.c.entries.alpha_wolf_boss)
    t.eq(boss.mark, "skull")
    t.eq(boss.tip.lines[#boss.tip.lines], "Boss")
    local bee = plain.page.cell(plain.c.entries.bee)
    t.eq(bee.image, nil)
    t.eq(bee.icon, "paw-print")
    t.eq(plain.page.cell(plain.c.entries.forest_deer).tone, "good")
    t.eq(plain.page.cell(plain.c.entries.dog).tone, "accent")
end)

t.test("cell: kept, internal names, and outside the Bestiary's own grid", function()
    local kept = plain.page.cell(plain.c.entries.alpha_wolf_boss, { kept = true, internal = true })
    t.eq(kept.mark, "star", "the star goes before the skull")
    t.eq(kept.tip.lines[#kept.tip.lines], "Alpha_Wolf_Boss")
    t.eq(kept.tip.lines[#kept.tip.lines - 1][1], "In favourites")
    local looks = plain.page.droppers(plain.c, "leather")
    t.eq(#looks, 5)
    t.eq(looks[1].value.creature, "forest_deer")
    t.eq(looks[1].mark, nil, "a card of creatures says what they are: no paw on each cell")
    t.eq(plain.page.cell(plain.c.entries.forest_deer, { outside = true }).mark, "paw-print",
        "among items, as on the shelf, its picture is an item's, so the paw tells it from one")
    t.eq(plain.page.droppers(plain.c, "alpha_wolf_fur")[1] and plain.page.droppers(plain.c, "alpha_wolf_fur")[1].mark or "skull", "skull",
        "a boss keeps its skull on a card")
    t.eq(looks[1].tip.lines[#looks[1].tip.lines], "Loot: 12 to 18")
    local head = plain.page.droppers(plain.c, "deer_head")
    t.eq(head[1].tip.lines[#head[1].tip.lines], "Trophy: 1")
    local gamey = plain.page.droppers(plain.c, "gamey_meat")
    t.eq(gamey[1].tip.lines[#gamey[1].tip.lines], "Loot: 3 to 5, 25% chance")
    t.eq(#plain.page.droppers(plain.c, "wood"), 0)
    local users = plain.page.users(plain.c, "saddle_standard")
    t.eq(#users, 1)
    t.eq(users[1].value.creature, "horse")
    t.eq(#plain.page.users(plain.c, "leather"), 0)
end)

t.test("variants: a cell each when there is more than one, named by kind and role", function()
    local cells = plain.page.variants(plain.c.entries.forest_wolf, 2)
    t.eq(#cells, 3)
    t.eq(cells[1].tip.title, "Wolf - Wild")
    t.eq(cells[2].tip.title, "Wolf - Tamed")
    t.eq(cells[3].tip.title, "Wolf - Young", "the cub's kind is the adult's, so its name is too")
    t.eq(tostring(cells[1].mark) .. " " .. cells[2].mark .. " " .. cells[3].mark, "nil heart baby")
    t.eq(cells[2].selected, true)
    t.eq(cells[1].selected, false)
    t.eq(cells[3].value.variant, 3)
    t.eq(cells[2].tip.lines[1][1], "Friendly")
    local deer = plain.page.variants(plain.c.entries.forest_deer)
    t.eq(deer[1].tip.title .. ", " .. deer[2].tip.title, "Deer - Wild, Large Deer - Wild")
    t.eq(#plain.page.variants(plain.c.entries.bee), 0, "one variant: no line")
    local dogs = plain.page.variants(plain.c.entries.dog)
    t.eq(#dogs, 9)
    t.eq(dogs[3].tip.title, "Dog - On your side")
    t.eq(dogs[3].mark, nil, "no heart for one no taming row names")
    local boss = plain.page.variants(plain.c.entries.alpha_wolf_boss)
    t.eq(boss[1].tip.title, "Black Wolf - Boss")
    t.eq(boss[2].tip.title, "Black Wolf - Wild")
end)

t.test("variants: two of one name are told apart by a drop the rows name, others say nothing more", function()
    local boss = plain.page.variants(plain.c.entries.alpha_wolf_boss, 1, plain.m)
    t.eq(boss[2].tip.title, boss[3].tip.title)
    t.eq(boss[2].tip.lines[2], "Trophy: Black Wolf Vestige")
    t.eq(boss[3].tip.lines[2], "Trophy: Snow Wolf Vestige")
    t.eq(#boss[1].tip.lines, 1, "the boss is the only one of its name")
    local dogs = plain.page.variants(plain.c.entries.dog, 1, plain.m)
    local said, different = {}, 0
    for position = 3, 9 do
        local line = dogs[position].tip.lines[2]
        t.ok(type(line) == "string" and line:find("^Trophy: %S") ~= nil, "dog " .. position .. " names its trophy")
        if not said[line] then different = different + 1 end
        said[line] = true
    end
    t.eq(different, 6, "seven dogs on your side, six trophies: two pugs differ in their loot row only")
    local wolves = plain.page.variants(plain.c.entries.forest_wolf, 1, plain.m)
    for position = 1, 3 do t.eq(#wolves[position].tip.lines, 1) end
    t.eq(#plain.page.variants(plain.c.entries.alpha_wolf_boss)[2].tip.lines, 1, "without the item model: the word alone")
end)

-- ---------------------------------------------------------------- Drops

t.test("drops: loot as slots with the row's amount and chance", function()
    local sections = plain.tab("drops", "forest_deer")
    local loot = titled(sections, "Loot")
    t.eq(slot_items(loot), "leather fur bone raw_meat gamey_meat")
    t.eq(slot_of(loot, "leather").count, "10-16")
    t.eq(table.concat(slot_of(loot, "leather").lines, " | "), "10 to 16")
    t.eq(slot_of(loot, "raw_meat").count, "2")
    t.eq(table.concat(slot_of(loot, "gamey_meat").lines, " | "), "3 to 5 | 10% chance")
    t.eq(slot_of(loot, "leather").dim, nil)
    local bee = titled(plain.tab("drops", "bee"), "Loot")
    t.eq(table.concat(slot_of(bee, "queen_bee").lines, " | "), "1 | 33.3% chance")
    t.eq(slot_of(bee, "queen_bee").count, nil, "one of a thing has no count")
end)

t.test("drops: a trophy is drawn as needing something and says what, bones say only that they are bones", function()
    local sections = plain.tab("drops", "forest_deer")
    local parts = titled(sections, "Trophy and bones")
    t.eq(slot_items(parts), "deer_head bone")
    local trophy = slot_of(parts, "deer_head")
    t.eq(trophy.dim, true)
    t.eq(trophy.mark, "trophy")
    t.eq(table.concat(trophy.lines, " | "), "Trophy | 1 | By a skinning chance that tools add")
    local bones = slot_of(parts, "bone")
    t.eq(bones.mark, "bone")
    t.eq(table.concat(bones.lines, " | "), "From its bones | 15 to 25")
    t.eq(parts.note[1], "Skinning gives a trophy by a chance that tools add, such as the Taxidermy Knife.")
    local foal = titled(plain.tab("drops", "horse", 3), "Trophy and bones")
    t.eq(slot_items(foal), "bone")
    t.eq(foal.note, nil, "no trophy, no note about one")
end)

t.test("drops: the knife is named by its own item, and left out when the game has none", function()
    local changed = fixture.copy()
    for position, row in ipairs(changed.ItemsStatic.rows) do
        if row.Name == "Taxidermy_Knife" then table.remove(changed.ItemsStatic.rows, position) end
    end
    local other = world({ tables = changed })
    t.eq(other.c.knife, nil)
    t.eq(titled(other.tab("drops", "forest_deer"), "Trophy and bones").note[1], "Skinning gives a trophy by a chance that tools add.")
end)

t.test("drops: a reward that needs a stat is a bonus, or the entry's own reward once the maps say so", function()
    local bacon = slot_of(titled(plain.tab("drops", "forest_wolf"), "Loot"), "raw_bacon")
    t.eq(bacon.dim, true)
    t.eq(table.concat(bacon.lines, " | "), "1 to 2 | 25% chance | Only with a bonus that adds it")
    bacon = slot_of(titled(served.tab("drops", "forest_wolf"), "Loot"), "raw_bacon")
    t.eq(bacon.lines[3], "Only with a reward of its Field Guide entry")
    local loot = titled(plain.tab("drops", "forest_wolf"), "Loot")
    t.eq(#loot.slots, 10, "ten rewards: two lines of five")
end)

t.test("drops: a carcass with its bench recipe, the arrow right after it; one without a recipe alone", function()
    local sections = plain.tab("drops", "forest_deer")
    local bench = titled(sections, "Carcass at the Skinning Bench")
    t.ok(bench, "titled by the station's own name: " .. all_text(sections))
    t.eq(bench.slots[1].item, "animalcarcass_deer")
    t.eq(bench.slots[2].arrow, true)
    t.eq(slot_of(bench, "leather").count, "30")
    t.eq(slot_of(bench, "raw_meat").count, "3")
    t.eq(titled(sections, "Carcass"), nil)
    local bear = titled(plain.tab("drops", "bear"), "Carcass")
    t.eq(slot_items(bear), "animalcarcass_bear", "no bench takes a bear's carcass")
    local early = world({ stages = 1 })
    t.eq(slot_items(titled(early.tab("drops", "forest_deer"), "Carcass")), "animalcarcass_deer", "before the recipes are read")
end)

t.test("drops: experience, the note under the last section, and the sentence when there is nothing", function()
    local sections = plain.tab("drops", "forest_deer")
    local gained = titled(sections, "Experience")
    t.eq(pair_of(gained, "Skinning"), "260 XP")
    t.eq(pair_of(gained, "Kill"), nil)
    t.eq(sections[#sections], gained)
    t.eq(gained.note[#gained.note], "Amounts and chances are before tools and talents.")
    t.eq(pair_of(titled(served.tab("drops", "forest_deer"), "Experience"), "Kill"), "520 XP", "a player's word: the note says it is before bonuses")

    local changed = fixture.copy()
    local bee = fixture.find(changed, "AISetup", "Bee")
    bee.Loot, bee.CreatureType = { RowName = "None" }, { RowName = "None" }
    local other = world({ tables = changed })
    local nothing = other.tab("drops", "bee")
    t.eq(#nothing, 1)
    t.eq(texts(nothing[1]), "The game lists no drops for it.")
    t.eq(nothing[1].note, nil)
end)

-- ---------------------------------------------------------------- Taming

t.test("taming: a trapped kind: the wild one is caught with a trap and its bait, and nothing says a young one is", function()
    local sections = plain.tab("taming", "forest_wolf")
    t.eq(texts(sections[1]), "It can be tamed.")
    t.eq(sections[1].title, nil)
    local wild = titled(sections, "Taming a wild one")
    t.eq(texts(wild), "A wild one is caught with a trap and its bait, in Forest or Grasslands.")
    t.eq(slot_items(wild), "snare_trap creaturebait_wolf")
    t.eq(titled(sections, "A young one"), nil, "its young come from breeding, which has a section of its own")
    local needs = titled(sections, "What taming takes")
    t.eq(pair_of(needs, "Taming time"), "10 min")
    t.eq(pair_of(needs, "Food wanted"), "25%")
    t.eq(pair_of(needs, "Shelter wanted"), nil, "0 in the row")
    t.eq(pair_of(needs, "Temperature wanted"), "10 to 40 degrees")
    t.eq(pair_of(needs, "Not while"), nil, "the wolf's row prohibits nothing")
    local breeding = titled(sections, "Breeding")
    t.eq(pair_of(breeding, "Gestation"), "25 min")
    t.eq(slot_items(breeding), "fertility_serum_wolf")
    local all = all_text(sections)
    for _, gone in ipairs({ "grows", "young one grows", "male", "needs are met", "Snare Trap with its bait catches one" }) do
        t.ok(not all:find(gone, 1, true), "nothing says '" .. gone .. "': " .. all)
    end
end)

t.test("taming: once tamed: the top level of its growth row, the orders in the enum's own words, what fits its slot", function()
    local sections = plain.tab("taming", "forest_wolf")
    local once = titled(sections, "Once tamed")
    t.eq(pair_of(once, "Top level"), "25")
    t.eq(pair_of(once, "Movement orders"), "Follow, Wander")
    t.eq(pair_of(once, "Comfortable at"), "8 to 35 degrees")
    t.eq(once.after[1], "Combat orders: Does not engage, Neutral, Aggressive", "too long for a pair: a sentence under the others")
    t.eq(once.text, nil)
    t.eq(texts(titled(sections, "For its saddle slot")), "No saddle fits it.")
    local feed = titled(sections, "Animal feed")
    t.eq(#feed.slots, 10)
    local rest = sections[#sections]
    t.eq(rest.title, nil, "the list goes on without a title")
    t.eq(#rest.slots, 5)
    t.eq(rest.note[1], "Items the game tags as animal feed.")
    t.eq(feed.note, nil, "the note is under the last of it")
end)

t.test("taming: a kind with young beside the adults, ridden: the chance, the needs, fourteen saddles", function()
    local sections = plain.tab("taming", "horse")
    t.eq(texts(sections[1]), "It can be tamed and ridden.")
    t.eq(titled(sections, "Taming a wild one"), nil)
    t.eq(texts(titled(sections, "A young one")), "A wild adult has a 50% chance of a young one with it.")
    local needs = titled(sections, "What taming takes")
    t.eq(pair_of(needs, "Taming time"), "15 min")
    t.eq(pair_of(needs, "Not while"), "Wet, Sleepy")
    t.eq(titled(sections, "Breeding"), nil, "the row has a gestation time; the game has no serum for it")
    local once = titled(sections, "Once tamed")
    t.eq(pair_of(once, "Top level"), "50")
    t.ok(all_text({ once }):find("Follow, Wander, Stand, Lie down", 1, true))
    t.eq(pair_of(once, "Comfortable at"), "-8 to 35 degrees")
    t.eq(pair_of(once, "Food"), nil, "a map")
    local saddles, at = titled(sections, "For its saddle slot")
    t.eq(#saddles.slots, 10)
    t.eq(saddles.slots[1].item, "saddle_standard")
    t.eq(sections[at + 1].title, nil)
    t.eq(#sections[at + 1].slots, 4)
    local with_maps = titled(served.tab("taming", "horse"), "Once tamed")
    t.eq(pair_of(with_maps, "Food"), "300, uses 240 an hour")
    t.eq(pair_of(with_maps, "Water"), "300, uses 120 an hour")
    t.eq(pair_of(with_maps, "Carries"), "200")
    t.eq(pair_of(with_maps, "Cargo slots"), "3")
end)

t.test("taming: a workshop animal comes tamed, shows no needs, and the figures follow the tamed variant chosen", function()
    local sections = plain.tab("taming", "dog")
    t.eq(texts(sections[1]), "It comes tamed from the Workshop.")
    t.eq(titled(sections, "What taming takes"), nil, "its row is the table's defaults")
    t.eq(titled(sections, "A young one"), nil)
    t.eq(slot_items(titled(sections, "For its saddle slot")), "dog_accessory_d")
    t.ok(all_text(sections):find("Does not engage, Neutral, Aggressive", 1, true))
    local small = plain.tab("taming", "dog", 2)
    t.eq(pair_of(titled(small, "Once tamed"), "Combat orders"), "Does not engage")
    t.eq(texts(titled(small, "For its saddle slot")), "No saddle fits it.")
    local skin = plain.tab("taming", "dog", 5)
    t.eq(slot_items(titled(skin, "For its saddle slot")), "dog_accessory_d", "one with no mount row shows the group's first")
end)

t.test("taming: a group with a tamed form and no way given says so, and a young one with no source says so", function()
    local changed = fixture.copy()
    for position, row in ipairs(changed.Tames.rows) do
        if row.Name == "Forest_Wolf" then table.remove(changed.Tames.rows, position) end
    end
    local horse = fixture.find(changed, "Tames", "Horse")
    horse.bAutomaticallySpawnJuvenileWithParent = false
    local other = world({ tables = changed })
    local wolf = other.tab("taming", "forest_wolf")
    t.eq(texts(wolf[1]), "The game has a tamed form of it. Its tables do not say how to tame it.")
    t.eq(titled(wolf, "What taming takes"), nil)
    t.eq(texts(titled(other.tab("taming", "horse"), "A young one")), "The game's tables do not say where a young one comes from.")
end)

-- ---------------------------------------------------------------- Where

t.test("where: the bestiary's biomes and maps, then a block a map and one for the outposts", function()
    local sections = plain.tab("where", "forest_deer")
    local found = titled(sections, "Found in")
    t.eq(pair_of(found, "Biomes"), "Forest, Arctic")
    t.eq(pair_of(found, "Maps"), "Olympus, Styx, Prometheus")
    local olympus = titled(sections, "Olympus")
    t.eq(pair_of(olympus, "Area levels"), "1 to 120")
    t.eq(pair_of(olympus, "Share"), "10 to 21%", "a short name, so it stands beside its figure: the note says what it is")
    t.eq(pair_of(olympus, "Areas"), "4")
    t.eq(olympus.note[1], "Share is its weight in an area's spawn list.")
    local styx = titled(sections, "Styx")
    t.eq(pair_of(styx, "Share"), "6 to 19%")
    t.eq(styx.note, nil, "the note is said once")
    t.eq(pair_of(titled(sections, "Prometheus"), "Area levels"), "30 to 90")
    t.eq(pair_of(titled(sections, "Outposts"), "Areas"), "3")
    t.eq(pair_of(titled(plain.tab("where", "forest_wolf"), "Prometheus"), "Share"), "29%", "one figure when least and most are the same")
    t.ok(not all_text(sections):find("missions", 1, true))
end)

t.test("where: the other sources as the tables state them, and one sentence when no spawn list names it", function()
    local boss = plain.tab("where", "alpha_wolf_boss")
    t.ok(all_text(boss):find("World boss. Its respawn time is 1 h.", 1, true), all_text(boss))
    local alpha = plain.tab("where", "alpha_wolf_boss", 2)
    t.ok(all_text(alpha):find("It is in the game's horde waves.", 1, true))
    t.ok(not all_text(alpha):find("World boss", 1, true), "the wild alpha is not the world boss")
    local tamed = plain.tab("where", "forest_wolf", 2)
    t.eq(texts(tamed[#tamed]), "The game's spawn lists do not name it.")
    t.ok(not all_text(tamed):find("raised", 1, true))
    local bee = plain.tab("where", "bee")
    t.eq(pair_of(titled(bee, "Found in"), "Biomes"), "Forest, Cave, Grasslands")
    t.ok(all_text(bee):find("Maps: Olympus, Styx, Prometheus, Elysium", 1, true), "a pair too long is a sentence: " .. all_text(bee))
    t.eq(texts(bee[#bee]), "The game's spawn lists do not name it.")
    local dog = plain.tab("where", "dog")
    t.eq(#dog, 1)
    t.eq(texts(dog[1]), "It comes from the Workshop.")

    local changed = fixture.copy()
    fixture.find(changed, "AutonomousSpawns", "Kea").AISetup = { Value = "Bee" }
    fixture.find(changed, "AISetup", "Bear").AdditionalAIToSpawn = { { RowName = "Bee" } }
    local other = world({ tables = changed })
    local last = other.tab("where", "bee")
    t.eq(texts(last[#last]), "The game also spawns it near players. | It spawns with Bear.")
end)

-- ---------------------------------------------------------------- About

t.test("about: without maps: the game's traits and the field guide's three texts, nothing made up", function()
    local sections = plain.tab("about", "forest_deer")
    t.eq(texts(titled(sections, "Traits")), "Critical Area: Head | Passive | Weak to Poison")
    local guide, at = titled(sections, "From the Field Guide")
    t.ok(texts(guide):find("^On Icarus, deer"))
    t.eq(#sections, at + 2, "a section a paragraph, the first with the title")
    t.eq(sections[at + 1].title, nil)
    t.eq(titled(sections, "Numbers"), nil)
    t.eq(titled(sections, "Resistances"), nil)
    t.eq(titled(sections, "Your Bestiary"), nil)
    local bear = plain.tab("about", "bear")
    t.eq(texts(titled(bear, "Named ones")), "Brutus, Grute | Roaming Beast | Tide-Gorged Bear")
    t.eq(texts(titled(plain.tab("about", "forest_wolf"), "Named ones")), "Mature Pack Wolf")
end)

t.test("about: nothing at all is one sentence", function()
    local changed = fixture.copy()
    local bee = fixture.find(changed, "BestiaryData", "Bee")
    bee.Traits, bee.Lore1, bee.Lore2, bee.Lore3 = {}, "", "  ", ""
    local other = world({ tables = changed })
    local sections = other.tab("about", "bee")
    t.eq(#sections, 1)
    t.eq(texts(sections[1]), "The game's Field Guide says nothing about it.")
end)

t.test("about: with maps and curves: the numbers at a level, speeds by the state's own name, senses in metres", function()
    local sections = served.tab("about", "forest_deer")
    local numbers = sections[1]
    t.eq(numbers.title, "At level 15", "it starts on the lowest middle level of its areas")
    t.eq(numbers.level.value, 15)
    t.eq(numbers.level.last, 120)
    t.eq(table.concat(numbers.level.quick, " "), "1 30 60 120", "the quick levels of the level row")
    t.eq(pair_of(numbers, "Health"), "325")
    t.eq(pair_of(numbers, "Damage"), nil, "the deer has no damage curve")
    t.eq(pair_of(numbers, "Attack speed"), nil, "no row says how often a deer hits")
    t.eq(pair_of(numbers, "Kill XP"), "520 XP", "the event's own XP while nobody has seen the level change it")
    t.eq(pair_of(numbers, "Found at levels"), "1 to 120", "over every map and the outposts")
    -- how often it hits, for the few whose growth row says so: BaseNPCMeleeAttacksPerMinute_+
    local dog = served.tab("about", "dog")[1]
    t.eq(pair_of(dog, "Attack speed"), "100 a minute")
    local order = {}
    for position, pair in ipairs(dog.pairs) do order[pair.name] = position end
    t.ok(order["Damage"] and order["Attack speed"] == order["Damage"] + 1, "right under its damage")
    t.eq(pair_of(numbers, "Walking"), nil, "health and damage stand under their own heading")
    t.eq(numbers.note[1], "A prospect can change health, damage and speed.")
    -- the speeds under a heading of their own, each named for what the animal is doing
    local speeds = sections[3]
    t.eq(speeds.title, "Speed")
    t.eq(speeds.level, nil)
    local named = {}
    for position, pair in ipairs(speeds.pairs) do named[position] = pair.name .. " " .. pair.value end
    t.eq(table.concat(named, " | "), "Sneaking 2.2 m/s | Walking 2.2 m/s | Jogging 4.4 m/s | Running 6.6 m/s | Sprinting 12 m/s | "
        .. "While attacking 4.4 m/s | While following 4.4 m/s | Swimming 3 m/s",
        "every moving state the row has, one as fast as another too; none it does not have, and not the two that are no movement")
    local senses = sections[2]
    t.eq(senses.title, "Senses", "the short one first: it fits on the page with the 3D view")
    t.eq(pair_of(senses, "Sight"), "50 m")
    t.eq(pair_of(senses, "Hearing"), "25 m")
    t.eq(#senses.pairs, 2)
    -- the names follow the game's own enum of movement states, so none is said of another state
    local enum = { [0] = "Undefined", "Stationary", "Sneak", "Walk", "Jog", "Run", "Sprint", "Attacking", "Following" }
    for number = 0, 8 do t.eq(creatures.STATES[number], enum[number], "EMovementState " .. number) end
    for _, state in ipairs(pages.STATES) do
        t.eq(creatures.MOVING[state], true, state .. " is listed and is a state it moves in")
        t.ok(beasts.about.states[state] and beasts.about.states[state]:find("ing"), state .. " has a player's word")
    end
    t.eq(creatures.MOVING.Stationary, nil)
    t.eq(creatures.MOVING.Undefined, nil)
    local at_28 = served.tab("about", "forest_deer", 1, { level = 28, here = 49.9 })[1]
    t.eq(at_28.title, "At level 28")
    t.eq(at_28.level.value, 28, "the level row follows the level that shows")
    t.eq(pair_of(at_28, "Health"), "347")
    t.eq(at_28.note[1], "In this prospect creatures have 50% of this health.")
    t.eq(served.tab("about", "forest_deer", 1, { level = 900 })[1].title, "At level 120", "held to its last level")
    t.eq(served.tab("about", "forest_deer", 1, { level = -4 })[1].title, "At level 1", "and never under 1")
    local wolf = served.tab("about", "forest_wolf")
    t.eq(pair_of(wolf[3], "While attacking"), "9 m/s", "the state it is fastest in is listed under its own name")
    t.eq(pair_of(wolf[3], "Sprinting"), "7.5 m/s")
    t.ok(pair_of(wolf[1], "Damage") ~= nil)
end)

t.test("about: a trait says the figure a stat of the creature stands behind, in the game's order", function()
    local deer = titled(served.tab("about", "forest_deer"), "Traits")
    t.eq(texts(deer), "Critical Area: Head | Passive | Weak to Poison: -50%")
    t.eq(deer.note[1], "A percent is its resistance to that damage.")
    t.eq(deer.note[2], "A hit there is a critical hit. A new character's Critical Damage is +300%: the area counts all, half or 15% of it.",
        "what the rows hold of a critical hit: no row says which kind of area a creature's head is")
    t.eq(titled(served.tab("about", "forest_deer"), "Resistances"), nil, "said with the trait, so not said again")
    -- a figure a row gives by level follows the level row
    local low = titled(served.tab("about", "forest_wolf", 1, { level = 1 }), "Traits")
    t.ok(texts(low):find("| Inflicts Wound$"), "no chance at level 1, so the trait alone: " .. texts(low))
    local high = titled(served.tab("about", "forest_wolf", 1, { level = 60 }), "Traits")
    t.ok(texts(high):find("Inflicts Wound: 30.7% chance", 1, true), texts(high))
    -- the tamed wolf resists the poison its wild form is weak to: the trait keeps no figure, the resistance is listed
    local tamed = served.tab("about", "forest_wolf", 2)
    t.ok(texts(titled(tamed, "Traits")):find("Weak to Poison$") or texts(titled(tamed, "Traits")):find("Weak to Poison |", 1, true),
        texts(titled(tamed, "Traits")))
    t.ok(texts(titled(tamed, "Resistances")):find("Poison Resistance: +40%", 1, true),
        "what it is of, then how much: " .. texts(titled(tamed, "Resistances")))
    t.ok(not texts(titled(tamed, "Resistances")):find("+40 Poison Resistance", 1, true), "not the game's bare '+40 Poison Resistance'")
    t.ok(texts(titled(tamed, "Resistances")):find("+10% chance to Resist Slow", 1, true), "a sentence with no figure to take out stays the game's")
    -- without maps there is no figure and no note about one
    local plain_deer = titled(plain.tab("about", "forest_deer"), "Traits")
    t.eq(texts(plain_deer), "Critical Area: Head | Passive | Weak to Poison")
    t.eq(plain_deer.note, nil)
end)

t.test("about: the rest of its stats in the game's own sentences, none said twice", function()
    local sections = served.tab("about", "forest_deer")
    local others = titled(sections, "Other stats")
    t.ok(texts(others):find("+10 Health Regeneration per Minute", 1, true), texts(others))
    t.ok(texts(others):find("175kg Character Mass", 1, true), texts(others))
    t.ok(not texts(others):find("Movement Speed", 1, true), "its speed is said as metres a second: " .. texts(others))
    t.ok(not texts(others):find("Swimming", 1, true), texts(others))
    t.ok(not all_text(sections):find("Poison Resistance", 1, true), "the trait said it")
    local horse = titled(served.tab("about", "horse", 2), "Other stats")
    t.ok(not texts(horse):find("Food", 1, true), "a tamed one's food and water are on Taming: " .. texts(horse))
end)

t.test("about: a tamed one's level row ends at its top level", function()
    local mount = served.tab("about", "horse", 2)[1]
    t.eq(mount.title, "At level 1", "no spawn area: it starts at 1")
    t.eq(mount.level.last, 50)
    t.eq(table.concat(mount.level.quick, " "), "1 15 30 50")
    t.eq(pair_of(mount, "Health"), "912")
    local top = served.tab("about", "horse", 2, { level = 60 })[1]
    t.eq(top.title, "At level 50")
    t.eq(pair_of(top, "Health"), "1,500")
    t.eq(pair_of(top, "Damage"), "58")
    t.eq(table.concat(served.tab("about", "forest_wolf", 2)[1].level.quick, " "), "1 10 20 25")
    t.eq(served.tab("about", "forest_wolf", 2, { level = 28 })[1].level.value, 25, "a level picked on another creature is pulled into its own")
end)

t.test("about: resistances, attacks, named forms and the entry's rewards in the game's own sentences", function()
    local tamed = served.tab("about", "forest_wolf", 2)
    local resists = titled(tamed, "Resistances")
    t.eq(#resists.text, 8, texts(resists))
    t.ok(texts(resists):find("Explosive", 1, true) and texts(resists):find("Fall", 1, true), texts(resists))
    local boss = served.tab("about", "alpha_wolf_boss")
    t.ok(texts(titled(boss, "Traits")):find("Inflicts Wound: 50% chance", 1, true), texts(titled(boss, "Traits")))
    t.eq(titled(boss, "Its attacks"), nil, "the trait says it, so it is not said again")
    local bear = served.tab("about", "bear")
    local named = titled(bear, "Named ones")
    t.eq(named.text[1], "Brutus, Grute", "a named form whose row adds nothing is only its names")
    t.ok(named.text[2]:find("^Roaming Beast %- ") and named.text[2]:find("300", 1, true), named.text[2])
    t.ok(not named.text[2]:find("CreatureDisplayBossMapIcon", 1, true), "a stat the game does not word is left out")
    local rewards = titled(bear, "Its Field Guide entry gives")
    t.eq(#rewards.text, 2, texts(rewards))
    t.ok(texts(rewards):find("Deep Wound", 1, true), texts(rewards))
end)

t.test("about: the player's progress is points of a total, shown only when it is given", function()
    t.eq(titled(plain.tab("about", "forest_deer"), "Your Bestiary"), nil)
    local with = plain.tab("about", "forest_deer", 1, { progress = 75 })
    t.eq(texts(titled(with, "Your Bestiary")), "75 of 1,800 points")
end)

-- ---------------------------------------------------------------- never a blank, never the word nil

t.test("every section of every creature, tab and variant is sound, with maps refused and with maps served", function()
    local count = 0
    for _, w in ipairs({ plain, served }) do
        for _, entry in ipairs(w.c.list) do
            for position = 1, #entry.variants do
                for _, tab in ipairs(pages.TABS) do
                    for _, more in ipairs({ {}, { level = 1 }, { level = 150, here = 37, progress = 0 } }) do
                        local where = entry.id .. " #" .. position .. " " .. tab .. (w == served and " (maps)" or "")
                        sound(w.tab(tab, entry.id, position, more), where, w.m)
                        count = count + 1
                    end
                end
            end
            local head = w.page.head(entry)
            t.ok(head.name:find("%S") and head.word.text:find("%S") and not head.facts:find("nil", 1, true))
            for _, look in ipairs({ w.page.cell(entry), w.page.cell(entry, { kept = true, internal = true, outside = true }) }) do
                t.ok(look.tip.title:find("%S"))
                for _, line in ipairs(look.tip.lines) do
                    local words = type(line) == "table" and line[1] or line
                    t.ok(type(words) == "string" and words:find("%S") and not words:find("%f[%a]nil%f[%A]"), entry.id .. " tip: " .. tostring(words))
                end
            end
        end
    end
    t.eq(count, 2 * 22 * 4 * 3)
end)

-- ---------------------------------------------------------------- sections into pages

t.test("pack: pages never pass the budget and never hold more than eight sections, with everything in order", function()
    local checked = 0
    for _, w in ipairs({ plain, served }) do
        for _, entry in ipairs(w.c.list) do
            for _, tab in ipairs(pages.TABS) do
                for _, budget in ipairs({ 373, 617 }) do
                    local sections = w.tab(tab, entry.id, 1)
                    local packed = pages.pack(sections, budget)
                    local function letters_of(section)
                        local count = 0
                        for _, key in ipairs({ "text", "after", "note" }) do
                            for _, words in ipairs(section[key] or {}) do count = count + #words:gsub("%s", "") end
                        end
                        return count
                    end
                    local slots, pairs_seen, letters = 0, 0, 0
                    for at, held in ipairs(packed) do
                        local tall = 0
                        t.ok(#held >= 1 and #held <= pages.MOST, entry.id .. " " .. tab .. " page " .. at .. " holds " .. #held)
                        for _, section in ipairs(held) do
                            tall = tall + pages.height(section)
                            slots, pairs_seen = slots + #(section.slots or {}), pairs_seen + #(section.pairs or {})
                            letters = letters + letters_of(section)
                        end
                        t.ok(tall <= budget, entry.id .. " " .. tab .. " page " .. at .. " is " .. tall .. " of " .. budget)
                    end
                    local want_slots, want_pairs, want_letters = 0, 0, 0
                    for _, section in ipairs(sections) do
                        want_slots, want_pairs = want_slots + #(section.slots or {}), want_pairs + #(section.pairs or {})
                        want_letters = want_letters + letters_of(section)
                    end
                    t.eq(slots, want_slots, "no slot is lost")
                    t.eq(pairs_seen, want_pairs, "no pair is lost")
                    t.eq(letters, want_letters, "no letter is lost")
                    checked = checked + 1
                end
            end
        end
    end
    t.eq(checked, 2 * 7 * 4 * 2)
end)

t.test("pack: a text too tall for a page goes on in sections without a title, cut after a sentence", function()
    local long = {}
    for index = 1, 60 do long[index] = "Sentence number " .. index .. " of a long text." end
    local sections = { { title = "From the Field Guide", text = { table.concat(long, " ") } }, { title = "After", pairs = { { name = "A", value = "1" } } } }
    local packed = pages.pack(sections, 373)
    t.ok(#packed >= 2, "it takes more than one page")
    t.eq(packed[1][1].title, "From the Field Guide")
    t.eq(packed[2][1].title, nil)
    t.ok(packed[1][1].text[1]:find("%.$"), "the cut is after a sentence")
    local last = packed[#packed]
    t.eq(last[#last].title, "After")
    t.eq(pages.height({ title = "T", pairs = { { name = "a", value = "b" }, { name = "c", value = "d" } } }), 8 + 14 + 32)
    t.eq(pages.height({ slots = { {}, {}, {}, {}, {}, {} } }), 8 + 2 * 42, "six slots are two lines")
end)

t.test("pack: a section's own lists are never torn mid-line, and a level row costs its two rows", function()
    local numbers = served.tab("about", "forest_deer")[1]
    t.eq(pages.height(numbers) > pages.height({ title = numbers.title, pairs = numbers.pairs, note = numbers.note }), true)
    local packed = pages.pack({ numbers }, 617)
    t.eq(packed[1][1].level.value, 15, "the level row stays with its numbers")
end)

t.test("levels: the quick levels for where a creature's levels end", function()
    t.eq(table.concat(pages.levels(25), " "), "1 10 20 25")
    t.eq(table.concat(pages.levels(50), " "), "1 15 30 50")
    t.eq(table.concat(pages.levels(120), " "), "1 30 60 120")
    t.eq(table.concat(pages.levels(150), " "), "1 50 100 150")
    t.eq(table.concat(pages.levels(90), " "), "1 30 60 90")
    t.eq(table.concat(pages.levels(1), " "), "1")
    t.eq(table.concat(pages.levels(nil), " "), "1")
end)

-- ---------------------------------------------------------------- the words

t.test("words: the tabs at the top, the count line and the keys line", function()
    t.eq(beasts.side("beasts"), "Bestiary")
    t.eq(beasts.side("beasts", 3), "Bestiary (3)")
    t.eq(beasts.side("items", 1200), "Items (1,200)")
    t.eq(plain.page.count_line(107), "107 creatures")
    t.eq(plain.page.count_line(1), "1 creature")
    t.eq(plain.page.count_line(35, "hostile"), "Hostile - 35 creatures")
    t.eq(plain.page.count_line(0, nil, "xyz"), 'Nothing matches "xyz".')
    t.eq(plain.page.count_line(0, "ridden"), "Can be ridden - 0 creatures")
    t.eq(plain.page.count_line(64, nil, nil, "Leather"), "Drops Leather - 64 creatures")
    t.eq(beasts.keys({ make = "R", used = "U", favourite = "A" }), "R opens it - U its drops - A favourite")
    t.eq(beasts.keys({ make = "R" }), "R opens it")
    t.eq(beasts.keys(nil), "")
    t.eq(beasts.dropped_by(1), "Dropped by 1 creature")
    t.eq(text.beasts, beasts, "the words are kept on the mod's text table")
end)

t.test("words: figures say what the row says, rounded the plain way", function()
    t.eq(beasts.amount(10, 16), "10 to 16")
    t.eq(beasts.amount(2, 2), "2")
    t.eq(beasts.stack(1, 1), nil)
    t.eq(beasts.stack(1500, 2500), "1.5k-2.5k")
    t.eq(beasts.chance(33.299999237061), "33.3% chance")
    t.eq(beasts.speed(220), "2.2 m/s")
    t.eq(beasts.speed(1199), "12 m/s")
    t.eq(beasts.metres(5000), "50 m")
    t.eq(beasts.xp(1500), "1,500 XP")
    t.eq(beasts.range(-8, 35, "degrees"), "-8 to 35 degrees")
    t.eq(beasts.range(1, 120), "1 to 120")
    t.eq(beasts.share(5.26, 16.67), "5 to 17%")
    t.eq(beasts.share(0.2, 0.4), "under 1%")
    t.eq(beasts.share(0.2, 3.6), "1 to 4%")
    t.eq(beasts.here(49.9), "In this prospect creatures have 50% of this health.")
    t.eq(beasts.here(84), "In this prospect creatures have 85% of this health.")
    t.eq(beasts.points(75, 1800), "75 of 1,800 points")
    t.eq(beasts.uses(300, 240), "300, uses 240 an hour")
    t.eq(beasts.uses(100, 0), "100")
    t.eq(beasts.boss(3600), "World boss. Its respawn time is 1 h.")
    t.eq(beasts.boss(0), "World boss.")
    t.eq(beasts.with({ "Mange Wolf Alpha" }), "It spawns with Mange Wolf Alpha.")
    t.eq(beasts.trap({ "Tundra" }, false), "A wild one is caught with a trap, in Tundra.")
    t.eq(beasts.trap({ "Forest", "Grasslands", "Tundra" }, true), "A wild one is caught with a trap and its bait, in Forest, Grasslands or Tundra.")
    t.eq(beasts.bench("Skinning Bench"), "Carcass at the Skinning Bench")
    t.eq(beasts.bench(nil), "Carcass")
    t.eq(beasts.role("Juvenile Terrenus", "young"), "Juvenile Terrenus - Young")
end)

t.test("words: the search knows the same words the page shows", function()
    local words = beasts.search_words()
    t.eq(words.hostile, beasts.words.hostile)
    t.eq(words.tamed, beasts.facts.tamed)
    t.eq(words.attacks, beasts.facts.attacks)
    t.eq(words.meat, beasts.diets.meat)
    local found = {}
    for position, entry in ipairs(creatures.filter(plain.c, { "can", "be", "ridden" })) do found[position] = entry.id end
    t.eq(table.concat(found, " "), "horse")
end)

t.finish("recipe-creature-page")
