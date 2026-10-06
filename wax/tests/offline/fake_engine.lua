-- A permissive stand-in for UE4SS and UMG: every object accepts any property or call.
-- It cannot catch wrong argument types (only the game can), but it runs all of the GUI's own logic.

local fake = { hooks = {}, objects = 0, calls = {}, pressed = false, mouse = { X = 0, Y = 0 }, screen_scale = 1,
    dead_touches = 0, dead_last = nil }

local OBJECT = {}
local next_address = 0x1000
local all = {}      -- every object, in the order it was made

-- An object the engine has freed: the library must never use one again. Each use is counted.
local function touched(object, key)
    if rawget(object, "__dead") then
        fake.dead_touches = fake.dead_touches + 1
        fake.dead_last = tostring(rawget(object, "__name")) .. "." .. tostring(key)
        -- where the first one came from, for a test that fails on it
        if fake.dead_touches == 1 then fake.dead_where = debug.traceback("", 3) end
    end
end

local ANSWERS = {
    IsValid = function() return true end,
    IsA = function() return false end,
    IsInViewport = function() return true end,
    IsPressed = function() return fake.pressed end,
    WasInputKeyJustPressed = function(_, key) return fake.key_pressed ~= nil and key.KeyName == fake.key_pressed end,
    GetArrayNum = function(self)
        local count = 0
        for key in pairs(rawget(self, "__members")) do
            if type(key) == "number" then count = count + 1 end
        end
        return count
    end,
    GetDesiredSize = function() return { X = 120, Y = 48 } end,
    GetScrollOffset = function() return fake.scroll_offset or 0 end,
    GetViewOffsetFraction = function() return fake.scroll_fraction or 0 end,
    IsHovered = function() return fake.hovered or false end,
    K2_GetWorldSettings = function() return fake.world_settings end,
    GetScrollOffsetOfEnd = function() return fake.scroll_end or 1000 end,
    GetViewportSize = function() return { X = 1920, Y = 1080 } end,
    GetViewportScale = function() return fake.screen_scale end,
    GetMousePositionOnViewport = function() return { X = fake.mouse.X, Y = fake.mouse.Y } end,
    ToString = function(self) return rawget(self, "__text") or "" end,
}

local function new_object(name)
    next_address = next_address + 16
    fake.objects = fake.objects + 1
    local object = setmetatable({ __name = name, __address = next_address, __members = {} }, OBJECT)
    all[#all + 1] = object
    return object
end
fake.new_object = new_object

-- fake.mark() before and after making something, then fake.free(before, after) once it is destroyed.
function fake.mark() return #all end
function fake.free(from, upto)
    for index = from + 1, upto do rawset(all[index], "__dead", true) end
end

-- How often object:member(...) was called, and with what the last time.
function fake.count(object, member)
    local found = rawget(object, "__members")[member]
    return found and rawget(found, "__count") or 0
end
function fake.last(object, member)
    local found = rawget(object, "__members")[member]
    return found and rawget(found, "__last") or nil
end
function fake.writes(object) return rawget(object, "__writes") or 0 end

OBJECT.__index = function(self, key)
    touched(self, key)
    if key == "GetAddress" then return function() return rawget(self, "__address") end end
    if key == "GetSize" then return function() return rawget(self, "__size") or { X = 0, Y = 0 } end end
    if key == "GetPosition" then return function() return rawget(self, "__position") or { X = 0, Y = 0 } end end
    if key == "SetSize" then return function(_, value) rawset(self, "__size", value) end end
    if key == "SetPosition" then return function(_, value) rawset(self, "__position", value) end end
    if key == "IsChecked" then return function() return rawget(self, "__checked") or false end end
    if key == "GetValue" then return function() return rawget(self, "__value") or 0 end end
    if key == "SetValue" then return function(_, value) rawset(self, "__value", value) end end
    if key == "HasMouseCapture" then return function() return fake.captured == self end end
    local answer = ANSWERS[key]
    if answer then return answer end
    local hook = fake.hooks[key]
    if hook then
        -- a hooked native function: deliver to the hook the way the engine does
        return function(context, value)
            hook({ get = function() return context end }, { get = function() return value end })
        end
    end
    local members = rawget(self, "__members")
    local member = members[key]
    if member == nil then
        member = new_object(tostring(rawget(self, "__name")) .. "." .. tostring(key))
        members[key] = member
    end
    return member
end

OBJECT.__newindex = function(self, key, value)
    touched(self, key)
    rawset(self, "__writes", (rawget(self, "__writes") or 0) + 1)
    rawget(self, "__members")[key] = value
end

-- Calling a member (widget:SetText(x)) records the call and returns a fresh object (a slot, a texture, ...).
OBJECT.__call = function(self, ...)
    local name = rawget(self, "__name")
    fake.calls[name] = (fake.calls[name] or 0) + 1
    rawset(self, "__count", (rawget(self, "__count") or 0) + 1)
    rawset(self, "__last", table.pack(...))
    return new_object(name .. "()")
end

function fake.install()
    function StaticFindObject(path) return new_object(path) end
    function StaticConstructObject(class, _, name) return new_object(tostring(rawget(class, "__name")) .. ":" .. tostring(name)) end
    function FindFirstOf(name) return new_object(name) end
    function FindAllOf() return nil end
    function FName(text) return text end
    function FText(text)
        local object = new_object("FText")
        rawset(object, "__text", text)
        return object
    end
    function RegisterHook(path, callback) fake.hooks[path:match(":(.+)$")] = callback end
end

return fake
