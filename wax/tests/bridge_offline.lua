-- Offline check of the bridge against a fake UE4SS: one frame loop, a request file in, a reply file out.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\bridge_offline.lua <scratch dir>
-- <scratch dir> must contain run/in and run/out.

local root = assert(arg[1], "usage: bridge_offline.lua <scratch dir>")
local run = root .. "/run"

local loops, handoffs, lookups = {}, 0, 0
function ExecuteInGameThread(fn) handoffs = handoffs + 1; fn() end
function LoopInGameThreadAfterFrames(_, fn) loops[#loops + 1] = fn end
function StaticFindObject()
    lookups = lookups + 1
    if lookups < 3 then error("engine not ready") end
    return {}
end
-- Anything that would run Lua off the game thread is a failure.
for _, name in ipairs({ "LoopAsync", "ExecuteAsync", "ExecuteWithDelay", "RegisterKeyBind" }) do
    _G[name] = function() error(name .. " must not be used by the bridge") end
end

-- The bridge locates its run folder from its own path, so present it as living next to the scratch run folder.
local real_getinfo = debug.getinfo
debug.getinfo = function() return { source = "@" .. root .. "/Scripts/main.lua" } end
dofile("wax/runtime/Scripts/main.lua")

assert(handoffs == 1, "expected exactly one hand-off to the game thread, got " .. handoffs)
assert(#loops == 1, "expected exactly one frame loop, got " .. #loops)

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

local function send(slot, text, wake)
    local request = assert(io.open(run .. "/in/" .. slot .. ".lua", "wb"))
    request:write(text)
    request:close()
    if wake then assert(io.open(run .. "/in/wake", "wb")):close() end
end

-- Idle: nothing is written to disk, however long the game runs.
local writes = 0
local real_open = io.open
io.open = function(path, mode)
    if mode and mode:find("[wa+]") then writes = writes + 1 end
    return real_open(path, mode)
end
for _ = 1, 600 do loops[1]() end
io.open = real_open
assert(writes == 0, "the idle bridge wrote to disk " .. writes .. " times")
assert(not exists(run .. "/alive.json"), "the bridge must not write a heartbeat file")

send(0, "--id:t1 thread:game\nprint('hi') return 6 * 7, { a = 1 }", true)
for _ = 1, 40 do loops[1]() end

local reply = assert(io.open(run .. "/out/t1.json", "rb"), "no reply was written")
local body = reply:read("a")
reply:close()
assert(body:find('"values":[42,{"a":1}]', 1, true), "unexpected values in reply: " .. body)
assert(body:find('"output":["hi"]', 1, true), "print output was not captured: " .. body)
assert(not exists(run .. "/in/0.lua"), "the request file was not consumed")
assert(not exists(run .. "/in/wake"), "the wake file was not consumed")

-- Two clients at once: both slots are answered from one wake.
send(1, "--id:t2\nreturn 'one'", false)
send(5, "--id:t3\nreturn WaxStage0.info().thread", true)
for _ = 1, 8 do loops[1]() end
assert(exists(run .. "/out/t2.json") and exists(run .. "/out/t3.json"), "a request in another slot was missed")

-- Running the file again in the same Lua state swaps the code in without a second loop.
local before = WaxStage0.frame
dofile("wax/runtime/Scripts/main.lua")
debug.getinfo = real_getinfo
assert(handoffs == 1 and #loops == 1, "re-running the bridge registered another loop")
loops[1]()
assert(WaxStage0.frame == before + 1, "the frame count did not carry over a re-run")

print("bridge offline test: PASS (start-up frames skipped while the engine was not ready: " .. (lookups - 1) .. ")")
