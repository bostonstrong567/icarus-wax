-- Builds the Bestiary's model on the game's real tables and compares it with what scripts\creature_check.py worked
-- out on its own, then reads every section of every creature's page for a blank or a "nil".
-- Run from the workspace root, after the Python:
--   tools\lua\lua54\lua.exe wax\tests\offline\recipe_creature_data_check.lua <mod folder> build\creature-browser\check

local folder, check = arg and arg[1], arg and arg[2]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end
if check then check = check:gsub("\\", "/"):gsub("/+$", "") end

local function file_exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
end

local function skip(why)
    print("creature-data: 0 passed (skipped: " .. why .. ")")
    os.exit(0)
end

if not folder or not file_exists(folder .. "/creatures.lua") then skip("the Bestiary's creatures.lua is not here") end
if not check or not file_exists(check .. "/tables.lua") or not file_exists(check .. "/expected.lua") then
    skip("run python scripts\\creature_check.py first")
end

local fixture = dofile("wax/tests/offline/creature_fixture.lua")
local part = fixture.parts(folder)
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
    if got == want then passed = passed + 1 else differ(group, what, got, want, where) end
end

local function figure(value)
    if value == nil or value == "" then return "" end
    return ("%.6g"):format(value)
end

local function joined(list, separator) return table.concat(list or {}, separator or " ") end

local function names_of(list)
    local out = {}
    for position, entry in ipairs(list or {}) do out[position] = entry.name end
    return table.concat(out, ", ")
end

local function drops_text(drops)
    local out = {}
    for position, drop in ipairs(drops or {}) do
        out[position] = ("%s %s-%s %s%s"):format(drop.item, figure(drop.min), figure(drop.max), figure(drop.chance),
            drop.needs and (" " .. drop.needs) or "")
    end
    return table.concat(out, ", ")
end

local function block_text(block, name)
    if not block then return "" end
    return ("%s %d %s-%s %.6f-%.6f %s"):format(name or block.name, block.count, figure(block.low), figure(block.high),
        block.share_low, block.share_high, figure(block.median))
end

local function mount_text(mount)
    if not mount then return "" end
    local comfortable = mount.comfortable and (figure(mount.comfortable.low) .. ".." .. figure(mount.comfortable.high)) or ""
    return table.concat({ mount.row, mount.pet and "pet" or "", figure(mount.top), joined(mount.orders), joined(mount.combat),
        comfortable, joined(mount.saddles), mount.ridden and "ridden" or "" }, " | ")
end

local function tame_text(tame)
    if not tame then return "" end
    if not tame.row then return "-" end
    return table.concat({ tame.row, figure(tame.young), figure(tame.grown), figure(tame.becomes), figure(tame.seconds),
        figure(tame.nutrition), figure(tame.shelter), figure(tame.cold), figure(tame.hot), joined(tame.not_while, ", "),
        figure(tame.beside), joined(tame.trap_in, ", "), tame.bait or "", tame.serum or "", figure(tame.gestation) }, " | ")
end

-- the mod, on the same tables, with maps and curves refused as the game refuses them today

local built, c, m, src = pcall(fixture.build, part, fixture.serve(tables), { words = E.words, stages = 2 })
if not built then
    io.stderr:write("DIFF the creature model could not be built on the game's tables: " .. tostring(c) .. "\n")
    print("creature-data: 0 passed, 1 failed")
    os.exit(1)
end

for _, problem in ipairs(src.problems) do
    differ("source", "D_" .. problem.table .. (problem.field and ("." .. problem.field) or ""), "a problem", "none", problem.message)
end
for name in pairs(c.off) do differ("off", "the part '" .. name .. "'", "off", "on", "a table of that part is missing or lost a field") end
same("stage", "the stage the model reached", c.stage, 1, "D_BestiaryData, D_AISetup, D_AICreatureType and the item model")

local COUNT_FROM = {
    all = "D_BestiaryData rows", hostile = "D_AISetup.Descriptors of each group's first variant",
    neutral = "D_AISetup.Descriptors of each group's first variant", passive = "D_AISetup.Descriptors of each group's first variant",
    friendly = "D_AISetup.Relationships = Player", tamed = "D_Tames rows that name a young or a grown set-up of the group",
    ridden = "D_Mounts.GrowthCurve = AI_Mounts and a D_Saddles row with an item", boss = "D_BestiaryData.bIsBoss",
    items = "D_ItemRewards through D_ItemTemplate", setups = "D_AISetup.BestiaryGroup",
    variants = "set-ups folded by kind, role, word, loot, growth and trophy",
}
for name, want in pairs(E.counts) do same("counts", "count " .. name, c.counts[name], want, COUNT_FROM[name] or "") end

same("list", "length of the creature list", #c.list, #E.list, "D_BestiaryData")
for position, id in ipairs(E.list) do
    local entry = c.list[position]
    if not entry or entry.id ~= id then
        differ("list", "place " .. position .. " in the creature list", entry and entry.id or "nothing", id,
            "the lowest D_AISpawnZones.MedianLevel of an area that lists it, then the name, bosses last")
        break
    end
    passed = passed + 1
end

local ENTRY_FROM = {
    name = "D_BestiaryData.CreatureName", boss = "D_BestiaryData.bIsBoss", workshop = "D_BestiaryData.Biomes names the row Workshop",
    temper = "the first variant: D_AISetup.Relationships, then Descriptors", attacks = "D_GOAPSetup.Motivations of a Neutral set-up",
    diet = "D_AISetup.Descriptors of the first variant that is not young", tamed = "D_Tames", ridden = "D_Mounts and D_Saddles",
    rank = "D_AISpawnZones.MedianLevel", icon = "the trophy's item icon, else a carcass's", image = "D_BestiaryData.Image",
    biomes = "D_BestiaryData.Biomes and D_Atmospheres.AtmosphereName", maps = "D_BestiaryData.Maps, D_Terrains and the spawn areas",
    traits = "D_BestiaryData.Traits and D_BestiaryTraits", words = "what the search matches", variants = "the folding of set-ups",
    tame = "D_Tames, and the bait, serum and trap items by tag",
}
for id, want in pairs(E.entries) do
    local entry = c.entries[id]
    if not entry then
        differ("entry", "creature " .. id, "nothing", "an entry", "D_BestiaryData")
    else
        local traits = {}
        for position, trait in ipairs(entry.traits) do traits[position] = trait.name .. "/" .. (trait.type or "") end
        local got = { entry.name, entry.row, entry.boss, entry.workshop, entry.temper or "", entry.attacks == true, entry.diet or "",
            entry.tamed, entry.ridden, entry.rank, entry.icon or "", entry.image or "", names_of(entry.biomes), names_of(entry.maps),
            joined(traits, ", "), entry.words, #entry.variants, tame_text(entry.tame) }
        for position, field in ipairs(E.entry_fields) do
            same("entry", "creature " .. id .. "." .. field, got[position], want[position], ENTRY_FROM[field] or "D_BestiaryData")
        end
    end
end
for id in pairs(c.entries) do
    if not E.entries[id] then differ("entry", "creature " .. id, "an entry", "nothing", "D_BestiaryData") end
end

local VARIANT_FROM = {
    setup = "D_AISetup rows of the group, the first of each fold", setups = "the fold: kind, role, word, loot, growth, trophy",
    name = "D_AICreatureType.CreatureName", role = "D_Tames, D_Mounts, D_WorldBosses, D_GreatHuntCreatureInfo, the team",
    temper = "D_AISetup.Relationships, then Descriptors", skin = "D_AISetup.Loot and D_ItemRewards",
    trophy = "D_AISetup.Trophy and D_ItemRewards", bones = "D_AISetup.Hitable and D_ItemRewards", carcass = "D_AISetup.DeadItem",
    areas = "D_Terrains.SpawnConfig, D_AISpawnConfig.SpawnZones, D_AISpawnZones", outposts = "the outposts' spawn configs",
    boss = "D_WorldBosses.RespawnTimeInSeconds", horde = "D_HordeWave", near = "D_AutonomousSpawns",
    with = "another row's D_AISetup.AdditionalAIToSpawn", epics = "D_EpicCreatures", mount = "D_Mounts, D_Saddles, D_CharacterGrowth",
}
for key, want in pairs(E.variants) do
    local id, position = key:match("^(.*)#(%d+)$")
    local entry = c.entries[id]
    local variant = entry and entry.variants[tonumber(position)]
    if not variant then
        differ("variant", "variant " .. key, "nothing", "a variant", "D_AISetup.BestiaryGroup")
    else
        local areas, epics = {}, {}
        for at, block in ipairs(variant.areas) do areas[at] = block_text(block) end
        for at, epic in ipairs(variant.epics) do epics[at] = epic.row .. "=" .. joined(epic.names, ", ") end
        local got = { variant.setup, joined(variant.setups), variant.name, variant.role, variant.kind or "", variant.tag or "",
            variant.temper or "", variant.attacks == true, variant.growth or "", variant.experience or "", variant.skin_event or "",
            variant.icon or "", drops_text(variant.skin), drops_text(variant.trophy), drops_text(variant.bones),
            joined(variant.carcass), joined(areas, "; "), block_text(variant.outposts, "outposts"),
            figure(variant.boss and variant.boss.respawn), variant.horde, variant.near, joined(variant.with, ", "),
            joined(epics, "; "), mount_text(variant.mount) }
        for at, field in ipairs(E.variant_fields) do
            same("variant", "variant " .. key .. "." .. field, got[at], want[at], VARIANT_FROM[field] or "D_AISetup")
        end
    end
end

local function index_text(lines, make)
    local out = {}
    for position, line in ipairs(lines) do out[position] = make(line) end
    return table.concat(out, " | ")
end
for item, want in pairs(E.drops) do
    same("drops", "who gives " .. item, index_text(c.drops[item] or {}, function(line)
        return ("%s#%d %s %s-%s %s%s"):format(line.entry, line.variant, line.way, figure(line.min), figure(line.max),
            figure(line.chance), line.needs and (" " .. line.needs) or "")
    end), want, "D_ItemRewards of every variant, the best line of each group, most first")
end
for item in pairs(c.drops) do
    if not E.drops[item] then differ("drops", "who gives " .. item, "lines", "nothing", "D_ItemRewards") end
end
for item, want in pairs(E.uses) do
    same("uses", "what " .. item .. " is used on", index_text(c.uses[item] or {}, function(line) return line.entry .. " " .. line.as end),
        want, "D_Saddles, the bait tags of D_AISetup, the kind tags of the serums")
end
for item in pairs(c.uses) do
    if not E.uses[item] then differ("uses", "what " .. item .. " is used on", "lines", "nothing", "D_Saddles and the item tags") end
end
same("items", "the feed items", joined(c.feed), E.feed, "items tagged Item.AnimalFeed")
same("items", "the trap", c.trap or "", E.trap, "the item tagged Item.Creature.Trap")
same("items", "the vestige knife", c.knife or "", E.knife, "D_ItemsStatic.Taxidermy_Knife")

local skipped = {}
for position, entry in ipairs(c.skipped) do skipped[position] = entry.table .. "." .. entry.row end
table.sort(skipped)
same("skipped", "handles to rows that are not there", #skipped, #E.skipped, "every creature table")
for position, want in ipairs(E.skipped) do
    if skipped[position] ~= want then
        differ("skipped", "skipped handle " .. position, skipped[position] or "nothing", want, "a handle whose row is missing")
        break
    end
    passed = passed + 1
end

-- every section of every creature, tab and variant: with maps refused as today, and with maps and curves served

local text, format, pages = part("text"), part("format"), part("creature_page")
local beasts = part("text_creatures")(text)
local BAD = { "%f[%a]nil%f[%A]", "%f[%a]nan%f[%A]", "%f[%a]inf%f[%A]", "table: ", "function: ", "%%[sd]", "  %S" }

local function words_ok(value)
    if type(value) ~= "string" or not value:find("%S") or value:find("^%s") or value:find("%s$") then return false end
    for _, bad in ipairs(BAD) do
        if value:find(bad) then return false end
    end
    return true
end

local function read_pages(label, model_c, model_m, model_src, provider)
    local source = part("source")
    local page = pages.new({ beasts = beasts, text = text, creatures = part("creatures"),
        stats = part("stats").new(source.new(provider), text, format) })
    local read, sections_read, alike = 0, 0, 0
    for _, entry in ipairs(model_c.list) do
        local head = page.head(entry)
        local cell = page.cell(entry, { kept = true, internal = true })
        if not words_ok(head.name) or not words_ok(head.word.text) or head.facts:find("%f[%a]nil%f[%A]") or not words_ok(cell.tip.title) then
            differ("pages", label .. " head of " .. entry.id, head.name .. " / " .. head.word.text .. " / " .. head.facts, "sound words", "the head")
        end
        -- every tip: the word's, the list cell's, and each variant cell's
        local tips, told = { head.word.tip }, {}
        for _, line in ipairs(cell.tip.lines) do tips[#tips + 1] = type(line) == "table" and line[1] or line end
        for _, look in ipairs(page.variants(entry, 1, model_m)) do
            local whole = { look.tip.title }
            for _, line in ipairs(look.tip.lines) do whole[#whole + 1] = type(line) == "table" and line[1] or line end
            for _, words in ipairs(whole) do tips[#tips + 1] = words end
            local key = table.concat(whole, "|")
            if told[key] then alike = alike + 1 end
            told[key] = true
        end
        local sound = true
        for _, words in ipairs(tips) do
            if not words_ok(words) then
                sound = false
                differ("pages", label .. " tips of " .. entry.id, show(words), "sound words", "creature_page.lua and text_creatures.lua")
            end
        end
        if sound then passed = passed + 1 end
        local function details(position) return part("creatures").detail(model_c, model_src, entry.id, position) end
        for position = 1, #entry.variants do
            for _, tab in ipairs(pages.TABS) do
                local where = ("%s %s #%d %s"):format(label, entry.id, position, tab)
                local made, sections = pcall(page.sections, tab, model_c, model_m, entry, position, details, { level = 30, progress = 10 })
                if not made then
                    differ("pages", where, "an error: " .. tostring(sections), "sections", "creature_page.lua")
                elseif #sections == 0 then
                    differ("pages", where, "no section", "at least one", "a tab is never blank")
                else
                    local fine = true
                    for at, section in ipairs(sections) do
                        local parts = #(section.text or {}) + #(section.pairs or {}) + #(section.after or {}) + #(section.slots or {})
                        local wrong = parts == 0 and "an empty section" or nil
                        if section.title ~= nil and not words_ok(section.title) then wrong = "the title " .. show(section.title) end
                        for _, key in ipairs({ "text", "after" }) do
                            for _, words in ipairs(section[key] or {}) do
                                if not words_ok(words) then wrong = "the sentence " .. show(words) end
                            end
                        end
                        for _, pair in ipairs(section.pairs or {}) do
                            if not words_ok(pair.name) or not words_ok(pair.value) then wrong = "the pair " .. show(pair.name) .. " = " .. show(pair.value) end
                        end
                        for _, slot in ipairs(section.slots or {}) do
                            if not slot.arrow and not (type(slot.item) == "string" and model_m.items[slot.item]) then wrong = "a slot with no item" end
                            if slot.count ~= nil and not words_ok(slot.count) then wrong = "the count " .. show(slot.count) end
                            for _, line in ipairs(slot.lines or {}) do
                                if not words_ok(line) then wrong = "the tip line " .. show(line) end
                            end
                        end
                        for _, words in ipairs(section.note or {}) do
                            if not words_ok(words) then wrong = "the note " .. show(words) end
                        end
                        if wrong then
                            fine = false
                            differ("pages", where .. " section " .. at, wrong, "sound words", "creature_page.lua and text_creatures.lua")
                        end
                        sections_read = sections_read + 1
                    end
                    if fine then passed = passed + 1 end
                end
                read = read + 1
            end
        end
    end
    return read, sections_read, alike
end

-- Every tab of every variant packed as the page draws it, with the heights layout.lua has from the game: no page may
-- be taller than its room or hold more sections than the page has. About is packed around the 3D view with its two
-- lines, at the level it opens on and at the creature's last level, with the level row.
local layout, rows, view = part("layout"), part("rows"), part("creature_view")
-- the inside of the column is the same at every screen size (layout.lua), so one size packs them all
local SIZES = { { 1920, 1080 } }

local function fit_pages(label, model_c, model_m, model_src, provider)
    local creatures, source = part("creatures"), part("source")
    local page = pages.new({ beasts = beasts, text = text, creatures = creatures, stats = part("stats").new(source.new(provider), text, format) })
    local packed_tabs, most, tallest = 0, 0, { share = 0 }
    for _, size in ipairs(SIZES) do
        local L = layout.compute(size[1], size[2])
        local high = view.heights(L, rows, { small = 10, usual = 11 })
        for _, entry in ipairs(model_c.list) do
            local variant_lines = #entry.variants < 2 and 0 or (#entry.variants <= view.ACROSS and 1 or 2)
            local open = page.tabs(entry)
            local function details(position) return creatures.detail(model_c, model_src, entry.id, position) end
            for position = 1, math.max(1, #entry.variants) do
                local facts = page.head(entry, position).facts
                local facts_lines = facts ~= "" and #rows.wrap(facts, L.inner * rows.LINE, 10) or 0
                for _, tab in ipairs(pages.TABS) do
                    local detail = details(position)
                    local levels = { false }
                    if tab == "about" and detail and detail.stats and detail.stats.last then levels = { false, detail.stats.last } end
                    -- Taming of a mount is also packed as it is drawn where Wax can put its saddles on: the 3D view with
                    -- three lines on every page, and the saddles straight under the tab's opening
                    local tamed = tab == "taming" and page.tamed_of(entry, position) or nil
                    local dressed = tamed and tamed.mount and tamed.mount.saddles[1] and {} or nil
                    for _, key in ipairs(dressed and tamed.mount.saddles or {}) do dressed[key] = true end
                    if dressed then levels = { false, "dressed" } end
                    for _, level in ipairs(open[tab] and levels or {}) do
                        local worn = level == "dressed"
                        if worn then level = false end
                        local where = ("%s %dx%d %s #%d %s%s%s"):format(label, size[1], size[2], entry.id, position, tab,
                            level and (" at level " .. level) or "", worn and " with a saddle on" or "")
                        local list = page.sections(tab, model_c, model_m, entry, position, details, { level = level or nil })
                        for at, section in ipairs(list) do list[at] = view.settled(section, rows, L.inner, text.pair) end
                        if worn then list = view.leading(list, dressed) end
                        local held, budget, first = view.paged(pages.pack, list, L, high,
                            { variant_lines = variant_lines, facts_lines = facts_lines, view_lines = tab == "about" and 2 or (worn and 3 or 0),
                                view_every = worn })
                        local fine, kept = true, 0
                        for at, sections in ipairs(held) do
                            local tall, room = 0, at == 1 and first or budget
                            for _, section in ipairs(sections) do tall = tall + pages.height(section, high) end
                            kept = kept + #sections
                            if tall > room or #sections > pages.MOST then
                                fine = false
                                differ("fit", where .. " page " .. at, ("%.1f units, %d sections"):format(tall, #sections),
                                    ("at most %.1f and %d"):format(room, pages.MOST), "creature_view.paged with layout.HIGH")
                            end
                            if room > 0 and tall / room > tallest.share then tallest = { share = tall / room, where = where .. " page " .. at } end
                        end
                        if kept < #list then
                            fine = false
                            differ("fit", where, kept .. " sections on its pages", "at least " .. #list, "a section was lost in the packing")
                        end
                        if fine then passed = passed + 1 end
                        packed_tabs, most = packed_tabs + 1, math.max(most, #held)
                    end
                end
            end
        end
    end
    return packed_tabs, most, tallest
end

-- The figures of About as the mod's model holds them, in the order the Python writes its own reading of the rows.
local function numbers_text(creatures, page, entry, position, detail)
    local variant, stats = entry.variants[position], detail.stats
    local crit = detail.crit and (figure(detail.crit.start) .. " of " .. joined(detail.crit.shares)) or ""
    if not stats then return { crit } end
    local level = stats.last and math.min(stats.last, page.start_level(variant, stats.last)) or nil
    local speeds, told, lists = {}, {}, {}
    for _, state in ipairs(pages.STATES) do
        local times = stats.states and stats.states[state]
        if stats.speed and times and times > 0 then speeds[#speeds + 1] = state .. "=" .. figure(stats.speed * times) end
    end
    for _, trait in ipairs(entry.traits) do
        local tied = stats.traits[trait.row]
        if tied then told[#told + 1] = trait.row .. "=" .. tied.name .. ":" .. figure(creatures.figure(tied.value, level)) end
    end
    for at, kind in ipairs({ "resists", "attacks", "others" }) do
        local out = {}
        for _, pair in ipairs(stats[kind]) do out[#out + 1] = pair.name .. "=" .. figure(creatures.figure(pair.value, level)) end
        lists[at] = table.concat(out, "; ")
    end
    local low, high = page.band(variant)
    return { crit, figure(stats.last), figure(level), figure(creatures.figure(stats.health, level)),
        figure(creatures.figure(stats.damage, level)), joined(speeds), figure(stats.swim), figure(stats.sight), figure(stats.hearing),
        low and (figure(low) .. "-" .. figure(high)) or "", table.concat(told, "; "), lists[1], lists[2], lists[3],
        figure(creatures.at(stats.xp_times, level)), figure(stats.attack_rate) }
end

local NUMBER_FROM = {
    crit = "D_CharacterStartingStats.StatsGranted and D_CriticalHitAreas.MultiplierStatMultiplier",
    last = "D_CharacterGrowth.MaxLevel of a mount, else where D_AIGrowth.Health ends", level = "the lowest D_AISpawnZones.MedianLevel",
    health = "D_AIGrowth.Health, else Base BaseMaximumHealth_+", damage = "D_AIGrowth.MeleeDamage, else Base BaseMeleeDamage_+",
    speeds = "Base BaseMovementSpeed_+ times D_AISetup.MovementMapping MaxWalkSpeed", swim = "Base BaseSwimSpeed_+",
    sight = "Base BaseAIPerceptionSightRadius_+", hearing = "Base BaseAIPerceptionSoundRadius_+",
    band = "D_AISpawnZones.MinLevel and MaxLevel of the areas that list it", traits = "D_BestiaryData.Traits tied to a stat of D_AIGrowth",
    resists = "D_AIGrowth.Base and CustomStats", attacks = "D_AIGrowth.Base and CustomStats", others = "D_AIGrowth.Base and CustomStats",
    xp_times = "D_AIGrowth.ExperienceMultiplier", attack_rate = "Base BaseNPCMeleeAttacksPerMinute_+",
}

local tabs_read, sections_read, alike = read_pages("maps refused", c, m, src, fixture.serve(tables))
local fitted = fit_pages("maps refused", c, m, src, fixture.serve(tables))
local later = fixture.serve(tables, { maps = true })
local built_later, c2, m2, src2 = pcall(fixture.build, part, later, { words = E.words, stages = 2 })
local served_tabs, served_sections, numbers, compared = 0, 0, 0, 0
local fitted_later, most_pages, tallest = 0, 0, { share = 0 }
if not built_later then
    differ("pages", "the model with maps served", "an error: " .. tostring(c2), "a model", "creatures.lua")
else
    served_tabs, served_sections = read_pages("maps served", c2, m2, src2, later)
    fitted_later, most_pages, tallest = fit_pages("maps served", c2, m2, src2, later)
    local creatures = part("creatures")
    local page = pages.new({ beasts = beasts, text = text, creatures = creatures })
    for _, entry in ipairs(c2.list) do
        local detail = creatures.detail(c2, src2, entry.id, 1)
        if detail and detail.stats then numbers = numbers + 1 end
    end
    same("pages", "creatures with numbers once maps are served", numbers > 100, true, "D_AIGrowth.Base")
    for key, want in pairs(E.numbers or {}) do
        local id, position = key:match("^(.*)#(%d+)$")
        local entry = c2.entries[id]
        local detail = entry and creatures.detail(c2, src2, id, tonumber(position))
        if not detail then
            differ("numbers", "numbers of " .. key, "nothing", "a detail", "D_AISetup.BestiaryGroup")
        else
            local got = numbers_text(creatures, page, entry, tonumber(position), detail)
            same("numbers", "numbers of " .. key .. ": how many", #got, #want, "D_AIGrowth")
            for at, field in ipairs(E.number_fields) do
                if want[at] ~= nil then
                    same("numbers", "numbers of " .. key .. "." .. field, got[at], want[at], NUMBER_FROM[field] or "D_AIGrowth")
                end
            end
            compared = compared + 1
        end
    end
end
print(("pages read: %d tabs and %d sections with maps refused, %d tabs and %d sections with maps served (%d creatures with numbers)")
    :format(tabs_read, sections_read, served_tabs, served_sections, numbers))
print(("pages packed with the game's heights at %d screen sizes: %d without numbers, %d with numbers, the level row and the 3D view; most pages %d; fullest %.0f%% (%s)")
    :format(#SIZES, fitted, fitted_later, most_pages, tallest.share * 100, tostring(tallest.where)))
print(("numbers compared with the Python's own reading: %d variants"):format(compared))
print(("variant cells whose tip reads like another's of its group: %d of %d"):format(alike, c.counts.variants))

for group, count in pairs(shown) do
    if count > LIMIT then io.stderr:write(("     ... and %d more differences in %s\n"):format(count - LIMIT, group)) end
end
print(("creature model on the game's tables: %d creatures, %d variants of %d set-ups, %d items dropped"):format(
    c.counts.all, c.counts.variants, c.counts.setups, c.counts.items))
print(("creature-data: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
