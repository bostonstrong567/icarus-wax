-- What a creature's page says: its word and facts, a cell's look, each tab as sections, and sections packed into pages.

local page = {}

page.TABS = { "about", "drops", "taming", "where" }
page.TONES = { hostile = "bad", neutral = "warn", passive = "good", friendly = "accent" }
page.MARKS = { kept = "star", boss = "skull", young = "baby", tamed = "heart", trophy = "trophy", bones = "bone",
    creature = "paw-print" }
-- The game's movement states a page lists, slowest kind first. Stationary and Undefined have a speed in the rows
-- too, which says nothing to a player, so they are left out.
page.STATES = { "Sneak", "Walk", "Jog", "Run", "Sprint", "Attacking", "Following" }
page.PAIR = 34          -- a name and its figure longer than this, in letters, are written as one sentence
page.LETTERS = 38       -- the letters a line of the column holds, for a section's height
page.ACROSS = 5         -- slots in a line
page.SLOTS = 10         -- slots in a section; more go on in the next one
page.MOST = 8           -- sections on a page
page.HEIGHTS = { line = 16, small = 14, space = 8, row = 30, tabs = 30, slot = 42 }
page.QUICK = { [25] = { 1, 10, 20, 25 }, [50] = { 1, 15, 30, 50 }, [120] = { 1, 30, 60, 120 }, [150] = { 1, 50, 100, 150 } }
page.QUICK_MOST = 4     -- quick levels in the level row's second line
page.STEP = 1           -- levels a press of the level row's minus or plus moves: a creature met in the world has any level
page.CRIT = "critspot"  -- the type of a trait that names a critical area

local function filled(value)
    return type(value) == "string" and value:find("%S") ~= nil
end

-- The lines a text takes: counted by heights.lines(words, small) when a view can measure, else by letters.
local function lines_of(words, letters, h, small)
    if h and h.lines then return math.max(1, h.lines(words, small == true)) end
    return math.max(1, math.ceil(#words / letters))
end

-- A section's height in the column's units. heights may also hold what a view knows of how it draws one:
-- under (the gap under each part), tail (the gap under slots that end a section), lines (see lines_of), letters.
function page.height(section, heights)
    local h = heights or page.HEIGHTS
    local under = h.under or 0
    local total = h.space
    if section.title then total = total + h.small + under end
    -- the level row is a row of buttons and a row of tabs, each with its gap
    if section.level then total = total + h.row + (h.tabs or h.row) + 2 * (h.under or h.space) end
    local function texts(list, letters, tall, small)
        local sum = 0
        for _, words in ipairs(list or {}) do sum = sum + lines_of(words, letters, h, small) * tall end
        return sum
    end
    local text = texts(section.text, page.LETTERS, h.line)
    if text > 0 then total = total + text + under end
    local pairs_high = #(section.pairs or {}) * h.line
    if pairs_high > 0 then total = total + pairs_high + under end
    local after = texts(section.after, page.LETTERS, h.line)
    if after > 0 then total = total + after + under end
    local slots = math.ceil(#(section.slots or {}) / page.ACROSS) * h.slot
    total = total + slots
    local note = texts(section.note, page.LETTERS + 4, h.small, true)
    if note > 0 then
        total = total + note + under
    elseif slots > 0 then
        total = total + (h.tail or 0)
    end
    return total
end

-- A long text as pieces no longer than `most` letters, cut after a sentence where one ends in the last part of a piece.
local function pieces(words, most)
    if #words <= most then return { words } end
    local out, current = {}, ""
    for word in words:gmatch("%S+") do
        if current ~= "" and #current + 1 + #word > most then
            out[#out + 1] = current
            current = word
        else
            current = current == "" and word or (current .. " " .. word)
            if #current >= most * 0.6 and word:find("[.!?\"]$") then
                out[#out + 1] = current
                current = ""
            end
        end
    end
    if current ~= "" then out[#out + 1] = current end
    return out
end

-- One section as sections that each fit the budget: what does not fit goes on without a title.
local function fit(section, budget, heights)
    if page.height(section, heights) <= budget then return { section } end
    local h = heights or page.HEIGHTS
    local letters = h.letters or page.LETTERS
    local room = budget - h.small - h.space - 2 * (h.under or 0)
    local most = math.max(letters, math.floor(room / h.line) * letters)
    -- a piece that still measures taller than a page is cut again, shorter
    local function cut(words, limit)
        local parts = {}
        for _, piece in ipairs(pieces(words, limit)) do
            if limit > letters and page.height({ title = section.title, text = { piece } }, heights) > budget then
                for _, smaller in ipairs(cut(piece, math.max(letters, math.floor(limit * 0.75)))) do parts[#parts + 1] = smaller end
            else
                parts[#parts + 1] = piece
            end
        end
        return parts
    end
    local out, current = {}, { title = section.title, level = section.level }
    local function add(kind, value)
        local trial = {}
        for key, held in pairs(current) do trial[key] = held end
        trial[kind] = {}
        for _, held in ipairs(current[kind] or {}) do trial[kind][#trial[kind] + 1] = held end
        trial[kind][#trial[kind] + 1] = value
        local has = current.text or current.pairs or current.after or current.slots or current.note
        if has and page.height(trial, heights) > budget then
            out[#out + 1] = current
            current = { [kind] = { value } }
        else
            current = trial
        end
    end
    for _, words in ipairs(section.text or {}) do
        for _, piece in ipairs(cut(words, most)) do add("text", piece) end
    end
    for _, pair in ipairs(section.pairs or {}) do add("pairs", pair) end
    for _, words in ipairs(section.after or {}) do add("after", words) end
    for _, slot in ipairs(section.slots or {}) do add("slots", slot) end
    for _, words in ipairs(section.note or {}) do add("note", words) end
    out[#out + 1] = current
    return out
end

-- Sections into pages: in order, none over the budget, at most page.MOST on one.
-- first: the room of the first page when something else stands on it too. With too little of it that page has no section.
function page.pack(sections, budget, heights, first)
    local pages, current, used = {}, {}, 0
    first = first and math.min(first, budget) or budget
    local less = first < budget
    for _, whole in ipairs(sections) do
        local room = #pages == 0 and first or budget
        local cut_to = room
        if #pages == 0 and #current > 0 and less then
            local tall = page.height(whole, heights)
            -- one that fits a later page whole is not cut to end the first
            if tall > room - used and tall <= budget then cut_to = budget end
        end
        for _, section in ipairs(fit(whole, cut_to, heights)) do
            local tall = page.height(section, heights)
            room = #pages == 0 and first or budget
            if (#current > 0 or (less and #pages == 0 and tall > room)) and (used + tall > room or #current >= page.MOST) then
                pages[#pages + 1] = current
                current, used = {}, 0
            end
            current[#current + 1] = section
            used = used + tall
        end
    end
    if #current > 0 then pages[#pages + 1] = current end
    return pages
end

-- The quick levels of the level row, for where a creature's levels end.
function page.levels(last)
    last = math.max(1, math.floor(tonumber(last) or 1))
    if page.QUICK[last] then return page.QUICK[last] end
    local out, seen = {}, {}
    for _, level in ipairs({ 1, math.floor(last / 3 / 5 + 0.5) * 5, math.floor(last * 2 / 3 / 5 + 0.5) * 5, last }) do
        level = math.min(last, math.max(1, level))
        if not seen[level] then
            seen[level] = true
            out[#out + 1] = level
        end
    end
    return out
end

-- parts: beasts (text_creatures.lua's words), text, creatures (creatures.lua), stats (what stats.new gives, or nil)
function page.new(parts)
    local beasts, text, creatures, stats = parts.beasts, parts.text, parts.creatures, parts.stats
    local self = {}

    local function section(title)
        return { title = title, text = {}, pairs = {}, slots = {}, note = {} }
    end

    local function say(held, words)
        if filled(words) then held.text[#held.text + 1] = words end
    end

    local function pair(held, name, value)
        if filled(name) and filled(value) then held.pairs[#held.pairs + 1] = { name = name, value = value } end
    end

    local function remark(held, words)
        if filled(words) then held.note[#held.note + 1] = words end
    end

    -- Drops what is empty, writes a pair too long as a sentence under the others, carries a long slot list on untitled.
    local function finish(sections)
        local out = {}
        for _, held in ipairs(sections) do
            local pairs_kept, after = {}, {}
            for _, entry in ipairs(held.pairs) do
                if #entry.name + #entry.value > page.PAIR then
                    after[#after + 1] = text.pair(entry.name, entry.value)
                else
                    pairs_kept[#pairs_kept + 1] = entry
                end
            end
            held.pairs = pairs_kept
            if #held.text + #held.pairs + #after + #held.slots > 0 then
                local slots, first = held.slots, true
                repeat
                    local part = { title = first and held.title or nil, level = first and held.level or nil }
                    if first and held.text[1] then part.text = held.text end
                    if first and held.pairs[1] then part.pairs = held.pairs end
                    if first and after[1] then part.after = after end
                    local taken = {}
                    for at = 1, math.min(page.SLOTS, #slots) do taken[at] = slots[at] end
                    if taken[1] then part.slots = taken end
                    local rest = {}
                    for at = page.SLOTS + 1, #slots do rest[#rest + 1] = slots[at] end
                    slots, first = rest, false
                    if #slots == 0 and held.note[1] then part.note = held.note end
                    out[#out + 1] = part
                until #slots == 0
            end
        end
        return out
    end

    local function names_of(list)
        local out = {}
        for position, entry in ipairs(list or {}) do out[position] = entry.name end
        return table.concat(out, ", ")
    end

    local function whole(value)
        return text.number(math.floor((tonumber(value) or 0) + 0.5))
    end

    -- The game's own sentence for each stat pair, or nothing without stats.lua.
    local function worded(found)
        local out = {}
        if not stats or not found then return out end
        for _, line in ipairs(stats.sentences(found)) do
            if filled(line.text) then out[#out + 1] = line.text end
        end
        return out
    end

    -- Resistances as what they are of and how much: "Poison Resistance: -100%". The game's own sentence, "-100 Poison
    -- Resistance", says neither. A sentence with no figure to take out stays the game's.
    local function resisted(found)
        local out = {}
        if not stats or not found then return out end
        for _, line in ipairs(stats.sentences(found)) do
            if filled(line.value) and filled(line.label) and line.value:find("^[+-]?[%d.,]+%%?$") then
                out[#out + 1] = text.pair(line.label, line.value:find("%%$") and line.value or (line.value .. "%"))
            elseif filled(line.text) then
                out[#out + 1] = line.text
            end
        end
        return out
    end

    -- The one word under the name: { text, tone, tip }. Without a variant, the group's.
    function self.word(entry, variant)
        local temper = entry.temper
        if variant then temper = variant.temper end
        if temper and beasts.words[temper] then
            return { text = beasts.words[temper], tone = page.TONES[temper], tip = beasts.word_tips[temper] }
        end
        if entry.boss then return { text = beasts.words.boss, tone = "bad" } end
        return { text = beasts.words.unknown, tone = "dim" }
    end

    -- The parts of the line under the word that hold, as a list.
    function self.facts(entry, variant)
        local out, word = {}, self.word(entry, variant)
        local attacks = entry.attacks
        if variant then attacks = variant.attacks end
        if entry.diet then out[#out + 1] = beasts.diets[entry.diet] end
        if attacks then out[#out + 1] = beasts.facts.attacks end
        if entry.boss and word.text ~= beasts.words.boss then out[#out + 1] = beasts.facts.boss end
        if entry.tamed then out[#out + 1] = beasts.facts.tamed end
        if entry.ridden then out[#out + 1] = beasts.facts.ridden end
        if entry.workshop and entry.temper == "friendly" then out[#out + 1] = beasts.facts.workshop end
        return out
    end

    -- What the top of a creature's page shows. facts is "" when nothing holds.
    function self.head(entry, position)
        local variant = entry.variants[position or 1]
        local picture = variant and variant.icon or entry.icon
        return { name = entry.name, image = picture, icon = not picture and page.MARKS.creature or nil,
            word = self.word(entry, variant), facts = text.join(self.facts(entry, variant)) }
    end

    -- A creature's cell. options: kept, internal (show the row name), outside (among items, where a paw tells it from one),
    -- gives (a drops line), note (a line of its own, such as what an item is to it)
    function self.cell(entry, options)
        options = options or {}
        local word = self.word(entry)
        local lines = { { text.join(word.text, entry.attacks and beasts.facts.attacks or nil), word.tone } }
        local places = {}
        for at = 1, math.min(3, #entry.biomes) do places[at] = entry.biomes[at].name end
        local about = text.join(entry.diet and beasts.diets[entry.diet] or nil, table.concat(places, ", "))
        if filled(about) then lines[#lines + 1] = about end
        if entry.ridden then
            lines[#lines + 1] = beasts.facts.ridden
        elseif entry.tamed then
            lines[#lines + 1] = beasts.facts.tamed
        end
        if entry.boss and word.text ~= beasts.words.boss then lines[#lines + 1] = beasts.facts.boss end
        local gives = options.gives
        if gives then lines[#lines + 1] = beasts.gives(gives.way == "skin" and "loot" or gives.way, gives.min, gives.max, gives.chance) end
        if filled(options.note) then lines[#lines + 1] = options.note end
        if options.kept then lines[#lines + 1] = { beasts.favourite, "accent" } end
        if options.internal then lines[#lines + 1] = entry.row end
        local mark = options.outside and page.MARKS.creature or options.kept and page.MARKS.kept
            or entry.boss and page.MARKS.boss or nil
        return { image = entry.icon, icon = not entry.icon and page.MARKS.creature or nil, tone = page.TONES[entry.temper],
            mark = mark, value = { creature = entry.id }, tip = { title = entry.name, lines = lines } }
    end

    -- The line of variants: empty for a group with one. m: the item model, to tell two of one name apart by a drop.
    function self.variants(entry, chosen, m)
        local out, times = {}, {}
        if #entry.variants < 2 then return out end
        for _, variant in ipairs(entry.variants) do
            local title = beasts.role(variant.name, variant.role)
            times[title] = (times[title] or 0) + 1
        end
        for position, variant in ipairs(entry.variants) do
            local picture = variant.icon or entry.icon
            local word = self.word(entry, variant)
            local title = beasts.role(variant.name, variant.role)
            local lines = { { word.text, word.tone } }
            if times[title] > 1 and m then
                local trophy = variant.trophy[1] and m.items[variant.trophy[1].item]
                local carcass = variant.carcass[1] and m.items[variant.carcass[1]]
                if trophy and filled(trophy.name) then
                    lines[#lines + 1] = text.pair(beasts.drops.trophy, trophy.name)
                elseif carcass and filled(carcass.name) then
                    lines[#lines + 1] = text.pair(beasts.drops.carcass, carcass.name)
                end
            end
            out[position] = { image = picture, icon = not picture and page.MARKS.creature or nil,
                selected = position == (chosen or 1), mark = page.MARKS[variant.role], tone = page.TONES[variant.temper],
                value = { variant = position }, tip = { title = title, lines = lines } }
        end
        return out
    end

    -- Which tabs can be opened, and why one cannot.
    function self.tabs(entry)
        local open = { about = true, drops = true, taming = entry.tame ~= nil, where = true }
        return open, { taming = not open.taming and beasts.no_taming or nil }
    end

    -- The looks of the creatures that give an item, most first. kept(id) says which are favourites. limit: no more than so many.
    -- A card of creatures says what they are, so its cells carry no paw.
    function self.droppers(c, key, kept, limit)
        local out, lines = {}, c.drops[key] or {}
        for position = 1, math.min(#lines, limit or #lines) do
            local line = lines[position]
            out[position] = self.cell(c.entries[line.entry], { gives = line, kept = kept and kept(line.entry) })
        end
        return out
    end

    -- The looks of the creatures an item is used on: a saddle's mounts, a bait's catch, a serum's kind. Each says what it is to it.
    function self.users(c, key, kept, limit)
        local out, lines = {}, c.uses[key] or {}
        for position = 1, math.min(#lines, limit or #lines) do
            local line = lines[position]
            out[position] = self.cell(c.entries[line.entry], { note = beasts.used and beasts.used[line.as] or nil,
                kept = kept and kept(line.entry) })
        end
        return out
    end

    -- The level the level row starts on: the lowest middle level of an area that lists the variant, inside its levels.
    function self.start_level(variant, last)
        local level = nil
        for _, block in ipairs(variant.areas) do
            if not level or block.median < level then level = block.median end
        end
        if variant.outposts and (not level or variant.outposts.median < level) then level = variant.outposts.median end
        level = math.max(1, math.floor(level or 1))
        if last and level > last then level = last end
        return level
    end

    -- The levels a variant is listed at over every map and the outposts, or nothing.
    function self.band(variant)
        local low, high = nil, nil
        local function take(block)
            if not low or block.low < low then low = block.low end
            if not high or block.high > high then high = block.high end
        end
        for _, block in ipairs(variant.areas) do take(block) end
        if variant.outposts then take(variant.outposts) end
        return low, high
    end

    -- The numbers of a creature: what changes with its level, with the row that picks one, then how it moves and what
    -- it senses. Gives the level they are of, or nothing for a creature whose rows have no levels.
    local function numbers(out, variant, detail, options)
        local numbers_of = detail and detail.stats
        if not numbers_of then return nil end
        local last = numbers_of.last
        local level = last and math.min(last, math.max(1, math.floor(tonumber(options.level) or self.start_level(variant, last))))
        local held = section(level and beasts.at_level(level) or beasts.about.numbers)
        if level then held.level = { value = level, last = last, quick = page.levels(last) } end
        local health, damage = creatures.figure(numbers_of.health, level), creatures.figure(numbers_of.damage, level)
        if health and health > 0 then pair(held, beasts.about.health, whole(health)) end
        if damage and damage > 0 then pair(held, beasts.about.damage, whole(damage)) end
        -- how often it hits, where a row of the game says so: most creatures have it only in their animations
        if numbers_of.attack_rate and numbers_of.attack_rate > 0 then
            pair(held, beasts.about.attack_rate, beasts.a_minute(numbers_of.attack_rate))
        end
        local xp = creatures.kill_xp(detail, level)
        if xp and xp > 0 then pair(held, beasts.about.kill, beasts.xp(math.floor(xp + 0.5))) end
        local low, high = self.band(variant)
        if low then pair(held, beasts.about.band, beasts.range(low, high)) end
        remark(held, options.here and beasts.here(options.here) or beasts.about.base)
        out[#out + 1] = held

        -- the short one first: it fits under the level's numbers on the page that has the 3D view
        local senses = section(beasts.about.senses)
        if numbers_of.sight and numbers_of.sight > 0 then pair(senses, beasts.about.sight, beasts.metres(numbers_of.sight)) end
        if numbers_of.hearing and numbers_of.hearing > 0 then pair(senses, beasts.about.hearing, beasts.metres(numbers_of.hearing)) end
        out[#out + 1] = senses

        -- how fast it moves in each thing it does, named for what it is doing
        local speeds = section(beasts.about.speeds)
        for _, state in ipairs(page.STATES) do
            local times = numbers_of.states and numbers_of.states[state]
            if numbers_of.speed and times and times > 0 then
                pair(speeds, beasts.about.states[state], beasts.speed(numbers_of.speed * times))
            end
        end
        if numbers_of.swim and numbers_of.swim > 0 then pair(speeds, beasts.about.swim, beasts.speed(numbers_of.swim)) end
        out[#out + 1] = speeds
        return level
    end

    -- Stat pairs as they are at a level: a figure a row gives by level is read at that one.
    local function at_level(found, level)
        local out = {}
        for _, entry in ipairs(found or {}) do
            local value = creatures.figure(entry.value, level)
            if value then out[#out + 1] = { name = entry.name, value = value } end
        end
        return out
    end

    local function about(c, entry, variant, detail, options)
        local out = {}
        local stats = detail and detail.stats
        local level = numbers(out, variant, detail, options)

        -- the game's own list, in its order. A trait a stat of the creature stands behind says that figure
        local traits, critical, resisting = section(beasts.about.traits), false, false
        for _, trait in ipairs(entry.traits) do
            local tied = stats and stats.traits and stats.traits[trait.row]
            local value = tied and creatures.figure(tied.value, level)
            if value and value ~= 0 then
                local resists = tied.name:find("Resistance", 1, true) ~= nil
                resisting = resisting or resists
                say(traits, text.pair(trait.name, resists and beasts.resistance(value) or beasts.chance(value)))
            else
                say(traits, trait.name)
            end
            if trait.type == page.CRIT and not trait.row:lower():find("^none") then critical = true end
        end
        if resisting then remark(traits, beasts.about.resisting) end
        if critical and detail and detail.crit then remark(traits, beasts.critical(detail.crit.start, detail.crit.shares)) end
        out[#out + 1] = traits

        for _, plan in ipairs({ { "resists", beasts.about.resists }, { "attacks", beasts.about.attacks },
            { "others", beasts.about.others } }) do
            local held = section(plan[2])
            local found = at_level(stats and stats[plan[1]], level)
            for _, words in ipairs(plan[1] == "resists" and resisted(found) or worded(found)) do say(held, words) end
            out[#out + 1] = held
        end

        local named = section(beasts.about.named)
        for at, epic in ipairs(variant.epics) do
            local adds = worded(detail and detail.epics and detail.epics[at])
            say(named, text.join(table.concat(epic.names, ", "), adds[1] and table.concat(adds, ", ") or nil))
        end
        out[#out + 1] = named

        local progress = options.progress
        if progress and detail and detail.points and detail.points > 0 then
            local yours = section(beasts.about.yours)
            say(yours, beasts.points(progress, detail.points))
            out[#out + 1] = yours
        end
        local rewards = section(beasts.about.rewards)
        for _, words in ipairs(worded(detail and detail.rewards)) do say(rewards, words) end
        out[#out + 1] = rewards

        for at, words in ipairs(detail and detail.lore or {}) do
            local held = section(at == 1 and beasts.about.guide or nil)
            say(held, words)
            out[#out + 1] = held
        end

        out = finish(out)
        if #out == 0 then out[1] = { text = { beasts.about.nothing } } end
        return out
    end

    local function drop_slot(drop, way, rewards)
        local lines = {}
        if way == "trophy" then lines[#lines + 1] = beasts.drops.trophy end
        if way == "bones" then lines[#lines + 1] = beasts.drops.bones end
        lines[#lines + 1] = beasts.amount(drop.min, drop.max)
        if drop.chance < 100 then lines[#lines + 1] = beasts.chance(drop.chance) end
        if drop.needs == creatures.TROPHY_STAT then
            lines[#lines + 1] = beasts.drops.by_chance
        elseif drop.needs then
            lines[#lines + 1] = rewards[drop.needs] and beasts.drops.entry or beasts.drops.bonus
        end
        return { item = drop.item, count = beasts.stack(drop.min, drop.max), dim = drop.needs ~= nil or nil,
            mark = page.MARKS[way], lines = lines }
    end

    -- The recipe that takes one carcass and nothing else, once the item model has its recipes.
    local function bench_of(m, item)
        for _, number in ipairs(m.used_in and m.used_in[item] or {}) do
            local recipe = m.recipes[number]
            if recipe and #recipe.inputs == 1 and recipe.inputs[1].item == item and #recipe.tags_in == 0 and recipe.outputs[1] then
                return recipe
            end
        end
        return nil
    end

    local function drops(c, m, entry, variant, detail)
        local out, rewards = {}, {}
        for _, reward in ipairs(detail and detail.rewards or {}) do rewards[reward.name] = true end

        local loot = section(beasts.drops.loot)
        for _, drop in ipairs(variant.skin) do loot.slots[#loot.slots + 1] = drop_slot(drop, "skin", rewards) end
        out[#out + 1] = loot

        local parts = section(beasts.drops.parts)
        for _, drop in ipairs(variant.trophy) do parts.slots[#parts.slots + 1] = drop_slot(drop, "trophy", rewards) end
        for _, drop in ipairs(variant.bones) do parts.slots[#parts.slots + 1] = drop_slot(drop, "bones", rewards) end
        if variant.trophy[1] then
            local knife = c.knife and m.items[c.knife]
            remark(parts, beasts.vestige(knife and knife.name or nil))
        end
        out[#out + 1] = parts

        local bare = section(beasts.drops.carcass)
        for _, item in ipairs(variant.carcass) do
            local recipe = bench_of(m, item)
            if recipe then
                local station = recipe.stations[1] and m.sets[recipe.stations[1]]
                local held = section(beasts.bench(station and station.name or nil))
                held.slots[1], held.slots[2] = { item = item }, { arrow = true }
                for _, made in ipairs(recipe.outputs) do
                    held.slots[#held.slots + 1] = { item = made.item, count = made.count > 1 and text.short(made.count) or nil }
                end
                out[#out + 1] = held
            else
                bare.slots[#bare.slots + 1] = { item = item }
            end
        end
        out[#out + 1] = bare

        local gained = section(beasts.drops.xp)
        local xp = detail and detail.xp or {}
        if xp.skin and xp.skin > 0 then pair(gained, beasts.drops.skinning, beasts.xp(xp.skin)) end
        if xp.kill and xp.kill > 0 then pair(gained, beasts.drops.kill, beasts.xp(xp.kill)) end
        out[#out + 1] = gained

        out = finish(out)
        local any = false
        for _, held in ipairs(out) do
            if held.slots then any = true end
        end
        if not any then
            table.insert(out, 1, { text = { beasts.drops.none } })
        else
            local last = out[#out]
            last.note = last.note or {}
            last.note[#last.note + 1] = beasts.drops.before
        end
        return out
    end

    -- The tamed variant the tab's figures are of: the one chosen when it has a mount row, else the group's first.
    function self.tamed_of(entry, position)
        local chosen = entry.variants[position or 1]
        if chosen and chosen.mount then return chosen, position or 1 end
        for at, variant in ipairs(entry.variants) do
            if variant.mount then return variant, at end
        end
        return nil, nil
    end

    local function mapped(names, words)
        local out = {}
        for position, name in ipairs(names or {}) do out[position] = words[name] or name end
        return table.concat(out, ", ")
    end

    local function taming(c, entry, position, details)
        local tame, t = entry.tame, beasts.taming
        if not tame then return { { text = { beasts.no_taming } } } end
        local out = {}
        local variant, at = self.tamed_of(entry, position)
        local mount = variant and variant.mount

        local opening = section(nil)
        if entry.workshop and entry.temper == "friendly" then
            say(opening, t.workshop)
        elseif entry.tamed then
            say(opening, entry.ridden and t.can_ride or t.can)
        else
            say(opening, t.form)
        end
        out[#out + 1] = opening

        if tame.trap_in then
            local wild = section(t.wild)
            say(wild, beasts.trap(tame.trap_in, tame.bait ~= nil))
            if c.trap then wild.slots[#wild.slots + 1] = { item = c.trap } end
            if tame.bait then wild.slots[#wild.slots + 1] = { item = tame.bait } end
            out[#out + 1] = wild
        end

        if tame.young and (tame.beside or not tame.serum) then
            local young = section(t.young)
            say(young, tame.beside and beasts.beside(tame.beside) or t.no_way)
            out[#out + 1] = young
        end

        if tame.seconds then
            local needs = section(t.needs)
            if tame.seconds > 0 then pair(needs, t.time, text.duration(tame.seconds)) end
            if tame.nutrition > 0 then pair(needs, t.food, beasts.percent(tame.nutrition)) end
            if tame.shelter > 0 then pair(needs, t.shelter, beasts.percent(tame.shelter)) end
            if tame.cold and tame.hot then pair(needs, t.warmth, beasts.range(tame.cold, tame.hot, "degrees")) end
            if tame.not_while[1] then pair(needs, t.not_while, table.concat(tame.not_while, ", ")) end
            out[#out + 1] = needs
        end

        if tame.serum then
            local breeding = section(t.breeding)
            if tame.gestation and tame.gestation > 0 then pair(breeding, t.gestation, text.duration(tame.gestation)) end
            breeding.slots[1] = { item = tame.serum }
            out[#out + 1] = breeding
        end

        if mount then
            local once = section(t.tamed)
            if mount.top then pair(once, t.top, text.number(mount.top)) end
            pair(once, t.orders, mapped(mount.orders, t.order))
            pair(once, t.combat, mapped(mount.combat, t.fight))
            if mount.comfortable then
                pair(once, t.comfortable, beasts.range(mount.comfortable.low, mount.comfortable.high, "degrees"))
            end
            local detail = details and details(at)
            local kept = detail and detail.stats
            if kept then
                if kept.food then pair(once, t.food_has, beasts.uses(kept.food, kept.food_hour)) end
                if kept.water then pair(once, t.water_has, beasts.uses(kept.water, kept.water_hour)) end
                if kept.carry and kept.carry > 0 then pair(once, t.carries, text.number(kept.carry)) end
                if kept.cargo and kept.cargo > 0 then pair(once, t.cargo, text.number(kept.cargo)) end
            end
            out[#out + 1] = once

            local saddles = section(t.saddles)
            for _, item in ipairs(mount.saddles) do saddles.slots[#saddles.slots + 1] = { item = item } end
            if not mount.saddles[1] then say(saddles, t.no_saddle) end
            out[#out + 1] = saddles

            local feed = section(t.feed)
            for _, item in ipairs(c.feed) do feed.slots[#feed.slots + 1] = { item = item } end
            if c.feed[1] then remark(feed, t.feed_note) end
            out[#out + 1] = feed
        end
        return finish(out)
    end

    local function where(entry, variant)
        local out, w = {}, beasts.where
        local found = section(not entry.workshop and w.found or nil)
        if entry.workshop then
            say(found, w.workshop)
        else
            pair(found, w.biomes, names_of(entry.biomes))
            pair(found, w.maps, names_of(entry.maps))
        end
        out[#out + 1] = found

        local blocks = 0
        local function block(title, area)
            local held = section(title)
            pair(held, w.levels, beasts.range(area.low, area.high))
            pair(held, w.share, beasts.share(area.share_low, area.share_high))
            pair(held, w.areas, text.number(area.count))
            if blocks == 0 then remark(held, w.share_note) end
            blocks = blocks + 1
            out[#out + 1] = held
        end
        for _, area in ipairs(variant.areas) do block(area.name, area) end
        if variant.outposts then block(w.outposts, variant.outposts) end

        local other = section(nil)
        if variant.boss then say(other, beasts.boss(variant.boss.respawn)) end
        if variant.horde then say(other, w.horde) end
        if variant.near then say(other, w.near) end
        if variant.with[1] then say(other, beasts.with(variant.with)) end
        if blocks == 0 and not other.text[1] and not entry.workshop then say(other, w.unlisted) end
        out[#out + 1] = other

        out = finish(out)
        if #out == 0 then out[1] = { text = { w.unlisted } } end
        return out
    end

    -- One tab's sections for one variant, never empty. details(position) gives creatures.detail; options: level, progress, here.
    function self.sections(tab, c, m, entry, position, details, options)
        position, options = position or 1, options or {}
        -- a group no set-up names still has its field guide page
        local variant = entry.variants[position] or entry.variants[1]
            or { role = "wild", skin = {}, trophy = {}, bones = {}, carcass = {}, areas = {}, epics = {}, with = {} }
        local detail = details and details(position) or nil
        if tab == "about" then return about(c, entry, variant, detail, options) end
        if tab == "drops" then return drops(c, m, entry, variant, detail) end
        if tab == "taming" then return taming(c, entry, position, details) end
        return where(entry, variant)
    end

    -- The line under the filters. item: the name of the item a "dropped by" list is of, or with `uses` a "used on" list.
    function self.count_line(shown, filter, query, item, uses)
        if item and uses then return beasts.uses_filter(item, shown) end
        if item then return beasts.drops_filter(item, shown) end
        return beasts.count(shown, filter, query)
    end

    return self
end

return page
