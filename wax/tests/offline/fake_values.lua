-- How UE4SS takes Lua values into the engine, as a stand-in on top of fake_world.lua: structs found by path, names
-- and texts as values of their own, and functions and properties that take what they are given the way the game does.
-- What would crash the real game is counted and raised as "CRASH: ...". What the engine would silently drop or turn
-- into something else is counted too. The rules are read from UE4SS's LuaUObject.cpp (call_ufunction_from_lua and the pushers).
--   local values = dofile("wax/tests/offline/fake_values.lua")
--   values.install(world)                                     after world.install()
--   values.struct(path, parent, { { "RowName", "NameProperty" }, { "Item", "StructProperty", struct = path } })
--   values.class(path, super, members, functions)             as world.class, where a struct is named by its path
--   values.actor(class, name, props, components)   values.part(class, name, props)   values.of(object)   values.plain(value)

local values = {}
---@type any
local world = nil       -- fake_world, given to install
local structs = {}
local stores = setmetatable({}, { __mode = "k" })

local COUNTERS = { "crashes", "dropped", "silent", "misuse", "finds", "misses", "walks" }

-- Every counter back to zero. Structs, classes and objects stay.
function values.reset()
    for _, name in ipairs(COUNTERS) do values[name] = 0 end
    values.log = {}
end
values.reset()

local INTS = {
    Int8Property = true, Int16Property = true, IntProperty = true, Int64Property = true, ByteProperty = true,
    UInt16Property = true, UInt32Property = true, UInt64Property = true, EnumProperty = true,
}
local FLOATS = { FloatProperty = true, DoubleProperty = true }
local OBJECTS = { UObject = true, AActor = true, UClass = true }

local function note(counter, what)
    values[counter] = values[counter] + 1
    values.log[#values.log + 1] = counter .. ": " .. what
end

-- What would end the real game.
local function crash(what)
    note("crashes", what)
    error("CRASH: " .. what, 0)
end

-- What the real objects do not offer.
local function misuse(what)
    note("misuse", what)
    error("MISUSE: " .. what, 0)
end

local function leaf(path) return path:match("([^%.:/]+)$") or path end

-- A stand-in for a userdata: one of fake_world's objects, or a name or text made here.
local function is_fake(value)
    if not pcall(rawget, value, 1) then return false end
    return rawget(value, "__props") ~= nil or rawget(value, "__invalid") == true
end

-- A Lua value as the engine sees it.
local function seen_as(value)
    if is_fake(value) then return "userdata" end
    return type(value)
end

local function kind_of(value)
    if not is_fake(value) then return nil end
    return rawget(value, "__kind") or "UObject"
end

local TEXT = {}
TEXT.__index = function(self, key)
    if key == "type" then return function() return rawget(self, "__kind") end end
    if key == "ToString" then return function() return rawget(self, "__text") end end
    if key == "IsValid" then return function() return true end end
    return nil
end

local function text_value(kind, text)
    if type(text) ~= "string" then crash(kind .. "() was given a " .. seen_as(text)) end
    return setmetatable({ __props = {}, __kind = kind, __text = text }, TEXT)
end

-- An object with these members and no others.
local function strict(what, members)
    return setmetatable({}, { __index = function(_, key)
        local member = members[key]
        if member == nil then misuse(("%s was asked for %s"):format(what, tostring(key))) end
        return member
    end })
end

-- A property, parameter or field as { name, type, struct, inner, out }, from any of the ways one is written.
local function normal(name, spec, entry)
    if type(spec) == "table" then
        return { name = name, type = spec.type or spec[1], struct = spec.struct, inner = spec.inner, out = entry and entry.out }
    end
    return { name = name, type = spec, struct = entry and entry.struct, inner = entry and entry.inner, out = entry and entry.out }
end

local function class_of(kind)
    return strict("a property's class", { GetFName = function() return world.name(kind) end })
end

-- What GetStruct() gives says what it is called and nothing else: it cannot list its fields.
local function handed_out(path)
    return strict("a struct handed out by a property", {
        GetFullName = function() return "ScriptStruct " .. tostring(path) end,
        GetFName = function() return world.name(leaf(tostring(path))) end,
    })
end

local function property(spec, open)
    local function check(key)
        if not open() then misuse(("the property %s was used after the walk that handed it out (%s)"):format(spec.name, key)) end
    end
    return strict("the property " .. spec.name, {
        GetFName = function()
            check("GetFName")
            return world.name(spec.name)
        end,
        GetClass = function()
            check("GetClass")
            return class_of(spec.type)
        end,
        GetStruct = function()
            check("GetStruct")
            if spec.type ~= "StructProperty" then crash("GetStruct() on a " .. spec.type) end
            return handed_out(spec.struct)
        end,
        GetInner = function()
            check("GetInner")
            if spec.type ~= "ArrayProperty" then crash("GetInner() on a " .. spec.type) end
            return strict("a property from GetInner()", {
                GetClass = function() return class_of(spec.inner) end,
                GetStruct = function()
                    if spec.inner ~= "StructProperty" then crash("GetStruct() on an array of " .. tostring(spec.inner)) end
                    return handed_out(spec.struct)
                end,
            })
        end,
    })
end

-- Own properties only, in the order given. A callback that returns true ends the walk, as in UE4SS.
local function walk(list, fn)
    values.walks = values.walks + 1
    local open = true
    local ok, problem = pcall(function()
        for _, spec in ipairs(list) do
            if fn(property(spec, function() return open end)) == true then break end
        end
    end)
    open = false
    if not ok then error(problem, 0) end
end

local function struct_object(shape)
    return strict("the struct " .. shape.path, {
        IsValid = function() return true end,
        type = function() return "UScriptStruct" end,
        GetFullName = function() return "ScriptStruct " .. shape.path end,
        GetFName = function() return world.name(leaf(shape.path)) end,
        ForEachProperty = function(_, fn) walk(shape.fields, fn) end,
        GetSuperStruct = function()
            if not shape.super then return world.INVALID end
            return strict("a struct from GetSuperStruct()", {
                IsValid = function() return true end,
                GetFullName = function() return "ScriptStruct " .. shape.super end,
            })
        end,
    })
end

-- Declares a struct that StaticFindObject finds by its path. `fields` is a list of { name, property class, struct = path, inner = property class }.
function values.struct(path, super, fields)
    local shape = { path = path, super = super, fields = {} }
    for i, field in ipairs(fields or {}) do shape.fields[i] = normal(field[1], field[2], field) end
    structs[path] = shape
    world.static[path] = struct_object(shape)
    return shape
end

local function fields_of(path)
    local all, at = {}, structs[path]
    if not at then error("fake_values: no struct was declared at " .. tostring(path), 0) end
    while at do
        for _, field in ipairs(at.fields) do
            if not all[field.name] then all[field.name] = field end
        end
        at = at.super and structs[at.super] or nil
    end
    return all
end

local take

-- A struct given as a table: each field is looked up under its exact name, a key the struct lacks is dropped unseen.
local function take_struct(spec, value, current, what)
    local all, out = fields_of(spec.struct), {}
    for key, item in pairs(current or {}) do out[key] = item end
    for key, item in pairs(value) do
        local field = type(key) == "string" and all[key] or nil
        if field then
            out[key] = take(field, item, out[key], what .. "." .. key, true)
        else
            note("dropped", ("%s.%s is not a field of %s, so the engine never saw it"):format(what, tostring(key), leaf(spec.struct)))
        end
    end
    return out
end

-- One value as the pusher of its property class takes it. `nested` is a value inside a struct given as a table.
function take(spec, value, current, what, nested)
    local kind, seen, fake = spec.type, seen_as(value), kind_of(value)
    if INTS[kind] then
        local whole = (seen == "number" or seen == "string") and math.tointeger(tonumber(value)) or nil
        if whole then return whole end
        note("silent", ("%s was given %s and the engine made it 0"):format(what, seen == "number" and tostring(value) or seen))
        return 0
    elseif FLOATS[kind] then
        local number = (seen == "number" or seen == "string") and tonumber(value) or nil
        if number then return number end
        note("silent", ("%s was given a %s and the engine made it 0"):format(what, seen))
        return 0
    elseif kind == "BoolProperty" then
        if seen ~= "boolean" then note("silent", ("%s was given a %s and the engine made it %s"):format(what, seen, tostring(value ~= nil))) end
        return value ~= nil and value ~= false
    elseif kind == "NameProperty" or kind == "TextProperty" then
        local wanted = kind == "NameProperty" and "FName" or "FText"
        if fake == wanted then return value end
        crash(("%s was given a %s where the engine reads %s userdata without looking"):format(what, fake or seen, wanted))
    elseif kind == "StrProperty" then
        if seen == "string" then return value end
        if fake == "FString" then return value:ToString() end
        error("StrProperty can only be set to a string or FString", 0)
    elseif kind == "ObjectProperty" or kind == "ClassProperty" then
        if seen == "userdata" then
            if OBJECTS[fake] then return value end
            crash(("%s was given %s userdata, which the engine reads as an object"):format(what, fake))
        end
        if value == nil then
            if kind == "ClassProperty" then return current end
            return world.INVALID
        end
        error("Value must be UObject or nil", 0)
    elseif kind == "StructProperty" then
        if value == nil then return current end
        if seen == "userdata" then
            if nested then crash(what .. " was given a struct userdata inside a struct table: UE4SS reads another stack slot for it") end
            if fake ~= "UScriptStruct" or rawget(value, "__struct") ~= spec.struct then
                error(("Can't copy struct of type %s into %s"):format(tostring(rawget(value, "__struct")), leaf(spec.struct)), 0)
            end
            return take_struct(spec, rawget(value, "__props"), current, what)
        end
        if seen == "table" then return take_struct(spec, value, current, what) end
        error("Parameter must be of type 'StructProperty' or table", 0)
    elseif kind == "ArrayProperty" then
        if fake == "TArray" then
            local out = {}
            for i, item in ipairs(rawget(value, "__props")) do out[i] = item end
            return out
        end
        if seen == "table" then
            if nested then crash(what .. " was given a list inside a struct table: UE4SS drops the struct from the stack and the call goes wrong") end
            local out = {}
            for i = 1, #value do
                out[i] = take({ name = "element", type = spec.inner, struct = spec.struct }, value[i], nil, ("%s[%d]"):format(what, i), false)
            end
            return out
        end
        if value == nil then return {} end
        error("Parameter must be of type 'TArray' or table", 0)
    elseif kind == "MapProperty" or kind == "SetProperty" then
        if seen == "table" and nested then crash(what .. " was given a table for a map or set inside a struct table") end
        return value
    elseif kind == "DelegateProperty" then
        if seen == "table" then crash(what .. " was given a table for a delegate") end
        return nil
    elseif kind == "WeakObjectProperty" or kind == "InterfaceProperty" then
        if value == nil or OBJECTS[fake] then return value end
        error("Value must be UObject or nil", 0)
    elseif kind == "SoftObjectProperty" or kind == "SoftClassProperty" then
        if seen == "userdata" then return value end
        crash(("%s was given a %s where the engine reads soft reference userdata without looking"):format(what, seen))
    end
    error(("Property type '%s' not supported"):format(tostring(kind)), 0)
end

local function declared(class, list, name)
    local at = class
    while at do
        local found = rawget(at, list)[name]
        if found ~= nil then return found end
        at = rawget(at, "__super")
    end
    return nil
end

-- A call as call_ufunction_from_lua makes it. A scalar out parameter takes the table on top without removing it,
-- so the parameter after it reads that table too and every later argument arrives one place early.
local function call(object, object_name, name, def, ...)
    local given = table.pack(...)
    if given.n ~= #def then
        error(("[UFunction::setup_metamethods -> __call] UFunction expected %d parameters, received %d"):format(#def, given.n), 0)
    end
    local head, args, outs = 1, {}, {}
    for _, entry in ipairs(def) do
        local spec = normal(entry[1], entry[2], entry)
        local whole = spec.type == "StructProperty" or spec.type == "ArrayProperty"
        if spec.out then
            if seen_as(given[head]) ~= "table" then
                error("Tried storing reference to a Lua table for an 'Out' parameter when calling a UFunction but no table was on the stack", 0)
            end
            outs[#outs + 1] = { spec = spec, into = given[head] }
        end
        if whole or not spec.out then
            args[spec.name] = take(spec, given[head], nil, ("%s:%s(%s)"):format(object_name, name, spec.name), false)
            head = head + 1
        end
    end
    local result, written = nil, nil
    if def.call then result, written = def.call(object, args) end
    for _, out in ipairs(outs) do
        local value = written and written[out.spec.name]
        if out.spec.type == "StructProperty" then
            for key, item in pairs(value or {}) do out.into[key] = item end
        elseif out.spec.type == "ArrayProperty" then
            for i, item in ipairs(value or {}) do
                out.into[i] = { get = function() return item end, type = function() return "RemoteUnrealParam" end }
            end
        else
            out.into[out.spec.name] = value
        end
    end
    return result
end

-- A class as world.class makes it, with properties and functions that hand out what UE4SS does.
-- A function is { { "Param", "IntProperty" }, { "Item", "StructProperty", struct = path }, { "Slot", "IntProperty", out = true },
-- returns = "BoolProperty", call = function(self, args) return result, { Slot = 3 } end }.
function values.class(path, super, members, functions)
    local class = world.class(path, super, members, functions)
    rawset(class, "ForEachProperty", function(self, fn)
        local list = {}
        for name, spec in pairs(rawget(self, "__members")) do list[#list + 1] = normal(name, spec) end
        table.sort(list, function(a, b) return a.name < b.name end)
        walk(list, fn)
    end)
    rawset(class, "ForEachFunction", function(self, fn)
        for name, def in pairs(rawget(self, "__functions")) do
            fn(strict("the function " .. name, {
                IsValid = function() return true end,
                GetFName = function() return world.name(name) end,
                GetFullName = function() return "Function " .. path .. ":" .. name end,
                ForEachProperty = function(_, each)
                    local list = {}
                    for i, entry in ipairs(def) do list[i] = normal(entry[1], entry[2], entry) end
                    if def.returns then list[#list + 1] = normal("ReturnValue", def.returns) end
                    walk(list, each)
                end,
            }))
        end
    end)
    return class
end

-- The properties of one object: a write goes through the pusher of the property's class, a read gives what the engine holds.
local function typed(class, name, initial)
    local store, callers = {}, {}
    for key, value in pairs(initial or {}) do store[key] = value end
    local props = setmetatable({}, {
        __index = function(_, key)
            local value = store[key]
            if value ~= nil then return value end
            local def = declared(class, "__functions", key)
            if not def then return nil end
            callers[key] = callers[key] or function(self, ...) return call(self, name, key, def, ...) end
            return callers[key]
        end,
        __newindex = function(_, key, value)
            local spec = declared(class, "__members", key)
            if spec == nil then
                store[key] = value
                return
            end
            store[key] = take(normal(key, spec), value, store[key], name .. "." .. key, false)
        end,
    })
    return props, store
end

-- An actor of the world whose properties and functions take values as the game does. Returns it and what the engine holds for it.
function values.actor(class, name, initial, components)
    local props, store = typed(class, name, initial)
    local actor = world.place(class, name, props, components)
    stores[actor] = store
    return actor, store
end

-- The same for a component or any other object.
function values.part(class, name, initial)
    local props, store = typed(class, name, initial)
    local object = world.component(class, name, props)
    stores[object] = store
    return object, store
end

-- What the engine holds for an object made here: property name -> value.
function values.of(object) return stores[object] end

-- A struct value as a property read hands it out. It is only taken whole, never inside a table.
function values.struct_value(path, fields)
    return setmetatable({ __props = fields or {}, __kind = "UScriptStruct", __struct = path }, TEXT)
end

-- What the engine holds, as plain Lua: names and texts as strings.
function values.plain(value)
    local kind = kind_of(value)
    if kind == "FName" or kind == "FText" or kind == "FString" then return value:ToString() end
    if seen_as(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = values.plain(item) end
    return out
end

values.name = function(text) return text_value("FName", text) end
values.text = function(text) return text_value("FText", text) end

-- Call after world.install(). Engine values made by the fakes answer type() with "userdata" from here on.
function values.install(the_world)
    world = the_world
    world.as_userdata()
    FName, FText = values.name, values.text
    local find = StaticFindObject
    function StaticFindObject(path)
        values.finds = values.finds + 1
        if world.static[path] == nil then values.misses = values.misses + 1 end
        return find(path)
    end
end

return values
