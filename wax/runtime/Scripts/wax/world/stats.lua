-- Stats and modifiers: the numbers the game keeps for a character, and the effects that are on it

local Wax = ...
local character = Wax.import("world.character")
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local suggest = Wax.import("core.suggest")
local perf = Wax.import("core.perf")
local log = Wax.import("core.log").channel("wax.stats")

local M = {}

M.BY_CALL = true        -- GetStat and the named stats ask the game's own GetStatByRowHandle: every stat. false reads them from the list
M.HOLD = 0.2            -- seconds the stat list of a character is kept after it was read
M.STATS_TABLE = "/Engine/Transient.D_Stats"
M.MODIFIERS_TABLE = "/Engine/Transient.D_ModifierStates"
M.MODIFIER_CLASS = "/Script/Icarus.ModifierStateComponent"
M.LIBRARY = "StatsLibrary"
M.NAMED = { HealthRegen = "HealthRegenPerMinute_+", StaminaRegen = "StaminaRegenPerMinute_+" }
M.KINDS = { [0] = "Buff", "Debuff", "Biome", "Aura_Positive", "Aura_Negative", "Radiation", "Item" }       -- EModifierType
M.ENUM_GLOBAL = "Enum_Type"
M.REMEMBERED = 256      -- how many wrong names keep their message

local type, error, pcall, tostring, pairs, lower = type, error, pcall, tostring, pairs, string.lower
local frame_stats = sched.stats
local part = character.part

local game_root = nil
local names, places, spellings = nil, nil, nil  -- place -> name, folded name -> place, and the names as a list. false when the table cannot be read
local place_of = {}         -- folded name -> the stat's place in D_Stats, for names that were asked for
local in_list = {}          -- place -> whether the game puts that stat in a character's list
local name_values = {}      -- folded name -> the name as the engine takes it
local facts = {}            -- folded row -> { shown name, kind } of a modifier
local modifier_rows = nil   -- every row of D_ModifierStates, read when a wrong name needs the nearest
local wrong, wrong_count = {}, 0
local missing, said = {}, {}
local held = setmetatable({}, { __mode = "k" })     -- Instance -> what its stat list held, and when it was read
local seen = setmetatable({}, { __mode = "k" })     -- Instance -> the modifiers found on it, and in which frame
local counts = { walks = 0, seconds = 0, asked = 0, named = 0 }

local function clean(problem)
    return ((tostring(problem):match("^[^\r\n]*") or ""):gsub("^.-%.lua:%d+: ", ""))
end

local function once(key, ...)
    if said[key] then return end
    said[key] = true
    log:warn(...)
end

local function number(value)
    if type(value) == "number" then return value end
    return nil
end

-- One lookup by path. What the game does not have is not looked for again on this map: a miss is slow.
local function find(path)
    if missing[path] then return nil end
    local found = StaticFindObject(path)
    if found:IsValid() then return found end
    missing[path] = true
    return nil
end

local function row_names(path)
    local data = find(path)
    if not data then error("the game has no table at " .. path, 0) end
    return data:GetRowNames()
end

-- Every stat's name by its place in the table, counted from 0. Nil when the table cannot be read.
local function load_names()
    if names ~= nil then return names or nil end
    names, places, spellings = false, false, false
    counts.named = counts.named + 1
    local ok, rows = pcall(row_names, M.STATS_TABLE)
    if not ok then
        once("names", "the names of the game's stats could not be read: %s", clean(rows))
        return nil
    end
    local by_place, by_name, list = { n = #rows }, {}, {}
    for i = 1, #rows do
        local name = rows[i]
        if type(name) == "string" then
            by_place[i - 1], by_name[lower(name)] = name, i - 1
            list[#list + 1] = name
        end
    end
    names, places, spellings = by_place, by_name, list
    return names
end

local function root()
    game_root = game_root or Wax.import("engine.game").root
    return game_root
end

local function ask_place(name) return root():Library(M.LIBRARY).Raw:NameToInt(FName(name)) end

local function unknown(what, name, key, list)
    local text = wrong[key]
    if text then return text end
    text = ("'%s' is not a %s of the game.%s"):format(name, what, list and suggest.phrase(name, list) or "")
    if wrong_count >= M.REMEMBERED then wrong, wrong_count = {}, 0 end
    wrong[key], wrong_count = text, wrong_count + 1
    return text
end

-- A stat's place in D_Stats, which is its number in a character's list. Raises for a name the game does not have.
-- Nil when neither the game's library nor its table can say.
local function stat_place(name)
    local key = lower(name)
    local place = place_of[key]
    if place then return place end
    local text = wrong["stat " .. key]
    if text then error(text, 0) end
    if places then
        place = places[key] or false
    else
        counts.asked = counts.asked + 1
        local ok, found = pcall(ask_place, name)
        if ok and type(found) == "number" then
            place = found >= 0 and found
        else
            once("library", "the game's %s did not say where a stat is, so the table of stats is read: %s", M.LIBRARY, clean(found))
            if load_names() then place = places and places[key] or false end
        end
    end
    if place then
        place_of[key] = place
        return place
    end
    if place == false then error(unknown("stat", name, "stat " .. key, load_names() and spellings), 0) end
    return nil
end

local function read_list(raw)
    local container = part(raw, "StatContainer")
    if not container then return nil end
    local list = container.ReplicatedStatArray.StatList
    local values = {}
    for i = 1, list:GetArrayNum() do
        local pair = list[i]
        local place, value = pair.Stat, pair.Value
        if type(place) == "number" then values[place] = value end
    end
    return values
end

-- What the character's stat list holds, as place -> value. It is read again once it is older than M.HOLD.
local function listed(self, raw)
    local kept, frame = held[self], frame_stats.frame
    if kept and (kept.frame == frame or sched.clock() - kept.at < M.HOLD) then return kept.values or nil end
    local started = perf.now()
    local ok, values = pcall(read_list, raw)
    counts.walks, counts.seconds = counts.walks + 1, counts.seconds + (perf.now() - started)
    if not ok then
        once("list", "the stat list of a %s could not be read, so its stats read as nothing: %s", self.ClassName, clean(values))
        values = nil
    end
    held[self] = { frame = frame, at = sched.clock(), values = values or false }
    return values
end

local function row_flag(name)
    local data = find(M.STATS_TABLE)
    local row = data and data:FindRow(name)
    if row == nil then return nil end
    return row.bIsReplicated == true
end

-- True when the game puts the stat in a character's list, so that not finding it there means it is 0.
local function is_listed(place, name)
    local known = in_list[place]
    if known == nil then
        local ok, flag = pcall(row_flag, name)
        if ok and flag ~= nil then
            known = flag
            in_list[place] = flag
        end
    end
    return known
end

-- The game's own answer for one stat. The name is known to be one of the game's by now.
local function by_call(raw, name)
    local container = part(raw, "StatContainer")
    if not container then return nil end
    local key = lower(name)
    local value = name_values[key]
    if not value then
        value = FName(name)
        name_values[key] = value
    end
    return number(container:GetStatByRowHandle({ RowName = value }))
end

local function value_of(self, raw, name)
    local place = stat_place(name)
    if not place then return nil end
    if M.BY_CALL then return by_call(raw, name) end
    local values = listed(self, raw)
    if not values then return nil end
    local value = values[place]
    if value ~= nil then return value end
    if is_listed(place, name) then return 0 end
    return nil
end

local function get_stat(self, raw, name)
    if type(name) ~= "string" or name == "" then
        error("GetStat expects the name of a stat, such as \"MovementSpeed_+\", got " .. type(name), 0)
    end
    return value_of(self, raw, name)
end

local function named(field)
    return function(self, raw)
        local ok, value = pcall(value_of, self, raw, M.NAMED[field])
        if ok then return value end
        once(field, "%s reads as nothing: %s", field, clean(value))
        return nil
    end
end

-- The whole list by name. A stat whose name the table does not give is left out.
local function all_stats(self, raw)
    local values = listed(self, raw)
    if not values then return nil end
    local list = load_names()
    if not list then return nil end
    local out = {}
    for place, value in pairs(values) do
        local name = list[place]
        if name == nil and place >= list.n and not list.grown then
            -- a mod added rows to the table since the names were read
            local old_names, old_places, old_spellings = names, places, spellings
            names = nil
            local again = load_names()
            if again then list = again else names, places, spellings = old_names, old_places, old_spellings end
            list.grown = true
            name = list[place]
        end
        if name then out[name] = value end
    end
    return out
end

-- modifiers

local function find_row(data, row) return data:FindRow(row) end

local function read_kind(found) return M.KINDS[found.Type] end

local function read_shown(found) return found.ModifierName:ToString() end

-- What the table says of a modifier: its shown name and its kind. False for a row the table lacks, nil when it cannot be asked.
local function facts_of(row)
    local key = lower(row)
    local known = facts[key]
    if known then return known end
    local data = find(M.MODIFIERS_TABLE)
    if not data then return nil end
    local ok, found = pcall(find_row, data, row)
    if not ok then return nil end
    if found == nil then return false end
    known = { row }
    local has_kind, kind = pcall(read_kind, found)
    -- UE4SS leaves a global behind for each enum it reads
    if rawget(_G, M.ENUM_GLOBAL) ~= nil then rawset(_G, M.ENUM_GLOBAL, nil) end
    local has_shown, shown = pcall(read_shown, found)
    if has_shown and type(shown) == "string" and shown ~= "" then known[1] = shown end
    if has_kind then known[2] = kind end
    facts[key] = known
    return known
end

local function by_id(a, b) return (a[3] or 0) < (b[3] or 0) end

local function read_modifiers(raw)
    local class = find(M.MODIFIER_CLASS)
    if not class then return {} end
    local found, out = raw:K2_GetComponentsByClass(class), {}
    for i = 1, #found do
        local component = found[i]:get()
        if component:IsValid() then
            local row = component.DataRowHandleNew.RowName:ToString()
            if row ~= "" and row ~= "None" then
                out[#out + 1] = { row, lower(row), number(component.ModifierUID), number(component.ModifierLifetime),
                    number(component.RemainingTime) }
            end
        end
    end
    table.sort(out, by_id)
    return out
end

-- The modifiers on a character as { row, folded row, id, lifetime, remaining }, read once a frame.
local function modifiers(self, raw)
    local kept, frame = seen[self], frame_stats.frame
    if kept and kept.frame == frame then return kept.list end
    local ok, list = pcall(read_modifiers, raw)
    if not ok then
        once("modifiers", "the modifiers of a %s could not be read, so it reads as having none: %s", self.ClassName, clean(list))
        list = {}
    end
    seen[self] = { frame = frame, list = list }
    return list
end

local function get_modifiers(self, raw)
    local list, out = modifiers(self, raw), {}
    for i = 1, #list do
        local entry = list[i]
        local known = facts_of(entry[1])
        -- the game gives one that lasts while its cause does (exposure, an aura) a lifetime of 0
        local ends = entry[4] ~= nil and entry[4] > 0
        out[i] = { Name = entry[1], DisplayName = known and known[1] or entry[1], Kind = known and known[2] or nil,
            Id = entry[3], Duration = ends and entry[4] or nil, Remaining = ends and entry[5] or nil }
    end
    return out
end

local function has_modifier(self, raw, name)
    if type(name) ~= "string" or name == "" then
        error("HasModifier expects the name of a modifier, such as \"Berry\", got " .. type(name), 0)
    end
    local key, list = lower(name), modifiers(self, raw)
    for i = 1, #list do
        if list[i][2] == key then return true end
    end
    local text = wrong["modifier " .. key]
    if text then error(text, 0) end
    if facts_of(name) == false then
        if modifier_rows == nil then
            local ok, rows = pcall(row_names, M.MODIFIERS_TABLE)
            modifier_rows = ok and rows or false
        end
        error(unknown("modifier", name, "modifier " .. key, modifier_rows), 0)
    end
    return false
end

local fields = { Stats = all_stats, HealthRegen = named("HealthRegen"), StaminaRegen = named("StaminaRegen") }
local methods = { GetStat = get_stat, GetModifiers = get_modifiers, HasModifier = has_modifier }

-- putting a modifier on and taking it off. Both are the game's own calls, made on this machine

M.FUNCTIONS = "IcarusFunctionLibrary"
M.MODIFIERS_NAME = "D_ModifierStates"
M.STRENGTH = 100        -- the effectiveness the game's call was made with when it was tried. What other numbers do is not known

local function library() return root():Library(M.FUNCTIONS).Raw end

-- The folded row a modifier's name means. Raises for a name the game does not have, and when the table cannot say.
local function modifier_row(name, what)
    if type(name) ~= "string" or name == "" then
        error(("%s expects the name of a modifier, such as \"Health_Regen\", got %s"):format(what, type(name)), 0)
    end
    local key = lower(name)
    local text = wrong["modifier " .. key]
    if text then error(text, 0) end
    local known = facts_of(name)
    if known == false then
        if modifier_rows == nil then
            local ok, rows = pcall(row_names, M.MODIFIERS_TABLE)
            modifier_rows = ok and rows or false
        end
        error(unknown("modifier", name, "modifier " .. key, modifier_rows), 0)
    end
    if not known then
        error(("%s: the game's table of modifiers cannot be read right now, so the name '%s' cannot be checked"):format(what, name), 0)
    end
    return key
end

local function handle(row) return { RowName = FName(row), DataTableName = FName(M.MODIFIERS_NAME) } end

local function add_state(raw, row, seconds)
    return library():AddModifierState(raw, { Modifier = handle(row), ModifierLifetime = seconds, ModifierEffectiveness = M.STRENGTH },
        nil, nil, M.STRENGTH)
end

local function remove_state(raw, row, id) return library():RemoveModifierState(raw, handle(row), id) end

-- AddModifier(name, seconds) or AddModifier(name, { seconds = n }). Answers the number the game gave it, or nil when it is not on.
local function add_modifier(self, raw, name, options)
    modifier_row(name, "AddModifier")
    local seconds = options
    if type(options) == "table" then
        for option in pairs(options) do
            if option ~= "seconds" then
                error(("AddModifier has no option '%s'. It takes seconds, how long the modifier stays"):format(tostring(option)), 0)
            end
        end
        seconds = options.seconds
    end
    if type(seconds) ~= "number" or seconds ~= seconds or seconds <= 0 or seconds == math.huge then
        error("AddModifier expects how long the modifier stays, in seconds: character:AddModifier(\"Health_Regen\", { seconds = 60 })", 0)
    end
    local id = character.ask("putting a modifier on", add_state, raw, name, seconds)
    M.forget(self)
    if type(id) ~= "number" then return nil end
    local list = modifiers(self, raw)
    for i = 1, #list do
        if list[i][3] == id then return id end
    end
    return nil
end

-- RemoveModifier(name) takes every modifier of that name off, RemoveModifier(record) the one GetModifiers listed. Answers how many went.
local function remove_modifier(self, raw, what)
    local name, id = what, nil
    if type(what) == "table" then name, id = rawget(what, "Name"), rawget(what, "Id") end
    local key = modifier_row(name, "RemoveModifier")
    M.forget(self)
    local list, gone = modifiers(self, raw), 0
    for i = 1, #list do
        local entry = list[i]
        if entry[2] == key and entry[3] and (id == nil or entry[3] == id) then
            if character.ask("taking a modifier off", remove_state, raw, entry[1], entry[3]) == true then gone = gone + 1 end
        end
    end
    M.forget(self)
    return gone
end

methods.AddModifier, methods.RemoveModifier = add_modifier, remove_modifier

-- Drops what is kept of one character, or of all, so the next read asks the game. For a module that changed a stat or a modifier.
function M.forget(self)
    if self ~= nil then
        held[self], seen[self] = nil, nil
        return
    end
    held = setmetatable({}, { __mode = "k" })
    seen = setmetatable({}, { __mode = "k" })
end

-- Called on a map change: a table may be another one, and what was not there may be there now.
function M.flush()
    names, places, spellings, modifier_rows = nil, nil, nil, nil
    place_of, in_list, name_values, facts = {}, {}, {}, {}
    wrong, wrong_count, missing, said = {}, 0, {}, {}
    M.forget()
end

local connection = nil

function M.start()
    character.extend("character", { fields = fields, methods = methods }, "stats")
    if connection then return end
    local previous = scope.enter(nil)
    connection = root().MapChanged:Connect(M.flush)
    scope.leave(previous)
end

function M.stats()
    local kept = 0
    for _ in pairs(held) do kept = kept + 1 end
    return { walks = counts.walks, walk_us = counts.walks > 0 and counts.seconds / counts.walks * 1e6 or 0, asked = counts.asked,
        named = counts.named, kept = kept, by_call = M.BY_CALL == true }
end

return M
