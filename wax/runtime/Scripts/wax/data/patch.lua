-- Changes rows of the game's tables for mods and puts them back: checked first, written, read back

local Wax = ...
local tables = Wax.import("data.tables")
local journal = Wax.import("data.journal")
local suggest = Wax.import("core.suggest")
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local perf = Wax.import("core.perf")
local co = Wax.import("core.co")
local log = Wax.import("core.log").channel("wax.data")

local M = {}
local T = tables.internal
local task = sched.task
local lower, type, pcall, error, tostring = string.lower, type, pcall, error, tostring

-- What this version writes. A kind is switched on once the game has shown that it works.
M.WRITES = {
    plain = true,           -- true or false, numbers, enums and strings, in place
    names = true,           -- names, row handles and row enums, in place
    handle_tables = false,  -- a row handle pointed at another table than it names now: the pointer it keeps is not written
    lists = true,           -- a list of the row whose entries are numbers, names and handles: emptied, then filled entry by entry
    long_lists = false,     -- the same with more than ROOM entries before or after, which makes the engine move the list as it grows
    owning_lists = false,   -- the same when an entry is a string or can hold one or a list of its own, those lists empty before and after
    nested_lists = false,   -- the same for a list inside a struct or a list entry, and emptying the lists of entries that go
    rows = false,           -- a new row: AddRow from a row of the game, then RefreshConstants
    remove = false,         -- taking a switched-off row out at the title screen
}
M.ROOM = 4                  -- the entries the first block of a list has room for

-- Asking a field which enum it is (GetEnum) was seen once in the game and never for a list. Off, an enum's names are known once a value of it was read.
M.FIND_ENUMS = false

-- How a row that a mod added is switched off when the mod unloads, by table. Modules that know a table add theirs.
M.OFF = { processorrecipes = { bForceDisableRecipe = true, RecipeSets = {} } }

M.TITLE = "TitleScreen"     -- the map on which switched-off rows are taken out
M.budget = 0.001            -- seconds of a frame for putting many fields back
M.summary_seconds = 1       -- how long a mod has to be quiet before the log says what it changed
M.announce_seconds = 0.25   -- while many fields are put back over frames, listeners hear of it this often
M.grace = 2                 -- seconds a mod that is loading again has to make its changes again before they are put back. 0 for none
M.retry_seconds = { 1, 5, 30 }      -- how long after a put-back that failed it is tried again
M.lost_every = 1            -- seconds between looks for a table that could not be found
M.lost_seconds = 120        -- after this long the log says its changes are not in the game
M.clock = perf.now

local RETIRED = "(switched off)"    -- owns the layers that switch a row off
local MAX_DEPTH = 16
local MAX_NAME = 100
local FLOAT_END = 0x1.ffffffp127    -- the first number a single-precision float turns into infinity
local HANDLE, MULTI = "/Script/IcarusUtilities.RowHandle", "/Script/IcarusUtilities.MultiRowHandle"
local ROW_ENUM, INT_ENUM = "/Script/IcarusUtilities.RowEnum", "/Script/IcarusEngineUtilities.IntEnum"

local owners = {}           -- mod id -> its scope while the mod is loaded
local watched = setmetatable({}, { __mode = "k" })      -- scopes that already put their changes back
local families = setmetatable({}, { __mode = "k" })     -- plan -> "handle", "enum" or false
local elements = setmetatable({}, { __mode = "k" })     -- a list's field -> what one entry of it is
local entries_of = setmetatable({}, { __mode = "k" })   -- a list of structs' field -> one entry of it, as a struct field
local enum_names = journal.enums()      -- "struct:field" of an enum -> { numbers = { folded name -> number }, names, values = { number -> name } }
local unfound = {}          -- "struct:field" of an enum the game was asked about without an answer
local built = {}            -- struct path -> whether UE4SS can make one from zeroed memory
local owning = {}           -- struct path -> whether one owns memory that Empty() would leave behind
local fixed = {}            -- struct path -> whether one holds text or a reference to an asset, which are never written
local seen = {}             -- table key -> { name, address } of the table that changes were written to
local lost = {}             -- table key -> when a table that changes were written to was first not found
local library_paths = nil
local leaving, leaving_at = {}, 1       -- keys to look at again, in the order they were queued
local parked, rows_wait = {}, false     -- keys and rows that wait for a mod that is loading again
local left_at = {}          -- mod id -> when it unloaded
local running = { now = {}, frame = nil }   -- which mods the loader has running, asked once a frame
local stuck = {}            -- keys whose put-back failed
local trouble = { again = 0, over = 0 }             -- the put-backs that failed in this round, for one line in the log
local torn = false          -- set when a write failed and the game was left holding neither the old value nor the new one
local rows_due, rows_check, title_due, at_title = false, false, false, false
local dirty = { list = {}, by = {}, tables = {} }
local fresh, summary_at = {}, 0
local told = {}             -- mods the player was told about in the game they joined
local timers = { retry_due = 0 }        -- the tasks that wait: hold, retry, lost, join and summary
local flush_thread, flush_frame, flush_begun, flush_watch = nil, 0, false, nil
local announced_at = 0
local standing = { ranks = nil, frame = nil, signature = nil }      -- each mod's place in the load order, worked out once a frame
local stats = { sets = 0, writes = 0, reads = 0, checks = 0, put_back = 0, settled = 0 }

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = copy(item) end
    return out
end

local function first_line(problem)
    return tostring(problem):match("^[^\r\n]*") or ""
end

-- What one entry of a list is, as a field of its own.
local function element_of(desc)
    local element = elements[desc]
    if not element then
        element = { Name = desc.Name, Kind = desc.Inner, how = desc.item, Struct = desc.Struct, named = desc.named, id = desc.id }
        elements[desc] = element
    end
    return element
end

-- One entry of a list of structs, as a struct field.
local function entry_of(desc)
    local entry = entries_of[desc]
    if not entry then
        entry = { Name = desc.Name, Kind = "Struct", how = "struct", Struct = desc.Struct }
        entries_of[desc] = entry
    end
    return entry
end

local TEXT_KINDS = { Name = "name", Str = "string", Text = "text" }
-- The switch each kind of value is written under. A kind that is not here is never written: text, and references to assets.
local SWITCH = { bool = "plain", int = "plain", float = "plain", enum = "plain", string = "plain", name = "names" }
local RANGES = { Byte = { 0, 255 }, Int8 = { -128, 127 }, Int16 = { -32768, 32767 }, Int = { -2147483648, 2147483647 },
                 UInt16 = { 0, 65535 }, UInt32 = { 0, 4294967295 }, UInt64 = { 0, math.maxinteger } }

-- What a single value is to the writer: bool, int, float, enum, name, string, text or soft.
local function leaf_kind(desc)
    local how = desc.how
    if how == "bool" then return "bool" end
    if how == "number" then
        if desc.named then return "enum" end
        return desc.Kind == "Float" and "float" or "int"
    end
    if how == "text" then return TEXT_KINDS[desc.Kind] or "text" end
    return "soft"
end

-- Names keep the letter case the game first saw them in, a float comes back in single precision, and what is never written never differs.
local function same_leaf(kind, a, b)
    if a == b or not SWITCH[kind] then return true end
    if kind == "name" then return type(a) == "string" and type(b) == "string" and lower(a) == lower(b) end
    if kind == "float" then
        if type(a) ~= "number" or type(b) ~= "number" then return false end
        local gap = math.abs(a - b)
        return gap < math.huge and gap <= 1e-6 * math.max(1, math.abs(a), math.abs(b))
    end
    return false
end

local same_struct

local function same(desc, a, b)
    local how = desc.how
    if how == "struct" then return same_struct(T.plan_of(desc.Struct), a, b) end
    if how ~= "array" then return same_leaf(leaf_kind(desc), a, b) end
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    if desc.item == "struct" then
        local plan = T.plan_of(desc.Struct)
        for index = 1, #a do
            if not same_struct(plan, a[index], b[index]) then return false end
        end
    else
        local kind = leaf_kind(element_of(desc))
        for index = 1, #a do
            if not same_leaf(kind, a[index], b[index]) then return false end
        end
    end
    return true
end

function same_struct(plan, a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local fields = plan.list
    for index = 1, #fields do
        local field = fields[index]
        if field.how and not same(field, a[field.Name], b[field.Name]) then return false end
    end
    return true
end

-- The first place where what the game holds is not what was asked for, in words.
local function difference(desc, wanted, got, where)
    local how = desc.how
    if how == "struct" or (how == "array" and desc.item == "struct") then
        if type(wanted) ~= "table" or type(got) ~= "table" then return where .. " could not be read back" end
        if how == "array" then
            if #wanted ~= #got then return ("%s has %d entries, not %d"):format(where, #got, #wanted) end
            local entry = { how = "struct", Struct = desc.Struct, Name = desc.Name }
            for index = 1, #wanted do
                local found = difference(entry, wanted[index], got[index], where .. "[" .. index .. "]")
                if found then return found end
            end
            return nil
        end
        local fields = T.plan_of(desc.Struct).list
        for index = 1, #fields do
            local field = fields[index]
            if field.how then
                local found = difference(field, wanted[field.Name], got[field.Name], where .. "." .. field.Name)
                if found then return found end
            end
        end
        return nil
    end
    if how == "array" then
        if type(wanted) ~= "table" or type(got) ~= "table" then return where .. " could not be read back" end
        if #wanted ~= #got then return ("%s has %d entries, not %d"):format(where, #got, #wanted) end
        local kind = leaf_kind(element_of(desc))
        for index = 1, #wanted do
            if not same_leaf(kind, wanted[index], got[index]) then
                return ("%s[%d] reads %s, not %s"):format(where, index, tostring(got[index]), tostring(wanted[index]))
            end
        end
        return nil
    end
    if same_leaf(leaf_kind(desc), wanted, got) then return nil end
    return ("%s reads %s, not %s"):format(where, tostring(got), tostring(wanted))
end

-- Keeps an enum's labels: each name to its number, with and without the enum in front, and each number's name. The _MAX label is its count, not a value.
local function keep_enum(id, labels)
    local known = { numbers = {}, names = {}, values = {} }
    for label, number in pairs(labels) do
        if type(label) == "string" and math.type(number) == "integer" then
            local short = label:match("::(.+)$") or label
            if not short:find("_MAX$") then
                known.numbers[lower(label)], known.numbers[lower(short)] = number, number
                known.names[#known.names + 1] = short
                local named = known.values[number]
                if named == nil or short < named then known.values[number] = short end
            end
        end
    end
    table.sort(known.names)
    -- only under the field's own text key: nothing of a plan is kept in the journal's global
    if type(id) == "string" then enum_names[id] = known end
    return known
end

-- UE4SS leaves an enum's names in a global each time one is read. They are kept, and the global is taken away.
local function take_enum(desc)
    local global = "Enum_" .. desc.Name
    local found = rawget(_G, global)
    if found == nil then return end
    rawset(_G, global, nil)
    if enum_names[desc.id] or type(found) ~= "table" then return end
    keep_enum(desc.id, found)
end

-- Asks the game which enum a field is and reads its names from the enum itself. Only with FIND_ENUMS, once for each field.
local function find_enum(desc)
    local id = desc.id
    if not M.FIND_ENUMS or type(id) ~= "string" or unfound[id] then return nil end
    unfound[id] = true
    local ok, known = pcall(function()
        local path, name = id:match("^(.*):([^:]*)$")
        local struct = StaticFindObject(path)
        if not struct:IsValid() then return nil end
        local enum_path = nil
        struct:ForEachProperty(function(property)
            if enum_path ~= nil or property:GetFName():ToString() ~= name then return end
            local class = property:GetClass():GetFName():ToString()
            if class == "ArrayProperty" then
                property = property:GetInner()
                class = property:GetClass():GetFName():ToString()
            end
            if class == "EnumProperty" then enum_path = (tostring(property:GetEnum():GetFullName()):gsub("^%S+%s+", "")) end
        end)
        if not enum_path then return nil end
        local enum = StaticFindObject(enum_path)
        if not enum:IsValid() or enum:type() ~= "UEnum" then return nil end
        local labels = {}
        enum:ForEachName(function(label, number) labels[label:ToString()] = number end)
        return keep_enum(id, labels)
    end)
    if not ok then log:warn("the names of the enum %s could not be read from the game: %s", id, first_line(known)) end
    return ok and known or nil
end

-- What is known of a field's enum, or nothing.
local function enum_of(desc)
    return enum_names[desc.id] or find_enum(desc)
end

local read_struct

local function read_leaf(desc, value)
    local out = T.scalar(desc.how, value)
    if desc.named then take_enum(desc) end
    return out
end

-- Everything of one field as plain values, enums too. Lists are read by their length, never past it.
local function read_field(desc, value, depth)
    local how = desc.how
    if how == "struct" then return read_struct(T.plan_of(desc.Struct), value, depth + 1) end
    if how ~= "array" then return read_leaf(desc, value) end
    local count = value:GetArrayNum()
    if type(count) ~= "number" then error("the game gave no length for a list", 0) end
    local out = {}
    if desc.item == "struct" then
        local plan = T.plan_of(desc.Struct)
        for index = 1, count do out[index] = read_struct(plan, value[index], depth + 1) end
    else
        local element = element_of(desc)
        for index = 1, count do
            local item = read_leaf(element, value[index])
            if item == nil then item = false end
            out[index] = item
        end
    end
    return out
end

function read_struct(plan, source, depth)
    if depth > MAX_DEPTH then error("a value is nested too deep to be read", 0) end
    local out, fields = {}, plan.list
    for index = 1, #fields do
        local field = fields[index]
        if field.how then out[field.Name] = read_field(field, source[field.Name], depth) end
    end
    return out
end

-- Reads one field of a row that the game handed out in this call.
local function read_of(field, row)
    stats.reads = stats.reads + 1
    return read_field(field, row[field.Name], 0)
end

-- "handle" for a row handle, "enum" for a row enum, nothing for any other struct.
local function family_of(plan)
    local known = families[plan]
    if known == nil then
        known = false
        for index = 1, #plan.chain do
            local path = plan.chain[index]
            if path == HANDLE then
                known = "handle"
                break
            elseif path == ROW_ENUM or path == INT_ENUM then
                known = "enum"
                break
            elseif path == MULTI then
                break
            end
        end
        families[plan] = known
    end
    return known or nil
end

-- The table a typed handle or a row enum points at, from the name of its struct.
local function target_of(plan, family)
    local short = plan.short
    local name = family == "handle" and short:match("^(.+)RowHandle$") or short:match("^(.+)Enum$")
    return name and ("D_" .. name) or nil
end

local ZEROED = { Bool = true, Int8 = true, Int16 = true, Int = true, Int64 = true, Byte = true, UInt16 = true, UInt32 = true,
                 UInt64 = true, Float = true, Enum = true, Name = true, Str = true, WeakObject = true }

-- Where the first field of a struct or of its parents starts. 0 means nothing sits in front that Lua cannot fill in.
local function lead_of(plan)
    local lowest = nil
    for index = 1, #plan.chain do
        local struct = StaticFindObject(plan.chain[index])
        if not struct:IsValid() then return nil end
        struct:ForEachProperty(function(property)
            local offset = property:GetOffset_Internal()
            if type(offset) == "number" and (lowest == nil or offset < lowest) then lowest = offset end
        end)
    end
    return lowest
end

local buildable
local deciding, decided = 0, {}

local function build_check(path)
    local ok, plan = pcall(T.plan_of, path)
    if not ok then return false end
    local read, lead = pcall(lead_of, plan)
    if not read or lead ~= 0 then return false end
    for index = 1, #plan.list do
        local field = plan.list[index]
        local kind = field.Kind
        if kind == "Struct" then
            if not (field.Struct and buildable(field.Struct)) then return false end
        elseif kind == "Array" then
            if field.item == "struct" then
                if not buildable(field.Struct) then return false end
            elseif not ZEROED[field.Inner] then
                return false
            end
        elseif not ZEROED[kind] then
            return false
        end
    end
    return true
end

-- True when UE4SS can add an entry of this struct to a list: it adds zeroed memory, so every byte has to be a field that zero is valid for.
function buildable(path)
    local known = built[path]
    if known ~= nil then return known end
    built[path] = true      -- a struct that holds a list of itself does not ask about itself again
    deciding = deciding + 1
    decided[#decided + 1] = path
    local answer = build_check(path)
    built[path] = answer
    deciding = deciding - 1
    if deciding == 0 then
        -- a yes that leaned on this one being a yes is asked again
        if not answer then
            for index = 1, #decided do
                if built[decided[index]] == true then built[decided[index]] = nil end
            end
        end
        decided = {}
    end
    return answer
end

-- True when an entry of this struct owns memory: a string or a list, at any depth.
local function owns(path)
    local known = owning[path]
    if known ~= nil then return known end
    owning[path] = false
    local answer = false
    for _, field in ipairs(T.plan_of(path).list) do
        if field.Kind == "Str" or field.Kind == "Array" or (field.Kind == "Struct" and field.Struct and owns(field.Struct)) then
            answer = true
            break
        end
    end
    owning[path] = answer
    return answer
end

-- The checks. Each raises with the place and what is wrong, and writes nothing.

local function shown(value)
    if type(value) == "string" then return "\"" .. value .. "\"" end
    if type(value) == "table" then return "a table" end
    return tostring(value)
end

local function wrong(where, wanted, value)
    error(("%s %s, got %s"):format(where, wanted, shown(value)), 0)
end

local function lacks(where, name, field)
    error(("%s lacks %s. Give the whole value, or use Change to alter a part of it%s"):format(where, name,
        field and field.named and " (Row reads an enum only when its path is named)" or ""), 0)
end

local function refuse_kind(where, desc)
    error(("%s is %s, which this version of Wax cannot change"):format(where, T.describe(desc)), 0)
end

local function enum_number(desc, value, where)
    local known = enum_of(desc)
    local number = known and known.numbers[lower(value)]
    if number then return number end
    if not known or #known.names == 0 then
        error(("%s is an enum and takes its number here, got \"%s\""):format(where, value), 0)
    end
    error(("%s has no value named '%s'.%s"):format(where, value, suggest.phrase(value, known.names)), 0)
end

-- An enum's values in words, by number: "Inherit (0), Block (1), Allow (2)".
local function enum_values(known)
    local numbers, parts = {}, {}
    for number in pairs(known.values) do numbers[#numbers + 1] = number end
    table.sort(numbers)
    for index = 1, math.min(#numbers, 12) do
        parts[index] = ("%s (%d)"):format(known.values[numbers[index]], numbers[index])
    end
    local text = table.concat(parts, ", ")
    if #numbers > 12 then text = ("%s and %d more"):format(text, #numbers - 12) end
    return text
end

-- Every number an enum holds anywhere in a value, by the enum's field.
local function collect_numbers(desc, value, into)
    local how = desc.how
    if how == "struct" then
        if type(value) ~= "table" then return end
        local fields = T.plan_of(desc.Struct).list
        for index = 1, #fields do
            local field = fields[index]
            if field.how then collect_numbers(field, value[field.Name], into) end
        end
    elseif how == "array" then
        if type(value) ~= "table" then return end
        local element = desc.item == "struct" and entry_of(desc) or element_of(desc)
        for index = 1, #value do collect_numbers(element, value[index], into) end
    elseif desc.named and desc.id and type(value) == "number" then
        local held = into[desc.id]
        if not held then
            held = {}
            into[desc.id] = held
        end
        held[value] = true
    end
end

-- A number the game's own value already holds for this enum may stay, named or not.
local function already_numbered(context, desc, number)
    local known = context.numbers
    if not known then
        known = {}
        if context.field then
            collect_numbers(context.field, context.current, known)
            collect_numbers(context.field, context.original, known)
        end
        context.numbers = known
    end
    local held = known[desc.id]
    return held ~= nil and held[number] == true
end

-- Every row a value points at: "table\0row" for a handle, "\0row" for a row enum, folded.
local function collect_names(value, into)
    if type(value) ~= "table" then return end
    local row, table_name, single = value.RowName, value.DataTableName, value.Value
    if type(row) == "string" and type(table_name) == "string" then into[lower(table_name) .. "\0" .. lower(row)] = true end
    if type(single) == "string" then into["\0" .. lower(single)] = true end
    for _, item in pairs(value) do collect_names(item, into) end
end

-- The game's own rows point at some rows that are not there. What a field already points at may stay.
local function already_named(context, table_name, row_name)
    local known = context.named
    if not known then
        known = {}
        collect_names(context.current, known)
        collect_names(context.original, known)
        context.named = known
    end
    return known[(table_name and lower(table_name) or "") .. "\0" .. lower(row_name)] == true
end

-- The nearest table name in words, with the D_ a handle spells it with. Nothing when it is the name that was given.
local function near_table(name)
    local short = name:gsub("^[Dd]_", "")
    local near = suggest.suggest(short, T.table_names(), 1)[1]
    if not near or lower(near) == lower(short) then return "" end
    return " Did you mean 'D_" .. near .. "'?"
end

local function no_table(where, table_name)
    error(("%s.DataTableName names the table %s, which the game does not have.%s"):format(where, table_name, near_table(table_name)), 0)
end

-- A row name checked against its table, returned as the game spells it. `where` is the handle or row enum, `part` its field, `single` true for a row enum.
local function check_row(table_name, row_name, where, part, context, single)
    if lower(row_name) == "none" then return "None" end
    if lower(table_name) == "none" then
        error(("%s.%s names the row '%s' but no table"):format(where, part, row_name), 0)
    end
    local index, names, title = T.rows(table_name)
    local real = index and (index[row_name] or index[lower(row_name)])
    if real then return real end
    if already_named(context, not single and table_name or nil, row_name) then return row_name end
    if not index then no_table(where, table_name) end
    error(("%s.%s: %s has no row named '%s'.%s"):format(where, part, title, row_name, suggest.phrase(row_name, names)), 0)
end

-- A handle's table name as the game lists it. A typed handle takes its own table, or the pair of table and row the field names already.
local function check_table(plan, given, row_name, held, where, context)
    local none = given == "" or lower(given) == "none"
    local listed = nil
    if not none then listed = select(4, T.rows(given)) end
    local own = target_of(plan, "handle")
    local own_listed = own and select(4, T.rows(own)) or nil
    if own_listed then
        if listed == own_listed then return own_listed end
        if none then
            if lower(row_name) ~= "none" then return "None" end
            -- a typed handle that points at nothing keeps the table it names, and a new one names its own, as the game's do
            return type(held) == "string" and held or own_listed
        end
        if already_named(context, given, row_name) then return given end
        error(("%s is a handle into %s and cannot name the table %s. Leave DataTableName out, or give %s"):format(where, own_listed,
            given, own_listed), 0)
    end
    if none then return "None" end
    if listed then return listed end
    if already_named(context, given, row_name) then return given end
    return no_table(where, given)
end

local function check_leaf(desc, value, base, where, context)
    local kind = leaf_kind(desc)
    local kept
    if kind == "bool" then
        if type(value) ~= "boolean" then wrong(where, "is true or false", value) end
        kept = value
    elseif kind == "int" then
        kept = type(value) == "number" and math.tointeger(value) or nil
        if not kept then wrong(where, "is a whole number", value) end
        local range = RANGES[desc.Kind]
        if range and (kept < range[1] or kept > range[2]) then
            error(("%s holds %d to %d, got %d"):format(where, range[1], range[2], kept), 0)
        end
    elseif kind == "float" then
        if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
            wrong(where, "is a number", value)
        end
        -- the game keeps a float in single precision: a larger number would be stored as infinity
        if math.abs(value) >= FLOAT_END then
            error(("%s holds numbers up to 3.4e38 either side of zero, got %s"):format(where, tostring(value)), 0)
        end
        kept = value
    elseif kind == "enum" then
        if type(value) == "string" then value = enum_number(desc, value, where) end
        kept = type(value) == "number" and math.tointeger(value) or nil
        if not kept or kept < 0 then wrong(where, "is an enum, given as its number or its name", value) end
        local known = enum_of(desc)
        if known and #known.names > 0 and not known.values[kept] and kept ~= base and not already_numbered(context, desc, kept) then
            error(("%s has no value with the number %d. It takes %s"):format(where, kept, enum_values(known)), 0)
        end
    elseif kind == "name" then
        if type(value) ~= "string" then wrong(where, "is a name, given as a string", value) end
        if #value > 1000 then error(where .. " is too long for a name", 0) end
        kept = value == "" and "None" or value
    elseif kind == "string" then
        if type(value) ~= "string" then wrong(where, "is a string", value) end
        kept = value
    else
        -- text and references to assets stay as they are in this version. A reference to nothing reads as nil, and as false in a list
        if value ~= nil and value ~= base and not (kind == "soft" and not value and not base) then
            error(("%s is %s, which this version of Wax cannot change"):format(where,
                kind == "text" and "text" or "a reference to an asset"), 0)
        end
        return base
    end
    if base == nil or not same_leaf(kind, kept, base) then context.needs[SWITCH[kind]] = true end
    return kept
end

local check_struct

-- True when a struct value holds a list that is not empty, at any depth.
local function holds_list(plan, value)
    if type(value) ~= "table" then return false end
    for _, field in ipairs(plan.list) do
        local inner = value[field.Name]
        if field.how == "array" then
            if type(inner) == "table" and #inner > 0 then return true end
        elseif field.how == "struct" and holds_list(T.plan_of(field.Struct), inner) then
            return true
        end
    end
    return false
end

-- `inside` is true for a list that is not a field of the row itself.
local function check_list(desc, value, base, where, made, context, inside)
    if type(value) ~= "table" then wrong(where, "is a list", value) end
    local count = #value
    for key in pairs(value) do
        if math.type(key) ~= "integer" or key < 1 or key > count then
            error(("%s is a list, which has no place for the key %s"):format(where, shown(key)), 0)
        end
    end
    local have = type(base) == "table" and #base or 0
    local rebuilt = made or count ~= have
    local by_struct = desc.item == "struct"
    local plan = by_struct and T.plan_of(desc.Struct) or nil
    if rebuilt and (count > 0 or have > 0) then
        local can = by_struct and buildable(desc.Struct) or (not by_struct and ZEROED[desc.Inner] == true)
        if not can then
            if made then
                error(("%s cannot get entries here: Wax cannot make entries of this kind yet"):format(where), 0)
            end
            error(("%s has %d %s and would get %d. Wax cannot make or remove entries of this kind yet, only change the ones that are there")
                :format(where, have, have == 1 and "entry" or "entries", count), 0)
        end
        local needs = context.needs
        needs.lists = true
        if count > M.ROOM or have > M.ROOM then needs.long_lists = true end
        if inside then
            needs.nested_lists = true
        elseif (plan and owns(desc.Struct)) or (not by_struct and desc.Inner == "Str") then
            needs.owning_lists = true
        end
        -- the entries that go would have to give back the lists they hold
        for index = 1, plan and have or 0 do
            if holds_list(plan, base[index]) then
                needs.nested_lists = true
                break
            end
        end
    end
    local out = {}
    local element = not by_struct and element_of(desc) or nil
    for index = 1, count do
        local item = value[index]
        local here = where .. "[" .. index .. "]"
        local below = nil
        if not rebuilt then below = base[index] end
        if item == nil then error(("%s has no entry %d"):format(where, index), 0) end
        if plan then
            out[index] = check_struct(plan, item, below, here, rebuilt, context)
        else
            local kept = check_leaf(element, item, below, here, context)
            if kept == nil then kept = false end
            out[index] = kept
        end
    end
    return out
end

-- Keys spelled in another letter case are taken as the field they mean. A key that is no field at all is an error.
local function refold(plan, value, where)
    local out = {}
    for key, item in pairs(value) do
        local field = type(key) == "string" and (plan.by[key] or plan.fold[lower(key)]) or nil
        if not field then
            local names = {}
            for index = 1, #plan.list do names[index] = plan.list[index].Name end
            error(("%s has no field named %s.%s"):format(where, shown(key), type(key) == "string" and suggest.phrase(key, names) or ""), 0)
        end
        if out[field.Name] ~= nil then error(("%s names %s twice"):format(where, field.Name), 0) end
        out[field.Name] = item
    end
    return out
end

-- `made` is true for a struct that will be a new, zeroed entry: it has nothing of its own to keep.
function check_struct(plan, value, base, where, made, context)
    if type(value) ~= "table" then wrong(where, "is a table of fields", value) end
    local fields, keys, matched = plan.list, 0, 0
    for _ in pairs(value) do keys = keys + 1 end
    for index = 1, #fields do
        if value[fields[index].Name] ~= nil then matched = matched + 1 end
    end
    if matched ~= keys then value = refold(plan, value, where) end
    local family = family_of(plan)
    local out = {}
    if type(base) ~= "table" then base = nil end
    -- a handle's table: its own when it is left out, and always spelled as the game lists it
    local table_name = nil
    if family == "handle" then
        local held = base and base.DataTableName
        table_name = value.DataTableName
        if table_name == nil then
            local target = target_of(plan, family)
            table_name = target and select(4, T.rows(target)) or held
        end
        local row_name = value.RowName
        if type(table_name) == "string" and type(row_name) == "string" then
            table_name = check_table(plan, table_name, row_name == "" and "None" or row_name, held, where, context)
            -- the handle keeps a pointer to the table it was first resolved with, and that pointer is not written
            if type(held) == "string" and lower(held) ~= "none" and lower(held) ~= lower(table_name) then
                context.needs.handle_tables = true
            end
        end
    end
    for index = 1, #fields do
        local field = fields[index]
        local name, how = field.Name, field.how
        local given = value[name]
        local here = where .. "." .. name
        if not how then
            if given ~= nil then refuse_kind(here, field) end
        elseif how == "struct" then
            if given == nil then lacks(where, name) end
            out[name] = check_struct(T.plan_of(field.Struct), given, base and base[name], here, made, context)
        elseif how == "array" then
            if given == nil then lacks(where, name) end
            out[name] = check_list(field, given, base and base[name], here, made, context, true)
        else
            local kind = leaf_kind(field)
            if table_name ~= nil and name == "DataTableName" then given = table_name end
            if given == nil and kind ~= "text" and kind ~= "soft" then lacks(where, name, field) end
            out[name] = check_leaf(field, given, base and base[name], here, context)
        end
    end
    if family == "handle" and type(out.RowName) == "string" and type(out.DataTableName) == "string" then
        out.RowName = check_row(out.DataTableName, out.RowName, where, "RowName", context)
    elseif family == "enum" and type(out.Value) == "string" then
        local target = target_of(plan, family)
        if target and T.rows(target) then out.Value = check_row(target, out.Value, where, "Value", context, true) end
    end
    return out
end

local OFF_TEXT = {
    plain = "%s: changing numbers, switches and strings is switched off in this version of Wax",
    names = "%s: changing names and row handles is switched off in this version of Wax",
    handle_tables = "%s: pointing a row handle at another table than it names now is switched off in this version of Wax",
    lists = "%s: making a list longer or shorter is switched off in this version of Wax. Its entries can be changed where they are",
    long_lists = "%s: making a list longer or shorter while it has more than %d entries, before or after, is switched off in this version of Wax",
    owning_lists = "%s: making a list longer or shorter whose entries are strings, or can hold strings or lists of their own, "
        .. "is switched off in this version of Wax",
    nested_lists = "%s: making a list longer or shorter inside another value, or while its entries hold lists of their own, "
        .. "is switched off in this version of Wax",
}
local OFF_ORDER = { "plain", "names", "handle_tables", "lists", "long_lists", "owning_lists", "nested_lists" }

-- Checks a whole new value of one field. Returns it complete, with the game's spelling of field and row names.
local function check(field, value, current, original, where)
    stats.checks = stats.checks + 1
    local context = { needs = {}, field = field, current = current, original = original }
    local out
    if field.how == "struct" then
        out = check_struct(T.plan_of(field.Struct), value, current, where, false, context)
    elseif field.how == "array" then
        out = check_list(field, value, current, where, false, context, false)
    else
        out = check_leaf(field, value, current, where, context)
    end
    for _, kind in ipairs(OFF_ORDER) do
        if context.needs[kind] and not M.WRITES[kind] then error(OFF_TEXT[kind]:format(where, M.ROOM), 0) end
    end
    return out
end

-- Why a field cannot be changed at all, or nothing.
local function closed(field)
    local how = field.how
    if not how then return ("%s is %s, which this version of Wax cannot change"):format(field.Name, T.describe(field)) end
    local kind = nil
    if how == "array" then
        if field.item ~= "struct" then kind = leaf_kind(element_of(field)) end
    elseif how ~= "struct" then
        kind = leaf_kind(field)
    end
    if kind == "text" then return field.Name .. " is text, which this version of Wax cannot change" end
    if kind == "soft" then return field.Name .. " is a reference to an asset, which this version of Wax cannot change" end
    return nil
end

-- The writes. Everything is found again from the row for each one, and nothing is kept across a list that moves.

local function put(kind, holder, key, value)
    stats.writes = stats.writes + 1
    if kind == "name" then holder[key] = FName(value) else holder[key] = value end
end

local write_struct, write_list

-- Gives back what an entry owns before its list is emptied, because Empty() frees the list without it. `was` is what the entry holds.
local function clear_struct(plan, target, was)
    for _, field in ipairs(plan.list) do
        local name, kind = field.Name, field.Kind
        local held = was and was[name]
        if kind == "Str" then
            if held ~= "" then put("string", target, name, "") end
        elseif kind == "Struct" and field.Struct and owns(field.Struct) then
            clear_struct(T.plan_of(field.Struct), target[name], held)
        elseif kind == "Array" and (type(held) ~= "table" or #held > 0) then
            local list = target[name]
            local count = list:GetArrayNum()
            if count > 0 then
                if field.item == "struct" then
                    if owns(field.Struct) then
                        local inner = T.plan_of(field.Struct)
                        for index = 1, count do clear_struct(inner, list[index], type(held) == "table" and held[index] or nil) end
                    end
                elseif field.Inner == "Str" then
                    for index = 1, count do put("string", list, index, "") end
                end
                stats.writes = stats.writes + 1
                list:Empty()
            end
        end
    end
end

function write_struct(plan, target, wanted, current)
    local fields = plan.list
    for index = 1, #fields do
        local field = fields[index]
        local how, name = field.how, field.Name
        if how and (current == nil or not same(field, wanted[name], current[name])) then
            if how == "struct" then
                write_struct(T.plan_of(field.Struct), target[name], wanted[name], current and current[name])
            elseif how == "array" then
                write_list(field, target[name], wanted[name], current and current[name])
            else
                local kind = leaf_kind(field)
                if SWITCH[kind] then put(kind, target, name, wanted[name]) end
            end
        end
    end
end

-- A new entry as UE4SS takes it in one assignment: its values and structs as a table, names as FNames, and no lists.
local function entry_table(plan, wanted)
    local out = {}
    for _, field in ipairs(plan.list) do
        local how, name = field.how, field.Name
        if how == "struct" then
            out[name] = entry_table(T.plan_of(field.Struct), wanted[name])
        elseif how and how ~= "array" then
            local kind = leaf_kind(field)
            if kind == "name" then out[name] = FName(wanted[name]) elseif SWITCH[kind] then out[name] = wanted[name] end
        end
    end
    return out
end

-- The lists inside a new entry: each starts empty and gets its entries one after the other.
local function fill_lists(plan, target, wanted)
    for _, field in ipairs(plan.list) do
        local how, name = field.how, field.Name
        if how == "array" then
            if #wanted[name] > 0 then write_list(field, target[name], wanted[name], nil) end
        elseif how == "struct" and owns(field.Struct) then
            fill_lists(T.plan_of(field.Struct), target[name], wanted[name])
        end
    end
end

function write_list(desc, target, wanted, current)
    local have, count = target:GetArrayNum(), #wanted
    local by_struct = desc.item == "struct"
    local plan = by_struct and T.plan_of(desc.Struct) or nil
    local kind = not by_struct and leaf_kind(element_of(desc)) or nil
    if have == count and (current == nil or #current == count) then
        for index = 1, count do
            local was = current and current[index]
            if plan then
                if was == nil or not same_struct(plan, wanted[index], was) then write_struct(plan, target[index], wanted[index], was) end
            elseif SWITCH[kind] and (was == nil or not same_leaf(kind, wanted[index], was)) then
                put(kind, target, index, wanted[index])
            end
        end
        return
    end
    local can = by_struct and buildable(desc.Struct) or (not by_struct and ZEROED[desc.Inner] == true)
    if not can then error(("the game holds %d entries of %s where Wax expected %d"):format(have, desc.Name, count), 0) end
    if have > 0 then
        local known = current and #current == have
        if plan then
            if owns(desc.Struct) then
                for index = 1, have do clear_struct(plan, target[index], known and current[index] or nil) end
            end
        elseif kind == "string" then
            for index = 1, have do
                if not known or current[index] ~= "" then put("string", target, index, "") end
            end
        end
        stats.writes = stats.writes + 1
        target:Empty()
    end
    -- one entry after the other from 1: on an empty list UE4SS adds a single entry whatever the index
    for index = 1, count do
        if plan then
            stats.writes = stats.writes + 1
            target[index] = entry_table(plan, wanted[index])
            if owns(desc.Struct) then fill_lists(plan, target[index], wanted[index]) end
        else
            put(kind, target, index, wanted[index])
        end
    end
end

local function write_field(field, row, wanted, current)
    local how, name = field.how, field.Name
    if how == "struct" then
        write_struct(T.plan_of(field.Struct), row[name], wanted, current)
    elseif how == "array" then
        write_list(field, row[name], wanted, current)
    else
        put(leaf_kind(field), row, name, wanted)
    end
end

-- The row of a table by the name the game listed, or an error.
local function row_of(record, object, real)
    local row = object:FindRow(real)
    if row == nil then error(("the game no longer has the row %s of %s"):format(real, record.name), 0) end
    return row
end

-- Writes `wanted` into one field and reads it back. Returns what the game holds, or puts the old value back and raises with what differed.
local function commit(entry, record, object, field, wanted, current)
    local real = entry.info.row
    local wrote, problem = pcall(function() write_field(field, row_of(record, object, real), wanted, current) end)
    local read, now = pcall(function() return read_of(field, row_of(record, object, real)) end)
    if wrote and read and same(field, wanted, now) then return now end
    local why = not wrote and first_line(problem) or (read and difference(field, wanted, now, field.Name) or first_line(now))
    stats.put_back = stats.put_back + 1
    local restored = pcall(function() write_field(field, row_of(record, object, real), current, read and now or nil) end)
    local again, back = pcall(function() return read_of(field, row_of(record, object, real)) end)
    local where = ("%s.%s.%s"):format(record.name, real, field.Name)
    if restored and again and same(field, current, back) then
        entry.applied = back
        error(("the game did not take the change of %s: %s. The old value was put back"):format(where, tostring(why)), 0)
    end
    entry.applied = again and back or nil
    log:error("%s could not be put back after a change the game did not take (%s)", where, tostring(why))
    error(("the game did not take the change of %s: %s. The old value could not be put back"):format(where, tostring(why)), 0)
end

-- Owners, order and the end of the frame.

-- The ids of the mods in the order they load, lowest first: from loader.ids once the loader has it, else from its list, which costs more.
function M.order()
    local out, mods = {}, Wax.mods
    if mods and mods.ids then return mods.ids() end
    if mods and mods.list then
        for index, mod in ipairs(mods.list()) do out[index] = mod.id end
    end
    return out
end

-- True while the loader has this mod running. Replaced in tests.
function M.loaded(name)
    local mods = Wax.mods
    if not mods then return false end
    if mods.get then
        local mod = mods.get(name)
        return mod ~= nil and mod.status == "loaded"
    end
    if mods.list then
        for _, mod in ipairs(mods.list()) do
            if mod.id == name then return mod.status == "loaded" end
        end
    end
    return false
end

-- True when this player is in a game that someone else hosts. Replaced in tests.
function M.is_client()
    local game = Wax.import("engine.game").root
    return game.World ~= nil and not game.IsHost
end

local flush

-- Makes sure the changes are looked at when this frame ends.
local function schedule()
    if flush_thread and co.status(flush_thread) ~= "dead" then
        if flush_begun then return end
        if sched.stats.frame == flush_frame then
            -- it may still be due, or the scheduler dropped it with a chain of deferred tasks it cut: the next frame tells
            if not (flush_watch and flush_watch.Connected) then
                local previous = scope.enter(nil)
                flush_watch = sched.Frame:Once(function()
                    if flush_thread and not flush_begun then schedule() end
                end)
                scope.leave(previous)
            end
            return
        end
        -- deferred in an earlier frame and never begun, so it was dropped. Stopping it is harmless if it was still due
        task.cancel(flush_thread)
    end
    local previous = scope.enter(nil)
    flush_thread, flush_frame, flush_begun = task.defer(flush), sched.stats.frame, false
    scope.leave(previous)
end

local function rank_of(owner)
    if owner == RETIRED then return math.huge end
    local frame = sched.stats.frame
    if not standing.ranks or standing.frame ~= frame then
        local ranks, parts = {}, {}
        standing.ranks, standing.frame = ranks, frame
        local ok, list = pcall(M.order)
        if ok and type(list) == "table" then
            for index, id in ipairs(list) do
                ranks[id] = index
                parts[index] = tostring(id)
            end
        end
        local signature = table.concat(parts, "\0")
        if standing.signature ~= signature then
            -- the mods stand in another order: every field follows, and is written again where that changes its value
            standing.signature = signature
            local any = false
            for _, entry in ipairs(journal.entries()) do
                if journal.rank(entry, rank_of) then
                    entry.moved, any = true, true
                    leaving[#leaving + 1] = entry.key
                end
            end
            if any then schedule() end
        end
    end
    return standing.ranks[owner] or 1e9
end

-- For the loader, when the player moves a mod in the list: fields that two mods changed follow in this frame.
function M.reordered()
    standing.frame = nil
    rank_of("")
end

-- True for a mod that unloaded a moment ago and is running again: what it changed waits for it to say so again.
local function held(owner)
    local since = left_at[owner]
    if not since then return false end
    if M.grace <= 0 or M.clock() - since >= M.grace then
        left_at[owner] = nil
        return false
    end
    local frame = sched.stats.frame
    if running.frame ~= frame then running.now, running.frame = {}, frame end
    local known = running.now[owner]
    if known == nil then
        local ok, answer = pcall(M.loaded, owner)
        known = ok and answer == true
        running.now[owner] = known
    end
    return known
end

-- Looks again at what waits for a mod that is loading again, once its time is up.
local function hold()
    if timers.hold then return end
    local previous = scope.enter(nil)
    -- a little longer than the time itself, so the look never comes a moment early
    timers.hold = task.delay(math.max(M.grace, 0) + 0.05, function()
        timers.hold = nil
        local keys = parked
        parked = {}
        for index = 1, #keys do leaving[#leaving + 1] = keys[index] end
        if rows_wait then rows_wait, rows_due = false, true end
        schedule()
    end)
    scope.leave(previous)
end

-- Called through the scope of a mod when it unloads: what it changed is on its way out.
function M.release(name, owner)
    if owners[name] == owner then owners[name] = nil end
    left_at[name] = M.clock()
    local keys, rows = journal.leave(name)
    for index = 1, #keys do leaving[#leaving + 1] = keys[index] end
    if #rows > 0 then rows_due = true end
    if #keys > 0 or #rows > 0 then schedule() end
end

-- The mod whose code is running. Its scope puts everything back when the mod unloads.
local function owner_of()
    local owner = scope.current()
    if not owner or not owner.alive then
        error("a change of the game's tables belongs to a mod, which puts it back when it unloads. This code runs outside any mod", 0)
    end
    local name = owner.name
    if not watched[owner] then
        watched[owner] = true
        owner:add(function()
            local live = Wax.modules["data.patch"]
            if type(live) ~= "table" or not live.release then live = M end
            live.release(name, owner)
        end)
    end
    owners[name] = owner
    return name
end

local function touched(group, table_name, row, field, owner)
    journal.bump(group)
    local id = table_name .. "\0" .. row .. "\0" .. (field or "")
    if not dirty.by[id] then
        dirty.by[id] = true
        dirty.list[#dirty.list + 1] = { table = table_name, row = row, field = field }
    end
    dirty.tables[table_name] = true
    if owner and owner ~= RETIRED then
        local made = fresh[owner]
        if not made then
            made = { fields = 0, rows = {}, tables = {}, by = {} }
            fresh[owner] = made
        end
        if not made.by[id] then
            made.by[id] = true
            made.fields = made.fields + 1
            made.rows[table_name .. "\0" .. row] = true
            made.tables[table_name] = true
        end
    end
    schedule()
end

local function joined()
    if at_title then return false end
    local ok, answer = pcall(M.is_client)
    return ok and answer == true
end

-- In a game someone else hosts, the player hears once for each mod that its table changes are only on this PC.
local function tell(names)
    for _, name in ipairs(names) do
        if owners[name] and not told[name] then
            told[name] = true
            local text = ("%s changes the game's tables on this PC. In this game the host decides what really happens."):format(name)
            log:warn("%s", text)
            local ui = rawget(Wax, "ui")
            if ui and ui.Notify then pcall(ui.Notify, text, { title = "Mods", kind = "warn", seconds = 8 }) end
        end
    end
end

local function say()
    timers.summary = nil
    if M.clock() < summary_at then
        local previous = scope.enter(nil)
        timers.summary = task.delay(summary_at - M.clock(), say)
        scope.leave(previous)
        return
    end
    local batch = fresh
    fresh = {}
    local names = {}
    for owner in pairs(batch) do names[#names + 1] = owner end
    table.sort(names)
    for _, owner in ipairs(names) do
        local made = batch[owner]
        local rows, where, count = 0, nil, 0
        for _ in pairs(made.rows) do rows = rows + 1 end
        for name in pairs(made.tables) do where, count = name, count + 1 end
        log:info("%s changed %d %s of %d %s in %s", owner, made.fields, made.fields == 1 and "field" or "fields", rows,
            rows == 1 and "row" or "rows", count == 1 and where or (count .. " tables"))
    end
    if #names > 0 and joined() then tell(names) end
end

-- Tells whoever listens what changed in this frame: Patched for each field, then Changed once for each table.
local function announce()
    announced_at = M.clock()
    if #dirty.list == 0 and next(dirty.tables) == nil then return end
    local batch = dirty
    dirty = { list = {}, by = {}, tables = {} }
    for index = 1, #batch.list do
        local item = batch.list[index]
        T.Patched:Fire(item.table, item.row, item.field)
    end
    local names = {}
    for name in pairs(batch.tables) do names[#names + 1] = name end
    table.sort(names)
    for index = 1, #names do T.changed(names[index]) end
    if next(fresh) then
        summary_at = M.clock() + M.summary_seconds
        if not timers.summary then
            local previous = scope.enter(nil)
            timers.summary = task.delay(M.summary_seconds, say)
            scope.leave(previous)
        end
    end
end

-- Remembers which table changes were written to. True when the game has made that table again since.
local function made_again(record)
    local known = seen[record.key]
    if not known then
        seen[record.key] = { name = record.name, address = record.address }
        return false
    end
    if known.address == record.address then return false end
    known.address = record.address
    for _, entry in ipairs(journal.entries(record.key)) do
        entry.applied = nil
        leaving[#leaving + 1] = entry.key
    end
    for _, row in ipairs(journal.rows(record.key)) do row.check = true end
    rows_check = true
    schedule()
    return true
end

-- True when a value of this field holds text or a reference to an asset somewhere. Those are never written.
local function has_fixed(desc, trail)
    local how = desc.how
    if not how then return false end
    if how ~= "struct" and not (how == "array" and desc.item == "struct") then
        return SWITCH[leaf_kind(how == "array" and element_of(desc) or desc)] == nil
    end
    local path = desc.Struct
    local known = fixed[path]
    if known ~= nil then return known end
    trail = trail or {}
    if trail[path] then return false end
    trail[path] = true
    local answer = false
    for _, field in ipairs(T.plan_of(path).list) do
        if has_fixed(field, trail) then
            answer = true
            break
        end
    end
    trail[path] = nil
    -- a no that was worked out inside a struct that holds itself may be short, so only the outermost one is kept
    if answer or next(trail) == nil then fixed[path] = answer end
    return answer
end

-- Gives a value the text and the references to assets that the game holds now, in place: a text reads in the language shown.
local function follow(desc, value, from)
    local how = desc.how
    if how == "struct" then
        if type(value) ~= "table" or type(from) ~= "table" then return value end
        local fields = T.plan_of(desc.Struct).list
        for index = 1, #fields do
            local field = fields[index]
            if field.how then value[field.Name] = follow(field, value[field.Name], from[field.Name]) end
        end
        return value
    end
    if how == "array" then
        if type(value) ~= "table" or type(from) ~= "table" or #value ~= #from then return value end
        local element = desc.item == "struct" and entry_of(desc) or element_of(desc)
        for index = 1, #value do value[index] = follow(element, value[index], from[index]) end
        return value
    end
    if SWITCH[leaf_kind(desc)] then return value end
    return from
end

local WAITED = "the function given to Change must not wait. It gets the value and returns the new one at once"

-- Runs a mod's function where it cannot pause: Lua refuses a wait below string.gsub, with an error the function gets.
local function call_now(fn, value)
    local ok, made
    string.gsub("x", "x", function() ok, made = xpcall(fn, guard.handler, value) end)
    return ok, made
end

-- The value the layers give for one field. `strict` is the step whose error goes to the caller. Others are logged and skipped.
local function compute(entry, field, current, strict)
    local layers = entry.layers
    local moves = has_fixed(field)
    if #layers == 1 and #layers[1].steps == 1 and layers[1].steps[1].set ~= nil then
        local set = layers[1].steps[1].set
        if moves then set = follow(field, set, current) end
        return set, nil
    end
    local function taken(value)
        local made = copy(value)
        if moves then made = follow(field, made, current) end
        return made
    end
    local function run(layer, step, value)
        local given = copy(value)
        local previous = scope.enter(owners[layer.owner])
        local ok, made = call_now(step.change, given)
        scope.leave(previous)
        local problem
        if not ok then
            local text = first_line(made)
            if text:find("can only be used inside a task", 1, true) or text:find("attempt to yield", 1, true) then
                problem = WAITED
            else
                problem = "the function given to Change raised: " .. text
            end
        else
            -- a function may change the list or struct it was handed and return nothing
            if made == nil and type(given) == "table" then made = given end
            if made == nil then
                problem = "the function given to Change returned nothing. It returns the new value"
            else
                local fine, checked = pcall(check, field, made, current, entry.original, field.Name)
                if fine then
                    step.broken = nil
                    return checked
                end
                problem = tostring(checked)
            end
        end
        if step == strict then error(problem, 0) end
        if step.broken ~= problem then
            step.broken = problem
            log:error("%s's change of %s.%s.%s no longer works and is left out: %s", layer.owner, entry.info.table, entry.info.row,
                entry.info.field, problem)
        end
        return nil
    end
    return journal.result(entry, taken, run, function(a, b) return same(field, a, b) end)
end

local function note_conflict(entry, conflict)
    entry.conflict = conflict
    if not conflict then return end
    local info = entry.info
    for _, covered in ipairs(conflict.covered) do
        if journal.first(entry.key .. "\0" .. covered .. "\0" .. conflict.used) then
            log:warn("%s and %s both change %s.%s.%s. %s's value is used", covered, conflict.used, info.table, info.row, info.field,
                conflict.used)
        end
    end
end

-- A field holds what its layers give, so nothing is owed for it any more.
local function settled(entry)
    if entry.tries then
        local info = entry.info
        log:info("%s.%s.%s holds what it should again", info.table, info.row, info.field)
    end
    if entry.owed then stuck[entry.key] = nil end
    entry.owed, entry.tries, entry.left = nil, nil, nil
end

-- Makes the table hold what the layers of one field give. True when the game was written to. A write that leaves the game torn sets `torn`.
local function apply(entry, record, object, field, strict)
    local current = entry.applied
    if current == nil then
        current = read_of(field, row_of(record, object, entry.info.row))
        entry.applied = current
    end
    local wanted, conflict = compute(entry, field, current, strict)
    note_conflict(entry, conflict)
    if same(field, wanted, current) then
        settled(entry)
        return false
    end
    local ok, now = pcall(commit, entry, record, object, field, wanted, current)
    if not ok then
        if entry.applied == nil or not same(field, entry.applied, current) then
            torn = true
            entry.applied, entry.owed = nil, true
            T.forget(record, entry.info.row)
            touched(record.key, record.name, entry.info.row, field.Name, nil)
        end
        error(now, 0)
    end
    entry.applied = now
    settled(entry)
    T.forget(record, entry.info.row)
    return true
end

-- After a change that failed and left the game holding something else: the field is put right when the frame ends.
local function mend(entry)
    if journal.find(entry.key) ~= entry then return end
    leaving[#leaving + 1] = entry.key
    schedule()
end

-- A table of the game by the name it was changed under: its record, the game's object and the row struct's plan.
local function open_table(name)
    local record, object = T.live(T.named(name))
    return record, object, T.plan_of(record.struct)
end

-- Keys whose put-back is still owed go back in the queue, to be read from the game again. `all` takes those that were given up on too.
local function requeue(all)
    local keys = {}
    for key in pairs(stuck) do keys[#keys + 1] = key end
    table.sort(keys)
    local any = false
    for _, key in ipairs(keys) do
        local entry = journal.find(key)
        if not entry or not entry.owed then
            stuck[key] = nil
        elseif all or M.retry_seconds[entry.tries or 0] then
            entry.applied = nil
            leaving[#leaving + 1] = key
            any = true
        end
    end
    if any then schedule() end
end

-- A put-back that failed stays owed. It is tried again a few times, further apart each time, and on every new map.
local function put_off(key, why)
    local entry = journal.find(key)
    local reason = (first_line(why):gsub("%. The old value was put back$", ""))
    if not entry then
        log:error("a change could not be put back: %s", reason)
        return
    end
    entry.owed = true
    entry.tries = (entry.tries or 0) + 1
    stuck[key] = true
    local info = entry.info
    local where = ("%s.%s.%s"):format(info.table, info.row, info.field)
    local wait = M.retry_seconds[entry.tries]
    if not wait then
        if entry.tries == #M.retry_seconds + 1 then
            trouble.over = trouble.over + 1
            if trouble.over == 1 then trouble.over_where, trouble.over_by, trouble.over_why = where, entry.left or "a mod", reason end
        end
        return
    end
    if entry.tries == 1 then
        trouble.again = trouble.again + 1
        if trouble.again == 1 then trouble.again_where, trouble.again_why = where, reason end
    end
    local due = M.clock() + wait
    if timers.retry and timers.retry_due <= due then return end
    if timers.retry then task.cancel(timers.retry) end
    local previous = scope.enter(nil)
    timers.retry = task.delay(wait, function()
        timers.retry = nil
        requeue(false)
    end)
    scope.leave(previous)
    timers.retry_due = due
end

-- One key that may have layers to drop: they go, and the table gets what the rest gives. True when a layer waits for a mod that is loading again.
local function settle_key(key)
    local entry = journal.find(key)
    if not entry then return false end
    local waits = false
    for _, layer in ipairs(entry.layers) do
        if layer.leaving then
            if held(layer.owner) then waits = true elseif not layer.quiet then entry.left = layer.owner end
        end
    end
    local dropped = journal.drop_leaving(entry, waits and held or nil)
    local moved = entry.moved
    entry.moved = nil
    if dropped == 0 and entry.applied ~= nil and not moved and not entry.owed then return waits end
    stats.settled = stats.settled + 1
    -- until the write is read back, the game may hold what a mod that is gone put there
    entry.owed = true
    local info = entry.info
    local record, object, plan = open_table(info.table)
    made_again(record)
    local field = plan.by[info.field]
    if not field or not record.index[lower(info.row)] then
        log:warn("%s.%s.%s is not in the game any more, so what mods changed there is forgotten", info.table, info.row, info.field)
        stuck[key] = nil
        journal.close(entry)
        return false
    end
    local changed = apply(entry, record, object, field, nil)
    if #entry.layers == 0 then journal.close(entry) end
    if changed then touched(record.key, record.name, info.row, info.field, nil) end
    return waits
end

-- Rows that mods add.

local function library_for(record, object)
    if not library_paths then
        local chunk = loadfile(Wax.root .. "/data/libraries.lua")
        local ok, list = pcall(chunk or error)
        library_paths = ok and type(list) == "table" and list or {}
    end
    local class = tostring(object:GetFullName()):match("^(%S+)%s")
    local path = class and library_paths[(class:gsub("Table$", "Library"))]
    if not path then
        error(("Wax does not know the game's own index of %s, so rows cannot be added to it"):format(record.name), 0)
    end
    local library = StaticFindObject(path)
    if not library:IsValid() then
        error(("the game's own index of %s cannot be found right now, so rows cannot be added to it"):format(record.name), 0)
    end
    return library
end

-- Tells the game's own index of a table to look at its rows again.
local function refresh(record, object, row)
    local ok, problem = pcall(function() library_for(record, object):RefreshConstants() end)
    if row then row.indexed = ok end
    if not ok then error(("%s: the game's own index of the table could not be renewed (%s)"):format(record.name, first_line(problem)), 0) end
end

-- Puts a copy of one row into the table under a new name, with a copy of its meta row.
local function clone(record, object, name, like)
    local size = #object
    stats.writes = stats.writes + 1
    object:AddRow(name, row_of(record, object, like))
    if #object ~= size + 1 or object:FindRow(name) == nil then
        error(("the game did not take the new row %s of %s"):format(name, record.name), 0)
    end
    T.row_added(record, name, object)
    local meta = object.MetaTable
    if meta:IsValid() and meta:type() == "UDataTable" then
        local source = meta:FindRow(like)
        if source ~= nil then
            meta:AddRow(name, source)
            local kept = T.meta(record)
            if kept then T.row_added(kept, name, meta) end
        end
    end
end

local function row_key(record, name) return record.key .. "\0" .. lower(name) end

-- Switches a row off in the way its table allows. The layers that do it belong to no mod and sit on top.
local function off_fields(record)
    local names = {}
    for name in pairs(M.OFF[record.key] or {}) do names[#names + 1] = name end
    table.sort(names)
    return names, M.OFF[record.key]
end

local function retire(row)
    row.leaving, row.retired = false, true
    local record, object, plan = open_table(row.table)
    local names, values = off_fields(record)
    for _, name in ipairs(names) do
        local field = plan.by[name] or plan.fold[lower(name)]
        local ok, problem = pcall(function()
            if not field then error("the table has no such field", 0) end
            local key = row_key(record, row.row) .. "\0" .. field.Name
            local entry = journal.find(key)
            local current = entry and entry.applied or read_of(field, row_of(record, object, row.row))
            local wanted = check(field, values[name], current, entry and entry.original or current, field.Name)
            local made = not entry
            if made then
                entry = journal.open(key, record.key, { table = record.name, row = row.row, field = field.Name }, copy(current))
                entry.applied = current
            end
            local token = journal.push(entry, RETIRED, { set = wanted }, rank_of)
            token.layer.quiet = true
            torn = false
            local fine, changed = pcall(apply, entry, record, object, field, nil)
            if not fine then
                journal.restore(token)
                if torn then mend(entry) elseif made then journal.close(entry) end
                error(changed, 0)
            end
            if changed then touched(record.key, record.name, row.row, field.Name, nil) end
        end)
        if not ok then
            log:warn("%s.%s could not be switched off through %s: %s", row.table, row.row, name, first_line(problem))
        end
    end
    touched(record.key, record.name, row.row, nil, nil)
end

-- Takes the layers that switched a row off away again, because its mod is back. An error leaves the row switched off.
local function revive(row, record, object, plan)
    local problem = nil
    for _, name in ipairs((off_fields(record))) do
        local field = plan.by[name] or plan.fold[lower(name)]
        local entry = field and journal.find(row_key(record, row.row) .. "\0" .. field.Name)
        local removed, taken = false, nil
        if entry then removed, taken = journal.remove(entry, RETIRED) end
        if removed then
            torn = false
            local ok, changed = pcall(apply, entry, record, object, field, nil)
            if ok then
                if #entry.layers == 0 then journal.close(entry) end
                if changed then touched(record.key, record.name, row.row, field.Name, nil) end
            else
                journal.put_back(entry, taken)
                if torn then mend(entry) end
                problem = problem or changed
            end
        end
    end
    if problem then
        -- what was switched on already is switched off again when the frame ends
        row.leaving, rows_due = true, true
        schedule()
        error(problem, 0)
    end
    row.leaving, row.retired = false, false
    touched(record.key, record.name, row.row, nil, nil)
end

-- Forgets a row a mod added and everything changed in it, without writing anything and without asking the game.
local function forget_row(row)
    for _, entry in ipairs(journal.under(row.group, row.key .. "\0")) do
        stuck[entry.key] = nil
        journal.close(entry)
    end
    journal.remove_row(row.key)
end

-- Rows of a table the game made again are added again, before their fields are written.
local function readd_rows()
    for _, row in ipairs(journal.rows()) do
        if row.check then
            row.check = nil
            local ok, problem = pcall(function()
                local record, object = open_table(row.table)
                if record.index[lower(row.row)] then return end
                if not (M.WRITES.rows and row.like and record.index[lower(row.like)]) then error("it cannot be added again", 0) end
                clone(record, object, row.row, record.index[lower(row.like)])
                refresh(record, object, row)
                touched(record.key, record.name, row.row, nil, nil)
            end)
            if not ok then
                log:warn("the game made %s again without the row %s, and %s", row.table, row.row, first_line(problem))
                forget_row(row)
            end
        end
    end
end

-- Rows whose mod has unloaded and did not add them again are switched off. A mod that is loading again gets its time first.
local function retire_rows()
    for _, row in ipairs(journal.rows()) do
        if row.leaving then
            if held(row.owner) then
                rows_wait = true
            else
                local ok, problem = pcall(retire, row)
                if not ok then log:warn("%s.%s could not be switched off: %s", row.table, row.row, first_line(problem)) end
            end
        end
    end
end

-- At the title screen nothing uses the tables, so rows that were switched off are taken out.
local function take_out()
    if not M.WRITES.remove then return end
    for _, row in ipairs(journal.rows()) do
        if row.retired then
            local ok, problem = pcall(function()
                local record, object = open_table(row.table)
                local real = record.index[lower(row.row)]
                if real then
                    stats.writes = stats.writes + 1
                    object:RemoveRow(real)
                    local meta = object.MetaTable
                    if meta:IsValid() and meta:type() == "UDataTable" and meta:FindRow(real) ~= nil then
                        meta:RemoveRow(real)
                        local kept = T.meta(record)
                        if kept then T.row_removed(kept, real, meta) end
                    end
                    T.row_removed(record, real, object)
                    refresh(record, object, nil)
                end
                forget_row(row)
                touched(record.key, record.name, row.row, nil, nil)
                log:info("the row %s of %s, which a mod added, was taken out", row.row, row.table)
            end)
            if not ok then log:warn("%s.%s could not be taken out: %s", row.table, row.row, first_line(problem)) end
        end
    end
end

-- One line for the put-backs that failed in a round, not one for each field.
local function report()
    local found = trouble
    if found.again == 0 and found.over == 0 then return end
    trouble = { again = 0, over = 0 }
    if found.again > 0 then
        log:warn("%s could not be put back yet%s, and is tried again: %s", found.again_where,
            found.again > 1 and (" (and %d more)"):format(found.again - 1) or "", found.again_why)
    end
    if found.over > 0 then
        log:error("%s is not as it should be%s: what %s changed there could not be put back (%s). It is tried again when the map changes",
            found.over_where, found.over > 1 and (" (and %d more)"):format(found.over - 1) or "", found.over_by, found.over_why)
    end
end

function flush()
    flush_begun = true
    local ok, problem = xpcall(function()
        local rounds = 0
        announced_at = M.clock()
        while true do
            local started = M.clock()
            if rows_check then
                rows_check = false
                readd_rows()
            end
            while leaving_at <= #leaving do
                local key = leaving[leaving_at]
                leaving_at = leaving_at + 1
                local fine, waits = pcall(settle_key, key)
                if not fine then
                    put_off(key, waits)
                elseif waits then
                    parked[#parked + 1] = key
                end
                if leaving_at <= #leaving and M.clock() - started >= M.budget then
                    -- a put-back that takes many frames is heard of a few times a second, not in each of them
                    if M.clock() - announced_at >= M.announce_seconds then announce() end
                    task.wait()
                    started = M.clock()
                end
            end
            leaving, leaving_at = {}, 1
            report()
            if rows_due then
                rows_due = false
                retire_rows()
            end
            if title_due or at_title then
                title_due = false
                take_out()
            end
            if #parked > 0 or rows_wait then hold() end
            announce()
            if #leaving == 0 and not rows_due and not rows_check and not title_due and #dirty.list == 0 and next(dirty.tables) == nil then
                break
            end
            -- a handler that changes a table each time it hears of a change goes on in the next frame, not in this one
            rounds = rounds + 1
            if rounds >= 4 then
                rounds = 0
                task.wait()
            end
        end
    end, debug.traceback)
    flush_thread = nil
    if not ok then log:error("putting changes of the game's tables back failed: %s", tostring(problem)) end
end

-- What mods call, through the table objects of game.Data.

-- Everything one change of one field needs: who asks, the table, the row, the field, and what the field holds now.
local function prepare(owner, record, object, plan, row_name, field_name)
    if type(row_name) ~= "string" then error(("a row name is a string such as \"Wood\", got %s"):format(type(row_name)), 0) end
    if type(field_name) ~= "string" then error(("a field name is a string such as \"Inputs\", got %s"):format(type(field_name)), 0) end
    local real = record.index[row_name] or record.index[lower(row_name)]
    if not real then
        error(("%s has no row named '%s'.%s"):format(record.name, row_name, suggest.phrase(row_name, record.names)), 0)
    end
    local field = plan.by[field_name] or plan.fold[lower(field_name)]
    if not field then
        if field_name:find(".", 1, true) then
            error(("'%s' is a part of a field. Set and Change take a whole field of a row, such as \"%s\""):format(field_name,
                field_name:match("^[^%.]*")), 0)
        end
        local names = {}
        for index = 1, #plan.list do names[index] = plan.list[index].Name end
        error(("%s has no field named '%s'.%s"):format(plan.short, field_name, suggest.phrase(field_name, names)), 0)
    end
    if field.Name == "Name" then error("Name is the row's own name, which cannot be changed", 0) end
    local why = closed(field)
    if why then error(why, 0) end
    made_again(record)
    local key = row_key(record, real) .. "\0" .. field.Name
    local entry = journal.find(key)
    local current = entry and entry.applied
    if current == nil then
        current = read_of(field, row_of(record, object, real))
        if entry then entry.applied = current end
    end
    return { owner = owner, record = record, object = object, real = real, field = field, key = key, entry = entry,
             current = current, original = entry and entry.original or current }
end

-- Puts one step on the owner's layer and makes the table follow. An error leaves everything as it was.
local function finish(job, step)
    local record, entry, made = job.record, job.entry, false
    if not entry then
        entry = journal.open(job.key, record.key, { table = record.name, row = job.real, field = job.field.Name }, copy(job.current))
        entry.applied = job.current
        made = true
    end
    local token, why = journal.push(entry, job.owner, step, rank_of)
    if not token then
        if made then journal.close(entry) end
        error(("%s.%s.%s was changed %d times by %s without a Set or a Reset in between (%s)"):format(record.name, job.real,
            job.field.Name, journal.MAX_STEPS, job.owner, tostring(why)), 0)
    end
    torn = false
    local ok, changed = pcall(apply, entry, record, job.object, job.field, step)
    if not ok then
        journal.restore(token)
        if torn then
            -- the game holds neither what it held nor what was asked for: the field is put right when the frame ends
            entry.left = entry.left or job.owner
            mend(entry)
        elseif made then
            journal.close(entry)
        end
        error(changed, 0)
    end
    stats.sets = stats.sets + 1
    if changed then touched(record.key, record.name, job.real, job.field.Name, job.owner) end
    return changed
end

local function table_of(self)
    local record, object = T.live(self)
    if record.owner then error("a meta table cannot be changed in this version of Wax", 0) end
    return record, object, T.plan_of(record.struct)
end

-- The keys of a table of fields, sorted. Two keys that mean one field, such as Count and count, are an error.
local function field_names(plan, values)
    local names, taken = {}, {}
    for name in pairs(values) do
        if type(name) ~= "string" then error(("a field name is a string such as \"Inputs\", got %s"):format(type(name)), 0) end
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local field = plan.by[name] or plan.fold[lower(name)]
        if field then
            if taken[field.Name] then
                error(("%s is named twice, as \"%s\" and \"%s\""):format(field.Name, taken[field.Name], name), 0)
            end
            taken[field.Name] = name
        end
    end
    return names
end

-- Set(row, field, value), or Set(row, { field = value, ... }): every value is checked before anything is written.
function M.set(self, row, field, value)
    local owner = owner_of()
    local record, object, plan = table_of(self)
    if type(field) == "table" and value == nil then
        local names = field_names(plan, field)
        local jobs = {}
        for index, name in ipairs(names) do
            local job = prepare(owner, record, object, plan, row, name)
            job.wanted = check(job.field, field[name], job.current, job.original, job.field.Name)
            jobs[index] = job
        end
        for _, job in ipairs(jobs) do
            -- an earlier field of this call may have made the entry
            job.entry = job.entry or journal.find(job.key)
            finish(job, { set = job.wanted })
        end
        return
    end
    if value == nil then error("Set needs the new value. To take a change back, use Reset", 0) end
    local job = prepare(owner, record, object, plan, row, field)
    finish(job, { set = check(job.field, value, job.current, job.original, job.field.Name) })
end

-- Change(row, field, fn): fn gets a copy of the value the field has and returns the new one. It is kept and run again.
function M.change(self, row, field, fn)
    local owner = owner_of()
    local record, object, plan = table_of(self)
    if type(fn) ~= "function" then
        error(("Change takes a function that gets the value and returns the new one, got %s"):format(type(fn)), 0)
    end
    finish(prepare(owner, record, object, plan, row, field), { change = fn })
end

local ADD_OPTIONS = { "like" }

-- Add(name, values, { like = row }): a copy of a row of the table under a new name, with `values` written over it.
function M.add(self, name, values, options)
    local owner = owner_of()
    if not M.WRITES.rows then error("adding rows to the game's tables is switched off in this version of Wax", 0) end
    if joined() then
        error("a row cannot be added in a game that someone else hosts, because the host's game would not have it. "
            .. "game.IsHost says whether this player is the host", 0)
    end
    local record, object, plan = table_of(self)
    if type(name) ~= "string" then error(("a row name is a string such as \"%s_Quick_Axe\", got %s"):format(owner, type(name)), 0) end
    if values ~= nil and type(values) ~= "table" then
        error(("the values are a table such as { RequiredMillijoules = 1000 }, got %s"):format(type(values)), 0)
    end
    if options ~= nil and type(options) ~= "table" then
        error(("the options are a table such as { like = \"Stone_Axe\" }, got %s"):format(type(options)), 0)
    end
    values, options = values or {}, options or {}
    for key in pairs(options) do
        if key ~= "like" then
            error(("Add has no option named %s.%s"):format(shown(key), type(key) == "string" and suggest.phrase(key, ADD_OPTIONS) or ""), 0)
        end
    end
    local prefix = owner:gsub("[^%w_]", "_") .. "_"
    if name:find("[^%w_]") or #name > MAX_NAME then
        error(("a new row's name is letters, digits and underscores, at most %d of them, got \"%s\""):format(MAX_NAME, name), 0)
    end
    if lower(name:sub(1, #prefix)) ~= lower(prefix) or #name == #prefix then
        error(("a row that %s adds has a name that begins with \"%s\", such as \"%s%s\""):format(owner, prefix, prefix, name), 0)
    end
    local names = field_names(plan, values)
    made_again(record)
    local key = row_key(record, name)
    local row = journal.row(key)
    local real = record.index[name] or record.index[lower(name)]
    if real and not row then error(("%s already has a row named %s"):format(record.name, real), 0) end
    if row and row.owner ~= owner then error(("the row %s of %s was added by %s"):format(row.row, record.name, row.owner), 0) end
    if not real then
        local like = options.like
        if type(like) ~= "string" then
            error("Add needs a row of the table to start from, such as { like = \"Stone_Axe\" }", 0)
        end
        local source = record.index[like] or record.index[lower(like)]
        if not source then
            error(("%s has no row named '%s' to start from.%s"):format(record.name, like, suggest.phrase(like, record.names)), 0)
        end
        library_for(record, object)
        -- the new row will hold what the row it copies holds, so the values are checked against that one
        for _, field_name in ipairs(names) do
            local job = prepare(owner, record, object, plan, source, field_name)
            check(job.field, values[field_name], job.current, job.original, job.field.Name)
        end
        -- a row is only added when it can be switched off again as the row it copies stands
        local off_names, off_values = off_fields(record)
        for _, off_name in ipairs(off_names) do
            local off_field = plan.by[off_name] or plan.fold[lower(off_name)]
            if off_field then
                local now = read_of(off_field, row_of(record, object, source))
                local fine, why = pcall(check, off_field, off_values[off_name], now, now, off_field.Name)
                if not fine then
                    error(("%s cannot be the row to start from: a copy of it could not be switched off again when %s unloads (%s)")
                        :format(source, owner, first_line(why)), 0)
                end
            end
        end
        clone(record, object, name, source)
        row = journal.add_row(key, { group = record.key, table = record.name, row = name, owner = owner, like = source })
        real = name
        refresh(record, object, row)
        touched(record.key, record.name, real, nil, owner)
    else
        if row.retired or row.leaving then revive(row, record, object, plan) end
        if row.indexed == false then refresh(record, object, row) end
    end
    for _, field_name in ipairs(names) do
        local job = prepare(owner, record, object, plan, real, field_name)
        finish(job, { set = check(job.field, values[field_name], job.current, job.original, job.field.Name) })
    end
    return real
end

-- Reset(row, field): takes this mod's changes back, of a field, a row or the table, and switches a row it added off. Returns how many.
function M.reset(self, row, field)
    local owner = owner_of()
    local record, object, plan = table_of(self)
    local real, wanted = nil, nil
    if row ~= nil then
        if type(row) ~= "string" then error(("a row name is a string such as \"Wood\", got %s"):format(type(row)), 0) end
        real = record.index[row] or record.index[lower(row)]
        if not real then
            error(("%s has no row named '%s'.%s"):format(record.name, row, suggest.phrase(row, record.names)), 0)
        end
    end
    if field ~= nil then
        if type(field) ~= "string" then error(("a field name is a string such as \"Inputs\", got %s"):format(type(field)), 0) end
        if not real then error("Reset of a field needs the row it is in", 0) end
        wanted = plan.by[field] or plan.fold[lower(field)]
        if not wanted then
            local names = {}
            for index = 1, #plan.list do names[index] = plan.list[index].Name end
            error(("%s has no field named '%s'.%s"):format(plan.short, field, suggest.phrase(field, names)), 0)
        end
    end
    made_again(record)
    -- the entries are found by their keys: a walk of everything the table has changed would make a loop over rows slow
    local found
    if wanted then
        found = { journal.find(row_key(record, real) .. "\0" .. wanted.Name) }
    elseif real then
        found = {}
        local base = row_key(record, real) .. "\0"
        for index = 1, #plan.list do
            local entry = journal.find(base .. plan.list[index].Name)
            if entry then found[#found + 1] = entry end
        end
        table.sort(found, function(a, b) return a.key < b.key end)
    else
        found = journal.entries(record.key)
    end
    local count, problem = 0, nil
    for index = 1, #found do
        local entry = found[index]
        local removed, taken = journal.remove(entry, owner)
        if removed then
            local info = entry.info
            torn = false
            local ok, changed = pcall(apply, entry, record, object, plan.by[info.field], nil)
            if ok then
                count = count + 1
                if #entry.layers == 0 then journal.close(entry) end
                if changed then touched(record.key, record.name, info.row, info.field, nil) end
            else
                -- the mod's change stands as before, so Reset can be called again
                journal.put_back(entry, taken)
                if torn then mend(entry) end
                problem = problem or changed
            end
        end
    end
    if not wanted then
        local rows = real and { journal.row(row_key(record, real)) } or journal.rows(record.key)
        for _, added in ipairs(rows) do
            if added.owner == owner and not added.retired then
                count = count + 1
                retire(added)
            end
        end
    end
    if problem then error(problem, 0) end
    return count
end

local function by_place(a, b)
    if a.Table ~= b.Table then return a.Table < b.Table end
    if a.Row ~= b.Row then return a.Row < b.Row end
    return (a.Field or "") < (b.Field or "")
end

-- What mods changed, in one table or in all: { Table, Row, Field, Was, Now, By, Others, Stuck }, and { Table, Row, Added, By, Like, Off } for a row.
function M.changes(self)
    local group = self and T.record_of(self).key or nil
    local out = {}
    for _, row in ipairs(journal.rows(group)) do
        out[#out + 1] = { Table = row.table, Row = row.row, Added = true, By = row.owner, Like = row.like, Off = row.retired or nil }
    end
    for _, entry in ipairs(journal.entries(group)) do
        local by, others = nil, {}
        for _, layer in ipairs(entry.layers) do
            if not layer.quiet then
                if by then others[#others + 1] = by end
                by = layer.owner
            end
        end
        -- a field that a mod left changed because it could not be put back is still listed, under that mod
        if by or (entry.owed and entry.left) then
            local info = entry.info
            out[#out + 1] = { Table = info.table, Row = info.row, Field = info.field, Was = copy(entry.original),
                              Now = copy(entry.applied), By = by or entry.left, Others = others, Stuck = entry.owed or nil }
        end
    end
    table.sort(out, by_place)
    return out
end

-- Where a Set of one mod hides another mod's different result: { Table, Row, Field, Used, Covered }.
function M.conflicts(self)
    local group = self and T.record_of(self).key or nil
    local out = {}
    for _, entry in ipairs(journal.entries(group)) do
        local conflict = entry.conflict
        if conflict then
            local info = entry.info
            out[#out + 1] = { Table = info.table, Row = info.row, Field = info.field, Used = conflict.used,
                              Covered = copy(conflict.covered) }
        end
    end
    table.sort(out, by_place)
    return out
end

-- How often a table was changed, for its stamp.
function M.count(group) return journal.count(group) end

local function on_map(name)
    at_title = name == M.TITLE
    told = {}
    -- a put-back that failed is tried again on every new map
    requeue(true)
    if at_title then
        title_due = true
        schedule()
    elseif not timers.join then
        -- once the new game has settled: is it someone else's?
        local previous = scope.enter(nil)
        timers.join = task.delay(M.summary_seconds, function()
            timers.join = nil
            if joined() then tell(journal.owners()) end
        end)
        scope.leave(previous)
    end
end

local look_again

local function reopen(known)
    return pcall(function() return (T.live(T.named(known.name))) end)
end

-- A table that changes were written to cannot be found. It is looked for again, and counts as another table when it is back, whatever its address.
local function look_later(group, known)
    known.address = nil
    lost[group] = lost[group] or M.clock()
    if timers.lost then return end
    local previous = scope.enter(nil)
    timers.lost = task.delay(M.lost_every, look_again)
    scope.leave(previous)
end

function look_again()
    timers.lost = nil
    local waiting = false
    for group, since in pairs(lost) do
        local known = seen[group]
        local ok, record = reopen(known)
        if ok then
            lost[group] = nil
            made_again(record)
        elseif M.clock() - since >= M.lost_seconds then
            lost[group] = nil
            log:warn("the game no longer has the table %s, so what mods changed in it is not in the game", known.name)
        else
            waiting = true
        end
    end
    if waiting then
        local previous = scope.enter(nil)
        timers.lost = task.delay(M.lost_every, look_again)
        scope.leave(previous)
    end
end

-- data.tables read a table from the game. Only one that changes were written to is of interest here.
function M.opened(record)
    if not seen[record.key] then return end
    lost[record.key] = nil
    made_again(record)
end

-- data.tables says a table was read again. When it is another object, the game made it again and it holds none of the changes.
local function on_changed(name)
    for group, known in pairs(seen) do
        if name == nil or lower(name) == group then
            local ok, record = reopen(known)
            if ok then
                lost[group] = nil
                made_again(record)
            else
                look_later(group, known)
            end
        end
    end
end

function M.start()
    tables.writer = M
    local old = rawget(Wax, "patch_live")
    if old then
        for _, connection in pairs(old) do connection:Disconnect() end
    end
    local live = {}
    rawset(Wax, "patch_live", live)
    local game = Wax.import("engine.game").root
    local previous = scope.enter(nil)
    live.map = game.MapChanged:Connect(on_map)
    live.changed = tables.api.Changed:Connect(on_changed)
    scope.leave(previous)
    local known, map = pcall(function() return game.MapName end)
    at_title = known and map == M.TITLE
    -- what a core before this one wrote is still in the game's tables, and its mods are gone
    local keys, rows = journal.adopt(Wax)
    for index = 1, #keys do leaving[#leaving + 1] = keys[index] end
    if #rows > 0 then rows_due = true end
    -- the journal outlives this module too: what was waiting when the module alone was swapped is looked at again
    if #keys == 0 then
        local waiting = journal.pending()
        for index = 1, #waiting do leaving[#leaving + 1] = waiting[index] end
        for _, row in ipairs(journal.rows()) do
            if row.leaving then rows_due = true end
        end
    end
    if #leaving >= leaving_at or rows_due then schedule() end
end

function M.stats()
    local out = journal.stats()
    for name, value in pairs(stats) do out[name] = value end
    out.pending = #leaving - leaving_at + 1 + #parked
    out.stuck = 0
    for _ in pairs(stuck) do out.stuck = out.stuck + 1 end
    return out
end

return M
