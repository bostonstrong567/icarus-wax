-- What the game hands a hook: parameters a listener may read and never write, and a return value it may set

local Wax = ...
local instance = Wax.import("engine.instance")

local M = {}

M.ARRAY = "Wax refuses to write into an array the game handed a hook: " .. instance.ARRAY_REFUSED
M.WRITE = "Wax refuses to write into what the game handed a hook: " .. instance.ARRAY_REFUSED
M.OVER = "the game's call is over, and what it handed the hook is gone with it. Read it inside the listener (:get() copies a value)"
M.NO_RETURN = "this function returns nothing, so there is no return value to set"
M.BEFORE = "the return value can only be set from a listener with when = \"post\": the function has not run yet"

local VALUE, KIND, OVER = {}, {}, {}
local GROWS = { Empty = true, Add = true, Insert = true, Remove = true, RemoveAt = true, Resize = true, Reserve = true,
    Append = true, Clear = true, set = true, Set = true }

local kind_of, OBJECT_KINDS, TEXT_KINDS, PARAM_KINDS = instance.kind_of, instance.OBJECT_KINDS, instance.TEXT_KINDS, instance.PARAM_KINDS
local type, error, setmetatable, rawget, select, tostring = type, error, setmetatable, rawget, select, tostring

local Handed = {}
local convert

local function view(value, kind) return setmetatable({ [VALUE] = value, [KIND] = kind }, Handed) end

-- An engine value as a listener may have it: objects as Instances, text as strings, arrays and structs as read-only views.
function convert(value)
    local kind = kind_of(value)
    if kind == nil then return value end
    if PARAM_KINDS[kind] then return convert(value:get()) end
    if OBJECT_KINDS[kind] then return instance.wrap(value) end
    if TEXT_KINDS[kind] then return value:ToString() end
    if kind == "TArray" then return view(value, "array") end
    return view(value, "struct")
end
M.convert = convert

local function inside(self)
    if rawget(self, OVER) then error(M.OVER, 3) end
    return rawget(self, VALUE)
end

local function count(self)
    local value = inside(self)
    if rawget(self, KIND) ~= "array" then error("this is a " .. rawget(self, KIND) .. ", not an array", 3) end
    return value:GetArrayNum()
end

local methods = {}

-- A copy a listener may keep: an array becomes a Lua table of its entries. A struct stays a view, good inside the listener.
function methods.get(self)
    local value = inside(self)
    if rawget(self, KIND) ~= "array" then return self end
    local out, n = {}, value:GetArrayNum()
    for i = 1, n do out[i] = convert(value[i]) end
    return out
end

function methods.GetArrayNum(self) return count(self) end
methods.Num = methods.GetArrayNum
function methods.IsEmpty(self) return count(self) == 0 end

-- ForEach(function(index, entry) ... end), entries converted; return true to stop
function methods.ForEach(self, fn)
    local value = inside(self)
    for i = 1, count(self) do
        if fn(i, convert(value[i])) == true then break end
    end
end

Handed.__index = function(self, key)
    local method = methods[key]
    if method then return method end
    if GROWS[key] then
        return function() error(rawget(self, KIND) == "array" and M.ARRAY or M.WRITE, 2) end
    end
    local value = inside(self)
    if type(key) == "number" then
        if rawget(self, KIND) ~= "array" then error("this is a " .. rawget(self, KIND) .. ", not an array", 2) end
        local n = value:GetArrayNum()
        -- never past the end: UE4SS makes the array longer for a read there
        if key < 1 or key > n or key % 1 ~= 0 then return nil end
        return convert(value[key])
    end
    if rawget(self, KIND) == "array" then error(("an array has entries 1 to %d, not a field '%s'"):format(value:GetArrayNum(), tostring(key)), 2) end
    local ok, field = pcall(function() return value[key] end)
    if not ok then error(("'%s' could not be read: %s"):format(tostring(key), (tostring(field):match("^[^\r\n]*"))), 2) end
    return convert(field)
end

Handed.__newindex = function(self, key)
    error(rawget(self, KIND) == "array" and M.ARRAY or M.WRITE, 2)
end

Handed.__len = function(self) return count(self) end
Handed.__tostring = function(self)
    if rawget(self, OVER) then return "handed (gone)" end
    return "handed " .. rawget(self, KIND)
end
Handed.__metatable = "Handed"

-- The parameters of one call as views. Plain values stay plain. Returns the list and how many.
function M.params(...)
    local n = select("#", ...)
    local out = {}
    for i = 1, n do out[i] = convert((select(i, ...))) end
    return out, n
end

-- After the call: every view handed out answers with an error from now on.
function M.retire(list, n)
    for i = 1, n or #list do
        local item = list[i]
        if type(item) == "table" and rawget(item, KIND) then rawset(item, OVER, true) end
    end
end

function M.is_view(value) return type(value) == "table" and rawget(value, KIND) ~= nil end

-- What goes to the engine when a return value is set.
local function plain(value)
    if instance.is_instance(value) then return value.Raw end
    if M.is_view(value) then return inside(value) end
    return value
end

-- The return value of a call as the listener gets it: get() reads it, set(value) replaces what the caller will see.
-- `param` is UE4SS's parameter for it, nil for a function that returns nothing, false before the function has run.
function M.returns(param)
    local over = false
    local ret = {}
    function ret.get(_)
        if over then error(M.OVER, 2) end
        if param == false then error(M.BEFORE, 2) end
        if param == nil then error(M.NO_RETURN, 2) end
        return convert(param:get())
    end
    function ret.set(_, value)
        if over then error(M.OVER, 2) end
        if param == false then error(M.BEFORE, 2) end
        if param == nil then error(M.NO_RETURN, 2) end
        if value == nil then error("set expects the new return value, got nil", 2) end
        local ok, problem = pcall(param.set, param, plain(value))
        if not ok then error("the return value could not be set: " .. (tostring(problem):match("^[^\r\n]*")), 2) end
        ret.changed = true
    end
    function ret.retire() over = true end
    return ret
end

return M
