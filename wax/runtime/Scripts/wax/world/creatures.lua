-- game.Creatures: the animals and enemies in the world, by kind

local Wax = ...
local track = Wax.import("engine.track")
local instance = Wax.import("engine.instance")
local reflect = Wax.import("engine.reflect")
local suggest = Wax.import("core.suggest")
local sched = Wax.import("core.sched")

local M = {}

local SETUP_TABLE, TYPE_TABLE = "/Engine/Transient.D_AISetup", "/Engine/Transient.D_AICreatureType"
local METRE = 100
local DEATHS_PER_FRAME = 8
local NAMES = { "GetAll", "GetNearest", "Count", "GetKinds", "GetLiveKinds", "GetKind", "Describe", "Observe",
                "Highlight", "Added", "Removed", "Died", "Cleared" }

local kinds = nil           -- read from the game's own tables on first use
local class_facts = {}      -- class address -> which properties that class has
local Died = sched.Signal.new("creatures.Died")
local tracked

-- Names are compared without case, spaces or underscores, because the game does not spell them one way.
local function fold(text) return (tostring(text):lower():gsub("[%s_%-]", "")) end

local function load_kinds()
    if kinds then return kinds end
    local setup, types = StaticFindObject(SETUP_TABLE), StaticFindObject(TYPE_TABLE)
    if not (setup:IsValid() and types:IsValid()) then
        error("this version of the game has no D_AISetup or D_AICreatureType table, so creature kinds cannot be read", 0)
    end
    local found = { types = {}, setups = {}, shown = {}, list = {}, names = {} }
    local function new_kind(name, display, tag)
        local record = { Name = name, DisplayName = display, Tag = tag, Variants = {} }
        found.types[fold(name)] = record
        found.list[#found.list + 1] = record
        found.names[#found.names + 1] = name
        return record
    end
    for _, name in ipairs(types:GetRowNames()) do
        local row = types:FindRow(name)
        if row then
            local record = new_kind(name, row.CreatureName:ToString(), row.Tag.TagName:ToString())
            if record.DisplayName == "" then record.DisplayName = name end
            found.shown[fold(record.DisplayName)] = record
        end
    end
    for _, name in ipairs(setup:GetRowNames()) do
        local row = setup:FindRow(name)
        if row then
            local record = found.types[fold(row.CreatureType.RowName:ToString())] or new_kind(name, name, "")
            record.Variants[#record.Variants + 1] = name
            found.setups[fold(name)] = { Name = name, kind = record }
            found.names[#found.names + 1] = name
        end
    end
    kinds = found
    return found
end

-- For a creature whose row is not filled in: the row that names its class.
local function setup_of_class(index, class)
    if not index.classes then
        index.classes = {}
        local setup = StaticFindObject(SETUP_TABLE)
        for _, record in pairs(index.setups) do
            local row = setup:FindRow(record.Name)
            local ok, path = pcall(function() return row.ActorClass:GetObjectID():GetAssetPathName():ToString() end)
            local class_name = ok and path:match("([^%.]+)$")
            if class_name and not index.classes[class_name] then index.classes[class_name] = record end
        end
    end
    return index.classes[class:GetFName():ToString()]
end

local function classify(actor, last, entry)
    local class = actor:GetClass()
    local class_address = class:GetAddress()
    local facts = class_facts[class_address]
    if not facts then
        local members = reflect.class_info(class).members
        facts = { row = members.AISetup and "AISetup" or members.AISetupRow and "AISetupRow" or false,
                  state = members.ActorState ~= nil, level = members.CurrentLevel ~= nil }
        class_facts[class_address] = facts
    end
    if not facts.row then return false end
    entry.has_state, entry.has_level = facts.state, facts.level
    local index = load_kinds()
    local row = actor[facts.row].RowName:ToString()
    local setup = index.setups[fold(row)]
    if not setup then
        if row ~= "None" and row ~= "" then return row, row end
        if not last then return nil end
        setup = setup_of_class(index, class)
        if not setup then return "Unknown" end
    end
    return setup.kind.Name, setup.Name
end

local LEFT_BEHIND = "Enum_CurrentAliveState"    -- the global UE4SS makes each time that enum is read

local function is_alive(entry)
    if not entry.has_state then return true end
    local state = entry.object.ActorState
    if not state:IsValid() then return true end
    local alive = state.CurrentAliveState == 0
    if rawget(_G, LEFT_BEHIND) ~= nil then rawset(_G, LEFT_BEHIND, nil) end
    return alive
end

local function watch_deaths(set)
    if Died.count == 0 then return end
    local sweep = set.sweep
    if not sweep or set.cursor > #sweep then
        sweep, set.cursor = {}, 1
        for _, entry in pairs(set.entries) do
            if entry.has_state then sweep[#sweep + 1] = entry end
        end
        set.sweep = sweep
    end
    for _ = 1, DEATHS_PER_FRAME do
        local entry = sweep[set.cursor]
        if not entry then break end
        set.cursor = set.cursor + 1
        if not entry.destroyed then
            local dead = not is_alive(entry)
            local known = entry.dead
            entry.dead = dead
            if dead and known == false then
                Died:Fire(entry.instance, { Kind = entry.kind, Variant = entry.variant, ClassName = entry.class_name,
                                            Name = entry.name })
            end
        end
    end
end

tracked = track.define("creatures", {
    roots = { "/Script/Icarus.IcarusNPCCharacter", "/Script/Icarus.IcarusPawn" },
    seed = { "IcarusNPCCharacter", "IcarusPawn" },
    classify = classify,
    step = watch_deaths,
})
tracked.Cleared:Connect(function()
    class_facts = {}
    tracked.sweep = nil
end)

-- "all" | "kinds", name | "variants", name | "class", name
local function resolve(kind, level)
    if kind == nil then return "all" end
    if type(kind) ~= "string" then
        error(("a creature kind is a name such as \"Wolf\", got %s"):format(type(kind)), level + 1)
    end
    local index, key = load_kinds(), fold(kind)
    if index.types[key] then return "kinds", index.types[key].Name end
    if index.setups[key] then return "variants", index.setups[key].Name end
    if index.shown[key] then return "kinds", index.shown[key].Name end
    if kind:find("^BP_") or kind:find("^Icarus") or kind:find("_C$") then return "class", kind end
    error(("'%s' is not a creature kind.%s"):format(kind, suggest.phrase(kind, index.names)), level + 1)
end

local function matching(set, how, name)
    local out = {}
    if how == "all" then
        for _, entry in pairs(set.entries) do out[#out + 1] = entry end
    elseif how == "class" then
        for _, entry in pairs(set.entries) do
            if entry.instance:IsA(name) then out[#out + 1] = entry end
        end
    else
        local group = set[how][name]
        if group then
            for entry in pairs(group) do out[#out + 1] = entry end
        end
    end
    return out
end

local function fits(entry, how, name)
    if how == "all" then return true end
    if how == "kinds" then return entry.kind == name end
    if how == "variants" then return entry.variant == name end
    return entry.instance:IsA(name)
end

local function spot(actor)
    local at = actor:K2_GetActorLocation()
    return at.X, at.Y, at.Z
end

local function origin(from, level)
    if from == nil then
        local me = Wax.game.Character
        if not me then
            error("there is no character to measure from right now. Pass `from`: an Instance or a position", level + 1)
        end
        return spot(me.Raw)
    end
    if instance.is_instance(from) and from:IsA("Actor") then return spot(from.Raw) end
    if type(from) == "table" and type(from.X) == "number" and type(from.Y) == "number" and type(from.Z) == "number" then
        return from.X, from.Y, from.Z
    end
    error("`from` must be an actor or a position such as { X = 0, Y = 0, Z = 0 }", level + 1)
end

-- Returns the matching creatures and, when distances were measured, each one's distance in metres.
local function query(kind, options, level)
    if type(kind) == "table" and not instance.is_instance(kind) then kind, options = nil, kind end
    options = options or {}
    if type(options) ~= "table" then error("the options must be a table such as { within = 50 }", level + 1) end
    local reach = options.within
    if reach ~= nil and type(reach) ~= "number" then error("`within` is a number of metres", level + 1) end
    local set = tracked:use()
    local found = matching(set, resolve(kind, level + 1))
    local out, far = {}, nil
    local x, y, z
    if reach or options.from ~= nil or options.sort == "nearest" then
        x, y, z = origin(options.from, level + 1)
        far = {}
    end
    for i = 1, #found do
        local entry = found[i]
        if options.dead or is_alive(entry) then
            if far then
                local ex, ey, ez = spot(entry.object)
                local distance = math.sqrt((ex - x) ^ 2 + (ey - y) ^ 2 + (ez - z) ^ 2) / METRE
                if not reach or distance <= reach then
                    out[#out + 1] = entry.instance
                    far[entry.instance] = distance
                end
            else
                out[#out + 1] = entry.instance
            end
        end
    end
    if far then table.sort(out, function(a, b) return far[a] < far[b] end) end
    return out, far
end

local Creatures = {}

-- Every creature, or those of one kind ("Wolf", "Conifer_Wolf", "Cave Worm"). Options: within, from, dead, sort.
function Creatures:GetAll(kind, options)
    return (query(kind, options, 2))
end

-- The closest matching creature and its distance in metres, or nil.
function Creatures:GetNearest(kind, options)
    if type(kind) == "table" and not instance.is_instance(kind) then kind, options = nil, kind end
    local wanted = { sort = "nearest" }
    for key, value in pairs(options or {}) do wanted[key] = value end
    local found, far = query(kind, wanted, 2)
    if not found[1] then return nil, nil end
    return found[1], far[found[1]]
end

function Creatures:Count(kind)
    local set = tracked:use()
    local how, name = resolve(kind, 2)
    if how == "all" then return set.count end
    if how == "class" then return #matching(set, how, name) end
    return set.counts[how][name] or 0
end

-- Every kind this version of the game has, with how many are in the world now.
function Creatures:GetKinds()
    local set, out = tracked:use(), {}
    for i, record in ipairs(load_kinds().list) do
        out[i] = { Name = record.Name, DisplayName = record.DisplayName, Tag = record.Tag,
                   Variants = table.move(record.Variants, 1, #record.Variants, 1, {}),
                   Count = set.counts.kinds[record.Name] or 0 }
    end
    table.sort(out, function(a, b) return a.Name < b.Name end)
    return out
end

-- The names of the kinds that are in the world now.
function Creatures:GetLiveKinds()
    local out = {}
    for name, count in pairs(tracked:use().counts.kinds) do
        if count > 0 then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

-- The kind and variant of a creature, or nil when it is not a creature in the world.
function Creatures:GetKind(creature)
    local entry = tracked:use():entry_of(creature)
    if not entry then return nil, nil end
    return entry.kind, entry.variant
end

-- The common facts about one creature as plain values.
function Creatures:Describe(creature)
    local entry = tracked:use():entry_of(creature)
    if not entry then error("this is not a creature that is in the world right now", 2) end
    local actor = entry.object
    local record = load_kinds().types[fold(entry.kind)]
    local out = { Kind = entry.kind, Variant = entry.variant, DisplayName = record and record.DisplayName or entry.kind,
                  ClassName = entry.class_name, Name = entry.name, IsAlive = true }
    if entry.has_state then
        local state = actor.ActorState
        if state:IsValid() then
            out.Health, out.MaxHealth, out.IsAlive = state.Health, state.MaxHealth, state.CurrentAliveState == 0
            if rawget(_G, LEFT_BEHIND) ~= nil then rawset(_G, LEFT_BEHIND, nil) end
        end
    end
    if entry.has_level then out.Level = actor.CurrentLevel end
    local x, y, z = spot(actor)
    out.Position = { X = x, Y = y, Z = z }
    return out
end

-- Calls fn(creature) for each matching creature that is here now and each that appears later.
-- If fn returns a function, it runs when that creature is gone or the watch is stopped.
function Creatures:Observe(kind, fn)
    if type(kind) == "function" then kind, fn = nil, kind end
    if type(fn) ~= "function" then error("Observe expects a function, got " .. type(fn), 2) end
    local how, name = resolve(kind, 2)
    return tracked:use():observe(function(entry) return fits(entry, how, name) end, fn, "Creatures:Observe")
end

-- Outlines every creature of a kind, now and as more appear. Returns a connection. Disconnect it to stop.
function Creatures:Highlight(kind, options)
    if type(kind) == "table" and not instance.is_instance(kind) then kind, options = nil, kind end
    local highlight = Wax.import("world.highlight").api
    highlight:Check(options, 2)
    return self:Observe(kind, function(creature)
        local mark = highlight:Add(creature, options)
        return function() mark:Remove() end
    end)
end

local TAMED_CLASS = "IcarusMountCharacter"

-- The kind and variant of a creature: from the list when it is in it, else from the creature's own row.
local function identify(target, raw)
    if tracked.tracking then
        local entry = tracked:entry_of(target)
        if entry then return entry.kind, entry.variant end
    end
    local ok, kind, variant = pcall(classify, raw, true, {})
    if ok and kind then return kind, variant end
    return nil
end

-- The variant a kind is asked about by its own name: the one named like the kind, else its first.
local function main_variant(record)
    local key = fold(record.Name)
    for _, name in ipairs(record.Variants) do
        if fold(name) == key then return name end
    end
    return record.Variants[1]
end

NAMES[#NAMES + 1] = "GetInfo"
NAMES[#NAMES + 1] = "GetTamed"

-- What the game's tables say about a variant, or about the main variant of a kind: team, loot, taming rule, orders, saddles.
function Creatures:GetInfo(kind)
    local expects = "GetInfo expects a kind such as \"Wolf\", a variant such as \"Conifer_Wolf\" or a creature"
    local record, variant
    if instance.is_instance(kind) then
        if not kind:IsValid() then error("GetInfo was given a creature that no longer exists", 2) end
        local found, index = pcall(load_kinds)
        if not found then error(index, 2) end
        local its_kind, its_variant = identify(kind, kind.Raw)
        local setup = its_variant and index.setups[fold(its_variant)]
        record = setup and setup.kind or (its_kind and index.types[fold(its_kind)])
        if not record then
            error(("%s, and the game's tables have nothing on this %s"):format(expects, kind.ClassName), 2)
        end
        variant = setup and setup.Name or main_variant(record)
    else
        if kind == nil then error(expects, 2) end
        local how, name = resolve(kind, 2)
        if how == "class" then
            error(("%s, and '%s' is the name of a class"):format(expects, tostring(kind)), 2)
        end
        local index = load_kinds()
        if how == "variants" then
            local setup = index.setups[fold(name)]
            record, variant = setup.kind, setup.Name
        else
            record = index.types[fold(name)]
            variant = main_variant(record)
        end
    end
    local loaded, creature = pcall(Wax.import, "world.creature")
    if not loaded then
        error("GetInfo needs world.creature, which did not load: " .. tostring(creature):gsub("%s*[\r\n]+%s*", " "):sub(1, 200), 2)
    end
    local ok, info = pcall(creature.info, record, variant)
    if not ok then error((tostring(info):gsub("^[^\n]-%.lua:%d+: ", "", 1)), 2) end
    return info
end

-- The tamed animals among the creatures: mounts, pets and livestock. A kind and the options of GetAll narrow it down.
function Creatures:GetTamed(kind, options)
    local found = query(kind, options, 2)
    local out = {}
    for i = 1, #found do
        if found[i]:IsA(TAMED_CLASS) then out[#out + 1] = found[i] end
    end
    return out
end

local SIGNALS = { Added = true, Removed = true, Cleared = true }

setmetatable(Creatures, {
    __index = function(_, key)
        if SIGNALS[key] then return tracked:use()[key] end
        if key == "Died" then
            tracked:use()
            return Died
        end
        error(("%s is not a member of game.Creatures.%s"):format(tostring(key), suggest.phrase(tostring(key), NAMES)), 2)
    end,
    __newindex = function(_, key)
        error(("game.Creatures.%s cannot be assigned because game.Creatures is read-only"):format(tostring(key)), 2)
    end,
    __tostring = function() return "Creatures" end,
    __names = function() return NAMES end,
})

function M.start()
    rawset(Wax.import("engine.game").root, "Creatures", Creatures)
end

M.api = Creatures
M.tracked = tracked
M.identify = identify
M.fold = fold
M.kinds = load_kinds
M.TAMED = TAMED_CLASS
M.died = Died
return M
