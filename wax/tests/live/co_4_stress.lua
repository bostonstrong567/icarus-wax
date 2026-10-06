-- Step 4: creation cost, memory behaviour over many create/finish cycles, and resuming on a later frame.
-- Called repeatedly by the driver; each call does one batch and returns counters.
local dll = "C:/Program Files (x86)/Steam/steamapps/common/Icarus/Icarus/Binaries/Win64/ue4ss/Mods/Wax/bin/waxco.dll"
local newthread = assert(package.loadlib(dll, "wax_newthread"))
local registry = debug.getregistry()
local KEY = -22433
local function cocreate(fn)
    registry[KEY] = fn
    local co = newthread()
    registry[KEY] = nil
    return co
end

local BATCH = 5000
local state = rawget(_G, "WaxCoStress")
if not state then
    state = { batches = 0, parked = {}, crossFrameOk = 0, crossFrameBad = 0 }
    _G.WaxCoStress = state
end

-- Resume the coroutines parked by the previous batch: this runs on a later frame than their creation.
for i = 1, #state.parked do
    local co = state.parked[i]
    local ok, valid = coroutine.resume(co)
    if ok and valid == true then state.crossFrameOk = state.crossFrameOk + 1 else state.crossFrameBad = state.crossFrameBad + 1 end
end
state.parked = {}

local world = FindFirstOf("World")
local sum = 0
local t0 = os.clock()
for i = 1, BATCH do
    local co = cocreate(function(a)
        local b = coroutine.yield(world:IsValid() and a or -1)
        return a + b
    end)
    local _, first = coroutine.resume(co, i)
    local _, second = coroutine.resume(co, 1)
    sum = sum + first + second
end
local elapsed = os.clock() - t0

-- Park a few across the frame boundary; each makes an engine call when resumed next time.
for i = 1, 20 do
    local co = cocreate(function()
        coroutine.yield()
        return FindFirstOf("World"):IsValid()
    end)
    coroutine.resume(co)
    state.parked[i] = co
end

collectgarbage("collect")
state.batches = state.batches + 1
return {
    batch = state.batches,
    created = state.batches * (BATCH + 20),
    sumOk = sum == BATCH * (BATCH + 1) + BATCH,     -- sum of (i + (i + 1)) for i = 1..BATCH
    microsPerCycle = elapsed / BATCH * 1e6,
    luaKB = collectgarbage("count"),
    crossFrameOk = state.crossFrameOk,
    crossFrameBad = state.crossFrameBad,
}
