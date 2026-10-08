-- The mod catalogue as the game sees it: the list, kept and searched here, and adding a mod from it.
-- Nothing is asked of the network until the Browse page is opened, and nothing while "Look for updates" is off.

local Wax = ...
local log = Wax.import("core.log").channel("wax.browse")
local scope = Wax.import("core.scope")
local sched = Wax.import("core.sched")
local storage = Wax.import("core.storage")

local task = sched.task
local browse = {}

local FRESH_SECONDS = 60           -- a list younger than this is not asked for again
local PER_PAGE, MAX_PAGES = 100, 10
local KEEP = 1000
local ID = "^[A-Za-z][A-Za-z0-9_]*$"

browse.Changed = sched.Signal.new("browse")
browse.time = os.time              -- replaced in tests

local mods, by_id = {}, {}
local read_at, loading, problem = 0, false, nil
local adding = {}                  -- id -> true while its files are fetched
local restored = false

local function changed() browse.Changed:Fire() end

local function text_of(value) return type(value) == "string" and value or "" end

-- One mod of the catalogue, cut down to what is shown and kept.
local function entry_of(raw)
    if type(raw) ~= "table" or type(raw.id) ~= "string" or not raw.id:match(ID) or #raw.id > 64 then return nil end
    local latest = type(raw.latest) == "table" and raw.latest or {}
    local votes = type(raw.votes) == "table" and raw.votes or {}
    local tags, needs = {}, {}
    for _, tag in ipairs(type(raw.tags) == "table" and raw.tags or {}) do
        if type(tag) == "string" and #tags < 12 then tags[#tags + 1] = tag:sub(1, 32) end
    end
    for _, other in ipairs(type(latest.dependencies) == "table" and latest.dependencies or {}) do
        if type(other) == "string" and other:match(ID) and #needs < 16 then needs[#needs + 1] = other end
    end
    return {
        id = raw.id, name = text_of(raw.name) ~= "" and raw.name:sub(1, 80) or raw.id, summary = text_of(raw.summary):sub(1, 300),
        author = text_of(raw.author):sub(1, 60), category = text_of(raw.category):sub(1, 40), tags = tags,
        needs_wax = text_of(raw.needs_wax):sub(1, 20), reviewed = raw.reviewed == true,
        downloads = tonumber(raw.downloads) or 0, up = tonumber(votes.up) or 0, down = tonumber(votes.down) or 0,
        created = text_of(raw.created_at):sub(1, 24), updated = text_of(raw.updated_at):sub(1, 24),
        version = text_of(latest.version):sub(1, 32), size = tonumber(latest.unpacked_size) or 0, files = tonumber(latest.files) or 0,
        needs = needs,
        pictures = math.min(6, type(raw.pictures) == "table" and #raw.pictures or math.tointeger(raw.pictures) or 0),
    }
end

local function take(list, at)
    mods, by_id = {}, {}
    for _, raw in ipairs(list) do
        local entry = entry_of(raw)
        if entry and not by_id[entry.id] and #mods < KEEP then
            mods[#mods + 1] = entry
            by_id[entry.id] = entry
        end
    end
    read_at = at
end

-- The list of the last session shows at once, until the catalogue has answered.
local function restore()
    if restored then return end
    restored = true
    local kept = storage.load("wax", "browse", { at = 0, mods = {} })
    if type(kept) == "table" and type(kept.mods) == "table" and #kept.mods > 0 then
        local list = {}
        for _, entry in ipairs(kept.mods) do
            if type(entry) == "table" then
                list[#list + 1] = { id = entry.id, name = entry.name, summary = entry.summary, author = entry.author,
                    category = entry.category, tags = entry.tags, needs_wax = entry.needs_wax, reviewed = entry.reviewed,
                    downloads = entry.downloads, votes = { up = entry.up, down = entry.down }, created_at = entry.created,
                    updated_at = entry.updated, pictures = entry.pictures,
                    latest = { version = entry.version, unpacked_size = entry.size, files = entry.files, dependencies = entry.needs } }
            end
        end
        take(list, 0)
        browse.kept_from = tonumber(kept.at) or 0
    end
end

local function updater()
    local update = Wax.update
    return update, update and update.shared
end

local function read_all(shared)
    local all, total = {}, nil
    for page = 1, MAX_PAGES do
        local output = ("plan/browse-%d.json"):format(page)
        shared.fetch({ { ("/api/mods?sort=updated&per_page=%d&page=%d"):format(PER_PAGE, page), output } })
        local answer = shared.answer(output, "the list of mods")
        if type(answer.mods) ~= "table" then shared.fail("the list of mods: the answer could not be read") end
        for _, raw in ipairs(answer.mods) do all[#all + 1] = raw end
        total = tonumber(answer.total) or #all
        if #answer.mods < PER_PAGE or #all >= total then break end
    end
    return all
end

-- Asks the catalogue for its list, unless the one here is fresh. force asks anyway.
function browse.refresh(force)
    restore()
    local update, shared = updater()
    if loading then return true end
    if not shared or shared.stopped() then
        problem = "The helper that downloads is missing, so the catalogue cannot be read."
        changed()
        return false
    end
    if not shared.looking() then
        problem = "\"Look for updates\" is switched off on the Mods page, so the catalogue is not asked."
        changed()
        return false
    end
    if not force and read_at > 0 and sched.clock() - read_at < FRESH_SECONDS then return true end
    loading = true
    changed()
    local previous = scope.enter(nil)
    task.label(task.spawn(function()
        local ok, why = shared.attempt(function() take(read_all(shared), sched.clock()) end)
        -- the votes cast from this address, on the site or in the game, so both show the same
        if ok then
            shared.attempt(function()
                shared.fetch({ { "/api/votes/mine", "plan/votes-mine.json" } })
                local mine = shared.answer("plan/votes-mine.json", "your votes").mine
                if type(mine) == "table" and browse.take_votes then browse.take_votes(mine) end
            end)
        end
        loading = false
        if ok then
            problem, browse.kept_from = nil, nil
            storage.save("wax", "browse", { at = browse.time(), mods = mods })
            if update.check_now then pcall(update.check_now) end
        else
            problem = "The catalogue could not be read."
            log:warn("could not read the catalogue: %s", tostring(why))
        end
        changed()
    end), "browse catalogue")
    scope.leave(previous)
    return true
end

local function lower(text) return text:lower() end

local SORTS = {
    updated = function(a, b) if a.updated ~= b.updated then return a.updated > b.updated end return a.id < b.id end,
    new = function(a, b) if a.created ~= b.created then return a.created > b.created end return a.id < b.id end,
    downloads = function(a, b) if a.downloads ~= b.downloads then return a.downloads > b.downloads end return a.id < b.id end,
    votes = function(a, b)
        local x, y = a.up - a.down, b.up - b.down
        if x ~= y then return x > y end
        if a.downloads ~= b.downloads then return a.downloads > b.downloads end
        return a.id < b.id
    end,
    name = function(a, b)
        local x, y = lower(a.name), lower(b.name)
        if x ~= y then return x < y end
        return a.id < b.id
    end,
}

-- Every word typed has to be somewhere in the mod's name, id, author, summary, category or tags.
local function matches(entry, words)
    if #words == 0 then return true end
    local hay = lower(table.concat({ entry.name, entry.id, entry.author, entry.summary, entry.category, table.concat(entry.tags, " ") }, " "))
    for _, word in ipairs(words) do
        if not hay:find(word, 1, true) then return false end
    end
    return true
end

-- The mods that fit: query = { text, category, tag, sort, have }. have is "all", "new" (not here yet) or "here".
function browse.find(query, list)
    query = query or {}
    local words = {}
    for word in lower(text_of(query.text)):gmatch("%S+") do words[#words + 1] = word end
    local out = {}
    for _, entry in ipairs(list or mods) do
        local fits = matches(entry, words) and (not query.category or entry.category == query.category)
        if fits and query.tag then
            fits = false
            for _, tag in ipairs(entry.tags) do fits = fits or tag == query.tag end
        end
        if fits and query.have and query.have ~= "all" then
            local here = Wax.mods and Wax.mods.get(entry.id) ~= nil
            fits = (query.have == "here") == here
        end
        if fits then out[#out + 1] = entry end
    end
    table.sort(out, SORTS[query.sort] or SORTS.updated)
    return out
end

-- The categories and tags the listed mods have, most used first.
function browse.facets()
    local function counted(pick)
        local count, names = {}, {}
        for _, entry in ipairs(mods) do
            for _, name in ipairs(pick(entry)) do
                if name ~= "" then
                    if not count[name] then names[#names + 1] = name end
                    count[name] = (count[name] or 0) + 1
                end
            end
        end
        table.sort(names, function(a, b)
            if count[a] ~= count[b] then return count[a] > count[b] end
            return a < b
        end)
        return names
    end
    return counted(function(entry) return { entry.category } end), counted(function(entry) return entry.tags end)
end

-- What the page shows about the list itself.
function browse.state()
    restore()
    return { count = #mods, loading = loading, problem = problem, age = read_at > 0 and sched.clock() - read_at or nil,
        kept_from = browse.kept_from }
end

-- How a listed mod stands here: "new", "here", "update" (a newer one is known), "adding", or "older" (it needs a newer Wax).
function browse.standing(id)
    local entry = by_id[id]
    local update, shared = updater()
    if adding[id] then return "adding" end
    local state = update and update.state and update.state() or nil
    if Wax.mods.get(id) then
        if state and state.available[id] then return "update", state.available[id] end
        return "here"
    end
    local running = (Wax.root and (io.open(Wax.root .. "/VERSION", "rb")))
    if running then
        local word = (running:read("a") or ""):match("^%s*(%S+)")
        running:close()
        if entry and entry.needs_wax ~= "" and word and update and update.newer and update.newer(entry.needs_wax, word) then
            return "older", entry.needs_wax
        end
    end
    if shared == nil then return "new" end
    return "new"
end

function browse.get(id) return by_id[id] end

local pictures, details = {}, {}
local PNG, JPG = "\137PNG\r\n\26\n", "\255\216\255"

local function in_background(label, fn)
    local previous = scope.enter(nil)
    task.label(task.spawn(fn), label)
    scope.leave(previous)
end

local function is_picture(path)
    local file = io.open(path, "rb")
    if not file then return false end
    local head = file:read(8) or ""
    file:close()
    return head == PNG or head:sub(1, 3) == JPG
end

-- The file of a mod's picture, fetched once and kept between sessions. Returns the path, or nil and "loading" or "none".
function browse.picture(id, number)
    local entry = by_id[id]
    local _, shared = updater()
    if not entry or not shared or math.type(number) ~= "integer" or number < 1 or number > entry.pictures then return nil, "none" end
    local name = ("pictures/%s-%d-%s.img"):format(id, number, (entry.updated:gsub("%D", "")):sub(1, 14))
    local known = pictures[name]
    if known == "loading" or known == "none" then return nil, known end
    local path = shared.net .. "/" .. name
    if known == nil and is_picture(path) then pictures[name] = path end
    if pictures[name] then return pictures[name] end
    if shared.stopped() or not shared.looking() then return nil, "none" end
    pictures[name] = "loading"
    in_background("browse picture", function()
        local ok = shared.attempt(function()
            shared.fetch({ { ("/api/mods/%s/pictures/%d"):format(id, number), name } })
            local code = shared.status_of(name)
            shared.pause()
            os.remove(path .. ".status")
            if code ~= 200 then shared.fail("no picture") end
        end)
        -- a picture of a kind the game cannot read (WebP) is not shown
        pictures[name] = ok and is_picture(path) and path or "none"
        changed()
    end)
    return nil, "loading"
end

local my_votes, voting = nil, {}

local function votes_kept()
    if not my_votes then
        local kept = storage.load("wax", "votes", {})
        my_votes = {}
        for id, vote in pairs(type(kept) == "table" and kept or {}) do
            if type(id) == "string" and (vote == 1 or vote == -1) then my_votes[id] = vote end
        end
    end
    return my_votes
end

-- What the catalogue says this address voted, in place of what was remembered here. A vote on its way is left alone.
function browse.take_votes(mine)
    local kept = votes_kept()
    for id in pairs(kept) do
        if not voting[id] then kept[id] = nil end
    end
    for id, vote in pairs(mine) do
        if type(id) == "string" and (vote == 1 or vote == -1) and not voting[id] then kept[id] = vote end
    end
    storage.save("wax", "votes", kept)
end

-- The vote cast from this game for a mod: 1, -1 or 0.
function browse.my_vote(id) return votes_kept()[id] or 0 end

-- Casts 1 (like), -1 (dislike) or 0 (none) for a listed mod. The count changes here at once and is put right by the
-- catalogue's answer. Returns false and why when it cannot be asked.
function browse.vote(id, vote)
    local entry = by_id[id]
    local _, shared = updater()
    if not entry or (vote ~= 1 and vote ~= -1 and vote ~= 0) then return false, "the catalogue does not list it" end
    if not shared or shared.stopped() then return false, "the helper that talks to the catalogue is missing" end
    if not shared.looking() then return false, "\"Look for updates\" is switched off on the Mods page" end
    if voting[id] then return true end
    local kept = votes_kept()
    local before, up, down = kept[id] or 0, entry.up, entry.down
    if before == vote then return true end
    voting[id] = true
    if before == 1 then entry.up = math.max(0, entry.up - 1) elseif before == -1 then entry.down = math.max(0, entry.down - 1) end
    if vote == 1 then entry.up = entry.up + 1 elseif vote == -1 then entry.down = entry.down + 1 end
    kept[id] = vote ~= 0 and vote or nil
    changed()
    in_background("browse vote", function()
        local answer = nil
        local ok, why = shared.attempt(function()
            local output = "plan/vote-" .. id .. ".json"
            shared.fetch({ { ("/api/mods/%s/vote/ticket"):format(id), output } })
            local ticket = shared.answer(output, "the vote").ticket
            if type(ticket) ~= "string" or not ticket:match("^%d+%.[%w_%-]+$") then shared.fail("the catalogue gave no ticket for the vote") end
            shared.fetch({ { ("/api/mods/%s/vote/cast?vote=%d&ticket=%s"):format(id, vote, ticket), output } })
            answer = shared.answer(output, "the vote")
        end)
        voting[id] = nil
        local now = by_id[id]
        if ok and type(answer.votes) == "table" then
            if now then now.up, now.down = tonumber(answer.votes.up) or now.up, tonumber(answer.votes.down) or now.down end
            storage.save("wax", "votes", kept)
        else
            -- the vote did not arrive: the numbers and the mark go back to what they were
            if now then now.up, now.down = up, down end
            kept[id] = before ~= 0 and before or nil
            log:warn("the vote for %s was not counted: %s", id, tostring(why))
            local ui = Wax.ui
            if ui and ui.Notify then pcall(ui.Notify, "Your vote was not counted. Try again in a moment.", { title = entry.name, kind = "bad" }) end
        end
        changed()
    end)
    return true
end

-- The long description of a mod and how many versions it has. Returns nil while it is being read.
function browse.detail(id)
    local entry = by_id[id]
    local _, shared = updater()
    if not entry or not shared then return nil end
    local known = details[id]
    if known and known ~= "loading" and (known.version == entry.version) then return known end
    if known == "loading" or shared.stopped() or not shared.looking() then return nil end
    details[id] = "loading"
    in_background("browse detail", function()
        local found = { version = entry.version, description = "", versions = 0 }
        shared.attempt(function()
            local output = "plan/browse-mod-" .. id .. ".json"
            shared.fetch({ { "/api/mods/" .. id, output } })
            local answer = shared.answer(output, "the mod")
            found.description = text_of(answer.description):sub(1, 4000)
            found.versions = type(answer.versions) == "table" and #answer.versions or 0
        end)
        details[id] = found
        changed()
    end)
    return nil
end

local function bring(shared, entry)
    local id, version = entry.id, entry.version
    if Wax.mods.get(id) then shared.fail("it is already in the mods folder") end
    local base = ("/api/mods/%s/files/%s"):format(id, shared.encode(version))
    local listing, stage = "plan/" .. id .. ".json", "stage/" .. id
    shared.fetch({ { base, listing } })
    local plan = shared.answer(listing, "the list of its files")
    local files = shared.read_plan(plan, id, version)
    -- every file below is checked against this list, so nothing is fetched before the list is known to be the owner's
    shared.check_signed(("mod %s %s"):format(id, version), files, plan.signature, "plan/" .. id .. ".list")
    local jobs = { { "-", stage } }
    for index, file in ipairs(files) do
        jobs[index + 1] = { base .. "/" .. file.path:gsub("[^/]+", shared.encode), stage .. "/" .. file.path }
    end
    shared.fetch(jobs)
    local cleared = shared.status_of(stage)
    shared.pause()
    if cleared ~= 200 then shared.fail("the folder the download goes to could not be emptied") end
    os.remove(shared.net .. "/" .. stage .. ".status")
    for _, file in ipairs(files) do
        local output = stage .. "/" .. file.path
        local code, bytes, hash, why = shared.status_of(output)
        shared.pause()
        if code ~= 200 then
            shared.fail(("%s was not downloaded (%s)"):format(file.path, code == 0 and why or ("the catalogue answered " .. code)))
        end
        if bytes ~= file.size or hash ~= file.sha256 then shared.fail(file.path .. " does not match its checksum") end
        os.remove(shared.net .. "/" .. output .. ".status")
        shared.check_file(shared.net .. "/" .. output, file)
        shared.pause()
    end
    local expected = {}
    for _, file in ipairs(files) do expected[file.path] = true end
    for name in pairs(shared.files_under(stage) or {}) do
        if not expected[name] then shared.fail("the download holds a file the catalogue does not list: " .. shared.shown(name)) end
    end
    if not shared.write(shared.net .. "/" .. stage .. "/" .. shared.origin, ("id=%s\nversion=%s\n"):format(id, version)) then
        shared.fail("the download could not be marked as coming from the catalogue")
    end
    -- a mod the player did not have is new: it stays switched off until they switch it on
    if not shared.write(shared.net .. "/" .. stage .. "/" .. shared.mark, "new\n") then
        shared.fail("the download could not be marked as a new mod")
    end
    shared.pause()
    if Wax.mods.get(id) then shared.fail("a mod of that name appeared while it was downloaded") end
    local moved, reason = os.rename(shared.net .. "/" .. stage, Wax.root .. "/mods/" .. id)
    if not moved then shared.fail(("the files could not be moved into the mods folder (%s)"):format(shared.shown(reason))) end
    Wax.mods.request_sync()
end

-- Adds a listed mod to the mods folder, switched off. The page asks the player first. Returns false and why when it cannot start.
function browse.add(id)
    local entry = by_id[id]
    local _, shared = updater()
    if not entry or entry.version == "" then return false, "the catalogue does not list it" end
    if not shared or shared.stopped() or not shared.read_plan then return false, "the helper that downloads is missing" end
    if not shared.looking() then return false, "\"Look for updates\" is switched off on the Mods page" end
    if adding[id] then return true end
    local standing, detail = browse.standing(id)
    if standing == "older" then return false, ("it needs Wax %s or newer"):format(detail) end
    if standing ~= "new" then return false, "it is already in the mods folder" end
    adding[id] = true
    changed()
    local previous = scope.enter(nil)
    task.label(task.spawn(function()
        local ok, why = shared.attempt(bring, shared, entry)
        adding[id] = nil
        local ui = Wax.ui
        if ok then
            log:info("%s %s was added from the catalogue, switched off", id, entry.version)
            if ui and ui.Notify then
                pcall(ui.Notify, ("%s was added. It is switched off until you enable it on the Mods page."):format(entry.name),
                    { title = "New mod", icon = "package-plus", seconds = 8 })
            end
        else
            log:warn("%s could not be added: %s", id, tostring(why))
            if ui and ui.Notify then
                pcall(ui.Notify, tostring(why), { title = "Could not add " .. entry.name, kind = "bad", seconds = 10 })
            end
            -- what was downloaded is not left lying about
            if shared.attempt(shared.fetch, { { "-", "stage/" .. id } }) then os.remove(shared.net .. "/stage/" .. id .. ".status") end
        end
        changed()
    end), "browse add " .. id)
    scope.leave(previous)
    return true
end

return browse
