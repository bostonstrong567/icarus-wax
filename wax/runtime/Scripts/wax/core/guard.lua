-- Catches errors: every call from the engine into mod code goes through here

local Wax = ...
local log = Wax.import("core.log")
local scope = Wax.import("core.scope")

local guard = {}

guard.breaker_errors = 5            -- consecutive failures before a wrapped callback is switched off
guard.timeout_seconds = 5           -- Lua that runs this many seconds without returning is stopped (0 turns the check off)
guard.hook_instructions = 100000    -- how often (VM instructions) the watchdog looks at the clock

local clock = os.clock
local traceback = debug.traceback
local sethook = debug.sethook
local running = coroutine.running

local records = {}      -- error records, oldest first
local by_key = {}
local MAX_RECORDS = 200

local function readable(err)
    if type(err) == "string" then return err end
    return "(error value of type " .. type(err) .. ": " .. tostring(err) .. ")"
end

-- The message handler for xpcall: turns any error value into text with a traceback.
local function handler(err)
    if guard.on_error then guard.on_error(err) end      -- set by the debugger: break on error
    return traceback(readable(err), 2)
end
guard.handler = handler

local function first_line(text) return (text:match("^[^\r\n]*")) end

-- Records an error. `trace` is the full text (message plus traceback) and `label` says what was running.
function guard.report(trace, label, owner)
    trace = readable(trace)
    owner = owner or scope.current()
    local channel = owner and owner.name or "wax"
    local message = first_line(trace)
    local key = channel .. "\0" .. tostring(label) .. "\0" .. message
    local record = by_key[key]
    if record then
        record.count = record.count + 1
        record.last = os.time()
        -- log.write counts a repeated message instead of adding a line, so this stays one line.
        log.write("error", channel, "%s: %s", tostring(label), message)
        return record
    end
    record = { message = message, trace = trace, label = tostring(label), channel = channel, count = 1,
               first = os.time(), last = os.time() }
    by_key[key] = record
    records[#records + 1] = record
    if #records > MAX_RECORDS then
        local dropped = table.remove(records, 1)
        by_key[dropped.channel .. "\0" .. dropped.label .. "\0" .. dropped.message] = nil
    end
    log.write("error", channel, "%s: %s", tostring(label), trace)
    return record
end

function guard.errors() return records end

function guard.clear_errors()
    records, by_key = {}, {}
end

-- Drops the errors recorded for one owner (a mod's id). Its mod loaded again, so they are about code that is gone.
function guard.forget(channel)
    local kept = {}
    for _, record in ipairs(records) do
        if record.channel == channel then
            by_key[record.channel .. "\0" .. record.label .. "\0" .. record.message] = nil
        else
            kept[#kept + 1] = record
        end
    end
    records = kept
end

-- The watchdog. A Lua hook belongs to one coroutine, so each coroutine gets its own.
local run_started = 0
local hooked = setmetatable({}, { __mode = "k" })
local suspended = false

local function watchdog()
    if suspended then return end
    local limit = guard.timeout_seconds
    if limit > 0 and clock() - run_started > limit then
        run_started = clock()       -- gives error handlers time to run. A loop that catches the error is stopped again.
        error(("script timeout: Lua ran for more than %g s without returning to the game"):format(limit), 2)
    end
end

-- Call when control passes from the engine (or the scheduler) into Lua that may run for a while.
local function arm()
    run_started = clock()
    local thread = running()
    if not hooked[thread] then
        hooked[thread] = true
        sethook(thread, watchdog, "", guard.hook_instructions)
        if guard.hook_installed then guard.hook_installed(thread) end   -- lets the debugger add its own hook
    end
end
guard.arm = arm

-- The debugger can pause Lua for any length of time. That must not count as a runaway script.
function guard.suspend_watchdog(flag) suspended = flag and true or false end

local function call_finish(label, ok, ...)
    if ok then return true, ... end
    guard.report((...), label)
    return false
end

-- Runs fn(...). Returns true, results... or false after reporting the error.
function guard.call(label, fn, ...)
    arm()
    return call_finish(label, xpcall(fn, handler, ...))
end

local function wrapped_finish(state, previous, ok, ...)
    scope.leave(previous)
    if ok then
        state.failures = 0
        return ...
    end
    state.failures = state.failures + 1
    guard.report((...), state.label, state.owner)
    if state.failures >= guard.breaker_errors then
        state.off = true
        guard.report(("switched off after %d consecutive errors"):format(state.failures), state.label, state.owner)
    end
    return state.fallback
end

-- Wraps a callback for the engine: errors are reported, and it is switched off after too many in a row.
function guard.wrap(label, fn, fallback)
    if type(fn) ~= "function" then error("guard.wrap expects a function, got " .. type(fn), 2) end
    local state = { label = label, owner = scope.current(), fallback = fallback, failures = 0, off = false }
    local enter = scope.enter
    return function(...)
        if state.off then return state.fallback end
        arm()
        local previous = enter(state.owner)
        return wrapped_finish(state, previous, xpcall(fn, handler, ...))
    end, state
end

return guard
