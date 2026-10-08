-- Live check of wax/runtime/data/creature_models.lua against the running game: every mesh, fur, material and
-- animation it names is loaded and its class is looked at. The loads are spread over frames, so send this file
-- once to start it and again to read how far it is. The last send returns { passed, failed, failures, details }.
-- Animation blueprints are left out: loading one loads every animation it uses.
local sched = Wax.import("core.sched")
local now = Wax.perf.now
local BUDGET = 0.002

local state = Wax._creature_models_check
if state and not state.finished then
    return { running = true, done = state.at - 1, total = #state.jobs, failed = #state.failures }
end
if state and state.finished and not rawget(_G, "WaxModelArgs") then
    Wax._creature_models_check = nil
    return { passed = state.passed, failed = #state.failures, failures = state.failures, details = state.details }
end

local chunk = assert(loadfile(Wax.root .. "/data/creature_models.lua"))
local data = chunk()
local KINDS = { mesh = "/Script/Engine.SkeletalMesh", material = "/Script/Engine.MaterialInterface",
    animation = "/Script/Engine.AnimationAsset", splines = "/Script/GFur.FurSplines" }
local classes = {}
for kind, path in pairs(KINDS) do classes[kind] = StaticFindObject(path) end

local jobs, seen, scales = {}, {}, {}
local function want(kind, path, scale)
    if not path then return end
    if kind == "mesh" and scale then scales[path] = math.max(scales[path] or 0, scale) end
    local key = kind .. " " .. path
    if seen[key] then return end
    seen[key] = true
    jobs[#jobs + 1] = { kind = kind, path = path, body = scale ~= nil }
end
for _, look in ipairs(data.looks) do
    want("mesh", look.mesh, look.scale or 1)
    for _, path in pairs(look.materials or {}) do want("material", path) end
    for _, part in ipairs(look.parts or {}) do
        want("mesh", part.mesh)
        for _, path in pairs(part.materials or {}) do want("material", path) end
    end
    for _, coat in ipairs(look.fur or {}) do
        want("mesh", coat.mesh)
        want("splines", coat.splines)
        for _, path in pairs(coat.materials or {}) do want("material", path) end
    end
    want("animation", look.walk)
    want("animation", look.idle)
    want("animation", look.loop)
end

state = { jobs = jobs, at = 1, failures = {}, passed = 0, finished = false, sizes = {}, worst = 0, seconds = 0, started = now() }
Wax._creature_models_check = state
local previous = Wax.import("core.scope").enter(nil)
state.connection = sched.Frame:Connect(function()
    local began = now()
    while state.at <= #jobs and now() - began < BUDGET do
        local job = jobs[state.at]
        state.at = state.at + 1
        local started = now()
        local ok, object = pcall(LoadAsset, job.path)
        local spent = now() - started
        state.seconds = state.seconds + spent
        if spent > state.worst then state.worst, state.worst_path = spent, job.path end
        if not ok or object == nil or not object:IsValid() then
            state.failures[#state.failures + 1] = job.kind .. " " .. job.path .. ": it did not load"
        elseif not object:IsA(classes[job.kind]) then
            state.failures[#state.failures + 1] = job.kind .. " " .. job.path .. ": it is a " .. object:GetClass():GetFName():ToString()
        else
            state.passed = state.passed + 1
            if job.body then
                local radius = object.ExtendedBounds.SphereRadius * (scales[job.path] or 1)
                state.sizes[#state.sizes + 1] = { path = job.path, radius = radius }
            end
        end
    end
    if state.at > #jobs then
        state.connection:Disconnect()
        table.sort(state.sizes, function(a, b) return a.radius > b.radius end)
        local largest, smallest = {}, {}
        for index = 1, math.min(6, #state.sizes) do
            largest[index] = ("%s %.0f"):format(state.sizes[index].path:match("([^%.]+)$"), state.sizes[index].radius)
            local last = state.sizes[#state.sizes + 1 - index]
            smallest[index] = ("%s %.0f"):format(last.path:match("([^%.]+)$"), last.radius)
        end
        state.details = ("%d things of %d looks loaded in %.1f s (%.0f ms of loading, the slowest %.1f ms: %s). Largest bodies by radius: %s. Smallest: %s."):format(
            #jobs, #data.looks, now() - state.started, state.seconds * 1000, state.worst * 1000, tostring(state.worst_path), table.concat(largest, ", "),
            table.concat(smallest, ", "))
        state.finished = true
    end
end)
Wax.import("core.scope").leave(previous)
return { running = true, done = 0, total = #jobs }
