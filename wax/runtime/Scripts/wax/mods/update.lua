-- Keeps mods that were added from the catalogue up to date. A mod folder without a wax.origin file is never touched

local Wax = ...
local log = Wax.import("core.log").channel("wax.update")
local scope = Wax.import("core.scope")
local sched = Wax.import("core.sched")
local storage = Wax.import("core.storage")
local json = Wax.import("data.json")

local task = sched.task
local update = {}

local FIRST_SECONDS, EVERY_SECONDS, GAP_SECONDS = 20, 6 * 3600, 60
local POLL_FRAMES = 30                      -- how often the answer to a request is looked for
local MAX_FILES, MAX_BYTES = 500, 20 * 1024 * 1024
local MAX_OUTPUT, MAX_FULL_PATH = 220, 255
local ORIGIN, MARK = "wax.origin", "wax.new"    -- the two files in a mod's folder that are Wax's own, never the mod's
local NET = Wax.root .. "/run/net"
local KINDS, DEVICES = {}, {}
for kind in ("lua json txt md png jpg jpeg webp ogg wav csv obj"):gmatch("%a+") do KINDS[kind] = true end
for name in ("CON PRN AUX NUL"):gmatch("%a+") do DEVICES[name] = true end
for digit = 0, 9 do DEVICES["COM" .. digit], DEVICES["LPT" .. digit] = true, true end

update.loadlib = package.loadlib            -- replaced in tests
update.time = os.time                       -- replaced in tests
update.Changed = sched.Signal.new("update") -- fired whenever update.state() would answer differently

-- look: whether the catalogue is asked at all. mods: id -> that mod's own Auto Update switch. auto: what a mod without one gets
local settings = { look = true, auto = true, last = 0, mods = {} }
local available, queued, queue = {}, {}, {}
local origins, roster = {}, nil             -- id -> the version its wax.origin gives, and the mods that were looked at for it
local checking, problem, wanted, asked_at = false, nil, false, nil
local worker, helper, dead = nil, nil, false
local wax_version, run_number = nil, nil
local staging = nil                         -- the folder under run/net a download is going to, until it is moved or given up
local busy_until = nil                      -- the helper does one request at a time. Set while one is out
local said = {}

local function fail(text, left) error({ said = text, left = left }, 0) end

local function once(key, level, ...)
    if said[key] then return end
    said[key] = true
    log[level](log, ...)
end

local function changed() update.Changed:Fire() end

-- One file operation a frame: every read, write, rename or remove is followed by this.
local function pause() task.wait() end

local function frames(count)
    for _ = 1, count do task.wait() end
end

local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("a")
    file:close()
    return text
end

local function write(path, text)
    local file = io.open(path, "wb")
    if not file then return false end
    file:write(text)
    file:close()
    return true
end

local function size_of(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return size
end

local function shown(value) return (tostring(value):sub(1, 80):gsub("%c", "?")) end

-- "1.10.0-beta.2" as { 1, 10, 0, "beta.2" }, or nil for anything that does not start with three numbers.
local function parse(version)
    if type(version) ~= "string" or #version > 32 or version:find("..", 1, true) then return nil end
    local major, minor, patch, rest = version:match("^(%d+)%.(%d+)%.(%d+)([A-Za-z0-9._+%-]*)$")
    if not major or #major > 6 or #minor > 6 or #patch > 6 then return nil end
    return { tonumber(major), tonumber(minor), tonumber(patch), (rest:gsub("%+.*$", ""):gsub("^[%-.]", "")) }
end

-- True when version a is newer than version b. Numbers are compared as numbers, so 1.10.0 is newer than 1.9.9.
function update.newer(a, b)
    local left, right = parse(a), parse(b)
    if not left or not right then return false end
    for index = 1, 3 do
        if left[index] ~= right[index] then return left[index] > right[index] end
    end
    -- an ending such as -beta.2 marks a version from before the plain one
    if left[4] == right[4] or right[4] == "" then return false end
    if left[4] == "" then return true end
    local ours, theirs = {}, {}
    for part in left[4]:gmatch("[^.%-]+") do ours[#ours + 1] = part end
    for part in right[4]:gmatch("[^.%-]+") do theirs[#theirs + 1] = part end
    for index = 1, math.max(#ours, #theirs) do
        local x, y = ours[index], theirs[index]
        if x == nil or y == nil then return y == nil end
        local nx, ny = x:match("^%d+$") and tonumber(x), y:match("^%d+$") and tonumber(y)
        if nx and ny then
            if nx ~= ny then return nx > ny end
        elseif nx or ny then
            return ny ~= nil
        elseif x ~= y then
            return x > y
        end
    end
    return false
end

-- The version of Wax that is running, from the VERSION file an installed copy has. false in a copy without one.
local function running_wax()
    if wax_version == nil then
        local word = (read(Wax.root .. "/VERSION") or ""):match("^%s*(%S+)")
        wax_version = parse(word) and word or false
        pause()
    end
    return wax_version
end

-- What wax.origin in a mod folder says: { id = , version = }. nil when the folder has none.
local function read_origin(dir)
    local text = read(dir .. "/" .. ORIGIN)
    if not text then return nil end
    local found = {}
    for line in (text:gsub("^\239\187\191", "")):gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*(%a+)%s*=%s*(.-)%s*$")
        if key then found[key] = value end
    end
    return found
end

-- A file path inside a mod: folders and a name with forward slashes, in letters, digits, space, dot, dash and underscore.
local function good_path(path)
    if type(path) ~= "string" or path == "" then return false end
    if path:find("[^A-Za-z0-9 ._/%-]") or path:find("..", 1, true) then return false end
    for name in (path .. "/"):gmatch("([^/]*)/") do
        if name == "" or name:find("^ ") or name:find("[ .]$") then return false end
        if DEVICES[(name:match("^[^.]*"):gsub(" +$", "")):upper()] then return false end
    end
    return true
end

local function encode(text)
    return (text:gsub("[^A-Za-z0-9._%-]", function(char) return ("%%%02X"):format(char:byte()) end))
end

-- Loads the helper on first use. Without it nothing can be downloaded, which is said once.
local function native()
    if helper then return helper end
    local dll = Wax.root .. "/bin/waxnet.dll"
    local ready, why = nil, "this Lua cannot load a library"
    if update.loadlib then ready, why = update.loadlib(dll, "wax_net_ready") end
    local run = ready and update.loadlib(dll, "wax_net_run")
    if not run then
        dead = true
        problem = "The helper that downloads updates is missing, so mods are not updated."
        log:warn("bin/waxnet.dll could not be loaded (%s). Mods are not updated by themselves", shown(why))
        fail(problem)
    end
    helper = { ready = ready, run = run }
    return helper
end

local function send(lib, jobs)
    run_number = (run_number or update.time() % 1000000 * 1000) + 1
    local lines = { "#" .. run_number }
    for _, job in ipairs(jobs) do lines[#lines + 1] = job[1] .. "\t" .. job[2] end
    lib.ready()
    if not write(NET .. "/request.txt", table.concat(lines, "\n") .. "\n") then fail("the request could not be written to run/net") end
    lib.run()
    local give_up = sched.clock() + 180 + 2 * #jobs
    while true do
        frames(POLL_FRAMES)
        local text = read(NET .. "/done")
        if text then
            pause()
            os.remove(NET .. "/done")
            pause()
            if text:match("^#(%d+)") == tostring(run_number) then return end
        end
        if sched.clock() > give_up then fail("no answer came in time", "stuck") end
        -- does nothing while the helper is busy. It starts this request when an older one was still running
        lib.run()
    end
end

-- Hands jobs ({ address, output } each) to the helper and waits until it has done them all. A second caller waits its turn.
local function fetch(jobs)
    -- with looking for updates switched off nothing is asked, and the helper is not even loaded
    if not settings.look then fail("looking for updates is switched off") end
    local lib = native()
    while busy_until and sched.clock() < busy_until do frames(POLL_FRAMES) end
    busy_until = sched.clock() + 200 + 2 * #jobs
    local ok, why = pcall(send, lib, jobs)
    busy_until = nil
    if not ok then error(why, 0) end
end

-- What the helper wrote about one output: the http status (0 when there was none), the size, the checksum, the reason.
local function status_of(output)
    local text = read(NET .. "/" .. output .. ".status")
    if not text then return 0, 0, nil, "no answer" end
    local code, bytes, hash, why = text:match("^(%d+) (%d+) (%S+) ?([^\r\n]*)")
    return tonumber(code) or 0, tonumber(bytes) or 0, hash, why ~= "" and why or "no answer"
end

-- A JSON answer of the catalogue, read from the output it was saved to.
local function answer(output, what)
    local code, _, _, why = status_of(output)
    pause()
    if code ~= 200 then fail(("%s: %s"):format(what, code == 0 and why or ("the catalogue answered " .. code))) end
    local text = read(NET .. "/" .. output)
    pause()
    local ok, value = pcall(json.decode, text or "")
    if not ok or type(value) ~= "table" then fail(what .. ": the answer could not be read") end
    return value
end

-- True when path a comes before path b by its bytes, whatever the locale is.
local function before(a, b)
    for index = 1, math.min(#a, #b) do
        local x, y = a:byte(index), b:byte(index)
        if x ~= y then return x < y end
    end
    return #a < #b
end

-- The text the owner signs for a list of files: the head line, then "<sha256> <size> <path>" for each file in the order of the paths.
local function signed_text(head, files)
    local order, sorted = {}, true
    for index, file in ipairs(files) do
        order[index] = file
        if index > 1 and not before(files[index - 1].path, file.path) then sorted = false end
    end
    if not sorted then table.sort(order, function(a, b) return before(a.path, b.path) end) end
    local lines = { head }
    for index, file in ipairs(order) do lines[index + 1] = ("%s %d %s"):format(file.sha256, file.size, file.path) end
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

-- Has the helper check the owner's signature on a list of files, the list being what was made of the catalogue's answer. Raises unless it is good.
local function check_signed(head, files, signature, output)
    if type(signature) ~= "string" or #signature ~= 88 or not signature:find("^[A-Za-z0-9+/]+==$") then
        fail("the catalogue gives no signature for the list of its files")
    end
    local text = signed_text(head, files)
    -- an answer left from an earlier check must not be taken for this one
    local gone, _, errno = os.remove(NET .. "/" .. output .. ".status")
    pause()
    if not gone and errno ~= 2 then fail("an earlier answer of the helper could not be removed") end
    for name, content in pairs({ [output] = text, [output .. ".sig"] = signature .. "\n" }) do
        if not write(NET .. "/" .. name, content) then fail("the list of its files could not be written to be checked") end
        pause()
    end
    fetch({ { "=", output } })
    local code, bytes, _, why = status_of(output)
    pause()
    os.remove(NET .. "/" .. output .. ".status")
    pause()
    if code ~= 200 then fail("the list of its files is not signed with Wax's key (" .. why .. ")") end
    if bytes ~= #text then fail("the helper checked another list than the one written for it") end
end

-- The mods that are here now, as one text: when it changes, their folders are looked at again.
local function present()
    local names = {}
    for index, entry in ipairs(Wax.mods.list()) do names[index] = entry.id end
    return table.concat(names, "\n")
end

-- Reads which installed mods came from the catalogue, and with which version. Nothing is asked of the network for this.
local function scan()
    local mine, now = {}, present()
    for id in now:gmatch("[^\n]+") do
        local mod = Wax.mods.get(id)
        local origin = mod and read_origin(mod.dir)
        pause()
        if origin and origin.id == id and parse(origin.version) then
            mine[id] = origin.version
        elseif origin then
            once("origin " .. id, "warn", "mods/%s has a wax.origin that names another mod or no version, so it is left alone", id)
        end
    end
    local same = true
    for id, version in pairs(mine) do same = same and origins[id] == version end
    for id in pairs(origins) do same = same and mine[id] ~= nil end
    origins, roster = mine, now
    if not same then changed() end
    return mine
end

-- Whether a mod is updated by itself: its own switch, else what the one switch for all mods said before each had one.
local function auto_for(id)
    local own = settings.mods[id]
    if own == nil then return settings.auto end
    return own
end

-- Finds out which installed mods the catalogue has a newer version of.
local function compare()
    local mine = scan()
    if next(mine) == nil then
        available = {}
        return
    end
    fetch({ { "/api/versions", "versions.json" } })
    local listed = answer("versions.json", "the list of versions").mods
    if type(listed) ~= "table" then fail("the list of versions: the answer could not be read") end
    local found = {}
    for id, have in pairs(mine) do
        local entry = listed[id]
        local version = type(entry) == "table" and entry.version
        if update.newer(version, have) then
            local needs, running = entry.wax, running_wax()
            if type(needs) == "string" and running and update.newer(needs, running) then
                once("wax " .. id .. " " .. version, "info", "%s %s needs Wax %s or newer and this is Wax %s, so it was not updated",
                    id, version, shown(needs), running)
            else
                found[id] = version
            end
        end
    end
    available = found
end

-- The files of a version as the catalogue lists them. Raises with the reason when the list cannot be used as it is.
local function read_plan(plan, id, version)
    if plan.id ~= id or plan.version ~= version then fail("the catalogue answered for another mod or version") end
    local files = plan.files
    if type(files) ~= "table" or #files == 0 then fail("the catalogue listed no files") end
    if #files > MAX_FILES then fail(("it has more than %d files"):format(MAX_FILES)) end
    local seen, total, out = {}, 0, {}
    for index = 1, #files do
        local file = files[index]
        local path = type(file) == "table" and file.path
        if not good_path(path) then fail("it holds a path that is not allowed: " .. shown(path)) end
        local name = path:match("[^/]*$"):lower()
        if name == ORIGIN or name == MARK then fail("it holds a file under a name that is Wax's own: " .. path) end
        if not KINDS[(path:match("%.([A-Za-z0-9]+)$") or ""):lower()] then fail("it holds a kind of file that is not allowed: " .. path) end
        if 7 + #id + #path > MAX_OUTPUT or #NET + #id + #path + 16 > MAX_FULL_PATH then fail("it holds a path that is too long: " .. path) end
        if seen[path:lower()] then fail("it lists the same file twice: " .. path) end
        seen[path:lower()] = true
        local size, hash = file.size, file.sha256
        if math.type(size) ~= "integer" or size < 0 then fail("it gives no size for " .. path) end
        if type(hash) ~= "string" or #hash ~= 64 or hash:find("%X") then fail("it gives no checksum for " .. path) end
        total = total + size
        out[index] = { path = path, size = size, sha256 = hash:lower() }
    end
    if total > MAX_BYTES then fail("it is larger than 20 MB") end
    if plan.total ~= nil and plan.total ~= total then fail("its sizes do not add up") end
    for _, file in ipairs(out) do
        if file.path == "init.lua" then return out end
    end
    fail("it has no init.lua")
end

-- The mod, while its folder still says it came from the catalogue and holds an older version than the one offered.
local function still_ours(id, version)
    local mod = Wax.mods.get(id)
    local origin = mod and read_origin(mod.dir)
    pause()
    return origin and origin.id == id and update.newer(version, origin.version) and mod or nil
end

-- A downloaded file has to be there in full, and a Lua file has to compile.
local function check_file(path, file)
    if not file.path:lower():find("%.lua$") then
        if size_of(path) ~= file.size then fail(file.path .. " is missing or cut short") end
        return
    end
    local text = read(path)
    if not text or #text ~= file.size then fail(file.path .. " is missing or cut short") end
    local chunk, why = load((text:gsub("^\239\187\191", "")), "=" .. file.path, "t")
    if not chunk then fail(("%s does not compile (%s)"):format(file.path, shown(why))) end
end

-- Every file under a folder of run/net, as UE4SS lists the game's folders: { ["sub/name"] = true }. nil when it cannot say.
local function files_under(folder)
    local list = rawget(_G, "IterateGameDirectories")
    if type(list) ~= "function" then return nil end
    local names, start = {}, nil
    for part in (NET .. "/" .. folder):gmatch("[^/\\]+") do
        if part == ".." then names[#names] = nil elseif part ~= "." then names[#names + 1] = part end
    end
    for index = #names, 1, -1 do
        if names[index] == "Binaries" then
            start = index
            break
        end
    end
    local found = {}
    local function collect(node, prefix)
        local here = node.__files
        for index = 1, here and #here or 0 do found[prefix .. here[index].__name] = true end
        for name, child in pairs(node) do
            if type(name) == "string" and type(child) == "table" and name:sub(1, 2) ~= "__" then collect(child, prefix .. name .. "/") end
        end
    end
    local ok = start and pcall(function()
        local node = list().Game
        for index = start, #names do node = node[names[index]] end
        collect(node, "")
    end)
    return ok and found or nil
end

local function notify(text)
    local ui = Wax.ui
    if ui and ui.Notify then pcall(ui.Notify, text, { title = "Mods", kind = "good", seconds = 8 }) end
end

-- Puts the staged folder where the mod is. The two renames happen in one frame, so the loader never sees the mod missing.
local function swap(id, mod, version)
    local dir, name = mod.dir, mod.manifest and mod.manifest.name or id
    local parent = dir:match("^(.*)/[^/]+$")
    if not parent then fail("its folder could not be worked out") end
    local dependents = {}
    for _, entry in ipairs(Wax.mods.list()) do
        local other = Wax.mods.get(entry.id)
        if other and other.depends and other.depends[id] then dependents[#dependents + 1] = entry.id end
    end
    -- the player has seen this mod: its next version is not a new mod
    local kept, why = Wax.mods.remove(id, true)
    if not kept then fail(tostring(why)) end
    local moved, reason = os.rename(NET .. "/stage/" .. id, dir)
    if not moved then
        local back = os.rename(parent .. "/" .. kept, dir)
        Wax.mods.request_sync()
        fail(("the new files could not be moved into the mods folder (%s)"):format(shown(reason)),
            back and "The version before was put back" or ("The version before is in mods/" .. kept .. ". Rename it to " .. id .. " to get it back"))
    end
    Wax.mods.request_sync()
    for _, other in ipairs(dependents) do Wax.mods.request_reload(other) end
    available[id], origins[id] = nil, version
    log:info("%s was updated to %s. The version before is kept as mods/%s", id, version, kept)
    notify(("%s was updated to %s."):format(name, version))
end

-- Downloads a version next to the game's files, checks all of it, and only then changes the mods folder.
local function bring(id, version)
    if #id > 64 or not id:match("^[A-Za-z][A-Za-z0-9_]*$") then fail("its name cannot be asked for") end
    if not still_ours(id, version) then
        available[id] = nil
        return
    end
    local base = ("/api/mods/%s/files/%s"):format(id, encode(version))
    local listing, stage = "plan/" .. id .. ".json", "stage/" .. id
    fetch({ { base .. "?update=1", listing } })
    local plan = answer(listing, "the list of its files")
    local files = read_plan(plan, id, version)
    -- every file below is checked against this list, so nothing is fetched before the list is known to be the owner's
    check_signed(("mod %s %s"):format(id, version), files, plan.signature, "plan/" .. id .. ".list")
    local jobs = { { "-", stage } }
    for index, file in ipairs(files) do
        jobs[index + 1] = { base .. "/" .. file.path:gsub("[^/]+", encode), stage .. "/" .. file.path }
    end
    staging = stage
    fetch(jobs)

    local cleared = status_of(stage)
    pause()
    if cleared ~= 200 then fail("the folder the download goes to could not be emptied") end
    os.remove(NET .. "/" .. stage .. ".status")
    pause()
    for _, file in ipairs(files) do
        local output = stage .. "/" .. file.path
        local code, bytes, hash, why = status_of(output)
        pause()
        if code ~= 200 then
            fail(("%s was not downloaded (%s)"):format(file.path, code == 0 and why or ("the catalogue answered " .. code)))
        end
        if bytes ~= file.size or hash ~= file.sha256 then fail(file.path .. " does not match its checksum") end
        if not os.remove(NET .. "/" .. output .. ".status") then fail("the download could not be tidied") end
        pause()
        check_file(NET .. "/" .. output, file)
        pause()
    end
    -- nothing but the listed files may be in the folder that becomes the mod
    local expected = {}
    for _, file in ipairs(files) do expected[file.path] = true end
    for name in pairs(files_under(stage) or {}) do
        if not expected[name] then fail("the download holds a file the catalogue does not list: " .. shown(name)) end
    end
    pause()
    if not write(NET .. "/" .. stage .. "/" .. ORIGIN, ("id=%s\nversion=%s\n"):format(id, version)) then
        fail("the download could not be marked as coming from the catalogue")
    end
    pause()
    local mod = still_ours(id, version)
    if not mod then
        available[id] = nil
        fail("its folder was changed while the update was downloaded")
    end
    -- a copy the player has not switched on yet keeps its mark, so an update never switches anything on
    local marked = read(mod.dir .. "/" .. MARK) ~= nil
    pause()
    if marked then
        if not write(NET .. "/" .. stage .. "/" .. MARK, "new\n") then fail("the download could not be marked as a mod that is still new") end
        pause()
    end
    if not settings.look then fail("looking for updates was switched off while it was downloaded") end
    swap(id, mod, version)
    staging = nil
end

local function attempt(fn, ...)
    local ok, why = pcall(fn, ...)
    if ok then return true end
    if type(why) == "table" then return false, tostring(why.said), why.left end
    return false, tostring(why)
end

-- how: "auto" when the mod's switch asked for it, "asked" when the player pressed its button.
local function enqueue(id, how)
    if queued[id] or not available[id] then return end
    queued[id] = how
    queue[#queue + 1] = id
end

-- Every newer version whose mod has its switch on is put in. One that waits because of a switch that is now off waits no more.
local function follow_switches()
    for id in pairs(available) do
        if auto_for(id) then
            enqueue(id, "auto")
        elseif queued[id] == "auto" then
            for index = #queue, 1, -1 do
                if queue[index] == id then
                    table.remove(queue, index)
                    queued[id] = nil
                end
            end
        end
    end
end

local function look()
    checking = true
    changed()
    local ok, why = attempt(compare)
    checking = false
    if ok then
        problem = nil
        settings.last = update.time()
        storage.save("wax", "updates", settings)
        follow_switches()
    elseif not dead then
        problem = "Updates could not be checked."
        once("check " .. why, "warn", "could not check for updates: %s", why)
    end
    changed()
end

local function install(id)
    local version, mod = available[id], Wax.mods.get(id)
    local name = mod and mod.manifest and mod.manifest.name or id
    local ok, why, left = true, nil, nil
    if version then ok, why, left = attempt(bring, id, version) end
    if ok then
        problem = nil
    elseif not dead then
        -- stopped by the player's own switch, it is said in the log and not shown as something that went wrong
        if settings.look then problem = ("%s could not be updated."):format(name) end
        once("install " .. id .. " " .. version, "warn", "%s could not be updated to %s: %s. %s", id, version, why,
            left ~= "stuck" and left or "The installed version stays as it is")
        -- what was downloaded is not left lying about
        pause()
        if staging and left ~= "stuck" and attempt(fetch, { { "-", staging } }) then
            os.remove(NET .. "/" .. staging .. ".status")
            pause()
        end
    end
    staging = nil
    queued[id] = nil
    changed()
end

local function loop()
    local due = sched.clock() + FIRST_SECONDS
    while not dead do
        task.wait(1)
        -- which mods came from the catalogue is read from their folders when the list of mods changes
        if present() ~= roster then scan() end
        local now = sched.clock()
        if settings.look and (wanted or now >= due) then
            wanted, due, asked_at = false, now + EVERY_SECONDS, now
            look()
        end
        while settings.look and queue[1] and not dead do install(table.remove(queue, 1)) end
    end
end

-- What the Mods page shows. mods: each mod from the catalogue as { version, auto }. last: os.time of the last check. stopped: no helper.
function update.state()
    local found, busy, mods = {}, {}, {}
    for id, version in pairs(available) do found[id] = version end
    for id in pairs(queued) do busy[id] = true end
    for id, version in pairs(origins) do mods[id] = { version = version, auto = auto_for(id) } end
    return { available = found, installing = busy, mods = mods, checking = checking, last = settings.last, look = settings.look,
        auto = settings.auto, problem = problem, stopped = dead }
end

-- Whether the catalogue is asked at all, for mods and for Wax itself. Switched off, no request is made and the helper is not loaded.
function update.set_looking(on)
    settings.look = on and true or false
    storage.save("wax", "updates", settings)
    if settings.look then
        wanted = true
    else
        available, queue, queued, problem = {}, {}, {}, nil
    end
    changed()
end

-- Whether one mod is updated by itself. Off, its newer version is only offered. With no id: for mods whose switch was never set, and for Wax.
function update.set_auto(id, on)
    if type(id) == "string" then
        settings.mods[id] = on and true or false
    else
        settings.auto = id and true or false
    end
    storage.save("wax", "updates", settings)
    follow_switches()
    changed()
end

-- Asks the catalogue soon. Not more often than once a minute: then it returns false and the seconds left to wait.
function update.check_now()
    if dead or not worker or not settings.look then return false end
    if wanted or checking then return true end
    local since = asked_at and sched.clock() - asked_at
    if since and since < GAP_SECONDS then return false, math.ceil(GAP_SECONDS - since) end
    wanted = true
    return true
end

-- Puts in the newer version that is known for this mod. Returns false when none is.
function update.install(id)
    if dead or not worker or not settings.look or not available[id] then return false end
    enqueue(id, "asked")
    changed()
    return true
end

function update.start()
    if worker then return end
    settings = storage.load("wax", "updates", settings)
    settings.look = settings.look ~= false
    settings.auto = settings.auto ~= false
    settings.last = tonumber(settings.last) or 0
    local switches = {}
    for id, on in pairs(type(settings.mods) == "table" and settings.mods or {}) do
        if type(id) == "string" and type(on) == "boolean" then switches[id] = on end
    end
    settings.mods = switches
    local previous = scope.enter(nil)
    worker = task.label(task.spawn(function()
        while not dead do
            local ok, why = pcall(loop)
            if not ok then
                once("loop " .. tostring(why), "error", "the check for updates stopped and starts again: %s", tostring(why))
                task.wait(GAP_SECONDS)
            end
        end
    end), "mod updates")
    scope.leave(previous)
end

function update.stop()
    if worker then task.cancel(worker) end
    worker = nil
end

-- What mods.selfupdate uses to bring Wax's own files the same way.
update.shared = { net = NET, fail = fail, pause = pause, read = read, write = write, size_of = size_of, shown = shown, parse = parse,
    good_path = good_path, encode = encode, fetch = fetch, status_of = status_of, answer = answer, check_file = check_file,
    check_signed = check_signed, files_under = files_under, attempt = attempt, stopped = function() return dead end,
    looking = function() return settings.look end, auto = function() return settings.auto end,
    read_plan = read_plan, origin = ORIGIN, mark = MARK }

return update
