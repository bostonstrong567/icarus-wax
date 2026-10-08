-- A permissive stand-in for UE4SS and UMG: every object accepts any property or call.
-- It cannot catch wrong argument types (only the game can), but it runs all of the GUI's own logic.

local fake = { hooks = {}, objects = 0, calls = {}, pressed = false, mouse = { X = 0, Y = 0 }, screen_scale = 1,
    dead_touches = 0, dead_last = nil,
    touches = 0,        -- every member read or written on any object, whatever answers it
    react = {},         -- react[name] = function(self, ...) stands in for the engine function of that name
    props = {},         -- props[name] = value: what reading the member of that name gives, on any object
    screen_size = { X = 1920, Y = 1080 },
    keys = {},          -- keys.R = true: WasInputKeyJustPressed answers true for R (fake.key_pressed still works)
    released = {},      -- released.R = true: WasInputKeyJustReleased answers true for R
    focused = nil }     -- the widget that has the keyboard, for HasKeyboardFocus and HasFocusedDescendants

local OBJECT = {}
local next_address = 0x1000
local all = {}      -- every object, in the order it was made
local hovered_widget = nil

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
    IsValid = function(self) return not (self and rawget(self, "__gone")) end,
    IsA = function() return false end,
    IsInViewport = function() return true end,
    IsPressed = function() return fake.pressed end,
    WasInputKeyJustPressed = function(_, key)
        local name = key.KeyName
        -- "AnyKey" is the engine's name for "some key or button", whichever it is
        if name == "AnyKey" then
            if fake.key_pressed ~= nil then return true end
            for _, down in pairs(fake.keys or {}) do
                if down == true then return true end
            end
            return false
        end
        if fake.key_pressed ~= nil and name == fake.key_pressed then return true end
        return fake.keys ~= nil and fake.keys[name] == true
    end,
    -- fake.released.RightMouseButton = true: that button came up in this frame
    WasInputKeyJustReleased = function(_, key)
        local name = key.KeyName
        if name == "AnyKey" then return next(fake.released) ~= nil end
        return fake.released[name] == true
    end,
    HasKeyboardFocus = function(self) return fake.focused ~= nil and rawequal(self, fake.focused) end,
    HasFocusedDescendants = function(self) return fake.focused ~= nil and not rawequal(self, fake.focused) end,
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
    IsHovered = function(self)
        if hovered_widget ~= nil then return rawequal(self, hovered_widget) end
        return fake.hovered or false
    end,
    K2_GetWorldSettings = function() return fake.world_settings end,
    GetScrollOffsetOfEnd = function() return fake.scroll_end or 1000 end,
    GetViewportSize = function() return { X = fake.screen_size.X, Y = fake.screen_size.Y } end,
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

-- Every object made since fake.mark() gave `from`.
function fake.made(from)
    local out = {}
    for index = from + 1, #all do out[#out + 1] = all[index] end
    return out
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

-- The game's screen: its size in pixels and the pixels to one unit. The game's own note of the size follows, as it does in the game.
function fake.set_screen(x, y, scale)
    fake.screen_size, fake.screen_scale = { X = x, Y = y }, scale or fake.screen_scale
    fake.props.ResolutionSizeX, fake.props.ResolutionSizeY = x, y
end

-- IsValid() answers false for this object from now on.
function fake.invalidate(object) rawset(object, "__gone", true) end

-- IsHovered() is true for this widget only. fake.hover(nil) goes back to fake.hovered for every widget.
function fake.hover(widget) hovered_widget = widget end

-- A value Lua owns, such as a soft reference: type() answers its kind and fake.free never marks it dead.
local VALUE_KINDS = { soft = "TSoftObjectPtrUserdata", soft_class = "TSoftClassPtrUserdata", name = "FName", text = "FText",
                      string = "FString" }
local VALUE = {}
VALUE.__index = function(self, key)
    if key == "type" then return function() return rawget(self, "__kind") end end
    if key == "IsValid" then return function() return not rawget(self, "__gone") end end
    return nil
end
VALUE.__tostring = function(self) return "value(" .. tostring(rawget(self, "__kind")) .. ")" end
function fake.value(kind)
    -- __props is what fake_world.as_userdata() looks for, so the value counts as userdata there too
    return setmetatable({ __kind = VALUE_KINDS[kind] or kind or "TSoftObjectPtrUserdata", __props = {} }, VALUE)
end

OBJECT.__index = function(self, key)
    touched(self, key)
    fake.touches = fake.touches + 1
    local react = fake.react[key]
    if react then return react end
    local prop = fake.props[key]
    if prop ~= nil then return prop end
    if key == "type" then
        local kind = rawget(self, "__kind") or "UObject"
        return function() return kind end
    end
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
    fake.touches = fake.touches + 1
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
