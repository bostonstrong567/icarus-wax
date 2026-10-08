-- Brings a newer Wax next to the running one. Scripts/selfswap.lua puts it in at the next start of the game. Nothing here changes what is running

local Wax = ...
local log = Wax.import("core.log").channel("wax.selfupdate")
local scope = Wax.import("core.scope")
local sched = Wax.import("core.sched")
local storage = Wax.import("core.storage")
local update = Wax.import("mods.update")

local task = sched.task
local net = update.shared
local selfupdate = {}

local FIRST_SECONDS, EVERY_SECONDS, GAP_SECONDS = 30, 6 * 3600, 60
local SETTLE_FRAMES = 120                   -- whole frames after which a version put in at this start counts as working
local MAX_FILES, MAX_BYTES = 6000, 64 * 1024 * 1024
local BATCH_FILES, BATCH_BYTES = 400, 24 * 1024 * 1024
local MAX_OUTPUT, MAX_FULL_PATH = 220, 255
local MAX_TRIES = 2                         -- the same number as in selfswap.lua
local NET = net.net
local READY, TRIAL, BAD, OLD = "wax-ready.txt", "wax-trial.txt", "wax-bad.txt", "wax-old.txt"
local TOPS = { "Scripts", "data", "assets", "bin", "Wax-Import.ps1", "VERSION" }
local NEEDED = { "VERSION", "Scripts/main.lua", "Scripts/selfswap.lua", "Scripts/wax/boot.lua", "Scripts/wax/loader.lua",
    "Scripts/wax/mods/update.lua", "Scripts/wax/mods/selfupdate.lua", "bin/waxco.dll", "bin/waxnet.dll" }
local KINDS = { Scripts = "lua", data = "lua json txt csv", assets = "png jpg jpeg webp txt json ogg wav", bin = "dll" }
local FILES = { VERSION = true, ["Wax-Import.ps1"] = true }
for folder, kinds in pairs(KINDS) do
    local set = {}
    for kind in kinds:gmatch("%a+") do set[kind] = true end
    KINDS[folder] = set
end

selfupdate.Changed = sched.Signal.new("selfupdate")    -- fired whenever selfupdate.state() would answer differently

local settings = { auto = true, last = 0, told = "", said = "" }
local running, off = nil, nil               -- the version that runs, and why nothing is done here ("dev", "no version")
local ready, installer = nil, nil           -- the version that waits for the next start, and one only the installer can put in
local checking, problem, wanted, asked_at = false, nil, false, nil
local worker, settled = nil, 0
local staging = nil                         -- the folder under run/net a download is going to, until it is marked or given up
local bad = nil                             -- what selfswap.lua remembers about a version that did not work here, read once
local said, is_top = {}, {}
for _, name in ipairs(TOPS) do is_top[name] = true end

local fail, pause, attempt = net.fail, net.pause, net.attempt
local was_fetching = false

-- Whether a newer Wax is fetched by itself: its own stored value (on unless switched off), and the Mods page's "Look for updates".
local function fetches() return settings.auto and net.looking() end

-- Like attempt, and hands back what the function returned.
local function try(fn, ...)
    local result = table.pack(pcall(fn, ...))
    if result[1] then return true, result[2] end
    return false
end

local function once(key, level, ...)
    if said[key] then return end
    said[key] = true
    log[level](log, ...)
end

local function changed() selfupdate.Changed:Fire() end

local function save() storage.save("wax", "selfupdate", settings) end

local function notify(text, kind)
    local ui = Wax.ui
    if ui and ui.Notify then pcall(ui.Notify, text, { title = "Wax", kind = kind or "info", seconds = 12 }) end
end

-- Three numbers and nothing else, which is how every version of Wax is written.
local function plain(version)
    local parts = net.parse(version)
    return parts ~= nil and parts[4] == "" and not version:find("+", 1, true)
end

local function fields(text)
    local found = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^(%a+)=(.*)$")
        if key and found[key] == nil then found[key] = value end
    end
    return found
end

-- The part of the runtime a path belongs to, or nil when it is not a place Wax's own files may be.
local function top_of(path)
    if not net.good_path(path) then return nil end
    if FILES[path] then return path end
    local folder, name = path:match("^([^/]+)/.-([^/]+)$")
    local kinds = folder and KINDS[folder]
    if not kinds or not kinds[(name:match("%.([A-Za-z0-9]+)$") or ""):lower()] then return nil end
    return folder
end

-- The files of a version as the catalogue lists them: { path, size, sha256, top } each. Raises when the list cannot be used as it is.
local function read_plan(plan, version, whole)
    if plan.version ~= version then fail("the catalogue answered for another version") end
    local files = plan.files
    if type(files) ~= "table" or #files == 0 then fail("the catalogue listed no files") end
    if #files > MAX_FILES then fail(("it has more than %d files"):format(MAX_FILES)) end
    local stage = "stage/wax-" .. version
    local seen, total, out = {}, 0, {}
    for index = 1, #files do
        local file = files[index]
        local path = type(file) == "table" and file.path
        local top = top_of(path)
        if not top then fail("it holds a file that is not part of Wax: " .. net.shown(path)) end
        if #stage + 1 + #path > MAX_OUTPUT or #NET + #stage + #path + 16 > MAX_FULL_PATH then fail("it holds a path that is too long: " .. path) end
        if seen[path:lower()] then fail("it lists the same file twice: " .. path) end
        seen[path:lower()] = true
        local size, hash = file.size, file.sha256
        if math.type(size) ~= "integer" or size < 0 then fail("it gives no size for " .. path) end
        if type(hash) ~= "string" or #hash ~= 64 or hash:find("%X") then fail("it gives no checksum for " .. path) end
        total = total + size
        out[index] = { path = path, size = size, sha256 = hash:lower(), top = top }
    end
    if total > MAX_BYTES then fail("it is larger than 64 MB") end
    if plan.total ~= nil and plan.total ~= total then fail("its sizes do not add up") end
    if whole then
        for _, needed in ipairs(NEEDED) do
            if not seen[needed:lower()] then fail("it has no " .. needed) end
        end
    end
    return out
end

-- The owner's signature on the files of a version of Wax, over the text that starts "wax <version>". Raises unless it is good.
local function check_signed(version, files, signature, output)
    net.check_signed("wax " .. version, files, signature, output)
end

-- A JSON answer of the catalogue, or nil when it says there is no such thing.
local function ask(address, output, what)
    net.fetch({ { address, output } })
    local code = net.status_of(output)
    pause()
    if code == 404 then return nil end
    return net.answer(output, what)
end

-- What the catalogue offers: { version, installer } when it is newer than what runs, or nil.
local function newest()
    local answer = ask("/api/wax", "wax-newest.json", "the newest version of Wax")
    if not answer then return nil end
    local version = answer.version
    if type(version) ~= "string" or not plain(version) then fail("the newest version of Wax: the answer could not be read") end
    if not update.newer(version, running) then return nil end
    local from = answer.installer_from
    local needs = answer.needs_installer == true or (type(from) == "string" and plain(from) and update.newer(from, running))
    return { version = version, installer = needs and true or false }
end

-- Which parts hold the same files in both lists: { [part] = true or false }.
local function unchanged(running_files, files)
    local old = {}
    for _, file in ipairs(running_files) do old[file.path] = file.size .. " " .. file.sha256 end
    local same, counts = {}, {}
    for _, name in ipairs(TOPS) do same[name], counts[name] = true, 0 end
    for _, file in ipairs(files) do
        counts[file.top] = counts[file.top] + 1
        if old[file.path] ~= file.size .. " " .. file.sha256 then same[file.top] = false end
    end
    for _, file in ipairs(running_files) do counts[file.top] = counts[file.top] - 1 end
    for _, name in ipairs(TOPS) do
        if counts[name] ~= 0 then same[name] = false end
    end
    return same
end

-- The parts to download. One that both signed lists give the same stays, once every file of it is found here at the listed size.
local function parts_to_bring(files, version)
    local all = {}
    for _, file in ipairs(files) do all[file.top] = true end
    local listed, plan = try(ask, "/api/wax/files/" .. running, "plan/wax-running.json", "the files of the running version")
    local known, running_files = false, nil
    if listed and plan then known, running_files = try(read_plan, plan, running, false) end
    -- an unsigned list of the running version could name a changed part as unchanged, so it is not believed
    if known then known = try(check_signed, running, running_files, plan.signature, "plan/wax-running.list") end
    if not known then return all end
    local same = unchanged(running_files, files)
    for _, file in ipairs(files) do
        if same[file.top] then
            if net.size_of(Wax.root .. "/" .. file.path) ~= file.size then same[file.top] = false end
            pause()
        end
    end
    for name in pairs(all) do
        if same[name] then all[name] = nil end
    end
    if not all.VERSION then fail("the catalogue lists the same VERSION file for " .. version .. " as for the running version") end
    return all
end

-- Has the helper empty a folder under run/net/stage. True when it is gone.
local function clear(folder)
    if not attempt(net.fetch, { { "-", folder } }) then return false end
    local code = net.status_of(folder)
    pause()
    os.remove(NET .. "/" .. folder .. ".status")
    pause()
    return code == 200
end

-- The version a marker names and the folder it uses, or nil when there is no marker.
local function waiting()
    local file = io.open(NET .. "/" .. READY, "rb")
    if not file then return nil end
    local head = file:read(400) or ""
    file:close()
    local found = fields(head)
    return found.version or "", found.folder
end

local function drop_marker(why)
    local version = waiting()
    pause()
    if not version then return end
    os.remove(NET .. "/" .. READY)
    pause()
    ready = nil
    if plain(version) then clear("stage/wax-" .. version) end
    log:info("the Wax update that was waiting is not put in: %s", why)
end

-- Fetches the files of one batch and checks each against the list.
local function bring_batch(jobs, batch, stage)
    net.fetch(jobs)
    for _, file in ipairs(batch) do
        local output = stage .. "/" .. file.path
        local code, bytes, hash, why = net.status_of(output)
        pause()
        if code ~= 200 then
            fail(("%s was not downloaded (%s)"):format(file.path, code == 0 and why or ("the catalogue answered " .. code)))
        end
        if bytes ~= file.size or hash ~= file.sha256 then fail(file.path .. " does not match its checksum") end
        if not os.remove(NET .. "/" .. output .. ".status") then fail("the download could not be tidied") end
        pause()
        net.check_file(NET .. "/" .. output, file)
        pause()
    end
end

-- Downloads a version beside the running one, checks all of it, and only then writes the marker that the next start acts on.
local function bring(version)
    local base, stage = "/api/wax/files/" .. version, "stage/wax-" .. version
    local plan = ask(base .. "?update=1", "plan/wax-own.json", "the list of its files")
    if not plan then fail("the catalogue no longer lists its files") end
    local files = read_plan(plan, version, true)
    -- every file below is checked against this list, so nothing is fetched before the list is known to be the owner's
    check_signed(version, files, plan.signature, "plan/wax-own.list")
    local parts = parts_to_bring(files, version)

    staging = stage
    if not clear(stage) then fail("the folder the download goes to could not be emptied") end
    local wanted_files, jobs, batch, bytes = {}, {}, {}, 0
    local function flush()
        if #jobs == 0 then return end
        bring_batch(jobs, batch, stage)
        jobs, batch, bytes = {}, {}, 0
    end
    for _, file in ipairs(files) do
        if parts[file.top] then
            if #batch >= BATCH_FILES or bytes + file.size > BATCH_BYTES then flush() end
            jobs[#jobs + 1] = { base .. "/" .. file.path:gsub("[^/]+", net.encode), stage .. "/" .. file.path }
            batch[#batch + 1] = file
            bytes = bytes + file.size
            wanted_files[#wanted_files + 1] = file
        end
    end
    flush()

    -- nothing but the listed files may be in the folders that become Wax's own
    local expected = {}
    for _, file in ipairs(wanted_files) do expected[file.path] = true end
    for name in pairs(net.files_under(stage) or {}) do
        if not expected[name] then fail("the download holds a file the catalogue does not list: " .. net.shown(name)) end
    end
    pause()
    if (net.read(NET .. "/" .. stage .. "/VERSION") or ""):match("^%s*(%S+)") ~= version then fail("its VERSION file says another version") end
    pause()
    if parts.Scripts and not (net.read(NET .. "/" .. stage .. "/Scripts/main.lua") or ""):find("selfswap.lua", 1, true) then
        fail("its main.lua does not run selfswap.lua, so it could not be taken back")
    end
    pause()

    -- the catalogue is asked once more, so a version that was withdrawn meanwhile is not put in
    local still = newest()
    if not still or still.version ~= version or still.installer then fail("the catalogue stopped offering it while it was downloaded") end
    if not fetches() then fail("updates of Wax were switched off while it was downloaded") end
    if net.read(Wax.root .. "/dev.txt") then fail("dev.txt appeared, so this copy is left alone") end
    pause()
    if (net.read(Wax.root .. "/VERSION") or ""):match("^%s*(%S+)") ~= running then fail("the installed version changed while it was downloaded") end
    pause()

    local lines = { "wax-ready 1", "version=" .. version, "from=" .. running, "folder=" .. stage, "files=" .. #wanted_files }
    for _, name in ipairs(TOPS) do
        if parts[name] then lines[#lines + 1] = "top=" .. name end
    end
    for _, file in ipairs(wanted_files) do lines[#lines + 1] = ("file=%d %s"):format(file.size, file.path) end
    lines[#lines + 1] = "end"
    if not net.write(NET .. "/" .. READY .. ".part", table.concat(lines, "\n") .. "\n") then fail("the marker could not be written") end
    pause()
    os.remove(NET .. "/" .. READY)
    pause()
    if not os.rename(NET .. "/" .. READY .. ".part", NET .. "/" .. READY) then fail("the marker could not be written") end
    pause()
    ready, staging = version, nil
    log:info("Wax %s is downloaded and checked (%d files). It is put in at the next start of the game", version, #wanted_files)
    notify(("Wax %s is ready. It is put in the next time you start ICARUS."):format(version), "good")
end

-- Deletes what selfswap.lua left for later: older sets of folders, and download folders that are used up.
local function tidy()
    local text = net.read(NET .. "/" .. OLD)
    pause()
    if not text then return end
    local _, in_use = waiting()
    pause()
    local number, left = 0, {}
    for line in text:gmatch("[^\r\n]+") do
        local kind, name = line:match("^(%a+) (.+)$")
        local done = true
        if kind == "stage" and name:match("^wax%-%d+%.%d+%.%d+$") then
            if "stage/" .. name ~= in_use then done = clear("stage/" .. name) end
        elseif kind == "root" then
            local top, what = name:match("^(.-)%.(%a+)%-%d+%.%d+%.%d+$")
            if is_top[top] and (what == "before" or what == "failed") then
                local path = Wax.root .. "/" .. name
                local gone = os.remove(path)
                pause()
                if not gone then
                    -- a folder: the helper deletes it on its own thread once it is under run/net/stage
                    number = number + 1
                    local folder = ("stage/old-%d-%d"):format(update.time() % 100000000, number)
                    done = clear(folder)
                    if done and os.rename(path, NET .. "/" .. folder) then
                        pause()
                        done = clear(folder)
                    end
                end
            end
        end
        if not done then left[#left + 1] = line end
    end
    if #left == 0 then
        os.remove(NET .. "/" .. OLD)
    else
        net.write(NET .. "/" .. OLD, table.concat(left, "\n") .. "\n")
    end
    pause()
end

-- Says once what the start of the game did with a version that was waiting.
local function report()
    bad = fields(net.read(NET .. "/" .. BAD))
    pause()
    if plain(bad.version or "") then
        if bad.why == "start" and settings.told ~= bad.version then
            settings.told = bad.version
            save()
            log:warn("Wax %s did not start here, so the version before was put back. It is not tried again", bad.version)
            notify(("Wax %s did not start here, so the version before was put back."):format(bad.version), "warn")
        elseif bad.why == "move" and (tonumber(bad.tries) or 0) >= MAX_TRIES and settings.said ~= bad.version and update.newer(bad.version, running) then
            settings.said = bad.version
            save()
            installer = bad.version
            log:warn("Wax %s could not be put in here, because its folders could not be moved. Update Wax.cmd can", bad.version)
            notify(("Wax %s is out. Run Update Wax.cmd to get it."):format(bad.version), "info")
        end
    end
    local applied = fields(net.read(NET .. "/wax-applied.txt"))
    pause()
    if applied.version == running and settings.applied ~= running then
        settings.applied = running
        save()
        log:info("Wax was updated from %s to %s at the start of the game", tostring(applied.from), running)
    end
end

local function check()
    if not bad then report() end
    tidy()
    if not fetches() then return end

    local offer = newest()
    local staged = waiting()
    pause()
    if staged and (not offer or offer.version ~= staged or offer.installer) then
        drop_marker("the catalogue no longer offers that version")
        staged = nil
    end
    ready, installer = staged, nil
    if not offer or staged then return end
    if plain(bad.version or "") and not update.newer(offer.version, bad.version) then
        if bad.why == "move" then installer = bad.version end
        return
    end
    if offer.installer then
        installer = offer.version
        if settings.said ~= offer.version then
            settings.said = offer.version
            save()
            log:info("Wax %s is out, and it needs the installer: run Update Wax.cmd", offer.version)
            notify(("Wax %s is out. Run Update Wax.cmd to get it."):format(offer.version), "info")
        end
        return
    end
    local ok, why, left = attempt(bring, offer.version)
    if ok then return end
    if not net.stopped() then
        once("bring " .. offer.version .. " " .. tostring(why), "warn", "Wax %s could not be downloaded: %s. The installed version stays as it is",
            offer.version, tostring(why))
        -- what was downloaded is not left lying about
        if staging and left ~= "stuck" then clear(staging) end
    end
    staging = nil
    error({ said = "Wax could not be updated." }, 0)
end

local function look()
    if not net.looking() then
        -- nothing is asked and the helper is left alone. What the start of the game did is still said, from the files it left
        if not bad then attempt(report) end
        return
    end
    checking = true
    changed()
    local ok, why = attempt(check)
    checking = false
    if ok then
        problem = nil
        settings.last = update.time()
        save()
    elseif not net.stopped() then
        if why == "Wax could not be updated." then
            problem = why
        else
            problem = "Updates of Wax could not be checked."
            once("check " .. tostring(why), "warn", "could not check for a newer Wax: %s", tostring(why))
        end
    end
    changed()
end

local function loop()
    local due = sched.clock() + FIRST_SECONDS
    while not net.stopped() do
        task.wait(1)
        local now = sched.clock()
        if wanted or now >= due then
            wanted, due, asked_at = false, now + EVERY_SECONDS, now
            look()
        end
    end
end

-- What a settings page shows. off is why this copy is never updated ("dev", "no version"), ready the version that waits, installer one for Update Wax.cmd.
function selfupdate.state()
    return { running = running or nil, off = off, auto = settings.auto, checking = checking, last = settings.last, ready = ready,
        installer = installer, problem = problem, stopped = net.stopped() }
end

-- Switched on, the catalogue is asked soon. Switched off, a version that waits is not put in.
local function switched(on)
    was_fetching = on
    if on then
        wanted = true
    elseif os.remove(NET .. "/" .. READY) then
        ready = nil
        log:info("the Wax update that was waiting is not put in: updates of Wax were switched off")
    end
    changed()
end

-- "Look for updates" is the mod updater's switch. This follows it whenever that updater says something changed.
local function follow()
    if fetches() ~= was_fetching then switched(fetches()) end
end

-- Whether a newer Wax is downloaded by itself: Wax's own value, kept in saved/wax.selfupdate.lua, apart from every mod's Auto Update.
-- Switched off, nothing is asked of the catalogue about Wax and a version that waits is not put in.
function selfupdate.set_auto(on)
    settings.auto = on and true or false
    save()
    if off then return end
    switched(fetches())
end

-- Asks the catalogue soon. Not more often than once a minute: then it returns false and the seconds left to wait.
function selfupdate.check_now()
    if off or not worker or net.stopped() or not fetches() then return false end
    if wanted or checking then return true end
    local since = asked_at and sched.clock() - asked_at
    if since and since < GAP_SECONDS then return false, math.ceil(GAP_SECONDS - since) end
    wanted = true
    return true
end

-- Called by boot at the end of every frame until it answers false. After enough whole frames the version put in at this start is kept.
function selfupdate.settle()
    if off then return false end
    settled = settled + 1
    if settled < SETTLE_FRAMES then return true end
    os.remove(NET .. "/" .. TRIAL)
    return false
end

function selfupdate.start()
    if worker or off then return end
    local word = (net.read(Wax.root .. "/VERSION") or ""):match("^%s*(%S+)")
    running = word and plain(word) and word or false
    if not running then
        off = "no version"
    elseif net.read(Wax.root .. "/dev.txt") then
        off = "dev"
    end
    if off then return end
    settings = storage.load("wax", "selfupdate", settings)
    settings.auto = settings.auto ~= false
    settings.last = tonumber(settings.last) or 0
    was_fetching = fetches()
    local previous = scope.enter(nil)
    update.Changed:Connect(follow)
    worker = task.label(task.spawn(function()
        while not net.stopped() do
            local ok, why = pcall(loop)
            if not ok then
                once("loop " .. tostring(why), "error", "the check for a newer Wax stopped and starts again: %s", tostring(why))
                task.wait(GAP_SECONDS)
            end
        end
    end), "wax updates")
    scope.leave(previous)
end

function selfupdate.stop()
    if worker then task.cancel(worker) end
    worker = nil
end

return selfupdate
