-- Signals fed by looking: a value is read a few times a second while something is connected, and fired when it changed

local Wax = ...
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local suggest = Wax.import("core.suggest")
local co = Wax.import("core.co")
local perf = Wax.import("core.perf")
local log = Wax.import("core.log").channel("wax.watch")

local M = {}

M.BASE = 0.05               -- seconds: every pace is a whole number of these, so looks of different paces fall in the same frames
M.EVERY = 0.1               -- the pace when none is asked for
M.SLOWEST = 3600            -- the longest time between two looks that is accepted
M.RETRY = 5                -- seconds between tries at a value that keeps failing to be read
M.WATCH_ANY_OBJECT = false  -- true also watches objects whose end Wax is not told about. Asking one that is gone can crash the game.

local BASE, DEPTH = M.BASE, 3
local UNSET = {}
local floor, type, pairs, getmetatable = math.floor, type, pairs, getmetatable

local beats, order = {}, {}         -- ticks -> the watchers looked at every that many BASE, and the same beats as a list
local active = 0                    -- watchers being looked at
local link = nil                    -- the connection to the frame signal, held only while something is watched
local driven = false                -- true once the frame loop calls M.step. Then there is no link
local epoch, last = 0, 0
local pass, in_round = 0, false     -- a pass is one round of looks. What is found in it is shared
local counts = { rounds = 0, looks = 0, fired = 0, failed = 0, ended = 0, scanned = 0, seconds = 0 }
local watcher_of = setmetatable({}, { __mode = "k" })       -- signal -> watcher
local by_instance = setmetatable({}, { __mode = "k" })      -- Instance -> { name -> watcher }
local holders = setmetatable({}, { __mode = "k" })          -- component Instance -> { its actor, the property that keeps it } or false
local vouched = setmetatable({}, { __mode = "k" })          -- component Instance -> the pass in which its actor last answered for it
local plain_connect, plain_disconnect = sched.Signal.Connect, nil
local guarded, breaker

-- Plain tables are compared by what they hold. Anything with a metatable (an Instance) is compared as it is.
local function same(a, b, depth)
    if a == b then return true end
    local kind = type(a)
    if kind == "number" then return a ~= a and b ~= b end
    if kind ~= "table" or type(b) ~= "table" or depth > DEPTH then return false end
    if getmetatable(a) ~= nil or getmetatable(b) ~= nil then return false end
    for key, value in pairs(a) do
        if not same(value, b[key], depth + 1) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

-- What is remembered is a copy, so a reader that changes its own table is still seen to have changed.
local function keep(value, depth)
    if type(value) ~= "table" or getmetatable(value) ~= nil or depth > DEPTH then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = keep(item, depth + 1) end
    return copy
end

local function ticks_of(seconds)
    local ticks = floor(seconds / BASE + 0.5)
    return ticks < 1 and 1 or ticks
end

local function join(watcher)
    local beat = beats[watcher.ticks]
    if not beat then
        beat = { ticks = watcher.ticks, n = 0 }
        beats[watcher.ticks] = beat
        order[#order + 1] = beat
    end
    beat.n = beat.n + 1
    beat[beat.n] = watcher
    watcher.beat, watcher.at = beat, beat.n
end

local function unjoin(watcher)
    local beat = watcher.beat
    local moved = beat[beat.n]
    beat[watcher.at], moved.at = moved, watcher.at
    beat[beat.n] = nil
    beat.n = beat.n - 1
    watcher.beat, watcher.at = nil, nil
    if beat.n > 0 then return end
    beats[beat.ticks] = nil
    for i = #order, 1, -1 do
        if order[i] == beat then table.remove(order, i) end
    end
end

local function stop(watcher)
    if not watcher.polling then return end
    watcher.polling, watcher.value = false, UNSET
    unjoin(watcher)
    active = active - 1
    if active == 0 and link then
        link:Disconnect()
        link = nil
    end
end

-- The watched object is gone: nothing is read again and every handler is let go.
local function finish(watcher)
    counts.ended = counts.ended + 1
    watcher.ended = ("the %s this signal watched no longer exists"):format(watcher.what)
    log:debug("%s is no longer watched, because the object is gone", watcher.name)
    stop(watcher)
    watcher.signal:DisconnectAll()
end

local function failed(watcher, trace, now)
    counts.failed = counts.failed + 1
    local failures = watcher.failures + 1
    watcher.failures = failures
    if failures == 1 then guard.report(trace, "watching " .. watcher.name) end
    if failures < guard.breaker_errors then return end
    if failures == guard.breaker_errors then
        log:warn("%s could not be read %d times in a row. It is tried every %g seconds until it can be read again",
            watcher.name, failures, M.RETRY)
    end
    watcher.rest = now + M.RETRY
end

-- Looks once. Returns true, the value and the one before when it changed. The first look only takes note.
local function look(watcher, now)
    local gone = watcher.gone
    if gone and gone(watcher, false) then
        finish(watcher)
        return false
    end
    counts.looks = counts.looks + 1
    local old, ok, value = watcher.value, nil, nil
    if old == UNSET then
        ok, value = xpcall(watcher.read, guard.handler)
    else
        ok, value = xpcall(watcher.read, guard.handler, old)
    end
    if not ok then
        if gone and gone(watcher, true) then finish(watcher) else failed(watcher, value, now) end
        return false
    end
    if watcher.failures > 0 then
        if watcher.rest then log:info("%s can be read again", watcher.name) end
        watcher.failures, watcher.rest = 0, nil
    end
    if old ~= UNSET and same(value, old, 1) then return false end
    watcher.value = keep(value, 1)
    if old == UNSET then return false end
    return true, value, old
end

-- One round: every watcher whose pace is due is looked at. Returns what changed as watcher, value, value before, ...
local function round(now, now_tick, before)
    local changes, n = nil, 0
    for i = #order, 1, -1 do
        local beat = order[i]
        local ticks = beat and beat.ticks
        if ticks and (ticks == 1 or now_tick // ticks ~= before // ticks) then
            for slot = beat.n, 1, -1 do
                local watcher = beat[slot]
                if watcher then
                    if watcher.signal.count == 0 then
                        stop(watcher)
                    elseif not (watcher.rest and now < watcher.rest) then
                        local changed, value, old = look(watcher, now)
                        if changed then
                            changes = changes or {}
                            changes[n + 1], changes[n + 2], changes[n + 3] = watcher, value, old
                            n = n + 3
                        end
                    end
                end
            end
        end
    end
    return changes, n
end

local function run(now, now_tick, before)
    pass = pass + 1
    counts.rounds = counts.rounds + 1
    local started = perf.now()
    in_round = true
    local ok, changes, n = xpcall(round, debug.traceback, now, now_tick, before)
    in_round = false
    counts.seconds = counts.seconds + (perf.now() - started)
    if not ok then error(changes, 0) end
    if not changes then return end
    -- handlers run after every look of the frame, so all of them see the same moment
    for i = 1, n, 3 do
        local watcher = changes[i]
        if watcher.polling then
            counts.fired = counts.fired + 1
            watcher.signal:Fire(changes[i + 1], changes[i + 2])
        end
    end
end

do
    -- made for no mod: this module may be loaded in the middle of a mod's call
    local previous = scope.enter(nil)
    guarded, breaker = guard.wrap("watch", run)
    scope.leave(previous)
end

-- Once a frame while something is watched. Most frames end at the comparison.
local function on_frame()
    local now = sched.clock()
    local now_tick = (now - epoch) // BASE
    if now_tick == last then return end
    local before = last
    last = now_tick
    for i = 1, #order do
        local ticks = order[i].ticks
        if ticks == 1 or now_tick // ticks ~= before // ticks then return guarded(now, now_tick, before) end
    end
end

-- For the frame loop. Called from there, nothing is put on the frame signal, which costs a task a frame.
function M.step()
    if not driven then
        driven = true
        if link then
            link:Disconnect()
            link = nil
        end
    end
    if active > 0 then on_frame() end
end

local function start(watcher)
    if watcher.polling then return end
    watcher.polling, watcher.failures, watcher.rest, watcher.value = true, 0, nil, UNSET
    join(watcher)
    active = active + 1
    local previous = scope.enter(nil)
    breaker.off, breaker.failures = false, 0
    if active == 1 then epoch, last = sched.clock(), 0 end
    if not driven and not (link and link.Connected) then link = sched.Frame:Connect(on_frame) end
    pass = pass + 1
    local was = in_round
    in_round = true
    local ok, problem = pcall(look, watcher, sched.clock())
    in_round = was
    scope.leave(previous)
    if not ok then guard.report(tostring(problem), "watching " .. watcher.name) end
end

-- Takes the place of a connection's own Disconnect: the last handler to leave ends the looking at once.
local function leave(connection)
    if not connection.Connected or not plain_disconnect then return end
    plain_disconnect(connection)
    local signal = connection.signal
    local watcher = watcher_of[signal]
    if watcher and signal.count == 0 then stop(watcher) end
end

local function connect(self, fn)
    if type(fn) ~= "function" then error("Connect expects a function, got " .. type(fn), 2) end
    local watcher = watcher_of[self]
    if not watcher then return plain_connect(self, fn) end
    if watcher.ended then error(watcher.ended, 2) end
    local connection = plain_connect(self, fn)
    if rawget(connection, "Disconnect") == nil then
        plain_disconnect = plain_disconnect or connection.Disconnect
        connection.Disconnect = leave
    end
    start(watcher)
    if watcher.ended then error(watcher.ended, 2) end
    return connection
end

local function new_watcher(name, ticks, read)
    local signal = sched.Signal.new(name)
    local watcher = { name = name, signal = signal, read = read, ticks = ticks, value = UNSET, failures = 0, polling = false }
    watcher_of[signal] = watcher
    signal.Connect = connect
    return watcher
end

local function pace(seconds, what, level)
    if type(seconds) ~= "number" or not (seconds > 0) or seconds > M.SLOWEST then
        error(("%s: the seconds between looks are a number above 0, such as 0.5, got %s"):format(what, tostring(seconds)), level)
    end
    return ticks_of(seconds)
end

local OPTIONS = { "read", "every" }

-- A signal fired with (value, previous) when what read(previous) returns changes. It is read only while a handler is connected.
function M.signal(name, options)
    if type(name) ~= "string" or name == "" then error("watch.signal expects a name for the signal, got " .. type(name), 2) end
    if type(options) ~= "table" or type(options.read) ~= "function" then
        error("watch.signal expects { read = function, every = seconds }", 2)
    end
    for key in pairs(options) do
        if key ~= "read" and key ~= "every" then
            error(("watch.signal has no option '%s'.%s"):format(tostring(key), suggest.phrase(tostring(key), OPTIONS)), 2)
        end
    end
    local ticks = options.every == nil and ticks_of(M.EVERY) or pace(options.every, "watch.signal", 3)
    return new_watcher(name, ticks, options.read).signal
end

-- Forgets what a signal last saw, so its next look only takes note. For when what is watched was swapped for another.
function M.reset(signal)
    local watcher = watcher_of[signal]
    if watcher then watcher.value = UNSET end
end

-- Looks now, between the usual looks, and fires when the value changed. For a module that was told something happened.
function M.check(signal)
    local watcher = watcher_of[signal]
    if not watcher or not watcher.polling then return false end
    pass = pass + 1
    local previous, was = scope.enter(nil), in_round
    in_round = true
    local ok, changed, value, old = pcall(look, watcher, sched.clock())
    in_round = was
    scope.leave(previous)
    if not (ok and changed) then return false end
    counts.fired = counts.fired + 1
    signal:Fire(value, old)
    return true
end

-- A getter that runs find() once for a whole round of looks. Outside a round it runs find() every time.
function M.shared(find)
    if type(find) ~= "function" then error("watch.shared expects a function, got " .. type(find), 2) end
    local value, seen = nil, -1
    return function()
        if in_round and seen == pass then return value end
        value = nil
        value = find()
        seen = pass
        return value
    end
end

local game_root = nil

-- The local player's character, found once for every watcher of a round. Nil while there is none.
M.character = M.shared(function()
    game_root = game_root or Wax.import("engine.game").root
    return game_root.Character
end)

-- watching one value of an Instance

local WATCHABLE = {
    BoolProperty = true, Int8Property = true, Int16Property = true, IntProperty = true, Int64Property = true, ByteProperty = true,
    UInt16Property = true, UInt32Property = true, UInt64Property = true, EnumProperty = true, FloatProperty = true,
    NameProperty = true, StrProperty = true, TextProperty = true, ObjectProperty = true, ClassProperty = true,
}
local REFUSED = {
    StructProperty = "a struct, which Lua cannot compare", ArrayProperty = "a list, which Lua cannot compare",
    MapProperty = "a map, which Lua cannot compare", SetProperty = "a set, which Lua cannot compare",
    DoubleProperty = "a double, which Wax does not read yet",
    DelegateProperty = "an event of the game's, not a value", MulticastDelegateProperty = "an event of the game's, not a value",
    MulticastInlineDelegateProperty = "an event of the game's, not a value",
    MulticastSparseDelegateProperty = "an event of the game's, not a value",
}

local function check_name(tools, inst, info, name)
    if tools.own(name) then
        error(("%s is one of the names Wax gives every object, and those cannot be watched. "
            .. "Give the name of a property of the object, or of a field Wax gives its class"):format(name), 0)
    end
    local added = tools.added(info)
    if added then
        if added.fields[name] then return end
        if added.methods[name] then error(("%s is a method of %s, and only a value can be watched"):format(name, info.name), 0) end
        if added.setters[name] then error(("%s of %s can be set and not read, so it cannot be watched"):format(name, info.name), 0) end
    end
    local member = info.members[name]
    if not member then error(tools.unknown(inst, name, "a property", true), 0) end
    if member.kind ~= "property" then
        error(("%s is a function of %s, and only a value can be watched"):format(name, info.name), 0)
    end
    if not WATCHABLE[member.type] then
        error(("%s.%s is %s, so it cannot be watched. A number, true or false, text and an object can be")
            :format(info.name, name, REFUSED[member.type] or ("of a kind Wax does not read yet (" .. member.type .. ")")), 0)
    end
end

-- A class's default object never begins or ends play, so nothing says when it is gone.
local function is_default(raw) return raw:GetFName():ToString():find("^Default__") ~= nil end

-- The actor a component belongs to and the property of that actor which keeps it. Nothing when there is none.
local function holder(tools, inst)
    local raw = tools.live(inst)
    local outer = raw:GetOuter()
    local owner = outer:IsValid() and tools.wrap(outer) or nil
    if not owner then return nil end
    local owner_info = tools.info(owner)
    if not owner_info.ancestors.Actor then return nil end
    local owner_raw, address, members = tools.live(owner), raw:GetAddress(), owner_info.members
    if is_default(owner_raw) then return nil, "default" end
    local function keeps(name)
        local member = members[name]
        if not member or member.kind ~= "property" or member.type ~= "ObjectProperty" then return false end
        counts.scanned = counts.scanned + 1
        local held = owner_raw[name]
        return held:IsValid() and held:GetAddress() == address
    end
    local own_name = raw:GetFName():ToString()
    if keeps(own_name) then return owner, own_name end
    local list = owner_info.list
    for i = 1, #list do
        if list[i] ~= own_name and keeps(list[i]) then return owner, list[i] end
    end
    return nil
end

-- How Wax learns that the object is gone: for a component, its actor and the property that keeps it. Raises when there is no way.
local function footing(tools, inst, info, name)
    if tools.handled(inst) then return nil, nil, true end
    local hooks = rawget(_G, "WaxActorHooks")
    local told = Wax.actor_ended ~= nil and hooks ~= nil and hooks.registered == true
    local is_actor, is_part, default = info.ancestors.Actor == true, info.ancestors.ActorComponent == true, false
    if told and is_actor then
        default = is_default(tools.live(inst))
        if not default then return nil end
    elseif told and is_part then
        local found = holders[inst]
        if found == nil then
            local ok, owner, property = pcall(holder, tools, inst)
            found = ok and owner and { owner, property } or (ok and property == "default" and "default") or false
            holders[inst] = found
        end
        if type(found) == "table" then return found[1], found[2] end
        default = found == "default"
    end
    if M.WATCH_ANY_OBJECT then return nil end
    local tail = (", and asking an object that is gone can crash the game. Read %s yourself when you need it"):format(name)
    if not told and (is_actor or is_part) then
        error(("nothing can be watched, because Wax is not being told when actors leave the world (its world helpers did not start). "
            .. "Read %s yourself when you need it"):format(name), 0)
    end
    if default then
        error(("this %s is, or belongs to, the default object of a class and not something in the world, "
            .. "so Wax is not told when it is gone%s"):format(info.name, tail), 0)
    end
    if is_part then
        error(("this %s is not kept in a property of its actor, so Wax cannot tell that it is gone without asking it%s")
            :format(info.name, tail), 0)
    end
    error(("a %s is not an actor or a part of one, so Wax is not told when it is gone%s"):format(info.name, tail), 0)
end

local function held(tools, owner, property, address)
    local part = tools.live(owner)[property]
    return part:IsValid() and part:GetAddress() == address
end

-- True when the watched object is gone for good. Before a read the object itself is asked nothing.
local function instance_gone(watcher, after_failure)
    local tools, inst = watcher.tools, watcher.instance
    if tools.retired(inst) then return true end
    if after_failure then return not tools.alive(inst) end
    if watcher.by_handle then return not tools.handled(inst) end
    local owner = watcher.owner
    if not owner or vouched[inst] == pass then return false end
    if tools.retired(owner) then return true end
    local ok, there = pcall(held, tools, owner, watcher.property, watcher.address)
    if not (ok and there) then
        holders[inst] = nil
        return true
    end
    vouched[inst] = pass
    return false
end

-- What Instance:GetPropertyChangedSignal returns. `tools` is engine.instance's own view of an Instance.
function M.property(tools, inst, name, seconds)
    if type(name) ~= "string" or name == "" then
        error("GetPropertyChangedSignal expects the name of a value, such as \"Health\", got " .. type(name), 0)
    end
    local ticks = seconds ~= nil and pace(seconds, "GetPropertyChangedSignal", 0) or nil
    local mine = by_instance[inst]
    local watcher = mine and mine[name]
    if watcher and not watcher.ended then
        if ticks and ticks < watcher.ticks then
            if watcher.polling then unjoin(watcher) end
            watcher.ticks = ticks
            if watcher.polling then join(watcher) end
        end
        return watcher.signal
    end
    local info = tools.info(inst)
    check_name(tools, inst, info, name)
    local owner, property, by_handle = footing(tools, inst, info, name)
    watcher = new_watcher(info.name .. "." .. name, ticks or ticks_of(M.EVERY), function() return inst[name] end)
    watcher.what, watcher.gone, watcher.tools, watcher.instance = info.name, instance_gone, tools, inst
    watcher.owner, watcher.property, watcher.by_handle = owner, property, by_handle
    watcher.address = owner and tools.address(inst) or nil
    if not mine then
        mine = {}
        by_instance[inst] = mine
    end
    mine[name] = watcher
    return watcher.signal
end

-- game.Frame: the frame signal as mods get it. They connect to it and cannot fire it or disconnect Wax's own handlers.
local frame_methods = {}
local FRAME_NAMES = { "Connect", "Once", "Wait" }
local FRAME_OWN = { Fire = true, FireDirect = true, DisconnectAll = true }

function frame_methods:Connect(fn)
    if type(fn) ~= "function" then error("game.Frame:Connect expects a function, got " .. type(fn), 2) end
    return sched.Frame:Connect(fn)
end

function frame_methods:Once(fn)
    if type(fn) ~= "function" then error("game.Frame:Once expects a function, got " .. type(fn), 2) end
    return sched.Frame:Once(fn)
end

function frame_methods:Wait()
    if not co.isyieldable() then
        error("game.Frame:Wait can only be used inside a task. Wrap the code in task.spawn(function() ... end)", 2)
    end
    return sched.Frame:Wait()
end

local Frame = setmetatable({}, {
    __index = function(_, key)
        local method = frame_methods[key]
        if method then return method end
        if FRAME_OWN[key] then
            error(("game.Frame has no %s: Wax fires it once a frame, and a mod disconnects only what it connected"):format(key), 2)
        end
        error(("%s is not a member of game.Frame.%s"):format(tostring(key), suggest.phrase(tostring(key), FRAME_NAMES)), 2)
    end,
    __newindex = function(_, key) error(("game.Frame.%s cannot be assigned"):format(tostring(key)), 2) end,
    __tostring = function() return "game.Frame" end,
    __names = function() return FRAME_NAMES end,
})
M.Frame = Frame

function M.start()
    rawset(Wax.import("engine.game").root, "Frame", Frame)
end

function M.stats()
    local paces = {}
    for i = 1, #order do paces[i] = { every = order[i].ticks * BASE, watchers = order[i].n } end
    table.sort(paces, function(a, b) return a.every < b.every end)
    return { watching = active, linked = link ~= nil and link.Connected == true, driven = driven, off = breaker.off, paces = paces,
        rounds = counts.rounds, looks = counts.looks, fired = counts.fired, failed = counts.failed, ended = counts.ended,
        scanned = counts.scanned, seconds = counts.seconds }
end

return M
