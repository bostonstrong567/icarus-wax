-- What a recipe needs before it can be made: tier, tech tree node, level, pack, mission, talent.

local unlock = { PAUSE_ROWS = 150 }

local FLAG_TABLES = { "CharacterFlags", "SessionFlags", "AccountFlags", "DLCPackageData" }
local NEEDED = { "Talents", "TalentTrees", "TalentArchetypes", "ProspectList", "CharacterFlags", "SessionFlags", "AccountFlags",
    "DLCPackageData" }
local PIECES = { "known", "mission_only", "no_talent", "no_station", "level", "pack", "mission", "talent" }
local EMPTY = { short = "", full = "", extra = "", tone = "dim", missing = false }

local function fold(name)
    return (name:lower())
end

local function ref(handle)
    local name = handle
    if type(handle) == "table" then name = handle.RowName end
    if type(name) ~= "string" or name == "" or name:lower() == "none" then return nil end
    return name
end

local function words(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function list(value)
    if type(value) ~= "table" then return {} end
    return value
end

local function row_of(source, name, handle)
    local wanted = ref(handle)
    return wanted and source.row(name, wanted) or nil
end

local function fill(piece, value)
    if type(piece) == "function" then return piece(value) end
    return (tostring(piece):format(value))
end

local function pieces_of(text, level)
    local pieces = type(text) == "table" and text.needs or nil
    if type(pieces) ~= "table" or type(text.join) ~= "function" then
        error("the needs line takes the text table (text.needs and text.join)", level + 1)
    end
    for _, piece in ipairs(PIECES) do
        if pieces[piece] == nil then error("the needs line takes text.needs." .. piece, level + 1) end
    end
    return pieces
end

-- Gives an index that was kept across a reload of the mod the new text table. Its lines are made afresh.
function unlock.rebind(index, text)
    index.pieces, index.join, index.cache = pieces_of(text, 2), text.join, {}
    return index
end

-- Joins what is already loaded. `text` is the mod's text table: its needs pieces and its join.
function unlock.index(source, pause, text)
    local pieces = pieces_of(text, 2)
    local index = { pieces = pieces, join = text.join, flags = {}, clashes = {}, talents = {}, grants = {}, packs = {}, missions = {},
        tiers = {}, cache = {}, off = false }
    for _, name in ipairs(NEEDED) do
        if source.broken[name] then index.off = true end
    end
    if index.off then return index end

    for _, name in ipairs(FLAG_TABLES) do
        for _, row in ipairs(source.names(name)) do
            local key = fold(row)
            local held = index.flags[key]
            if held and held ~= name then
                index.clashes[#index.clashes + 1] = { row = row, tables = { held, name } }
            else
                index.flags[key] = name
            end
        end
    end
    for _, name in ipairs(source.names("DLCPackageData")) do
        local row = source.row("DLCPackageData", name)
        if row then index.packs[fold(name)] = words(row.DLCName) end
    end
    for _, name in ipairs(source.names("AccountFlags")) do
        local row = source.row("AccountFlags", name)
        local missions = {}
        for _, handle in ipairs(list(row and row.RewardedFromMissions)) do
            local mission = row_of(source, "ProspectList", handle)
            local label = mission and words(mission.DropName) or ""
            if label ~= "" then missions[#missions + 1] = label end
        end
        index.missions[fold(name)] = missions
    end

    local count = 0
    for _, name in ipairs(source.names("Talents")) do
        local row = source.row("Talents", name)
        if row then
            local key = fold(name)
            local tree = row_of(source, "TalentTrees", row.TalentTree)
            local tier = tree and row_of(source, "TalentArchetypes", tree.Archetype)
            local label = words(row.DisplayName)
            if label == "" then
                local item = row_of(source, "Itemable", row.ExtraData)
                label = item and words(item.DisplayName) or ""
            end
            local flags
            for _, handle in ipairs(list(row.RequiredFlags)) do
                local flag = ref(handle)
                if flag then
                    flags = flags or {}
                    flags[#flags + 1] = fold(flag)
                end
            end
            index.talents[key] = { name = label, tier = tier and words(tier.DisplayName) or "",
                tier_level = tier and tonumber(tier.RequiredLevel) or 0, level = tonumber(row.RequiredLevel) or 0,
                start = row.bDefaultUnlocked == true, flags = flags }
            for _, reward in ipairs(list(row.Rewards)) do
                for _, handle in ipairs(list(reward.GrantedFlags)) do
                    local flag = ref(handle)
                    if flag and not index.grants[fold(flag)] then index.grants[fold(flag)] = key end
                end
            end
        end
        count = count + 1
        if count % unlock.PAUSE_ROWS == 0 and pause then pause() end
    end
    return index
end

-- The lowest tier among the recipes that make a set's benches, or false.
local function tier_of_set(index, model, id)
    local known = index.tiers[id]
    if known ~= nil then return known end
    local best
    local set = model.sets[id]
    for _, bench in ipairs(set and set.benches or {}) do
        for _, number in ipairs(model.made_by[bench.item] or {}) do
            local maker = model.recipes[number]
            local talent = maker and maker.talent and index.talents[maker.talent]
            if talent and talent.tier ~= "" and (not best or talent.tier_level < best.level) then
                best = { name = talent.tier, level = talent.tier_level }
            end
        end
    end
    index.tiers[id] = best or false
    return best or false
end

-- The level a recipe asks of the player, as a number to sort by: that of its own node in the tech tree, else that of
-- the lowest tier a bench for it comes in, else 0.
function unlock.level(index, model, recipe)
    if not index or index.off or not model or not recipe then return 0 end
    local talent = recipe.talent and index.talents[recipe.talent] or nil
    if talent then return math.max(talent.level, talent.tier_level) end
    local lowest = nil
    for _, id in ipairs(recipe.stations or {}) do
        local tier = tier_of_set(index, model, id)
        if tier and (not lowest or tier.level < lowest) then lowest = tier.level end
    end
    return lowest or 0
end

local function add(entries, value)
    if value == "" then return end
    for _, known in ipairs(entries) do
        if known == value then return end
    end
    entries[#entries + 1] = value
end

-- Returns { short, full, extra, tone, tier, level, missing } and the parts the texts were made from.
function unlock.describe(index, model, recipe)
    if not index or index.off or not model or not recipe then return EMPTY end
    local cached = index.cache[recipe.id]
    if cached then return cached end
    local pieces, join = index.pieces, index.join
    local result = { short = "", full = "", extra = "", tone = "dim", missing = false, packs = {}, missions = {}, talents = {},
        mission_only = false }
    index.cache[recipe.id] = result

    local talent = recipe.talent and index.talents[recipe.talent] or nil
    if recipe.talent and not talent then
        result.missing, result.tone = true, "bad"
        result.short, result.full = pieces.no_talent, pieces.no_talent
        return result
    end
    if recipe.disabled or not recipe.stations or #recipe.stations == 0 then
        result.tone, result.cannot = "bad", true
        result.short, result.full = pieces.no_station, pieces.no_station
        return result
    end

    local flags = {}
    if talent then
        result.tier, result.node, result.start = talent.tier, talent.name, talent.start
        result.level = math.max(talent.level, talent.tier_level)
        for _, flag in ipairs(talent.flags or {}) do flags[#flags + 1] = flag end
    else
        local lowest
        for _, id in ipairs(recipe.stations) do
            local tier = tier_of_set(index, model, id)
            if tier and (not lowest or tier.level < lowest.level) then lowest = tier end
        end
        result.tier = lowest and lowest.name or nil
    end
    if recipe.session then flags[#flags + 1] = recipe.session end

    local function need_talent(flag)
        local giver = index.grants[flag]
        if giver then add(result.talents, index.talents[giver].name) end
    end
    for _, flag in ipairs(flags) do
        local where = index.flags[flag]
        if where == "DLCPackageData" then
            add(result.packs, index.packs[flag] or "")
        elseif where == "AccountFlags" then
            for _, mission in ipairs(index.missions[flag] or {}) do add(result.missions, mission) end
        elseif where == "SessionFlags" then
            result.mission_only = true
        elseif where == "CharacterFlags" then
            need_talent(flag)
        end
    end
    if recipe.char_flag then need_talent(recipe.char_flag) end

    local tail = ""
    if talent then
        if talent.start then
            tail = pieces.known
        elseif result.level > 0 then
            tail = fill(pieces.level, result.level)
        end
    end
    local node = talent and talent.name or ""
    local short_node = node
    for _, pack in ipairs(result.packs) do
        if pack == node then short_node = "" end
    end
    result.full = join(result.tier or "", node, tail)
    result.short = join(result.tier or "", short_node, tail)

    local extra = {}
    for _, pack in ipairs(result.packs) do extra[#extra + 1] = fill(pieces.pack, pack) end
    for _, mission in ipairs(result.missions) do extra[#extra + 1] = fill(pieces.mission, mission) end
    if result.mission_only then extra[#extra + 1] = pieces.mission_only end
    for _, name in ipairs(result.talents) do extra[#extra + 1] = fill(pieces.talent, name) end
    result.extra = join(extra)
    if result.extra ~= "" then result.tone = "warn" end
    return result
end

return unlock
