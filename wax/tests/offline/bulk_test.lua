-- Offline tests for data.bulk: SetAll over every row of a table, spread over frames, on the stand-in tables.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\bulk_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_tables.lua")
fake.sample()
local S, U = "/Script/Icarus.", "/Script/IcarusUtilities."

fake.struct(S .. "StackRow", U .. "IcarusTableRowBase", {
    { "MaxStack", "IntProperty" }, { "Weight", "FloatProperty" }, { "Kind", "StrProperty" },
})
fake.table("Stacks", S .. "StackRow", {
    Wood = { MaxStack = 100, Weight = 5, Kind = "resource" },
    Stone = { MaxStack = 50, Weight = 10, Kind = "resource" },
    Arrow = { MaxStack = 20, Weight = 1, Kind = "ammo" },
    Fuel = { MaxStack = 10, Weight = 2, Kind = "fuel" },
}, { "Wood", "Stone", "Arrow", "Fuel" })
fake.install()
fake.allow_writes(true)

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local game = Wax.import("engine.game")
local data = Wax.import("data.tables")
local journal = Wax.import("data.journal")
journal.clear()

local now = 100
sched.clock = function() return now end
data.clock = function() return now end
data.start()
local patch = Wax.import("data.patch")
patch.clock = function() return now end
rawset(Wax, "mods", { list = function() return { { id = "ModA", name = "ModA" } } end })
patch.start()
local bulk = Wax.import("data.bulk")
bulk.start()

local Data = game.root.Data
local stacks = Data:Table("Stacks")
local A = scope.new("ModA")
local function as(fn, ...) return scope.run(A, fn, ...) end

local function frame()
    now = now + 0.016
    fake.next_frame()
    sched.step()
end

local function finish(job)
    for _ = 1, 50 do
        if not job.Running then return end
        frame()
    end
    error("the job did not finish in 50 frames")
end

local function stack(name) return fake.row("Stacks", name).MaxStack end

t.test("SetAll is a member, and outside a mod it is refused like Set", function()
    t.ok(stacks.SetAll, "SetAll exists")
    t.raises(function() stacks:SetAll("MaxStack", 1) end, "belongs to a mod")
    t.raises(function() as(function() stacks:SetAll(7, 1) end) end, "SetAll takes a field name")
    t.raises(function() as(function() stacks:SetAll("MaxStack") end) end, "SetAll needs the new value")
    t.raises(function() as(function() stacks:SetAll("MaxStack", 1, 5) end) end, "the options are a table")
    t.raises(function() as(function() stacks:SetAll("MaxStack", 1, { where = 5 }) end) end, "where is a function")
end)

t.test("a function of the old value runs over every row, in a task that pauses on its budget", function()
    local job = as(function() return stacks:SetAll("MaxStack", function(was) return was * 2 end, { budget = 0 }) end)
    t.eq(job.Total, 4)
    t.eq(job.Running, true)
    frame()
    t.ok(job.Running, "a budget of zero means one row a frame, so it is still running after one frame")
    finish(job)
    t.eq(job.Count, 4)
    t.eq(job.Changed, 4)
    t.eq(job.Failed, 0)
    t.eq(stack("Wood"), 200)
    t.eq(stack("Stone"), 100)
    t.eq(stack("Arrow"), 40)
    t.eq(stack("Fuel"), 20)
    t.eq(#stacks:Changes(), 4)
end)

t.test("run again, the function sees the game's own value, not the last result", function()
    local done
    local job = as(function() return stacks:SetAll("MaxStack", function(was) return was * 3 end) end)
    as(function() job.Done:Connect(function(finished) done = finished end) end)
    finish(job)
    frame()
    t.eq(done, job, "Done fires with the job")
    t.eq(stack("Wood"), 300)
    t.eq(stack("Arrow"), 60)
    t.eq(job.Changed, 4)
end)

t.test("a plain value and a where filter, with other fields read for it", function()
    local seen = {}
    local job = as(function()
        return stacks:SetAll("MaxStack", 999, {
            fields = { "Kind", "Weight" },
            where = function(name, row)
                seen[#seen + 1] = name .. ":" .. row.Kind .. ":" .. row.Weight
                return row.Kind == "resource"
            end,
        })
    end)
    finish(job)
    t.eq(job.Count, 2)
    t.eq(job.Changed, 2)
    t.eq(#seen, 4)
    t.eq(stack("Wood"), 999)
    t.eq(stack("Stone"), 999)
    t.eq(stack("Arrow"), 60, "a row the filter left out keeps what it had")
end)

t.test("nil from the function leaves the row alone, and the same value is not written again", function()
    local writes = fake.writes
    local job = as(function()
        return stacks:SetAll("MaxStack", function(was, name) if name == "Fuel" then return was * 2 end return nil end)
    end)
    finish(job)
    t.eq(job.Count, 1)
    t.eq(job.Changed, 1)
    t.eq(stack("Fuel"), 20)
    local again = as(function() return stacks:SetAll("MaxStack", function(was, name) if name == "Fuel" then return was * 2 end return nil end) end)
    finish(again)
    t.eq(again.Changed, 0, "already there: nothing written")
    t.ok(fake.writes > writes, "the first run wrote")
end)

t.test("a function that raises counts as a failure and the job goes on", function()
    local job = as(function()
        return stacks:SetAll("MaxStack", function(was, name)
            if name == "Stone" then error("no stone today") end
            return was
        end)
    end)
    finish(job)
    t.eq(job.Failed, 1)
    t.ok(job.Problem and job.Problem:find("Stone: ", 1, true) and job.Problem:find("no stone today", 1, true), tostring(job.Problem))
    t.eq(job.Count, 3)
end)

t.test("a named list of rows, and Cancel", function()
    local job = as(function() return stacks:SetAll("MaxStack", 5, { rows = { "Arrow", "Wood" }, budget = 0 }) end)
    t.eq(job.Total, 2)
    job:Cancel()
    finish(job)
    t.ok(job.Changed <= 1, "cancelled after at most the first row")
    local whole = as(function() return stacks:SetAll("MaxStack", 5, { rows = { "Arrow", "Wood" } }) end)
    finish(whole)
    t.eq(stack("Arrow"), 5)
    t.eq(stack("Wood"), 5)
    t.eq(stack("Stone"), 999)
end)

t.test("Reset puts the game's numbers back", function()
    as(function() stacks:Reset() end)
    frame()
    t.eq(stack("Wood"), 100)
    t.eq(stack("Arrow"), 20)
    t.eq(#stacks:Changes(), 0)
end)

t.finish()
