-- Which parts of Wax still find what they use in this version of the game

local Wax = ...
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local storage = Wax.import("core.storage")
local suggest = Wax.import("core.suggest")
local perf = Wax.import("core.perf")
local log = Wax.import("core.log").channel("wax.needs")

local M = {}

M.WAIT_SECONDS = 6          -- in a prospect, before anything is looked up
M.LOOK_FRAMES = 30          -- how often it asks whether a prospect is loaded
M.KEPT_VERSIONS = 3
M.READ_VERSION = true       -- false: an update is told by the size of the game's files alone
M.NOTIFY = true
M.clock = function() return sched.clock() end
M.now = os.time

M.TEXT = {
    title = "Wax",
    updated_fine = "ICARUS was updated. Wax checked itself and everything works.",
    updated_one = "ICARUS was updated. 1 part of Wax needs an update: %s.",
    updated_some = "ICARUS was updated. %d parts of Wax need an update: %s.",
    broken_one = "1 part of Wax does not work with this version of ICARUS and needs an update: %s.",
    broken_some = "%d parts of Wax do not work with this version of ICARUS and need an update: %s.",
    rest = " The rest works.",
    line_fine = "%s: works",
    line_broken = "%s: needs an update. %s",
    line_waiting = "%s: not checked yet. Wax checks it a few seconds after you enter a prospect.",
    line_unsure = "%s: could not be checked",
    head_done = "Checked with ICARUS %s on %s: %d of %d parts work.",
    head_waiting = "Wax checks itself a few seconds after you enter a prospect.",
    head_checking = "Wax is checking itself: %d of %d lookups done.",
}

local TABLES = "/Engine/Transient."
local VERSION_ALL = 63      -- EIcarusGameVersionFlags::All
local FILES = { "/../../../Icarus-Win64-Shipping.exe", "/../../../../../Content/Data/data.pak" }
local MEMBER = { properties = "property", functions = "function" }

-- Everything that touches the game. The tests put a made-up game here.
local engine = {}
M.engine = engine

-- One lookup by path. A miss takes the engine tens of milliseconds, so there is one of these a frame.
function engine.find(path)
    local found = StaticFindObject(path)
    if found:IsValid() then return found end
    return nil
end

function engine.members(class)
    local out = {}
    for name, member in pairs(Wax.import("engine.reflect").class_info(class).members) do out[name] = member.kind end
    return out
end

-- name -> the struct a field holds (its own, or that of its array's items), or true for any other field
function engine.fields(struct)
    local out, at, depth = {}, struct, 0
    while at and depth < 16 do
        depth = depth + 1
        -- a struct handed out by a table or a property cannot list its fields: the one found by its path can
        local path = at:GetFullName():match("^%S+%s+(.+)$")
        local found = path and StaticFindObject(path)
        if not (found and found:IsValid()) then error("the struct " .. tostring(path) .. " was not found again", 0) end
        at = found
        at:ForEachProperty(function(property)
            local name = property:GetFName():ToString()
            if out[name] ~= nil then return end
            local kind, inside = property:GetClass():GetFName():ToString(), true
            if kind == "StructProperty" then
                inside = property:GetStruct()
            elseif kind == "ArrayProperty" then
                local inner = property:GetInner()
                if inner:GetClass():GetFName():ToString() == "StructProperty" then inside = inner:GetStruct() end
            end
            out[name] = inside
        end)
        local parent = at:GetSuperStruct()
        at = parent:IsValid() and parent or nil
    end
    return out
end

function engine.values(enum)
    if enum:type() ~= "UEnum" then error("the game has something else under this enum's name", 0) end
    local out = {}
    enum:ForEachName(function(name, value)
        out[(name:ToString():gsub("^.*::", ""))] = value
    end)
    return out
end

function engine.row_struct(data)
    if data:type() ~= "UDataTable" then return nil end
    local struct = data:GetRowStruct()
    return struct:IsValid() and struct or nil
end

function engine.meta(data)
    local found = data.MetaTable
    if found:IsValid() and found:type() == "UDataTable" then return found end
    return nil
end

-- The game's own version text, such as "3.0.30.158174-SHIPPING-DANGEROUSHORIZONS". Nothing while the game has none to give.
function engine.version()
    local subsystem = FindFirstOf("VersionSubsystem")
    if not subsystem:IsValid() then return nil end
    local wrapped = Wax.import("engine.instance").wrap(subsystem)
    local text = wrapped and wrapped:Call("GetFormattedVersion", VERSION_ALL)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text ~= "" and text or nil
end

-- The sizes of the game's program and of its tables, which change with an update. Nothing when they cannot be read.
function engine.files()
    local sizes = {}
    for at, relative in ipairs(FILES) do
        local file = io.open(Wax.root .. relative, "rb")
        if not file then return nil end
        local size = file:seek("end")
        file:close()
        sizes[at] = tostring(size)
    end
    return table.concat(sizes, "-")
end

function engine.in_prospect()
    local game = Wax.game
    return game ~= nil and game.InProspect == true
end

function engine.on_map(fn)
    local previous = scope.enter(nil)
    local connection = Wax.import("engine.game").root.MapChanged:Connect(fn)
    scope.leave(previous)
    return connection
end

-- The list and a stamp of its text, so a list that changed is checked again.
function M.read_list()
    local file = io.open(Wax.root .. "/data/needs.lua", "rb")
    if not file then error("data/needs.lua is missing", 0) end
    local text = file:read("a")
    file:close()
    local chunk, problem = load(text, "=needs.lua", "t", {})
    if not chunk then error(problem, 0) end
    local hash, byte = 0, string.byte
    for at = 1, #text do hash = (hash * 31 + byte(text, at)) % 2147483647 end
    return chunk(), ("%d-%d"):format(#text, hash)
end

-- Sends the notification. Replaced in tests.
function M.notify(text, broken)
    local ui = Wax.ui
    if ui and ui.Notify then pcall(ui.Notify, text, { title = M.TEXT.title, kind = broken and "warn" or "good", seconds = 15 }) end
end

local Checked = sched.Signal.new("Needs.Checked")
M.Checked = Checked

local order, by_id, by_name = {}, {}, {}    -- part ids in the list's order, id -> part, name -> id
local jobs = {}             -- one lookup each: a class, struct, enum or table and what is wanted of it
local stamp = nil
local kept = nil            -- what storage holds: { last = id, versions = { [id] = entry } }
local current = nil         -- the entry whose answers are in use
local answers = {}          -- part id -> true or false. A part not in here is not known yet
local pending = nil         -- "confirm" (read the version again in a prospect) or "check"
local run = nil             -- the check under way
local due, frames = nil, 0
local hurry, again = false, false      -- recheck: no wait in a prospect, and nothing kept counts
local version, files = nil, nil
local live = { frame = nil, map = nil }
local started = false
local last_message, last_updated = nil, false

local function clean(problem)
    local text = tostring(problem):match("^[^\r\n]*") or ""
    return (text:gsub("^.-%.lua:%d+: ", ""))
end

local function native(path) return path:sub(1, 8) == "/Script/" end

local function build(parts)
    order, by_id, by_name, jobs = {}, {}, {}, {}
    local by_key = {}
    local function job_for(kind, path, part, late)
        local key = kind .. " " .. path
        local job = by_key[key]
        if not job then
            job = { kind = kind, path = path, parts = {}, wants = {}, by = {}, late = true }
            by_key[key] = job
            jobs[#jobs + 1] = job
        end
        job.parts[part.id] = true
        if not late then job.late = false end
        return job
    end
    local function want(job, what, name, part, number)
        local key = what .. " " .. name
        local item = job.by[key]
        if not item then
            item = { what = what, name = name, number = number, parts = {} }
            job.by[key] = item
            job.wants[#job.wants + 1] = item
        end
        item.parts[part.id] = true
    end
    for _, part in ipairs(parts) do
        if type(part.id) ~= "string" or type(part.name) ~= "string" then error("every part of data/needs.lua has an id and a name", 0) end
        if by_id[part.id] then error("data/needs.lua lists the part " .. part.id .. " twice", 0) end
        order[#order + 1] = part.id
        by_id[part.id], by_name[part.name] = part, part.id
        for _, entry in ipairs(part.classes or {}) do
            local job = job_for("class", entry.class, part, entry.late == true)
            for key, what in pairs(MEMBER) do
                for _, name in ipairs(entry[key] or {}) do want(job, what, name, part) end
            end
        end
        for _, entry in ipairs(part.structs or {}) do
            local job = job_for("struct", entry.struct, part)
            for _, name in ipairs(entry.fields or {}) do want(job, "field", name, part) end
        end
        for _, entry in ipairs(part.enums or {}) do
            local job = job_for("enum", entry.enum, part)
            for name, number in pairs(entry.values or {}) do want(job, "value", name, part, number) end
        end
        for _, entry in ipairs(part.tables or {}) do
            local job = job_for("table", entry.table, part)
            for _, path in ipairs(entry.fields or {}) do want(job, "field", path, part) end
            for _, path in ipairs(entry.meta or {}) do want(job, "meta", path, part) end
        end
    end
end

-- Follows a dotted path through structs. Returns true, or false with the closest name or the reason.
local function walk(struct, path, seen, prefix)
    local at, last = struct, nil
    for segment in path:gmatch("[^%.]+") do
        if at == true then return false, nil, last .. " has no fields" end
        local fields = seen[prefix]
        if not fields then
            fields = engine.fields(at)
            seen[prefix] = fields
        end
        local inside = fields[segment]
        if inside == nil then return false, suggest.suggest(segment, fields, 1)[1], nil end
        at, last, prefix = inside, segment, prefix .. "." .. segment
    end
    return true
end

-- Looks one thing up and says what is gone: note("missing" | "unchecked", parts, kind, name, hint, why).
local function look(job, note)
    local path = job.path
    if job.kind == "table" then
        local data = engine.find(TABLES .. path)
        if not data then return note("missing", job.parts, "table", path) end
        local struct, meta_struct, seen = engine.row_struct(data), nil, {}
        if not struct then return note("missing", job.parts, "table", path, nil, "it has no rows to read") end
        for _, item in ipairs(job.wants) do
            local found, hint, why
            if item.what == "meta" then
                if meta_struct == nil then
                    local meta = engine.meta(data)
                    meta_struct = meta and engine.row_struct(meta) or false
                end
                if meta_struct then
                    found, hint, why = walk(meta_struct, item.name, seen, "meta")
                else
                    found, why = false, "the table has no meta table"
                end
            else
                found, hint, why = walk(struct, item.name, seen, "row")
            end
            if not found then
                note("missing", item.parts, "field", path .. (item.what == "meta" and " (its meta table):" or ":") .. item.name, hint, why)
            end
        end
        return
    end
    local object = engine.find(path)
    if not object then
        if job.kind == "class" and not native(path) and job.late then
            return note("unchecked", job.parts, "class", path, nil, "not loaded right now")
        end
        return note("missing", job.parts, job.kind, path)
    end
    if #job.wants == 0 then return end
    if job.kind == "class" then
        local members = engine.members(object)
        for _, item in ipairs(job.wants) do
            local kind = members[item.name]
            if kind ~= item.what then
                local hint, why = nil, nil
                if kind then why = "it is a " .. kind .. " now" else hint = suggest.suggest(item.name, members, 1)[1] end
                note("missing", item.parts, item.what, path .. ":" .. item.name, hint, why)
            end
        end
    elseif job.kind == "struct" then
        local fields = engine.fields(object)
        for _, item in ipairs(job.wants) do
            if fields[item.name] == nil then
                note("missing", item.parts, "field", path .. ":" .. item.name, suggest.suggest(item.name, fields, 1)[1])
            end
        end
    else
        local values = engine.values(object)
        for _, item in ipairs(job.wants) do
            local now = values[item.name]
            if now == nil then
                note("missing", item.parts, "value", path .. ":" .. item.name, suggest.suggest(item.name, values, 1)[1])
            elseif now ~= item.number then
                note("missing", item.parts, "value", path .. ":" .. item.name, nil, ("it is %s now and Wax expects %s"):format(now, item.number))
            end
        end
    end
end

local function adopt(entry)
    current, answers = entry, {}
    if not entry then return end
    for id, part in pairs(entry.parts) do
        if part.ok ~= nil then answers[id] = part.ok end
    end
end

local function agrees(mine, theirs) return mine == nil or theirs == nil or mine == theirs end

-- What was found out before about this version of the game, with the list as it is now.
local function kept_entry()
    local best = nil
    for _, entry in pairs(kept.versions) do
        if entry.list == stamp and agrees(version, entry.version) and agrees(files, entry.files)
            and ((version ~= nil and version == entry.version) or (files ~= nil and files == entry.files)) then
            if not best or (entry.at or 0) > (best.at or 0) then best = entry end
        end
    end
    return best
end

local function entry_id(entry) return (entry.version or "?") .. " " .. (entry.files or "?") end

local function keep(entry)
    kept.versions[entry_id(entry)] = entry
    kept.last = entry_id(entry)
    local ids = {}
    for id in pairs(kept.versions) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b) return (kept.versions[a].at or 0) > (kept.versions[b].at or 0) end)
    for at = M.KEPT_VERSIONS + 1, #ids do
        if ids[at] ~= kept.last then kept.versions[ids[at]] = nil end
    end
    storage.save("wax", "needs", kept)
end

local function names_of(entry, wanted)
    local out = {}
    for _, id in ipairs(order) do
        local part = entry.parts[id]
        if part and part.ok == wanted then out[#out + 1] = by_id[id].name end
    end
    return out
end

-- The notification for an entry: nothing when there is nothing a player needs to hear.
local function message_for(entry, updated)
    local broken, known = names_of(entry, false), names_of(entry, true)
    local text = M.TEXT
    if #broken == 0 then
        if updated and #known == #order then return text.updated_fine end
        return nil
    end
    local line
    if updated then
        line = #broken == 1 and text.updated_one:format(broken[1]) or text.updated_some:format(#broken, table.concat(broken, ", "))
    else
        line = #broken == 1 and text.broken_one:format(broken[1]) or text.broken_some:format(#broken, table.concat(broken, ", "))
    end
    if #known > 0 then line = line .. text.rest end
    return line, true
end

local function read_version()
    if not M.READ_VERSION then return nil end
    local ok, text = pcall(engine.version)
    if ok then return text end
    log:warn("the game's version could not be read: %s", clean(text))
    return nil
end

local function begin()
    local last = kept.last and kept.versions[kept.last]
    local updated = last ~= nil and ((version ~= nil and last.version ~= nil and version ~= last.version)
        or (files ~= nil and last.files ~= nil and files ~= last.files))
    adopt(nil)
    run = { at = 1, updated = updated, notes = {}, cost = 0, worst = 0, frames = 0, failed = false }
    for _, id in ipairs(order) do run.notes[id] = { missing = {}, unchecked = {}, failed = false } end
end

local function finish()
    local check = run
    run, pending = nil, nil
    local entry = { version = version, files = files, list = stamp, at = M.now(), frames = check.frames,
        cost_ms = math.floor(check.cost * 100000 + 0.5) / 100, worst_ms = math.floor(check.worst * 100000 + 0.5) / 100, parts = {} }
    for _, id in ipairs(order) do
        local notes = check.notes[id]
        local part = { missing = notes.missing, unchecked = notes.unchecked }
        if #notes.missing > 0 then part.ok = false elseif not notes.failed then part.ok = true end
        entry.parts[id] = part
    end
    adopt(entry)
    -- a check that could not finish its lookups is made again at the next start
    if check.failed then
        log:warn("some of what Wax uses could not be looked up, so this check is not kept")
    else
        keep(entry)
    end
    local broken = names_of(entry, false)
    if #broken > 0 then
        log:warn("%d of %d parts of Wax do not find what they use in this version of the game: %s", #broken, #order, table.concat(broken, ", "))
    else
        log:info("checked %d lookups in %d frames, %.2f ms in all: every part finds what it uses", #jobs, check.frames, entry.cost_ms)
    end
    last_updated = check.updated
    local text, bad = message_for(entry, check.updated)
    last_message = text
    Checked:Fire(M.report())
    if text and M.NOTIFY then M.notify(text, bad == true) end
end

-- One lookup, with what it wants, in one frame.
local function step_check()
    local job = jobs[run.at]
    if not job then return finish() end
    run.at = run.at + 1
    run.frames = run.frames + 1
    local notes = run.notes
    local function note(state, parts, kind, name, hint, why)
        for id in pairs(parts) do
            local list = notes[id][state]
            list[#list + 1] = { kind = kind, name = name, hint = hint, why = why }
        end
    end
    local started_at = perf.now()
    local ok, problem = pcall(look, job, note)
    local took = perf.now() - started_at
    run.cost = run.cost + took
    if took > run.worst then run.worst = took end
    if not ok then
        run.failed = true
        for id in pairs(job.parts) do notes[id].failed = true end
        note("unchecked", job.parts, job.kind, job.path, nil, clean(problem))
        log:warn("%s could not be looked up: %s", job.path, clean(problem))
    end
    if not jobs[run.at] then finish() end
end

local function stop()
    if live.frame then live.frame:Disconnect() end
    live.frame = nil
end

-- An entry kept before the version could be read gets the version it turned out to be.
local function name_current()
    if not (version and current and not current.version) then return end
    kept.versions[entry_id(current)] = nil
    current.version = version
    keep(current)
end

-- In a prospect, after the wait: settle which version this is, then look things up one a frame.
local function tick()
    if not pending then return stop() end
    frames = frames + 1
    if not due then
        if frames % M.LOOK_FRAMES ~= 0 then return end
        local ok, inside = pcall(engine.in_prospect)
        if not (ok and inside) then return end
        due = M.clock() + (hurry and 0 or M.WAIT_SECONDS)
        hurry = false
        return
    end
    if M.clock() < due then return end
    if not run then
        if not version then version = read_version() end
        if pending == "confirm" and not (version and current.version and current.version ~= version) then
            name_current()
            pending = nil
            return stop()
        end
        pending = "check"
        -- the version may only be readable here, and what was found out about it may be kept already
        local known = not again and kept_entry()
        if known then
            adopt(known)
            pending = nil
            return stop()
        end
        again = false
        begin()
    end
    step_check()
    if not pending then stop() end
end

local function watch()
    if live.frame and live.frame.Connected then return end
    local previous = scope.enter(nil)
    live.frame = sched.Frame:Connect(tick)
    scope.leave(previous)
end

-- true when the part finds what it uses, false when it does not, nothing while that is not known.
-- `part` is an id of data/needs.lua ("crafting") or the name shown to the player.
function M.ok(part)
    local known = answers[part]
    if known ~= nil then return known end
    if not started or by_id[part] then return nil end
    local id = by_name[part]
    if id then return answers[id] end
    error(("'%s' is not a part of data/needs.lua.%s"):format(tostring(part), suggest.phrase(tostring(part), order)), 2)
end

-- One line for a list of parts.
function M.line(part)
    local id = by_id[part] and part or by_name[part]
    if not id then error(("'%s' is not a part of data/needs.lua.%s"):format(tostring(part), suggest.phrase(tostring(part), order)), 2) end
    local text, name = M.TEXT, by_id[id].name
    local known = answers[id]
    if known == true then return text.line_fine:format(name) end
    if known == false then return text.line_broken:format(name, by_id[id].without or "") end
    if current then return text.line_unsure:format(name) end
    return text.line_waiting:format(name)
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = copy(item) end
    return out
end

local function state()
    if not started then return "off" end
    if run then return "checking" end
    return pending == "check" and "waiting" or "done"
end

-- Everything known, as plain values. `state` is "off", "waiting" (for a prospect), "checking" or "done".
function M.report()
    local entry, text = current, M.TEXT
    local out = { state = state(),
        version = entry and entry.version or version, files = entry and entry.files or files,
        checked_at = entry and entry.at or nil, cost_ms = entry and entry.cost_ms or nil, frames = entry and entry.frames or nil,
        worst_ms = entry and entry.worst_ms or nil, lookups = #jobs, updated = last_updated, message = last_message, parts = {} }
    local working = 0
    for at, id in ipairs(order) do
        local part, result = by_id[id], entry and entry.parts[id]
        if answers[id] == true then working = working + 1 end
        out.parts[at] = { id = id, name = part.name, without = part.without, files = copy(part.files or {}), ok = answers[id],
            missing = copy(result and result.missing or {}), unchecked = copy(result and result.unchecked or {}), line = M.line(id) }
    end
    if run then
        out.headline = text.head_checking:format(run.at - 1, #jobs)
    elseif entry then
        out.headline = text.head_done:format(entry.version or "(version not read)", os.date("%Y-%m-%d %H:%M", entry.at), working, #order)
    else
        out.headline = text.head_waiting
    end
    return out
end

-- The notification of the last check, or nothing when it had nothing to say.
function M.message() return last_message end

-- Checks again whatever is kept: at once in a prospect, else in the next one.
function M.recheck()
    if not started then error("needs.recheck before needs.start", 2) end
    adopt(nil)
    run, pending, due, hurry, again = nil, "check", nil, true, true
    frames = M.LOOK_FRAMES - 1
    watch()
end

function M.start()
    local old = rawget(Wax, "needs_live")
    if old then
        for _, connection in pairs(old) do connection:Disconnect() end
    end
    live = { frame = nil, map = nil }
    rawset(Wax, "needs_live", live)

    local parts
    parts, stamp = M.read_list()
    build(parts)
    kept = storage.load("wax", "needs", { versions = {} })
    if type(kept.versions) ~= "table" then kept.versions = {} end
    for id, entry in pairs(kept.versions) do
        if type(entry) ~= "table" or type(entry.parts) ~= "table" then kept.versions[id] = nil end
    end

    local ok, sizes = pcall(engine.files)
    files = ok and sizes or nil
    version = read_version()
    run, due, frames, hurry, again, last_message, last_updated = nil, nil, 0, false, false, nil, false
    adopt(kept_entry())
    if not current then
        pending = "check"
    elseif not version and M.READ_VERSION then
        pending = "confirm"
    else
        pending = nil
        name_current()
    end
    started = true
    live.map = engine.on_map(function() due = nil end)
    if pending then watch() end
end

function M.stats()
    return { state = state(), lookups = #jobs, done = run and run.at - 1 or nil, pending = pending,
        cost_ms = current and current.cost_ms or nil, frames = current and current.frames or nil }
end

return M
