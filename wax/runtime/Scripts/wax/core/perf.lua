-- Timing: what each part of Wax costs per frame, and how smooth the game's own frames are

local Wax = ...
local co = Wax.import("core.co")

local perf = {}

local clock = co.clock or os.clock
perf.precise = co.clock ~= nil
perf.now = clock

local HITCH_SECONDS = 0.05
local MAX_HITCHES = 20

local sections, order = {}, {}
local frames, frame_total, frame_max = 0, 0, 0
local over33, over50, over100 = 0, 0, 0
local hitches = {}
local last_frame, window_started = nil, clock()
local spent_this_frame = 0

local life_frames, life_seconds = 0, 0

local function section(name)
    local s = { name = name, calls = 0, total = 0, max = 0, life = 0 }
    sections[name] = s
    order[#order + 1] = s
    return s
end

local function finish(s, started, ...)
    local took = clock() - started
    s.calls = s.calls + 1
    s.total = s.total + took
    s.life = s.life + took
    if took > s.max then s.max = took end
    spent_this_frame = spent_this_frame + took
    return ...
end

-- Runs fn(...) and adds the time it took to the named section.
function perf.run(name, fn, ...)
    return finish(sections[name] or section(name), clock(), fn(...))
end

-- Call once at the start of each frame.
function perf.frame()
    local now = clock()
    if last_frame then
        local dt = now - last_frame
        frames = frames + 1
        frame_total = frame_total + dt
        life_frames = life_frames + 1
        life_seconds = life_seconds + dt
        if dt > frame_max then frame_max = dt end
        if dt > 0.0333 then over33 = over33 + 1 end
        if dt > 0.05 then over50 = over50 + 1 end
        if dt > 0.1 then over100 = over100 + 1 end
        if dt > HITCH_SECONDS then
            if #hitches >= MAX_HITCHES then table.remove(hitches, 1) end
            hitches[#hitches + 1] = { at = now - window_started, frame_ms = dt * 1000, wax_ms = spent_this_frame * 1000 }
        end
    end
    last_frame = now
    spent_this_frame = 0
end

function perf.reset()
    for _, s in ipairs(order) do s.calls, s.total, s.max = 0, 0, 0 end
    hitches = {}
    frames, frame_total, frame_max, over33, over50, over100 = 0, 0, 0, 0, 0, 0
    window_started = clock()
end

-- Totals that reset() leaves alone. Take two readings and subtract.
function perf.totals()
    local out = { frames = life_frames, seconds = life_seconds, sections = {} }
    for _, s in ipairs(order) do out.sections[s.name] = s.life end
    return out
end

-- Everything measured since the last reset.
function perf.report()
    local out = {
        precise = perf.precise, seconds = clock() - window_started, frames = frames,
        fps = frame_total > 0 and frames / frame_total or 0,
        frame_ms = { avg = frames > 0 and frame_total / frames * 1000 or 0, max = frame_max * 1000 },
        hitches = { over33ms = over33, over50ms = over50, over100ms = over100 },
        worst = hitches, sections = {}, wax_us_per_frame = 0,
    }
    for i, s in ipairs(order) do
        local per_frame = frames > 0 and s.total / frames * 1e6 or 0
        out.sections[i] = { name = s.name, calls = s.calls, us_per_frame = per_frame,
            avg_us = s.calls > 0 and s.total / s.calls * 1e6 or 0, max_ms = s.max * 1000 }
        out.wax_us_per_frame = out.wax_us_per_frame + per_frame
    end
    return out
end

return perf
