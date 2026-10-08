-- What a model view shows for a creature: its mesh, fur and animations, from a list made of the game's own files

local Wax = ...
local suggest = Wax.import("core.suggest")

local M = {}

local SETUP_TABLE = "/Engine/Transient.D_AISetup"
local list = nil            -- data/creature_models.lua, read on first use
local shown = nil           -- the set-up names as the game spells them, for suggestions

-- Names are compared without case, spaces, underscores or hyphens, as game.Creatures compares them.
local function fold(text) return (tostring(text):lower():gsub("[%s_%-]", "")) end

local function read()
    if list then return list end
    local chunk, problem = loadfile(Wax.root .. "/data/creature_models.lua")
    if not chunk then error("Wax's list of creature models could not be read: " .. tostring(problem), 0) end
    local found = chunk()
    if type(found) ~= "table" or type(found.looks) ~= "table" or type(found.rows) ~= "table" then
        error("Wax's list of creature models is not in the form this version reads", 0)
    end
    found.names, found.kinds = found.names or {}, found.kinds or {}
    shown = {}
    for _, name in pairs(found.names) do shown[#shown + 1] = name end
    table.sort(shown)
    list = found
    return found
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, inner in pairs(value) do out[key] = copy(inner) end
    return out
end

-- Whether the running game has a set-up row of this name. The list may be older than the game.
local function in_game(name)
    local ok, found = pcall(function()
        local setups = StaticFindObject(SETUP_TABLE)
        return setups:IsValid() and setups:FindRow(name) ~= nil
    end)
    return ok and found == true
end

local function check_name(name, level)
    if type(name) ~= "string" or name == "" then
        error(("a creature is named by its set-up row, such as \"Bear\", not by %s"):format(name == "" and "an empty text" or "a " .. type(name)), level + 1)
    end
end

-- The key of a set-up or of a kind's first set-up, whether or not Wax has a model for it.
local function key_of(data, name)
    local key = fold(name)
    if not data.rows[key] and data.kinds[key] then key = data.kinds[key] end
    return key
end

-- Why a name has no look: nil and a reason, or an error when it is no creature at all.
local function missing(data, key, name, level)
    if data.names[key] then return nil, ("Wax has no model for %s"):format(data.names[key]) end
    if in_game(name) then return nil, ("%s is newer than Wax's list of models. An update of Wax will bring it."):format(name) end
    error(("'%s' is not a creature set-up.%s"):format(name, suggest.phrase(name, shown)), level + 1)
end

-- The saddle of a mount that is named by its row, its tag or an item that carries the tag. Nil and why when none is.
local function saddle_of(data, key, wanted)
    local found = data.saddles and data.saddles[key]
    local mount = data.names[key] or key
    if not found then return nil, ("%s wears no saddle in Wax's list of models"):format(mount) end
    local folded, known = fold(wanted), {}
    for _, entry in ipairs(found) do
        if fold(entry.row) == folded or (entry.tag and fold(entry.tag) == folded) then return entry end
        for _, item in ipairs(entry.items or {}) do
            if fold(item) == folded then return entry end
            known[#known + 1] = item
        end
        known[#known + 1] = entry.row
    end
    return nil, ("Wax's list has no saddle '%s' for %s.%s"):format(wanted, mount, suggest.phrase(wanted, known))
end

-- What to give Container:Model for a set-up row ("Bear", "Conifer_Wolf") or a kind ("Wolf"). Nil and why when Wax has no model for it.
-- options.saddle: a saddle the mount wears in the picture, by its item ("Saddle_Standard"), its tag or its own row.
function M.get(name, level, options)
    level = (level or 1) + 1
    check_name(name, level)
    if options ~= nil and type(options) ~= "table" then
        error("GetModel's second argument is a table such as { saddle = \"Saddle_Standard\" }", level)
    end
    local wanted = options and options.saddle
    if wanted ~= nil and (type(wanted) ~= "string" or wanted == "") then
        error("saddle is the name of a saddle's item, such as \"Saddle_Standard\"", level)
    end
    local data = read()
    local key = key_of(data, name)
    local at = data.rows[key]
    if not at then
        -- two steps: a tail call would lose the line of whoever asked from the error
        local nothing, reason = missing(data, key, name, level)
        return nothing, reason
    end
    local look = copy(data.looks[at])
    look.walks = look.walk ~= nil
    if not wanted then return look end
    local entry, why = saddle_of(data, key, wanted)
    local part = entry and data.worn and data.worn[entry.part]
    if not part then return nil, why or ("Wax's list has no mesh for the saddle '%s'"):format(wanted) end
    look.parts = look.parts or {}
    look.parts[#look.parts + 1] = copy(part)
    -- the game keeps the mount's fur from growing through this saddle
    local coat = entry.mask and look.fur and look.fur[entry.fur or 1]
    if coat then coat.mask = entry.mask end
    return look
end

-- The saddles Wax can put on a set-up's model, in the game's order: { Row, Tag, Items }. Empty for what wears none.
function M.saddles(name, level)
    level = (level or 1) + 1
    check_name(name, level)
    local data = read()
    local key = key_of(data, name)
    if not data.rows[key] then
        local _, why = missing(data, key, name, level)
        return {}, why
    end
    local out = {}
    for index, entry in ipairs(data.saddles and data.saddles[key] or {}) do
        out[index] = { Row = entry.row, Tag = entry.tag, Items = copy(entry.items or {}) }
    end
    return out
end

-- Every set-up Wax has a model for, as the game spells it.
function M.names()
    local data, out = read(), {}
    for key in pairs(data.rows) do out[#out + 1] = data.names[key] or key end
    table.sort(out)
    return out
end

-- The build of the game the list was made from.
function M.build() return read().build end

-- Hangs GetModel and GetSaddles on game.Creatures.
function M.start()
    local creatures = Wax.import("world.creatures").api
    rawset(creatures, "GetModel", function(_, name, options)
        local look, why = M.get(name, 2, options)
        return look, why
    end)
    rawset(creatures, "GetSaddles", function(_, name)
        local found, why = M.saddles(name, 2)
        return found, why
    end)
    local meta = getmetatable(creatures)
    local names = meta and meta.__names and meta.__names()
    if type(names) == "table" then
        for _, added in ipairs({ "GetModel", "GetSaddles" }) do
            local there = false
            for _, known in ipairs(names) do there = there or known == added end
            if not there then names[#names + 1] = added end
        end
    end
end

return M
