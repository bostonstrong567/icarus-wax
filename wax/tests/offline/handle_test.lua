-- Offline tests for engine.handle: the engine's own "does this object still exist", and what Wax builds on it.
-- The first engine here is unkind in the ways the real one is: a freed address is given to the next object, UE4SS's
-- IsValid() says true on the old wrapper once that happens, a handle with nothing behind it hands back a wrapper and
-- not nil, any userdata in an object slot is read as an object, and reading freed memory is counted (the game dies of it).
-- The second part plugs the module into engine.instance on the stand-in world the other suites use.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\handle_test.lua

local t = dofile("wax/tests/offline/harness.lua")

-- --------------------------------------------------------------------------------------------- the unkind engine

local fake = { made = 0, conversions = 0, gets = 0, faults = 0, wild = 0 }
local UNREACHABLE, PENDING_KILL = 1 << 28, 1 << 29
local MARKER = -4097            -- UE4SS's pointer for a member that does not exist
local OBJECT_WRAPPERS = { UObject = true, AActor = true, UClass = true, UWorld = true, UDataTable = true, UEnum = true, UStruct = true }

local memory = {}               -- address -> the object that lives there now
local slots = {}                -- index -> { object, serial, flags }: the engine's object array
local free_addresses, free_indexes = {}, {}
local next_address, next_index, master_serial, serial = 0x20000, 0, 1000, 0
local seen = {}                 -- UE4SS's set: addresses Lua has wrapped and the engine has not destroyed since
local static = {}

local raw_type = type
rawset(_G, "type", function(value)
    local kind = raw_type(value)
    if kind == "table" and rawget(value, "__wrapper") then return "userdata" end
    return kind
end)

local function allocate(class_name, kind, rooted, name)
    local address = table.remove(free_addresses)
    if not address then
        next_address = next_address + 0x40
        address = next_address
    end
    local index = table.remove(free_indexes)
    if not index then
        next_index = next_index + 1
        index = next_index
    end
    serial = serial + 1
    local object = { address = address, index = index, class = class_name, kind = kind or "UObject", rooted = rooted or false,
        name = name or (class_name .. "_" .. serial) }
    memory[address] = object
    slots[index] = { object = object, serial = 0, flags = 0 }
    return object
end

-- What touching an object's memory does: on freed memory, or through a pointer that is no object, the game dies.
local function read(wrapper, what)
    local object = memory[rawget(wrapper, "ptr")]
    if not object then
        fake.faults = fake.faults + 1
        fake.fault_at = fake.fault_at or (what .. debug.traceback("", 3))
        error("read freed memory (" .. what .. ")", 3)
    end
    return object
end

local methods = {}
local Wrapper = {}
local wrap, pointer

-- A member that does not exist: not nil, not an object, and with no type() to ask.
local function no_member()
    return pointer("TrivialObject", { ptr = MARKER }, { GetAddress = function() return MARKER end, IsValid = function() return false end,
        type = false })
end

Wrapper.__index = function(self, key)
    local method = methods[key]
    if method then return method end
    read(self, tostring(key))
    return no_member()
end

function wrap(object, kind, ptr)
    if object then seen[object.address] = true end
    return setmetatable({ __wrapper = true, ptr = object and object.address or ptr or 0,
        kind = kind or (object and object.kind) or "UObject" }, Wrapper)
end

function methods.type(self) return rawget(self, "kind") end
function methods.GetAddress(self) return rawget(self, "ptr") end
-- UE4SS's own: the address is in its set and the object there is not marked unreachable. It reads the object.
function methods.IsValid(self)
    local ptr = rawget(self, "ptr")
    if ptr == 0 or ptr == MARKER or not seen[ptr] then return false end
    return slots[read(self, "IsValid").index].flags & UNREACHABLE == 0
end
function methods.GetFName(self)
    local name = read(self, "GetFName").name
    return { ToString = function() return name end }
end

local Pointer = {}
Pointer.__index = function(self, key)
    local method = rawget(self, "methods")[key]
    if method then return method end
    error("a " .. rawget(self, "kind") .. " has no " .. tostring(key), 2)
end

function pointer(kind, fields, own)
    fields.__wrapper, fields.kind, fields.methods = true, kind, own
    if own.type == nil then own.type = function(self) return rawget(self, "kind") end end
    return setmetatable(fields, Pointer)
end

local weak_methods, soft_methods = {}, {}
-- The engine's FWeakObjectPtr::Get. It reads the object array only, never the object.
function weak_methods.Get(self)
    fake.gets = fake.gets + 1
    if fake.broken == "get raises" then error("the weak pointer said no", 2) end
    local index, wanted = rawget(self, "index"), rawget(self, "serial")
    local slot = wanted ~= 0 and index >= 0 and slots[index] or nil
    if slot and slot.object and slot.serial == wanted and slot.flags & (UNREACHABLE | PENDING_KILL) == 0 then
        if fake.broken == "another object" then return wrap(static["/Engine/Transient"]) end
        return wrap(slot.object)
    end
    if fake.broken == "nothing answers" then return wrap(static["/Engine/Transient"]) end
    return wrap(nil)        -- a wrapper of nothing. Never nil
end
function soft_methods.GetWeakPtr(self)
    return pointer("FWeakObjectPtr", { index = rawget(self, "index"), serial = rawget(self, "serial") }, weak_methods)
end

-- KismetSystemLibrary's function, as UE4SS calls it: whatever userdata sits in the object slot is read as an object.
function methods.Conv_ObjectToSoftObjectReference(self, value)
    if read(self, "Conv_ObjectToSoftObjectReference").class ~= "KismetSystemLibrary" then error("no such function", 2) end
    fake.conversions = fake.conversions + 1
    if fake.broken == "convert raises" then error("the game said no", 2) end
    if fake.broken == "no soft reference" then return wrap(nil) end
    if value == nil then return pointer("TSoftObjectPtrUserdata", { index = -1, serial = 0 }, soft_methods) end
    if not (raw_type(value) == "table" and rawget(value, "__wrapper")) then error("Value must be UObject or nil", 2) end
    local ptr = rawget(value, "ptr")
    if ptr == 0 then return pointer("TSoftObjectPtrUserdata", { index = -1, serial = 0 }, soft_methods) end
    if not OBJECT_WRAPPERS[rawget(value, "kind")] or ptr == MARKER then
        fake.wild = fake.wild + 1
        error("a wild pointer was read as an object", 2)
    end
    local object = read(value, "the object's path")
    local slot = slots[object.index]
    if slot.serial == 0 then
        master_serial = master_serial + 1
        slot.serial = master_serial
    end
    return pointer("TSoftObjectPtrUserdata", { index = object.index, serial = slot.serial }, soft_methods)
end

local function install()
    rawset(_G, "StaticFindObject", function(path) return wrap(static[path]) end)
    rawset(_G, "StaticConstructObject", function(class)
        fake.made = fake.made + 1
        return wrap(allocate(read(class, "StaticConstructObject").name, "UObject"))
    end)
end

static["/Script/Engine.Default__KismetSystemLibrary"] = allocate("KismetSystemLibrary", "UObject", true, "Default__KismetSystemLibrary")
static["/Script/Engine.ObjectLibrary"] = allocate("Class", "UClass", true, "ObjectLibrary")
static["/Engine/Transient"] = allocate("Package", "UObject", true, "Transient")
install()

-- The engine hands over a new object of this kind.
function fake.new(kind, rooted)
    local object = allocate("Thing", kind or "UObject", rooted)
    return wrap(object), object
end

-- A collection marks what nothing holds. full = true also frees it at once, as a forced collection does.
function fake.collect(full)
    for _, slot in pairs(slots) do
        if slot.object and not slot.object.rooted then slot.flags = slot.flags | UNREACHABLE end
    end
    if full then fake.purge() end
end

function fake.purge()
    for index, slot in pairs(slots) do
        local object = slot.object
        if object and slot.flags & UNREACHABLE ~= 0 then
            seen[object.address] = nil
            memory[object.address] = nil
            free_addresses[#free_addresses + 1] = object.address
            free_indexes[#free_indexes + 1] = index
            slots[index] = { object = nil, serial = 0, flags = 0 }
        end
    end
end

function fake.destroy(object)
    object.rooted = false
    slots[object.index].flags = slots[object.index].flags | PENDING_KILL
end

-- New objects until one is given this address. Returns its wrapper and the object.
function fake.reuse(address)
    for _ = 1, 64 do
        local wrapper, object = fake.new("UObject", true)
        if object.address == address then return wrapper, object end
    end
    error("no new object was given the old address", 2)
end

-- ------------------------------------------------------------------------------------------------------- set-up

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)
local sched = Wax.import("core.sched")
local log = Wax.import("core.log")
local handle = Wax.import("engine.handle")

local clock = 0
sched.clock = function() return clock end
local function frames(count, seconds)
    for _ = 1, count or 1 do
        clock = clock + (seconds or (1 / 60))
        sched.step()
    end
end

-- One call of the frame loop, as boot wraps it: what fn does happens inside a frame.
local function in_frame(fn) return handle.framed(fn)() end

local function warnings(after) return log.since(after, { channel = "wax.handle", level = "warn" }) end

local function counted(fn)
    local conversions, gets = fake.conversions, fake.gets
    fn()
    return fake.conversions - conversions, fake.gets - gets
end

local function restart()
    fake.broken = nil
    t.eq(handle.start(), true, "handles start")
end

-- ---------------------------------------------------------------------------------------------- the self-check

t.test("before it is started the module is off: nothing is taken, nothing is known to be gone", function()
    local wrapper = fake.new()
    local made, conversions = fake.made, fake.conversions
    t.eq(handle.on(), false)
    local taken, why = handle.take(wrapper)
    t.eq(taken, nil)
    t.eq(why, "off")
    t.eq(handle.alive(nil), true)
    t.eq(handle.get(nil), nil)
    t.eq(handle.stats().why, "not started")
    t.eq(fake.made, made)
    t.eq(fake.conversions, conversions)
end)

t.test("start proves the mechanism on one throwaway object and switches handles on", function()
    local made, newest = fake.made, log.newest_id()
    t.eq(handle.start(), true)
    t.eq(handle.on(), true)
    t.eq(fake.made - made, 1, "one throwaway object")
    local state = handle.stats()
    t.eq(state.on, true)
    t.eq(state.confirmed, false, "the throwaway has not been let go yet")
    t.eq(state.why, nil)
    t.eq(#warnings(newest), 0)
    t.eq(fake.faults, 0)
    t.eq(fake.wild, 0)
end)

-- One look at the throwaway is due every WATCH_EVERY seconds: this many frames at 60 a second, and one to spare.
local LOOK = handle.WATCH_EVERY * 60 + 1

t.test("the throwaway is watched until the engine lets it go, and then no longer", function()
    restart()
    local listening = sched.Frame.count
    local _, gets = counted(function() frames(LOOK * 2) end)
    t.eq(gets, 2, "one look every two seconds")
    t.eq(handle.stats().confirmed, false, "it still exists")
    t.eq(sched.Frame.count, listening, "it is a timer: nothing was added to what runs every frame")
    fake.collect(true)
    _, gets = counted(function() frames(LOOK) end)
    t.eq(gets, 1)
    t.eq(handle.stats().confirmed, true)
    t.eq(handle.on(), true)
    _, gets = counted(function() frames(LOOK * 3) end)
    t.eq(gets, 0, "nothing is asked once the proof is whole")
    t.eq(sched.stats.live_timers, 0)
end)

t.test("a throwaway that still answers after ten minutes of play switches handles off, with one log line", function()
    restart()
    local newest = log.newest_id()
    -- this engine never lets go of anything
    for _, slot in pairs(slots) do
        if slot.object then slot.object.rooted = true end
    end
    local wrapper = fake.new()
    local held = handle.hold(wrapper)
    frames(360, 1)
    t.eq(handle.on(), true, "six minutes are not enough")
    frames(360, 1)
    t.eq(handle.on(), false)
    local lines = warnings(newest)
    t.eq(#lines, 1)
    t.eq(lines[1].count, 1)
    t.ok(lines[1].message:find("handles are off, so Wax goes by its older checks", 1, true), lines[1].message)
    t.ok(lines[1].message:find("still answered after", 1, true), lines[1].message)
    t.ok(handle.stats().why:find("still answered after", 1, true))
    -- what was made while it was on goes on unchecked
    local _, gets = counted(function()
        frames(2)
        t.ok(rawequal(held:get(), wrapper))
        t.eq(held:checked(), false)
    end)
    t.eq(gets, 0)
    t.eq(handle.take(fake.new()), nil)
end)

t.test("a long pause counts as two looks, so a game that stood still is not blamed", function()
    restart()
    for _, slot in pairs(slots) do
        if slot.object then slot.object.rooted = true end
    end
    frames(10)
    for _ = 1, 3 do frames(1, 7200) end
    t.eq(handle.on(), true)
    t.eq(handle.stats().confirmed, false)
end)

t.test("a throwaway that cannot be asked from a task ends the watch after five tries and leaves handles on", function()
    restart()
    local newest = log.newest_id()
    fake.broken = "get raises"
    local _, gets = counted(function() frames(LOOK * 8) end)
    fake.broken = nil
    t.eq(gets, 5)
    t.eq(handle.on(), true)
    t.eq(handle.stats().confirmed, false)
    t.eq(#warnings(newest), 0)
    t.eq(sched.stats.live_timers, 0)
end)

t.test("starting again takes the watcher of the start before away", function()
    restart()
    restart()
    restart()
    frames(LOOK)
    local _, gets = counted(function() frames(LOOK) end)
    t.eq(gets, 1, "one watcher looks, not three")
    t.eq(sched.stats.live_timers, 1)
end)

for _, case in ipairs({
    { "convert raises", "the game said no" },
    { "no soft reference", "the game gave no soft reference" },
    { "get raises", "the weak pointer said no" },
    { "another object", "a handle did not give its own object back" },
    { "nothing answers", "a handle of nothing answered with an object" },
}) do
    t.test("a game in which " .. case[1] .. " leaves handles off, with one log line saying why", function()
        fake.broken = case[1]
        local newest = log.newest_id()
        t.eq(handle.start(), false)
        fake.broken = nil
        t.eq(handle.on(), false)
        local lines = warnings(newest)
        t.eq(#lines, 1)
        t.ok(lines[1].message:find(case[2], 1, true), lines[1].message)
        t.ok(not lines[1].message:find(".lua:", 1, true), "no file and line in what a player reads: " .. lines[1].message)
        t.eq(handle.stats().why ~= nil, true)
        local _, gets = counted(function() frames(LOOK * 2) end)
        t.eq(gets, 0, "nothing is watched while it is off")
        t.eq(handle.take(fake.new()), nil)
        t.eq(handle.alive({}), true)
    end)
end

t.test("a game without KismetSystemLibrary, or with nothing to make a throwaway from, leaves handles off", function()
    local made = fake.made
    for path, why in pairs({
        ["/Script/Engine.Default__KismetSystemLibrary"] = "the game has no KismetSystemLibrary",
        ["/Script/Engine.ObjectLibrary"] = "the game has nothing to make a throwaway object from",
        ["/Engine/Transient"] = "the game has nothing to make a throwaway object from",
    }) do
        local kept = static[path]
        static[path] = nil
        t.eq(handle.start(), false, path)
        static[path] = kept
        t.eq(handle.stats().why, why, path)
    end
    t.eq(fake.made, made, "and nothing was made")
    restart()
end)

-- ------------------------------------------------------------------------------------------- take, alive and get

t.test("a handle gives its object back while it lives, for each kind of wrapper the engine hands over", function()
    restart()
    for _, kind in ipairs({ "UObject", "AActor", "UClass", "UWorld", "UDataTable" }) do
        local wrapper = fake.new(kind, true)
        local taken, why = handle.take(wrapper)
        t.ok(taken ~= nil, kind .. ": " .. tostring(why))
        t.eq(handle.alive(taken), true, kind)
        local back = handle.get(taken)
        t.ok(back ~= nil and not rawequal(back, wrapper), kind .. ": a wrapper of its own")
        t.eq(back:GetAddress(), wrapper:GetAddress(), kind)
        t.eq(back:type(), kind)
    end
    t.eq(fake.faults, 0)
end)

t.test("take refuses whatever is not an object wrapper, and the engine is never handed it", function()
    restart()
    local struct = pointer("UScriptStruct", { ptr = 0x5550000 }, { GetAddress = function() return 0x5550000 end })
    local name = pointer("FName", {}, {})
    local weak = soft_methods.GetWeakPtr(pointer("TSoftObjectPtrUserdata", { index = 1, serial = 1 }, soft_methods))
    local refused = handle.stats().refused
    local conversions = counted(function()
        for label, value in pairs({
            ["a struct"] = struct, ["a name"] = name, ["a weak pointer"] = weak, ["a function"] = wrap(nil, "UFunction", 0x77000),
            ["an enum"] = fake.new("UEnum", true), ["a Lua table"] = {}, ["a number"] = 5, ["a text"] = "Actor",
            ["a file"] = io.stdout, ["a member that does not exist"] = wrap(static["/Engine/Transient"]).NoSuchMember,
        }) do
            local taken, why = handle.take(value)
            t.eq(taken, nil, label)
            t.eq(why, "not an object", label)
        end
        local taken, why = handle.take(nil)
        t.eq(taken, nil)
        t.eq(why, "not an object")
        for label, value in pairs({ ["a wrapper of nothing"] = wrap(nil),
            ["an object wrapper UE4SS marked as no object"] = wrap(nil, "UObject", MARKER) }) do
            taken, why = handle.take(value)
            t.eq(taken, nil, label)
            t.eq(why, "nothing", label)
        end
    end)
    t.eq(conversions, 0, "nothing reached the game's function")
    t.eq(handle.stats().refused - refused, 13)
    t.eq(fake.wild, 0)
    t.eq(fake.faults, 0)
end)

t.test("after a collection the handle says gone, and the wrapper of nothing it gets is never handed out", function()
    restart()
    local wrapper = fake.new()
    local taken = handle.take(wrapper)
    t.eq(handle.alive(taken), true)
    fake.collect(true)
    t.eq(handle.alive(taken), false)
    t.eq(handle.get(taken), nil)
    t.eq(taken:Get() ~= nil, true, "the engine's own answer is a wrapper, not nil")
    t.eq(taken:Get():GetAddress(), 0)
    t.eq(fake.faults, 0)
end)

t.test("a new object at the old address: IsValid() says true on the old wrapper, the handle says gone", function()
    restart()
    local old, old_object = fake.new()
    local old_name, address = old_object.name, old:GetAddress()
    local old_handle = handle.take(old)
    fake.collect(true)
    t.eq(old:IsValid(), false, "nothing new there yet: UE4SS took the address out of its set")
    local fresh, fresh_object = fake.reuse(address)
    t.eq(fresh:GetAddress(), address)
    -- the mistake behind the crashes: the old wrapper answers for the new object
    t.eq(old:IsValid(), true)
    t.eq(old:GetFName():ToString(), fresh_object.name)
    t.ok(old_name ~= fresh_object.name)
    -- the handle is right both ways
    t.eq(handle.alive(old_handle), false)
    t.eq(handle.get(old_handle), nil)
    local fresh_handle = handle.take(fresh)
    t.eq(handle.alive(fresh_handle), true)
    t.eq(handle.get(fresh_handle):GetFName():ToString(), fresh_object.name)
    t.eq(handle.alive(old_handle), false, "and stays gone")
    t.eq(fake.faults, 0)
end)

t.test("marked by a collection and not freed yet, an object is gone already", function()
    restart()
    local wrapper = fake.new()
    local taken = handle.take(wrapper)
    fake.collect(false)
    t.eq(memory[wrapper:GetAddress()] ~= nil, true, "its memory is still there")
    t.eq(handle.alive(taken), false)
    fake.purge()
    t.eq(handle.alive(taken), false)
    t.eq(fake.faults, 0)
end)

t.test("a destroyed actor is gone at once, while IsValid() still says true", function()
    restart()
    local actor, object = fake.new("AActor", true)
    local taken = handle.take(actor)
    fake.destroy(object)
    t.eq(actor:IsValid(), true)
    t.eq(handle.alive(taken), false)
    t.eq(handle.get(taken), nil)
    fake.collect(true)
    t.eq(handle.alive(taken), false)
    t.eq(fake.faults, 0)
end)

t.test("keeping a handle does not keep its object, and a handle of something that lives goes on answering", function()
    restart()
    local kept = fake.new("UObject", true)
    local loose = fake.new()
    local kept_handle, loose_handle = handle.take(kept), handle.take(loose)
    for _ = 1, 3 do
        fake.collect(true)
        fake.new()
    end
    t.eq(handle.alive(loose_handle), false)
    t.eq(handle.alive(kept_handle), true)
    t.eq(handle.get(kept_handle):GetAddress(), kept:GetAddress())
end)

t.test("a handle taken from a kept wrapper stands for whatever is at its address now, so it is taken at hand-over", function()
    restart()
    local old = fake.new()
    local address = old:GetAddress()
    fake.collect(true)
    local _, fresh_object = fake.reuse(address)
    local late = handle.take(old)
    t.eq(handle.get(late):GetFName():ToString(), fresh_object.name, "it is the new object's handle")
end)

t.test("a handle taken from a wrapper whose memory was freed is what the game dies of", function()
    restart()
    local old = fake.new()
    fake.collect(true)
    local faults = fake.faults
    handle.take(old)
    t.eq(fake.faults - faults, 1, "taking read the freed memory: in the game that is no Lua error to catch")
    fake.faults, fake.fault_at = faults, nil
end)

t.test("what is asked and what was gone is counted", function()
    restart()
    local before = handle.stats()
    local taken = handle.take(fake.new())
    handle.alive(taken)
    fake.collect(true)
    handle.alive(taken)
    handle.get(taken)
    local after = handle.stats()
    t.eq(after.taken - before.taken, 1)
    t.eq(after.asked - before.asked, 3)
    t.eq(after.gone - before.gone, 2)
end)

-- ---------------------------------------------------------------------------------------------------------- hold

t.test("hold gives the object back only while the engine says it exists", function()
    restart()
    local wrapper = fake.new()
    local held = handle.hold(wrapper)
    t.ok(rawequal(held:get(), wrapper))
    t.eq(held:alive(), true)
    t.eq(held:checked(), true)
    local ok, address, extra = held:use(function(object, more) return object:GetAddress(), more end, "more")
    t.eq(ok, true)
    t.eq(address, wrapper:GetAddress())
    t.eq(extra, "more")
    frames(1)
    t.ok(rawequal(held:get(), wrapper))
    fake.collect(true)
    frames(1)
    t.eq(held:get(), nil)
    t.eq(held:alive(), false)
    t.eq(held:checked(), false)
    local ran = false
    t.eq(held:use(function() ran = true end), false)
    t.eq(ran, false)
    t.eq(fake.faults, 0)
end)

t.test("inside the frame loop a held object is asked about once a frame, however often it is used", function()
    restart()
    local wrapper = fake.new("UObject", true)
    local held
    local conversions, gets = counted(function()
        in_frame(function()
            held = handle.hold(wrapper)
            for _ = 1, 20 do held:get() end
        end)
    end)
    t.eq(conversions, 1)
    t.eq(gets, 0, "it was handed over in this frame")
    for _ = 1, 3 do
        _, gets = counted(function()
            in_frame(function()
                for _ = 1, 20 do
                    held:get()
                    held:alive()
                    held:use(function() end)
                end
            end)
        end)
        t.eq(gets, 1)
    end
end)

t.test("outside the frame loop (a widget's event, a hook) nothing is kept: every use asks", function()
    restart()
    local wrapper = fake.new()
    local held = handle.hold(wrapper)
    local _, gets = counted(function()
        for _ = 1, 5 do held:get() end
    end)
    t.eq(gets, 5)
    in_frame(function() t.ok(rawequal(held:get(), wrapper)) end)
    -- the engine collects after the frame and then calls a handler, before the next frame begins
    fake.collect(true)
    t.eq(held:get(), nil)
    t.eq(fake.faults, 0)
end)

t.test("an answer from the end of one frame is not used at the start of the next, which the scheduler counts as the same frame", function()
    restart()
    local wrapper = fake.new()
    local held = handle.hold(wrapper)
    in_frame(function()
        frames(1)       -- the scheduler's step comes in the middle of a frame, and the interface after it
        t.ok(rawequal(held:get(), wrapper))
    end)
    local counted_frame = sched.stats.frame
    fake.collect(true)
    in_frame(function()
        t.eq(sched.stats.frame, counted_frame, "mods run before the scheduler counts on")
        t.eq(held:get(), nil)
    end)
    t.eq(fake.faults, 0)
end)

t.test("a frame that raises still ends, and what it returns or raises is passed on", function()
    restart()
    local wrapper = fake.new()
    local held = handle.hold(wrapper)
    t.raises(function()
        in_frame(function()
            held:get()
            error("the frame broke", 0)
        end)
    end, "the frame broke")
    t.eq(handle.stamp(), nil)
    fake.collect(true)
    t.eq(held:get(), nil)
    local a, b, c = handle.framed(function(x, y) return x, y, x + y end)(1, 2)
    t.eq(a, 1)
    t.eq(b, 2)
    t.eq(c, 3)
    t.eq(fake.faults, 0)
end)

t.test("stamp marks an answer a caller keeps: one number through a frame, another in the next, none outside", function()
    t.eq(handle.stamp(), nil)
    local first, again, expired, second
    in_frame(function()
        first, again = handle.stamp(), handle.stamp()
        handle.expire()
        expired = handle.stamp()
    end)
    in_frame(function() second = handle.stamp() end)
    t.ok(first ~= nil and first == again)
    t.ok(expired ~= nil and expired ~= first)
    t.ok(second ~= nil and second ~= first and second ~= expired)
    t.eq(handle.stamp(), nil)
end)

t.test("a handle the game refuses to give leaves that object without one, with one log line however often", function()
    restart()
    local newest, before = log.newest_id(), handle.stats()
    local wrapper = fake.new()
    fake.broken = "convert raises"
    local taken, why = handle.take(wrapper)
    local held = handle.hold(wrapper)
    handle.take(wrapper)
    fake.broken = nil
    t.eq(taken, nil)
    t.eq(why, "failed")
    t.eq(held:checked(), false)
    t.ok(rawequal(held:get(), wrapper), "it is kept as it is, as when handles are off")
    t.eq(handle.on(), true, "one refusal does not switch handles off")
    local after = handle.stats()
    t.eq(after.failed - before.failed, 3)
    t.eq(after.taken, before.taken)
    local lines = warnings(newest)
    t.eq(#lines, before.failed == 0 and 1 or 0)
    if lines[1] then
        t.ok(lines[1].message:find("the game gave no handle for an object", 1, true), lines[1].message)
        t.ok(not lines[1].message:find(".lua:", 1, true), lines[1].message)
    end
    t.ok(handle.take(fake.new()) ~= nil, "the next object gets one")
end)

t.test("once gone a held object never comes back, also when a new object takes its address", function()
    restart()
    local wrapper = fake.new()
    local address = wrapper:GetAddress()
    local held = handle.hold(wrapper)
    fake.collect(true)
    frames(1)
    t.eq(held:get(), nil)
    fake.reuse(address)
    t.eq(wrapper:IsValid(), true, "the old wrapper would have passed")
    frames(1)
    local _, gets = counted(function() t.eq(held:get(), nil) end)
    t.eq(gets, 0, "and nothing is asked about it any more")
end)

t.test("an answer is kept for the frame: after something is destroyed in it expire() makes everything be asked again", function()
    restart()
    local actor, object = fake.new("AActor", true)
    local held = handle.hold(actor)
    in_frame(function()
        t.ok(held:get())
        fake.destroy(object)
        t.ok(rawequal(held:get(), actor), "the answer of this frame, from before the destroy")
        handle.expire()
        t.eq(held:get(), nil)
    end)
    t.eq(fake.faults, 0)
end)

t.test("drop lets the object go for good", function()
    restart()
    local held = handle.hold(fake.new("UObject", true))
    held:drop()
    t.eq(held:get(), nil)
    t.eq(held:alive(), false)
    frames(1)
    local _, gets = counted(function() t.eq(held:get(), nil) end)
    t.eq(gets, 0)
end)

t.test("hold refuses what is not an object, in words that say what to pass", function()
    restart()
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        handle.hold({})
    end, "expects an engine object as the engine has just handed it over, got a table (for an Instance, hold its Raw)")
    t.ok(err:find("handle_test.lua:" .. line .. ":", 1, true), "the caller's line: " .. err)
    t.raises(function() handle.hold(nil) end, "got nil")
    t.raises(function() handle.hold("Actor") end, "got string")
    t.raises(function() handle.hold(pointer("UScriptStruct", {}, {})) end, "got a UScriptStruct")
    t.raises(function() handle.hold(wrap(nil, "UFunction", 0x77000)) end, "got a UFunction")
    t.raises(function() handle.hold(wrap(nil)) end, "a wrapper with no object behind it")
    t.raises(function() handle.hold(wrap(nil, "UObject", MARKER)) end, "a wrapper with no object behind it")
    t.raises(function() handle.hold(wrap(static["/Engine/Transient"]).NoSuchMember) end,
        "got a value that is no object (a member the object does not have reads as one)")
    t.eq(fake.wild, 0)
    t.eq(fake.faults, 0)
end)

t.test("with handles off a held object is only kept: it is given as it is until it is dropped", function()
    fake.broken = "convert raises"
    t.eq(handle.start(), false)
    fake.broken = nil
    local wrapper = fake.new()
    local held
    local conversions, gets = counted(function()
        held = handle.hold(wrapper)
        frames(2)
        t.ok(rawequal(held:get(), wrapper))
        t.eq(held:alive(), true)
        t.eq(held:checked(), false)
    end)
    t.eq(conversions, 0)
    t.eq(gets, 0)
    t.raises(function() handle.hold({}) end, "expects an engine object")
    held:drop()
    t.eq(held:get(), nil)
    restart()
end)

t.test("nothing in all of this read freed memory or handed the engine a wild pointer", function()
    t.eq(fake.faults, 0, tostring(fake.fault_at))
    t.eq(fake.wild, 0)
end)

-- ------------------------------------------------------------------------------ plugged into engine.instance

local world = dofile("wax/tests/offline/fake_world.lua")
world.install()
world.as_userdata()

local PENDING = 0x20000000
local NOTHING = world.object("None", {})
rawset(NOTHING, "__address", 0)
local asked = 0

local function stand_in(fields)
    fields.__wrapper = true
    return fields
end

-- The game's function on the stand-in world: a weak pointer is the object itself, and answers while it is not freed or destroyed.
local function soft_reference(_, object)
    local weak = stand_in({ type = function() return "FWeakObjectPtr" end })
    function weak.Get()
        asked = asked + 1
        if object == nil or rawget(object, "__freed") or rawget(object, "__flags") & PENDING ~= 0 then return NOTHING end
        return object
    end
    return stand_in({ type = function() return "TSoftObjectPtrUserdata" end, GetWeakPtr = function() return weak end })
end

local object_class = world.class("/Script/CoreUObject.Object")
local actor_class = world.class("/Script/Engine.Actor", object_class)
world.class("/Script/Engine.World", object_class)
local component_class = world.class("/Script/Engine.ActorComponent", object_class)
world.class("/Script/Engine.SceneComponent", component_class)
local library_class = world.class("/Script/Engine.ObjectLibrary", object_class)
world.static["/Engine/Transient"] = world.object("Transient", {})
world.static["/Script/Engine.Default__KismetSystemLibrary"] =
    world.object("Default__KismetSystemLibrary", { Conv_ObjectToSoftObjectReference = soft_reference })
local throwaways = 0
rawset(_G, "StaticConstructObject", function(class)
    throwaways = throwaways + 1
    local made = world.object("ObjectLibrary_" .. throwaways, {})
    rawset(made, "__class", class)
    return made
end)

local instance = Wax.import("engine.instance")
instance.start()

local function plug()
    t.eq(handle.start(), true, "handles start on the stand-in world")
    instance.use_handles(handle)
end

local lamps = 0
local function lamp(name)
    lamps = lamps + 1
    return world.place(actor_class, name or ("Lamp_" .. lamps), { Location = { 0, 0, 0 } })
end

t.test("the self-check passes on the stand-in world too, with a throwaway of the class it names", function()
    local made = throwaways
    plug()
    t.eq(throwaways - made, 1)
    t.eq(rawget(world.static["/Script/Engine.ObjectLibrary"], "__name"), rawget(library_class, "__name"))
    instance.use_handles(nil)
end)

t.test("plugged in, an Instance of an object that was freed says so and the object is never touched", function()
    plug()
    local actor = lamp()
    local held = instance.wrap(actor)
    t.ok(held.Name:find("^Lamp_"))
    frames(1)
    world.free(actor)
    t.raises(function() return held.Name end, "this Actor no longer exists")
    t.eq(held:IsValid(), false)
    t.eq(tostring(held), "Actor (destroyed)")
    t.eq(world.dead_touches, 0, tostring(world.dead_where))
    instance.use_handles(nil)
end)

t.test("plugged in, a new object at the old address under the old name gets an Instance of its own", function()
    plug()
    local first = lamp("Lamp_Same")
    local old = instance.wrap(first)
    old:SetAttribute("Lit", true)
    frames(1)
    world.free(first)
    local second = lamp("Lamp_Same")
    rawset(second, "__address", rawget(first, "__address"))
    local fresh = instance.wrap(second)
    t.ok(not rawequal(fresh, old))
    t.eq(fresh.Name, "Lamp_Same")
    t.eq(fresh:GetAttribute("Lit"), nil)
    t.eq(old:IsValid(), false)
    t.ok(rawequal(instance.wrap(second), fresh))
    t.eq(world.dead_touches, 0, tostring(world.dead_where))
    instance.use_handles(nil)
end)

t.test("plugged in, an Instance costs one question a frame inside the frame loop, and every use asks outside it", function()
    plug()
    local actor = lamp()
    local held
    local before = asked
    in_frame(function()
        held = instance.wrap(actor)
        for _ = 1, 5 do t.ok(held.Name) end
    end)
    t.eq(asked - before, 0, "it was handed over in this frame")
    in_frame(function()
        for _ = 1, 5 do
            t.ok(held.Name)
            t.ok(rawequal(instance.wrap(actor), held))
        end
    end)
    t.eq(asked - before, 1)
    before = asked
    for _ = 1, 3 do t.ok(held.Name) end
    t.eq(asked - before, 3, "between two frames nothing is kept")
    world.destroy(actor)
    t.raises(function() return held.Name end, "no longer exists")
    t.eq(world.dead_touches, 0)
    instance.use_handles(nil)
end)

t.test("plugged in, what was checked late in one frame is asked again at the start of the next", function()
    plug()
    local actor = lamp()
    local held = instance.wrap(actor)
    -- the later half of a frame: the scheduler's own counter has gone up
    in_frame(function()
        frames(1)
        t.ok(held.Name)
    end)
    world.free(actor)
    -- the earlier half of the next: the scheduler's counter has not moved, and the engine collected in between
    in_frame(function()
        t.eq(held:IsValid(), false)
        t.raises(function() return held.Name end, "no longer exists")
    end)
    t.eq(world.dead_touches, 0, tostring(world.dead_where))
    instance.use_handles(nil)
end)

t.test("a handle module without a stamp keeps answers by the scheduler's frame, as with nothing plugged in", function()
    plug()
    instance.use_handles({ take = handle.take, alive = handle.alive })
    local actor = lamp()
    local held = instance.wrap(actor)
    frames(1)
    local before = asked
    for _ = 1, 5 do t.ok(held.Name) end
    t.eq(asked - before, 1)
    instance.use_handles(nil)
end)

t.test("plugged in while handles are off, Instances go by their older checks and nothing is unplugged", function()
    local kept = world.static["/Script/Engine.Default__KismetSystemLibrary"]
    world.static["/Script/Engine.Default__KismetSystemLibrary"] = nil
    local newest = log.newest_id()
    t.eq(handle.start(), false)
    world.static["/Script/Engine.Default__KismetSystemLibrary"] = kept
    instance.use_handles(handle)
    local before = asked
    local held = instance.wrap(lamp())
    frames(1)
    t.ok(held.Name:find("^Lamp_"))
    frames(1)
    t.ok(held.Name)
    t.eq(asked - before, 0)
    t.eq(#log.since(newest, { channel = "wax.instance", level = "error" }), 0)
    instance.use_handles(nil)
end)

t.finish("handle")
