-- The Explorer's list of what is in the world: built a slice per frame, kept current from begin and end of play,
-- and searched and sorted a slice per frame too

local Wax = ...
local actors = Wax.import("engine.actors")
local instance = Wax.import("engine.instance")
local inspect = Wax.import("engine.inspect")
local game = Wax.import("engine.game")

local M = {}

-- how much is done in one frame
M.budget = {
    seed = 120,         -- actors taken from the world while the list is first built
    new = 60,           -- actors that began play
    parts = 6,          -- actors whose components are listed
    filter = 2500,      -- entries tested against the search
    sort = 400,         -- entries sorted in one go
    merge = 2000,       -- entries moved while sorted pieces are joined
    spots = 16,         -- positions read
    first_spots = 60,   -- positions read while some are still unknown
    inserts = 16,       -- new entries put into the shown list one by one
    overflow = 4000,    -- with more than this waiting, the world is walked again instead
    seconds = 0.001,    -- listing stops for the frame after this long, however few that was (a class seen for the first time is slow)
}
M.rerun = 60            -- frames between two runs of a search that depends on distance
M.clock = Wax.import("core.perf").now

local METRE = 100
local find, sqrt = string.find, math.sqrt

local entries, by_address = {}, {}
local actor_count, part_count, removed_total = 0, 0, 0
local classes = {}                      -- class name -> how many actors have it
local pending, waiting = {}, {}         -- actors that began play since the last frame, and the same by address
local seq, frame, version, mark = 0, 0, 0, 0
local awake, walk = false, nil
local stop_began, stop_ended = nil, nil
local holes, result_holes = false, false
local want_parts, parts_at = false, 1
local spots_at, covered, fresh = 1, false, {}
local query = { text = "", words = {}, kind = "actors", near = nil, sort = "name", distance = false }
local results, results_version = {}, 0
local job, stale, last_run, inserts = nil, false, 0, 0
local origin = nil                      -- where distances are measured from
local deadline = math.huge              -- when this frame's listing has to stop
local function late() return M.clock() > deadline end
local did = { seeded = 0, added = 0, removed = 0, parts = 0, spots = 0, filtered = 0, sorted = 0, merged = 0 }
local most = {}

local ORDER = {
    name = function(a, b)
        if a.name_key ~= b.name_key then return a.name_key < b.name_key end
        return a.seq < b.seq
    end,
    class = function(a, b)
        if a.class_key ~= b.class_key then return a.class_key < b.class_key end
        if a.name_key ~= b.name_key then return a.name_key < b.name_key end
        return a.seq < b.seq
    end,
    newest = function(a, b)
        if a.began ~= b.began then return a.began > b.began end
        return a.seq > b.seq
    end,
    distance = function(a, b)
        local near, far = a.distance or math.huge, b.distance or math.huge
        if near ~= far then return near < far end
        return a.seq < b.seq
    end,
}

local function fits(entry, q)
    if entry.gone then return false end
    local kind = q.kind
    if kind == "actors" then
        if entry.owner then return false end
    elseif kind == "components" then
        if not entry.owner then return false end
    elseif kind ~= "everything" and entry.kind ~= kind then
        return false
    end
    local key, words = entry.key, q.words
    for i = 1, #words do
        if not find(key, words[i], 1, true) then return false end
    end
    if q.distance then
        local at, distance = entry.owner or entry, nil      -- a component is where its actor is
        if origin and at.x then distance = sqrt((at.x - origin[1]) ^ 2 + (at.y - origin[2]) ^ 2 + (at.z - origin[3]) ^ 2) / METRE end
        entry.distance = distance
        if q.near and (not distance or distance > q.near) then return false end
    end
    return true
end

local function insert(list, entry, before)
    local low, high = 1, #list + 1
    while low < high do
        local middle = (low + high) // 2
        if before(entry, list[middle]) then high = middle else low = middle + 1 end
    end
    table.insert(list, low, entry)
end

-- Takes an entry out. Its object is not asked anything.
local function unlist(entry)
    if entry.gone then return end
    entry.gone = true
    if by_address[entry.address] == entry then by_address[entry.address] = nil end
    if entry.owner then
        part_count = part_count - 1
    else
        actor_count = actor_count - 1
        local left = (classes[entry.class_name] or 1) - 1
        classes[entry.class_name] = left > 0 and left or nil
    end
    holes, result_holes = true, true
    version, removed_total = version + 1, removed_total + 1
    did.removed = did.removed + 1
    local parts = entry.parts
    if parts then
        entry.parts = nil
        for i = 1, #parts do unlist(parts[i]) end
    end
end

local function name_of(inst) return inst.Name end

-- Lists an Instance. `owner` is the entry of the actor a component belongs to. Returns the new entry, or nil when it was listed already.
local function list(inst, began, owner)
    local address = instance.address(inst)
    local old = by_address[address]
    if old then
        if rawequal(old.instance, inst) then
            old.mark = mark
            return nil
        end
        unlist(old)
    end
    local ok, name = pcall(name_of, inst)
    if not ok then return nil end
    local class_name, kind = inst.ClassName, "component"
    if not owner then
        local known, found = pcall(inspect.kind, inst)
        kind = known and found or "actor"
    end
    seq = seq + 1
    local name_key, class_key = name:lower(), class_name:lower()
    local entry = { instance = inst, address = address, name = name, class_name = class_name, kind = kind, seq = seq,
        began = began, mark = mark, owner = owner or false, name_key = name_key, class_key = class_key,
        key = name_key .. " " .. class_key, depth = 1 }
    by_address[address] = entry
    entries[#entries + 1] = entry
    if owner then
        part_count = part_count + 1
        owner.parts = owner.parts or {}
        owner.parts[#owner.parts + 1] = entry
    else
        actor_count = actor_count + 1
        classes[class_name] = (classes[class_name] or 0) + 1
        if query.distance then fresh[#fresh + 1] = entry end
    end
    version = version + 1
    did.added = did.added + 1
    if job then
        -- a search that is still reading the list comes to it; one that is past that takes it at the end
        if job.late then job.late[#job.late + 1] = entry end
    elseif not query.distance and fits(entry, query) then
        inserts = inserts + 1
        if inserts > M.budget.inserts then
            stale = true
        else
            insert(results, entry, ORDER[query.sort])
            results_version = results_version + 1
        end
    end
    return entry
end

-- Inside the engine's own call: only note it. The actor is listed in the next frame.
local function began(actor)
    local address = actor:GetAddress()
    local record = { actor = actor, address = address }
    waiting[address] = record
    pending[#pending + 1] = record
end

local function ended(_, address)
    local record = waiting[address]
    if record then
        record.actor = nil
        waiting[address] = nil
    end
    local entry = by_address[address]
    if entry then unlist(entry) end
end

local function start_walk()
    mark = mark + 1
    walk = { place = nil }
end

local function take_new()
    local count = #pending
    if count == 0 then return end
    if count > M.budget.overflow then
        pending, waiting = {}, {}
        start_walk()
        return
    end
    local upto = 0
    for i = 1, math.min(count, M.budget.new) do
        upto = i
        local record = pending[i]
        local actor = record.actor
        if actor then
            record.actor = nil
            if waiting[record.address] == record then waiting[record.address] = nil end
            local ok, inst = pcall(instance.wrap, actor)
            if ok and inst then list(inst, frame) end
            if late() then break end
        end
    end
    pending = upto == count and {} or table.move(pending, upto + 1, count, 1, {})
end

local function seed()
    if not walk then return end
    local ok, found, place = pcall(game.actors_from, walk.place, M.budget.seed, late)
    if not ok then
        walk = nil
        return
    end
    for i = 1, #found do list(found[i], 0) end
    did.seeded = #found
    if place then
        walk.place = place
        return
    end
    walk = nil
    -- what the walk did not meet has left the world
    for i = 1, #entries do
        local entry = entries[i]
        if not entry.gone and not entry.owner and entry.mark ~= mark then unlist(entry) end
    end
end

local function take_parts()
    local done, count = 0, #entries
    while parts_at <= count and done < M.budget.parts do
        local entry = entries[parts_at]
        parts_at = parts_at + 1
        if not entry.gone and not entry.owner and not entry.parted then
            entry.parted = true
            done = done + 1
            local ok, found = pcall(inspect.parts, entry.instance)
            if ok then
                for i = 1, #found do list(found[i], entry.began, entry) end
            end
            if late() then break end
        end
    end
    did.parts = done
end

local function drop_parts()
    for i = 1, #entries do
        local entry = entries[i]
        if entry.owner then
            unlist(entry)
        else
            entry.parted, entry.parts = nil, nil
        end
    end
    parts_at = 1
end

local function read_spot(entry)
    local x, y, z = inspect.position(entry.instance)
    entry.x, entry.y, entry.z = x or false, y, z
end

local function take_spots()
    local budget = covered and M.budget.spots or M.budget.first_spots
    local done, looked, count = 0, 0, #entries
    while done < budget and #fresh > 0 do
        local entry = table.remove(fresh)
        if not entry.gone then
            read_spot(entry)
            done = done + 1
        end
    end
    while done < budget and looked < budget * 8 and count > 0 do
        if spots_at > count then spots_at, covered = 1, true end
        local entry = entries[spots_at]
        spots_at, looked = spots_at + 1, looked + 1
        if not entry.gone and not entry.owner then
            read_spot(entry)
            done = done + 1
        end
    end
    did.spots = done
end

local function compact()
    if result_holes and not job then
        local kept = {}
        for i = 1, #results do
            local entry = results[i]
            if not entry.gone then kept[#kept + 1] = entry end
        end
        results, result_holes = kept, false
        results_version = results_version + 1
    end
    if holes and frame % 30 == 0 and not job then
        local kept = {}
        for i = 1, #entries do
            local entry = entries[i]
            if not entry.gone then kept[#kept + 1] = entry end
        end
        entries, holes, parts_at, spots_at = kept, false, 1, 1
    end
end

local function start(source)
    if query.distance then
        origin = nil
        local ok, me = pcall(function() return game.root.Character end)
        if ok and me then
            local x, y, z = inspect.position(me)
            if x then origin = { x, y, z } end
        end
    end
    job = { phase = "filter", source = source or entries, sorted = source ~= nil, at = 1, found = {},
        late = source and {} or nil, removed = removed_total }
    stale, last_run = false, frame
end

local function finish(found)
    local extra, before = job.late or {}, ORDER[query.sort]
    result_holes = removed_total ~= job.removed
    job = nil
    if #extra > M.budget.inserts * 4 then
        stale = true
    else
        for i = 1, #extra do
            if fits(extra[i], query) then insert(found, extra[i], before) end
        end
    end
    results = found
    results_version = results_version + 1
end

local function run()
    local budget, before = M.budget, ORDER[query.sort]
    if job.phase == "filter" then
        local source, found = job.source, job.found
        local upto = math.min(#source, job.at + budget.filter - 1)
        for i = job.at, upto do
            local entry = source[i]
            if fits(entry, query) then found[#found + 1] = entry end
        end
        did.filtered = upto - job.at + 1
        job.at = upto + 1
        if job.at <= #source then return end
        job.late = job.late or {}
        if job.sorted then return finish(found) end
        if #found <= budget.sort then
            table.sort(found, before)
            did.sorted = #found
            return finish(found)
        end
        job.phase, job.at, job.runs, job.joined = "sort", 1, {}, {}
        return
    end
    if job.phase == "sort" then
        local found = job.found
        local upto = math.min(#found, job.at + budget.sort - 1)
        local piece = table.move(found, job.at, upto, 1, {})
        table.sort(piece, before)
        job.runs[#job.runs + 1] = piece
        did.sorted = #piece
        job.at = upto + 1
        if job.at > #found then job.phase, job.found = "merge", nil end
        return
    end
    -- sorted pieces are joined two at a time until one is left
    local moves = budget.merge
    while moves > 0 do
        local joining = job.joining
        if not joining then
            if #job.runs == 0 then
                job.runs, job.joined = job.joined, {}
                if #job.runs <= 1 then return finish(job.runs[1] or {}) end
            end
            local first, second = table.remove(job.runs), table.remove(job.runs)
            if second then
                job.joining = { a = first, b = second, i = 1, j = 1, out = {} }
            else
                job.joined[#job.joined + 1] = first
            end
        else
            local a, b, i, j, out = joining.a, joining.b, joining.i, joining.j, joining.out
            local a_count, b_count, count = #a, #b, #out
            while moves > 0 and i <= a_count and j <= b_count do
                count = count + 1
                if before(b[j], a[i]) then
                    out[count], j = b[j], j + 1
                else
                    out[count], i = a[i], i + 1
                end
                moves = moves - 1
            end
            did.merged = budget.merge - moves
            if i > a_count or j > b_count then
                if i <= a_count then table.move(a, i, a_count, count + 1, out) else table.move(b, j, b_count, count + 1, out) end
                job.joined[#job.joined + 1] = out
                job.joining = nil
            else
                joining.i, joining.j = i, j
            end
        end
    end
end

-- What to show: { text, kind, near, sort }. text is words that all have to be in the name or the class, kind is "actors",
-- "components", "everything" or one kind, near is a number of metres or nil, sort is "name", "class", "distance" or "newest".
-- Returns false when that is what is being shown already.
function M.query(spec)
    local text = tostring(spec.text or ""):lower()
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    local q = { text = text, words = {}, kind = spec.kind or "actors", near = spec.near or nil, sort = spec.sort or "name" }
    if not ORDER[q.sort] then error("the sort is \"name\", \"class\", \"distance\" or \"newest\"", 2) end
    for word in text:gmatch("%S+") do q.words[#q.words + 1] = word end
    q.distance = q.near ~= nil or q.sort == "distance"
    local old = query
    if old.text == q.text and old.kind == q.kind and old.near == q.near and old.sort == q.sort then return false end
    -- more letters of the same search only have to look at what the search found before
    local narrows = not job and not stale and not q.distance and not old.distance and old.kind == q.kind and old.sort == q.sort
        and #q.text > #old.text and q.text:sub(1, #old.text) == old.text
    query = q
    local parts_needed = q.kind == "components" or q.kind == "everything"
    if parts_needed ~= want_parts then
        want_parts, parts_at = parts_needed, 1
        if not parts_needed then drop_parts() end
    end
    if awake then start(narrows and results or nil) else stale = true end
    return true
end

-- Starts listening and walks the world once (again after a sleep, to find what changed meanwhile).
function M.wake()
    if awake then return end
    awake = true
    stop_began = actors.on_began(began)
    stop_ended = actors.on_ended(ended)
    start_walk()
    stale = true
end

-- Stops everything. Nothing is looked at again until wake.
function M.sleep()
    if not awake then return end
    awake = false
    stop_began()
    stop_ended()
    stop_began, stop_ended = nil, nil
    pending, waiting, walk, job = {}, {}, nil, nil
end

-- After a map change: the list is emptied without asking anything in it.
function M.reset()
    entries, by_address, classes = {}, {}, {}
    actor_count, part_count = 0, 0
    pending, waiting, fresh = {}, {}, {}
    results, job, holes, result_holes = {}, nil, false, false
    parts_at, spots_at, covered, origin = 1, 1, false, nil
    version, results_version = version + 1, results_version + 1
    if awake then start_walk() end
end

-- Once per frame while the Explorer shows.
function M.step()
    if not awake then return end
    frame = frame + 1
    for name in pairs(did) do did[name] = 0 end
    inserts = 0
    deadline = M.clock() + M.budget.seconds
    take_new()
    seed()
    if want_parts then take_parts() end
    if query.distance then take_spots() end
    compact()
    if job then
        run()
    elseif stale or (query.distance and frame - last_run >= M.rerun) then
        start()
    end
    for name, amount in pairs(did) do
        if amount > (most[name] or 0) then most[name] = amount end
    end
end

-- The entries that fit the search, in order, and a number that changes whenever that list does.
function M.results() return results, results_version end
function M.awake() return awake end
function M.seeding() return walk ~= nil end
function M.searching() return job ~= nil or stale end
function M.counts() return actor_count, part_count end
function M.unique(class_name) return classes[class_name] == 1 end
function M.frame() return frame end
function M.current() return query end

-- The entry of an Instance, or nil when it is not listed.
function M.entry_of(inst)
    local entry = by_address[instance.address(inst)]
    return entry and rawequal(entry.instance, inst) and entry or nil
end

function M.stats()
    local now, peak = {}, {}
    for name, amount in pairs(did) do now[name] = amount end
    for name, amount in pairs(most) do peak[name] = amount end
    return { awake = awake, actors = actor_count, components = part_count, listed = #entries, waiting = #pending,
        seeding = walk ~= nil, searching = job and job.phase or false, shown = #results, version = version,
        thisFrame = now, mostInAFrame = peak, budget = M.budget }
end

return M
