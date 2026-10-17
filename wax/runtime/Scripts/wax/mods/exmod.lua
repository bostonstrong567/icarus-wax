-- Applies an EXMOD, the community's table patch format, through game.Data, so it is undone like any other change.
local Wax = ...
local sched = Wax.import("core.sched")
local log = Wax.import("core.log").channel("wax.exmod")
local json = Wax.import("data.json")
local tables = Wax.import("data.tables")
local zip = Wax.import("mods.zip")
local task = sched.task

local M = {}
M.BUDGET = 0.002            -- seconds of one frame the apply may use before it pauses
M.MAX_FILE = 64 * 1024 * 1024
M.MAX_PROBLEMS = 3

local function read_file(path)
    local file, err = io.open(path, "rb")
    if not file then error(("cannot read %s: %s"):format(path, tostring(err)), 0) end
    local text = file:read("a")
    file:close()
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
    return text
end

-- "Traits-D_Itemable.json" names the table Itemable.
local function table_name(current_file)
    local stem = tostring(current_file):match("([^%-/\\]+)%.[Jj][Ss][Oo][Nn]$") or tostring(current_file):match("([^%-/\\]+)$") or ""
    if stem:sub(1, 2):lower() == "d_" then stem = stem:sub(3) end
    return stem
end

-- The EXMOD table of a file, .EXMOD or .EXMODZ, and notes about what the file holds besides it.
function M.load(path, pause)
    local text = read_file(path)
    local notes = {}
    if path:lower():match("%.exmodz$") then
        local entries = zip.entries(text)
        local found, extra = nil, 0
        for _, entry in ipairs(entries) do
            local name = entry.name
            if name:lower():match("%.exmod$") and not found then
                found = entry
            elseif name:sub(-1) ~= "/" and not name:lower():match("readme") and not name:lower():match("%.exmod$") then
                extra = extra + 1
            end
        end
        if not found then error("the zip holds no .EXMOD file", 0) end
        text = zip.read(text, found, M.MAX_FILE, pause)
        if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
        if extra > 0 then notes[#notes + 1] = ("%d game files in the zip need a pak and are not loaded"):format(extra) end
    end
    local ok, decoded = pcall(json.decode, text)
    if not ok then error("not an EXMOD: " .. tostring(decoded), 0) end
    if type(decoded) ~= "table" or type(decoded.Rows) ~= "table" then error("not an EXMOD: it has no Rows list", 0) end
    return decoded, notes
end

local function plural(n, word) return ("%d %s%s"):format(n, word, n == 1 and "" or "s") end

-- Writes every field of every row, pausing on the budget. Returns the counts and the first problems.
function M.apply(loaded, pause)
    local data = tables.api
    local counts = { done = 0, failed = 0, missing = 0, nulls = 0, tables = 0 }
    local problems = {}
    local clock = tables.clock
    local started = clock()
    local function note(text)
        if #problems < M.MAX_PROBLEMS then problems[#problems + 1] = text end
    end
    local function tick()
        if pause and clock() - started >= M.BUDGET then
            pause()
            started = clock()
        end
    end
    for _, entry in ipairs(loaded.Rows) do
        local items = type(entry) == "table" and entry.File_Items or nil
        local name = type(entry) == "table" and table_name(entry.CurrentFile) or ""
        local ok, found = pcall(function() return data:Table(name) end)
        if not ok or not found then
            counts.tables = counts.tables + 1
            note(("no table named %s"):format(name ~= "" and name or tostring(entry.CurrentFile)))
        elseif type(items) == "table" then
            for _, item in ipairs(items) do
                local row = type(item) == "table" and item.Name or nil
                if type(row) ~= "string" then
                    counts.failed = counts.failed + 1
                    note(("%s: an entry has no Name"):format(name))
                elseif not found:Has(row) then
                    counts.missing = counts.missing + 1
                    note(("%s has no row %s (new rows are not supported yet)"):format(name, row))
                else
                    for field, value in pairs(item) do
                        if field ~= "Name" then
                            if value == json.null then
                                counts.nulls = counts.nulls + 1
                            else
                                local wrote, problem = pcall(found.Set, found, row, field, value)
                                if wrote then
                                    counts.done = counts.done + 1
                                else
                                    counts.failed = counts.failed + 1
                                    note(("%s.%s.%s: %s"):format(name, row, field, tostring(problem):match("^[^\r\n]*")))
                                end
                            end
                            tick()
                        end
                    end
                end
            end
        end
    end
    return counts, problems
end

-- One line for the mod's card.
function M.summary(counts, notes)
    local parts = { plural(counts.done, "value") .. " applied" }
    if counts.failed > 0 then parts[#parts + 1] = plural(counts.failed, "value") .. " refused" end
    if counts.missing > 0 then parts[#parts + 1] = plural(counts.missing, "new row") .. " skipped" end
    if counts.nulls > 0 then parts[#parts + 1] = plural(counts.nulls, "cleared field") .. " skipped" end
    if counts.tables > 0 then parts[#parts + 1] = plural(counts.tables, "unknown table") end
    local line = table.concat(parts, ", ")
    for _, extra in ipairs(notes or {}) do line = line .. ". " .. extra end
    return line
end

-- Called by the loader in the mod's scope: fills the manifest from the file and applies it in a task.
function M.start(mod)
    local path = mod.dir .. "/" .. mod.exmod
    local loaded, notes = M.load(path)
    local manifest = mod.manifest
    for _, key in ipairs({ "name", "version", "author", "description" }) do
        if type(loaded[key]) == "string" and loaded[key] ~= "" then manifest[key] = loaded[key] end
    end
    mod.note = "Applying the table changes..."
    task.defer(function()
        local counts, problems = M.apply(loaded, task.wait)
        mod.note = M.summary(counts, notes)
        log:info("%s: %s", mod.id, mod.note)
        if counts.failed > 0 or counts.missing > 0 or counts.tables > 0 then
            log:warn("%s: %s", mod.id, table.concat(problems, "; "))
        end
    end)
    return true
end

return M
