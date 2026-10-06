-- Tells the rest of Wax when an actor begins or ends play

local Wax = ...
local instance = Wax.import("engine.instance")
local guard = Wax.import("core.guard")

local M = {}

M.DESTROYED, M.MAP_CHANGE, M.UNLOADED, M.QUIT = 0, 1, 3, 4

local began, ended = {}, {}
local counts = { began = 0, ended = 0 }

-- A real global, so restarting the core does not register the two engine hooks again.
local hooked = rawget(_G, "WaxActorHooks")
if not hooked then
    hooked = { registered = false }
    rawset(_G, "WaxActorHooks", hooked)
end

local function began_now(parameter)
    counts.began = counts.began + 1
    local actor = parameter:get()
    for i = 1, #began do began[i](actor) end
end

local function ended_now(parameter, reason_parameter)
    counts.ended = counts.ended + 1
    local actor = parameter:get()
    local address = actor:GetAddress()
    local reason = reason_parameter:get()
    for i = 1, #ended do ended[i](actor, address, reason) end
    instance.retire(address)
end

-- The engine calls these during a map load, seconds after the last frame: that is not a runaway script.
local function on_began(parameter)
    local was = guard.suspend_watchdog(true)
    local ok, problem = pcall(began_now, parameter)
    guard.suspend_watchdog(was)
    if not ok then guard.report(tostring(problem), "actors.began") end
end

local function on_ended(parameter, reason_parameter)
    local was = guard.suspend_watchdog(true)
    local ok, problem = pcall(ended_now, parameter, reason_parameter)
    guard.suspend_watchdog(was)
    if not ok then guard.report(tostring(problem), "actors.ended") end
end

local function remove(list, fn)
    for i = #list, 1, -1 do
        if list[i] == fn then table.remove(list, i) end
    end
end

-- fn(actor) runs inside the engine's own call, so it must be quick and must not run mod code.
function M.on_began(fn)
    began[#began + 1] = fn
    Wax.actor_began = on_began
    return function()
        remove(began, fn)
        if #began == 0 then Wax.actor_began = nil end
    end
end

-- fn(actor, address, reason) runs just before the actor ends play, while it can still be read.
function M.on_ended(fn)
    ended[#ended + 1] = fn
    return function() remove(ended, fn) end
end

function M.start()
    Wax.actor_ended = on_ended
    if hooked.registered then return end
    RegisterBeginPlayPostHook(function(parameter)
        local wax = rawget(_G, "Wax")
        local handler = wax and wax.actor_began
        if handler then handler(parameter) end
    end)
    RegisterEndPlayPreHook(function(parameter, reason_parameter)
        local wax = rawget(_G, "Wax")
        local handler = wax and wax.actor_ended
        if handler then handler(parameter, reason_parameter) end
    end)
    hooked.registered = true
end

function M.stats()
    return { began = counts.began, ended = counts.ended, listening = #began > 0 }
end

return M
