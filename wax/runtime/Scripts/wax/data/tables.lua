-- game.Data: the game's data tables as plain Lua values

local Wax = ...
local suggest = Wax.import("core.suggest")
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local perf = Wax.import("core.perf")
local log = Wax.import("core.log").channel("wax.data")

local M = {}

M.clock = perf.now          -- seconds (replaced in tests)
M.min_tables = 250          -- a shorter list was taken while the game was still loading, so it is not kept
M.relist_seconds = 5        -- a name the list lacks makes it be taken again, at most this often
M.pauses = 0                -- how often a Load gave the frame back
M.epoch = 0                 -- counts up whenever rows are forgotten, so a reader can tell its copy is old
M.MAPS = true               -- a map field is read when its own path is named. Off, it is refused as before
M.CURVES = true             -- so is a field that refers to a CurveFloat, as numbers. Off, it is refused as before
M.max_entries = 4096        -- a map with more entries than this is not read
M.max_samples = 1024        -- a curve over more whole steps than this gives its keys and no values
M.max_keys = 256            -- a curve with more keys than this gives its values and no keys

local LIST_CLASS = "IcarusDataTable"
local TABLE_KIND = "UDataTable"
local DEFAULT_BUDGET = 1    -- milliseconds a frame
local MAX_DEPTH = 16
local ALL = {}              -- the key of "every readable field"

local task = sched.task
local lower, type, pcall, error = string.lower, type, pcall, error

-- How a value of each property class becomes a Lua value. A class that is not here is never read.
local READ = {
    BoolProperty = "bool", FloatProperty = "number", ByteProperty = "number", IntProperty = "number", Int8Property = "number",
    Int16Property = "number", Int64Property = "number", UInt16Property = "number", UInt32Property = "number",
    UInt64Property = "number", EnumProperty = "number", NameProperty = "text", StrProperty = "text", TextProperty = "text",
    SoftObjectProperty = "soft", SoftClassProperty = "soft",
}

local plans = {}        -- struct path -> { path, short, list, by }. Strings only, nothing of the engine's
local records = {}      -- folded table name -> what is cached of that table
local metas = {}        -- folded table name -> the record of its meta table, or false when it has none
local objects, meta_objects = {}, {}                    -- folded table name -> the table object mods hold
local infos = setmetatable({}, { __mode = "k" })        -- table object -> { key, name, meta, owner }
local seen = setmetatable({}, { __mode = "k" })         -- a field list -> { key, n, copy }
local slices = setmetatable({}, { __mode = "k" })       -- task -> when its share of the frame began
local list, recent, listed_at = nil, nil, nil           -- the kept table list, the last one taken, and when
local Changed = sched.Signal.new("Data.Changed")
local Patched = sched.Signal.new("Data.Patched")
local reading = nil     -- the field being read, for the message when a row fails
local curves = {}       -- a curve asset's full name -> its numbers, or false for an object that is no curve
local refusal = nil     -- set when a read found a field that can never be read: the caller hears it as an error
local CURVE_CLASS = "CurveFloat"
-- what UE4SS calls a reference to a live object, by the kind of wrapper it hands out
local OBJECTS = { UObject = true, AActor = true, UClass = true, UWorld = true, UDataTable = true, UEnum = true, UFunction = true,
                  UInterface = true }

M.writer = nil          -- data.patch puts itself here when it starts. Until then nothing can be changed

local function strip(full) return (full:gsub("^%S+%s+", "")) end
local function leaf_name(path) return path:match("([^%.:/]+)$") or path end
local function short_name(name) return (name:gsub("^[Dd]_", "")) end
local function short_kind(class) return (class:gsub("Property$", "")) end

local function clean(problem)
    local text = tostring(problem):match("^[^\r\n]*") or ""
    return (text:gsub("^.-%.lua:%d+: ", ""))
end

-- Wraps a function whose errors carry no position, so they point at the mod's line.
local function public(fn)
    return function(...)
        local ok, a, b, c = pcall(fn, ...)
        if not ok then error(a, 2) end
        return a, b, c
    end
end

local function describe(field)
    if field.Inner then return "an array of " .. field.Inner end
    return (field.Kind:find("^[AEIOU]") and "an " or "a ") .. field.Kind .. " field"
end

-- Hook, not built: if reflection ever stops working, a generated data/row_shapes.lua answers here instead of the engine.
local function own_fields(path)
    local struct = StaticFindObject(path)
    if not struct:IsValid() then error(("the game has no struct at %s"):format(path), 0) end
    local fields, problem = {}, nil
    struct:ForEachProperty(function(property)
        local ok, err = pcall(function()
            local class = property:GetClass():GetFName():ToString()
            local field = { Name = property:GetFName():ToString(), Kind = short_kind(class) }
            if class == "StructProperty" then
                field.how, field.Struct = "struct", strip(property:GetStruct():GetFullName())
            elseif class == "ArrayProperty" then
                local inner = property:GetInner()
                local inner_class = inner:GetClass():GetFName():ToString()
                field.Inner = short_kind(inner_class)
                if inner_class == "StructProperty" then
                    field.how, field.item, field.Struct = "array", "struct", strip(inner:GetStruct():GetFullName())
                elseif READ[inner_class] then
                    field.how, field.item, field.named = "array", READ[inner_class], inner_class == "EnumProperty"
                end
            elseif class == "MapProperty" then
                -- `reads`, not `how`: read when named, and nothing the writer goes by
                if M.MAPS then field.reads = "map" end
            elseif class == "ObjectProperty" then
                if M.CURVES then field.reads = "object" end
            else
                field.how, field.named = READ[class], class == "EnumProperty"
            end
            fields[#fields + 1] = field
        end)
        if not ok and not problem then problem = err end
    end)
    if problem then error(problem, 0) end
    local parent = struct:GetSuperStruct()
    return fields, parent:IsValid() and strip(parent:GetFullName()) or nil
end

local function build_plan(path)
    local fields, by, fold, chain, at, depth = {}, {}, {}, {}, path, 0
    while at do
        depth = depth + 1
        if depth > MAX_DEPTH then error(("the struct %s has more than %d parents"):format(path, MAX_DEPTH), 0) end
        chain[depth] = at
        local own, parent = own_fields(at)
        for i = 1, #own do
            local field = own[i]
            if not by[field.Name] then
                by[field.Name] = field
                fields[#fields + 1] = field
                field.id = at .. ":" .. field.Name
                -- the game's own files spell a few fields in another letter case than the game does
                local key = lower(field.Name)
                if not fold[key] then fold[key] = field end
            end
        end
        at = parent
    end
    return { path = path, short = leaf_name(path), list = fields, by = by, fold = fold, chain = chain }
end

-- A struct's fields with those of its parents. One that fails is not asked for again.
local function plan_of(path)
    local plan = plans[path]
    if plan then return plan end
    if plan == nil then
        local ok, built = pcall(build_plan, path)
        if ok then
            plans[path] = built
            return built
        end
        plans[path] = false
        log:warn("the struct %s could not be read from the game: %s", path, clean(built))
    end
    error(("the fields of %s cannot be read from the game"):format(leaf_name(path)), 0)
end

-- Walks a dotted path from a struct. Returns the field it ends at and the path as it is kept.
local function walk(struct, path)
    local plan, field, kept = plan_of(struct), nil, nil
    for segment in path:gmatch("[^%.]+") do
        if field then
            if not field.Struct then
                if field.reads == "map" then
                    error(("'%s' is a map, which is read whole: name it without what follows it (in '%s')"):format(kept, path), 0)
                end
                error(("'%s' is %s, so it has no fields (in '%s')"):format(kept, describe(field), path), 0)
            end
            plan = plan_of(field.Struct)
        end
        field = plan.by[segment] or plan.fold[lower(segment)]
        if not field then
            local names = {}
            for i = 1, #plan.list do names[i] = plan.list[i].Name end
            error(("%s has no field named '%s'%s.%s"):format(plan.short, segment,
                kept and (" (in '" .. path .. "')") or "", suggest.phrase(segment, names)), 0)
        end
        kept = kept and (kept .. "." .. field.Name) or field.Name
    end
    if not field then error("a field path cannot be empty", 0) end
    return field, kept
end

-- Adds every value below a struct that is read without being asked for by name. `row` is true for a row itself.
local function add_readable(struct, prefix, leaves, trail, depth, row)
    if depth > MAX_DEPTH or trail[struct] then return end
    local ok, plan = pcall(plan_of, struct)
    if not ok then return end
    trail[struct] = true
    local fields = plan.list
    for i = 1, #fields do
        local field = fields[i]
        -- in a row, Name is the row's own name. A name with a dot in it could not be told from a path
        if field.how and not field.named and not (row and field.Name == "Name") and not field.Name:find(".", 1, true) then
            if field.Struct then
                add_readable(field.Struct, prefix .. field.Name .. ".", leaves, trail, depth + 1)
            else
                leaves[prefix .. field.Name] = true
            end
        end
    end
    trail[struct] = nil
end

local function add_named(struct, path, leaves)
    if path == "Name" then return end
    local field, kept = walk(struct, path)
    if kept == "Name" then return end
    if not field.how and not field.reads then error(("'%s' is %s, which game.Data never reads"):format(kept, describe(field)), 0) end
    if field.refused then error(field.refused, 0) end
    if field.Struct then
        plan_of(field.Struct)
        add_readable(field.Struct, kept .. ".", leaves, {}, 1)
    else
        leaves[kept] = true
    end
end

-- Checks a field list and gives the key its selection is kept under.
local function key_of(fields)
    if fields == nil then return ALL end
    if type(fields) ~= "table" then
        error(("the fields are a list of paths such as { \"Inputs.Count\" }, got %s"):format(type(fields)), 0)
    end
    local known, count = seen[fields], #fields
    if known and known.n == count then
        local copy, same = known.copy, true
        for i = 1, count do
            if fields[i] ~= copy[i] then
                same = false
                break
            end
        end
        if same then return known.key end
    end
    local copy = {}
    for i = 1, count do
        local path = fields[i]
        if type(path) ~= "string" then
            error(("a field path is a string such as \"Inputs.Count\", got %s"):format(type(path)), 0)
        end
        copy[i] = path
    end
    local key = table.concat(copy, "\n")
    seen[fields] = { key = key, n = count, copy = copy }
    return key
end

-- What a field list asks for: the full paths of every single value, sorted.
local function selection_for(record, fields)
    local key = key_of(fields)
    local selection = record.selections[key]
    if selection then return selection end
    local leaves, sorted = {}, {}
    plan_of(record.struct)
    if fields == nil then
        add_readable(record.struct, "", leaves, {}, 1, true)
    else
        for i = 1, #fields do add_named(record.struct, fields[i], leaves) end
    end
    for leaf in pairs(leaves) do sorted[#sorted + 1] = leaf end
    table.sort(sorted)
    local same = table.concat(sorted, "\n")
    selection = record.by_leaves[same]
    if not selection then
        selection = { list = sorted }
        record.by_leaves[same] = selection
    end
    record.selections[key] = selection
    return selection
end

-- The reads that fetch these values, as a tree that follows the structs.
local function compile(struct, leaves)
    local root = { list = {}, by = {} }
    for i = 1, #leaves do
        local node, plan = root, plan_of(struct)
        for segment in leaves[i]:gmatch("[^%.]+") do
            local field, entry = plan.by[segment], node.by[segment]
            if not entry then
                entry = { name = segment, how = field.how or field.reads, item = field.item, field = field.reads and field or nil }
                node.by[segment] = entry
                node.list[#node.list + 1] = entry
            end
            if field.Struct then
                if not entry.sub then entry.sub = { list = {}, by = {} } end
                node, plan = entry.sub, plan_of(field.Struct)
            end
        end
    end
    return root
end

-- From what a row holds to what it holds once `selection` is read: the reads still needed, and the new state.
local function step_of(record, state, selection)
    local held, wanted, missing = state.held, selection.list, {}
    for i = 1, #wanted do
        if not held[wanted[i]] then missing[#missing + 1] = wanted[i] end
    end
    local step
    if #missing == 0 then
        step = { tree = false, to = state }
    else
        local all, sorted = {}, {}
        for leaf in pairs(held) do
            all[leaf] = true
            sorted[#sorted + 1] = leaf
        end
        for i = 1, #missing do
            all[missing[i]] = true
            sorted[#sorted + 1] = missing[i]
        end
        table.sort(sorted)
        local key = table.concat(sorted, "\n")
        local to = record.states[key]
        if not to then
            to = { held = all, steps = {} }
            record.states[key] = to
        end
        step = { tree = compile(record.struct, missing), to = to }
    end
    state.steps[selection] = step
    return step
end

local function scalar(how, value)
    if how == "number" then
        if type(value) ~= "number" then error("the game gave a " .. type(value) .. " where a number was expected", 0) end
        return value
    elseif how == "text" then
        if type(value) == "string" then return value end
        local text = value:ToString()
        if type(text) ~= "string" then error("the game gave a " .. type(text) .. " where text was expected", 0) end
        return text
    elseif how == "bool" then
        if type(value) ~= "boolean" then error("the game gave a " .. type(value) .. " where true or false was expected", 0) end
        return value
    end
    local path = value:GetObjectID():GetAssetPathName():ToString()
    if type(path) ~= "string" or path == "None" or path == "" then return nil end
    return path
end

local read_map, read_object

-- Reads the values of `node` from an engine struct into `target`, which keeps what it already holds.
local function read_struct(node, source, target)
    local entries = node.list
    for i = 1, #entries do
        local entry = entries[i]
        local name, how = entry.name, entry.how
        reading = name
        local value = source[name]
        if how == "struct" then
            local into = target[name]
            if type(into) ~= "table" then
                into = {}
                target[name] = into
            end
            read_struct(entry.sub, value, into)
        elseif how == "array" then
            -- the length first, then only places that exist: reading one past the end makes the game's array longer
            local count = value:GetArrayNum()
            if type(count) ~= "number" then error("the game gave no length for an array", 0) end
            local into = target[name]
            if type(into) ~= "table" then
                into = {}
                target[name] = into
            end
            local item, sub = entry.item, entry.sub
            for index = 1, count do
                if sub then
                    local element = into[index]
                    if type(element) ~= "table" then
                        element = {}
                        into[index] = element
                    end
                    read_struct(sub, value[index], element)
                    reading = name
                else
                    local element = scalar(item, value[index])
                    -- a list keeps its length: a reference to nothing is false there
                    if element == nil then element = false end
                    into[index] = element
                end
            end
            for index = #into, count + 1, -1 do into[index] = nil end
        elseif how == "map" then
            target[name] = read_map(entry.field, name, value)
        elseif how == "object" then
            target[name] = read_object(entry.field, value, false)
        else
            target[name] = scalar(how, value)
        end
    end
end

-- A field that turned out to hold what is never read. It is remembered, and whoever named it hears why.
local function refuse(field, text)
    field.refused = text
    refusal = text
    error(text, 0)
end

-- A curve's numbers: its value at each whole step from its first key to its last, and the keys themselves.
local function sample(object)
    local keys = object.FloatCurve.Keys
    local count = keys:GetArrayNum()
    if type(count) ~= "number" then error("the game gave no length for a curve's keys", 0) end
    local out = { First = 0, Last = -1, Values = {} }
    if count == 0 then
        out.Keys = {}
        return out
    end
    local from, to = keys[1].Time, keys[count].Time
    if type(from) ~= "number" or type(to) ~= "number" or from ~= from or to ~= to then
        error("the game gave no time for a curve's key", 0)
    end
    if count <= M.max_keys then
        local points = {}
        for index = 1, count do
            local key = keys[index]
            points[index] = { Time = key.Time, Value = key.Value }
        end
        out.Keys = points
    end
    local first, last = math.ceil(from - 1e-6), math.floor(to + 1e-6)
    out.First, out.Last = first, last
    if last - first >= M.max_samples then
        out.Values = nil
        return out
    end
    local values = out.Values
    for step = first, last do
        local value = object:GetFloatValue(step)
        if type(value) ~= "number" then error("the game gave no value for a curve", 0) end
        values[#values + 1] = value
    end
    return out
end

local function curve_copy(kept)
    local out = { First = kept.First, Last = kept.Last }
    local values, keys = kept.Values, kept.Keys
    if values then out.Values = table.move(values, 1, #values, 1, {}) end
    if keys then
        local points = {}
        for index = 1, #keys do points[index] = { Time = keys[index].Time, Value = keys[index].Value } end
        out.Keys = points
    end
    return out
end

-- A reference to a live object as plain values: the numbers of a CurveFloat. Nil for a reference to nothing.
function read_object(field, value, inside)
    if field.refused then refuse(field, field.refused) end
    if value == nil or not value:IsValid() then return nil end
    local full = value:GetFullName()
    if type(full) ~= "string" then error("the game gave no name for an object", 0) end
    local kept = curves[full]
    if kept == nil then
        kept = full:match("^(%S+)") == CURVE_CLASS and sample(value) or false
        curves[full] = kept
    end
    if not kept then
        local class = full:match("^(%S+)") or "object"
        refuse(field, (inside and "the values of '%s' are references to %s objects, which game.Data never reads. Only a CurveFloat is read, as its numbers"
            or "'%s' refers to a %s object, which game.Data never reads. Only a CurveFloat is read, as its numbers"):format(field.Name, class))
    end
    return curve_copy(kept)
end

-- The one field a struct is named by when it is the key of a map: a row handle's row, else its only value.
local function key_field(plan)
    local row = plan.by.RowName
    if row and row.how == "text" then return row end
    local only = nil
    for index = 1, #plan.list do
        local field = plan.list[index]
        if field.how then
            if only or field.named or (field.how ~= "text" and field.how ~= "number") then return nil end
            only = field
        end
    end
    return only
end

-- The reads for everything below a struct that a map holds, as for a struct that was named.
local function value_tree(path)
    local leaves, sorted = {}, {}
    add_readable(path, "", leaves, {}, 1)
    for leaf in pairs(leaves) do sorted[#sorted + 1] = leaf end
    table.sort(sorted)
    return compile(path, sorted)
end

-- What a map's keys or its values are, from the first one the game hands out. Strings only, nothing of the engine's.
local function element_of(field, value, is_key)
    local side = is_key and "keys" or "values"
    local kind = type(value)
    if kind == "number" then return { how = "number" } end
    if kind == "string" then return { how = "text" } end
    if kind == "boolean" and not is_key then return { how = "bool" } end
    if kind ~= "userdata" and kind ~= "table" then
        refuse(field, ("the %s of '%s' are %s values, which game.Data does not read from a map"):format(side, field.Name, kind))
    end
    local what = value:type()
    if type(what) ~= "string" then error("the game did not say what a map holds", 0) end
    if what == "FName" or what == "FText" or what:find("String$") then return { how = "text" } end
    if what:find("^TSoft") then return { how = "soft" } end
    if what == "UScriptStruct" then
        if not value:IsMappedToProperty() then error("the game did not say which struct a map holds", 0) end
        local path = strip(value:GetProperty():GetStruct():GetFullName())
        local plan = plan_of(path)
        if not is_key then return { how = "struct", node = value_tree(path) } end
        local pick = key_field(plan)
        if not pick then
            refuse(field, ("the keys of '%s' are %s structs, which game.Data cannot use as keys"):format(field.Name, plan.short))
        end
        return { how = "struct", pick = pick.Name, as = pick.how }
    end
    if what == "TArray" or what == "TMap" or what == "TSet" then
        refuse(field, ("the %s of '%s' are lists, maps or sets themselves, which game.Data does not read from a map"):format(side, field.Name))
    end
    if not OBJECTS[what] then
        refuse(field, ("the %s of '%s' are %s values, which game.Data does not read from a map"):format(side, field.Name, what))
    end
    if is_key then
        refuse(field, ("the keys of '%s' are references to live objects, which game.Data cannot use as keys"):format(field.Name))
    end
    return { how = "object" }
end

-- UE4SS leaves an enum's names in a global each time one is read.
local function clear_enum(name)
    local global = "Enum_" .. name
    if rawget(_G, global) ~= nil then rawset(_G, global, nil) end
end

-- A map as a plain table. A key is a number or a string: a struct key is the one name in it.
function read_map(field, name, map)
    if field.refused then refuse(field, field.refused) end
    local out, count, problem = {}, 0, nil
    local shape = field.shape
    local function entry(key_at, value_at)
        count = count + 1
        if count > M.max_entries then
            error(("'%s' holds more than %d entries, which is more than game.Data reads of one map"):format(name, M.max_entries), 0)
        end
        local key, value = key_at:get(), value_at:get()
        if not shape then
            shape = { key = element_of(field, key, true), value = element_of(field, value, false) }
            field.shape = shape
        end
        local how = shape.key.how
        if how == "struct" then
            key = scalar(shape.key.as, key[shape.key.pick])
        else
            key = scalar(how, key)
        end
        if key == nil then return end
        how = shape.value.how
        if how == "struct" then
            local into = {}
            read_struct(shape.value.node, value, into)
            value = into
        elseif how == "object" then
            value = read_object(field, value, true)
        else
            value = scalar(how, value)
        end
        -- as in a list: a reference to nothing is false, so its key is still there
        if value == nil then value = false end
        out[key] = value
    end
    -- an error must not leave the callback, where it would pass through UE4SS's own code
    map:ForEach(function(key_at, value_at)
        if problem == nil then
            local ok, err = pcall(entry, key_at, value_at)
            if not ok then problem = err or "a map entry could not be read" end
        end
    end)
    reading = name
    clear_enum(name .. "_Key")
    clear_enum(name)
    if problem ~= nil then error(problem, 0) end
    return out
end

local function take_list()
    listed_at = M.clock()
    local index, names = {}, {}
    local found = FindAllOf(LIST_CLASS)
    if found then
        for i = 1, #found do
            local object = found[i]
            if object:IsValid() then
                local path = strip(object:GetFullName())
                local name = short_name(leaf_name(path))
                local key = lower(name)
                if not index[key] and not name:find("^Default__") then
                    index[key] = { name = name, path = path }
                    names[#names + 1] = name
                end
            end
        end
    end
    table.sort(names)
    recent = { index = index, names = names }
    list = #names >= M.min_tables and recent or nil
    return recent
end

-- The list entry for a table name, or nil. Only names from the list are ever given to StaticFindObject.
local function listed(name)
    local key = lower(short_name(name))
    local known = list or recent
    local entry = known and known.index[key]
    if entry then return entry end
    if not listed_at or M.clock() - listed_at >= M.relist_seconds then entry = take_list().index[key] end
    return entry
end

local function new_record(name, object, owner)
    local struct = object:GetRowStruct()
    if not struct:IsValid() then error(("the table %s has no row struct"):format(name), 0) end
    local given, names, index = object:GetRowNames(), {}, {}
    for i = 1, #given do
        local row = given[i]
        if type(row) == "string" then
            local key = lower(row)
            if not index[key] then
                -- under both spellings, so the usual ask needs no folding
                index[key], index[row] = row, row
                names[#names + 1] = row
            end
        end
    end
    local record = {
        name = name, key = lower(name), owner = owner, names = names, index = index, count = #names,
        size = #object, address = object:GetAddress(), struct = strip(struct:GetFullName()),
        rows = {}, state = {}, states = {}, selections = {}, by_leaves = {}, failed = {}, warned = false,
        empty = { held = {}, steps = {} },
    }
    record.states[""] = record.empty
    if record.count ~= record.size then
        log:warn("%s: the game says %d rows and named %d of them", name, record.size, record.count)
    end
    return record
end

local function open(name)
    local short = short_name(name)
    local record = records[lower(short)]
    if record then return record end
    local entry = listed(name)
    if not entry then
        local known = list or recent
        error(("the game has no table named %s.%s"):format(short, suggest.phrase(short, known and known.names or {})), 0)
    end
    local object = StaticFindObject(entry.path)
    if not object:IsValid() or object:type() ~= TABLE_KIND then
        -- so the next ask is a miss in Lua, not another slow one in the engine
        local known = list or recent
        if known then known.index[lower(entry.name)] = nil end
        error(("the game lists the table %s but it cannot be found right now"):format(entry.name), 0)
    end
    record = new_record(entry.name, object, nil)
    record.path = entry.path
    records[record.key] = record
    -- the writer hears of a table that was read from the game again: it may be a new one without the mods' changes
    local found = M.writer
    if found and found.opened then pcall(found.opened, record) end
    return record
end

-- The engine's table for a record, found again: valid and still a table, or nil.
local function find(record)
    local object
    if record.owner then
        local owner = records[record.owner]
        if not owner then return nil end
        local parent = StaticFindObject(owner.path)
        if not parent:IsValid() or parent:type() ~= TABLE_KIND then return nil end
        object = parent.MetaTable
    else
        object = StaticFindObject(record.path)
    end
    if not object:IsValid() or object:type() ~= TABLE_KIND then return nil end
    return object
end

-- Like find, and false when it is not the table the cache was made from.
local function locate(record)
    local object = find(record)
    if not object then return nil end
    if object:GetAddress() ~= record.address or #object ~= record.size then return false end
    return object
end

local function drop(record)
    M.epoch = M.epoch + 1
    if record.owner then
        if metas[record.owner] == record then metas[record.owner] = nil end
    else
        if records[record.key] == record then records[record.key] = nil end
        metas[record.key] = nil
    end
end

function M.flush()
    M.epoch = M.epoch + 1
    records, metas, plans, curves = {}, {}, {}, {}
    list, recent, listed_at = nil, nil, nil
end

-- Fires Changed at the end of the frame, so no handler runs in the middle of a read.
local function announce(name)
    local previous = scope.enter(nil)
    task.defer(function() Changed:Fire(name) end)
    scope.leave(previous)
end

local function object_for(record)
    local store, key = record.owner and meta_objects or objects, record.owner or record.key
    local object = store[key]
    if not object then
        object = setmetatable({}, M.table_meta)
        infos[object] = { key = key, name = record.name, meta = record.owner ~= nil,
                          owner = record.owner and records[record.owner].name or nil }
        store[key] = object
    end
    return object
end

local meta_record

-- What is cached of the table behind a table object. It is opened again if the cache was emptied since.
local function record_of(self)
    local info = infos[self]
    if not info then error("this is not a data table. Get one from game.Data:Table(name)", 0) end
    if not info.meta then return records[info.key] or open(info.name) end
    local record = metas[info.key]
    if record then return record end
    local owner = open(info.owner)
    record = meta_record(object_for(owner), owner)
    if not record then error(("the table %s has no meta table any more"):format(info.owner), 0) end
    return record
end

-- The cache no longer matches the game. `found` is what locate said: nil for gone, false for another table.
local function renew(self, record, found)
    if found == nil then
        M.flush()
        announce(nil)
        error(("the game no longer has the table %s"):format(record.name), 0)
    end
    drop(record)
    announce(record.name)
    return record_of(self)
end

function meta_record(self, owner)
    for attempt = 1, 2 do
        local known = metas[owner.key]
        if known ~= nil then return known or nil end
        local object = locate(owner)
        if object then
            local found, record = object.MetaTable, false
            if found:IsValid() and found:type() == TABLE_KIND then
                record = new_record(owner.name .. "_METATABLE", found, owner.key)
            end
            metas[owner.key] = record
            return record or nil
        end
        if attempt == 1 then owner = renew(self, owner, object) end
    end
    error(("the table %s keeps changing, so it cannot be read right now"):format(owner.name), 0)
end

local function fail(record, real, selection, problem)
    local failed = record.failed[real]
    if not failed then
        failed = {}
        record.failed[real] = failed
    end
    failed[selection] = true
    if not record.warned then
        record.warned = true
        log:warn("%s: the row %s could not be read%s: %s. Other rows of this table that fail are not logged",
            record.name, real, reading and (" (at " .. reading .. ")") or "", clean(problem))
    end
end

-- Reads what one row still lacks. The row is found by the name the game itself listed.
local function read_row(record, object, real, step, selection)
    reading = nil
    local row = object:FindRow(real)
    if row == nil then
        fail(record, real, selection, "the game no longer has this row")
        return nil
    end
    local target = record.rows[real] or { Name = real }
    refusal = nil
    local ok, problem = pcall(read_struct, step.tree, row, target)
    if not ok then
        -- a field that can never be read is the asker's mistake, not this row's
        if refusal then
            local text = refusal
            refusal = nil
            error(text, 0)
        end
        fail(record, real, selection, problem)
        return nil
    end
    record.rows[real] = target
    record.state[real] = step.to
    return target
end

local function held_row(record, real)
    local row = record.rows[real]
    if not row then
        row = { Name = real }
        record.rows[real] = row
    end
    return row
end

local function check_name(name)
    if type(name) ~= "string" then error(("a row name is a string such as \"Wood\", got %s"):format(type(name)), 0) end
end

local function row_of(self, name, fields)
    check_name(name)
    key_of(fields)
    local record = record_of(self)
    for attempt = 1, 2 do
        -- the name is checked here, in Lua: asking the engine for an unknown one adds it to its name table for good
        local index = record.index
        local real = index[name] or index[lower(name)]
        if not real then return nil end
        local selection = selection_for(record, fields)
        local state = record.state[real] or record.empty
        local step = state.steps[selection] or step_of(record, state, selection)
        if not step.tree then return held_row(record, real) end
        local failed = record.failed[real]
        if failed and failed[selection] then return nil end
        local object = locate(record)
        if object then return read_row(record, object, real, step, selection) end
        if attempt == 1 then record = renew(self, record, object) end
    end
    error(("the table %s keeps changing, so it cannot be read right now"):format(record.name), 0)
end

-- When the calling task's share of this frame began, and how many rows it has read in it.
local function slice()
    local thread, frame = coroutine.running(), sched.stats.frame
    local mark = slices[thread]
    if not mark then
        mark = { frame = frame, at = M.clock(), rows = 0 }
        slices[thread] = mark
    elseif mark.frame ~= frame then
        mark.frame, mark.at, mark.rows = frame, M.clock(), 0
    end
    return mark
end

-- Checks what Load was given. Returns the fields, a copy of the names and the budget in seconds.
local function load_options(self, options)
    if not coroutine.isyieldable() then
        error("Load can only be used inside a task. Wrap the code in task.spawn(function() ... end)", 0)
    end
    if options ~= nil and type(options) ~= "table" then
        error(("the options are a table such as { fields = { \"DisplayName\" } }, got %s"):format(type(options)), 0)
    end
    options = options or {}
    local fields, names, budget = options.fields, options.names, options.budget
    if budget == nil then budget = DEFAULT_BUDGET end
    if type(budget) ~= "number" or budget < 0 then error("`budget` is a number of milliseconds a frame", 0) end
    if names ~= nil then
        if type(names) ~= "table" then error(("`names` is a list of row names, got %s"):format(type(names)), 0) end
        local copy = {}
        for i = 1, #names do
            check_name(names[i])
            copy[i] = names[i]
        end
        names = copy
    end
    selection_for(record_of(self), fields)
    return fields, names, budget / 1000
end

-- The reading itself. It runs outside any pcall of Wax's own, so its pauses are plain ones.
local function load_rows(self, fields, names, limit)
    local mark, renewed, passes = slice(), 0, 0
    while true do
        -- nothing of the engine's is carried over a pause: the table is found again when a row needs it
        local record = record_of(self)
        local selection = selection_for(record, fields)
        local wanted = record.names
        if names then
            wanted = {}
            local taken = {}
            for i = 1, #names do
                local real = record.index[names[i]] or record.index[lower(names[i])]
                if real and not taken[real] then
                    taken[real] = true
                    wanted[#wanted + 1] = real
                end
            end
        end
        local object, again, at = nil, false, 1
        while at <= #wanted do
            local real = wanted[at]
            local state = record.state[real] or record.empty
            local step = state.steps[selection] or step_of(record, state, selection)
            local failed = step.tree and record.failed[real]
            if not step.tree or (failed and failed[selection]) then
                at = at + 1
            elseif mark.rows > 0 and M.clock() - mark.at >= limit then
                -- the budget is used up: this row is looked at again after the pause, because someone else may read it
                object = nil
                M.pauses = M.pauses + 1
                task.wait()
                mark.frame, mark.at, mark.rows = sched.stats.frame, M.clock(), 0
                local info = infos[self]
                if (info.meta and metas or records)[info.key] ~= record then
                    again = true
                    break
                end
            else
                if not object then
                    object = locate(record)
                    if not object then
                        renewed = renewed + 1
                        if renewed > 3 then
                            error(("the table %s keeps changing, so it cannot be read right now"):format(record.name), 0)
                        end
                        renew(self, record, object)
                        again = true
                        break
                    end
                end
                read_row(record, object, real, step, selection)
                renewed, at = 0, at + 1
                mark.rows = mark.rows + 1
            end
        end
        if not again then
            -- a row that was changed during a pause was forgotten, and is read once more
            local out, missing = {}, false
            for i = 1, #wanted do
                local real = wanted[i]
                local state = record.state[real] or record.empty
                local step = state.steps[selection] or step_of(record, state, selection)
                if not step.tree then
                    out[real] = held_row(record, real)
                else
                    local failed = record.failed[real]
                    if not (failed and failed[selection]) then
                        missing = true
                        break
                    end
                end
            end
            if not missing then return out end
            -- rows that keep changing: after three tries the rest is read without a pause
            passes = passes + 1
            if passes >= 3 then limit = math.huge end
        end
    end
end

local function loaded(self, fields)
    local record = record_of(self)
    local selection = selection_for(record, fields)
    local done, failures = 0, 0
    for i = 1, record.count do
        local real = record.names[i]
        local state = record.state[real] or record.empty
        local step = state.steps[selection] or step_of(record, state, selection)
        local failed = record.failed[real]
        if not step.tree then
            done = done + 1
        elseif failed and failed[selection] then
            failures = failures + 1
        end
    end
    return done, record.count, failures
end

local function fields_of(self, path)
    local record = record_of(self)
    local struct = record.struct
    if path ~= nil then
        if type(path) ~= "string" then error(("a field path is a string such as \"Inputs\", got %s"):format(type(path)), 0) end
        local field, kept = walk(struct, path)
        if not field.Struct then error(("'%s' is %s, so it has no fields"):format(kept, describe(field)), 0) end
        struct = field.Struct
    end
    local out = {}
    for i, field in ipairs(plan_of(struct).list) do
        out[i] = { Name = field.Name, Kind = field.Kind, Struct = field.Struct and leaf_name(field.Struct) or nil, Inner = field.Inner }
    end
    return out
end

local function stamp(self)
    local record = record_of(self)
    for attempt = 1, 2 do
        local object = locate(record)
        if object then
            local address = math.tointeger(record.address)
            local text = ("%d:%s"):format(record.size, address and ("0x%X"):format(address) or tostring(record.address))
            -- a third part once a mod has changed the table, so what was worked out before is not trusted
            local writer = M.writer
            local changes = writer and writer.count(record.key) or 0
            if changes > 0 then text = text .. ":" .. changes end
            return text
        end
        if attempt == 1 then record = renew(self, record, object) end
    end
    error(("the table %s keeps changing, so it cannot be read right now"):format(record.name), 0)
end

-- The record of a table object and the game's table, found now.
local function live(self)
    local record = record_of(self)
    for attempt = 1, 2 do
        local object = locate(record)
        if object then return record, object end
        if attempt == 1 then record = renew(self, record, object) end
    end
    error(("the table %s keeps changing, so it cannot be read right now"):format(record.name), 0)
end

-- The row names of a table by its name, or nothing when the game has no such table. Returns index, names, name, and the name the game lists it under.
local function rows_of(name)
    local record = records[lower(short_name(name))]
    if not record then
        if not listed(name) then return nil end
        local ok, opened = pcall(open, name)
        if not ok then return nil end
        record = opened
    end
    return record.index, record.names, record.name, record.path and leaf_name(record.path) or nil
end

-- What was read of a row is dropped, so the next Row reads it again.
local function forget_row(record, real)
    M.epoch = M.epoch + 1
    record.rows[real], record.state[real], record.failed[real] = nil, nil, nil
end

-- A row was added to the game's table: the cache learns its name instead of being read again.
local function row_added(record, name, object)
    M.epoch = M.epoch + 1
    local key = lower(name)
    if not record.index[key] then
        record.index[key], record.index[name] = name, name
        record.names[#record.names + 1] = name
        record.count = record.count + 1
    end
    record.size = #object
end

local function row_removed(record, name, object)
    local real = record.index[name] or record.index[lower(name)]
    if real then
        record.index[real], record.index[lower(real)] = nil, nil
        for at = #record.names, 1, -1 do
            if record.names[at] == real then table.remove(record.names, at) end
        end
        record.count = record.count - 1
        forget_row(record, real)
    end
    record.size = #object
end

-- A writer of rows, or an error when this version has none.
local function writer()
    local found = M.writer
    if not found then error("changing the game's tables is not switched on in this version of Wax", 0) end
    return found
end

local Table = {}
local TABLE_NAMES = { "Name", "RowStruct", "Raw", "Count", "GetNames", "Has", "Row", "Load", "Loaded", "Fields", "Meta", "Stamp",
                      "Set", "Change", "Add", "Reset", "Changes", "Conflicts" }

Table.Set = public(function(self, row, field, value) return writer().set(self, row, field, value) end)
Table.Change = public(function(self, row, field, fn) return writer().change(self, row, field, fn) end)
Table.Add = public(function(self, name, values, options) return writer().add(self, name, values, options) end)
Table.Reset = public(function(self, row, field) return writer().reset(self, row, field) end)

Table.Changes = public(function(self)
    record_of(self)
    return M.writer and M.writer.changes(self) or {}
end)

Table.Conflicts = public(function(self)
    record_of(self)
    return M.writer and M.writer.conflicts(self) or {}
end)

Table.Count = public(function(self) return record_of(self).count end)

Table.GetNames = public(function(self)
    local names = record_of(self).names
    return table.move(names, 1, #names, 1, {})
end)

Table.Has = public(function(self, name)
    check_name(name)
    local index = record_of(self).index
    return (index[name] or index[lower(name)]) ~= nil
end)

Table.Row = public(row_of)
Table.Loaded = public(loaded)
Table.Fields = public(fields_of)
Table.Stamp = public(stamp)

function Table:Load(options)
    local ok, fields, names, limit = pcall(load_options, self, options)
    if not ok then error(fields, 2) end
    return load_rows(self, fields, names, limit)
end

Table.Meta = public(function(self)
    if infos[self] and infos[self].meta then return nil end
    local record = meta_record(self, record_of(self))
    return record and object_for(record) or nil
end)

local READS = {
    RowStruct = function(self) return leaf_name(record_of(self).struct) end,
    Raw = function(self) return find(record_of(self)) end,
}

M.table_meta = {
    __index = function(self, key)
        local method = Table[key]
        if method then return method end
        if key == "Name" then return infos[self].name end
        local read = READS[key]
        if read then
            local ok, value = pcall(read, self)
            if not ok then error(value, 2) end
            return value
        end
        error(("%s is not a member of a data table.%s"):format(tostring(key), suggest.phrase(tostring(key), TABLE_NAMES)), 2)
    end,
    __newindex = function(_, key)
        error(("%s cannot be assigned because a data table is read-only. Rows are changed with Set"):format(tostring(key)), 2)
    end,
    __tostring = function(self) return "DataTable(" .. infos[self].name .. ")" end,
    __names = function() return TABLE_NAMES end,
}

local Data = { Changed = Changed, Patched = Patched }
local NAMES = { "Table", "GetTables", "Has", "Resolve", "Flush", "Changed", "Changes", "Conflicts", "Patched" }

-- What mods changed in every table, and where one mod's change hides another's.
Data.Changes = public(function() return M.writer and M.writer.changes(nil) or {} end)
Data.Conflicts = public(function() return M.writer and M.writer.conflicts(nil) or {} end)

local function check_table_name(name)
    if type(name) ~= "string" then error(("a table name is a string such as \"ItemsStatic\", got %s"):format(type(name)), 0) end
end

-- A table by name, with or without the "D_" in front. Letter case does not matter.
Data.Table = public(function(_, name)
    check_table_name(name)
    return object_for(open(name))
end)

Data.GetTables = public(function()
    local known = list or recent
    if not known or (not list and M.clock() - listed_at >= M.relist_seconds) then known = take_list() end
    return table.move(known.names, 1, #known.names, 1, {})
end)

Data.Has = public(function(_, name)
    check_table_name(name)
    return records[lower(short_name(name))] ~= nil or listed(name) ~= nil
end)

-- The row a row handle points at, and its table, or nil when it names none.
Data.Resolve = public(function(_, handle, fields)
    if type(handle) ~= "table" then
        error(("a row handle is a table such as { RowName = \"Wood\", DataTableName = \"D_ItemsStatic\" }, got %s"):format(type(handle)), 0)
    end
    local row_name, table_name = handle.RowName, handle.DataTableName
    if type(row_name) ~= "string" then error("this is not a row handle: it has no RowName", 0) end
    if type(table_name) ~= "string" then
        error("this handle does not name its table (DataTableName was not read as a name). Use game.Data:Table(name):Row(handle.RowName)", 0)
    end
    key_of(fields)
    if row_name == "None" or row_name == "" or table_name == "None" or table_name == "" then return nil end
    if not records[lower(short_name(table_name))] and not listed(table_name) then return nil end
    local found = object_for(open(table_name))
    local row = row_of(found, row_name, fields)
    if row == nil then return nil end
    return row, found
end)

-- Everyone who keeps something worked out from rows is told, not only the mod that asked.
function Data:Flush()
    M.flush()
    announce()
end

setmetatable(Data, {
    __index = function(_, key)
        error(("%s is not a member of game.Data.%s"):format(tostring(key), suggest.phrase(tostring(key), NAMES)), 2)
    end,
    __newindex = function(_, key)
        error(("game.Data.%s cannot be assigned because game.Data is read-only"):format(tostring(key)), 2)
    end,
    __tostring = function() return "Data" end,
    __names = function() return NAMES end,
})

-- After a map change: is every cached table still the one it was read from?
local function check_tables()
    local changed = {}
    for _, store in ipairs({ records, metas }) do
        for _, record in pairs(store) do
            if record then
                local object = locate(record)
                -- one table that is not found: stop looking, because each miss is slow
                if object == nil then return nil end
                if object == false then changed[#changed + 1] = record end
            end
        end
    end
    return changed
end

local function on_map_changed()
    local ok, changed = pcall(check_tables)
    if not ok then log:warn("the cached tables could not be checked after a map change: %s", clean(changed)) end
    if not ok or not changed then
        M.flush()
        Changed:Fire()
        return
    end
    for i = 1, #changed do drop(changed[i]) end
    for i = 1, #changed do Changed:Fire(changed[i].name) end
end

local connection = nil

function M.start()
    local game = Wax.import("engine.game")
    rawset(game.root, "Data", Data)
    if not connection then connection = game.root.MapChanged:Connect(on_map_changed) end
end

function M.stats()
    local out = { tables = 0, meta_tables = 0, rows = 0, structs = 0, pauses = M.pauses, listed = list and #list.names or 0 }
    for _, record in pairs(records) do
        out.tables = out.tables + 1
        for _ in pairs(record.rows) do out.rows = out.rows + 1 end
    end
    for _, record in pairs(metas) do
        if record then
            out.meta_tables = out.meta_tables + 1
            for _ in pairs(record.rows) do out.rows = out.rows + 1 end
        end
    end
    for _ in pairs(plans) do out.structs = out.structs + 1 end
    out.curves = 0
    for _ in pairs(curves) do out.curves = out.curves + 1 end
    return out
end

-- What data.patch works with. Nothing here is for mods.
M.internal = {
    plan_of = plan_of, scalar = scalar, clean = clean, describe = describe, live = live, record_of = record_of, rows = rows_of,
    forget = forget_row, row_added = row_added, row_removed = row_removed, Patched = Patched,
    named = function(name) return object_for(open(name)) end,
    meta = function(record) return metas[record.key] or nil end,
    changed = function(name) Changed:Fire(name) end,
    table_names = function()
        local known = list or recent
        return known and known.names or {}
    end,
}

M.api = Data
return M
