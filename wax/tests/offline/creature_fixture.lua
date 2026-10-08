-- The Bestiary suites' stand-in for game.Data: real rows of seven creature groups (creature_rows.lua, cut from
-- game-data by scripts/creature_check.py --fixture) behind the provider of recipe_fixture.lua.
--   local fixture = dofile("wax/tests/offline/creature_fixture.lua")
--   local provider = fixture.provider()                  -- maps and curves refused, as the game refuses them today
--   local later = fixture.provider({ maps = true })      -- served, in the shapes the files have them
--   local other = fixture.provider({ tables = fixture.copy() })   -- over a copy a test changed first

local fixture = {}

local recipes = dofile("wax/tests/offline/recipe_fixture.lua")

-- The map and curve fields the Bestiary lists as maybe. game.Data refuses a field of these kinds by name.
fixture.MAPS = {
    AIGrowth = { Base = "Map", Health = "Object", MeleeDamage = "Object", ExperienceMultiplier = "Object", CustomStats = "Object" },
    CharacterStartingStats = { StatsGranted = "Map" },
    AISetup = { MovementMapping = "Map" },
    EpicCreatures = { AdditionalStats = "Map" },
    Experience = { ExperienceEvents = "Map" },
    BestiaryData = { StatsUnlock1 = "Map", StatsUnlock2 = "Map" },
}

local rows = nil

function fixture.tables()
    rows = rows or dofile("wax/tests/offline/creature_rows.lua")
    return rows
end

local function clone(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, inner in pairs(value) do out[key] = clone(inner) end
    return out
end

function fixture.copy() return clone(fixture.tables()) end

-- A row of a table of the fixture as the files have it, for a test to change in a copy.
function fixture.find(tables, name, row)
    for _, found in ipairs(tables[name] and tables[name].rows or {}) do
        if found.Name:lower() == row:lower() then return found end
    end
    return nil
end

-- tables: any tables in the format of creature_rows.lua. options: maps (default false), strict (default true)
function fixture.serve(tables, options)
    options = options or {}
    local provider = recipes.serve(tables, { strict = options.strict })
    if options.maps then return provider end
    local open, wrapped = provider.Table, {}

    local function refuse(name, fields)
        local kinds = fixture.MAPS[name]
        for _, field in ipairs(kinds and fields or {}) do
            local top = field:match("^[^.]+")
            if kinds[top] then
                error(("'%s' is %s %s field, which game.Data never reads"):format(top, kinds[top] == "Object" and "an" or "a",
                    kinds[top]), 0)
            end
        end
    end

    function provider:Table(name)
        local object = open(self, name)
        local short = name:gsub("^D_", "")
        if wrapped[object] then return wrapped[object] end
        local outer = setmetatable({}, { __index = object })
        function outer:Row(row, fields)
            refuse(short, fields)
            return object:Row(row, fields)
        end
        function outer:Load(request)
            refuse(short, request and request.fields)
            return object:Load(request)
        end
        wrapped[object] = outer
        return outer
    end

    return provider
end

function fixture.provider(options)
    options = options or {}
    return fixture.serve(options.tables or fixture.tables(), options)
end

-- The mod's files with the standard library and nothing else, so a use of Wax or the engine fails here.
function fixture.parts(folder)
    return function(name, extra)
        local env = { string = string, table = table, math = math, select = select, type = type, pairs = pairs, ipairs = ipairs,
            next = next, tostring = tostring, tonumber = tonumber, setmetatable = setmetatable, getmetatable = getmetatable,
            error = error, pcall = pcall, rawget = rawget, rawset = rawset }
        for key, value in pairs(extra or {}) do env[key] = value end
        setmetatable(env, { __index = function(_, key) error(name .. ".lua reads the global '" .. tostring(key) .. "'", 2) end })
        local chunk = assert(loadfile(folder .. "/" .. name .. ".lua", "t", env))
        local value = chunk()
        assert(type(value) == "table" or type(value) == "function", name .. ".lua must return a table or a function")
        return value
    end
end

-- The item model and the creature model over a provider, as the mod builds them.
-- parts: the result of fixture.parts. options: words, lower, stages (how far the item model is built, default 2)
function fixture.build(part, provider, options)
    options = options or {}
    local source, tags, model, creatures = part("source"), part("tags"), part("model"), part("creatures")
    local items = source.new(provider)
    local b = model.begin(items, options.lower or string.lower, tags)
    items.read(1, 1)
    model.items(b)
    if (options.stages or 2) >= 2 then
        items.read(2, 1)
        model.recipes(b)
    end
    local src = source.new(provider, creatures.TABLES)
    src.read(1, 1)
    local c = creatures.build(src, b.model, { lower = options.lower, words = options.words, pause = options.pause })
    return c, b.model, src, items
end

return fixture
