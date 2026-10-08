-- A struct written as a Lua table, made into what the engine takes: each field is checked against the struct itself

local Wax = ...
local suggest = Wax.import("core.suggest")
local log = Wax.import("core.log").channel("wax.convert")

local M = {}

M.CHECK_PLAIN = true        -- false: a table of plain numbers goes to the engine unchecked

-- Set by engine.instance: what tells an Instance, and what gives its engine object or raises when it is gone.
M.is_instance = function(_) return false end
M.unwrap = function(_) return nil end

local MAX_DEPTH = 16
local CLASS_DEPTH = 64
local NAME_LENGTH = 1023
local shapes = {}           -- struct path -> its fields, or false when the game did not give them. Strings only
local lower = string.lower

local INTEGERS = {
    Int8Property = true, Int16Property = true, IntProperty = true, Int64Property = true, ByteProperty = true,
    UInt16Property = true, UInt32Property = true, UInt64Property = true, EnumProperty = true,
}
local NUMBERS = { FloatProperty = true, DoubleProperty = true }
local OBJECT_KINDS = { UObject = true, AActor = true, UClass = true, UFunction = true, UEnum = true, UWorld = true, UDataTable = true }
-- What a struct written as a table cannot carry: UE4SS reads these from the wrong place, or without looking what they are.
local REFUSED = {
    MapProperty = "a map", SetProperty = "a set", WeakObjectProperty = "a weak object reference",
    SoftObjectProperty = "a soft object reference", SoftClassProperty = "a soft class reference",
    InterfaceProperty = "an interface", DelegateProperty = "a delegate", MulticastInlineDelegateProperty = "an event",
    MulticastSparseDelegateProperty = "an event", MulticastDelegateProperty = "an event",
    FieldPathProperty = "a field path", LazyObjectProperty = "a lazy object reference",
}

local function strip(full) return (full:gsub("^%S+%s+", "")) end
local function leaf(path) return path:match("([^%.:/]+)$") or path end
local function name_of(object) return object:GetFName():ToString() end

local function clean(problem)
    local text = tostring(problem):match("^[^\r\n]*") or ""
    return (text:gsub("^.-%.lua:%d+: ", ""))
end

local function kind_of(value)
    local ok, kind = pcall(function() return value:type() end)
    return ok and kind or nil
end

local function got(value)
    if M.is_instance(value) then return "an Instance" end
    return type(value)
end

local function described(kind)
    local word = kind:gsub("Property$", ""):lower()
    return (word:find("^[aeiou]") and "an " or "a ") .. word
end

-- A struct handed out by a property cannot list its fields: the one found by its path can.
local function own_fields(path)
    local struct = StaticFindObject(path)
    if not struct:IsValid() then error(("the game has no struct at %s"):format(path), 0) end
    local fields, problem = {}, nil
    struct:ForEachProperty(function(property)
        local ok, err = pcall(function()
            local kind = name_of(property:GetClass())
            local field = { name = name_of(property), type = kind }
            if kind == "StructProperty" then field.struct = strip(property:GetStruct():GetFullName()) end
            fields[#fields + 1] = field
        end)
        if not ok and not problem then problem = err end
    end)
    if problem then error(problem, 0) end
    local parent = struct:GetSuperStruct()
    return fields, parent:IsValid() and strip(parent:GetFullName()) or nil
end

local function build(path)
    local by, folded, names, at, depth = {}, {}, {}, path, 0
    while at do
        depth = depth + 1
        if depth > MAX_DEPTH then error(("the struct %s has more than %d parents"):format(path, MAX_DEPTH), 0) end
        local own, parent = own_fields(at)
        for i = 1, #own do
            local field = own[i]
            if not by[field.name] then
                by[field.name] = field
                names[#names + 1] = field.name
                local key = lower(field.name)
                -- two fields that differ only by letter case can only be named exactly
                if folded[key] == nil then folded[key] = field else folded[key] = false end
            end
        end
        at = parent
    end
    return { path = path, name = leaf(path), by = by, folded = folded, names = names }
end

-- The fields of the struct at `path`, with those of its parents. Nil when the game does not give them.
function M.shape(path)
    if not path then return nil end
    local shape = shapes[path]
    if shape == nil then
        local ok, built = pcall(build, path)
        shape = ok and built or false
        shapes[path] = shape
        if not ok then log:warn("the fields of the struct %s could not be read from the game: %s", path, clean(built)) end
    end
    return shape or nil
end

local struct_value

local function field_value(value, field, what, depth)
    local kind, t = field.type, type(value)
    if kind == "NameProperty" then
        if t == "string" then
            if #value > NAME_LENGTH then error(("%s is a name, and a name has at most %d letters"):format(what, NAME_LENGTH), 0) end
            return FName(value)
        end
        if t == "userdata" and kind_of(value) == "FName" then return value end
        error(("%s expects a name (a string), got %s"):format(what, got(value)), 0)
    elseif kind == "StructProperty" then
        if t == "table" and not M.is_instance(value) then
            local shape = M.shape(field.struct)
            if not shape then
                error(("%s is a %s, and the game did not say what fields that has"):format(what, leaf(field.struct or "struct")), 0)
            end
            local inner, changed = struct_value(value, shape, what, depth + 1)
            return changed and inner or value
        end
        if t == "userdata" then
            error(("%s is a struct inside a struct. Write it as a table of its fields: an engine struct is only taken whole")
                :format(what), 0)
        end
        error(("%s expects a struct written as a table of its fields, got %s"):format(what, got(value)), 0)
    elseif kind == "BoolProperty" then
        if t == "boolean" then return value end
        error(("%s expects true or false, got %s"):format(what, got(value)), 0)
    elseif INTEGERS[kind] then
        if t == "number" then
            local whole = math.tointeger(value)
            if whole then return whole end
            error(("%s expects a whole number, got %s"):format(what, tostring(value)), 0)
        end
        error(("%s expects a whole number, got %s"):format(what, got(value)), 0)
    elseif NUMBERS[kind] then
        if t == "number" then return value end
        error(("%s expects a number, got %s"):format(what, got(value)), 0)
    elseif kind == "StrProperty" then
        if t == "string" then return value end
        if t == "number" then return tostring(value) end
        error(("%s expects a string, got %s"):format(what, got(value)), 0)
    elseif kind == "TextProperty" then
        if t == "string" then return FText(value) end
        if t == "userdata" and kind_of(value) == "FText" then return value end
        error(("%s expects text (a string), got %s"):format(what, got(value)), 0)
    elseif kind == "ObjectProperty" or kind == "ClassProperty" then
        if M.is_instance(value) then return M.unwrap(value) end
        if t == "userdata" and OBJECT_KINDS[kind_of(value)] then return value end
        error(("%s expects an Instance, got %s"):format(what, got(value)), 0)
    elseif kind == "ArrayProperty" then
        if t == "userdata" and kind_of(value) == "TArray" then return value end
        error(("%s is a list inside a struct, which a struct written as a table cannot carry into the engine. "
            .. "Leave it out, or give an engine array (see .Raw)"):format(what), 0)
    end
    error(("%s is %s, which cannot be given inside a struct written as a table"):format(what, REFUSED[kind] or described(kind)), 0)
end

function struct_value(value, shape, what, depth)
    if depth > MAX_DEPTH then error(("%s is a struct inside too many others"):format(what), 0) end
    local out, changed = {}, false
    for key, item in pairs(value) do
        if type(key) ~= "string" then
            error(("%s: %s is written with the names of its fields, and this table has the key %s")
                :format(what, shape.name, tostring(key)), 0)
        end
        local field = shape.by[key] or shape.folded[lower(key)]
        if not field then
            error(("%s: %s has no field named '%s'.%s"):format(what, shape.name, key, suggest.phrase(key, shape.names)), 0)
        end
        local name = field.name
        if out[name] ~= nil then error(("%s.%s is given twice: as '%s' and in another spelling"):format(what, name, key), 0) end
        local converted = field_value(item, field, what .. "." .. name, depth)
        out[name] = converted
        changed = changed or name ~= key or not rawequal(converted, item)
    end
    return out, changed
end

-- `value` as the engine takes it: names for strings, engine objects for Instances, every field under its own name.
-- A table that needs no change is handed back as it is. `what` names the place for messages. Raises without a position.
function M.struct(value, shape, what)
    local out, changed = struct_value(value, shape, what, 1)
    return changed and out or value
end

local function find(holder, name, climb)
    local at, found = holder, nil
    for _ = 1, CLASS_DEPTH do
        -- a callback that returns true ends the walk
        at:ForEachProperty(function(property)
            if found ~= nil then return true end
            if name_of(property) ~= name then return end
            found = name_of(property:GetClass()) == "StructProperty" and strip(property:GetStruct():GetFullName()) or false
            return true
        end)
        if found ~= nil or not climb then break end
        at = at:GetSuperStruct()
        if not at:IsValid() then break end
    end
    return found or nil
end

-- The path of the struct that the property `name` of a class or a function holds, or nil. `climb` also looks in what the class is built on.
function M.struct_path(holder, name, climb)
    local ok, path = pcall(find, holder, name, climb)
    return ok and path or nil
end

-- Called after a map change: a struct that could not be read is asked for again.
function M.flush()
    for path, shape in pairs(shapes) do
        if shape == false then shapes[path] = nil end
    end
end

function M.stats()
    local read, failed = 0, 0
    for _, shape in pairs(shapes) do
        if shape then read = read + 1 else failed = failed + 1 end
    end
    return { structs = read, unread = failed }
end

return M
