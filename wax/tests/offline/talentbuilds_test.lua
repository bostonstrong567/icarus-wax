-- Offline tests for Talent Builds: the plan, and the run over a pretend talent screen that keeps the game's rules.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\talentbuilds_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local DIR = "luamods/TalentBuilds/"

local loaded = {}
local env = setmetatable({}, { __index = _G })
env.require = function(name)
    if not loaded[name] then loaded[name] = assert(loadfile(DIR .. name .. ".lua", "t", env))() end
    return loaded[name]
end
local plan, run = env.require("plan"), env.require("run")

-- a: root, b and c need a, d needs b. Every talent has three ranks.
local function catalogue()
    return {
        a = { name = "a", shown = "A", max = 3, requires = {} },
        b = { name = "b", shown = "B", max = 3, requires = { "a" } },
        c = { name = "c", shown = "C", max = 3, requires = { "a" } },
        d = { name = "d", shown = "D", max = 3, requires = { "b" } },
        r = { name = "r", shown = "R", max = 1, requires = {}, given = true },
    }
end

-- A talent screen with the game's rules: a refund only when nothing researched needs the talent, a rank only with a
-- free point and its parent researched. Each answer shows a frame later.
local function screen(ranks, total, options)
    options = options or {}
    local cat = catalogue()
    local w = { step = 0.1, inbox = {}, held = ranks, total = total, calls = 0, respec = options.respec or 10 }
    local queued = nil
    local function spent() local n = 0 for _, r in pairs(w.held) do n = n + r end return n end
    function w.catalogue() return cat end
    function w.points()
        return { level = 50, total = w.total, spent = spent(), free = w.total - spent(), respec = w.respec,
            prospect = options.prospect }
    end
    function w.ranks() local copy = {} for k, v in pairs(w.held) do if v > 0 then copy[k] = v end end return copy end
    function w.rank(name) return w.held[name] or 0 end
    function w.syncing() return false end
    function w.sync()
        w.syncs = (w.syncs or 0) + 1
        if options.sync_applies then
            for _, apply in ipairs(w.waiting or {}) do apply() end
            w.waiting = {}
        end
        return true
    end
    function w.can_refund(name)
        if (w.held[name] or 0) < 1 then return false, "it is not researched" end
        for other, talent in pairs(cat) do
            for _, need in ipairs(talent.requires) do
                if need == name and (w.held[other] or 0) > 0 then return false, "a talent after it needs it" end
            end
        end
        return true
    end
    function w.can_unlock(name)
        local talent = cat[name]
        if (w.held[name] or 0) >= talent.max then return false end
        for _, need in ipairs(talent.requires) do if (w.held[need] or 0) < 1 then return false end end
        return true
    end
    function w.refund(name)
        w.calls = w.calls + 1
        w.respec = w.respec - 1
        queued = function() w.held[name] = (w.held[name] or 0) - (options.whole and w.held[name] or 1) end
        if options.lose_point then queued = function() w.held[name] = w.held[name] - 1; w.total = w.total - 1 end end
        if options.late then
            queued = function()
                w.held[name] = w.held[name] - 1
                w.total, w.late, w.owed = w.total - 1, options.late, (w.owed or 0) + 1
            end
        end
        if options.ignore then queued = nil end
        if options.stale then
            local apply = queued
            queued = nil
            w.waiting = w.waiting or {}
            w.waiting[#w.waiting + 1] = apply
        end
        if queued then w.inbox[#w.inbox + 1] = queued; queued = nil end
        return true
    end
    function w.unlock(name)
        if w.total - spent() < 1 then return false end
        queued = function() w.held[name] = (w.held[name] or 0) + 1 end
        return true
    end
    function w.wait()
        if #w.inbox > 0 then
            for _, apply in ipairs(w.inbox) do apply() end
            w.inbox = {}
            return
        end
        if queued then queued(); queued = nil return end
        if w.late then
            w.late = w.late - 1
            if w.late <= 0 then w.late, w.total, w.owed = nil, w.total + w.owed, 0 end
        end
    end
    return w
end

local quiet = function() end
run.WAIT, run.SETTLE = 0.3, 2

t.test("depths follow the shallowest parent", function()
    local d = plan.depths(catalogue())
    t.eq(d.a, 0); t.eq(d.b, 1); t.eq(d.c, 1); t.eq(d.d, 2)
end)

t.test("refunds go deepest first and research shallowest first", function()
    local todo = plan.diff(catalogue(), { a = 3, b = 2, d = 1 }, { a = 1, c = 2 })
    t.eq(todo.refund[1].name, "d"); t.eq(todo.refund[#todo.refund].name, "a")
    t.eq(todo.refunds, 1 + 2 + 2); t.eq(todo.unlocks, 2)
end)

t.test("a build keeps known talents, caps ranks and names the missing", function()
    local target, missing = plan.target(catalogue(), { a = 9, gone = 2, b = 0 })
    t.eq(target.a, 3); t.eq(target.b, nil); t.eq(missing[1], "gone")
end)

t.test("talents the game gives are not part of a build", function()
    local ranks, count, total = plan.chosen(catalogue(), { a = 2, r = 1 })
    t.eq(ranks.r, nil); t.eq(count, 1); t.eq(total, 2)
end)

t.test("refund all leaves every point free and the total as it was", function()
    local w = screen({ a = 3, b = 2, c = 1, d = 1 }, 10)
    local result = run.run(w, {}, quiet)
    t.ok(result.ok, result.why)
    t.eq(result.refunded, 7)
    t.eq(w.points().total, 10); t.eq(w.points().free, 10)
end)

t.test("loading a build swaps talents and keeps leftover points free", function()
    local w = screen({ a = 1, b = 3, d = 2 }, 10)
    local result = run.run(w, { a = 2, c = 3 }, quiet)
    t.ok(result.ok, result.why)
    t.eq(w.rank("b"), 0); t.eq(w.rank("d"), 0); t.eq(w.rank("a"), 2); t.eq(w.rank("c"), 3)
    t.eq(w.points().free, 5); t.eq(w.points().total, 10)
end)

t.test("a build bigger than the points researches what fits and says what is left", function()
    local w = screen({}, 4)
    local result = run.run(w, { a = 3, b = 3 }, quiet)
    t.ok(result.ok)
    t.eq(result.researched, 4); t.eq(result.left_unlocks, 2); t.eq(w.points().total, 4)
end)

t.test("a refund that takes the whole talent at once is counted right", function()
    local w = screen({ a = 3 }, 5, { whole = true })
    local result = run.run(w, {}, quiet)
    t.eq(result.refunded, 3); t.eq(w.rank("a"), 0)
end)

t.test("a game that counts the points late still refunds everything", function()
    local w = screen({ a = 3, b = 2, c = 1, d = 1 }, 10, { late = 15 })
    local result = run.run(w, {}, quiet)
    t.ok(result.ok, result.why)
    t.eq(result.refunded, 7); t.eq(w.calls, 7)
    t.eq(w.points().total, 10); t.eq(w.points().free, 10)
end)

t.test("a refund is never sent twice for the same rank", function()
    local w = screen({ a = 1 }, 5, { ignore = true })
    run.run(w, {}, quiet)
    t.eq(w.calls, 1)
end)

t.test("it stops when the points are never counted back", function()
    local w = screen({ a = 3, b = 1 }, 10, { lose_point = true })
    local result = run.run(w, {}, quiet)
    t.eq(result.ok, false)
    t.ok(result.why:find("Nothing more was sent"), result.why)
    t.eq(w.calls, 1)
end)

t.test("a refund the game never takes is reported, not retried for ever", function()
    local w = screen({ a = 1 }, 5, { ignore = true })
    local result = run.run(w, {}, quiet)
    t.ok(result.ok)
    t.eq(result.left_refunds, 1); t.eq(result.refused.a, "the game did not take the refund")
    t.ok(w.calls <= run.MAX_ROUNDS)
end)

t.test("no Respec Points means no refund at all", function()
    local w = screen({ a = 1 }, 5, { respec = 0 })
    local result = run.run(w, {}, quiet)
    t.eq(result.ok, false); t.eq(w.calls, 0); t.eq(w.rank("a"), 1)
end)

t.test("on a prospect a reload of the talents makes each refund show, and it goes on", function()
    local w = screen({ a = 2, b = 1 }, 6, { stale = true, sync_applies = true, prospect = true })
    local result = run.run(w, {}, quiet)
    t.ok(result.ok, result.why)
    t.eq(result.refunded, 3); t.eq(w.calls, 3); t.eq(w.points().free, 6)
end)

t.test("on a prospect that never shows a refund it stops after one", function()
    local w = screen({ a = 2, b = 1 }, 6, { stale = true, prospect = true })
    local result = run.run(w, {}, quiet)
    t.eq(result.ok, false); t.eq(w.calls, 1); t.eq(w.syncs, 1)
    t.ok(result.why:find("leave and join again"), result.why)
end)

t.test("a tree the screen calls locked by its points is refunded from the bottom up", function()
    local w = screen({ a = 1, b = 2, d = 1 }, 8)
    local order = {}
    local refund = w.refund
    w.refund = function(name) order[#order + 1] = name return refund(name) end
    w.can_refund = function(name)
        for other, talent in pairs(w.catalogue()) do
            for _, need in ipairs(talent.requires) do
                if need == name and w.rank(other) > 0 then return false, "a talent after it needs it" end
            end
        end
        return false, "a talent further up the tree needs the points in this tree"
    end
    local result = run.run(w, {}, quiet)
    t.eq(order[1], "d"); t.eq(order[#order], "a")
    t.ok(result.ok, result.why)
    t.eq(result.refunded, 4); t.eq(w.points().free, 8); t.eq(w.points().total, 8)
end)

t.test("every file of the mod compiles", function()
    for _, name in ipairs({ "mod", "init", "plan", "live", "run" }) do
        local chunk, problem = loadfile(DIR .. name .. ".lua", "t", {})
        t.ok(chunk, tostring(problem))
    end
end)

t.finish("talentbuilds")
