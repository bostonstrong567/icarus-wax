-- Live core test: tasks that wait across real frames and call the engine, signals, ownership, error capture.
-- First call starts the test; call again a second later to collect the result (the driver does both).
local state = rawget(_G, "WaxCoreLive")
if state then
    _G.WaxCoreLive = nil
    state.framesSeen = Wax.sched.stats.frame - state.startFrame
    state.ownerSizeAfterDestroy = state.owner:size()
    state.owner = nil
    state.errorsRecorded = 0
    for _, record in ipairs(Wax.guard.errors()) do
        if record.trace:find("live deliberate failure", 1, true) then state.errorsRecorded = state.errorsRecorded + record.count end
    end
    return state
end

local scope = Wax.import("core.scope")
local task, Signal = Wax.task, Wax.Signal
state = { startFrame = Wax.sched.stats.frame, steps = {}, frameSignalHits = 0, cancelledTaskRan = false }
_G.WaxCoreLive = state
local owner = scope.new("core-live-test")
state.owner = owner

scope.run(owner, function()
    -- 1. A task that waits across frames and calls the engine before and after each wait.
    task.spawn(function()
        local world = FindFirstOf("World"):GetFullName()
        state.steps[#state.steps + 1] = "started"
        local waited = task.wait(0.1)
        state.waitedSeconds = waited
        local pc = FindFirstOf("PlayerController")
        state.pawnAfterWait = pc.Pawn:IsValid() and pc.Pawn:GetFullName() or "no pawn"
        state.sameWorldAfterWait = FindFirstOf("World"):GetFullName() == world
        for i = 1, 3 do
            task.wait()
            state.steps[#state.steps + 1] = "frame " .. i
        end
        -- sort with an engine call in the comparator, inside a task
        local values = { 3, 1, 2 }
        table.sort(values, function(a, b) return pc:IsValid() and a < b end)
        state.sortedInTask = table.concat(values, ",")
        state.steps[#state.steps + 1] = "done"
    end)

    -- 2. The per-frame signal, and a handler that pauses.
    local connection
    connection = Wax.sched.Frame:Connect(function(dt)
        state.frameSignalHits = state.frameSignalHits + 1
        state.lastDt = dt
        if state.frameSignalHits == 5 then connection:Disconnect() end
    end)
    local signal = Signal.new("live")
    signal:Connect(function(value)
        task.wait(0.05)
        state.pausedHandlerGot = value
    end)
    signal:Fire("payload")

    -- 3. A failing task is reported, not raised.
    task.spawn(function() error("live deliberate failure") end)

    -- 4. A task that will be cancelled by destroying its owner before it wakes.
    task.delay(0.3, function() state.cancelledTaskRan = true end)
end)

-- Destroy the owner after the short work is done but before the 0.3 s task is due.
task.delay(0.2, function()
    state.ownerSizeBeforeDestroy = owner:size()
    owner:destroy()
end)

return "started"
