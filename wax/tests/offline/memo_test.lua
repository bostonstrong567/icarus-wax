-- The frame and timed memos: tools\lua\lua54\lua.exe wax\tests\offline\memo_test.lua
local t = dofile("wax/tests/offline/harness.lua")

local frame = 10
local now = 100
local Wax = { import = function(name)
    if name == "core.sched" then return { stats = { frame = frame } } end
    error("unexpected import " .. name)
end }
local sched_stats = Wax.import("core.sched").stats
Wax.import = function(name) if name == "core.sched" then return { stats = sched_stats } end error(name) end
local memo = assert(loadfile("wax/runtime/Scripts/wax/core/memo.lua"))(Wax)
local real_clock = os.clock
os.clock = function() return now end

t.test("a frame memo answers again within the frame and forgets when the frame moves on", function()
    local cache = memo.frame()
    local asked = 0
    local function cost() asked = asked + 1 return "answer" end
    t.eq(cache:take("a", cost), "answer")
    t.eq(cache:take("a", cost), "answer")
    t.eq(asked, 1, "asked once in the frame")
    t.eq(cache:get("a"), "answer")
    t.ok(cache:has("a"))
    t.eq(cache:get("b"), nil)
    cache:set("no", false)
    t.eq(cache:get("no"), false, "false is kept as a value")
    t.ok(cache:has("no"))
    t.eq(cache.hits, 3)
    sched_stats.frame = 11
    t.eq(cache:get("a"), nil, "a new frame: forgotten")
    t.eq(cache:take("a", cost), "answer")
    t.eq(asked, 2)
    t.eq(cache:take("none", function() return nil end), nil, "nil is not kept")
    t.ok(not cache:has("none"))
end)

t.test("a timed memo forgets an entry after its seconds", function()
    local cache = memo.timed(2)
    cache:set("x", 1)
    now = 101
    t.eq(cache:get("x"), 1)
    now = 102
    t.eq(cache:get("x"), nil, "two seconds on: gone")
    t.eq(cache.count, 0)
    cache:set("y", 2)
    cache:set("z", 3)
    now = 110
    cache:sweep()
    t.eq(cache.count, 0, "sweep drops every stale entry")
    t.ok(not pcall(memo.timed, 0), "seconds must be positive")
    t.ok(not pcall(memo.timed, "soon"))
end)

t.test("keys are any value, and clear empties a memo", function()
    local cache = memo.frame()
    local key = {}
    cache:set(key, "by table")
    cache:set(42, "by number")
    t.eq(cache:get(key), "by table")
    t.eq(cache:get(42), "by number")
    t.eq(cache.count, 2)
    cache:clear()
    t.eq(cache.count, 0)
    t.eq(cache:get(42), nil)
    t.eq(memo.api.frame, memo.frame)
end)

os.clock = real_clock
t.finish("memo")
