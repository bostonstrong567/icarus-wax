-- Live lists of actors, kept current from begin play and end play

local Wax = ...
local actors = Wax.import("engine.actors")
local instance = Wax.import("engine.instance")
local sched = Wax.import("core.sched")
local guard = Wax.import("core.guard")
local scope = Wax.import("core.scope")
local log = Wax.import("core.log").channel("wax.track")

local M = {}

local PENDING_KILL = EInternalObjectFlags and EInternalObjectFlags.PendingKill or 0x20000000
local TRIES = 30            -- frames an actor may take to learn its kind
local PER_FRAME = 60        -- new actors announced per frame

local sets = {}             -- name -> set
local active = {}           -- the sets that are tracking
local routes = {}           -- class address -> { name_index, sets }
local by_address = {}       -- actor address -> { [set] = entry }
local leaving = {}          -- removals waiting to be announced
local stop_began = nil

local Set = {}
Set.__index = Set

local function unlist(entry)
    if not entry.ready then return end
    local set = entry.set
    set.entries[entry.address] = nil
    set.count = set.count - 1
    for index, key in pairs({ kinds = entry.kind, variants = entry.variant }) do
        local group = key and set[index][key]
        if group then
            group[entry] = nil
            set.counts[index][key] = set.counts[index][key] - 1
        end
    end
end

local function list(entry)
    local set = entry.set
    entry.ready = true
    set.entries[entry.address] = entry
    set.count = set.count + 1
    for index, key in pairs({ kinds = entry.kind, variants = entry.variant }) do
        if key then
            local group = set[index][key]
            if not group then
                group = {}
                set[index][key] = group
            end
            group[entry] = true
            set.counts[index][key] = (set.counts[index][key] or 0) + 1
        end
    end
end

-- Takes an entry out for good. The engine object is dropped here and never touched again.
local function drop(entry, info)
    local was_ready = entry.ready and not entry.destroyed
    entry.destroyed = true
    entry.object = nil
    if was_ready then
        unlist(entry)
        if info then leaving[#leaving + 1] = { entry, info } end
    end
end

local function describe_end(entry, actor, reason)
    local info = { Kind = entry.kind, Variant = entry.variant, ClassName = entry.class_name, Name = entry.name,
                   Reason = reason == actors.DESTROYED and "Destroyed" or "Unloaded" }
    if actor then
        pcall(function()
            local spot = actor:K2_GetActorLocation()
            info.Position = { X = spot.X, Y = spot.Y, Z = spot.Z }
        end)
    end
    return info
end

local function add(set, actor, address)
    local owned = by_address[address]
    local name_index = actor:GetFName():GetComparisonIndex()
    if owned then
        local existing = owned[set]
        if existing then
            if existing.name_index == name_index then return nil end
            drop(existing, describe_end(existing, nil, actors.UNLOADED))
        end
    else
        owned = {}
        by_address[address] = owned
    end
    local entry = { set = set, address = address, object = actor, name_index = name_index, tries = 0,
                    ready = false, destroyed = false }
    owned[set] = entry
    return entry
end

-- Works out an entry's kind. Returns true when the entry is settled (listed or dropped).
local function settle(entry, last)
    local set = entry.set
    local ok, kind, variant = pcall(set.spec.classify, entry.object, last, entry)
    if not ok then
        guard.report(tostring(kind), "track." .. set.name)
        kind = false
    end
    if kind == nil and not last then return false end
    if kind == false then
        local owned = by_address[entry.address]
        owned[set] = nil
        if next(owned) == nil then by_address[entry.address] = nil end
        entry.destroyed, entry.object = true, nil
        return true
    end
    entry.kind, entry.variant = kind or "Unknown", variant
    entry.instance = instance.wrap(entry.object)
    entry.class_name = entry.instance.ClassName
    entry.name = entry.object:GetFName():ToString()
    list(entry)
    return true
end

local function seed(set, quiet)
    set.need_seed = false
    for _, class_name in ipairs(set.spec.seed) do
        local found = FindAllOf(class_name)
        if found then
            for i = 1, #found do
                local actor = found[i]
                if actor:IsValid() and not actor:HasAnyInternalFlags(PENDING_KILL) then
                    local entry = add(set, actor, actor:GetAddress())
                    if entry then
                        if quiet then settle(entry, true) else set.pending[#set.pending + 1] = entry end
                    end
                end
            end
        end
    end
end

local function learn(actor, class_address, name_index)
    local route = { name_index = name_index, sets = false }
    for i = 1, #active do
        local set = active[i]
        for r = 1, #set.roots do
            if actor:IsA(set.roots[r]) then
                route.sets = route.sets or {}
                route.sets[#route.sets + 1] = set
                break
            end
        end
    end
    routes[class_address] = route
    return route
end

local function began(actor)
    local class = actor:GetClass()
    local class_address = class:GetAddress()
    local name_index = class:GetFName():GetComparisonIndex()
    local route = routes[class_address]
    if not route or route.name_index ~= name_index then route = learn(actor, class_address, name_index) end
    local wanted = route.sets
    if not wanted then return end
    local address = actor:GetAddress()
    for i = 1, #wanted do
        local set = wanted[i]
        local entry = add(set, actor, address)
        if entry then set.pending[#set.pending + 1] = entry end
    end
end

local function ended(actor, address, reason)
    local owned = by_address[address]
    if not owned then return end
    by_address[address] = nil
    local silent = reason == actors.MAP_CHANGE or reason == actors.QUIT
    for _, entry in pairs(owned) do
        drop(entry, not silent and entry.ready and describe_end(entry, actor, reason) or nil)
    end
end

local function clear()
    routes, by_address, leaving = {}, {}, {}
    for i = 1, #active do
        local set = active[i]
        for _, entry in pairs(set.entries) do entry.destroyed, entry.object = true, nil end
        for _, entry in ipairs(set.pending) do entry.destroyed, entry.object = true, nil end
        set.entries, set.pending, set.count = {}, {}, 0
        set.kinds, set.variants, set.counts = {}, {}, { kinds = {}, variants = {} }
        set.need_seed = true
        set.Cleared:Fire()
    end
end

local function announce(set)
    local pending, later, done = set.pending, {}, 0
    set.pending = later
    for i = 1, #pending do
        local entry = pending[i]
        if not entry.destroyed then
            if done >= PER_FRAME then
                later[#later + 1] = entry
            else
                entry.tries = entry.tries + 1
                if settle(entry, entry.tries >= TRIES) then
                    if entry.ready then
                        done = done + 1
                        set.Added:Fire(entry.instance)
                    end
                else
                    later[#later + 1] = entry
                end
            end
        end
    end
end

-- spec: roots (class paths), seed (class names), classify(actor, last, entry) -> kind, variant, and an optional step(set).
-- classify returns nil to be asked again next frame and false for an actor that does not belong.
function M.define(name, spec)
    local set = setmetatable({
        name = name, spec = spec, roots = {}, tracking = false, need_seed = false,
        entries = {}, pending = {}, count = 0, kinds = {}, variants = {}, counts = { kinds = {}, variants = {} },
        Added = sched.Signal.new(name .. ".Added"), Removed = sched.Signal.new(name .. ".Removed"),
        Cleared = sched.Signal.new(name .. ".Cleared"),
    }, Set)
    sets[name] = set
    return set
end

-- Starts tracking on first use, so a list no mod asks for costs nothing.
function Set:use()
    if self.tracking then return self end
    for _, path in ipairs(self.spec.roots) do
        local class = StaticFindObject(path)
        if class:IsValid() then
            self.roots[#self.roots + 1] = class
        else
            log:warn("the class %s was not found, so the list of %s may be incomplete", path, self.name)
        end
    end
    self.tracking = true
    active[#active + 1] = self
    routes = {}
    if not stop_began then stop_began = actors.on_began(began) end
    seed(self, true)
    return self
end

-- The entry for an Instance, or nil when it is not in this list (any more).
function Set:entry_of(target)
    if not instance.is_instance(target) then return nil end
    local owned = by_address[instance.address(target)]
    local entry = owned and owned[self]
    if entry and entry.ready and not entry.destroyed and entry.instance == target then return entry end
    return nil
end

-- Calls fn(instance) for every listed entry that fits, now and as more appear. What fn returns runs when that one is gone.
function Set:observe(fits, fn, label)
    local set, undo, stopped = self, {}, false
    local function see(target)
        if stopped or undo[target] ~= nil then return end
        local entry = set:entry_of(target)
        if not entry or not fits(entry) then return end
        undo[target] = false
        local ok, result = guard.call(label, fn, target)
        if ok and type(result) == "function" then
            if undo[target] == false then undo[target] = result else guard.call(label, result, target) end
        end
    end
    local function forget(target)
        local cleanup = undo[target]
        undo[target] = nil
        if cleanup then guard.call(label, cleanup, target) end
    end
    local function forget_all()
        local old = undo
        undo = {}
        for target, cleanup in pairs(old) do
            if cleanup then guard.call(label, cleanup, target) end
        end
    end
    local added, removed, cleared = set.Added:Connect(see), set.Removed:Connect(forget), set.Cleared:Connect(forget_all)
    local connection = { Connected = true }
    local owner, slot
    function connection:Disconnect()
        if stopped then return end
        stopped, self.Connected = true, false
        added:Disconnect()
        removed:Disconnect()
        cleared:Disconnect()
        forget_all()
        if owner and slot then owner:remove(slot) end
    end
    owner, slot = scope.own(function() connection:Disconnect() end)
    local now = {}
    for _, entry in pairs(set.entries) do now[#now + 1] = entry end
    for _, entry in ipairs(now) do
        if not entry.destroyed then see(entry.instance) end
    end
    return connection
end

function M.step()
    for i = 1, #active do
        local set = active[i]
        if set.need_seed then seed(set, false) end
        if #set.pending > 0 then announce(set) end
        if set.spec.step then set.spec.step(set) end
    end
    if #leaving > 0 then
        local gone = leaving
        leaving = {}
        for i = 1, #gone do
            local entry, info = gone[i][1], gone[i][2]
            entry.set.Removed:Fire(entry.instance, info)
        end
    end
end

function M.start()
    actors.on_ended(ended)
    Wax.import("engine.game").root.MapChanged:Connect(clear)
end

function M.stats()
    local out, known = {}, 0
    for _ in pairs(routes) do known = known + 1 end
    for name, set in pairs(sets) do
        out[name] = { tracking = set.tracking, count = set.count, pending = #set.pending }
    end
    return { sets = out, classes = known, hooks = actors.stats() }
end

M.sets = sets
return M
