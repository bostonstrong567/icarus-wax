-- Small animations: run a function with a value easing from 0 to 1 over some time

local Wax = ...
local guard = Wax.import("core.guard")

local tween = {}

local active = {}
local clock = os.clock

local EASING = {
    linear = function(t) return t end,
    out = function(t) local u = 1 - t return 1 - u * u * u end,                        -- starts fast and slows to a stop
    in_out = function(t) return t < 0.5 and 4 * t * t * t or 1 - ((-2 * t + 2) ^ 3) / 2 end,
}

-- Calls apply(progress) each frame with progress easing from 0 to 1, then done() once. Stops when owner.destroyed is set.
function tween.run(duration, apply, done, easing, owner)
    local ease = EASING[easing or "out"] or EASING.out
    if not duration or duration <= 0 then
        guard.call("tween", apply, 1)
        if done then guard.call("tween", done) end
        return { cancel = function() end }
    end
    local entry = { started = clock(), duration = duration, apply = apply, done = done, ease = ease, owner = owner }
    function entry.cancel() entry.cancelled = true end
    active[#active + 1] = entry
    guard.call("tween", apply, 0)
    return entry
end

function tween.step()
    if #active == 0 then return end
    local now = clock()
    local kept = {}
    for i = 1, #active do
        local entry = active[i]
        if not entry.cancelled and not (entry.owner and entry.owner.destroyed) then
            local t = (now - entry.started) / entry.duration
            if t >= 1 then
                guard.call("tween", entry.apply, 1)
                if entry.done then guard.call("tween", entry.done) end
            else
                -- An animation whose target is gone raises. Drop it so it is not reported every frame.
                if guard.call("tween", entry.apply, entry.ease(t)) then kept[#kept + 1] = entry end
            end
        end
    end
    active = kept
end

function tween.count() return #active end

return tween
