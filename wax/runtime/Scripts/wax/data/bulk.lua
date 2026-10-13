-- One change for every row of a table, spread over frames: items:SetAll("MaxStack", function(was) return was * 2 end).
local Wax = ...
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local tables = Wax.import("data.tables")
local task = sched.task

local M = {}
M.BUDGET = 0.001        -- seconds of one frame a job may use before it pauses

local lower = string.lower

local function check(field, fn, options)
    if type(field) ~= "string" or field == "" then error("SetAll takes a field name such as \"MaxStack\"", 3) end
    if fn == nil then
        error("SetAll needs the new value, or a function of the old one: SetAll(\"MaxStack\", function(was) return was * 2 end)", 3)
    end
    if options ~= nil and type(options) ~= "table" then
        error("the options are a table such as { where = function(name, row) return row.Weight > 0 end }", 3)
    end
    options = options or {}
    if options.where ~= nil and type(options.where) ~= "function" then error("where is a function of the row's name and the row", 3) end
    if options.fields ~= nil and type(options.fields) ~= "table" then error("fields is a list of field names to read as well", 3) end
    if options.rows ~= nil and type(options.rows) ~= "table" then error("rows is a list of row names", 3) end
    if options.budget ~= nil and type(options.budget) ~= "number" then error("budget is seconds of a frame, such as 0.002", 3) end
    return options
end

-- What the game had before any mod changed the field, by row name folded.
local function originals_of(self, field)
    local out = {}
    for _, change in ipairs(self:Changes()) do
        if change.Field == field and change.Was ~= nil then out[lower(change.Row)] = change.Was end
    end
    return out
end

function M.set_all(self, field, fn, options)
    options = check(field, fn, options)
    local owner = scope.current()
    if not owner or not owner.alive then
        error("a change of the game's tables belongs to a mod, which puts it back when it unloads. This code runs outside any mod", 0)
    end
    local read = { field }
    for _, extra in ipairs(options.fields or {}) do read[#read + 1] = extra end
    local names = options.rows or self:GetNames()
    local job = { Field = field, Total = #names, Count = 0, Changed = 0, Failed = 0, Running = true, Done = sched.Signal.new("Done") }
    local cancelled = false
    function job:Cancel() cancelled = true end
    local budget = options.budget or M.BUDGET
    local originals = originals_of(self, field)
    local clock = tables.clock

    local function one(name)
        local row = self:Row(name, read)
        if row == nil then return "the row could not be read" end
        if options.where and not options.where(name, row) then return nil end
        local current = row[field]
        local was = originals[lower(name)]
        if was == nil then was = current end
        local new = fn
        if type(fn) == "function" then new = fn(was, name, row) end
        if new == nil then return nil end
        job.Count = job.Count + 1
        if type(new) ~= "table" and new == current then return nil end
        self:Set(name, field, new)
        job.Changed = job.Changed + 1
        return nil
    end

    task.defer(function()
        local started = clock()
        for index = 1, #names do
            if cancelled then break end
            if index > 1 and clock() - started >= budget then
                task.wait()
                started = clock()
                if cancelled then break end
            end
            local ok, problem = pcall(one, names[index])
            if not ok or problem then
                job.Failed = job.Failed + 1
                if not job.Problem then job.Problem = ("%s: %s"):format(names[index], tostring(problem):gsub("\n.*", "")) end
            end
        end
        job.Running = false
        job.Done:Fire(job)
    end)
    return job
end

function M.start()
    local internal = tables.internal
    internal.Table.SetAll = internal.public(function(self, field, fn, options) return M.set_all(self, field, fn, options) end)
end

return M
