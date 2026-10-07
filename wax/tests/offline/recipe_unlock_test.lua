-- Offline tests for the Recipe Browser's needs line: tier, node, level, pack, mission, talent.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\recipe_unlock_test.lua luamods\RecipeBrowser

local t = dofile("wax/tests/offline/harness.lua")

local folder = arg and arg[1]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end

local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
end

if not folder or not exists(folder .. "/unlock.lua") or not exists(folder .. "/model.lua") then
    print("recipe-unlock: 0 passed (skipped: Recipe Browser is not here)")
    os.exit(0)
end

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

local source, tags, model, unlock = part("source"), part("tags"), part("model"), part("unlock")
local fixture = dofile("wax/tests/offline/recipe_fixture.lua")

-- The texts of the plan, in the shape text.lua gives them, so a change of wording there does not fail this suite.
local function make_text()
    local text = { needs = {
        known = "known from the start",
        mission_only = "only during a mission",
        no_talent = "cannot be made in this version of the game",
        no_station = "cannot be made",
        level = function(level) return "level " .. level end,
        pack = function(name) return "needs " .. name end,
        mission = function(name) return "needs " .. name .. " finished" end,
        talent = function(name) return "needs talent " .. name end,
    } }
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
        return table.concat(parts, " - ")
    end
    return text
end

local text = make_text()

local function world(tables, pause)
    local provider = fixture.serve(tables or fixture.tables)
    local src = source.new(provider)
    src.read_all(1)
    local m = model.build(src, nil, string.lower, tags)
    local index = unlock.index(src, pause, text)
    return { provider = provider, src = src, m = m, index = index }
end

local w = world()

local function needs(name, from)
    from = from or w
    local number = from.m.recipe[name]
    assert(number, "the fixture has no recipe " .. name)
    return unlock.describe(from.index, from.m, from.m.recipes[number])
end

t.test("case: a node named through ExtraData, in a tier with a level", function()
    local line = needs("gear")
    t.eq(line.short, "Tier 3 - Gear - level 20")
    t.eq(line.full, "Tier 3 - Gear - level 20")
    t.eq(line.extra, "")
    t.eq(line.tone, "dim")
    t.eq(line.tier, "Tier 3")
    t.eq(line.level, 20)
    t.eq(line.node, "Gear")
    t.eq(line.missing, false)
end)

t.test("case: a node with its own DisplayName, and the larger of node and tier level", function()
    local line = needs("timber_wall")
    t.eq(line.short, "Tier 2 - Timber Wall Set - level 15")
    t.eq(line.full, "Tier 2 - Timber Wall Set - level 15")
    t.eq(line.level, 15)
    t.eq(needs("nails").level, 10, "the tier's level when the node has none")
    t.eq(needs("nails").short, "Tier 2 - Nails - level 10")
end)

t.test("case: a node that is known from the start", function()
    local line = needs("stone_knife")
    t.eq(line.short, "Tier 1 - Stone Knife - known from the start")
    t.eq(line.full, line.short)
    t.eq(line.start, true)
    t.eq(line.tone, "dim")
    t.eq(needs("hearth").short, "Tier 1 - Hearth", "tier 1 has no level to print")
end)

t.test("case: the node and the recipe both ask for one pack, which is named once", function()
    local line = needs("rug")
    t.eq(line.extra, "needs Harvest Decor Pack")
    t.eq(#line.packs, 1)
    t.eq(line.full, "Tier 2 - Harvest Decor Pack - level 10")
    t.eq(line.short, "Tier 2 - level 10", "the node is named like the pack, so the short form leaves it out")
    t.eq(line.tone, "warn")
end)

t.test("case: a node behind an account flag names the mission that rewards it", function()
    local line = needs("bone_saw")
    t.eq(line.short, "Tier 2 - Bone Saw - level 10")
    t.eq(line.extra, "needs DEEP DIVE finished")
    t.eq(line.missions[1], "DEEP DIVE")
    t.eq(line.tone, "warn")
end)

t.test("case: a character flag names the talent that grants it", function()
    local line = needs("bulk_nails")
    t.eq(line.short, "Tier 2 - Nails - level 10")
    t.eq(line.extra, "needs talent Nail Saver")
    t.eq(line.talents[1], "Nail Saver")
    local node = needs("twig_split")
    t.eq(node.short, "Tier 1 - Twig")
    t.eq(node.extra, "needs talent Wood Sense", "the flag is on the node, and the talent's second reward grants it")
end)

t.test("case: a recipe with a session flag", function()
    local line = needs("signal_fire")
    t.eq(line.extra, "only during a mission")
    t.eq(line.mission_only, true)
    t.eq(line.short, "")
    t.eq(line.tone, "warn")
end)

t.test("case: no requirement, so the tier of the lowest bench", function()
    local line = needs("baked_fish")
    t.eq(line.short, "Tier 1", "Hearth is tier 1, Big Hearth tier 2")
    t.eq(line.full, "Tier 1")
    t.eq(line.tier, "Tier 1")
    t.eq(line.level, nil)
    t.eq(line.extra, "")
    t.eq(needs("seed_mash").short, "Tier 1", "its first station is tier 3, its second tier 1")
    t.eq(needs("dough").short, "", "no recipe makes its bench")
    t.eq(needs("butcher_trout").short, "", "by hand")
    t.eq(needs("dough").tier, nil)
end)

t.test("case: a requirement that names a talent the game does not have", function()
    local line = needs("old_charm")
    t.eq(line.missing, true)
    t.eq(line.short, "cannot be made in this version of the game")
    t.eq(line.full, line.short)
    t.eq(line.tone, "bad")
end)

t.test("case: a recipe with no station", function()
    local line = needs("brick")
    t.eq(line.short, "cannot be made")
    t.eq(line.full, "cannot be made")
    t.eq(line.tone, "bad")
    t.eq(line.missing, false)
    t.ok(needs("trade_ruby").short ~= "cannot be made", "a hidden bench is still a station")
end)

t.test("a recipe the game switched off reads the same", function()
    local line = unlock.describe(w.index, w.m, { id = "off", disabled = true, stations = { "hearth" }, sets = { "hearth" } })
    t.eq(line.short, "cannot be made")
end)

t.test("pack, mission, session and talent parts keep that order", function()
    local line = unlock.describe(w.index, w.m, { id = "all", talent = "bone_saw", session = "harvest", char_flag = "talent_bulk_nails",
        stations = { "work_table" }, sets = { "work_table" } })
    t.eq(line.extra, "needs Harvest Decor Pack - needs DEEP DIVE finished - needs talent Nail Saver")
    local both = unlock.describe(w.index, w.m, { id = "both", talent = "decor_set", session = "mission_signal",
        stations = { "work_table" }, sets = { "work_table" } })
    t.eq(both.extra, "needs Harvest Decor Pack - only during a mission")
end)

t.test("describe before the index exists gives empty texts", function()
    local line = unlock.describe(nil, w.m, w.m.recipes[1])
    t.eq(line.short, "")
    t.eq(line.full, "")
    t.eq(line.extra, "")
    t.eq(line.missing, false)
    t.eq(unlock.describe(w.index, w.m, nil).short, "")
end)

t.test("describe asks the provider nothing, and the second answer is the first", function()
    local fresh = world()
    local before = fresh.provider.calls
    local first = {}
    for number, recipe in ipairs(fresh.m.recipes) do first[number] = unlock.describe(fresh.index, fresh.m, recipe) end
    t.eq(fresh.provider.calls, before, "no provider call while describing")
    for number, recipe in ipairs(fresh.m.recipes) do
        t.ok(unlock.describe(fresh.index, fresh.m, recipe) == first[number], recipe.id .. " comes from the cache")
    end
    t.eq(fresh.provider.calls, before)
    t.ok(#fresh.m.recipes > 20)
end)

t.test("index pauses every PAUSE_ROWS talents", function()
    local kept = unlock.PAUSE_ROWS
    t.eq(kept, 150)
    local pauses = 0
    unlock.PAUSE_ROWS = 3
    local ok, err = pcall(world, nil, function() pauses = pauses + 1 end)
    unlock.PAUSE_ROWS = kept
    t.ok(ok, err)
    t.eq(pauses, 4, "twelve talents, three at a time")
    pauses = 0
    world(nil, function() pauses = pauses + 1 end)
    t.eq(pauses, 0)
end)

t.test("a flag's table is found by its name, never from the handle", function()
    t.eq(w.index.flags.harvest, "DLCPackageData")
    t.eq(w.index.flags.granted_bone_saw, "AccountFlags")
    t.eq(w.index.flags.mission_signal, "SessionFlags")
    t.eq(w.index.flags.talent_bulk_nails, "CharacterFlags")
    t.eq(#w.index.clashes, 0)
    t.eq(w.index.grants.talent_twig_split, "skill_wood")
    t.eq(w.index.grants.none, nil, "an empty handle grants nothing")
end)

t.test("a name in two flag tables is noted, and the first table keeps it", function()
    local tables = fixture.copy()
    tables.SessionFlags.rows[#tables.SessionFlags.rows + 1] = { Name = "HARVEST" }
    local other = world(tables)
    t.eq(#other.index.clashes, 1)
    t.eq(other.index.clashes[1].row, "Harvest")
    t.eq(table.concat(other.index.clashes[1].tables, " "), "SessionFlags DLCPackageData")
    t.eq(other.index.flags.harvest, "SessionFlags")
end)

t.test("when a needs table is missing every line is empty, not a claim about the recipe", function()
    local tables = fixture.copy()
    tables.Talents = nil
    local other = world(tables)
    t.ok(other.index.off)
    t.eq(needs("gear", other).short, "")
    t.eq(needs("old_charm", other).missing, false)
    t.eq(#other.m.recipes, #w.m.recipes, "the model is as before")
end)

t.test("index reads only loaded rows of listed fields", function()
    local fresh = world()
    local reader = source.new(fresh.provider)
    reader.read_all(1)
    local before = fresh.provider.calls
    local index = unlock.index(reader, nil, text)
    t.eq(fresh.provider.calls, before, "every table it joins was loaded whole")
    t.eq(index.talents.gear.name, "Gear")
    t.eq(index.talents.gear.tier, "Tier 3")
    t.eq(index.talents.gear.tier_level, 20)
    t.eq(index.talents.wall_set.level, 15)
    t.eq(index.talents.stone_knife.start, true)
    t.eq(index.packs.far_lands, "Far Lands Expansion", "pack names are trimmed")
end)

t.test("index says which text piece it lacks", function()
    local broken = make_text()
    broken.needs.mission = nil
    t.raises(function() unlock.index(w.src, nil, broken) end, "text.needs.mission")
    t.raises(function() unlock.index(w.src, nil, nil) end, "text table")
    t.raises(function() unlock.index(w.src, nil, { needs = broken.needs }) end, "text table")
end)

t.test("a kept index takes a new text table, and holds nothing else that is not a plain value", function()
    local fresh = world()
    local first = unlock.describe(fresh.index, fresh.m, fresh.m.recipes[fresh.m.recipe.gear])
    local other = make_text()
    other.needs.level = function(level) return "lvl " .. level end
    t.eq(unlock.rebind(fresh.index, other), fresh.index)
    local second = unlock.describe(fresh.index, fresh.m, fresh.m.recipes[fresh.m.recipe.gear])
    t.ok(second ~= first, "the lines are made again")
    t.eq(second.short, "Tier 3 - Gear - lvl 20")
    t.raises(function() unlock.rebind(fresh.index, {}) end, "text table")
    local seen = {}
    local function walk(value, where)
        local kind = type(value)
        t.ok(kind ~= "function" and kind ~= "userdata" and kind ~= "thread", where .. " holds a " .. kind)
        if kind ~= "table" or seen[value] then return end
        seen[value] = true
        for key, inner in pairs(value) do walk(inner, where .. "." .. tostring(key)) end
    end
    for key, value in pairs(fresh.index) do
        if key ~= "pieces" and key ~= "join" then walk(value, "index." .. key) end
    end
end)

t.test("text pieces may be patterns in place of functions", function()
    local plain = make_text()
    plain.needs.level, plain.needs.pack = "level %d", "needs %s"
    local index = unlock.index(w.src, nil, plain)
    local line = unlock.describe(index, w.m, w.m.recipes[w.m.recipe.rug])
    t.eq(line.full, "Tier 2 - Harvest Decor Pack - level 10")
    t.eq(line.extra, "needs Harvest Decor Pack")
end)

if exists(folder .. "/text.lua") then
    t.test("the mod's own text.lua has every piece and gives the plan's lines", function()
        local real = part("text")
        local index = unlock.index(w.src, nil, real)
        local function line(name) return unlock.describe(index, w.m, w.m.recipes[w.m.recipe[name]]) end
        t.eq(line("gear").short, "Tier 3 - Gear - level 20")
        t.eq(line("stone_knife").short, "Tier 1 - Stone Knife - known from the start")
        t.eq(line("rug").extra, "needs Harvest Decor Pack")
        t.eq(line("bone_saw").extra, "needs DEEP DIVE finished")
        t.eq(line("signal_fire").extra, "only during a mission")
        t.eq(line("bulk_nails").extra, "needs talent Nail Saver")
        t.eq(line("old_charm").short, "cannot be made in this version of the game")
        t.eq(line("brick").short, "cannot be made")
    end)
end

-- a copy of the mod from before it had a research line has neither
local research_words = exists(folder .. "/text.lua") and part("text").research
if unlock.research and research_words then
    -- A plan as game.Research gives it, for a node of level 25 that needs `count` points.
    local function plan(count, fields)
        local out = { node = "shotgun", name = "Shotgun", unlocked = false, default = false, level = 25, steps = {}, points = count,
            available = 11, player_level = 30, needed_level = 25, can = true, blocked = false }
        local names = { "Machining Bench", "Cement Mixer", "Shotgun Shell Casing", "Shotgun" }
        for at = 1, count do out.steps[at] = { node = "n" .. at, name = names[#names - count + at], level = 20 } end
        for key, value in pairs(fields or {}) do out[key] = value end
        return out
    end
    local function told(count, fields) return unlock.research(plan(count, fields), research_words) end

    t.test("research: nothing for a recipe with no node, a node known from the start, and one the game holds back", function()
        t.eq(unlock.research(nil, research_words), nil)
        t.eq(told(0, { unlocked = true, default = true }), nil)
        t.eq(told(1, { can = false, blocked = true }), nil, "the needs line already names the pack or the mission")
        t.eq(told(3, { can = false, blocked = true }), nil)
    end)

    t.test("research: researched, one step, and several steps with what is asked first", function()
        t.eq(told(0, { unlocked = true }).kind, "done")
        t.eq(told(0, { unlocked = true }).line, "Researched")
        local one = told(1)
        t.eq(one.kind, "buy")
        t.eq(one.caption, "Research (1 point)")
        t.eq(one.ask, "This spends 1 point.", "a press is always asked about first")
        t.eq(one.confirm, "Research")
        local three = told(3)
        t.eq(three.kind, "buy")
        t.eq(three.caption, "Research (3 points)")
        t.eq(three.ask, "Researches Cement Mixer and Shotgun Shell Casing first. 3 points in all.")
        t.eq(three.confirm, "Research all")
    end)

    t.test("research: the level comes before the points, and each says what is missing", function()
        local low = told(3, { player_level = 20, available = 0, can = false })
        t.eq(low.kind, "level")
        t.eq(low.line, "Unlocks at level 25")
        local poor = told(3, { available = 1, can = false })
        t.eq(poor.kind, "points")
        t.eq(poor.line, "Needs 3 points")
        t.eq(poor.caption, "Research (3 points)", "the button shows what it costs and cannot be pressed")
        t.eq(told(3, { available = 3 }).kind, "buy")
    end)
end

t.finish("recipe-unlock")
