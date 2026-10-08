-- What each class has: its properties and functions, read from the engine's own reflection data and cached

local Wax = ...

local reflect = {}

-- class address -> info. Blueprint classes are unloaded on a map change, so the whole cache is flushed then.
local by_class = {}
local oversized = nil       -- function path -> parameter block size, for functions UE4SS cannot call safely

local function name_of(object) return object:GetFName():ToString() end
-- names are compared without letter case and without a space at the end
local function folded(path) return (path:lower():gsub("%s+$", "")) end

local function own_members(class, members, list)
    class:ForEachProperty(function(property)
        local name = name_of(property)
        if not members[name] then list[#list + 1] = name end
        members[name] = { kind = "property", type = name_of(property:GetClass()) }
    end)
    class:ForEachFunction(function(fn)
        local name = name_of(fn)
        if not members[name] then list[#list + 1] = name end
        members[name] = { kind = "function", fn = fn }
    end)
end

-- Members and ancestry of a class, cached per class
function reflect.class_info(class)
    local key = class:GetAddress()
    local info = by_class[key]
    if info then return info end

    local name = name_of(class)
    info = { name = name, path = class:GetFullName(), chain = { name }, ancestors = { [name] = true }, members = {}, list = {} }
    local parent = class:GetSuperStruct()
    if parent:IsValid() then
        -- Start from the parent's members, then let this class's own definitions override them.
        local inherited = reflect.class_info(parent)
        for i = 1, #inherited.chain do
            info.chain[#info.chain + 1] = inherited.chain[i]
            info.ancestors[inherited.chain[i]] = true
        end
        for member, record in pairs(inherited.members) do info.members[member] = record end
        for i = 1, #inherited.list do info.list[i] = inherited.list[i] end
    end
    own_members(class, info.members, info.list)
    by_class[key] = info
    return info
end

-- The parameters of a function, in call order, without the return value
function reflect.parameters(member)
    if member.params then return member.params end
    local params = {}
    member.fn:ForEachProperty(function(property)
        local name = name_of(property)
        if name ~= "ReturnValue" then
            params[#params + 1] = { name = name, type = name_of(property:GetClass()) }
        end
    end)
    member.params = params
    return params
end

-- Size of the function's parameter block if it is known to exceed what UE4SS can call safely, else nil.
function reflect.oversized(member)
    if member.oversized ~= nil then return member.oversized or nil end
    if not oversized then
        local chunk = loadfile(Wax.root .. "/data/oversized_functions.lua")
        oversized = {}
        for listed, size in pairs(chunk and chunk() or {}) do
            local key = folded(listed)
            oversized[key] = math.max(oversized[key] or 0, size)
        end
    end
    local path = folded((member.fn:GetFullName():gsub("^%S+%s+", "")))     -- "Function /Script/X.Y:Z" -> "/script/x.y:z"
    member.oversized = oversized[path] or false
    return member.oversized or nil
end

function reflect.flush() by_class = {} end

function reflect.cached_classes()
    local n = 0
    for _ in pairs(by_class) do n = n + 1 end
    return n
end

return reflect
