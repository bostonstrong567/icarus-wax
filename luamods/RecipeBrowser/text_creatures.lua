-- Every text of the Bestiary, each saying no more than a row of the game's tables. Called with the mod's text table.

return function(text)
    local number, join, duration = text.number, text.join, text.duration
    local SEPARATOR = " - "

    local function counted(count, one, many)
        return number(count) .. " " .. (count == 1 and one or many)
    end

    -- A figure with at most one decimal: 2.2, 50, 1,300, -8.
    local function plain(value)
        value = tonumber(value) or 0
        local tenths = math.floor(math.abs(value) * 10 + 0.5)
        local whole, tenth = tenths // 10, tenths % 10
        local sign = value < 0 and tenths > 0 and "-" or ""
        if tenth == 0 then return sign .. number(whole) end
        return sign .. number(whole) .. "." .. ("%d"):format(tenth)
    end

    local function either(names)
        if #names < 2 then return names[1] or "" end
        return table.concat(names, ", ", 1, #names - 1) .. " or " .. names[#names]
    end

    local beasts = {
        sides = { items = "Items", beasts = "Bestiary" },
        back = "Bestiary",
        reading = "Reading the game's creatures...",
        failed = "The game's creatures could not be read. The Log page of the Wax menu says why.",
        changed = "This version of the game changed its creature tables.",
        creature = "Creature",
        filters = { all = "All creatures", hostile = "Hostile", neutral = "Neutral", passive = "Passive", friendly = "Friendly",
            boss = "Boss", tamed = "Can be tamed", ridden = "Can be ridden", meat = "Meat eater", plants = "Plant eater" },
        words = { hostile = "Hostile", neutral = "Neutral", passive = "Passive", friendly = "Friendly", boss = "Boss",
            unknown = "Behaviour not listed" },
        word_tips = { hostile = "The game lists it as Aggressive.", neutral = "The game lists it as Neutral.",
            passive = "The game lists it as Passive.", friendly = "It is on the player's team." },
        diets = { meat = "Meat eater", plants = "Plant eater" },
        facts = { attacks = "Can attack", boss = "Boss", tamed = "Can be tamed", ridden = "Can be ridden",
            workshop = "From the Workshop" },
        roles = { wild = "Wild", boss = "Boss", tamed = "Tamed", friendly = "On your side", young = "Young" },
        tabs = { about = "About", drops = "Drops", taming = "Taming", where = "Where" },
        no_taming = "The game's taming tables do not name it.",
        favourite = "In favourites",
        map_only = "This map only",
        no_map = "No creature list for this map.",
        orders = { game = "Game order", speed = "Fastest", health = "Most health", damage = "Most damage",
            sight = "Sees furthest", hearing = "Hears furthest", xp = "Most XP" },
        figures = { speed = "Fastest it moves", health = "Health", damage = "Damage", sight = "Sight", hearing = "Hearing",
            xp = "Kill XP" },
        view_keys = "Drag to turn - wheel to zoom",
        view_stop = "Click to stop it", view_walk = "Click to make it walk",
        view_bare = "Nothing on", view_wear = "Click one below to try it on",
        put_on = "Click to put it on the model", take_off = "Click to take it off the model", its_recipe = "Double click for its recipe",
        open = "Click to open it",
        dropped = "Creatures",
        list_them = "Click to list them in the Bestiary",
        no_recipe = "No recipe makes this. Mining, farming and fishing are not listed yet.",
        used = { saddle = "For its saddle slot", bait = "Its bait", serum = "For breeding" },

        about = { numbers = "Numbers", traits = "Traits", resists = "Resistances", attacks = "Its attacks", named = "Named ones",
            others = "Other stats", guide = "From the Field Guide", health = "Health", damage = "Damage", sight = "Sight",
            hearing = "Hearing", swim = "Swimming", kill = "Kill XP", band = "Found at levels", attack_rate = "Attack speed",
            level_down = "One level lower", level_up = "One level higher", speeds = "Speed", senses = "Senses",
            resisting = "A percent is its resistance to that damage.",
            -- a movement state of the game, as what the animal is doing
            states = { Sneak = "Sneaking", Walk = "Walking", Jog = "Jogging", Run = "Running", Sprint = "Sprinting",
                Attacking = "While attacking", Following = "While following" },
            yours = "Your Bestiary", rewards = "Its Field Guide entry gives",
            base = "A prospect can change health, damage and speed.",
            nothing = "The game's Field Guide says nothing about it." },
        drops = { loot = "Loot", parts = "Trophy and bones", carcass = "Carcass", xp = "Experience", kill = "Kill",
            skinning = "Skinning", trophy = "Trophy", by_chance = "By a skinning chance that tools add",
            bones = "From its bones", bonus = "Only with a bonus that adds it",
            entry = "Only with a reward of its Field Guide entry", none = "The game lists no drops for it.",
            before = "Amounts and chances are before tools and talents." },
        taming = { wild = "Taming a wild one", young = "A young one", needs = "What taming takes", breeding = "Breeding",
            tamed = "Once tamed", saddles = "For its saddle slot", feed = "Animal feed",
            time = "Taming time", food = "Food wanted", shelter = "Shelter wanted", warmth = "Temperature wanted",
            not_while = "Not while", gestation = "Gestation", top = "Top level", orders = "Movement orders",
            combat = "Combat orders", comfortable = "Comfortable at", food_has = "Food", water_has = "Water",
            carries = "Carries", cargo = "Cargo slots",
            order = { Follow = "Follow", IdleWander = "Wander", IdleStanding = "Stand", IdleLying = "Lie down" },
            fight = { DoNotEngage = "Does not engage", NeutralEngagement = "Neutral", AggressiveEngagement = "Aggressive" },
            can = "It can be tamed.", can_ride = "It can be tamed and ridden.",
            form = "The game has a tamed form of it. Its tables do not say how to tame it.",
            workshop = "It comes tamed from the Workshop.",
            no_way = "The game's tables do not say where a young one comes from.",
            no_saddle = "No saddle fits it.",
            feed_note = "Items the game tags as animal feed." },
        where = { found = "Found in", biomes = "Biomes", maps = "Maps", levels = "Area levels",
            share = "Share", areas = "Areas", outposts = "Outposts",
            share_note = "Share is its weight in an area's spawn list.",
            horde = "It is in the game's horde waves.", near = "The game also spawns it near players.",
            workshop = "It comes from the Workshop.", unlisted = "The game's spawn lists do not name it." },
    }

    -- The fixed words the search knows, for creatures.build.
    function beasts.search_words()
        return { hostile = beasts.words.hostile, neutral = beasts.words.neutral, passive = beasts.words.passive,
            friendly = beasts.words.friendly, attacks = beasts.facts.attacks, boss = beasts.facts.boss,
            tamed = beasts.facts.tamed, ridden = beasts.facts.ridden, meat = beasts.diets.meat, plants = beasts.diets.plants }
    end

    -- A tab of the two at the top: "Bestiary", or with text typed "Bestiary (3)".
    function beasts.side(name, count)
        local label = beasts.sides[name] or tostring(name)
        if not count then return label end
        return label .. " (" .. number(count) .. ")"
    end

    -- The line under the filters: "107 creatures", "Hostile - 35 creatures", 'Nothing matches "xyz".'
    function beasts.count(shown, filter, query)
        if shown == 0 and query and query ~= "" then return text.no_match(query) end
        return join(filter and beasts.filters[filter] or nil, counted(shown, "creature", "creatures"))
    end

    -- "Drops Leather - 64 creatures", or without a count "Drops Leather".
    function beasts.drops_filter(item, count)
        if not count then return "Drops " .. item end
        return "Drops " .. item .. SEPARATOR .. counted(count, "creature", "creatures")
    end

    function beasts.uses_filter(item, count)
        if not count then return "Uses " .. item end
        return "Uses " .. item .. SEPARATOR .. counted(count, "creature", "creatures")
    end

    -- The keys line under the list, from the binds in use: "R opens it - U its drops - A favourite".
    -- short: "R open - U drops - A favourite", for a column the long form does not fit on one line.
    function beasts.keys(binds, short)
        local parts = {}
        for _, pair in ipairs({ { "make", "opens it", "open" }, { "used", "its drops", "drops" }, { "favourite", "favourite", "favourite" } }) do
            local key = binds and binds[pair[1]]
            if key and key ~= "" then parts[#parts + 1] = key .. " " .. pair[short and 3 or 2] end
        end
        return table.concat(parts, SEPARATOR)
    end

    -- A creature's tip while the list is in order by a figure: "Health at level 30: 1,300", "Fastest it moves: 12 m/s".
    function beasts.order_tip(order, value, level)
        local name = beasts.figures[order] or tostring(order)
        if order == "speed" then return text.pair(name, beasts.speed(value)) end
        if order == "sight" or order == "hearing" then return text.pair(name, beasts.metres(value)) end
        if order == "xp" then return text.pair(name, beasts.xp(math.floor(value + 0.5))) end
        return text.pair(name .. " at level " .. number(level), number(math.floor(value + 0.5)))
    end

    -- The lines under the 3D view. walks: the model has a walk to play. walking: it plays now.
    function beasts.view_lines(walks, walking)
        if not walks then return { beasts.view_keys } end
        return { beasts.view_keys, walking and beasts.view_stop or beasts.view_walk }
    end

    -- The lines under the 3D view of Taming. name: what the model wears, or nothing while it wears nothing.
    function beasts.saddle_lines(name)
        return { beasts.view_keys, name and ("Wearing: " .. name) or beasts.view_bare, beasts.view_wear }
    end

    -- What a click on a saddle of Taming does, for its tip. on: the model wears it.
    function beasts.saddle_tip(on) return { on and beasts.take_off or beasts.put_on, beasts.its_recipe } end

    function beasts.role(name, role)
        return join(name, beasts.roles[role])
    end

    function beasts.dropped_by(count)
        return "Dropped by " .. counted(count, "creature", "creatures")
    end

    function beasts.used_on(count)
        return "Used on " .. counted(count, "creature", "creatures")
    end

    -- "10 to 16", "2"
    function beasts.amount(low, high)
        if not high or high <= low then return plain(low) end
        return plain(low) .. " to " .. plain(high)
    end

    -- What a slot shows in its corner: "10-16", "2", nothing for one.
    function beasts.stack(low, high)
        if not high or high <= low then return low > 1 and text.short(low) or nil end
        return text.short(low) .. "-" .. text.short(high)
    end

    function beasts.chance(percent)
        return plain(percent) .. "% chance"
    end

    -- A creature's tip on an item's page: "Loot: 10 to 16", "Trophy: 1, 10% chance".
    function beasts.gives(way, low, high, chance)
        local line = text.pair(beasts.drops[way] or tostring(way), beasts.amount(low, high))
        if chance and chance < 100 then line = line .. ", " .. beasts.chance(chance) end
        return line
    end

    function beasts.level(level)
        return "Level " .. number(level)
    end

    function beasts.at_level(level)
        return "At level " .. number(level)
    end

    -- A row's attacks a minute: "60 a minute".
    function beasts.a_minute(count)
        return plain(count) .. " a minute"
    end

    -- The game's units are centimetres: 220 a second is "2.2 m/s", 5000 is "50 m".
    function beasts.speed(units)
        return plain((tonumber(units) or 0) / 100) .. " m/s"
    end

    function beasts.metres(units)
        return plain((tonumber(units) or 0) / 100) .. " m"
    end

    function beasts.xp(amount)
        return number(amount) .. " XP"
    end

    function beasts.percent(value)
        return plain(value) .. "%"
    end

    -- A resistance stat after the trait it stands behind: "Weak to Poison: -50%", "Resists Frost: +50%".
    function beasts.resistance(value)
        return (value > 0 and "+" or "") .. plain(value) .. "%"
    end

    -- What the game's rows say of a critical hit. start: the Critical Damage a character starts with, in percent.
    -- shares: the percents of it the kinds of weak point count, most first.
    function beasts.critical(start, shares)
        local parts = {}
        for at, share in ipairs(shares) do
            parts[at] = share >= 100 and "all" or (share == 50 and "half" or (plain(share) .. "%"))
        end
        return "A hit there is a critical hit. A new character's Critical Damage is +" .. plain(start) .. "%: the area counts "
            .. either(parts) .. " of it."
    end

    -- "10 to 40 degrees", "1 to 120", "10 to 21%", "14%"
    function beasts.range(low, high, unit)
        unit = unit or ""
        if unit ~= "" and unit ~= "%" then unit = " " .. unit end
        local first, last = plain(low), plain(high)
        if first == last then return first .. unit end
        return first .. " to " .. last .. unit
    end

    function beasts.share(low, high)
        if high < 0.5 then return "under 1%" end
        return beasts.range(math.max(1, math.floor(low + 0.5)), math.max(1, math.floor(high + 0.5)), "%")
    end

    -- "In this prospect creatures have 50% of this health." The percent is rounded to the nearest five.
    function beasts.here(percent)
        local rounded = math.floor((tonumber(percent) or 0) / 5 + 0.5) * 5
        return "In this prospect creatures have " .. number(rounded) .. "% of this health."
    end

    function beasts.points(points, total)
        return number(points) .. " of " .. counted(total, "point", "points")
    end

    function beasts.beside(percent)
        return "A wild adult has a " .. plain(percent) .. "% chance of a young one with it."
    end

    -- "A wild one is caught with a trap and its bait, in Forest or Grasslands."
    function beasts.trap(biomes, bait)
        local how = bait and "with a trap and its bait" or "with a trap"
        if not biomes or #biomes == 0 then return "A wild one is caught " .. how .. "." end
        return "A wild one is caught " .. how .. ", in " .. either(biomes) .. "."
    end

    -- "300, uses 240 an hour"
    function beasts.uses(most, hour)
        if not hour or hour <= 0 then return plain(most) end
        return plain(most) .. ", uses " .. plain(hour) .. " an hour"
    end

    function beasts.boss(seconds)
        if not seconds or seconds <= 0 then return "World boss." end
        return "World boss. Its respawn time is " .. duration(seconds) .. "."
    end

    function beasts.with(names)
        return "It spawns with " .. either(names) .. "."
    end

    -- "Carcass at the Skinning Bench"
    function beasts.bench(station)
        if not station or station == "" then return beasts.drops.carcass end
        return beasts.drops.carcass .. " at the " .. station
    end

    -- The note under a trophy, with the knife's own name when the game has that item.
    function beasts.vestige(tool)
        if not tool or tool == "" then return "Skinning gives a trophy by a chance that tools add." end
        return "Skinning gives a trophy by a chance that tools add, such as the " .. tool .. "."
    end

    text.beasts = beasts
    return beasts
end
