-- A strict stand-in for the game's data tables as UE4SS hands them to Lua.
-- It raises on what crashes or changes the real game and counts what a reader asks the engine.
--   local tables = dofile("wax/tests/offline/fake_tables.lua")
--   tables.struct(path, parent, fields)   tables.table(name, struct, rows, order)   tables.install()
-- Nothing can be written until tables.allow_writes(true). Then writes follow UE4SS's rules: a value of the wrong kind
-- is stored as the game would store it (and counted) or crashes, a list grows by zeroed entries, Empty and growth kill
-- the entries handed out before, a row is only added or removed whole. `assigns` counts what Lua assigned or emptied,
-- `writes` every value that was stored for it: a struct given as a table is one assignment and a write a field.
-- A property of an enum says which enum it is (GetEnum), and that enum is found by its path and gives its labels (ForEachName).
-- Run it by itself to see each strict behaviour raise:  tools\lua\lua54\lua.exe wax\tests\offline\fake_tables.lua

local tables = { frame = 0, writable = false }

local COUNTERS = { "touches", "finds", "misses", "lists", "stale", "grown", "crashes", "misuse", "unknown_names",
                   "rows_asked", "enum_reads", "enum_finds", "never_reads", "map_reads", "map_entries", "curve_keys", "curve_values",
                   "writes", "assigns", "appends", "empties", "leaks", "sloppy", "silent", "rows_added", "rows_removed", "refreshes" }

-- Every counter back to zero. The tables and structs stay.
function tables.reset()
    for _, name in ipairs(COUNTERS) do tables[name] = 0 end
    tables.asked = {}       -- table name -> row name as it was asked -> how often
end
tables.reset()

local structs, by_path, by_name, by_library, listed = {}, {}, {}, {}, {}
local field_names = {}      -- every field name a struct declares, folded: a name the game knows
local enum_fields = {}      -- enum path -> the field that declared it. An enum field named Mode is the enum /Script/Icarus.EMode
local short = nil
local next_address = 0x7FF600000000

local wrappers = setmetatable({}, { __mode = "k" })     -- struct wrapper -> { path, data }
local arrays = setmetatable({}, { __mode = "k" })       -- list wrapper -> { field, data }
local fnames = setmetatable({}, { __mode = "k" })       -- name object -> its text
local fstrings = setmetatable({}, { __mode = "k" })     -- string or text object -> its text
local moved = setmetatable({}, { __mode = "k" })        -- the data of a list or row -> how often what it held was freed
local mapped = setmetatable({}, { __mode = "k" })       -- struct wrapper -> true when a property handed it out, not FindRow

local NUMBERS = { Int8Property = true, Int16Property = true, IntProperty = true, Int64Property = true, UInt16Property = true,
                  UInt32Property = true, UInt64Property = true, ByteProperty = true, FloatProperty = true }
local WIDTHS = { Int8Property = { 8, true }, Int16Property = { 16, true }, IntProperty = { 32, true }, Int64Property = { 64, true },
                 ByteProperty = { 8, false }, UInt16Property = { 16, false }, UInt32Property = { 32, false }, UInt64Property = { 64, false } }
local TEXTS = { NameProperty = "None", StrProperty = "", TextProperty = "" }
local SOFTS = { SoftObjectProperty = "TSoftObjectPtrUserdata", SoftClassProperty = "TSoftClassPtrUserdata" }

-- What would crash the game, or change the player's data.
local function crash(what)
    tables.crashes = tables.crashes + 1
    error("CRASH: " .. what, 3)
end

-- What the real objects may allow but a reader has no business doing.
local function misuse(what)
    tables.misuse = tables.misuse + 1
    error("MISUSE: " .. what, 3)
end

-- A check for one wrapper: using it in a later frame raises. `live`, when given, raises once what it points into is gone.
local function stamp(what, live)
    local born = tables.frame
    return function(key)
        if born ~= tables.frame then
            tables.stale = tables.stale + 1
            error(("STALE: %s was used after its frame (%s)"):format(what, tostring(key)), 3)
        end
        if live then live(what, key) end
        tables.touches = tables.touches + 1
    end
end

-- Using what points into freed memory: in the game that reads or writes whatever is there now.
local function freed(what, key, why)
    tables.crashes = tables.crashes + 1
    error(("CRASH: %s was used after %s (%s)"):format(what, why, tostring(key)), 5)
end

local function count_touch() tables.touches = tables.touches + 1 end

-- An object with these members and no others.
local function strict(what, members, check)
    check = check or count_touch
    return setmetatable({}, {
        __index = function(_, key)
            check(key)
            local member = members[key]
            if member == nil then misuse(("%s was asked for %s"):format(what, tostring(key))) end
            return member
        end,
        __newindex = function(_, key) crash(("%s.%s was written"):format(what, tostring(key))) end,
    })
end

local function text(value)
    return strict("a name or text", { ToString = function() return value end })
end

-- A name as a row hands it out and as FName() makes it: the only thing a name slot takes.
local function name_object(value)
    local object = strict("a name", { ToString = function() return value end, type = function() return "FName" end })
    fnames[object] = value
    return object
end

local function string_object(value, kind)
    local object = strict("a string or text", { ToString = function() return value end, type = function() return kind or "FString" end })
    fstrings[object] = value
    return object
end

local function soft(path, kind)
    return strict("a soft reference", {
        type = function() return kind end,
        GetObjectID = function()
            return strict("a soft object path", { GetAssetPathName = function() return text(path) end })
        end,
    })
end

local function shape_of(path)
    local shape = structs[path]
    if not shape then error("fake_tables: no struct was declared at " .. tostring(path), 0) end
    return shape
end

-- Own fields and inherited ones, by name and by folded name. The struct's own definition wins.
local function fields_of(shape)
    if shape.all then return shape.all, shape.folded end
    local all, folded, at = {}, {}, shape
    while at do
        for _, field in ipairs(at.fields) do
            if not all[field.name] then
                all[field.name] = field
                folded[field.name:lower()] = field
            end
        end
        at = at.super and shape_of(at.super) or nil
    end
    shape.all, shape.folded = all, folded
    return all, folded
end

-- A made-up layout: eight bytes a field, after the parent and after any part in front that nothing reflects.
local function size_of(shape)
    local base = shape.super and size_of(shape_of(shape.super)) or 0
    return base + (shape.lead or 0) + 8 * #shape.fields
end

local function offset_of(shape, index)
    local base = shape.super and size_of(shape_of(shape.super)) or 0
    return base + (shape.lead or 0) + 8 * (index - 1)
end

-- Why Lua cannot make a value of this struct from zeroed memory, or false when it can.
local function engine_made(path, seen)
    seen = seen or {}
    if seen[path] then return false end
    seen[path] = true
    local shape = structs[path]
    if not shape then return "is a struct nobody declared" end
    while shape do
        if (shape.lead or 0) > 0 then return "has a part in front that only the game fills in" end
        for _, field in ipairs(shape.fields) do
            if field.kind == "TextProperty" or field.kind == "MapProperty" or field.kind == "SetProperty" then
                return "holds a " .. field.kind .. ", and a zeroed one is not valid"
            end
            if field.kind == "StructProperty" then
                local why = engine_made(field.struct, seen)
                if why then return why end
            end
        end
        shape = shape.super and structs[shape.super] or nil
    end
    return false
end

-- True when a value owns memory that Empty() would leave behind.
local function holds(field, value)
    if value == nil then return false end
    if field.kind == "StrProperty" or field.kind == "TextProperty" then return value ~= "" end
    if field.kind == "ArrayProperty" then return #value > 0 end
    if field.kind == "StructProperty" and structs[field.struct] then
        for name, inner in pairs((fields_of(structs[field.struct]))) do
            if holds(inner, value[name]) then return true end
        end
    end
    return false
end

local function deep(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = deep(item) end
    return out
end

-- Everything that pointed into this data is dead from now on.
local function kill(data)
    moved[data] = (moved[data] or 0) + 1
    for _, item in pairs(data) do
        if type(item) == "table" then kill(item) end
    end
end

local function wrap(kind, whole)
    local bits, signed = WIDTHS[kind][1], WIDTHS[kind][2]
    if bits == 64 then return whole end
    whole = whole & ((1 << bits) - 1)
    if signed and whole >= (1 << (bits - 1)) then whole = whole - (1 << bits) end
    return whole
end

local function zero_of(element)
    local kind = element.kind
    if kind == "BoolProperty" then return false end
    if NUMBERS[kind] or kind == "EnumProperty" then return 0 end
    if TEXTS[kind] then return TEXTS[kind] end
    return {}
end

-- The names UE4SS leaves in a global each time an enum is read.
local function enum_names(field)
    local out, labels = {}, field.enum
    if labels then
        local prefix = "E" .. field.name .. "::"
        for index, label in ipairs(labels) do out[prefix .. label] = index - 1 end
        out[prefix .. "E" .. field.name .. "_MAX"] = #labels
    end
    return out
end

local struct_value, array_value, store, value_of

-- A curve's value at a time: straight lines between its keys, held at its ends.
local function curve_at(keys, at)
    if #keys == 0 then return 0.0 end
    if at <= keys[1][1] then return keys[1][2] + 0.0 end
    for index = 2, #keys do
        local from, to = keys[index - 1], keys[index]
        if at <= to[1] then return from[2] + (to[2] - from[2]) * (at - from[1]) / (to[1] - from[1]) end
    end
    return keys[#keys][2] + 0.0
end

-- What an object field of a declared class hands out. A row gives { class =, path =, keys = { { time, value } } } or nothing.
-- Only a CurveFloat can be asked for more than what it is.
local function object_value(field, value, what)
    if value == nil then return tables.INVALID end
    local class = value.class or field.class
    local full = class .. " " .. (value.path or ("/Game/Data/Curves/" .. tostring(value.name) .. "." .. tostring(value.name)))
    local check = stamp(what)
    local members = {
        IsValid = function() return true end,
        type = function() return "UObject" end,
        GetFullName = function() return full end,
    }
    if class == "CurveFloat" then
        local keys = value.keys or {}
        local list = setmetatable({}, {
            __index = function(_, index)
                check(index)
                if index == "GetArrayNum" then return function() return #keys end end
                if math.type(index) ~= "integer" then misuse(("%s.FloatCurve.Keys was asked for %s"):format(what, tostring(index))) end
                if index < 1 or index > #keys then
                    crash(("%s.FloatCurve.Keys[%d] was read and it has %d: reading past the end makes the game's list longer")
                        :format(what, index, #keys))
                end
                tables.curve_keys = tables.curve_keys + 1
                return strict("a key of " .. what, { Time = keys[index][1] + 0.0, Value = keys[index][2] + 0.0 }, check)
            end,
            __newindex = function(_, index) crash(("%s.FloatCurve.Keys[%s] was written"):format(what, tostring(index))) end,
        })
        members.FloatCurve = strict("the FloatCurve of " .. what, { Keys = list }, check)
        members.GetFloatValue = function(_, at)
            if type(at) ~= "number" then crash("GetFloatValue was given a " .. type(at)) end
            tables.curve_values = tables.curve_values + 1
            return curve_at(keys, at)
        end
    end
    return strict(what, members, check)
end

-- A map field declared with what its keys and values are. A row gives its entries as a list of { key, value }.
-- ForEach hands out each key and value behind get(), as UE4SS does, and they are dead once the callback returns.
local function map_value(field, data, what, live)
    local check = stamp(what, live)
    local function element(of, name)
        return { name = name, kind = of[1], struct = of.struct, enum = of.enum, class = of.class }
    end
    local key_of, item_of = element(field.key, field.name .. "_Key"), element(field.value, field.name)
    return setmetatable({}, {
        __index = function(_, member)
            check(member)
            if member == "type" then return function() return "TMap" end end
            if member ~= "ForEach" then misuse(("%s was asked for %s"):format(what, tostring(member))) end
            return function(_, fn)
                if type(fn) ~= "function" then crash(what .. ":ForEach was given a " .. type(fn)) end
                tables.map_reads = tables.map_reads + 1
                for index, pair in ipairs(data) do
                    local open = true
                    local function param(of, slot, label)
                        local here = ("%s[%d].%s"):format(what, index, label)
                        local function get()
                            if not open then
                                tables.stale = tables.stale + 1
                                error(("STALE: %s was used after its callback returned"):format(here), 2)
                            end
                            return value_of(of, pair[slot], here, pair, slot, live)
                        end
                        return strict(here, { get = get, Get = get, type = function() return "RemoteUnrealParam" end,
                            set = function() crash(here .. " was written") end, Set = function() crash(here .. " was written") end }, check)
                    end
                    tables.map_entries = tables.map_entries + 1
                    local ok, result = pcall(fn, param(key_of, 1, "key"), param(item_of, 2, "value"))
                    open = false
                    if not ok then
                        tables.crashes = tables.crashes + 1
                        error(("CRASH: an error left the callback of %s:ForEach, where it passes through UE4SS's own code (%s)")
                            :format(what, tostring(result)), 2)
                    end
                    if result == true then break end
                end
            end
        end,
        __len = function()
            check("#")
            return #data
        end,
        __newindex = function(_, member) crash(("%s.%s was written"):format(what, tostring(member))) end,
    })
end

-- A struct given as a Lua table: only the keys spelled exactly as a field are written, the rest is skipped without a word.
local function fill_from_table(path, into, given, what)
    local all = fields_of(shape_of(path))
    local taken = 0
    for name, field in pairs(all) do
        local value = rawget(given, name)
        if value ~= nil then
            taken = taken + 1
            if field.kind == "ArrayProperty" and type(value) == "table" and not arrays[value] then
                -- UE4SS takes the length from the wrong place here: the list comes out empty
                tables.sloppy = tables.sloppy + 1
                if into[name] then kill(into[name]) end
                into[name] = {}
            else
                store(field, into, name, value, what .. "." .. name)
            end
        end
    end
    local keys = 0
    for _ in pairs(given) do keys = keys + 1 end
    tables.silent = tables.silent + (keys - taken)
end

-- One write as UE4SS makes it. A value of the wrong kind is stored as the game would store it and counted, or crashes.
function store(field, holder, key, value, what)
    local kind = field.kind
    tables.writes = tables.writes + 1
    if kind == "BoolProperty" then
        if type(value) ~= "boolean" then tables.sloppy = tables.sloppy + 1 end
        holder[key] = value ~= nil and value ~= false
    elseif WIDTHS[kind] then
        local whole = type(value) == "number" and math.tointeger(value)
        if not whole then
            tables.sloppy = tables.sloppy + 1
            whole = 0
        end
        holder[key] = wrap(kind, whole)
    elseif kind == "FloatProperty" then
        if type(value) ~= "number" then
            tables.sloppy = tables.sloppy + 1
            value = 0
        end
        holder[key] = string.unpack("f", string.pack("f", value))
    elseif kind == "EnumProperty" then
        local whole = type(value) == "number" and math.tointeger(value)
        if not whole then
            tables.sloppy = tables.sloppy + 1
            whole = 0
        end
        holder[key] = whole & 0xFF
    elseif kind == "NameProperty" then
        local name = fnames[value]
        if name == nil then crash(("%s is a name and was given a %s: only an FName may be written there"):format(what, type(value))) end
        holder[key] = name
    elseif kind == "StrProperty" then
        if type(value) == "string" then
            holder[key] = value
        elseif fstrings[value] then
            holder[key] = fstrings[value]
        else
            error("StrProperty can only be set to a string or FString", 3)
        end
    elseif kind == "TextProperty" then
        crash(("%s is a text and was given a %s: only an FText may be written there"):format(what, type(value)))
    elseif SOFTS[kind] then
        crash(("%s is a soft reference and was written: nothing Lua can make may be written there"):format(what))
    elseif kind == "StructProperty" then
        local source = wrappers[value]
        local into = holder[key]
        if type(into) ~= "table" then
            into = {}
            holder[key] = into
        end
        if source then
            if source.path ~= field.struct then error(("Can't copy struct of type %s into %s"):format(source.path, field.struct), 3) end
            local copy = deep(source.data)
            for name, item in pairs(into) do
                if type(item) == "table" then kill(item) end
                into[name] = nil
            end
            for name, item in pairs(copy) do into[name] = item end
        elseif type(value) == "table" then
            fill_from_table(field.struct, into, value, what)
        elseif value ~= nil then
            error("Parameter must be of type 'StructProperty' or table", 3)
        end
    elseif kind == "ArrayProperty" then
        local source = arrays[value]
        local into = holder[key]
        if type(into) ~= "table" then
            into = {}
            holder[key] = into
        end
        if source or value == nil then
            local copy = source and deep(source.data) or {}
            kill(into)
            for index = #into, 1, -1 do into[index] = nil end
            for index = 1, #copy do into[index] = copy[index] end
        else
            misuse(("%s was given a Lua table: UE4SS starts a new list over the old one without freeing it"):format(what))
        end
    else
        crash(("%s is a %s and was written"):format(what, kind))
    end
end

function value_of(field, value, what, holder, key, live, tap)
    local kind = field.kind
    if kind == "BoolProperty" then return value == true end
    if NUMBERS[kind] then return value or 0 end
    if kind == "EnumProperty" then
        tables.enum_reads = tables.enum_reads + 1
        rawset(_G, "Enum_" .. field.name, enum_names(field))
        return value or 0
    end
    if kind == "NameProperty" then return name_object(value or "None") end
    if TEXTS[kind] then return string_object(value or TEXTS[kind], kind == "TextProperty" and "FText" or "FString") end
    if SOFTS[kind] then return soft(value or "None", SOFTS[kind]) end
    if kind == "StructProperty" or kind == "ArrayProperty" then
        if value == nil then
            value = {}
            holder[key] = value
        end
        if kind == "StructProperty" then
            local made = struct_value(field.struct, value, what, nil, live, tap)
            mapped[made] = true
            return made
        end
        return array_value(field, value, what, live, tap)
    end
    -- a map and an object are only handed out when the struct says what they hold
    if kind == "MapProperty" and field.key then
        if value == nil then
            value = {}
            holder[key] = value
        end
        return map_value(field, value, what, live)
    end
    if kind == "ObjectProperty" and field.class then return object_value(field, value, what) end
    tables.never_reads = tables.never_reads + 1
    error(("NEVER: %s is a %s, which a reader must not read"):format(what, kind), 3)
end

-- `tap`, when given, sees every write below: it returns true to drop the write without a word, or raises.
-- `taps` gives one for each of a row's fields by name.
function struct_value(path, data, what, poison, live, tap, taps)
    local all, folded = fields_of(shape_of(path))
    local check = stamp(what, live)
    local proxy = setmetatable({}, {
        __index = function(self, key)
            check(key)
            if type(key) ~= "string" then crash(("%s was indexed with a %s"):format(what, type(key))) end
            local field = all[key]
            -- what a struct value says of itself, as UE4SS has it
            if not field and key == "type" then return function() return "UScriptStruct" end end
            if not field and key == "IsMappedToProperty" then return function() return mapped[self] == true end end
            if not field and key == "GetProperty" then
                return function()
                    if not mapped[self] then crash(what .. ":GetProperty() was called on a struct that no property handed out") end
                    return strict("a property from GetProperty()", { GetStruct = function()
                        return strict("a struct from GetStruct()", { GetFullName = function() return "ScriptStruct " .. path end })
                    end })
                end
            end
            if not field then misuse(("%s has no field named %s"):format(path, key)) end
            if poison == key then error(("the engine could not read %s.%s"):format(what, key), 2) end
            return value_of(field, data[key], what .. "." .. key, data, key, live, tap or (taps and taps[key]))
        end,
        __newindex = function(_, key, value)
            if not tables.writable then crash(("%s.%s was written: that changes the player's game"):format(what, tostring(key))) end
            check(key)
            if type(key) ~= "string" then crash(("%s was written with a %s for a field name"):format(what, type(key))) end
            local field = all[key] or folded[key:lower()]
            if not field then
                -- as in the game: a name it knows from elsewhere is an error, any other name is taken without a word
                if field_names[key:lower()] then error(("Was unable to retrieve property '%s' mapped to '%s'"):format(key, path), 2) end
                tables.silent = tables.silent + 1
                return
            end
            local hook = tap or (taps and taps[field.name])
            if hook and hook(what .. "." .. field.name) then return end
            tables.assigns = tables.assigns + 1
            store(field, data, field.name, value, what .. "." .. field.name)
        end,
    })
    wrappers[proxy] = { path = path, data = data }
    return proxy
end

function array_value(field, data, what, live, tap)
    local check = stamp(what, live)
    local element = { name = field.name, kind = field.inner, struct = field.struct, enum = field.enum }
    local grown = 0
    -- Adds zeroed entries up to `to`, as UE4SS does for any index at or past the end.
    local function grow(to)
        local count = #data
        if count == 0 and to > 1 then
            crash(("%s[%d] was asked of an empty list: UE4SS adds one entry and then touches memory past it"):format(what, to))
        end
        if element.kind == "StructProperty" then
            local why = engine_made(element.struct)
            if why then crash(("%s was made longer, and its new entry is zeroed memory: %s %s"):format(what, element.struct, why)) end
        elseif element.kind == "TextProperty" then
            crash(("%s was made longer, and a zeroed text is not valid"):format(what))
        end
        for index = count + 1, to do data[index] = zero_of(element) end
        moved[data] = (moved[data] or 0) + 1
    end
    local proxy = setmetatable({}, {
        __index = function(_, key)
            check(key)
            if key == "GetArrayNum" or key == "GetArrayMax" then
                return function()
                    check(key)
                    return #data
                end
            end
            if key == "type" then return function() return "TArray" end end
            if key == "Empty" then
                return function()
                    check(key)
                    if not tables.writable then crash(("%s:Empty() was called: that changes the player's game"):format(what)) end
                    if tap and tap(what) then return end
                    if element.kind == "StructProperty" and engine_made(element.struct) then
                        misuse(("%s:Empty() was called: a list whose entries only the game can make keeps its length"):format(what))
                    end
                    for index = 1, #data do
                        if holds(element, data[index]) then
                            -- no destructor runs, so what the entries own is left behind
                            tables.leaks = tables.leaks + 1
                            break
                        end
                    end
                    kill(data)
                    for index = #data, 1, -1 do data[index] = nil end
                    tables.empties = tables.empties + 1
                    tables.assigns = tables.assigns + 1
                    tables.writes = tables.writes + 1
                end
            end
            if math.type(key) ~= "integer" then misuse(("%s was asked for %s"):format(what, tostring(key))) end
            local count = #data
            if key == count + 1 then
                -- as in the game: reading one past the end makes the array one longer
                tables.grown = tables.grown + 1
                grown = grown + 1
                if grown > 3 then error(what .. " grows each time its end is read, so a loop that waits for nil never ends", 2) end
                grow(key)
            elseif key < 1 or key > count then
                misuse(("%s[%d] is out of range (it has %d)"):format(what, key, count))
            end
            local made = moved[data] or 0
            local function alive(entry, entry_key)
                if live then live(entry, entry_key) end
                if (moved[data] or 0) ~= made then freed(entry, entry_key, "its list was emptied or made longer") end
            end
            return value_of(element, data[key], what .. "[" .. key .. "]", data, key, alive, tap)
        end,
        __len = function()
            check("#")
            return #data
        end,
        __newindex = function(_, key, value)
            if not tables.writable then crash(("%s[%s] was written: that changes the player's game"):format(what, tostring(key))) end
            check(key)
            if math.type(key) ~= "integer" or key < 1 then error("TArray index out of range.", 2) end
            local here = what .. "[" .. key .. "]"
            if tap and tap(here) then return end
            local count = #data
            if key > count then
                grow(key)
                tables.appends = tables.appends + (key - count)
            end
            tables.assigns = tables.assigns + 1
            store(element, data, key, value, here)
        end,
    })
    arrays[proxy] = { field = field, data = data }
    return proxy
end

-- A property as ForEachProperty hands it out. What GetStruct() and GetInner() return says its name and nothing else.
local function property(field, is_open, offset)
    local function check(key)
        if not is_open() then
            tables.stale = tables.stale + 1
            error(("STALE: the property %s was used after ForEachProperty returned (%s)"):format(field.name, tostring(key)), 3)
        end
        tables.touches = tables.touches + 1
    end
    local function class_of(kind)
        return strict("a property's class", { GetFName = function() return text(kind) end }, check)
    end
    local function struct_of(path)
        return strict("a struct from GetStruct()", { GetFullName = function() return "ScriptStruct " .. path end }, check)
    end
    -- what GetEnum() returns says the enum's name and nothing else
    local function enum_of()
        return strict("an enum from GetEnum()", { GetFullName = function() return "Enum /Script/Icarus.E" .. field.name end }, check)
    end
    return strict("the property " .. field.name, {
        GetFName = function() return text(field.name) end,
        GetClass = function() return class_of(field.kind) end,
        GetOffset_Internal = function() return offset end,
        GetStruct = function()
            if field.kind ~= "StructProperty" then crash("GetStruct() on a " .. field.kind) end
            return struct_of(field.struct)
        end,
        GetEnum = function()
            if field.kind ~= "EnumProperty" then crash("GetEnum() on a " .. field.kind) end
            return enum_of()
        end,
        GetInner = function()
            if field.kind ~= "ArrayProperty" then crash("GetInner() on a " .. field.kind) end
            return strict("a property from GetInner()", {
                GetClass = function() return class_of(field.inner) end,
                GetStruct = function()
                    if field.inner ~= "StructProperty" then crash("GetStruct() on an array of " .. field.inner) end
                    return struct_of(field.struct)
                end,
                GetEnum = function()
                    if field.inner ~= "EnumProperty" then crash("GetEnum() on an array of " .. field.inner) end
                    return enum_of()
                end,
            }, check)
        end,
    }, check)
end

-- An enum as StaticFindObject hands it out: its labels with the enum's name in front, and the _MAX label last.
local function enum_object(field)
    local what = "the enum E" .. field.name
    local check = stamp(what)
    return strict(what, {
        IsValid = function() return true end,
        type = function() return "UEnum" end,
        GetFullName = function() return "Enum /Script/Icarus.E" .. field.name end,
        ForEachName = function(_, fn)
            for label, number in pairs(enum_names(field)) do fn(name_object(label), number) end
        end,
    }, check)
end

local NO_STRUCT = strict("a struct that does not exist", { IsValid = function() return false end })

local function struct_object(shape)
    local what = "the struct " .. shape.path
    local check = stamp(what)
    return strict(what, {
        IsValid = function() return true end,
        type = function() return "UScriptStruct" end,
        GetFullName = function() return "ScriptStruct " .. shape.path end,
        -- own fields only, as the engine does it
        ForEachProperty = function(_, fn)
            local open = true
            local function is_open() return open end
            local ok, problem = pcall(function()
                for index, field in ipairs(shape.fields) do
                    if fn(property(field, is_open, offset_of(shape, index))) ~= nil then
                        tables.misuse = tables.misuse + 1
                        error("MISUSE: a ForEachProperty callback returned a value, which may end the walk early", 0)
                    end
                end
            end)
            open = false
            if not ok then error(problem, 0) end
        end,
        GetSuperStruct = function()
            if not shape.super then return NO_STRUCT end
            return strict("a struct from GetSuperStruct()", {
                IsValid = function() return true end,
                GetFullName = function() return "ScriptStruct " .. shape.super end,
            }, check)
        end,
    }, check)
end

local INVALID = setmetatable({}, { __index = function(_, key)
    tables.touches = tables.touches + 1
    if key == "IsValid" then return function() return false end end
    -- what kind of wrapper it is can be asked of any wrapper
    if key == "type" then return function() return "UObject" end end
    crash(("%s was used on an object that is not valid"):format(tostring(key)))
end })
tables.INVALID = INVALID

local handle

local function find_row(state, name)
    if type(name) ~= "string" then crash("FindRow was given a " .. type(name)) end
    tables.rows_asked = tables.rows_asked + 1
    local asked = tables.asked[state.name]
    if not asked then
        asked = {}
        tables.asked[state.name] = asked
    end
    asked[name] = (asked[name] or 0) + 1
    local key = name:lower()
    local row = state.rows[key]
    if row == nil then
        -- in the game this name now sits in the engine's name table until the game closes
        tables.unknown_names = tables.unknown_names + 1
        return nil
    end
    -- the row is a pointer: once the row is removed or replaced it points at freed memory
    local function live(used, used_key)
        if state.rows[key] ~= row then freed(used, used_key, "its row was removed or replaced") end
    end
    return struct_value(state.struct, row, state.name .. "." .. name, state.poison[key], live, nil, state.taps[key])
end

-- AddRow as UE4SS does it: a copy of another row or a row made from a Lua table, put straight into the row map.
local function add_row(state, what, name, source)
    if not tables.writable then crash(("%s:AddRow was called: that changes the player's game"):format(what)) end
    if type(name) ~= "string" then error("AddRow expects a string as the first parameter", 3) end
    local data
    local from = wrappers[source]
    if from then
        if from.path ~= state.struct then crash(("%s:AddRow was given a %s: its memory is copied as a row all the same"):format(what, from.path)) end
        data = deep(from.data)
    elseif type(source) == "table" and getmetatable(source) == nil then
        data = {}
        fill_from_table(state.struct, data, source, state.name .. "." .. name)
    else
        error("AddRow expects a table or UScriptStruct as the second parameter", 3)
    end
    local key = name:lower()
    local old = state.rows[key]
    if old then
        -- the row under that name is freed first
        if state.vanilla[key] then crash(("%s:AddRow replaced %s, a row of the game"):format(what, name)) end
        kill(old)
    else
        state.order[#state.order + 1] = name
    end
    state.rows[key] = data
    tables.rows_added = tables.rows_added + 1
    tables.writes = tables.writes + 1
end

local function remove_row(state, what, name)
    if not tables.writable then crash(("%s:RemoveRow was called: that changes the player's game"):format(what)) end
    if type(name) ~= "string" then crash("RemoveRow was given a " .. type(name)) end
    local key = name:lower()
    local old = state.rows[key]
    if not old then
        tables.unknown_names = tables.unknown_names + 1
        return
    end
    if state.vanilla[key] then crash(("%s:RemoveRow took out %s, a row of the game"):format(what, name)) end
    kill(old)
    state.rows[key] = nil
    for index = #state.order, 1, -1 do
        if state.order[index]:lower() == key then table.remove(state.order, index) end
    end
    tables.rows_removed = tables.rows_removed + 1
    tables.writes = tables.writes + 1
end

function handle(state)
    local what = "the table " .. state.name
    local check = stamp(what)
    local methods = {
        IsValid = function() return true end,
        type = function() return "UDataTable" end,
        GetAddress = function() return state.address end,
        GetFName = function() return text(state.path:match("([^%.]+)$")) end,
        GetFullName = function() return state.class .. " " .. state.path end,
        GetRowNames = function()
            local out = {}
            for i, name in ipairs(state.order) do out[i] = name end
            return out
        end,
        GetRowStruct = function()
            return strict("a struct from GetRowStruct()", {
                IsValid = function() return true end,
                GetFullName = function() return "ScriptStruct " .. state.struct end,
            }, check)
        end,
        FindRow = function(_, name) return find_row(state, name) end,
        AddRow = function(_, name, source) return add_row(state, what, name, source) end,
        RemoveRow = function(_, name) return remove_row(state, what, name) end,
        EmptyTable = function() crash(what .. ":EmptyTable was called") end,
    }
    return setmetatable({}, {
        __index = function(_, key)
            check(key)
            if key == "MetaTable" then return state.meta and handle(state.meta) or INVALID end
            local method = methods[key]
            if not method then misuse(("%s was asked for %s"):format(what, tostring(key))) end
            return method
        end,
        __len = function()
            check("#")
            return #state.order
        end,
        __newindex = function(_, key) crash(("%s.%s was written"):format(what, tostring(key))) end,
    })
end

-- Declares a struct. `fields` is a list of { name, property class, struct = path, inner = property class, enum = { names } }.
-- A MapProperty that says what it holds can be read: key = { property class, struct = path, enum = { names } } and value = the same.
-- So can an ObjectProperty that says its class: class = "CurveFloat". Without those both raise when read, as before.
-- `options.lead` is how many bytes in front of its first field nothing reflects: 8 for a struct with a vtable pointer.
function tables.struct(path, super, fields, options)
    local shape = { path = path, super = super, fields = {}, lead = options and options.lead or nil }
    for i, field in ipairs(fields or {}) do
        shape.fields[i] = { name = field[1], kind = field[2], struct = field.struct, inner = field.inner, enum = field.enum,
                            key = field.key, value = field.value, class = field.class }
        field_names[field[1]:lower()] = true
        if field[2] == "EnumProperty" or field.inner == "EnumProperty" then enum_fields["/Script/Icarus.E" .. field[1]] = shape.fields[i] end
    end
    structs[path] = shape
    return shape
end

-- The rows a table is declared with are the game's own: replacing or removing one is a crash.
local function take_rows(state, rows, order)
    state.rows, state.order, state.vanilla, state.indexed, state.taps = {}, {}, {}, {}, {}
    for key, row in pairs(rows) do
        state.rows[key:lower()] = row
        state.vanilla[key:lower()] = true
    end
    for i, row_name in ipairs(order) do
        if not state.rows[row_name:lower()] then
            error(("fake_tables: %s lists %s but has no such row"):format(state.name, row_name), 4)
        end
        state.order[i] = row_name
        state.indexed[row_name:lower()] = true
    end
    state.index_count = #state.order
end

local function new_table(name, struct, rows, order, class, path)
    next_address = next_address + 0x1000
    local state = { name = name, struct = struct, address = next_address, hidden = false, class = class, path = path, poison = {} }
    take_rows(state, rows, order)
    by_path[path] = state
    return state
end

-- The game's own index of a table's rows. It only learns of a new row when it is told to look again.
local function library(state)
    local what = "the library of " .. state.name
    return strict(what, {
        IsValid = function() return true end,
        RefreshConstants = function()
            if not tables.writable then misuse(what .. ":RefreshConstants was called") end
            state.indexed = {}
            for _, row_name in ipairs(state.order) do state.indexed[row_name:lower()] = true end
            state.index_count = #state.order
            tables.refreshes = tables.refreshes + 1
        end,
        IsValidName = function(_, name)
            if fnames[name] == nil then crash("IsValidName was given a " .. type(name) .. " where an FName belongs") end
            return state.indexed[fnames[name]:lower()] == true
        end,
        NumRows = function() return state.index_count end,
    }, stamp(what))
end

-- Declares a table the game lists. `rows` maps a row name to plain data and `order` gives each name as the engine spells it.
function tables.table(name, struct, rows, order)
    local state = new_table(name, struct, rows, order, name .. "Table", "/Engine/Transient.D_" .. name)
    by_name[name] = state
    by_library["/Script/Icarus.Default__" .. name .. "Library"] = state
    listed[#listed + 1] = state
    return state
end

-- Declares the meta table of a table. The game does not list these: they are reached through MetaTable.
function tables.meta(name, struct, rows, order)
    local owner = by_name[name] or error("fake_tables: no table named " .. tostring(name), 2)
    owner.meta = new_table(name .. "_METATABLE", struct, rows, order, "IcarusMetaTable", "/Engine/Transient.D_" .. name .. "_METATABLE")
    return owner.meta
end

-- Adds `count` small tables, so the list is as long as the game's.
function tables.fill(count)
    tables.struct("/Script/Icarus.FillerRow", nil, { { "Value", "IntProperty" } })
    for i = 1, count do
        tables.table(("Filler%03d"):format(i), "/Script/Icarus.FillerRow", { Only = { Value = i } }, { "Only" })
    end
end

local function state_of(name)
    local owner, meta = tostring(name):match("^(.-)(_METATABLE)$")
    local state = meta and by_name[owner] and by_name[owner].meta or by_name[name]
    return state or error("fake_tables: no table named " .. tostring(name), 3)
end

-- The table is another object from now on, as after the game made it again.
function tables.move(name)
    next_address = next_address + 0x1000
    state_of(name).address = next_address
end

-- The table cannot be found (true) or can again (false).
function tables.hide(name, hidden) state_of(name).hidden = hidden ~= false end

function tables.set_rows(name, rows, order)
    local state = state_of(name)
    for _, row in pairs(state.rows) do kill(row) end
    take_rows(state, rows, order)
end

-- Reading `field` of this row raises, as when UE4SS cannot read a value.
function tables.poison(name, row, field) state_of(name).poison[row:lower()] = field end

-- Writes follow UE4SS's rules (true) or crash, as for a reader (false).
function tables.allow_writes(on) tables.writable = on ~= false end

local function tap_for(name, row, field, tap)
    local state = state_of(name)
    local taps = state.taps[row:lower()]
    if not taps then
        taps = {}
        state.taps[row:lower()] = taps
    end
    taps[field] = tap
end

-- Writes to this field of this row, and to anything inside it, are dropped without a word (true) or taken again (false).
function tables.deaf(name, row, field, on)
    tap_for(name, row, field, on ~= false and function() return true end or nil)
end

-- The write number `after + 1` to this field of this row, or to anything inside it, raises as an engine error does:
-- that one only, or every write from there on when `stays` is true. nil for `after` ends it.
function tables.break_write(name, row, field, after, stays)
    local count = 0
    tap_for(name, row, field, after and function(what)
        count = count + 1
        if count == after + 1 or (stays and count > after) then error("the engine refused to write " .. what, 0) end
        return false
    end or nil)
end

-- What the game holds of one row, as plain data, or nil. For looking at the result of a write without a wrapper.
function tables.row(name, row) return state_of(name).rows[row:lower()] end

-- What the game's own index of a table knows: how many rows, and whether one is among them.
function tables.indexed(name, row)
    local state = state_of(name)
    return state.index_count, row and state.indexed[row:lower()] == true or false
end

-- FindAllOf gives only the first `count` tables, as while the game is still loading. nil gives all again.
function tables.short_list(count) short = count end

-- A new frame: everything handed out so far must not be used again.
function tables.next_frame() tables.frame = tables.frame + 1 end

function tables.listed() return #listed end

-- How many different names FindRow was asked for in a table, and the most often any one was asked.
function tables.asked_rows(name)
    local distinct, most = 0, 0
    for _, times in pairs(tables.asked[name] or {}) do
        distinct = distinct + 1
        if times > most then most = times end
    end
    return distinct, most
end

function tables.install()
    function StaticFindObject(path)
        tables.touches = tables.touches + 1
        tables.finds = tables.finds + 1
        if type(path) ~= "string" then crash("StaticFindObject was given a " .. type(path)) end
        local shape = structs[path]
        if shape then return struct_object(shape) end
        if enum_fields[path] then
            tables.enum_finds = tables.enum_finds + 1
            return enum_object(enum_fields[path])
        end
        local state = by_path[path]
        if state and not state.hidden then return handle(state) end
        state = by_library[path]
        if state and not state.hidden then return library(state) end
        -- a miss costs 20 to 60 ms in the game
        tables.misses = tables.misses + 1
        return INVALID
    end
    function FName(value)
        tables.touches = tables.touches + 1
        if type(value) ~= "string" then crash("FName was given a " .. type(value)) end
        return name_object(value)
    end
    function FindAllOf(class_name)
        tables.touches = tables.touches + 1
        tables.lists = tables.lists + 1
        if class_name ~= "IcarusDataTable" then return nil end
        local out = {}
        for index, state in ipairs(listed) do
            if short and index > short then break end
            if not state.hidden then out[#out + 1] = handle(state) end
        end
        return #out > 0 and out or nil
    end
end

-- A small copy of the game's shapes: recipes, items and their meta table, tag queries. Returns what was put in.
function tables.sample(options)
    options = options or {}
    local S, U, G = "/Script/Icarus.", "/Script/IcarusUtilities.", "/Script/GameplayTags."
    -- a row, a row enum and a multi row handle start with a vtable pointer that nothing reflects
    tables.struct("/Script/Engine.TableRowBase", nil, {}, { lead = 8 })
    tables.struct(U .. "IcarusTableRowBase", "/Script/Engine.TableRowBase",
        { { "CachedHardReferences", "ArrayProperty", inner = "ObjectProperty" } })
    tables.struct(U .. "RowHandle", nil,
        { { "DataTablePtr", "WeakObjectProperty" }, { "RowName", "NameProperty" }, { "DataTableName", "NameProperty" } })
    for _, name in ipairs({ "ItemsStatic", "ItemTemplate", "Talents", "RecipeSets", "CharacterFlags", "Itemable", "TagQueries",
                            "FeatureLevels" }) do
        tables.struct(S .. name .. "RowHandle", U .. "RowHandle", {})
    end
    tables.struct(U .. "MultiRowHandle", nil, { { "RowName", "NameProperty" } }, { lead = 8 })
    tables.struct(S .. "FlagsMultiRowHandle", U .. "MultiRowHandle", { { "DataTableName", "EnumProperty",
        enum = { "D_CharacterFlags", "D_SessionFlags", "D_AccountFlags", "D_DLCPackageData" } } })
    tables.struct(U .. "RowEnum", nil, { { "Value", "NameProperty" } }, { lead = 8 })
    tables.struct(S .. "IcarusResourcesEnum", U .. "RowEnum", {})
    tables.struct(S .. "CraftingInput", nil,
        { { "Element", "StructProperty", struct = S .. "ItemsStaticRowHandle" }, { "Count", "IntProperty" } })
    tables.struct(S .. "QueryInput", nil,
        { { "Query", "StructProperty", struct = S .. "TagQueriesRowHandle" }, { "Count", "IntProperty" } })
    tables.struct(S .. "ResourceItem", nil,
        { { "Type", "StructProperty", struct = S .. "IcarusResourcesEnum" }, { "RequiredUnits", "IntProperty" } })
    tables.struct(S .. "CraftingOutput", nil,
        { { "Element", "StructProperty", struct = S .. "ItemTemplateRowHandle" }, { "Count", "IntProperty" } })
    tables.struct(S .. "ProcessorRecipe", U .. "IcarusTableRowBase", {
        { "bForceDisableRecipe", "BoolProperty" },
        { "Requirement", "StructProperty", struct = S .. "TalentsRowHandle" },
        { "SessionRequirement", "StructProperty", struct = S .. "FlagsMultiRowHandle" },
        { "CharacterRequirement", "StructProperty", struct = S .. "CharacterFlagsRowHandle" },
        { "RequiredMillijoules", "IntProperty" },
        { "RecipeSets", "ArrayProperty", inner = "StructProperty", struct = S .. "RecipeSetsRowHandle" },
        { "Inputs", "ArrayProperty", inner = "StructProperty", struct = S .. "CraftingInput" },
        { "QueryInputs", "ArrayProperty", inner = "StructProperty", struct = S .. "QueryInput" },
        { "ResourceInputs", "ArrayProperty", inner = "StructProperty", struct = S .. "ResourceItem" },
        { "Outputs", "ArrayProperty", inner = "StructProperty", struct = S .. "CraftingOutput" },
        { "Refundable", "EnumProperty", enum = { "Inherit", "Block", "Allow" } },
        { "RefundSteps", "ArrayProperty", inner = "EnumProperty", enum = { "None", "Half", "Full", "Double" } },
        { "ExperienceMultiplier", "FloatProperty" },
        { "Overrides", "MapProperty" },
        { "OnCrafted", "MulticastInlineDelegateProperty" },
        { "Preview", "ObjectProperty" },
    })
    tables.struct(S .. "ItemableData", U .. "IcarusTableRowBase", {
        { "Behaviour", "SoftClassProperty" }, { "DisplayName", "TextProperty" }, { "Icon", "SoftObjectProperty" },
        { "Description", "TextProperty" }, { "FieldGuideKeywords", "ArrayProperty", inner = "TextProperty" },
        { "Weight", "IntProperty" }, { "bAllowZeroWeight", "BoolProperty" }, { "MaxStack", "IntProperty" },
    })
    tables.struct(G .. "GameplayTag", nil, { { "TagName", "NameProperty" } })
    tables.struct(G .. "GameplayTagContainer", nil, {
        { "GameplayTags", "ArrayProperty", inner = "StructProperty", struct = G .. "GameplayTag" },
        { "ParentTags", "ArrayProperty", inner = "StructProperty", struct = G .. "GameplayTag" },
    })
    tables.struct(G .. "GameplayTagQuery", nil, {
        { "TokenStreamVersion", "IntProperty" },
        { "TagDictionary", "ArrayProperty", inner = "StructProperty", struct = G .. "GameplayTag" },
        { "QueryTokenStream", "ArrayProperty", inner = "ByteProperty" },
        { "UserDescription", "StrProperty" },
    })
    tables.struct(S .. "TagQueryData", U .. "IcarusTableRowBase",
        { { "Query", "StructProperty", struct = G .. "GameplayTagQuery" } })
    tables.struct(S .. "ItemStaticData", U .. "IcarusTableRowBase", {
        { "Itemable", "StructProperty", struct = S .. "ItemableRowHandle" },
        { "Generated_Tags", "StructProperty", struct = G .. "GameplayTagContainer" },
    })
    tables.struct(U .. "RowMetadata", "/Script/Engine.TableRowBase", {
        { "RequiredFeatureLevel", "StructProperty", struct = S .. "FeatureLevelsRowHandle" },
        { "bIsDeprecated", "BoolProperty" }, { "Notes", "StrProperty" }, { "ExtraMetadata", "MapProperty" },
    })
    -- a row struct with a field called Name, as two of the game's tables have
    tables.struct(S .. "LogCategory", U .. "IcarusTableRowBase", { { "Name", "StrProperty" }, { "Verbosity", "IntProperty" } })

    local function item(name) return { RowName = name, DataTableName = "D_ItemsStatic" } end
    local function made(name) return { RowName = name, DataTableName = "D_ItemTemplate" } end
    local function set(name) return { RowName = name, DataTableName = "D_RecipeSets" } end
    local function talent(name) return { RowName = name, DataTableName = "D_Talents" } end
    local recipes = {
        Stone_Pickaxe = { Requirement = talent("Stone_Pickaxe"), RequiredMillijoules = 2500, RecipeSets = { set("Character") },
            Inputs = { { Element = item("Fiber"), Count = 10 }, { Element = item("Stick"), Count = 4 }, { Element = item("Stone"), Count = 6 } },
            Outputs = { { Element = made("Stone_Pickaxe"), Count = 1 } }, ExperienceMultiplier = 1.0, Refundable = 2 },
        -- the engine spells this input "bone": names keep the letter case they were first seen with
        Bone_Knife = { Requirement = talent("Bone_Knife"), RequiredMillijoules = 3750, RecipeSets = { set("Character") },
            Inputs = { { Element = item("Wood"), Count = 2 }, { Element = item("Leather"), Count = 2 }, { Element = item("bone"), Count = 20 } },
            Outputs = { { Element = made("Bone_Knife"), Count = 1 } }, ExperienceMultiplier = 1.0, Refundable = 1,
            RefundSteps = { 3, 1 } },
        Dough_Bread = { Requirement = talent("Dough_Bread"), RequiredMillijoules = 2500,
            RecipeSets = { set("Kitchen_Bench"), set("Advanced_Kitchen_Bench") },
            Inputs = { { Element = item("Flour"), Count = 3 }, { Element = item("Yeast"), Count = 1 } },
            ResourceInputs = { { Type = { Value = "Water" }, RequiredUnits = 100 } },
            Outputs = { { Element = made("Dough_Bread"), Count = 1 } }, ExperienceMultiplier = 0.5 },
        Gold_Bed = { Requirement = talent("Gold_Decorations"), SessionRequirement = { RowName = "Art_Deco_Pack", DataTableName = 4 },
            RequiredMillijoules = 5000, RecipeSets = { set("Rustic_Decorations_Bench") }, bForceDisableRecipe = true,
            Inputs = { { Element = item("Refined_Gold"), Count = 8 }, { Element = item("Stone"), Count = 20 } },
            QueryInputs = { { Query = { RowName = "Any_Fabric", DataTableName = "D_TagQueries" }, Count = 6 } },
            Outputs = { { Element = made("Gold_Bed"), Count = 1 } }, ExperienceMultiplier = 1.0 },
        Nothing_In = { RequiredMillijoules = 1 },
    }
    local order = { "Stone_Pickaxe", "Bone_Knife", "Dough_Bread", "Gold_Bed", "Nothing_In" }
    for i = 1, options.recipes or 55 do
        local name = ("Made_%02d"):format(i)
        local row = { Requirement = talent(name), RequiredMillijoules = 1000 + i, RecipeSets = {}, Inputs = {}, Outputs = {},
                      ExperienceMultiplier = 1.0 }
        for j = 1, i % 3 do row.RecipeSets[j] = set("Bench_" .. j) end
        for j = 1, i % 4 + 1 do row.Inputs[j] = { Element = item("Part_" .. j), Count = i + j } end
        for j = 1, i % 2 + 1 do row.Outputs[j] = { Element = made(name), Count = j } end
        recipes[name] = row
        -- the engine keeps one spelling per name, not always the file's
        order[#order + 1] = i % 7 == 0 and name:upper() or name
    end
    local total = { recipes = #order, inputs = 0, outputs = 0, sets = 0 }
    for _, row in pairs(recipes) do
        total.inputs = total.inputs + #(row.Inputs or {})
        total.outputs = total.outputs + #(row.Outputs or {})
        total.sets = total.sets + #(row.RecipeSets or {})
    end
    tables.table("ProcessorRecipes", S .. "ProcessorRecipe", recipes, order)

    tables.table("Itemable", S .. "ItemableData", {
        Item_Wood = { DisplayName = "Wood", Icon = "/Game/Assets/2DArt/UI/Items/Item_Icons/Resources/ITEM_Wood.ITEM_Wood",
                      Description = "A length of timber.", Weight = 150, MaxStack = 100, FieldGuideKeywords = { "log", "timber" } },
        Item_Fiber = { DisplayName = "Fiber", Icon = "/Game/Assets/2DArt/UI/Items/Item_Icons/Resources/ITEM_Fibre.ITEM_Fibre",
                       Weight = 10, MaxStack = 200, Behaviour = "/Game/BP/Items/BP_Fiber.BP_Fiber_C" },
        Item_Ghost = { DisplayName = "", Weight = 0, bAllowZeroWeight = true, MaxStack = 1 },
    }, { "Item_Wood", "Item_Fiber", "Item_Ghost" })

    local function tags(...)
        local out = {}
        for i, name in ipairs({ ... }) do out[i] = { TagName = name } end
        return out
    end
    tables.table("ItemsStatic", S .. "ItemStaticData", {
        Wood = { Itemable = { RowName = "Item_Wood", DataTableName = "D_Itemable" },
                 Generated_Tags = { GameplayTags = tags("Item.Resource.Wood"), ParentTags = tags("Item", "Item.Resource") } },
        Fish_03 = { Itemable = { RowName = "Item_Fish_03", DataTableName = "D_Itemable" },
                    Generated_Tags = { GameplayTags = tags("NPC.Fish.Saltwater", "Item.Food"), ParentTags = tags("NPC", "NPC.Fish", "Item") } },
        Kit_Radar = { Itemable = { RowName = "Item_Kit_Radar", DataTableName = "D_Itemable" } },
    }, { "Wood", "Fish_03", "Kit_Radar" })
    local function level(name) return { RowName = name, DataTableName = "D_FeatureLevels" } end
    tables.meta("ItemsStatic", U .. "RowMetadata", {
        Wood = { RequiredFeatureLevel = level("Core") },
        Fish_03 = { RequiredFeatureLevel = level("NewFrontiers"), Notes = "salt water" },
        Kit_Radar = { RequiredFeatureLevel = level("Core"), bIsDeprecated = true },
    }, { "Wood", "Fish_03", "Kit_Radar" })

    tables.table("TagQueries", S .. "TagQueryData", {
        FieldGuide_Hide = { Query = { TokenStreamVersion = 0, TagDictionary = tags("Item.Quest", "FieldGuide.BlackList"),
                                      QueryTokenStream = { 0, 1, 5, 2, 1, 6, 0, 1 }, UserDescription = "hidden from the guide" } },
    }, { "FieldGuide_Hide" })

    tables.table("LogCategories", S .. "LogCategory", {
        LogTemp = { Name = "Temporary", Verbosity = 3 },
    }, { "LogTemp" })

    tables.struct(S .. "RecipeSet", U .. "IcarusTableRowBase", {
        { "RecipeSetName", "TextProperty" }, { "RecipeSetIcon", "SoftObjectProperty" }, { "ExperienceMultiplier", "FloatProperty" },
        { "bAllowRefundOfRecipesOnDestroy", "BoolProperty" },
    })
    tables.table("RecipeSets", S .. "RecipeSet", {
        Character = { RecipeSetName = "Character", RecipeSetIcon = "/Game/Assets/2DArt/UI/Icons/Icon_PlayerCrafting.Icon_PlayerCrafting",
                      ExperienceMultiplier = 0.25 },
        Kitchen_Bench = { RecipeSetName = "Kitchen Bench", ExperienceMultiplier = 10.0, bAllowRefundOfRecipesOnDestroy = true },
    }, { "Character", "Kitchen_Bench" })

    tables.fill(options.fill or 255)
    return total
end

-- Forgets every struct and table, for a file that builds more than one set.
function tables.clear()
    structs, by_path, by_name, by_library, listed, field_names, enum_fields, short = {}, {}, {}, {}, {}, {}, {}, nil
    tables.frame, tables.writable = 0, false
    tables.reset()
end

local function self_test()
    local passed, failed = 0, 0
    local function check(what, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        print(("%s  %s%s"):format(ok and "ok  " or "FAIL", what, detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
    -- fn must raise with `fragment` in the message, and `counter` must go up by one
    local function raises(what, counter, fragment, fn)
        local before = counter and tables[counter] or 0
        local ok, problem = pcall(fn)
        local counted = not counter or tables[counter] == before + 1
        check(what, not ok and tostring(problem):find(fragment, 1, true) ~= nil and counted, ok and "did not raise" or problem)
    end

    local total = tables.sample()
    tables.install()
    local path = "/Engine/Transient.D_ProcessorRecipes"

    local recipes = StaticFindObject(path)
    check("a table is a UDataTable with a length, an address and its row struct",
        recipes:IsValid() and recipes:type() == "UDataTable" and #recipes == total.recipes and math.type(recipes:GetAddress()) == "integer"
        and recipes:GetRowStruct():GetFullName() == "ScriptStruct /Script/Icarus.ProcessorRecipe")
    check("GetRowNames gives plain strings in the engine's spelling", recipes:GetRowNames()[11] == "Made_06"
        and recipes:GetRowNames()[12] == "MADE_07")
    local knife = recipes:FindRow("bone_knife")
    check("a row is found whatever the letter case", knife ~= nil and knife.RequiredMillijoules == 3750)
    check("names and text have ToString", knife.Requirement.RowName:ToString() == "Bone_Knife")
    check("a handle's inherited fields are there", knife.Inputs[3].Element.DataTableName:ToString() == "D_ItemsStatic")
    check("a field the row leaves out reads as its empty value", knife.bForceDisableRecipe == false
        and knife.SessionRequirement.RowName:ToString() == "None" and knife.QueryInputs:GetArrayNum() == 0)
    local wood = StaticFindObject("/Engine/Transient.D_Itemable"):FindRow("Item_Wood")
    check("a soft reference gives its path through GetObjectID():GetAssetPathName():ToString()",
        wood.Icon:GetObjectID():GetAssetPathName():ToString():find("ITEM_Wood", 1, true) ~= nil and wood.Icon:type() == "TSoftObjectPtrUserdata")
    check("a soft reference to nothing is None", wood.Behaviour:GetObjectID():GetAssetPathName():ToString() == "None")
    local stream = StaticFindObject("/Engine/Transient.D_TagQueries"):FindRow("FieldGuide_Hide").Query.QueryTokenStream
    check("an array of bytes reads as numbers", stream:GetArrayNum() == 8 and stream[3] == 5)
    local meta = StaticFindObject("/Engine/Transient.D_ItemsStatic").MetaTable
    check("MetaTable is another table", meta:IsValid() and meta:type() == "UDataTable" and #meta == 3
        and meta:FindRow("Kit_Radar").bIsDeprecated == true)
    check("a table without one has an invalid MetaTable", recipes.MetaTable:IsValid() == false)
    local listed_now = FindAllOf("IcarusDataTable")
    check("FindAllOf lists the tables and no meta table", #listed_now == tables.listed() and tables.listed() >= 250)
    tables.short_list(40)
    check("it can be told to give a short list", #FindAllOf("IcarusDataTable") == 40)
    tables.short_list(nil)
    check("another class finds nothing", FindAllOf("Actor") == nil)

    raises("FindRow with a number raises", "crashes", "FindRow was given a number", function() recipes:FindRow(12) end)
    local unknown = tables.unknown_names
    check("FindRow with a name the table lacks is nil and is counted", recipes:FindRow("No_Such_Row") == nil
        and tables.unknown_names == unknown + 1 and tables.asked.ProcessorRecipes.No_Such_Row == 1)
    check("every name asked is recorded", tables.asked.ProcessorRecipes.bone_knife == 1)
    raises("a struct indexed with a number raises", "crashes", "indexed with a number", function() return knife[1] end)
    raises("a field the struct does not have raises", "misuse", "has no field named Inputz", function() return knife.Inputz end)
    raises("writing to a row raises", "crashes", "was written", function() knife.RequiredMillijoules = 1 end)
    raises("a map field raises", "never_reads", "MapProperty", function() return knife.Overrides end)
    raises("a delegate field raises", "never_reads", "MulticastInlineDelegateProperty", function() return knife.OnCrafted end)
    raises("an object field raises", "never_reads", "ObjectProperty", function() return knife.Preview end)
    raises("a weak object field raises", "never_reads", "WeakObjectProperty", function() return knife.Requirement.DataTablePtr end)
    raises("an element of an array of objects raises", "never_reads", "ObjectProperty", function()
        local kept = knife.CachedHardReferences
        return kept[1]
    end)
    local enums = tables.enum_reads
    check("every enum read is counted", knife.Refundable == 1 and knife.SessionRequirement.DataTableName == 0
        and knife.RefundSteps[2] == 1 and tables.enum_reads == enums + 3)

    local inputs = knife.Inputs
    local grown = tables.grown
    check("reading one past the end of an array makes it longer and is counted", inputs:GetArrayNum() == 3 and inputs[4] ~= nil
        and inputs:GetArrayNum() == 4 and tables.grown == grown + 1)
    raises("an index further out raises", "misuse", "out of range", function() return inputs[9] end)
    raises("index 0 raises", "misuse", "out of range", function() return inputs[0] end)
    raises("a loop that waits for nil is stopped", nil, "never ends", function()
        for _ in ipairs(recipes:FindRow("Stone_Pickaxe").Inputs) do end
    end)
    raises("an array asked for a member it should not be asked for raises", "misuse", "ForEach", function() return inputs.ForEach end)

    raises("a name asked for anything but ToString raises", "misuse", "GetComparisonIndex",
        function() return knife.Requirement.RowName:GetComparisonIndex() end)
    raises("anything but IsValid on an invalid object raises", "crashes", "not valid",
        function() return StaticFindObject("/Engine/Transient.D_Nothing"):GetRowNames() end)
    check("and that find was a miss", tables.misses == 1)
    raises("StaticFindObject with a number raises", "crashes", "StaticFindObject was given a number", function() StaticFindObject(5) end)

    local struct = StaticFindObject("/Script/Icarus.ProcessorRecipe")
    local seen, kept = {}, nil
    struct:ForEachProperty(function(p)
        seen[#seen + 1] = p:GetFName():ToString() .. ":" .. p:GetClass():GetFName():ToString()
        if p:GetFName():ToString() == "Inputs" then kept = p end
    end)
    check("ForEachProperty gives the struct's own fields only", #seen == 16 and seen[1] == "bForceDisableRecipe:BoolProperty"
        and seen[7] == "Inputs:ArrayProperty", #seen)
    check("GetSuperStruct names the parent", struct:GetSuperStruct():IsValid()
        and struct:GetSuperStruct():GetFullName() == "ScriptStruct /Script/IcarusUtilities.IcarusTableRowBase")
    check("a struct without a parent has an invalid one", StaticFindObject("/Script/Icarus.CraftingInput"):GetSuperStruct():IsValid() == false)
    raises("a parent struct asked for its properties raises", "misuse", "ForEachProperty",
        function() struct:GetSuperStruct():ForEachProperty(function() end) end)
    raises("a property used after ForEachProperty returned raises", "stale", "after ForEachProperty returned",
        function() return kept:GetFName() end)
    struct:ForEachProperty(function(p)
        local name = p:GetFName():ToString()
        if name == "Requirement" then
            check("GetStruct() says its full name", p:GetStruct():GetFullName() == "ScriptStruct /Script/Icarus.TalentsRowHandle")
            raises("and nothing else", "misuse", "ForEachProperty", function() p:GetStruct():ForEachProperty(function() end) end)
            raises("GetInner() on a struct property raises", "crashes", "GetInner() on a StructProperty", function() p:GetInner() end)
        elseif name == "Inputs" then
            local inner = p:GetInner()
            check("GetInner() says its class and its struct's full name", inner:GetClass():GetFName():ToString() == "StructProperty"
                and inner:GetStruct():GetFullName() == "ScriptStruct /Script/Icarus.CraftingInput")
            raises("and nothing else", "misuse", "GetFName", function() return inner:GetFName() end)
        elseif name == "RequiredMillijoules" then
            raises("GetStruct() on a number property raises", "crashes", "GetStruct() on a IntProperty", function() p:GetStruct() end)
        elseif name == "RefundSteps" then
            raises("GetStruct() on the inner of an array of enums raises", "crashes", "array of EnumProperty",
                function() p:GetInner():GetStruct() end)
            check("GetEnum() on the inner of an array of enums says the enum's full name",
                p:GetInner():GetEnum():GetFullName() == "Enum /Script/Icarus.ERefundSteps")
        elseif name == "Refundable" then
            check("GetEnum() on an enum property says the enum's full name", p:GetEnum():GetFullName() == "Enum /Script/Icarus.ERefundable")
        elseif name == "ExperienceMultiplier" then
            raises("GetEnum() on a number property raises", "crashes", "GetEnum() on a FloatProperty", function() p:GetEnum() end)
        end
    end)
    local labels = {}
    local refundable = StaticFindObject("/Script/Icarus.ERefundable")
    refundable:ForEachName(function(label, number) labels[label:ToString()] = number end)
    check("an enum is found by its path and gives each label with its number, the _MAX label too",
        refundable:IsValid() and refundable:type() == "UEnum" and labels["ERefundable::Block"] == 1
        and labels["ERefundable::ERefundable_MAX"] == 3 and tables.enum_finds == 1)
    raises("a ForEachProperty callback that returns a value raises", "misuse", "returned a value",
        function() struct:ForEachProperty(function() return true end) end)

    tables.poison("Itemable", "Item_Fiber", "Weight")
    raises("a poisoned field raises as a failed engine read", nil, "could not read",
        function() return StaticFindObject("/Engine/Transient.D_Itemable"):FindRow("Item_Fiber").Weight end)

    local row = recipes:FindRow("Dough_Bread")
    local resources = row.ResourceInputs
    local first = resources[1]
    local name = first.Type.Value
    tables.next_frame()
    raises("a table used after its frame raises", "stale", "after its frame", function() return recipes:IsValid() end)
    raises("a row used after its frame raises", "stale", "after its frame", function() return row.RequiredMillijoules end)
    raises("an array used after its frame raises", "stale", "after its frame", function() return resources:GetArrayNum() end)
    raises("a struct from an array used after its frame raises", "stale", "after its frame", function() return first.RequiredUnits end)
    raises("a struct object used after its frame raises", "stale", "after its frame", function() return struct:GetFullName() end)
    check("a name read before the frame ended is still text", name:ToString() == "Water")

    local address = StaticFindObject(path):GetAddress()
    tables.move("ProcessorRecipes")
    check("a moved table has another address", StaticFindObject(path):GetAddress() ~= address)
    tables.hide("ProcessorRecipes")
    check("a hidden table is not found and not listed", StaticFindObject(path):IsValid() == false
        and #FindAllOf("IcarusDataTable") == tables.listed() - 1)
    tables.hide("ProcessorRecipes", false)
    check("and is back when shown again", StaticFindObject(path):IsValid() == true)

    -- writes, with UE4SS's rules
    tables.next_frame()
    tables.reset()
    recipes = StaticFindObject(path)
    raises("AddRow raises while writes are not allowed", "crashes", "AddRow was called",
        function() recipes:AddRow("Scratch", recipes:FindRow("Bone_Knife")) end)
    tables.allow_writes(true)
    recipes:AddRow("Scratch", recipes:FindRow("Bone_Knife"))
    check("AddRow puts a copy at the end, and the game's own index is not told", #recipes == total.recipes + 1
        and recipes:GetRowNames()[#recipes] == "Scratch" and select(2, tables.indexed("ProcessorRecipes", "Scratch")) == false)
    local index = StaticFindObject("/Script/Icarus.Default__ProcessorRecipesLibrary")
    index:RefreshConstants()
    check("RefreshConstants tells it", index:IsValid() and index:IsValidName(FName("scratch")) == true
        and index:NumRows() == total.recipes + 1 and tables.refreshes == 1)
    local scratch = recipes:FindRow("Scratch")
    scratch.RequiredMillijoules = 5000
    scratch.ExperienceMultiplier = 0.1
    scratch.bForceDisableRecipe = true
    scratch.Refundable = 2
    check("a number, a float kept in single precision, a bool and an enum are written",
        scratch.RequiredMillijoules == 5000 and scratch.ExperienceMultiplier ~= 0.1 and math.abs(scratch.ExperienceMultiplier - 0.1) < 1e-7
        and scratch.bForceDisableRecipe == true and scratch.Refundable == 2)
    check("the copy is its own", recipes:FindRow("Bone_Knife").RequiredMillijoules == 3750)
    check("reading an enum leaves its names in a global", rawget(_G, "Enum_Refundable")["ERefundable::Block"] == 1)
    scratch.Requirement.RowName = FName("Stone_Pickaxe")
    check("a name is written as an FName", scratch.Requirement.RowName:ToString() == "Stone_Pickaxe")
    raises("a string into a name slot raises", "crashes", "only an FName", function() scratch.Requirement.RowName = "Stone_Pickaxe" end)
    local sloppy = tables.sloppy
    scratch.RequiredMillijoules = 1.5
    scratch.bForceDisableRecipe = 0
    check("a fraction into a whole number stores 0, 0 into a bool stores true, and both are counted",
        scratch.RequiredMillijoules == 0 and scratch.bForceDisableRecipe == true and tables.sloppy == sloppy + 2)
    local silent = tables.silent
    scratch.NoSuchFieldAnywhere = 1
    check("a field name the game does not know is taken without a word, and is counted", tables.silent == silent + 1)
    raises("a field name the game knows from another struct raises", nil, "Was unable to retrieve property",
        function() scratch.TagName = FName("x") end)
    scratch.requiredmillijoules = 7
    check("a field is written whatever its letter case", scratch.RequiredMillijoules == 7)
    scratch.Requirement = { RowName = FName("Bone_Knife"), rowname = FName("x") }
    check("a struct given as a table writes the keys spelled as its fields, skips the rest and keeps what it was not given",
        scratch.Requirement.RowName:ToString() == "Bone_Knife" and scratch.Requirement.DataTableName:ToString() == "D_Talents"
        and tables.silent == silent + 2)

    local list = scratch.Inputs
    local had = list:GetArrayNum()
    local head = list[1]
    local appends = tables.appends
    list[had + 1] = {}
    check("a write one past the end adds a zeroed entry", list:GetArrayNum() == had + 1 and tables.appends == appends + 1
        and list[had + 1].Count == 0 and list[had + 1].Element.RowName:ToString() == "None" and tables.grown == 0)
    raises("an entry handed out before the list grew raises", "crashes", "emptied or made longer", function() return head.Count end)
    list[had + 1].Count = 9
    list[had + 1].Element.RowName = FName("Wood")
    check("and it is filled in place", list[had + 1].Count == 9 and list[had + 1].Element.RowName:ToString() == "Wood")
    local second = list[2]
    list:Empty()
    check("Empty leaves nothing", list:GetArrayNum() == 0 and tables.empties == 1 and tables.leaks == 0)
    raises("an entry handed out before Empty raises", "crashes", "emptied or made longer", function() return second.Count end)
    raises("an index past the first on an empty list raises", "crashes", "touches memory past it", function() list[3] = {} end)
    raises("a Lua table for a whole list raises", "misuse", "without freeing it", function() scratch.Inputs = { {} } end)
    local wooden = StaticFindObject("/Engine/Transient.D_Itemable"):FindRow("Item_Wood")
    raises("a text cannot be written", "crashes", "only an FText", function() wooden.DisplayName = "Timber" end)
    local keywords = wooden.FieldGuideKeywords
    keywords:Empty()
    check("Empty on entries that own memory leaves it behind, and that is counted", tables.leaks == 1)
    raises("a list of text cannot be made longer", "crashes", "a zeroed text is not valid", function() keywords[1] = "log" end)

    local bread = recipes:FindRow("Dough_Bread")
    local water = bread.ResourceInputs
    raises("a list whose entries start with a vtable pointer cannot be made longer", "crashes", "only the game fills in",
        function() water[2] = {} end)
    raises("nor emptied", "misuse", "keeps its length", function() water:Empty() end)
    water[1].Type.Value = FName("Milk")
    water[1].RequiredUnits = 5
    check("an entry it has is changed in place", water:GetArrayNum() == 1 and water[1].Type.Value:ToString() == "Milk"
        and tables.row("ProcessorRecipes", "Dough_Bread").ResourceInputs[1].RequiredUnits == 5)

    local offsets = {}
    StaticFindObject("/Script/IcarusUtilities.RowEnum"):ForEachProperty(function(p) offsets.enum = p:GetOffset_Internal() end)
    StaticFindObject("/Script/IcarusUtilities.RowHandle"):ForEachProperty(function(p) offsets[#offsets + 1] = p:GetOffset_Internal() end)
    check("a property says its offset: 8 behind a vtable pointer, 0 without one", offsets.enum == 8 and offsets[1] == 0 and offsets[2] == 8)

    tables.deaf("ProcessorRecipes", "Bone_Knife", "RequiredMillijoules")
    knife = recipes:FindRow("Bone_Knife")
    knife.RequiredMillijoules = 1
    check("a deaf field drops a write without a word", knife.RequiredMillijoules == 3750)
    tables.deaf("ProcessorRecipes", "Bone_Knife", "RequiredMillijoules", false)
    tables.break_write("ProcessorRecipes", "Bone_Knife", "Inputs", 1)
    knife = recipes:FindRow("Bone_Knife")
    knife.Inputs[1].Count = 3
    raises("a broken field raises after the writes it lets through", nil, "the engine refused to write",
        function() knife.Inputs[2].Count = 3 end)
    tables.break_write("ProcessorRecipes", "Bone_Knife", "Inputs", nil)

    raises("AddRow over a row of the game raises", "crashes", "a row of the game",
        function() recipes:AddRow("Bone_Knife", recipes:FindRow("Stone_Pickaxe")) end)
    raises("RemoveRow of a row of the game raises", "crashes", "a row of the game", function() recipes:RemoveRow("Bone_Knife") end)
    recipes:AddRow("Scratch", recipes:FindRow("Stone_Pickaxe"))
    raises("a row handed out before AddRow replaced it raises", "crashes", "removed or replaced",
        function() return scratch.RequiredMillijoules end)
    scratch = recipes:FindRow("Scratch")
    recipes:RemoveRow("scratch")
    check("RemoveRow takes a scratch row out", #recipes == total.recipes and tables.row("ProcessorRecipes", "Scratch") == nil
        and tables.rows_removed == 1)
    raises("a row handed out before it was removed raises", "crashes", "removed or replaced",
        function() return scratch.RequiredMillijoules end)
    raises("EmptyTable raises", "crashes", "EmptyTable", function() recipes:EmptyTable() end)
    raises("AddRow with a number for a name raises as UE4SS does", nil, "expects a string", function() recipes:AddRow(5, {}) end)

    tables.allow_writes(false)
    tables.struct("/Script/Icarus.GrowthRow", nil, {
        { "Base", "MapProperty", key = { "StructProperty", struct = "/Script/Icarus.IcarusResourcesEnum" }, value = { "IntProperty" } },
        { "Health", "ObjectProperty", class = "CurveFloat" },
    })
    tables.table("Growth", "/Script/Icarus.GrowthRow", {
        Deer = { Base = { { { Value = "Speed" }, 220 }, { { Value = "Mass" }, 175 } },
                 Health = { name = "C_Deer", keys = { { 0, 300 }, { 120, 500 } } } },
        Rabbit = {},
    }, { "Deer", "Rabbit" })
    local deer = StaticFindObject("/Engine/Transient.D_Growth"):FindRow("Deer")
    local seen, kept = {}, nil
    deer.Base:ForEach(function(k, v)
        kept = k
        local key = k:get()
        seen[#seen + 1] = key.Value:ToString() .. "=" .. v:get() .. " " .. key:type() .. " " .. tostring(key:IsMappedToProperty())
            .. " " .. key:GetProperty():GetStruct():GetFullName()
    end)
    check("a declared map hands out each key and value behind get(), and a struct key says which struct it is",
        #deer.Base == 2 and seen[1] == "Speed=220 UScriptStruct true ScriptStruct /Script/Icarus.IcarusResourcesEnum"
        and seen[2]:find("^Mass=175") ~= nil and tables.map_entries == 2)
    raises("a key used after its callback raises", "stale", "after its callback returned", function() return kept:get() end)
    raises("an error that leaves a ForEach callback raises", "crashes", "passes through UE4SS's own code",
        function() deer.Base:ForEach(function() error("oops") end) end)
    raises("GetProperty on a row raises", "crashes", "no property handed out", function() return deer:GetProperty() end)
    check("a row is not mapped to a property", deer:IsMappedToProperty() == false)
    local curve = deer.Health
    check("a curve says what it is, its keys and its value at a time", curve:IsValid() and curve:type() == "UObject"
        and curve:GetFullName() == "CurveFloat /Game/Data/Curves/C_Deer.C_Deer" and curve.FloatCurve.Keys:GetArrayNum() == 2
        and curve.FloatCurve.Keys[2].Time == 120 and curve:GetFloatValue(30) == 350)
    raises("a curve key past the end raises", "crashes", "reading past the end", function() return curve.FloatCurve.Keys[3] end)
    local none = StaticFindObject("/Engine/Transient.D_Growth"):FindRow("Rabbit").Health
    check("an object field that points at nothing is an invalid object", none:IsValid() == false and none:type() == "UObject")
    raises("and anything else asked of it raises", "crashes", "not valid", function() return none:GetFullName() end)

    print(("fake_tables: %d passed, %d failed"):format(passed, failed))
    os.exit(failed == 0 and 0 or 1)
end

if arg and arg[0] and arg[0]:gsub("\\", "/"):find("fake_tables%.lua$") then self_test() end

return tables
