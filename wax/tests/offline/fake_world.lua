-- A small stand-in for the engine's world: classes, actors, components and data tables.
-- An object that was freed raises on any use, which is how the tests prove nothing touches one.

local world = { dead_touches = 0, touches = 0, static = {}, actors = {}, began = nil, ended = nil, watch = nil }

local PENDING_KILL = 0x20000000
local next_address = 0x10000
local name_indexes, name_count = {}, 0

local function name_index(text)
    local key = text:lower()
    if not name_indexes[key] then
        name_count = name_count + 1
        name_indexes[key] = name_count
    end
    return name_indexes[key]
end

function world.name(text)
    return { ToString = function() return text end, GetComparisonIndex = function() return name_index(text) end }
end

local INVALID = setmetatable({ __invalid = true }, { __index = function(_, key)
    if key == "IsValid" then return function() return false end end
    if key == "type" then return function() return "UObject" end end
    error("used an invalid object (" .. tostring(key) .. ")", 2)
end })
world.INVALID = INVALID

local methods = {}
local Object = {}
Object.__index = function(self, key)
    if rawget(self, "__freed") then
        world.dead_touches = world.dead_touches + 1
        if world.dead_touches == 1 then world.dead_where = tostring(rawget(self, "__name")) .. "." .. tostring(key) .. debug.traceback("", 2) end
        error("touched a freed object (" .. tostring(key) .. ")", 2)
    end
    world.touches = world.touches + 1
    local method = methods[key]
    if method then return method end
    local props = rawget(self, "__props")
    -- world.watch = {} counts how often each property is read
    local watch = world.watch
    if watch then watch[key] = (watch[key] or 0) + 1 end
    local value = props[key]
    if value ~= nil then return value end
    if rawget(self, "__kind") == "TArray" and key == #props + 1 then
        props[key] = { Weight = 0, Object = INVALID }
        return props[key]
    end
    return INVALID
end
Object.__newindex = function(self, key, value)
    if rawget(self, "__freed") then
        world.dead_touches = world.dead_touches + 1
        error("wrote to a freed object (" .. tostring(key) .. ")", 2)
    end
    rawget(self, "__props")[key] = value
end

local function new(class, name, props, kind)
    next_address = next_address + 0x100
    return setmetatable({ __class = class, __name = name, __address = next_address, __props = props or {},
                          __kind = kind or "UObject", __flags = 0 }, Object)
end

function methods.IsValid() return true end
function methods.GetAddress(self) return rawget(self, "__address") end
function methods.GetFName(self) return world.name(rawget(self, "__name")) end
function methods.GetClass(self) return rawget(self, "__class") end
function methods.GetOuter(self) return rawget(self, "__outer") or INVALID end
function methods.GetOwner(self) return rawget(self, "__outer") or INVALID end
function methods.type(self) return rawget(self, "__kind") end
function methods.HasAnyInternalFlags(self, flag) return rawget(self, "__flags") & flag ~= 0 end
function methods.GetFullName(self) return "Class " .. (rawget(self, "__path") or rawget(self, "__name")) end
function methods.GetSuperStruct(self) return rawget(self, "__super") or INVALID end
function methods.IsA(self, class)
    local mine = rawget(self, "__class")
    while mine do
        if mine == class then return true end
        mine = rawget(mine, "__super")
    end
    return false
end
-- A property as reflection hands it out. `spec` is a type name, or { type name, struct = "Vector" } or { type name, inner = type name }.
local function property(name, spec)
    local type_name = type(spec) == "table" and spec[1] or spec
    local detail = type(spec) == "table" and spec or {}
    local function named(text) return { GetFName = function() return world.name(text) end } end
    return {
        GetFName = function() return world.name(name) end,
        GetClass = function() return named(type_name) end,
        GetStruct = function()
            if not detail.struct then error("this property holds no struct", 2) end
            return named(detail.struct)
        end,
        GetInner = function()
            if not detail.inner then error("this property holds no array", 2) end
            return { GetClass = function() return named(detail.inner) end }
        end,
    }
end

function methods.ForEachProperty(self, fn)
    for name, spec in pairs(rawget(self, "__members") or {}) do fn(property(name, spec)) end
end
-- A class's functions: name -> a list of { parameter name, type name }.
function methods.ForEachFunction(self, fn)
    local path = rawget(self, "__path") or rawget(self, "__name")
    for name, params in pairs(rawget(self, "__functions") or {}) do
        fn({
            GetFName = function() return world.name(name) end,
            GetFullName = function() return "Function " .. tostring(path) .. ":" .. name end,
            ForEachProperty = function(_, each)
                for _, param in ipairs(params) do each(property(param[1], param[2])) end
            end,
        })
    end
end
function methods.ForEach(self, fn)
    local props = rawget(self, "__props")
    for index = 1, #props do
        if fn(index, { get = function() return props[index] end, type = function() return "RemoteUnrealParam" end }) then break end
    end
end
function methods.GetAttachedActors(self, out)
    for _, actor in ipairs(rawget(self, "__attached") or {}) do
        out[#out + 1] = { get = function() return actor end, type = function() return "RemoteUnrealParam" end }
    end
end
function methods.K2_GetActorLocation(self)
    local at = rawget(self, "__props").Location
    return { X = at[1], Y = at[2], Z = at[3] }
end
function methods.K2_GetComponentsByClass(self, class)
    local out = {}
    for _, component in ipairs(rawget(self, "__components") or {}) do
        if component:IsA(class) then
            out[#out + 1] = { get = function() return component end, type = function() return "RemoteUnrealParam" end }
        end
    end
    return out
end
function methods.SetVectorParameterValue(self, name, value) rawget(self, "__props")[name] = value end
function methods.SetScalarParameterValue(self, name, value) rawget(self, "__props")[name] = value end
function methods.CreateDynamicMaterialInstance(_, _, parent)
    world.copies = (world.copies or 0) + 1
    return new(nil, "MaterialInstanceDynamic_" .. world.copies, { Parent = parent })
end
function methods.GetArrayNum(self) return #rawget(self, "__props") end
function methods.SetRenderCustomDepth(self, on) rawget(self, "__props").bRenderCustomDepth = on end
function methods.SetCustomDepthStencilValue(self, value) rawget(self, "__props").CustomDepthStencilValue = value end

-- A class. `members` maps property names to property type names (see `property` above), `functions` maps names to parameter lists.
function world.class(path, super, members, functions)
    local name = path:match("([^%.:/]+)$")
    local class = new(nil, name, {}, "UClass")
    rawset(class, "__path", path)
    rawset(class, "__super", super)
    rawset(class, "__members", members or {})
    rawset(class, "__functions", functions or {})
    world.static[path] = class
    return class
end

-- Makes these objects answer type() with "userdata", as the engine's do, so reads through an Instance convert them.
function world.as_userdata()
    local real = type
    rawset(_G, "type", function(value)
        local kind = real(value)
        if kind == "table" and (rawget(value, "__props") ~= nil or rawget(value, "__invalid")) then return "userdata" end
        return kind
    end)
end

-- Attaches one actor to another, the way GetAttachedActors reports it.
function world.attach(child, parent)
    local list = rawget(parent, "__attached") or {}
    list[#list + 1] = child
    rawset(parent, "__attached", list)
end

function world.table(path, rows, order)
    local data = { IsValid = function() return true end }
    function data:GetRowNames() return order end
    function data:FindRow(name)
        for key, row in pairs(rows) do
            if key:lower() == name:lower() then return row end
        end
        return nil
    end
    world.static[path] = data
    return data
end

function world.handle(row) return { RowName = world.name(row) } end

-- Makes an actor without telling anyone, as one that was in the world before tracking started.
function world.place(class, name, props, components)
    local actor = new(class, name, props, "AActor")
    rawset(actor, "__components", components or {})
    for _, component in ipairs(components or {}) do rawset(component, "__outer", actor) end
    world.actors[#world.actors + 1] = actor
    return actor
end

function world.component(class, name, props)
    return new(class, name, props)
end

function world.spawn(class, name, props, components)
    local actor = world.place(class, name, props, components)
    if world.began then world.began({ get = function() return actor end }) end
    return actor
end

-- Ends play. The object stays readable until world.free, like an actor waiting for garbage collection.
function world.destroy(actor, reason)
    if world.ended then
        world.ended({ get = function() return actor end }, { get = function() return reason or 0 end })
    end
    rawset(actor, "__flags", PENDING_KILL)
end

function world.free(actor)
    rawset(actor, "__freed", true)
    for _, component in ipairs(rawget(actor, "__components") or {}) do rawset(component, "__freed", true) end
    for i = #world.actors, 1, -1 do
        if world.actors[i] == actor then table.remove(world.actors, i) end
    end
end

-- An engine array: numbered values plus GetArrayNum.
function world.array(values) return new(nil, "Array", values, "TArray") end

function world.object(name, props) return new(nil, name, props) end

-- Makes `pawn` the local player's character, the way game.Character finds it.
function world.possess(pawn)
    if world.controller then
        world.controller.Pawn = pawn or INVALID
        return
    end
    local controller = world.object("PlayerController_0", { Pawn = pawn or INVALID })
    world.controller = controller
    local player = world.object("LocalPlayer_0", { PlayerController = controller })
    local game_instance = world.object("GameInstance_0", { LocalPlayers = world.array({ player }) })
    local level = world.object("World_0", {})
    world.engine = world.object("Engine_0", { GameViewport = world.object("Viewport_0", { World = level, GameInstance = game_instance }) })
end

function world.install()
    function StaticFindObject(path) return world.static[path] or INVALID end
    function FindAllOf(class_name)
        local out = {}
        for _, actor in ipairs(world.actors) do
            local class = rawget(actor, "__class")
            while class do
                if rawget(class, "__name") == class_name then
                    out[#out + 1] = actor
                    break
                end
                class = rawget(class, "__super")
            end
        end
        return #out > 0 and out or nil
    end
    function FindFirstOf(name) return name == "Engine" and world.engine or INVALID end
    function RegisterBeginPlayPostHook(fn) world.began = fn end
    function RegisterEndPlayPreHook(fn) world.ended = fn end
    function FName(text) return text end
end

return world
