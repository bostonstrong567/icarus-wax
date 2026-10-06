-- What an inspector needs to know about an object's members, and the typed reads and writes it makes

local Wax = ...
local reflect = Wax.import("engine.reflect")
local instance = Wax.import("engine.instance")

local M = {}

M.ELEMENTS = 50         -- how many places of an array are read at most

local INTEGERS = {
    Int8Property = "int8", Int16Property = "int16", IntProperty = "int", Int64Property = "int64", ByteProperty = "byte",
    UInt16Property = "uint16", UInt32Property = "uint32", UInt64Property = "uint64", EnumProperty = "enum",
}
local TEXTS = { NameProperty = "name", StrProperty = "string", TextProperty = "text" }
local LABELS = {
    ObjectProperty = "object", ClassProperty = "class", StructProperty = "struct", ArrayProperty = "array", MapProperty = "map",
    SetProperty = "set", WeakObjectProperty = "weak object", SoftObjectProperty = "soft object", SoftClassProperty = "soft class",
    InterfaceProperty = "interface", DelegateProperty = "delegate", MulticastInlineDelegateProperty = "event",
    MulticastSparseDelegateProperty = "event", MulticastDelegateProperty = "event", FieldPathProperty = "field path",
    LazyObjectProperty = "lazy object", DoubleProperty = "double",
}
-- Structs made only of numbers, with the names of their parts. Only these are read.
local STRUCTS = {
    Vector = { "X", "Y", "Z" }, Vector2D = { "X", "Y" }, Rotator = { "Pitch", "Yaw", "Roll" },
    LinearColor = { "R", "G", "B", "A" }, Color = { "R", "G", "B", "A", whole = true },
}
M.STRUCTS = STRUCTS

local by_class = {}     -- class address -> { info, list }
local kinds = {}        -- class name -> kind

local function name_of(object) return object:GetFName():ToString() end

-- An error as one line, without the file and line it was raised at.
local function clean(problem)
    local text = tostring(problem):match("^[^\r\n]*") or ""
    return (text:gsub("^.-%.lua:%d+: ", ""))
end
M.clean = clean

-- How a value of a property type is shown: "bool", "int", "float", "text", "object", or nil for one that is never read.
local function simple(type_name)
    if type_name == "BoolProperty" then return "bool" end
    if INTEGERS[type_name] then return "int" end
    if type_name == "FloatProperty" then return "float" end
    if TEXTS[type_name] then return "text" end
    return nil
end

local function label_of(record, member, detail)
    if member.kind == "function" then
        record.label, record.member = "function", member
        return
    end
    local type_name = member.type
    record.type = type_name
    local show = simple(type_name)
    if show then
        record.show, record.edit, record.poll = show, true, true
        record.label = show == "bool" and "bool" or show == "float" and "float" or INTEGERS[type_name] or TEXTS[type_name]
    elseif type_name == "ObjectProperty" or type_name == "ClassProperty" then
        record.show, record.label = "object", LABELS[type_name]
    elseif type_name == "StructProperty" then
        record.struct, record.label = detail or nil, detail or "struct"
        local fields = detail and STRUCTS[detail]
        if fields then record.show, record.fields, record.edit = "struct", fields, true end
    elseif type_name == "ArrayProperty" then
        record.show, record.inner = "array", detail or nil
        local inner = detail and (simple(detail) or (detail == "ObjectProperty" and "object")) or nil
        record.inner_show = inner or nil
        record.label = "array of " .. (detail and (LABELS[detail] or INTEGERS[detail] or TEXTS[detail] or simple(detail)
            or detail:gsub("Property$", ""):lower()) or "?")
    else
        record.label = LABELS[type_name] or type_name:gsub("Property$", ""):lower()
    end
end

-- One member: name, kind, a short name for its type, how it is shown (`show`), and whether it can be typed and watched.
local function describe(name, member, detail)
    local record = { name = name, kind = member.kind, order = name:lower() }
    label_of(record, member, detail)
    record.search = record.order .. " " .. record.label:lower()
    return record
end

-- The struct a struct property holds and the kind of thing an array holds, by property name.
local function details(class)
    local found = {}
    local at = class
    while at:IsValid() do
        at:ForEachProperty(function(property)
            local type_name = name_of(property:GetClass())
            if type_name ~= "StructProperty" and type_name ~= "ArrayProperty" then return end
            local name = name_of(property)
            if found[name] ~= nil then return end
            local ok, detail = pcall(function()
                if type_name == "StructProperty" then return name_of(property:GetStruct()) end
                return name_of(property:GetInner():GetClass())
            end)
            found[name] = ok and detail or false
        end)
        at = at:GetSuperStruct()
    end
    return found
end

-- Every member of the object's class, sorted by name. One list per class, shared by every object of it.
function M.members(inst)
    local class = inst.Raw:GetClass()
    local info = reflect.class_info(class)
    local key = class:GetAddress()
    local cached = by_class[key]
    if cached and cached.info == info then return cached.list end
    local detail = details(class)
    local list = {}
    for name, member in pairs(info.members) do list[#list + 1] = describe(name, member, detail[name] or nil) end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.name < b.name
    end)
    by_class[key] = { info = info, list = list }
    return list
end

-- A function's parameters as { name, label }, without what a blueprint function keeps for itself.
function M.parameters(record)
    local out = {}
    for _, param in ipairs(reflect.parameters(record.member)) do
        if param.name:find("^CallFunc_") or param.name:find("^K2Node_") or param.name:find("^Temp_") then break end
        local label = simple(param.type) and (INTEGERS[param.type] or TEXTS[param.type] or simple(param.type))
            or LABELS[param.type] or param.type:gsub("Property$", ""):lower()
        out[#out + 1] = { name = param.name, label = label }
    end
    return out
end

local function plain(show, value)
    if show == "bool" then
        if type(value) ~= "boolean" then error("this is not true or false", 0) end
    elseif show == "int" or show == "float" then
        if type(value) ~= "number" then error("this is not a number", 0) end
    elseif show == "text" then
        if type(value) ~= "string" then error("this is not text", 0) end
    elseif show == "object" then
        if value == nil then return false end
        if not instance.is_instance(value) then error("this is not an object", 0) end
        return { name = value.Name, class = value.ClassName }
    end
    return value
end

local function read(inst, record)
    local show = record.show
    if not show then error("values of this type are not read", 0) end
    if show == "array" then return inst.Raw[record.name]:GetArrayNum() end
    local value = inst:Get(record.name)
    if show ~= "struct" then return plain(show, value) end
    local out = {}
    for _, field in ipairs(record.fields) do
        local part = value[field]
        if type(part) ~= "number" then error(("no number named %s in this %s"):format(field, record.struct), 0) end
        out[field] = part
    end
    return out
end

-- Reads one property. Returns true and the value (a boolean, a number, text, { name, class } or false for an object,
-- a table of numbers for a struct, the length for an array), or false and why it could not be read.
function M.read(inst, record)
    local ok, value = pcall(read, inst, record)
    if ok then return true, value end
    return false, clean(value)
end

-- The first places of an array. Returns true and { total, items }, or false and why.
function M.elements(inst, record, limit)
    local ok, result = pcall(function()
        local array = inst.Raw[record.name]
        local total = array:GetArrayNum()
        local items = {}
        if record.inner_show then
            for index = 1, math.min(total, limit or M.ELEMENTS) do
                items[index] = plain(record.inner_show, instance.to_lua(array[index]))
            end
        end
        return { total = total, items = items }
    end)
    if ok then return true, result end
    return false, clean(result)
end

-- The object in one place of an array, or nil.
function M.element(inst, record, index)
    local array = inst.Raw[record.name]
    if index < 1 or index > array:GetArrayNum() then return nil end
    local value = instance.to_lua(array[index])
    return instance.is_instance(value) and value or nil
end

-- Writes through the checked path. Returns true, or false and why not.
function M.write(inst, record, value)
    local ok, problem = pcall(inst.Set, inst, record.name, value)
    if ok then return true end
    return false, clean(problem)
end

local YES = { ["true"] = true, ["1"] = true, on = true, yes = true }
local NO = { ["false"] = true, ["0"] = true, off = true, no = true }

-- Typed text as a value for the property (or for one part of a struct). Returns the value, or nil and what is expected.
function M.parse(record, text, field)
    local show = record.show
    text = tostring(text)
    if show == "text" then
        if record.type == "NameProperty" and text == "" then return "None" end
        return text
    end
    local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
    if show == "bool" then
        local word = trimmed:lower()
        if YES[word] then return true end
        if NO[word] then return false end
        return nil, "true or false is needed"
    end
    local part = show == "struct" and field ~= nil
    if show ~= "int" and show ~= "float" and not part then return nil, "this cannot be typed" end
    local number = tonumber(trimmed)
    if not number or number ~= number then return nil, "a number is needed" end
    if show == "int" or (part and record.fields.whole) then
        local whole = math.tointeger(number)
        if not whole then return nil, "a whole number is needed" end
        return whole
    end
    return number
end

local function number_text(value)
    if math.type(value) == "integer" then return ("%d"):format(value) end
    if value ~= value then return "nan" end
    if value == math.huge then return "inf" end
    if value == -math.huge then return "-inf" end
    local size = math.abs(value)
    if size >= 1e15 or (size > 0 and size < 0.001) then return ("%.6g"):format(value) end
    local text = ("%.4f"):format(value):gsub("0+$", "")
    return (text:gsub("%.$", ".0"))
end

-- A value as it is shown in a row.
function M.text(record, value, field)
    local kind = type(value)
    if value == false and (field and record.inner_show or record.show) == "object" then return "none" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        if record.show == "array" and not field then return value == 1 and "1 item" or ("%d items"):format(value) end
        return number_text(value)
    end
    if kind == "string" then
        local line = value:gsub("[%c]+", " ")
        return #line > 120 and line:sub(1, 117) .. "..." or line
    end
    if kind == "table" then
        if record.fields and not field then
            local parts = {}
            for index, part in ipairs(record.fields) do parts[index] = number_text(value[part]) end
            return table.concat(parts, ", ")
        end
        return ("%s (%s)"):format(tostring(value.name), tostring(value.class))
    end
    if value == false then return "none" end
    return ""
end

-- A value as Lua code.
function M.literal(record, value)
    local kind = type(value)
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        if value ~= value then return "0 / 0" end
        if value == math.huge then return "math.huge" end
        if value == -math.huge then return "-math.huge" end
        return number_text(value)
    end
    if kind == "string" then return (("%q"):format(value):gsub("\\\n", "\\n")) end
    if kind == "table" and record.fields then
        local parts = {}
        for index, part in ipairs(record.fields) do parts[index] = ("%s = %s"):format(part, number_text(value[part])) end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    return "nil"
end

-- "player", "creature", "building", "item", "actor", "component", "widget" or "object", from the class and what it inherits.
function M.kind(inst)
    local class_name = inst.ClassName
    local kind = kinds[class_name]
    if kind then return kind end
    if inst:IsA("IcarusPlayerCharacter") then
        kind = "player"
    elseif inst:IsA("IcarusNPCCharacter") or inst:IsA("IcarusPawn") then
        local members = reflect.class_info(inst.Raw:GetClass()).members
        kind = (members.AISetup or members.AISetupRow) and "creature" or "actor"
    elseif inst:IsA("BuildingBase") or inst:IsA("Deployable") then
        kind = "building"
    elseif inst:IsA("IcarusItem") then
        kind = "item"
    elseif inst:IsA("Actor") then
        kind = "actor"
    elseif inst:IsA("ActorComponent") then
        kind = "component"
    elseif inst:IsA("Widget") then
        kind = "widget"
    else
        kind = "object"
    end
    kinds[class_name] = kind
    return kind
end

-- The shortest name of a property of `owner` that holds `target`, or nil. Only plain object references are looked at.
function M.holder(owner, target)
    local wanted, raw, found = instance.address(target), owner.Raw, nil
    local function holds(name)
        local value = raw[name]
        return value:IsValid() and value:GetAddress() == wanted
    end
    for _, record in ipairs(M.members(owner)) do
        if record.type == "ObjectProperty" and (not found or #record.name < #found) then
            local ok, same = pcall(holds, record.name)
            if ok and same then found = record.name end
        end
    end
    return found
end

-- True for an actor and for a component of one. Those are told when they end play, so their Instances may be kept.
function M.owned(inst)
    if inst:IsA("Actor") then return true end
    if not inst:IsA("ActorComponent") then return false end
    local ok, outer = pcall(function() return instance.wrap(inst.Raw:GetOuter()) end)
    return ok and outer ~= nil and outer:IsA("Actor")
end

local function spot(inst)
    local at = inst:K2_GetActorLocation()
    return at.X, at.Y, at.Z
end

-- Where an actor is, in the engine's units, or nil.
function M.position(inst)
    local ok, x, y, z = pcall(spot, inst)
    if ok and type(x) == "number" then return x, y, z end
    return nil
end

-- Every component of an actor, however it is attached.
function M.parts(actor, limit)
    local out, queue, head = {}, actor:GetChildren(), 1
    limit = limit or 200
    while queue[head] and #out < limit do
        local child = queue[head]
        head = head + 1
        if child:IsA("ActorComponent") then
            out[#out + 1] = child
            if child:IsA("SceneComponent") then
                for _, below in ipairs(child:GetChildren()) do queue[#queue + 1] = below end
            end
        end
    end
    return out
end

function M.flush() by_class, kinds = {}, {} end

function M.stats()
    local classes, named = 0, 0
    for _ in pairs(by_class) do classes = classes + 1 end
    for _ in pairs(kinds) do named = named + 1 end
    return { classes = classes, kinds = named }
end

return M
