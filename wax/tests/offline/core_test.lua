-- Offline tests for the Wax core: scope, log, guard, co, sched.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\core_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local Wax = t.new_wax()
local scope = Wax.import("core.scope")
local log = Wax.import("core.log")
local guard = Wax.import("core.guard")
local co = Wax.import("core.co")
local sched = Wax.import("core.sched")
local task, Signal = sched.task, sched.Signal

-- A clock the tests move by hand.
local now = 100
sched.clock = function() return now end
local function frame(advance)
    now = now + (advance or 0.016)
    return sched.step()
end

local function errors_mentioning(fragment)
    local n = 0
    for _, record in ipairs(guard.errors()) do
        if record.trace:find(fragment, 1, true) then n = n + record.count end
    end
    return n
end

---------------------------------------------------------------------------------------------------- scope
t.test("scope: undo runs newest first and failures do not stop the rest", function()
    local s, order = scope.new("a"), {}
    s:add(function() order[#order + 1] = 1 end)
    s:add(function() error("boom") end)
    s:add(function() order[#order + 1] = 3 end)
    local failures = s:destroy()
    t.eq(table.concat(order, ","), "3,1")
    t.eq(#failures, 1)
    t.ok(failures[1]:find("boom", 1, true))
    t.eq(#s:destroy(), 0, "second destroy is a no-op")
end)

t.test("scope: remove forgets an undo, late add runs at once, size does not grow", function()
    local s, ran = scope.new("b"), 0
    local slot = s:add(function() ran = ran + 1 end)
    s:remove(slot)
    for _ = 1, 10000 do s:remove(s:add(function() end)) end
    t.eq(s:size(), 0)
    local kept = 0
    for _ in pairs(s.undo) do kept = kept + 1 end
    t.eq(kept, 0, "no slots retained")
    s:destroy()
    t.eq(ran, 0)
    s:add(function() ran = ran + 1 end)
    t.eq(ran, 1, "undo added to a dead scope runs immediately")
end)

t.test("scope: destroying a parent destroys its children; run restores the current scope on error", function()
    local parent = scope.new("parent")
    local child, gone = scope.new("child", parent), false
    child:add(function() gone = true end)
    parent:destroy()
    t.ok(gone)
    local outer = scope.new("outer")
    t.raises(function() scope.run(outer, function() error("inside") end) end, "inside")
    t.eq(scope.current(), nil)
    t.eq(scope.run(outer, function() return scope.current() end), outer)
end)

------------------------------------------------------------------------------------------------------ log
t.test("log: repeats fold into a count, filters work, a failing sink is isolated", function()
    log.clear()
    local seen = 0
    local remove = log.add_sink(function() seen = seen + 1 error("sink failure") end)
    local base = log.newest_id()
    for _ = 1, 500 do log.write("warn", "modA", "same %d", 7) end
    log.write("info", "modB", "other")
    local all = log.since(base)
    t.eq(#all, 2)
    t.eq(all[1].count, 500)
    t.eq(all[1].message, "same 7")
    t.eq(#log.since(base, { level = "warn" }), 1)
    t.eq(#log.since(base, { channel = "modB" }), 1)
    t.eq(#log.since(base, { text = "OTH" }), 1)
    t.eq(seen, 501)
    remove()
    log.write("info", "modB", "after")
    t.eq(seen, 501, "removed sink is no longer called")
    t.eq(log.write("trace", "x", "dropped"), nil, "below the level threshold")
    t.eq(log.write("info", "x", "%d", "not a number").message, "%d not a number", "bad format still logs")
end)

t.test("log: the ring buffer keeps only the newest entries", function()
    log.clear()
    local saved = log.capacity
    log.capacity = 10
    local base = log.newest_id()
    for i = 1, 25 do log.write("info", "ring", "line %d", i) end
    local kept = log.since(base)
    log.capacity = saved
    t.eq(#kept, 10)
    t.eq(kept[1].message, "line 16")
    t.eq(kept[10].message, "line 25")
    log.clear()
end)

---------------------------------------------------------------------------------------------------- guard
t.test("guard.call reports once and counts repeats", function()
    guard.clear_errors()
    local function bad() error("kaput") end
    for _ = 1, 3 do t.eq(guard.call("job", bad), false) end
    local ok, a, b = guard.call("job", function(x) return x, x * 2 end, 4)
    t.ok(ok)
    t.eq(a + b, 12)
    local records = guard.errors()
    t.eq(#records, 1)
    t.eq(records[1].count, 3)
    t.ok(records[1].trace:find("stack traceback", 1, true), "traceback kept")
end)

t.test("guard.wrap: owner scope, fallback, circuit breaker", function()
    guard.clear_errors()
    local owner = scope.new("mod")
    local calls, seen_owner = 0, nil
    local wrapped, state = scope.run(owner, function()
        return guard.wrap("cb", function(fail)
            calls = calls + 1
            seen_owner = scope.current()
            if fail then error("cb failed") end
            return "fine"
        end, "fallback")
    end)
    t.eq(wrapped(false), "fine")
    t.eq(seen_owner, owner, "callback runs under the scope that wrapped it")
    t.eq(scope.current(), nil, "scope restored after the call")
    for _ = 1, guard.breaker_errors do t.eq(wrapped(true), "fallback") end
    t.ok(state.off, "switched off after consecutive failures")
    local before = calls
    t.eq(wrapped(false), "fallback")
    t.eq(calls, before, "a switched-off callback is not called")
    t.eq(scope.current(), nil)
    t.eq(errors_mentioning("switched off"), 1)
end)

t.test("guard: the watchdog stops an endless loop", function()
    guard.clear_errors()
    local saved_timeout, saved_step = guard.timeout_seconds, guard.hook_instructions
    guard.timeout_seconds, guard.hook_instructions = 0.05, 1000
    -- A fresh coroutine so the hook is installed with the small instruction count.
    local finished = false
    local thread = coroutine.create(function()
        guard.call("spinner", function() while true do end end)
        finished = true
    end)
    local started = os.clock()
    coroutine.resume(thread)
    guard.timeout_seconds, guard.hook_instructions = saved_timeout, saved_step
    t.ok(finished, "the loop was interrupted and control returned")
    t.ok(os.clock() - started < 2, "interrupted promptly")
    t.eq(errors_mentioning("script timeout"), 1)
end)

t.test("guard: a suspended watchdog lets long work through and says what it was before", function()
    guard.clear_errors()
    local saved_timeout, saved_step = guard.timeout_seconds, guard.hook_instructions
    guard.timeout_seconds, guard.hook_instructions = 0.05, 1000
    local thread = coroutine.create(function()
        guard.arm()
        local was = guard.suspend_watchdog(true)
        local finish = os.clock() + 0.2
        while os.clock() < finish do end
        guard.timeout_seconds = saved_timeout
        t.eq(guard.suspend_watchdog(was), true)
        t.eq(was, false)
    end)
    local ok, problem = coroutine.resume(thread)
    guard.timeout_seconds, guard.hook_instructions = saved_timeout, saved_step
    t.ok(ok, tostring(problem))
    t.eq(errors_mentioning("script timeout"), 0)
end)

------------------------------------------------------------------------------------------------------- co
t.test("co: create and wrap behave like the standard ones", function()
    local thread = co.create(function(a) local b = coroutine.yield(a + 1) return a + b end)
    t.eq(select(2, coroutine.resume(thread, 1)), 2)
    t.eq(select(2, coroutine.resume(thread, 10)), 11)
    local gen = co.wrap(function() coroutine.yield(1) coroutine.yield(2) end)
    t.eq(gen(), 1)
    t.eq(gen(), 2)
    local err = t.raises(co.wrap(function() error("inside wrap") end), "inside wrap")
    t.ok(tostring(err):find("stack traceback", 1, true), "wrap keeps the coroutine's traceback")
    t.raises(function() co.create(42) end, "expects a function")
    t.eq(co.library().create, co.create)
    t.eq(co.library().status, coroutine.status)
end)

---------------------------------------------------------------------------------------------------- sched
t.test("task.spawn runs at once; task.wait resumes on a later frame with the time waited", function()
    sched.reset()
    local log_ = {}
    task.spawn(function()
        log_[#log_ + 1] = "start"
        local waited = task.wait(0.05)
        log_[#log_ + 1] = ("woke %.3f"):format(waited)
    end)
    t.eq(log_[1], "start")
    frame(0.016)
    frame(0.016)
    t.eq(#log_, 1, "not due yet")
    frame(0.030)
    t.eq(log_[2], "woke 0.062")
end)

t.test("task.wait() with no time resumes next frame, never in the frame that scheduled it", function()
    sched.reset()
    local count = 0
    task.spawn(function() while true do task.wait() count = count + 1 end end)
    for i = 1, 5 do
        frame()
        t.eq(count, i)
    end
end)

t.test("task.delay keeps first-in first-out order for equal times; defer runs at the end of the step", function()
    sched.reset()
    local order = {}
    for i = 1, 5 do task.delay(0.01, function(n) order[#order + 1] = n end, i) end
    sched.Frame:Connect(function() order[#order + 1] = "frame" task.defer(function() order[#order + 1] = "deferred" end) end)
    frame(0.02)
    t.eq(table.concat(order, " "), "1 2 3 4 5 frame deferred")
end)

t.test("task.cancel stops a waiting task and runs its close handlers; errors are reported, not raised", function()
    sched.reset()
    guard.clear_errors()
    local closed, resumed = false, false
    local thread = task.spawn(function()
        local _ <close> = setmetatable({}, { __close = function() closed = true end })
        task.wait(1)
        resumed = true
    end)
    task.cancel(thread)
    frame(2)
    t.ok(closed)
    t.eq(resumed, false)
    task.spawn(function() error("task blew up") end)
    t.eq(errors_mentioning("task blew up"), 1)
    t.raises(function() task.wait(1) end, "inside a task")
    t.raises(function() task.spawn(5) end, "expected a function or a thread")
end)

t.test("Signal: newest handler first, Once, Disconnect inside a handler, Wait", function()
    sched.reset()
    local signal, order = Signal.new("s"), {}
    signal:Connect(function(v) order[#order + 1] = "a" .. v end)
    local b
    b = signal:Connect(function(v) order[#order + 1] = "b" .. v b:Disconnect() end)
    signal:Once(function(v) order[#order + 1] = "once" .. v end)
    signal:Fire(1)
    signal:Fire(2)
    t.eq(table.concat(order, " "), "once1 b1 a1 a2")
    t.eq(signal.count, 1)
    local got
    task.spawn(function() got = table.pack(signal:Wait()) end)
    signal:Fire("x", "y")
    t.eq(got[1] .. got[2], "xy")
    t.eq(signal.count, 1, "the Wait connection removed itself")
    t.raises(function() signal:Wait() end, "inside a task")
end)

t.test("Signal: a handler may pause; the others still run; a failing handler does not stop the rest", function()
    sched.reset()
    guard.clear_errors()
    local signal, order = Signal.new("pausing"), {}
    signal:Connect(function() order[#order + 1] = "third" end)
    signal:Connect(function() error("handler failed") end)
    signal:Connect(function()
        order[#order + 1] = "first-before"
        task.wait(0.01)
        order[#order + 1] = "first-after"
    end)
    signal:Fire()
    t.eq(table.concat(order, " "), "first-before third")
    frame(0.02)
    t.eq(table.concat(order, " "), "first-before third first-after")
    t.eq(errors_mentioning("handler failed"), 1)
    signal:Fire()
    t.eq(order[#order], "third", "the signal still works after a failure")
end)

t.test("ownership: destroying a scope disconnects its handlers and cancels its sleeping tasks", function()
    sched.reset()
    local owner = scope.new("mod")
    local signal, hits, woke = Signal.new("owned"), 0, false
    scope.run(owner, function()
        signal:Connect(function() hits = hits + 1 end)
        task.spawn(function() task.wait(0.01) woke = true end)
        task.delay(0.01, function() woke = true end)
        signal:Connect(function() task.wait(0.01) woke = true end)
    end)
    signal:Fire()
    t.eq(hits, 1)
    owner:destroy()
    signal:Fire()
    frame(1)
    t.eq(hits, 1, "handler disconnected")
    t.eq(woke, false, "tasks cancelled")
    t.eq(signal.count, 0)
end)

t.test("ownership: a task keeps its creator's scope across pauses", function()
    sched.reset()
    local owner = scope.new("carrier")
    local seen = {}
    scope.run(owner, function()
        task.spawn(function()
            seen[1] = scope.current()
            task.wait()
            seen[2] = scope.current()
        end)
    end)
    t.eq(scope.current(), nil)
    frame()
    t.eq(seen[1], owner)
    t.eq(seen[2], owner)
    t.eq(scope.current(), nil)
end)

t.test("no growth: many fires, waits and finished tasks leave the owner scope empty", function()
    sched.reset()
    local owner = scope.new("busy")
    local signal = Signal.new("hot")
    local fired = 0
    scope.run(owner, function()
        signal:Connect(function() fired = fired + 1 end)
        task.spawn(function() for _ = 1, 2000 do task.wait() end end)
    end)
    for _ = 1, 2000 do
        signal:Fire()
        scope.run(owner, function() task.spawn(function() end) end)
        frame()
    end
    frame()
    t.eq(fired, 2000)
    t.eq(owner:size(), 1, "only the live connection remains registered")
    local slots = 0
    for _ in pairs(owner.undo) do slots = slots + 1 end
    t.eq(slots, 1, "no dead slots retained")
end)

t.test("frame budget: due timers beyond the budget carry over to the next frame", function()
    sched.reset()
    local saved = sched.resume_budget
    sched.resume_budget = 0.001
    local ran = 0
    for _ = 1, 10 do
        task.delay(0, function()
            ran = ran + 1
            now = now + 0.0005      -- each timer "costs" half a millisecond
        end)
    end
    frame()
    t.ok(ran < 10 and ran > 0, "only part of the batch ran: " .. ran)
    for _ = 1, 10 do frame() end
    sched.resume_budget = saved
    t.eq(ran, 10)
    t.ok(sched.stats.carried_over > 0)
end)

t.test("task.defer chains are cut off instead of looping forever", function()
    sched.reset()
    guard.clear_errors()
    local rounds = 0
    local function again() rounds = rounds + 1 task.defer(again) end
    task.defer(again)
    frame()
    t.eq(rounds, sched.max_defer_passes)
    t.eq(errors_mentioning("task.defer chain"), 1)
end)

t.test("FireDirect calls handlers without a coroutine and reports failures", function()
    sched.reset()
    guard.clear_errors()
    local signal, yieldable = Signal.new("direct"), nil
    signal:Connect(function() error("direct failed") end)
    signal:Connect(function() yieldable = coroutine.isyieldable() end)
    signal:FireDirect()
    t.eq(yieldable, false)
    t.eq(errors_mentioning("direct failed"), 1)
end)

t.finish("core")
