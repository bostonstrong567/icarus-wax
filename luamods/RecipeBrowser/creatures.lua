-- The Bestiary's model: creature groups with their variants, drops, taming and where they are found. No interface, no text.

-- version: raised whenever build or detail gives something else, so a model kept across a reload is made again
local creatures = { version = 4, PAUSE_ROWS = 60 }
-- Assumed, not seen in play: a kill gives its event's XP times the growth row's ExperienceMultiplier at the creature's level.
creatures.XP_BY_LEVEL = false

-- In source.lua's list format: stage 1 is read ahead, stage 4 a row at a time for a page; a maybe field is a map or a curve.
creatures.TABLES = {
    { table = "BestiaryData", stage = 1, fields = { "CreatureName", "Image", "bIsBoss", "Biomes.RowName", "Maps.RowName",
        "Traits.RowName" } },
    { table = "BestiaryTraits", stage = 1, fields = { "TraitName", "Type.RowName" } },
    { table = "Atmospheres", stage = 1, fields = { "AtmosphereName" } },
    { table = "Terrains", stage = 1, fields = { "TerrainName", "SpawnConfig.RowName" } },
    { table = "AISetup", stage = 1, fields = { "BestiaryGroup.RowName", "CreatureType.RowName", "Descriptors.RowName",
        "Relationships.RowName", "GOAPSetup.RowName", "Loot.RowName", "Trophy.RowName", "Hitable.RowName", "DeadItem.RowName",
        "AIGrowth.RowName", "Experience.RowName", "AdditionalAIToSpawn.RowName", "ValidBaitTagQuery.TagDictionary.TagName" } },
    { table = "GOAPSetup", stage = 1, rows = "named", from = { { "AISetup", "GOAPSetup.RowName" } },
        fields = { "Motivations.RowName" } },
    { table = "AICreatureType", stage = 1, fields = { "CreatureName", "Tag.TagName", "SkinningXPEvent.RowName" } },
    { table = "ItemRewards", stage = 1, rows = "named", from = { { "AISetup", "Loot.RowName" }, { "AISetup", "Trophy.RowName" },
        { "AISetup", "Hitable.RowName" } }, fields = { "Rewards.Item.RowName", "Rewards.DropChance",
        "Rewards.MinRandomStackCount", "Rewards.MaxRandomStackCount", "Rewards.RequiredStatToDrop.RowName" } },
    { table = "Tames", stage = 1, fields = { "TameDurationInSeconds", "DesiredTemperatureRange.X", "DesiredTemperatureRange.Y",
        "DesiredShelterPercentage", "DesiredNutritionPercentage", "ProhibitedTamingModifiers.RowName", "TamedAI.RowName",
        "MatureCreatureType.RowName", "JuvenileCreatureType.RowName", "bAutomaticallySpawnJuvenileWithParent",
        "PercentChanceToSpawnJuvenile", "TrappingSupportedAtmospheres.Value", "GestationPeriodSeconds" } },
    { table = "ModifierStates", stage = 1, rows = "named", from = { { "Tames", "ProhibitedTamingModifiers.RowName" } },
        fields = { "ModifierName" } },
    { table = "Mounts", stage = 1, fields = { "AISetup.RowName", "GrowthCurve.RowName", "SupportedMovementStates",
        "SupportedCombatStates", "bUseTemperature", "ComfortableTemperatureRange.X", "ComfortableTemperatureRange.Y" } },
    { table = "Saddles", stage = 1, fields = { "SaddleTag.TagName", "SupportedMount.RowName" } },
    { table = "CharacterGrowth", stage = 1, rows = "named", from = { { "Mounts", "GrowthCurve.RowName" } }, fields = { "MaxLevel" } },
    { table = "AISpawnZones", stage = 1, fields = { "MinLevel", "MedianLevel", "MaxLevel", "Creatures.AISpawnList.AISetup.Value",
        "Creatures.AISpawnList.SpawnWeight" } },
    { table = "AISpawnConfig", stage = 1, fields = { "SpawnZones.SpawnZone.RowName" } },
    { table = "EpicCreatures", stage = 1, fields = { "CreatureNames", "AISetup.RowName" } },
    { table = "WorldBosses", stage = 1, fields = { "AISetup.RowName", "RespawnTimeInSeconds" } },
    { table = "GreatHuntCreatureInfo", stage = 1, fields = { "AISetup.RowName" } },
    { table = "AutonomousSpawns", stage = 1, fields = { "AISetup.Value" } },
    { table = "HordeWave", stage = 1, fields = { "Creatures.Creature.RowName" } },
    { table = "CriticalHitAreas", stage = 1, fields = { "DamageMultiplierStat.Value", "MultiplierStatMultiplier" } },

    { table = "BestiaryData", stage = 4, rows = "request", fields = { "Lore1", "Lore2", "Lore3", "TotalPointsRequired" },
        maybe = { "StatsUnlock1", "StatsUnlock2" } },
    { table = "ExperienceEvents", stage = 4, rows = "request", fields = { "ExperienceGranted" } },
    { table = "AIGrowth", stage = 4, rows = "request", fields = {}, maybe = { "Base", "Health", "MeleeDamage",
        "ExperienceMultiplier", "CustomStats.Stat.Value", "CustomStats.Curve" } },
    { table = "AISetup", stage = 4, rows = "request", fields = {}, maybe = { "MovementMapping" } },
    { table = "EpicCreatures", stage = 4, rows = "request", fields = {}, maybe = { "AdditionalStats" } },
    { table = "Experience", stage = 4, rows = "request", fields = {}, maybe = { "ExperienceEvents" } },
    { table = "CharacterStartingStats", stage = 4, rows = "request", fields = {}, maybe = { "StatsGranted" } },
}

-- The game's enums as the tables number them. The files write the names.
creatures.ORDERS = { "Follow", "IdleWander", "IdleStanding", "IdleLying" }
creatures.COMBAT = { "DoNotEngage", "NeutralEngagement", "AggressiveEngagement" }
creatures.STATES = { [0] = "Undefined", "Stationary", "Sneak", "Walk", "Jog", "Run", "Sprint", "Attacking", "Following" }
-- the states in which it goes somewhere: the two others have a speed in the rows that says nothing of how fast it is
creatures.MOVING = { Sneak = true, Walk = true, Jog = true, Run = true, Sprint = true, Attacking = true, Following = true }

creatures.TROPHY_STAT = "BaseChanceToHarvestCreatureTrophiesOnSkinning_%"
creatures.CRIT_STAT = "CriticalDamage_+%"
creatures.NO_RANK = 9999

local PLAYER, MOUNTS, PETS, WORKSHOP, KNIFE = "player", "ai_mounts", "ai_pets", "workshop", "taxidermy_knife"
local SADDLE, SERUM, FEED, TRAP, BAIT, NPC = "item.mount.saddle", "item.husbandry.serum", "item.animalfeed",
    "item.creature.trap", "item.creature.bait.", "npc."
local SKIP_TERRAINS = { space = true, outpost_dev = true }
local OUTPOST, TEST_WAVE, DEV = "^outpost", "^test_wave", "^%[DNT%]"
local FIGHTS = { aggression = true, protective = true }
local TEMPERS = { aggressive = "hostile", neutral = "neutral", passive = "passive" }
local DIETS = { carnivore = "meat", herbivore = "plants" }
local ROLES = { wild = 1, boss = 2, tamed = 3, friendly = 4, young = 5 }
local BOSS_ROLES = { boss = 1, wild = 2, tamed = 3, friendly = 4, young = 5 }
local WAYS = { skin = 1, trophy = 2, bones = 3 }

local function fold(name)
    return (name:lower())
end

local function ref(handle)
    local name = handle
    if type(handle) == "table" then name = handle.RowName end
    if type(name) ~= "string" or name == "" or name:lower() == "none" then return nil end
    return name
end

local function key_of(handle)
    local name = ref(handle)
    return name and fold(name) or nil
end

local function trim(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- A name the game shows, or nil for an empty one and for one marked as not for players.
local function shown(value)
    local name = trim(value)
    if name == "" or name:lower() == "none" or name:find(DEV) then return nil end
    return name
end

local function path(value)
    if type(value) ~= "string" or value == "" or value:lower() == "none" then return nil end
    return value
end

local function list(value)
    if type(value) ~= "table" then return {} end
    return value
end

local function number(value, default)
    value = tonumber(value)
    if not value or value ~= value then return default end
    return value
end

-- What one row of each loop counts towards PAUSE_ROWS, from timing the loops on the real tables in the game.
local COST = { item = 0.5, row = 1, zone = 1.5, setup = 3, group = 14, entry = 1.5 }

local function ticker(pause)
    local count = 0
    return function(cost)
        count = count + (cost or 1)
        if count >= creatures.PAUSE_ROWS then
            count = 0
            if pause then pause() end
        end
    end
end

-- A stat map as { name, value } pairs: keys plain or as the files write them, (Value="Name"), or a list of pairs.
function creatures.stat_pairs(map)
    if type(map) ~= "table" then return nil end
    local out = {}
    for key, value in pairs(map) do
        local name, figure = key, value
        if type(value) == "table" then
            name, figure = value.Key or value.Stat or value.Name, value.Value
            if type(name) == "table" then name = name.Value or name.RowName end
        end
        figure = tonumber(figure)
        if type(name) == "string" and figure then
            out[#out + 1] = { name = name:match('^%(Value="(.*)"%)$') or name, value = figure }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- A movement map as { [state name] = multiplier }: keys the enum's number or name, values a number or a struct.
function creatures.speeds(map)
    if type(map) ~= "table" then return nil end
    local out, any = {}, false
    for key, value in pairs(map) do
        local state = key
        if type(value) == "table" and value.Key ~= nil then state, value = value.Key, value.Value end
        if type(state) == "number" then state = creatures.STATES[math.tointeger(state) or -1] end
        if type(state) == "string" then state = state:match("([%a_]+)$") end
        if type(value) == "table" then value = value.MaxWalkSpeed end
        value = tonumber(value)
        if state and value then
            out[state] = value
            any = true
        end
    end
    return any and out or nil
end

-- A curve as { first, last, values = { one a whole level } } from a list that starts at level 0, { First, Values } or keys.
function creatures.curve(value)
    if type(value) ~= "table" then return nil end
    local first, values = tonumber(value.First or value.first) or 0, value.Values or value.values
    if type(values) ~= "table" and type(value[1]) == "number" then values = value end
    if type(values) == "table" and type(values[1]) == "number" then
        local out = {}
        for position = 1, #values do out[position] = tonumber(values[position]) or 0 end
        return { first = first, last = first + #out - 1, values = out }
    end
    local keys = {}
    for _, key in ipairs(value.Keys or value.keys or value) do
        if type(key) == "table" then
            local at, figure = tonumber(key.Time or key.time or key[1]), tonumber(key.Value or key.value or key[2])
            if at and figure then keys[#keys + 1] = { at, figure } end
        end
    end
    if #keys == 0 then return nil end
    table.sort(keys, function(a, b) return a[1] < b[1] end)
    local low, high = math.ceil(keys[1][1]), math.floor(keys[#keys][1])
    local out, at = {}, 1
    for level = low, high do
        while keys[at + 1] and keys[at + 1][1] < level do at = at + 1 end
        local from, to = keys[at], keys[at + 1] or keys[at]
        local span = to[1] - from[1]
        out[#out + 1] = span > 0 and (from[2] + (to[2] - from[2]) * (level - from[1]) / span) or from[2]
    end
    if #out == 0 then return nil end
    return { first = low, last = high, values = out }
end

-- The value of a curve at a level, held to the curve's own ends. A plain number is the same at every level.
function creatures.at(curve, level)
    if type(curve) == "number" then return curve end
    if type(curve) ~= "table" then return nil end
    local place = math.floor((tonumber(level) or curve.first) + 0.5) - curve.first + 1
    if place < 1 then place = 1 end
    if place > #curve.values then place = #curve.values end
    return curve.values[place]
end

-- The row of experience events as the event a kill gives: the entry keyed XP_OnDeath, by name or as the one entry.
local function death_event(map)
    if type(map) ~= "table" then return nil end
    local only, count = nil, 0
    for key, value in pairs(map) do
        if type(value) == "table" then
            local name = type(value.Key) == "string" and value.Key or key
            local event = ref(value.ExperienceEvent or (type(value.Value) == "table" and value.Value.ExperienceEvent))
            if type(name) == "string" and name:lower():find("ondeath", 1, true) then return event end
            only, count = event, count + 1
        end
    end
    return count == 1 and only or nil
end

local function miss(c, name, field)
    for _, known in ipairs(c.missing) do
        if known.table == name and known.field == field then return end
    end
    c.missing[#c.missing + 1] = { table = name, field = field }
end

local function skip(c, name, row, from)
    c.skipped[#c.skipped + 1] = { table = name, row = row, from = from }
end

-- A part is off when one of its tables is missing or lost a field.
local function broken(c, src, part, ...)
    local any = false
    for _, name in ipairs({ ... }) do
        if src.broken[name] then any = true end
    end
    for _, problem in ipairs(src.problems) do miss(c, problem.table, problem.field) end
    if any then c.off[part] = true end
    return any
end

local function new_model(src, m)
    return {
        version = creatures.version, stamp = src.stamps and src.stamps() or "", items = m and m.stamp or "", stage = 0,
        list = {}, entries = {}, by_setup = {}, drops = {}, uses = {}, feed = {}, details = {}, places = {},
        counts = { all = 0, hostile = 0, neutral = 0, passive = 0, friendly = 0, tamed = 0, ridden = 0, boss = 0, items = 0,
            setups = 0, variants = 0 },
        missing = {}, off = {}, skipped = {},
    }
end

-- Items by the tags the Bestiary asks about, each list in the order of the keys. Feed the item list hides is left out.
local function tagged_items(m, tick)
    local by_tag, npc = {}, {}
    for key, item in pairs(m.items) do
        if not item.variant then
            local serum, own = false, nil
            local listed = not (item.hidden or item.title_only)
            for _, tag in ipairs(item.tags or {}) do
                if tag == SERUM then serum = true end
                if (tag == FEED and listed) or tag == TRAP or tag == SERUM or tag:sub(1, #SADDLE) == SADDLE
                    or tag:sub(1, #BAIT) == BAIT then
                    local held = by_tag[tag]
                    if not held then
                        held = {}
                        by_tag[tag] = held
                    end
                    held[#held + 1] = key
                elseif tag:sub(1, #NPC) == NPC then
                    own = own or {}
                    own[tag] = true
                end
            end
            if serum then npc[key] = own or {} end
        end
        tick(COST.item)
    end
    for _, held in pairs(by_tag) do table.sort(held) end
    return by_tag, npc
end

-- The shown name of each row of a table that has one.
local function read_names(src, name, field)
    local out = {}
    for _, row in ipairs(src.names(name)) do
        local found = src.row(name, row)
        local label = found and shown(found[field])
        if label then out[fold(row)] = { row = row, name = label } end
    end
    return out
end

-- Every spawn area with its level band, total weight and weight a set-up; and for each set-up the areas that list it.
local function read_zones(src, tick)
    local zones, listed = {}, {}
    for _, name in ipairs(src.names("AISpawnZones")) do
        local row = src.row("AISpawnZones", name)
        if row then
            local key = fold(name)
            local zone = { low = number(row.MinLevel, 1), median = number(row.MedianLevel, 1), high = number(row.MaxLevel, 1),
                total = 0, weights = {} }
            local held = type(row.Creatures) == "table" and row.Creatures.AISpawnList or nil
            for _, entry in ipairs(list(held)) do
                local setup = key_of(type(entry.AISetup) == "table" and entry.AISetup.Value or nil)
                local weight = number(entry.SpawnWeight, 0)
                if setup and weight > 0 then
                    zone.total = zone.total + weight
                    if not zone.weights[setup] then
                        local areas = listed[setup]
                        if not areas then
                            areas = {}
                            listed[setup] = areas
                        end
                        areas[#areas + 1] = key
                    end
                    zone.weights[setup] = (zone.weights[setup] or 0) + weight
                end
            end
            zones[key] = zone
        end
        tick(COST.zone)
    end
    return zones, listed
end

-- The maps in the table's order, each with the areas of its spawn config, every outpost's areas as one list, and the
-- outposts one by one.
local function read_maps(src, zones)
    local maps, outposts, in_outposts, posts = {}, {}, {}, {}
    for _, name in ipairs(src.names("Terrains")) do
        local row = src.row("Terrains", name)
        local key, label = fold(name), row and shown(row.TerrainName)
        local config = row and ref(row.SpawnConfig)
        local config_row = config and src.row("AISpawnConfig", config)
        if label and config_row and not SKIP_TERRAINS[key] then
            local own, seen = {}, {}
            for _, slot in ipairs(list(config_row.SpawnZones)) do
                local zone = key_of(slot.SpawnZone)
                if zone and zones[zone] and not seen[zone] then
                    seen[zone] = true
                    own[#own + 1] = zone
                end
            end
            if key:find(OUTPOST) then
                posts[#posts + 1] = { row = name, name = label, zones = own }
                for _, zone in ipairs(own) do
                    if not in_outposts[zone] then
                        in_outposts[zone] = true
                        outposts[#outposts + 1] = zone
                    end
                end
            else
                maps[#maps + 1] = { row = name, name = label, zones = own }
            end
        end
    end
    return maps, outposts, posts
end

-- A variant's block for each place (a map's number, 0 the outposts): how many areas list it, their levels and its share.
local function blocks_of(zones, listed, places, setups)
    local out, seen = {}, {}
    for _, setup in ipairs(setups) do
        for _, zone_key in ipairs(listed[setup] or {}) do
            local zone = zones[zone_key]
            if not seen[zone_key] and zone.total > 0 then
                seen[zone_key] = true
                local weight = 0
                for _, own in ipairs(setups) do weight = weight + (zone.weights[own] or 0) end
                local share = 100 * weight / zone.total
                for _, place in ipairs(places[zone_key] or {}) do
                    local block = out[place]
                    if not block then
                        block = { count = 0, low = zone.low, high = zone.high, share_low = share, share_high = share,
                            median = zone.median, common = 0 }
                        out[place] = block
                    end
                    block.count = block.count + 1
                    if zone.low < block.low then block.low = zone.low end
                    if zone.high > block.high then block.high = zone.high end
                    if share < block.share_low then block.share_low = share end
                    if share > block.share_high then block.share_high = share end
                    -- common: its largest share among the areas with the lowest middle level
                    if zone.median < block.median then
                        block.median, block.common = zone.median, share
                    elseif zone.median == block.median and share > block.common then
                        block.common = share
                    end
                end
            end
        end
    end
    return out
end

local function enum_names(values, names)
    local out, seen = {}, {}
    for _, value in ipairs(list(values)) do
        local name = value
        if type(value) == "number" then name = names[math.tointeger(value) or -1] end
        if type(name) == "string" then name = name:match("([%a_]+)$") end
        if name and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    return out
end

-- options: lower (how names are lower-cased), words (the fixed words the search knows), pause (called now and then)
function creatures.build(src, m, options)
    options = options or {}
    local lower, words = options.lower or string.lower, options.words or {}
    local tick = ticker(options.pause)
    local c = new_model(src, m)
    if type(m) ~= "table" or (m.stage or 0) < 1 or m.off.list or type(m.templates) ~= "table" then
        c.off.items = true
        return c
    end
    if broken(c, src, "list", "BestiaryData", "AISetup", "AICreatureType") then return c end

    local by_tag, serum_tags = tagged_items(m, tick)
    local biomes = broken(c, src, "biomes", "Atmospheres") and {} or read_names(src, "Atmospheres", "AtmosphereName")
    local trait_names = broken(c, src, "traits", "BestiaryTraits") and {} or read_names(src, "BestiaryTraits", "TraitName")
    local no_where = broken(c, src, "where", "Terrains", "AISpawnZones", "AISpawnConfig")
    local terrains = src.broken.Terrains and {} or read_names(src, "Terrains", "TerrainName")
    local zones, listed, maps, outposts, places, posts = {}, {}, {}, {}, {}, {}
    if not no_where then
        zones, listed = read_zones(src, tick)
        maps, outposts, posts = read_maps(src, zones)
        local function belongs(zone, place)
            local held = places[zone]
            if not held then
                held = {}
                places[zone] = held
            end
            held[#held + 1] = place
        end
        for place, map in ipairs(maps) do
            for _, zone in ipairs(map.zones) do belongs(zone, place) end
        end
        for _, zone in ipairs(outposts) do belongs(zone, 0) end
    end
    local no_drops = broken(c, src, "drops", "ItemRewards")
    local no_fights = broken(c, src, "fights", "GOAPSetup")
    local no_taming = broken(c, src, "taming", "Tames", "Mounts", "Saddles", "CharacterGrowth", "ModifierStates")

    -- the shares of the hitter's Critical Damage the game's kinds of weak point count, as percents, most first
    if not broken(c, src, "crit", "CriticalHitAreas") then
        local shares, seen = {}, {}
        for _, name in ipairs(src.names("CriticalHitAreas")) do
            local row = src.row("CriticalHitAreas", name)
            local stat = row and type(row.DamageMultiplierStat) == "table" and row.DamageMultiplierStat.Value
            local share = math.floor(number(row and row.MultiplierStatMultiplier, 0) * 100 + 0.5)
            if stat == creatures.CRIT_STAT and share > 0 and not seen[share] then
                seen[share] = true
                shares[#shares + 1] = share
            end
        end
        table.sort(shares, function(a, b) return a > b end)
        if shares[1] then c.crit = { shares = shares } end
    end

    local function setup_exists(name)
        return name ~= nil and src.has("AISetup", name)
    end

    -- taming and mount rows whose set-ups all exist
    local tame_rows, young_of, tamed_of, grown_of, mount_of = {}, {}, {}, {}, {}
    if not no_taming then
        for _, name in ipairs(src.names("Tames")) do
            local row = src.row("Tames", name)
            if row then
                local young, grown, tamed = ref(row.JuvenileCreatureType), ref(row.MatureCreatureType), ref(row.TamedAI)
                local whole = (young or grown or tamed) and true or false
                for _, wanted in ipairs({ young or false, grown or false, tamed or false }) do
                    if wanted and not setup_exists(wanted) then
                        whole = false
                        skip(c, "AISetup", wanted, "Tames." .. name)
                    end
                end
                if whole then
                    local entry = { name = name, row = row, young = young and fold(young), grown = grown and fold(grown),
                        tamed = tamed and fold(tamed) }
                    tame_rows[#tame_rows + 1] = entry
                    if entry.young and not young_of[entry.young] then young_of[entry.young] = entry end
                    if entry.grown and not grown_of[entry.grown] then grown_of[entry.grown] = entry end
                    if entry.tamed and not tamed_of[entry.tamed] then tamed_of[entry.tamed] = entry end
                end
            end
            tick(COST.row)
        end
        for _, name in ipairs(src.names("Mounts")) do
            local row = src.row("Mounts", name)
            local setup = row and ref(row.AISetup)
            if setup and setup_exists(setup) then
                if not mount_of[fold(setup)] then mount_of[fold(setup)] = { name = name, row = row } end
            elseif setup then
                skip(c, "AISetup", setup, "Mounts." .. name)
            end
            tick(COST.row)
        end
    end

    local boss_of, hunted = {}, {}
    if not broken(c, src, "bosses", "WorldBosses", "GreatHuntCreatureInfo") then
        for _, name in ipairs(src.names("WorldBosses")) do
            local row = src.row("WorldBosses", name)
            local setup = row and key_of(row.AISetup)
            if setup and not boss_of[setup] then boss_of[setup] = { respawn = number(row.RespawnTimeInSeconds, 0) } end
        end
        for _, name in ipairs(src.names("GreatHuntCreatureInfo")) do
            local row = src.row("GreatHuntCreatureInfo", name)
            local setup = row and key_of(row.AISetup)
            if setup then hunted[setup] = true end
        end
    end

    local epics_of = {}
    if not broken(c, src, "named", "EpicCreatures") then
        for _, name in ipairs(src.names("EpicCreatures")) do
            local row = src.row("EpicCreatures", name)
            local setup = row and key_of(row.AISetup)
            local names = {}
            for _, given in ipairs(list(row and row.CreatureNames)) do
                local label = shown(given)
                if label then names[#names + 1] = label end
            end
            if setup and names[1] then
                local held = epics_of[setup]
                if not held then
                    held = {}
                    epics_of[setup] = held
                end
                held[#held + 1] = { row = name, names = names }
            end
            tick(COST.row)
        end
    end

    local in_horde, near_players = {}, {}
    if not broken(c, src, "hordes", "HordeWave") then
        for _, name in ipairs(src.names("HordeWave")) do
            local row = src.row("HordeWave", name)
            if row and not fold(name):find(TEST_WAVE) then
                for _, wave in ipairs(list(row.Creatures)) do
                    local setup = key_of(wave.Creature)
                    if setup then in_horde[setup] = true end
                end
            end
        end
    end
    if not broken(c, src, "near", "AutonomousSpawns") then
        for _, name in ipairs(src.names("AutonomousSpawns")) do
            local row = src.row("AutonomousSpawns", name)
            local setup = row and key_of(type(row.AISetup) == "table" and row.AISetup.Value or nil)
            if setup then near_players[setup] = true end
        end
    end

    local fighters = {}
    local function fights(goap)
        if not goap or no_fights then return false end
        local key = fold(goap)
        local known = fighters[key]
        if known == nil then
            known = false
            local row = src.row("GOAPSetup", goap)
            for _, handle in ipairs(list(row and row.Motivations)) do
                local wanted = key_of(handle)
                if wanted and FIGHTS[wanted] then known = true end
            end
            fighters[key] = known
        end
        return known
    end

    local reward_cache = {}
    local function drops_of(handle)
        local name = ref(handle)
        if not name or no_drops then return nil, nil end
        local key = fold(name)
        local known = reward_cache[key]
        if known ~= nil then return known or nil, known and key or nil end
        if not src.has("ItemRewards", name) then
            skip(c, "ItemRewards", name, "AISetup")
            reward_cache[key] = false
            return nil, nil
        end
        local row, out = src.row("ItemRewards", name), {}
        for _, reward in ipairs(list(row and row.Rewards)) do
            local template = ref(reward.Item)
            local item = template and m.templates[fold(template)]
            if item and m.items[item] then
                local low = number(reward.MinRandomStackCount, 1)
                local high = number(reward.MaxRandomStackCount, low)
                if high < low then high = low end
                out[#out + 1] = { item = item, min = low, max = high, chance = number(reward.DropChance, 100),
                    needs = ref(reward.RequiredStatToDrop) }
            elseif template then
                skip(c, "ItemTemplate", template, "ItemRewards." .. name)
            end
        end
        reward_cache[key] = out
        return out, key
    end

    local kinds = {}
    local function kind_of(handle)
        local name = ref(handle)
        if not name then return nil end
        local key = fold(name)
        local known = kinds[key]
        if known == nil then
            local row = src.row("AICreatureType", name)
            local own = src.names("AICreatureType")[src.position("AICreatureType", name) or 0]
            known = row and { key = key, row = own or name, name = shown(row.CreatureName),
                tag = key_of(type(row.Tag) == "table" and row.Tag.TagName or nil), skin = ref(row.SkinningXPEvent) } or false
            kinds[key] = known
        end
        return known or nil
    end

    -- the groups, then every set-up into its group
    local group_of, groups = {}, {}
    for _, name in ipairs(src.names("BestiaryData")) do
        local row = src.row("BestiaryData", name)
        if row then
            local group = { id = fold(name), row = name, guide = row, setups = {} }
            group_of[group.id] = group
            groups[#groups + 1] = group
        end
    end

    local brought = {}      -- folded set-up -> the set-ups that bring it along
    for _, name in ipairs(src.names("AISetup")) do
        local row = src.row("AISetup", name)
        local group = row and group_of[key_of(row.BestiaryGroup) or ""]
        local key = fold(name)
        for _, handle in ipairs(list(row and row.AdditionalAIToSpawn)) do
            local other = key_of(handle)
            if other and other ~= key then
                local held = brought[other]
                if not held then
                    held = { seen = {} }
                    brought[other] = held
                end
                if not held.seen[key] then
                    held.seen[key] = true
                    held[#held + 1] = row
                end
            end
        end
        if group then
            local kind = kind_of(row.CreatureType)
            local team = key_of(row.Relationships)
            local temper, diet = nil, nil
            for _, handle in ipairs(list(row.Descriptors)) do
                local word = key_of(handle)
                if word then
                    temper = temper or TEMPERS[word]
                    diet = diet or DIETS[word]
                end
            end
            if team == PLAYER then temper = "friendly" end
            local role = "wild"
            if young_of[key] then
                role = "young"
            elseif tamed_of[key] or mount_of[key] then
                role = "tamed"
            elseif boss_of[key] or hunted[key] then
                role = "boss"
            elseif team == PLAYER then
                role = "friendly"
            end
            local skin, loot = drops_of(row.Loot)
            local trophy, trophy_key = drops_of(row.Trophy)
            local bones = drops_of(row.Hitable)
            local carcass = key_of(row.DeadItem)
            if carcass and not m.items[carcass] then
                skip(c, "ItemsStatic", ref(row.DeadItem), "AISetup." .. name)
                carcass = nil
            end
            local baits = {}
            local query = type(row.ValidBaitTagQuery) == "table" and row.ValidBaitTagQuery.TagDictionary or nil
            for _, entry in ipairs(list(query)) do
                local tag = type(entry) == "table" and entry.TagName or entry
                if type(tag) == "string" and fold(tag):sub(1, #BAIT) == BAIT then baits[#baits + 1] = fold(tag) end
            end
            local growth = ref(row.AIGrowth)
            group.setups[#group.setups + 1] = { key = key, row = name, kind = kind, role = role, temper = temper, diet = diet,
                attacks = temper == "neutral" and fights(ref(row.GOAPSetup)), skin = skin, trophy = trophy, bones = bones,
                carcass = carcass, baits = baits, growth = growth, experience = ref(row.Experience),
                fold = table.concat({ kind and kind.key or "", role, temper or "", loot or "", growth and fold(growth) or "",
                    trophy_key or "" }, "|") }
            c.counts.setups = c.counts.setups + 1
        end
        tick(COST.setup)
    end

    -- for each mount row, the tags of the saddle rows that list it, in the table's order
    local saddle_tags = {}
    if not no_taming then
        for _, name in ipairs(src.names("Saddles")) do
            local saddle = src.row("Saddles", name)
            local tag = saddle and type(saddle.SaddleTag) == "table" and key_of(saddle.SaddleTag.TagName) or nil
            for _, handle in ipairs(list(tag and saddle.SupportedMount)) do
                local mount = key_of(handle)
                if mount then
                    local held = saddle_tags[mount]
                    if not held then
                        held = {}
                        saddle_tags[mount] = held
                    end
                    held[#held + 1] = tag
                end
            end
            tick(COST.row)
        end
    end

    local function mount_info(found)
        local row = found.row
        local growth = key_of(row.GrowthCurve)
        local growth_row = growth and src.row("CharacterGrowth", growth)
        local range = row.ComfortableTemperatureRange
        local info = { row = found.name, pet = growth == PETS, top = growth_row and number(growth_row.MaxLevel, nil) or nil,
            orders = enum_names(row.SupportedMovementStates, creatures.ORDERS),
            combat = enum_names(row.SupportedCombatStates, creatures.COMBAT), saddles = {} }
        if row.bUseTemperature == true and type(range) == "table" and number(range.X) and number(range.Y) then
            info.comfortable = { low = number(range.X), high = number(range.Y) }
        end
        local seen = {}
        for _, tag in ipairs(saddle_tags[fold(found.name)] or {}) do
            for _, item in ipairs(by_tag[tag] or {}) do
                if not seen[item] then
                    seen[item] = true
                    info.saddles[#info.saddles + 1] = item
                end
            end
        end
        info.ridden = growth == MOUNTS and #info.saddles > 0
        return info
    end

    local function icon_of(drops)
        for _, drop in ipairs(drops or {}) do
            local item = m.items[drop.item]
            if item and item.icon then return item.icon end
        end
        return nil
    end

    for _, group in ipairs(groups) do
        local guide = group.guide
        local name = shown(guide.CreatureName) or group.row
        local entry = { id = group.id, row = group.row, name = name, lower = lower(name), image = path(guide.Image),
            boss = guide.bIsBoss == true, workshop = false, tamed = false, ridden = false, biomes = {}, maps = {}, traits = {},
            rank = creatures.NO_RANK, rank_map = 0, rank_share = 0, variants = {} }

        -- Where it is met first: the lowest middle level, then the earlier map, then the larger share of the list.
        local function met(block, place)
            if block.median < entry.rank or (block.median == entry.rank and (place < entry.rank_map
                or (place == entry.rank_map and block.common > entry.rank_share))) then
                entry.rank, entry.rank_map, entry.rank_share = block.median, place, block.common
            end
        end

        local seen = {}
        for _, handle in ipairs(list(guide.Biomes)) do
            local key = key_of(handle)
            local biome = key and biomes[key]
            if key == WORKSHOP then entry.workshop = true end
            if biome and not seen[biome.name] then
                seen[biome.name] = true
                entry.biomes[#entry.biomes + 1] = { row = biome.row, name = biome.name }
            end
        end
        local map_seen = {}
        for _, handle in ipairs(list(guide.Maps)) do
            local terrain = terrains[key_of(handle) or ""]
            if terrain and not map_seen[terrain.name] then
                map_seen[terrain.name] = true
                entry.maps[#entry.maps + 1] = { row = terrain.row, name = terrain.name }
            end
        end
        for _, handle in ipairs(list(guide.Traits)) do
            local trait = trait_names[key_of(handle) or ""]
            if trait then
                local row = src.row("BestiaryTraits", trait.row)
                entry.traits[#entry.traits + 1] = { row = trait.row, name = trait.name, type = row and key_of(row.Type) or nil }
            end
        end

        -- set-ups that would read alike on a page are one variant
        local variants, by_fold = {}, {}
        for _, setup in ipairs(group.setups) do
            local variant = by_fold[setup.fold]
            if not variant then
                variant = { setup = setup.row, key = setup.key, setups = {}, keys = {}, name = setup.kind and setup.kind.name or name,
                    role = setup.role, kind = setup.kind and setup.kind.row or nil, tag = setup.kind and setup.kind.tag or nil,
                    temper = setup.temper, attacks = setup.attacks == true, diet = setup.diet, growth = setup.growth,
                    experience = setup.experience, skin_event = setup.kind and setup.kind.skin or nil,
                    skin = setup.skin or {}, trophy = {}, bones = setup.bones or {}, carcass = {}, areas = {}, epics = {},
                    with = {}, horde = false, near = false, baits = setup.baits, first = #variants + 1 }
                for _, drop in ipairs(setup.trophy or {}) do
                    variant.trophy[#variant.trophy + 1] = { item = drop.item, min = drop.min, max = drop.max, chance = drop.chance,
                        needs = drop.needs or creatures.TROPHY_STAT }
                end
                by_fold[setup.fold] = variant
                variants[#variants + 1] = variant
            end
            variant.setups[#variant.setups + 1] = setup.row
            variant.keys[#variant.keys + 1] = setup.key
            if setup.carcass then
                local held = false
                for _, item in ipairs(variant.carcass) do
                    if item == setup.carcass then held = true end
                end
                if not held then variant.carcass[#variant.carcass + 1] = setup.carcass end
            end
            for _, epic in ipairs(epics_of[setup.key] or {}) do variant.epics[#variant.epics + 1] = epic end
            if in_horde[setup.key] then variant.horde = true end
            if near_players[setup.key] then variant.near = true end
            if boss_of[setup.key] and not variant.boss then variant.boss = { respawn = boss_of[setup.key].respawn } end
            if mount_of[setup.key] and not variant.mount then variant.mount = mount_info(mount_of[setup.key]) end
            for _, other in ipairs(brought[setup.key] or {}) do
                local kind = kind_of(other.CreatureType)
                local label = kind and kind.name or nil
                local held = label == nil
                for _, known in ipairs(variant.with) do
                    if known == label then held = true end
                end
                if not held then variant.with[#variant.with + 1] = label end
            end
        end
        local order = entry.boss and BOSS_ROLES or ROLES
        table.sort(variants, function(a, b)
            if order[a.role] ~= order[b.role] then return order[a.role] < order[b.role] end
            return a.first < b.first
        end)

        local block_maps = {}
        for position, variant in ipairs(variants) do
            variant.first = nil
            variant.icon = icon_of(variant.trophy)
            if not variant.icon then
                for _, item in ipairs(variant.carcass) do
                    variant.icon = variant.icon or (m.items[item] and m.items[item].icon)
                end
            end
            local blocks = blocks_of(zones, listed, places, variant.keys)
            for place, map in ipairs(maps) do
                local block = blocks[place]
                if block then
                    block.map, block.name = map.row, map.name
                    variant.areas[#variant.areas + 1] = block
                    block_maps[map.name] = map
                    met(block, place)
                end
            end
            variant.outposts = blocks[0]
            if variant.mount and variant.mount.ridden then entry.ridden = true end
            for _, key in ipairs(variant.keys) do c.by_setup[key] = { entry = entry.id, variant = position } end
            entry.variants[position] = variant
            c.counts.variants = c.counts.variants + 1
        end
        for _, map in ipairs(maps) do
            if block_maps[map.name] and not map_seen[map.name] then
                map_seen[map.name] = true
                entry.maps[#entry.maps + 1] = { row = map.row, name = map.name }
            end
        end
        -- one that only the outposts list is met there, after those of the maps at that level
        if entry.rank == creatures.NO_RANK then
            for _, variant in ipairs(variants) do
                if variant.outposts then met(variant.outposts, #maps + 1) end
            end
        end

        -- the group's picture: a trophy's, else a carcass's
        for _, variant in ipairs(variants) do
            entry.icon = entry.icon or icon_of(variant.trophy)
        end
        for _, variant in ipairs(variants) do
            entry.icon = entry.icon or variant.icon
        end

        local main = variants[1]
        if main then
            entry.temper, entry.attacks = main.temper, main.attacks
            for _, variant in ipairs(variants) do
                if variant.role ~= "young" then entry.diet = entry.diet or variant.diet end
            end
            for _, variant in ipairs(variants) do entry.diet = entry.diet or variant.diet end
        end

        -- taming: the first taming row that names one of its set-ups, and its tamed variants
        local tame, has_mount = nil, false
        for _, variant in ipairs(variants) do
            if variant.mount then has_mount = true end
        end
        for _, found in ipairs(tame_rows) do
            local own = (found.young and c.by_setup[found.young] and c.by_setup[found.young].entry == entry.id)
                or (found.grown and c.by_setup[found.grown] and c.by_setup[found.grown].entry == entry.id)
                or (found.tamed and c.by_setup[found.tamed] and c.by_setup[found.tamed].entry == entry.id)
            if own then
                tame = { row = found.name }
                local function place(key)
                    local at = key and c.by_setup[key]
                    return at and at.entry == entry.id and at.variant or nil
                end
                tame.young, tame.grown, tame.becomes = place(found.young), place(found.grown), place(found.tamed)
                local row = found.row
                if tame.young or tame.grown then
                    entry.tamed = true
                    local range = type(row.DesiredTemperatureRange) == "table" and row.DesiredTemperatureRange or {}
                    tame.seconds, tame.nutrition = number(row.TameDurationInSeconds, 0), number(row.DesiredNutritionPercentage, 0)
                    tame.shelter, tame.cold, tame.hot = number(row.DesiredShelterPercentage, 0), number(range.X), number(range.Y)
                    tame.not_while = {}
                    for _, handle in ipairs(list(row.ProhibitedTamingModifiers)) do
                        local wanted = ref(handle)
                        local state = wanted and src.row("ModifierStates", wanted)
                        local label = state and shown(state.ModifierName)
                        if label then tame.not_while[#tame.not_while + 1] = label end
                    end
                end
                local chance = number(row.PercentChanceToSpawnJuvenile, 0)
                if tame.young and row.bAutomaticallySpawnJuvenileWithParent == true and chance > 0 then tame.beside = chance end
                local trapped, known = {}, {}
                for _, value in ipairs(list(row.TrappingSupportedAtmospheres)) do
                    local biome = biomes[key_of(type(value) == "table" and value.Value or value) or ""]
                    if biome and not known[biome.name] then
                        known[biome.name] = true
                        trapped[#trapped + 1] = biome.name
                    end
                end
                if tame.grown and trapped[1] then
                    tame.trap_in = trapped
                    for _, setup in ipairs(group.setups) do
                        if setup.key == found.grown then
                            for _, tag in ipairs(setup.baits) do tame.bait = tame.bait or (by_tag[tag] and by_tag[tag][1]) end
                        end
                    end
                end
                local serums = by_tag[SERUM] or {}
                for _, variant in ipairs(variants) do
                    for _, item in ipairs(serums) do
                        if not tame.serum and variant.tag and serum_tags[item][variant.tag] then tame.serum = item end
                    end
                end
                if tame.serum then tame.gestation = number(row.GestationPeriodSeconds, 0) end
                break
            end
        end
        if not tame and has_mount then tame = {} end
        entry.tame = tame

        local parts = { name }
        for _, variant in ipairs(variants) do parts[#parts + 1] = variant.name end
        parts[#parts + 1] = entry.temper and words[entry.temper] or nil
        if entry.attacks then parts[#parts + 1] = words.attacks end
        if entry.boss then parts[#parts + 1] = words.boss end
        if entry.tamed then parts[#parts + 1] = words.tamed end
        if entry.ridden then parts[#parts + 1] = words.ridden end
        parts[#parts + 1] = entry.diet and words[entry.diet] or nil
        for _, biome in ipairs(entry.biomes) do parts[#parts + 1] = biome.name end
        for _, map in ipairs(entry.maps) do parts[#parts + 1] = map.name end
        for _, trait in ipairs(entry.traits) do parts[#parts + 1] = trait.name end
        entry.words = lower(table.concat(parts, " "))

        c.entries[entry.id] = entry
        c.list[#c.list + 1] = entry
        tick(COST.group)
    end

    -- as you meet them: lowest middle level, the earlier map, the commoner one, then by name; bosses last
    table.sort(c.list, function(a, b)
        if a.boss ~= b.boss then return b.boss end
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.rank_map ~= b.rank_map then return a.rank_map < b.rank_map end
        if a.rank_share ~= b.rank_share then return a.rank_share > b.rank_share end
        if a.lower ~= b.lower then return a.lower < b.lower end
        return a.id < b.id
    end)

    -- Which groups a place can have, a map or one outpost, by its D_Terrains row: those a spawn list of its areas names,
    -- on a map those whose own page names the map (a boss is in no spawn list), and everywhere those from the Workshop.
    local at_zone = {}
    for _, held in ipairs({ maps, posts }) do
        for _, found in ipairs(held) do
            local here = { row = found.row, name = found.name, has = {}, count = 0 }
            c.places[fold(found.row)] = here
            for _, zone in ipairs(found.zones) do
                at_zone[zone] = at_zone[zone] or {}
                at_zone[zone][#at_zone[zone] + 1] = here
            end
        end
    end
    local function met_at(here, id)
        if here.has[id] then return end
        here.has[id], here.count = true, here.count + 1
    end
    for _, entry in ipairs(c.list) do
        for _, variant in ipairs(entry.variants) do
            for _, setup in ipairs(variant.keys) do
                for _, zone in ipairs(listed[setup] or {}) do
                    for _, here in ipairs(at_zone[zone] or {}) do met_at(here, entry.id) end
                end
            end
        end
        for _, map in ipairs(entry.maps) do
            local here = c.places[fold(map.row)]
            if here then met_at(here, entry.id) end
        end
        if entry.workshop then
            for _, here in pairs(c.places) do met_at(here, entry.id) end
        end
        tick(COST.entry)
    end

    local counts, place = c.counts, {}
    for position, entry in ipairs(c.list) do
        place[entry.id] = position
        counts.all = counts.all + 1
        if entry.temper then counts[entry.temper] = counts[entry.temper] + 1 end
        if entry.boss then counts.boss = counts.boss + 1 end
        if entry.tamed then counts.tamed = counts.tamed + 1 end
        if entry.ridden then counts.ridden = counts.ridden + 1 end
    end

    -- who gives an item, the best line of each group, most first
    local best = {}
    for _, entry in ipairs(c.list) do
        for position, variant in ipairs(entry.variants) do
            for way, order in pairs(WAYS) do
                for _, drop in ipairs(variant[way]) do
                    local amount = drop.chance / 100 * (drop.min + drop.max) / 2
                    local held = best[drop.item]
                    if not held then
                        held = {}
                        best[drop.item] = held
                    end
                    local known = held[entry.id]
                    local better = not known
                    if known then
                        local a = { known.needs and 1 or 0, -known.amount, known.variant, WAYS[known.way] }
                        local b = { drop.needs and 1 or 0, -amount, position, order }
                        for at = 1, 4 do
                            if a[at] ~= b[at] then
                                better = b[at] < a[at]
                                break
                            end
                        end
                    end
                    if better then
                        held[entry.id] = { entry = entry.id, variant = position, way = way, min = drop.min, max = drop.max,
                            chance = drop.chance, needs = drop.needs, amount = amount }
                    end
                end
            end
        end
        tick(COST.entry)
    end
    for item, held in pairs(best) do
        local lines = {}
        for _, line in pairs(held) do lines[#lines + 1] = line end
        table.sort(lines, function(a, b)
            if (a.needs == nil) ~= (b.needs == nil) then return a.needs == nil end
            if a.amount ~= b.amount then return a.amount > b.amount end
            return place[a.entry] < place[b.entry]
        end)
        c.drops[item] = lines
        counts.items = counts.items + 1
    end

    -- what an item is used on
    local function uses(item, id, as)
        local held = c.uses[item]
        if not held then
            held = {}
            c.uses[item] = held
        end
        for _, known in ipairs(held) do
            if known.entry == id and known.as == as then return end
        end
        held[#held + 1] = { entry = id, as = as }
    end
    for _, entry in ipairs(c.list) do
        for _, variant in ipairs(entry.variants) do
            for _, item in ipairs(variant.mount and variant.mount.saddles or {}) do uses(item, entry.id, "saddle") end
        end
        if entry.tame and entry.tame.bait then uses(entry.tame.bait, entry.id, "bait") end
        if entry.tame and entry.tame.serum then uses(entry.tame.serum, entry.id, "serum") end
    end

    for position, item in ipairs(by_tag[FEED] or {}) do c.feed[position] = item end
    c.trap = by_tag[TRAP] and by_tag[TRAP][1] or nil
    c.knife = m.items[KNIFE] and KNIFE or nil
    for _, problem in ipairs(src.problems) do miss(c, problem.table, problem.field) end
    c.stage = 1
    return c
end

-- The entries that hold every word, pass the filter (a behaviour, "tamed" or "ridden") and, with `item`, give that item.
function creatures.filter(c, typed, which, item)
    local out, gives = {}, nil
    if item then
        gives = {}
        for _, line in ipairs(c.drops[item] or {}) do gives[line.entry] = true end
    end
    for _, entry in ipairs(c.list) do
        local fits = not gives or gives[entry.id] == true
        if fits and which then
            if which == "tamed" or which == "ridden" then fits = entry[which] == true else fits = entry.temper == which end
        end
        if fits then
            for _, word in ipairs(typed or {}) do
                if not entry.words:find(word, 1, true) then
                    fits = false
                    break
                end
            end
        end
        if fits then out[#out + 1] = entry end
    end
    return out
end

-- The place the game's own name for the map it has loaded stands for ("Terrain_016"): its D_Terrains row. Nothing for a
-- map the tables do not place, such as the station.
function creatures.place(c, map)
    if type(map) ~= "string" or type(c.places) ~= "table" then return nil end
    return c.places[fold(map)]
end

local SPEED, SIGHT, HEARING, HEALTH, MELEE, SWIM = "BaseMovementSpeed_+", "BaseAIPerceptionSightRadius_+",
    "BaseAIPerceptionSoundRadius_+", "BaseMaximumHealth_+", "BaseMeleeDamage_+", "BaseSwimSpeed_+"
local KEPT = { food = "BaseMaximumFood_+", food_hour = "BaseFoodConsumptionPerHour_+", water = "BaseMaximumWater_+",
    water_hour = "BaseWaterConsumptionPerHour_+", carry = "BaseWeightCapacity_+", cargo = "BaseMountCargoSlots_+" }
-- stats a page says in a place of their own, so the list of the rest leaves them out
local ATTACK_RATE = "BaseNPCMeleeAttacksPerMinute_+"
local SAID = { [SPEED] = true, [SIGHT] = true, [HEARING] = true, [HEALTH] = true, [MELEE] = true, [SWIM] = true,
    [ATTACK_RATE] = true }
for _, stat in pairs(KEPT) do SAID[stat] = true end

-- The kind of a stat on a creature's page: what it resists, what its attacks cause, or one of the rest.
local function kind_of(name)
    if name:find("Resistance_%+?%%$") then return "resists" end
    if name:find("^BaseAttacksCause") then return "attacks" end
    return "others"
end

-- The stat a trait's own row name ties it to, of those the creature has: "Fire_Weakness" and "Fire_Resist_Strength" a
-- resistance to that damage, "Wound_DamageType" what its attacks cause. Gives the stat's name and its kind, or nothing.
-- A resistance that says the other thing than the trait (a tamed form that resists what its wild one is weak to) is
-- not the trait's figure.
function creatures.trait_stat(trait, has)
    local row = type(trait) == "table" and trait.row or ""
    local weak = row:match("^(%a+)_Weakness$")
    local damage = weak or row:match("^(%a+)_Resist_Strength$")
    if damage then
        for _, ending in ipairs({ "_%", "_+%" }) do
            local name = "Base" .. damage .. "DamageResistance" .. ending
            local value = has[name]
            if type(value) == "number" and value ~= 0 and (value < 0) == (weak ~= nil) then return name, "resists" end
        end
        return nil
    end
    local caused = row:match("^(%a+)_DamageType$") or row:match("^(%a+)_Infliction$")
    local name = caused and ("BaseAttacksCause" .. caused .. "_%")
    if name and has[name] ~= nil then return name, "attacks" end
    return nil
end

-- A figure of a page at a level: a plain number as it is, a curve at that level.
function creatures.figure(value, level)
    if type(value) == "table" then return creatures.at(value, level) end
    return tonumber(value)
end

-- What a page reads through the model's own source and keeps: field guide texts, experience, and numbers while served.
function creatures.detail(c, src, id, position)
    local entry = c.entries[id]
    local variant = entry and entry.variants[position or 1]
    if not variant then return nil end
    local key = id .. ":" .. (position or 1)
    local known = c.details[key]
    if known then return known end
    local d = { lore = {}, xp = {}, epics = {} }

    local guide = src.detail("BestiaryData", entry.row)
    for _, field in ipairs({ "Lore1", "Lore2", "Lore3" }) do
        local words = guide and trim(guide[field]):gsub("  +", " ") or ""
        if words ~= "" then d.lore[#d.lore + 1] = words end
    end
    d.points = guide and number(guide.TotalPointsRequired, nil) or nil
    if guide and src.serves("BestiaryData", "StatsUnlock1") then
        d.rewards = {}
        for _, field in ipairs({ "StatsUnlock1", "StatsUnlock2" }) do
            for _, pair in ipairs(creatures.stat_pairs(guide[field]) or {}) do d.rewards[#d.rewards + 1] = pair end
        end
    end

    local skin = variant.skin_event and src.detail("ExperienceEvents", variant.skin_event)
    d.xp.skin = skin and number(skin.ExperienceGranted, nil) or nil
    local given = variant.experience and src.serves("Experience", "ExperienceEvents") and src.detail("Experience", variant.experience)
    local event = given and death_event(given.ExperienceEvents)
    local kill = event and src.detail("ExperienceEvents", event)
    d.xp.kill = kill and number(kill.ExperienceGranted, nil) or nil

    local growth = variant.growth and src.serves("AIGrowth", "Base") and src.detail("AIGrowth", variant.growth)
    local base = growth and creatures.stat_pairs(growth.Base)
    if base then
        -- a stat the row gives by level stands for the plain one of that name
        local by_name, stats = {}, { resists = {}, attacks = {}, others = {}, traits = {} }
        for _, pair in ipairs(base) do by_name[pair.name] = pair.value end
        if src.serves("AIGrowth", "CustomStats.Curve") then
            for _, custom in ipairs(list(growth.CustomStats)) do
                local name = type(custom.Stat) == "table" and custom.Stat.Value or nil
                local curve = creatures.curve(custom.Curve)
                if type(name) == "string" and curve then
                    if by_name[name] == nil then base[#base + 1] = { name = name } end
                    by_name[name] = curve
                end
            end
            table.sort(base, function(a, b) return a.name < b.name end)
        end
        -- what a trait of the group says is said with the trait, so the lists under it leave it out
        local tied = {}
        for _, trait in ipairs(entry.traits) do
            local name = creatures.trait_stat(trait, by_name)
            if name and not tied[name] then
                tied[name] = true
                stats.traits[trait.row] = { name = name, value = by_name[name] }
            end
        end
        for _, pair in ipairs(base) do
            local kind = kind_of(pair.name)
            if not tied[pair.name] and not SAID[pair.name] then
                stats[kind][#stats[kind] + 1] = { name = pair.name, value = by_name[pair.name] }
            end
        end
        stats.health = creatures.curve(growth.Health) or by_name[HEALTH]
        stats.damage = creatures.curve(growth.MeleeDamage) or by_name[MELEE]
        local function plain(stat) return type(by_name[stat]) == "number" and by_name[stat] or nil end
        stats.speed, stats.sight, stats.hearing, stats.swim = plain(SPEED), plain(SIGHT), plain(HEARING), plain(SWIM)
        stats.attack_rate = plain(ATTACK_RATE)
        if src.serves("AIGrowth", "ExperienceMultiplier") then stats.xp_times = creatures.curve(growth.ExperienceMultiplier) end
        for name, stat in pairs(KEPT) do stats[name] = plain(stat) end
        local setup = src.serves("AISetup", "MovementMapping") and src.detail("AISetup", variant.setup)
        stats.states = setup and creatures.speeds(setup.MovementMapping) or nil
        -- a tamed one stops at its growth row's top level, a wild one where its health curve ends
        if variant.mount and variant.mount.top then
            stats.last = variant.mount.top
        elseif type(stats.health) == "table" then
            stats.last = stats.health.last
        elseif type(stats.damage) == "table" then
            stats.last = stats.damage.last
        end
        d.stats = stats
    end

    if src.serves("EpicCreatures", "AdditionalStats") then
        for at, epic in ipairs(variant.epics) do
            local row = src.detail("EpicCreatures", epic.row)
            d.epics[at] = row and creatures.stat_pairs(row.AdditionalStats) or {}
        end
    end

    -- the Critical Damage a character starts with, read once: what a critical area's share is of
    local crit = c.crit
    if crit and crit.start == nil then
        crit.start = false
        local first = src.serves("CharacterStartingStats", "StatsGranted") and src.names("CharacterStartingStats")[1]
        local granted = first and src.detail("CharacterStartingStats", first)
        for _, pair in ipairs(granted and creatures.stat_pairs(granted.StatsGranted) or {}) do
            if pair.name == "Base" .. creatures.CRIT_STAT and pair.value > 0 then crit.start = pair.value end
        end
    end
    if crit and crit.start then d.crit = { start = crit.start, shares = crit.shares } end

    c.details[key] = d
    return d
end

-- The XP a kill gives at a level: the event's own, times the growth row's multiplier while XP_BY_LEVEL is on.
function creatures.kill_xp(detail, level)
    local base = detail and detail.xp and detail.xp.kill
    if not base then return nil end
    local times = creatures.XP_BY_LEVEL and detail.stats and creatures.at(detail.stats.xp_times, level) or nil
    return times and base * times or base, times ~= nil
end

-- What a list of creatures can be put in order by: of a group's first variant, each only where a row gives it.
-- speed: its fastest movement state. health, damage: at `level`, or where its own levels end before that (the level
-- used is given as level). xp: for a kill.
function creatures.figures(c, src, id, level)
    local d = creatures.detail(c, src, id, 1)
    if not d then return nil end
    local out, stats = {}, d.stats
    if stats then
        local fastest = 0
        for state, times in pairs(stats.states or {}) do
            if creatures.MOVING[state] and times > fastest then fastest = times end
        end
        if stats.speed then out.speed = stats.speed * fastest end
        out.level = stats.last and math.min(level, stats.last) or level
        out.health, out.damage = creatures.at(stats.health, out.level), creatures.at(stats.damage, out.level)
        out.sight, out.hearing = stats.sight, stats.hearing
    end
    out.xp = d.xp.kill
    for name, value in pairs(out) do
        if type(value) ~= "number" or value <= 0 then out[name] = nil end
    end
    return out
end

return creatures
