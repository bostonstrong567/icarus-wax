-- The scheduler: tasks, timers, signals and the per-frame step

local Wax = ...
local co = Wax.import("core.co")
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")

local sched = {}

sched.clock = os.clock              -- returns seconds (replaced in tests)
sched.resume_budget = 0.002         -- seconds per frame for resuming due timers. The rest waits a frame.
sched.max_defer_passes = 80         -- a chain of defers that keeps deferring is cut after this many rounds
sched.stats = { frame = 0, resumed = 0, carried_over = 0, live_timers = 0, step_seconds = 0 }

local stats = sched.stats
local co_create, co_resume, co_yield, co_running, co_status, co_close, co_isyieldable =
    co.create, co.resume, co.yield, co.running, co.status, co.close, co.isyieldable
local traceback = debug.traceback
local pack, unpack, select, type, error, tostring = table.pack, table.unpack, select, type, error, tostring

-- thread -> { owner = Scope or false, label, cancelled }
local threads = setmetatable({}, { __mode = "k" })

local function track(thread, label)
    local owner = scope.current()
    local record = { owner = owner or false, label = label, cancelled = false }
    threads[thread] = record
    return record
end

-- While a thread is parked it is listed with its owner, so destroying the owner cancels it.
local function park(thread, record)
    if record.owner and not record.slot then
        record.slot = record.owner:add(function() sched.task.cancel(thread) end)
    end
end

local function unpark(record)
    if record.slot then
        record.owner:remove(record.slot)
        record.slot = nil
    end
end

local function after_resume(thread, record, previous, ok, ...)
    scope.leave(previous)
    stats.resumed = stats.resumed + 1
    if not ok then
        local err = ...
        guard.report(traceback(thread, type(err) == "string" and err or ("(error value: " .. tostring(err) .. ")")),
            record.label or "task", record.owner or nil)
        co_close(thread)
        return false
    end
    -- An idle signal runner is suspended too, but it is waiting for work, not parked on behalf of an owner.
    if co_status(thread) == "suspended" and not record.idle then park(thread, record) end
    return true, ...
end

-- Resumes a task under its owner's scope
local function resume(thread, ...)
    local record = threads[thread] or track(thread)
    if record.cancelled or co_status(thread) ~= "suspended" then return false end
    unpark(record)
    guard.arm()
    local previous = scope.enter(record.owner or nil)
    return after_resume(thread, record, previous, co_resume(thread, ...))
end
sched.resume = resume

local function as_thread(f, label)
    local kind = type(f)
    if kind == "thread" then
        if not threads[f] then track(f, label) end
        return f
    end
    if kind ~= "function" then error("expected a function or a thread, got " .. kind, 3) end
    local thread = co_create(f)
    track(thread, label)
    return thread
end

-- timer heap: ordered by due time, ties in insertion order so equal waits resume first in, first out
local heap, heap_n, seq = {}, 0, 0

local function less(a, b)
    if a.at ~= b.at then return a.at < b.at end
    return a.seq < b.seq
end

local function heap_push(entry)
    seq = seq + 1
    entry.seq = seq
    heap_n = heap_n + 1
    local i = heap_n
    while i > 1 do
        local parent = i // 2
        if not less(entry, heap[parent]) then break end
        heap[i] = heap[parent]
        i = parent
    end
    heap[i] = entry
end

local function heap_pop()
    local top = heap[1]
    local last = heap[heap_n]
    heap[heap_n] = nil
    heap_n = heap_n - 1
    if heap_n > 0 then
        local i = 1
        while true do
            local child = i * 2
            if child > heap_n then break end
            if child < heap_n and less(heap[child + 1], heap[child]) then child = child + 1 end
            if not less(heap[child], last) then break end
            heap[i] = heap[child]
            i = child
        end
        heap[i] = last
    end
    return top
end

local task = {}
sched.task = task

local deferred, deferred_n = {}, 0
local step_started = nil    -- clock value when the current step began, nil outside a step

-- Deadlines use the live clock, and a wait made during a step is never due in that same step.
local function due_in(seconds)
    if not seconds or seconds < 0 then seconds = 0 end
    local at = sched.clock() + seconds
    if step_started and at <= step_started then at = step_started + 1e-9 end
    return at
end

-- Runs f now, until it returns or first pauses. Returns the thread.
function task.spawn(f, ...)
    local thread = as_thread(f)
    resume(thread, ...)
    return thread
end

-- Runs f at the end of the current frame's step (or of the next one, when called outside a step).
function task.defer(f, ...)
    local thread = as_thread(f)
    park(thread, threads[thread])
    deferred_n = deferred_n + 1
    deferred[deferred_n] = { thread = thread, args = select("#", ...) > 0 and pack(...) or nil }
    return thread
end

-- Runs f after `seconds`, never earlier than the next frame. Returns the thread, which task.cancel stops.
function task.delay(seconds, f, ...)
    local thread = as_thread(f)
    park(thread, threads[thread])
    heap_push({ at = due_in(seconds), thread = thread, args = select("#", ...) > 0 and pack(...) or nil })
    return thread
end

-- Pauses the calling task for `seconds` (at least until the next frame). Returns the time it waited.
function task.wait(seconds)
    if not co_isyieldable() then
        error("task.wait can only be used inside a task. Wrap the code in task.spawn(function() ... end)", 2)
    end
    local thread = co_running()
    if not threads[thread] then track(thread) end
    heap_push({ at = due_in(seconds), thread = thread, wait_from = sched.clock() })
    return co_yield()
end

-- Stops a task. It cannot be resumed afterwards.
function task.cancel(thread)
    if type(thread) ~= "thread" then error("task.cancel expects a thread, got " .. type(thread), 2) end
    local record = threads[thread] or track(thread)
    record.cancelled = true
    unpark(record)
    if co_status(thread) == "suspended" then
        local ok, err = co_close(thread)
        if not ok then guard.report(tostring(err), record.label or "task (while cancelling)", record.owner or nil) end
    end
end

-- Names a task for error messages and the debugger.
function task.label(thread, label)
    local record = threads[thread] or track(thread)
    record.label = label
    return thread
end

-- Signals. Fire runs each handler in a reused coroutine, so a handler may pause like any task.
local Signal = {}
Signal.__index = Signal
sched.Signal = Signal

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
    if not self.Connected then return end
    self.Connected = false
    local signal = self.signal
    -- Unlink only. A Fire in progress holds its own next pointer, so disconnecting inside a handler is safe.
    if signal.head == self then
        signal.head = self.next
    else
        local previous = signal.head
        while previous and previous.next ~= self do previous = previous.next end
        if previous then previous.next = self.next end
    end
    signal.count = signal.count - 1
    if self.owner and self.slot then self.owner:remove(self.slot) end
end

function Signal.new(name)
    return setmetatable({ head = false, count = 0, name = name or "Signal" }, Signal)
end

-- Calls fn(...) on every Fire, newest connection first. Returns a connection with :Disconnect().
function Signal:Connect(fn)
    if type(fn) ~= "function" then error("Connect expects a function, got " .. type(fn), 2) end
    local connection = setmetatable({ Connected = true, signal = self, fn = fn, next = self.head }, Connection)
    self.head = connection
    self.count = self.count + 1
    local owner = scope.current()
    if owner then
        connection.owner = owner
        connection.slot = owner:add(function() connection:Disconnect() end)
    end
    return connection
end

-- Like Connect, for the next Fire only.
function Signal:Once(fn)
    if type(fn) ~= "function" then error("Once expects a function, got " .. type(fn), 2) end
    local connection
    connection = self:Connect(function(...)
        connection:Disconnect()
        return fn(...)
    end)
    return connection
end

-- Pauses the calling task until the next Fire and returns what was fired.
function Signal:Wait()
    if not co_isyieldable() then
        error("Signal:Wait can only be used inside a task. Wrap the code in task.spawn(function() ... end)", 2)
    end
    local thread = co_running()
    if not threads[thread] then track(thread) end
    local connection
    connection = self:Connect(function(...)
        connection:Disconnect()
        resume(thread, ...)
    end)
    return co_yield()
end

local free_runner = nil

local function run_handler(fn, ...)
    local me = co_running()
    local record = threads[me]
    record.idle = false
    free_runner = nil               -- taken: a handler that pauses keeps this runner for itself
    fn(...)
    record.idle = true              -- finished, so it waits for work again and has no owner
    record.owner = false
    free_runner = me
end

local function runner_body(...)
    run_handler(...)
    while true do run_handler(co_yield()) end
end

function Signal:Fire(...)
    local connection = self.head
    while connection do
        local next_connection = connection.next
        if connection.Connected then
            local runner = free_runner
            if not runner or co_status(runner) ~= "suspended" then
                runner = co_create(runner_body)
                free_runner = runner
            end
            -- The runner serves whichever connection is being fired, so it takes on that connection's owner.
            local record = threads[runner]
            if not record then
                record = { owner = false, cancelled = false }
                threads[runner] = record
            end
            unpark(record)
            record.owner = connection.owner or false
            record.label = self.name
            record.cancelled = false
            resume(runner, connection.fn, ...)
            if free_runner ~= runner and co_status(runner) == "dead" then free_runner = nil end
        end
        connection = next_connection
    end
end

-- Like Fire, but handlers are called directly, without a coroutine. They must not pause.
function Signal:FireDirect(...)
    local connection = self.head
    while connection do
        local next_connection = connection.next
        if connection.Connected then
            guard.arm()
            local previous = scope.enter(connection.owner or nil)
            local ok, err = xpcall(connection.fn, guard.handler, ...)
            scope.leave(previous)
            if not ok then guard.report(err, self.name, connection.owner) end
        end
        connection = next_connection
    end
end

function Signal:DisconnectAll()
    local connection = self.head
    while connection do
        local next_connection = connection.next
        connection:Disconnect()
        connection = next_connection
    end
end

sched.Frame = Signal.new("Frame")   -- fired once per frame with the seconds since the previous frame

local function flush_deferred()
    local passes = 0
    while deferred_n > 0 do
        passes = passes + 1
        if passes > sched.max_defer_passes then
            guard.report(("task.defer chain longer than %d rounds. The rest was dropped"):format(sched.max_defer_passes), "task.defer")
            deferred, deferred_n = {}, 0
            return
        end
        local batch, n = deferred, deferred_n
        deferred, deferred_n = {}, 0
        for i = 1, n do
            local entry = batch[i]
            if entry.args then resume(entry.thread, unpack(entry.args, 1, entry.args.n)) else resume(entry.thread) end
        end
    end
end

local last_step = nil

-- Call once per frame from the game thread. Returns the seconds since the previous step.
function sched.step()
    local started = sched.clock()
    local dt = last_step and (started - last_step) or 0
    last_step = started
    step_started = started
    stats.frame = stats.frame + 1

    -- 1. Timers and waits that are due, oldest first, within the frame budget.
    local deadline = started + sched.resume_budget
    while heap_n > 0 and heap[1].at <= started do
        if sched.clock() > deadline then
            stats.carried_over = stats.carried_over + 1
            break
        end
        local entry = heap_pop()
        if entry.wait_from then
            resume(entry.thread, started - entry.wait_from)
        elseif entry.args then
            resume(entry.thread, unpack(entry.args, 1, entry.args.n))
        else
            resume(entry.thread)
        end
    end

    -- 2. The per-frame signal.
    sched.Frame:Fire(dt)

    -- 3. Everything deferred during this frame.
    flush_deferred()

    step_started = nil
    stats.live_timers = heap_n
    stats.step_seconds = sched.clock() - started
    return dt
end

-- For tests and for a full core reload: forget all timers and deferred work.
function sched.reset()
    heap, heap_n, deferred, deferred_n, last_step, step_started = {}, 0, {}, 0, nil, nil
    sched.Frame:DisconnectAll()
    free_runner = nil
end

return sched
