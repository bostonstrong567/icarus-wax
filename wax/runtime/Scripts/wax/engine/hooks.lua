-- The game's own events: one hook per function for as long as the game runs, and listeners that come and go

local Wax = ...
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local sched = Wax.import("core.sched")
local perf = Wax.import("core.perf")
local suggest = Wax.import("core.suggest")
local instance = Wax.import("engine.instance")
local handed = Wax.import("engine.handed")
local log = Wax.import("core.log").channel("wax.hooks")

local M = {}

-- how the game reaches a hooked function, which says what a listener may read
M.NET = "net"               -- the game's own code raises it as a network call: its values are right
M.DELEGATE = "delegate"     -- the game bound it to one of its events: its values are right
M.CALLED = "called"         -- blueprint code calls it: only the object is right, so no values are handed over
M.LIST = "blueprint_calls"  -- the functions blueprints call, read from the data folder when it has that file
M.MOST = 4096               -- what is kept to tell in one frame. More is dropped and counted

local REACHES = { M.NET, M.DELEGATE, M.CALLED }
local IS_REACH = { [M.NET] = true, [M.DELEGATE] = true, [M.CALLED] = true }
local OPTIONS = { "reach", "catch", "deliver", "label" }
local IS_OPTION = { reach = true, catch = true, deliver = true, label = true }
local CHECKED_OPTIONS = { "when", "reach", "label" }
local IS_CHECKED_OPTION = { when = true, reach = true, label = true }

local type, pcall, xpcall, error, pairs, tostring, select, unpack = type, pcall, xpcall, error, pairs, tostring, select, table.unpack
local clock, suspend = perf.now, guard.suspend_watchdog

-- A real global: the hooks UE4SS holds outlive every reload of this file, and UE4SS cannot take one off for good.
local registry = rawget(_G, "WaxHooks")
if type(registry) ~= "table" or type(registry.slots) ~= "table" then
    registry = { slots = {} }
    rawset(_G, "WaxHooks", registry)
end
-- what an older copy of this file listened for is let go
for _, slot in pairs(registry.slots) do slot.fn, slot.after = nil, nil end

local records = {}                  -- function path -> what listens to it here
local queue, queued = {}, 0         -- listener, value, listener, value ...
local spare = {}
-- the connection to the frame signal: held only while something waits to be told, and never once the frame loop calls M.step
local link, driven = nil, false
local counts = { delivered = 0, dropped = 0, flushes = 0, seconds = 0 }
local listed = nil                  -- lower-case path -> true for what blueprints call. false: the build has no list

local function first_line(problem) return (tostring(problem):match("^[^\r\n]*") or "") end

local function called_by_blueprints(path)
    if listed == nil then
        listed = false
        local chunk = loadfile(Wax.root .. "/data/" .. M.LIST .. ".lua")
        local ok, data = pcall(function() return chunk and chunk() end)
        if ok and type(data) == "table" then
            listed = {}
            for name in pairs(data) do
                if type(name) == "string" then listed[name:lower()] = true end
            end
        end
    end
    return listed and listed[path:lower()] == true or false
end

local function failed(listener, problem)
    listener.failures = listener.failures + 1
    if listener.failures == 1 then guard.report(tostring(problem), "hooks: " .. listener.label, listener.owner) end
    if listener.failures >= guard.breaker_errors then
        listener.off = true
        guard.report(("switched off after %d errors in a row"):format(listener.failures), "hooks: " .. listener.label, listener.owner)
    end
end

local tell

local function on_frame()
    if queued > 0 then tell() end
    if queued == 0 and link then
        link:Disconnect()
        link = nil
    end
end

-- Where the frame loop does not call M.step, a handler on the frame signal tells what waits. It belongs to no mod.
local function hold()
    local previous = scope.enter(nil)
    local ok, made = pcall(sched.Frame.Connect, sched.Frame, on_frame)
    scope.leave(previous)
    if ok then link = made end
end

-- A mod's listener runs inside the game's call, as its own scope, with the watchdog back on for it.
-- A value it returns is the new return value, which only a post listener has.
local function run_checked(listener, object, ret, views, n)
    local previous = scope.enter(listener.owner)
    local was = suspend(false)
    guard.arm()
    local ok, result
    if ret then ok, result = xpcall(listener.checked, guard.handler, object, ret, unpack(views, 1, n))
    else ok, result = xpcall(listener.checked, guard.handler, object, unpack(views, 1, n)) end
    suspend(was)
    scope.leave(previous)
    if ok and result ~= nil then
        if ret then ok, result = pcall(ret.set, ret, result) else ok, result = false, handed.BEFORE end
    end
    return ok, result
end

-- Runs inside the engine's own call. Wax's own listeners copy what they need and nothing of a mod's runs here;
-- a mod's checked listener runs here with views it can read and not write.
local function caught(record, bare, context, ...)
    local object = context:get()
    record.pre_n = select("#", ...)
    local list = record.listeners
    local views, n, wrapped = nil, 0, nil
    for i = 1, #list do
        local listener = list[i]
        if not listener.off then
            local ok, value
            if listener.checked then
                if not views then
                    wrapped = instance.wrap(object)
                    if bare then views, n = {}, 0 else views, n = handed.params(...) end
                end
                ok, value = run_checked(listener, wrapped, nil, views, n)
                if ok then value = nil end
            elseif bare then ok, value = pcall(listener.catch, object)
            else ok, value = pcall(listener.catch, object, ...) end
            if not ok then
                failed(listener, value)
            else
                listener.failures = 0
                if value ~= nil and listener.deliver then
                    if queued >= M.MOST * 2 then
                        counts.dropped = counts.dropped + 1
                    else
                        queue[queued + 1], queue[queued + 2] = listener, value
                        queued = queued + 2
                        if not driven and not link then hold() end
                    end
                end
            end
        end
    end
    if views then handed.retire(views, n) end
end

-- After the function ran. UE4SS hands (object, return value, parameters...) when the function has a return value.
local function caught_after(record, bare, context, ...)
    local object = context:get()
    local n = select("#", ...)
    local has_return = record.pre_n ~= nil and n == record.pre_n + 1
    local list = record.afters
    local wrapped, ret, views, m = nil, nil, nil, 0
    for i = 1, #list do
        local listener = list[i]
        if not listener.off then
            if not ret then
                wrapped = instance.wrap(object)
                ret = handed.returns(has_return and (...) or nil)
                if bare then views, m = {}, 0
                elseif has_return then views, m = handed.params(select(2, ...))
                else views, m = handed.params(...) end
            end
            local ok, problem = run_checked(listener, wrapped, ret, views, m)
            if not ok then failed(listener, problem) else listener.failures = 0 end
        end
    end
    if ret then
        ret.retire()
        handed.retire(views, m)
    end
end

-- The engine may call a hooked function during a map load, seconds after the last frame: that is not a runaway script.
local function entry_for(record, run)
    local bare = record.reach == M.CALLED
    return function(context, ...)
        local started = clock()
        local was = suspend(true)
        local ok, problem = pcall(run, record, bare, context, ...)
        suspend(was)
        record.calls = record.calls + 1
        record.seconds = record.seconds + (clock() - started)
        if not ok then
            record.failed = record.failed + 1
            if record.failed == 1 then guard.report(tostring(problem), "hooks: " .. record.path) end
        end
    end
end

-- One registration per function for the life of the game process, with a callback before and one after the function.
-- What they call is looked up on every call. A slot from before this file had post callbacks gets a second
-- registration the first time a post listener needs one.
local function slot_for(path, after)
    local slot = registry.slots[path]
    if slot and (slot.both or not after) then return slot end
    if type(RegisterHook) ~= "function" then error("this build of UE4SS has no RegisterHook", 0) end
    local fresh = slot == nil
    slot = slot or { fn = nil }
    local ok, pre, post = pcall(RegisterHook, path,
        function(context, ...)
            local fn = slot.fn
            if fn then fn(context, ...) end
        end,
        function(context, ...)
            local fn = slot.after
            if fn then fn(context, ...) end
        end)
    if not ok then error(("the game has no function %s to listen to (%s)"):format(path, first_line(pre)), 0) end
    if fresh then slot.pre, slot.post = pre, post else slot.pre2, slot.post2 = pre, post end
    slot.both = true
    registry.slots[path] = slot
    return slot
end

function tell()
    local list, n = queue, queued
    queue, queued, spare = spare, 0, list
    local started = clock()
    for i = 1, n, 2 do
        local listener, value = list[i], list[i + 1]
        list[i], list[i + 1] = nil, nil
        if not listener.gone then listener.deliver(value) end
    end
    counts.delivered = counts.delivered + n // 2
    counts.flushes = counts.flushes + 1
    counts.seconds = counts.seconds + (clock() - started)
end

-- For the frame loop. Called from there, nothing is put on the frame signal.
function M.step()
    if not driven then
        driven = true
        if link then
            link:Disconnect()
            link = nil
        end
    end
    if queued > 0 then tell() end
end

local function without(list, listener)
    local out = {}
    for i = 1, #list do
        if list[i] ~= listener then out[#out + 1] = list[i] end
    end
    return out
end

local function check_path(path)
    if type(path) ~= "string" or not path:find("^/Script/[%w_]+%.[%w_]+:[%w_]+$") then
        error("hooks.listen expects the path of a function of the game's own code, such as "
            .. "\"/Script/Icarus.ActorState:Multicast_OnDamaged\", got " .. tostring(path)
            .. ". A blueprint's function cannot be listened to: UE4SS never lets go of such a hook", 3)
    end
end

-- The record of a function, hooked on first use. `reach` must agree with what listens already.
local function record_for(path, reach)
    local record = records[path]
    if not record then
        if reach ~= M.CALLED and called_by_blueprints(path) then
            reach = M.CALLED
            log:warn("%s is called by blueprints in this build of the game, so only the object it was called on is handed over", path)
        end
        local ok, slot = pcall(slot_for, path)
        if not ok then error("hooks.listen: " .. tostring(slot), 3) end
        record = { path = path, reach = reach, slot = slot, listeners = {}, afters = {}, calls = 0, seconds = 0, failed = 0 }
        record.entry = entry_for(record, caught)
        record.exit = entry_for(record, caught_after)
        records[path] = record
    elseif record.reach ~= reach and not (record.reach == M.CALLED and called_by_blueprints(path)) then
        error(("hooks.listen: %s is already listened to as \"%s\", and a function is reached one way only"):format(path, record.reach), 3)
    end
    return record
end

local function wire(record)
    local slot = record.slot
    slot.fn = (#record.listeners > 0 or #record.afters > 0) and record.entry or nil
    slot.after = #record.afters > 0 and record.exit or nil
end

-- Adds a listener to the record's `listeners` or `afters` and returns the undo, owned by the current scope.
local function attach(record, listener, after)
    if after and not record.slot.both then
        local ok, problem = pcall(slot_for, record.path, true)
        if not ok then error("hooks.listen: " .. tostring(problem), 3) end
    end
    local key = after and "afters" or "listeners"
    local list = without(record[key], nil)
    list[#list + 1] = listener
    record[key] = list
    wire(record)
    local owner, slot_number = nil, nil
    local function undo()
        if listener.gone then return end
        listener.gone = true
        record[key] = without(record[key], listener)
        wire(record)
        if owner then owner:remove(slot_number) end
    end
    owner, slot_number = scope.own(undo)
    return undo
end

-- hooks.listen("/Script/Icarus.ActorState:Multicast_OnDamaged", { reach = hooks.NET, catch = fn, deliver = fn, label = "damage" })
-- catch(object, ...) runs inside the game's call with the object the function was called on and its values as UE4SS
-- hands them (each read with :get()). It copies what it needs and returns one value, or nil for nothing to tell.
-- deliver(value) runs with that value in the frame loop, where a mod's code may run. Returns the undo.
-- This is Wax's own way; a mod's is M.checked, below.
function M.listen(path, options)
    check_path(path)
    if type(options) ~= "table" then error("hooks.listen expects { reach = ..., catch = function, deliver = function }", 2) end
    for key in pairs(options) do
        if not IS_OPTION[key] then
            error(("hooks.listen has no option '%s'.%s"):format(tostring(key), suggest.phrase(tostring(key), OPTIONS)), 2)
        end
    end
    local reach = options.reach
    if not IS_REACH[reach] then
        error(("hooks.listen: reach says how the game calls %s and is one of \"net\", \"delegate\" and \"called\", got %s.%s")
            :format(path, tostring(reach), type(reach) == "string" and suggest.phrase(reach, REACHES) or ""), 2)
    end
    if type(options.catch) ~= "function" then error("hooks.listen: catch must be a function, got " .. type(options.catch), 2) end
    if options.deliver ~= nil and type(options.deliver) ~= "function" then
        error("hooks.listen: deliver must be a function, got " .. type(options.deliver), 2)
    end
    local label = type(options.label) == "string" and options.label or path:match("([%w_]+)$")
    local record = record_for(path, reach)
    local listener = { catch = options.catch, label = label, owner = scope.current(), failures = 0, off = false, gone = false }
    if options.deliver then listener.deliver = guard.wrap("hooks: " .. label, options.deliver) end
    return attach(record, listener, false)
end

-- A mod's way: hooks.listen(path, fn, { when = "pre" | "post", reach = ..., label = ... }). Returns the undo.
-- when = "pre": fn(object, params...) runs before the function, when = "post": fn(object, ret, params...) after it.
-- Every parameter is a view the listener can read and not write, good only inside fn; ret:get() reads the return
-- value, ret:set(value) or a value returned from fn replaces it. With reach "called" only the object is handed over.
function M.checked(path, fn, options)
    check_path(path)
    if type(fn) ~= "function" then
        error("hooks.listen expects the function to run: hooks.listen(path, function(object, ...) end, { when = \"post\" }), got "
            .. type(fn) .. " in its place", 2)
    end
    if options == nil then options = {} end
    if type(options) ~= "table" then error("hooks.listen: the options are a table such as { when = \"post\" }, got " .. type(options), 2) end
    for key in pairs(options) do
        if not IS_CHECKED_OPTION[key] then
            error(("hooks.listen has no option '%s'.%s"):format(tostring(key), suggest.phrase(tostring(key), CHECKED_OPTIONS)), 2)
        end
    end
    local when = options.when or "pre"
    if when ~= "pre" and when ~= "post" then
        error(("hooks.listen: when is \"pre\" (before the function runs) or \"post\" (after it, with its return value), got %s"):format(tostring(when)), 2)
    end
    local reach = options.reach
    if reach == nil then reach = records[path] and records[path].reach or M.DELEGATE end
    if not IS_REACH[reach] then
        error(("hooks.listen: reach is one of \"net\", \"delegate\" and \"called\", got %s.%s")
            :format(tostring(reach), type(reach) == "string" and suggest.phrase(reach, REACHES) or ""), 2)
    end
    if options.label ~= nil and type(options.label) ~= "string" then error("hooks.listen: label must be a string", 2) end
    local label = options.label or path:match("([%w_]+)$")
    local record = record_for(path, reach)
    local listener = { checked = fn, label = label, owner = scope.current(), failures = 0, off = false, gone = false }
    return attach(record, listener, when == "post")
end

-- What a mod sees as `hooks`.
M.api = { listen = M.checked, NET = M.NET, DELEGATE = M.DELEGATE, CALLED = M.CALLED }

-- Makes a signal say when its first handler comes and when its last one leaves. first may raise: nothing is connected then.
function M.count(signal, first, last)
    local connect = signal.Connect
    signal.Connect = function(self, fn)
        if type(fn) ~= "function" then error("Connect expects a function, got " .. type(fn), 2) end
        if self.count == 0 and first then
            local ok, problem = pcall(first, self)
            if not ok then error(problem, 2) end
        end
        local made, connection = pcall(connect, self, fn)
        if not made then
            if self.count == 0 and last then pcall(last, self) end
            error((tostring(connection):gsub("^[^\n]-hooks%.lua:%d+: ", "", 1)), 2)
        end
        local theirs = connection.Disconnect
        connection.Disconnect = function(this)
            if not this.Connected then return end
            theirs(this)
            if self.count == 0 and last then last(self) end
        end
        return connection
    end
    return signal
end

function M.signal(name, first, last) return M.count(sched.Signal.new(name), first, last) end

function M.start()
    if type(RegisterHook) ~= "function" then
        log:warn("this build of UE4SS has no RegisterHook, so the game's own events cannot be listened to")
    end
end

function M.stats()
    local hooked, registered = {}, 0
    for _ in pairs(registry.slots) do registered = registered + 1 end
    for path, record in pairs(records) do
        local off = 0
        for i = 1, #record.listeners do
            if record.listeners[i].off then off = off + 1 end
        end
        for i = 1, #record.afters do
            if record.afters[i].off then off = off + 1 end
        end
        hooked[path] = { reach = record.reach, listeners = #record.listeners, afters = #record.afters, off = off, calls = record.calls,
            failed = record.failed, us = record.calls > 0 and record.seconds / record.calls * 1e6 or 0 }
    end
    return { registered = registered, hooks = hooked, queued = queued // 2, delivered = counts.delivered, dropped = counts.dropped,
        flushes = counts.flushes, tell_us = counts.flushes > 0 and counts.seconds / counts.flushes * 1e6 or 0,
        driven = driven, linked = link ~= nil and link.Connected == true, list = listed and true or false }
end

return M
