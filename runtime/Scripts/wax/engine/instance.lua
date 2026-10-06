-- Instances: what mods get in place of raw engine objects, with every read, write and call checked

local Wax = ...
local reflect = Wax.import("engine.reflect")
local suggest = Wax.import("core.suggest")
local sched = Wax.import("core.sched")

local M = {}

-- Private fields are stored under table keys, which mod code cannot name.
local OBJ, INFO, NAME_INDEX, CLASS_ADDRESS, CHECKED, ADDRESS, WORLD, GONE = {}, {}, {}, {}, {}, {}, {}, {}
local generation = 0        -- goes up on every map change

local Instance = {}                                     -- the methods every Instance has
local meta = {}
local cache = setmetatable({}, { __mode = "v" })        -- address -> Instance
local attributes = {}                                   -- address -> { name_index, class_address, values, tags, signals }
local parts = {}                                        -- actor address -> the Instances of its components
local tagged
local stats = sched.stats

local PENDING_KILL = EInternalObjectFlags and EInternalObjectFlags.PendingKill or 0x20000000
local OBJECT_KINDS = { UObject = true, AActor = true, UClass = true, UFunction = true, UEnum = true, UWorld = true, UDataTable = true }
local TEXT_KINDS = { FName = true, FString = true, FText = true, FAnsiString = true, FUtf8String = true }
local PARAM_KINDS = { RemoteUnrealParam = true, LocalUnrealParam = true }

local actor_class, scene_component_class, component_class, world_class

local function kind_of(value)
    local ok, kind = pcall(function() return value:type() end)
    return ok and kind or nil
end

local function describe_dead(self)
    return ("this %s no longer exists (it was destroyed, or the map changed)"):format(rawget(self, INFO).name)
end

-- Returns the engine object, raising if it is gone
local function live(self, level)
    if rawget(self, GONE) then error(describe_dead(self), (level or 2) + 1) end
    local object = rawget(self, OBJ)
    if rawget(self, WORLD) ~= generation then
        error("this object is from before the last map change. Get it again from `game`", (level or 2) + 1)
    end
    if rawget(self, CHECKED) == stats.frame then return object end
    if not object:IsValid() or object:HasAnyInternalFlags(PENDING_KILL)
        or object:GetFName():GetComparisonIndex() ~= rawget(self, NAME_INDEX)
        or object:GetClass():GetAddress() ~= rawget(self, CLASS_ADDRESS) then
        error(describe_dead(self), (level or 2) + 1)
    end
    rawset(self, CHECKED, stats.frame)
    return object
end

local function is_live(self) return (pcall(live, self)) end

-- The Instance for an engine object, or nil for a null/invalid one. One Instance per object.
local function wrap(object)
    if object == nil or not object:IsValid() then return nil end
    local address = object:GetAddress()
    local name_index = object:GetFName():GetComparisonIndex()
    local class = object:GetClass()
    local class_address = class:GetAddress()
    local existing = cache[address]
    if existing and rawget(existing, NAME_INDEX) == name_index and rawget(existing, CLASS_ADDRESS) == class_address then
        return existing
    end
    local self = setmetatable({
        [OBJ] = object, [INFO] = reflect.class_info(class), [NAME_INDEX] = name_index,
        [CLASS_ADDRESS] = class_address, [CHECKED] = stats.frame, [ADDRESS] = address, [WORLD] = generation,
    }, meta)
    cache[address] = self
    if self[INFO].ancestors.ActorComponent then
        local owner = object:GetOuter()
        if owner:IsValid() then
            local key = owner:GetAddress()
            local list = parts[key]
            if not list then
                list = setmetatable({}, { __mode = "k" })
                parts[key] = list
            end
            list[self] = true
        end
    end
    return self
end
M.wrap = wrap

-- Recognised by the private field, not by getmetatable: the metatable is protected, so getmetatable returns a label.
local function is_instance(value) return type(value) == "table" and rawget(value, OBJ) ~= nil end
M.is_instance = is_instance

-- The engine address an Instance was made for. Asks the engine nothing, so it is safe for one that is gone.
function M.address(self) return rawget(self, ADDRESS) end

local function retire_one(self)
    rawset(self, GONE, true)
    local address = rawget(self, ADDRESS)
    if cache[address] == self then cache[address] = nil end
    local store = attributes[address]
    if store and store.instance == self then
        for tag in pairs(store.tags) do
            if tagged[tag] then tagged[tag][address] = nil end
        end
        attributes[address] = nil
    end
end

-- Called when an actor ends play: its Instance and its components' Instances answer with an error from now on.
function M.retire(address)
    local self = cache[address]
    if self then retire_one(self) end
    local list = parts[address]
    if list then
        parts[address] = nil
        for part in pairs(list) do retire_one(part) end
    end
end

-- engine values -> Lua values
local to_lua

local function array_to_lua(array)
    local out = {}
    -- ForEach, never ipairs: reading an engine array past its end grows it, so ipairs would not terminate.
    array:ForEach(function(index, element) out[index] = to_lua(element:get()) end)
    return out
end

function to_lua(value)
    local t = type(value)
    if t == "table" then
        -- A function result that is an array arrives as a Lua table of parameter handles.
        if PARAM_KINDS[kind_of(value[1])] then
            local out = {}
            for i = 1, #value do out[i] = to_lua(value[i]:get()) end
            return out
        end
        return value
    end
    if t ~= "userdata" then return value end
    local kind = kind_of(value)
    if OBJECT_KINDS[kind] then return wrap(value) end
    if TEXT_KINDS[kind] then return value:ToString() end
    if kind == "TArray" then return array_to_lua(value) end
    if PARAM_KINDS[kind] then return to_lua(value:get()) end
    return value        -- structs, maps, sets, delegates, soft references: handed over as they are
end
M.to_lua = to_lua

-- Lua values -> what a member expects
local INTEGER_TYPES = {
    Int8Property = true, Int16Property = true, IntProperty = true, Int64Property = true, ByteProperty = true,
    UInt16Property = true, UInt32Property = true, UInt64Property = true, EnumProperty = true,
}
local NUMBER_TYPES = { FloatProperty = true, DoubleProperty = true }
local REFUSED_TYPES = {
    DelegateProperty = "assigning a delegate from Lua crashes the game",
    MulticastInlineDelegateProperty = "delegates are connected with :Connect on the signal, not assigned",
    MulticastSparseDelegateProperty = "delegates are connected with :Connect on the signal, not assigned",
    MulticastDelegateProperty = "delegates are connected with :Connect on the signal, not assigned",
}
local RAW_ONLY_TYPES = {
    WeakObjectProperty = true, SoftObjectProperty = true, SoftClassProperty = true, InterfaceProperty = true,
    MapProperty = true, SetProperty = true, FieldPathProperty = true, LazyObjectProperty = true,
}

-- A table is safe to hand over as a struct when it holds only numbers, booleans and tables of those.
local function plain_numbers(value, depth)
    if depth > 4 then return false end
    for key, item in pairs(value) do
        if type(key) ~= "string" then return false end
        local t = type(item)
        if t == "table" then
            if not plain_numbers(item, depth + 1) then return false end
        elseif t ~= "number" and t ~= "boolean" then
            return false
        end
    end
    return true
end

-- Converts `value` for a slot of the given property type. `what` describes the slot for error messages.
local function to_engine(value, property_type, what)
    local t = type(value)
    if is_instance(value) then
        if property_type ~= "ObjectProperty" and property_type ~= "ClassProperty" then
            error(("%s expects %s, got an Instance"):format(what, property_type), 0)
        end
        return live(value, 3)
    end
    local refused = REFUSED_TYPES[property_type]
    if refused then error(("%s cannot be set: %s"):format(what, refused), 0) end
    if RAW_ONLY_TYPES[property_type] then
        if t == "userdata" then return value end
        error(("%s is a %s, which Wax does not convert yet. Pass the engine value itself (see .Raw)"):format(what, property_type), 0)
    end
    if property_type == "NameProperty" then
        if t == "string" then return FName(value) end
        if t == "userdata" and kind_of(value) == "FName" then return value end
        error(("%s expects a name (a string), got %s"):format(what, t), 0)
    elseif property_type == "TextProperty" then
        if t == "string" then return FText(value) end
        if t == "userdata" and kind_of(value) == "FText" then return value end
        error(("%s expects text (a string), got %s"):format(what, t), 0)
    elseif property_type == "StrProperty" then
        if t == "string" then return value end
        if t == "number" then return tostring(value) end
        error(("%s expects a string, got %s"):format(what, t), 0)
    elseif property_type == "BoolProperty" then
        if t == "boolean" then return value end
        -- The engine would accept anything here, and treats 0 as true.
        error(("%s expects true or false, got %s"):format(what, t), 0)
    elseif INTEGER_TYPES[property_type] then
        if t == "number" then
            local whole = math.tointeger(value)
            if whole then return whole end
            error(("%s expects a whole number, got %s"):format(what, tostring(value)), 0)
        end
        error(("%s expects a whole number, got %s"):format(what, t), 0)
    elseif NUMBER_TYPES[property_type] then
        if t == "number" then return value end
        error(("%s expects a number, got %s"):format(what, t), 0)
    elseif property_type == "ObjectProperty" or property_type == "ClassProperty" then
        if value == nil and property_type == "ObjectProperty" then return nil end
        if t == "userdata" then return value end
        error(("%s expects an Instance, got %s"):format(what, t), 0)
    elseif property_type == "StructProperty" then
        if t == "userdata" then return value end
        if t == "table" and plain_numbers(value, 1) then return value end
        error(("%s expects a struct: a table of numbers such as { X = 0, Y = 0, Z = 0 }, or an engine struct"):format(what), 0)
    elseif property_type == "ArrayProperty" then
        if t == "userdata" then return value end
        if t == "table" then
            local out = {}
            for i = 1, #value do
                local item = value[i]
                local item_type = type(item)
                if is_instance(item) then
                    out[i] = live(item, 3)
                elseif item_type == "number" or item_type == "boolean" or item_type == "userdata" then
                    out[i] = item
                else
                    error(("%s: array element %d is a %s. Arrays of text need engine values (see .Raw)"):format(what, i, item_type), 0)
                end
            end
            return out
        end
        error(("%s expects an array (a table), got %s"):format(what, t), 0)
    end
    return value
end

-- members: read, write, call
local function unknown_member(self, name, verb)
    local info = rawget(self, INFO)
    return ("%s is not %s of %s.%s"):format(tostring(name), verb, info.name, suggest.phrase(tostring(name), info.list))
end

local function read_property(self, name)
    return to_lua(live(self, 3)[name])
end

local function write_property(self, name, member, value)
    local object = live(self, 3)
    local info = rawget(self, INFO)
    local ok, converted = pcall(to_engine, value, member.type, info.name .. "." .. name)
    if not ok then error(converted, 3) end
    object[name] = converted
end

local function call_function(self, name, member, ...)
    local object = live(self, 3)
    local info = rawget(self, INFO)
    local size = reflect.oversized(member)
    if size then
        error(("%s:%s cannot be called from Lua: its parameters take %d bytes and UE4SS's call buffer holds 512, "
            .. "so the call would crash the game"):format(info.name, name, size), 3)
    end
    local params = reflect.parameters(member)
    local count = select("#", ...)
    local args = table.pack(...)
    for i = 1, count do
        local param = params[i]
        -- nil stays nil (optional object arguments). Tables for an out-parameter pass through unchanged.
        if param and args[i] ~= nil then
            local ok, converted = pcall(to_engine, args[i], param.type, ("%s:%s argument %d (%s)"):format(info.name, name, i, param.name))
            if not ok then error(converted, 3) end
            args[i] = converted
        end
    end
    return to_lua(object[name](object, table.unpack(args, 1, count)))
end

-- Reflected members by name, for a class whose own member has a name Wax also uses (such as "Name").
function Instance:Get(name)
    local member = rawget(self, INFO).members[name]
    if not member or member.kind ~= "property" then error(unknown_member(self, name, "a property"), 2) end
    return read_property(self, name)
end

function Instance:Set(name, value)
    local member = rawget(self, INFO).members[name]
    if not member or member.kind ~= "property" then error(unknown_member(self, name, "a property"), 2) end
    write_property(self, name, member, value)
end

function Instance:Call(name, ...)
    local member = rawget(self, INFO).members[name]
    if not member or member.kind ~= "function" then error(unknown_member(self, name, "a function"), 2) end
    return call_function(self, name, member, ...)
end

-- identity and the tree
function Instance:IsValid() return is_live(self) end

-- True when the object's class is, or inherits from, the named class ("Actor", "BP_IcarusPlayerCharacterSurvival_C").
function Instance:IsA(class_name) return rawget(self, INFO).ancestors[class_name] == true end

-- The class names from this object's own class up to Object.
function Instance:GetClassChain()
    local chain = rawget(self, INFO).chain
    return table.move(chain, 1, #chain, 1, {})
end

-- Every property and function name this object has.
function Instance:GetMembers()
    local list = rawget(self, INFO).list
    local out = table.move(list, 1, #list, 1, {})
    table.sort(out)
    return out
end

local function same_actor(component_a, component_b)
    return component_a:GetOuter():GetAddress() == component_b:GetOuter():GetAddress()
end

-- The actor this actor is attached to, or nil
local function attached_to(actor)
    local root = actor.RootComponent
    if not root:IsValid() then return nil end
    local attach_parent = root.AttachParent
    if not attach_parent:IsValid() then return nil end
    local owner = attach_parent:GetOuter()
    if owner:IsValid() and owner:IsA(actor_class) then return owner end
    return nil
end
M.attached_to = attached_to

local function parent_of(object)
    if object:IsA(actor_class) then
        return attached_to(object) or M.world_object()
    end
    if object:IsA(scene_component_class) then
        local attach_parent = object.AttachParent
        if attach_parent:IsValid() and same_actor(attach_parent, object) then return attach_parent end
    end
    return object:GetOuter()
end

function Instance:GetParent() return wrap(parent_of(live(self))) end

-- Children: actors for the world, components and attached actors for an actor, attached components for a component
function Instance:GetChildren()
    local object, out = live(self), {}
    if object:IsA(world_class) then
        for _, actor in ipairs(M.world_actors(object)) do
            if not attached_to(actor) then out[#out + 1] = wrap(actor) end
        end
    elseif object:IsA(actor_class) then
        local components = object:K2_GetComponentsByClass(component_class)
        for i = 1, #components do
            local component = components[i]:get()
            if component:IsValid() then
                local nested = component:IsA(scene_component_class) and component.AttachParent:IsValid()
                    and same_actor(component.AttachParent, component)
                if not nested then out[#out + 1] = wrap(component) end
            end
        end
        local attached = {}
        object:GetAttachedActors(attached, true)
        for i = 1, #attached do
            local actor = attached[i]:get()
            if actor:IsValid() then out[#out + 1] = wrap(actor) end
        end
    elseif object:IsA(scene_component_class) then
        object.AttachChildren:ForEach(function(_, element)
            local child = element:get()
            if child:IsValid() and same_actor(child, object) then out[#out + 1] = wrap(child) end
        end)
    end
    return out
end

function Instance:FindFirstChild(name, recursive)
    local children = recursive and self:GetDescendants() or self:GetChildren()
    for i = 1, #children do
        if children[i].Name == name then return children[i] end
    end
    return nil
end

-- The first child of exactly this class.
function Instance:FindFirstChildOfClass(class_name)
    local children = self:GetChildren()
    for i = 1, #children do
        if children[i].ClassName == class_name then return children[i] end
    end
    return nil
end

-- The first child of this class or a class derived from it.
function Instance:FindFirstChildWhichIsA(class_name)
    local children = self:GetChildren()
    for i = 1, #children do
        if children[i]:IsA(class_name) then return children[i] end
    end
    return nil
end

-- Every Instance below this one, nearest first. Stops at `limit` (default 5000) so a huge world cannot hang a frame.
function Instance:GetDescendants(limit)
    limit = limit or 5000
    local out, queue, head = {}, { self }, 1
    while queue[head] and #out < limit do
        local children = queue[head]:GetChildren()
        for i = 1, #children do
            if #out >= limit then break end
            out[#out + 1] = children[i]
            queue[#queue + 1] = children[i]
        end
        head = head + 1
    end
    return out
end

-- attributes and tags: your own data on any Instance
local function store_for(self, create)
    live(self, 3)
    local address = rawget(self, ADDRESS)
    local store = attributes[address]
    -- A store left by a previous object at the same address belongs to nobody.
    if store and (store.name_index ~= rawget(self, NAME_INDEX) or store.class_address ~= rawget(self, CLASS_ADDRESS)) then
        store = nil
        attributes[address] = nil
    end
    if not store and create then
        -- The store keeps its Instance, so attributes stay with the object even if the mod drops its reference.
        store = { name_index = rawget(self, NAME_INDEX), class_address = rawget(self, CLASS_ADDRESS),
                  instance = self, values = {}, tags = {} }
        attributes[address] = store
    end
    return store
end

function Instance:GetAttribute(name)
    local store = store_for(self, false)
    return store and store.values[name]
end

function Instance:GetAttributes()
    local store, out = store_for(self, false), {}
    if store then
        for name, value in pairs(store.values) do out[name] = value end
    end
    return out
end

function Instance:SetAttribute(name, value)
    if type(name) ~= "string" then error("an attribute name must be a string, got " .. type(name), 2) end
    local store = store_for(self, true)
    local previous = store.values[name]
    if previous == value then return end
    store.values[name] = value
    local signals = store.signals
    if signals then
        if signals.any then signals.any:Fire(name, value, previous) end
        if signals[name] then signals[name]:Fire(value, previous) end
    end
end

-- Fires (name, value, previous) whenever any attribute of this Instance changes.
function Instance:GetAttributeChangedSignal(name)
    local store = store_for(self, true)
    store.signals = store.signals or {}
    local key = name or "any"
    if name ~= nil and type(name) ~= "string" then error("an attribute name must be a string", 2) end
    if name == "any" then error("'any' is reserved. Call GetAttributeChangedSignal() without a name for all attributes", 2) end
    store.signals[key] = store.signals[key] or sched.Signal.new("AttributeChanged")
    return store.signals[key]
end

tagged = {}             -- tag -> { [address] = Instance }

function Instance:AddTag(tag)
    if type(tag) ~= "string" then error("a tag must be a string, got " .. type(tag), 2) end
    local store = store_for(self, true)
    store.tags[tag] = true
    tagged[tag] = tagged[tag] or {}
    tagged[tag][rawget(self, ADDRESS)] = self
end

function Instance:RemoveTag(tag)
    local store = store_for(self, false)
    if store then store.tags[tag] = nil end
    if tagged[tag] then tagged[tag][rawget(self, ADDRESS)] = nil end
end

function Instance:HasTag(tag)
    local store = store_for(self, false)
    return store ~= nil and store.tags[tag] == true
end

function Instance:GetTags()
    local store, out = store_for(self, false), {}
    if store then
        for tag in pairs(store.tags) do out[#out + 1] = tag end
        table.sort(out)
    end
    return out
end

-- Every live Instance carrying the tag.
function M.get_tagged(tag)
    local out = {}
    local set = tagged[tag]
    if set then
        for address, instance in pairs(set) do
            if is_live(instance) and instance:HasTag(tag) then out[#out + 1] = instance else set[address] = nil end
        end
    end
    return out
end

local computed = {
    Name = function(self) return live(self, 3):GetFName():ToString() end,
    ClassName = function(self) return rawget(self, INFO).name end,
    FullName = function(self) return live(self, 3):GetFullName() end,
    Parent = function(self) return wrap(parent_of(live(self, 3))) end,
    Raw = function(self) return live(self, 3) end,
}

meta.__index = function(self, key)
    local method = Instance[key]
    if method ~= nil then return method end
    local getter = computed[key]
    if getter then return getter(self) end
    local member = rawget(self, INFO).members[key]
    if not member then error(unknown_member(self, key, "a member"), 2) end
    if member.kind == "property" then return read_property(self, key) end
    -- instance:Function(...): return the function that makes the checked call
    local caller = member.caller
    if not caller then
        caller = function(receiver, ...)
            if not is_instance(receiver) then
                error(("call %s with a colon: instance:%s(...)"):format(key, key), 2)
            end
            return call_function(receiver, key, member, ...)
        end
        member.caller = caller
    end
    return caller
end

meta.__newindex = function(self, key, value)
    if Instance[key] ~= nil or computed[key] then
        error(("%s is read-only (to set a property the class itself calls '%s', use :Set(\"%s\", value))"):format(key, key, key), 2)
    end
    local member = rawget(self, INFO).members[key]
    if not member or member.kind ~= "property" then error(unknown_member(self, key, "a property"), 2) end
    write_property(self, key, member, value)
end

meta.__tostring = function(self)
    local info = rawget(self, INFO)
    if rawget(self, GONE) then return info.name .. " (destroyed)" end
    local ok, name = pcall(function() return rawget(self, OBJ):GetFName():ToString() end)
    if is_live(self) and ok then return info.name .. " " .. name end
    return info.name .. " (destroyed)"
end

meta.__eq = function(a, b) return rawget(a, ADDRESS) == rawget(b, ADDRESS) and rawget(a, NAME_INDEX) == rawget(b, NAME_INDEX) end
meta.__metatable = "Instance"

-- Replaced by engine.game when it starts: the current world object and its actors.
M.world_object = function() error("engine.game has not been started") end
M.world_actors = function() return {} end

function M.start()
    actor_class = StaticFindObject("/Script/Engine.Actor")
    component_class = StaticFindObject("/Script/Engine.ActorComponent")
    scene_component_class = StaticFindObject("/Script/Engine.SceneComponent")
    world_class = StaticFindObject("/Script/Engine.World")
end

-- Called after a map change. Nothing old is asked if it still exists (asking is what crashes): the caches are emptied instead.
function M.flush()
    generation = generation + 1
    cache = setmetatable({}, { __mode = "v" })
    attributes = {}
    tagged = {}
    parts = {}
    reflect.flush()
end

function M.stats()
    local wrapped, with_attributes = 0, 0
    for _ in pairs(cache) do wrapped = wrapped + 1 end
    for _ in pairs(attributes) do with_attributes = with_attributes + 1 end
    return { instances = wrapped, withAttributes = with_attributes, classes = reflect.cached_classes() }
end

M.Instance = Instance
return M
