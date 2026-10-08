-- Handles: the engine's own answer to "does this object still exist", asked without touching the object

local Wax = ...
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local log = Wax.import("core.log").channel("wax.handle")

local M = {}

M.WATCH_EVERY = 2           -- seconds between two looks at the throwaway object of the self-check
M.WATCH_SECONDS = 600       -- a throwaway that still answers after this much play means the answers cannot be trusted

local LIBRARY = "/Script/Engine.Default__KismetSystemLibrary"
local THROWAWAY_CLASS, THROWAWAY_OUTER = "/Script/Engine.ObjectLibrary", "/Engine/Transient"
-- The wrappers seen to come back as themselves. Any other userdata in an object slot is read as a wild pointer.
local OBJECT_KINDS = { UObject = true, AActor = true, UClass = true, UWorld = true, UDataTable = true }
-- Below this is a wrapper of nothing, or UE4SS's marker for a member that does not exist.
local LOWEST_ADDRESS = 0x10000

local library = nil        -- KismetSystemLibrary's default object while handles are on
---@type string?
local why_off = "not started"
local confirmed = false     -- the throwaway of the self-check was seen to go
local watching = nil        -- { handle, played } until then
---@type { thread: thread? }
local live = { thread = nil }
local counts = { taken = 0, refused = 0, failed = 0, asked = 0, gone = 0 }
local epoch = 0             -- goes up whenever answers kept so far stop holding
local inside = false        -- the frame loop is running: until it returns the engine collects nothing

local function type_name(value) return value:type() end

local function kind(value)
    if type(value) ~= "userdata" then return nil end
    local ok, name = pcall(type_name, value)
    return ok and name or nil
end

local function clean(problem)
    local text = tostring(problem):match("^[^\r\n]*") or ""
    return (text:gsub("^.-%.lua:%d+: ", ""))
end

-- Why no handle can stand for this, or nil when one can. Reads nothing of the object.
local function refusal(object)
    if not OBJECT_KINDS[kind(object)] then return "not an object" end
    if object:GetAddress() < LOWEST_ADDRESS then return "nothing" end
    return nil
end

local function convert(object) return library:Conv_ObjectToSoftObjectReference(object):GetWeakPtr() end

-- nil when the game refuses: that object then goes without a handle.
local function make(object)
    local ok, made = pcall(convert, object)
    if ok then
        counts.taken = counts.taken + 1
        return made
    end
    counts.failed = counts.failed + 1
    if counts.failed == 1 then log:warn("the game gave no handle for an object, which goes by Wax's older checks: %s", clean(made)) end
    return nil
end

-- A handle for an object the engine has just handed over, or nil and why not ("off", "not an object", "nothing", "failed").
-- Never for a wrapper kept from earlier: taking reads the object.
function M.take(object)
    if not library then return nil, "off" end
    local why = refusal(object)
    if why then
        counts.refused = counts.refused + 1
        return nil, why
    end
    local made = make(object)
    if made == nil then return nil, "failed" end
    return made
end

-- False only when the engine says the object is gone: collected, or destroyed and waiting for that.
-- Without a handle nothing is known, and the caller's own checks decide as before.
function M.alive(handle)
    if handle == nil or not library then return true end
    counts.asked = counts.asked + 1
    if handle:Get():GetAddress() ~= 0 then return true end
    counts.gone = counts.gone + 1
    return false
end

-- The object, for use now and not for keeping, or nil when it is gone or there is no handle.
function M.get(handle)
    if handle == nil or not library then return nil end
    counts.asked = counts.asked + 1
    local object = handle:Get()
    if object:GetAddress() ~= 0 then return object end
    counts.gone = counts.gone + 1
    return nil
end

local function ended(ok, ...)
    inside = false
    if not ok then error((...), 0) end
    return ...
end

-- Wraps the frame loop's function: the engine collects between two calls of it, so an answer is kept only until it returns.
function M.framed(frame)
    return function(...)
        epoch = epoch + 1
        inside = true
        return ended(pcall(frame, ...))
    end
end

-- The mark of an answer a caller keeps: it holds while stamp() gives the same number. nil (a widget's event, a hook): keep nothing.
function M.stamp() return inside and epoch or nil end

-- Answers kept in this frame are asked again. For after something was destroyed in it.
function M.expire() epoch = epoch + 1 end

local OBJECT, HANDLE, ASKED = {}, {}, {}
local Held = {}
Held.__index = Held

-- Keeps an object the engine has just handed over so that it is only reached by asking: held:get(), held:use(fn).
function M.hold(object)
    local why = refusal(object)
    if why == "nothing" then
        error("handle.hold was handed a wrapper with no object behind it. Check what made it before holding it", 2)
    elseif why then
        local got = type(object)
        if got == "table" then
            got = "a table (for an Instance, hold its Raw)"
        elseif kind(object) then
            got = "a " .. kind(object)
        elseif got == "userdata" then
            got = "a value that is no object (a member the object does not have reads as one)"
        end
        error("handle.hold expects an engine object as the engine has just handed it over, got " .. got, 2)
    end
    return setmetatable({ [OBJECT] = object, [HANDLE] = library and make(object) or false, [ASKED] = inside and epoch or false }, Held)
end

-- The object, or nil once the engine says it is gone or it was dropped. Inside the frame loop the engine is asked once a frame.
-- One without a handle is given as it is: its owner's own flags decide, as before.
function Held:get()
    local object = self[OBJECT]
    if object == nil then return nil end
    local handle = self[HANDLE]
    if not handle or not library then return object end
    if inside and self[ASKED] == epoch then return object end
    counts.asked = counts.asked + 1
    if handle:Get():GetAddress() ~= 0 then
        self[ASKED] = inside and epoch or false
        return object
    end
    counts.gone = counts.gone + 1
    self[OBJECT] = nil
    return nil
end

function Held:alive() return self:get() ~= nil end

-- Runs fn(object, ...) while the object exists. Returns true and what fn returned, or false.
function Held:use(fn, ...)
    local object = self:get()
    if object == nil then return false end
    return true, fn(object, ...)
end

-- True when the engine is asked about this one, false when it is only kept.
function Held:checked() return self[OBJECT] ~= nil and self[HANDLE] ~= false and library ~= nil end

-- Lets the object go. Its owner calls this when it destroys what it made.
function Held:drop() self[OBJECT] = nil end

local function switch_off(why)
    library, why_off, watching = nil, why, nil
    log:warn("handles are off, so Wax goes by its older checks for objects that are gone: %s", why)
end

-- Nothing holds the throwaway, so the engine lets it go at its next collection. Until that is seen the proof is half done.
-- A wait that took far longer than asked (a loading screen, the PC asleep) counts as two looks, so a game that stood still is not blamed.
local function watch_for(watch)
    local failed = 0
    while watching == watch do
        local waited = sched.task.wait(M.WATCH_EVERY)
        if watching ~= watch then return end
        watch.played = watch.played + math.min(waited or 0, M.WATCH_EVERY * 2)
        local ok, address = pcall(function() return watch.handle:Get():GetAddress() end)
        if not ok then
            -- it cannot be asked from a task (no coroutine helper): what start() proved stands, and the watch ends
            failed = failed + 1
            if failed >= 5 then watching = nil end
        elseif address == 0 then
            confirmed, watching = true, nil
            log:debug("handles: the throwaway object was let go after %d s of play", math.floor(watch.played))
        elseif watch.played > M.WATCH_SECONDS then
            switch_off(("an object nothing holds still answered after %d s"):format(math.floor(watch.played)))
        end
    end
end

local function usable(object) return kind(object) ~= nil and object:IsValid() end

-- One throwaway object: its handle gives it back, a second handle agrees, another object's does not, and nothing gives nothing.
local function prove()
    local found = StaticFindObject(LIBRARY)
    if not usable(found) then return nil, "the game has no KismetSystemLibrary" end
    local class, outer = StaticFindObject(THROWAWAY_CLASS), StaticFindObject(THROWAWAY_OUTER)
    if not (usable(class) and usable(outer)) then return nil, "the game has nothing to make a throwaway object from" end
    local made = StaticConstructObject(class, outer)
    if not usable(made) or refusal(made) then return nil, "a throwaway object could not be made" end
    local address = made:GetAddress()
    local soft = found:Conv_ObjectToSoftObjectReference(made)
    if kind(soft) ~= "TSoftObjectPtrUserdata" then return nil, "the game gave no soft reference for an object" end
    local weak = soft:GetWeakPtr()
    if kind(weak) ~= "FWeakObjectPtr" then return nil, "a soft reference gave no weak pointer" end
    local back = weak:Get()
    if not OBJECT_KINDS[kind(back)] or back:GetAddress() ~= address then return nil, "a handle did not give its own object back" end
    if found:Conv_ObjectToSoftObjectReference(made):GetWeakPtr():Get():GetAddress() ~= address then
        return nil, "a second handle of one object gave another object"
    end
    if found:Conv_ObjectToSoftObjectReference(class):GetWeakPtr():Get():GetAddress() ~= class:GetAddress() then
        return nil, "the handle of another object did not give that object"
    end
    local none = found:Conv_ObjectToSoftObjectReference(nil):GetWeakPtr():Get()
    if kind(none) == nil or none:GetAddress() ~= 0 then return nil, "a handle of nothing answered with an object" end
    return found, weak
end

-- Proves the mechanism in this game build and switches handles on. False, with one log line, when it does not hold.
function M.start()
    local old = rawget(Wax, "handle_live")
    if old and type(old.thread) == "thread" then pcall(sched.task.cancel, old.thread) end
    live = { thread = nil }
    rawset(Wax, "handle_live", live)
    library, confirmed, watching = nil, false, nil
    local ok, found, weak = pcall(prove)
    if not ok or not found then
        switch_off(clean(ok and weak or found))
        return false
    end
    library, why_off = found, nil
    watching = { handle = weak, played = 0 }
    -- a timer, not a frame handler: it costs nothing in the frames between two looks
    local previous = scope.enter(nil)
    live.thread = sched.task.spawn(watch_for, watching)
    scope.leave(previous)
    return true
end

function M.on() return library ~= nil end

-- confirmed: the throwaway of the self-check was seen to go. why: the reason while handles are off.
function M.stats()
    return { on = library ~= nil, confirmed = confirmed, why = why_off, taken = counts.taken, refused = counts.refused,
        failed = counts.failed, asked = counts.asked, gone = counts.gone }
end

return M
