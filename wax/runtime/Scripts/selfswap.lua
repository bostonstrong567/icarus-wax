-- Runs before Wax starts: puts in a version of Wax that was downloaded while the game ran, or takes one back that did not start

local options = ... or {}
if not options.root and (rawget(_G, "WaxStage0") or rawget(_G, "Wax")) then return { did = "running" } end

local TOPS = { "Scripts", "data", "assets", "bin", "Wax-Import.ps1", "VERSION" }    -- VERSION goes last
local MAX_TRIES = 2         -- how often a version is tried when its folders cannot be moved
local MAX_RETURNS = 3       -- how often taking a version back is tried

local rename = options.rename or os.rename
local say = options.print or print
local clock = options.time or os.time

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local scripts = source:match("^(.*)[/\\][^/\\]*$") or "ue4ss\\Mods\\Wax\\Scripts"
local root = options.root or scripts:match("^(.*)[/\\][Ss]cripts$")
if not root then return { did = "nothing", why = "not in a Scripts folder" } end
local net = root .. "/run/net"

local known = {}
for order, name in ipairs(TOPS) do known[name] = order end

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

-- True for a file or a folder that is there. Renaming a thing to its own name changes nothing.
local function exists(path)
    local ok, _, code = os.rename(path, path)
    return ok and true or (code ~= nil and code ~= 2)
end

local function triple(version)
    if type(version) ~= "string" or #version > 20 then return nil end
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
    if not major then return nil end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function newer(a, b)
    local left, right = triple(a), triple(b)
    if not left or not right then return false end
    for index = 1, 3 do
        if left[index] ~= right[index] then return left[index] > right[index] end
    end
    return false
end

-- "key=value" lines as a table. A key that comes more than once is in lists[key] in order.
local function fields(text)
    local found, lists = {}, {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^(%a+)=(.*)$")
        if key then
            found[key] = value
            lists[key] = lists[key] or {}
            lists[key][#lists[key] + 1] = value
        end
    end
    return found, lists
end

local function note(text)
    local file = io.open(net .. "/wax-failed.txt", "ab")
    if file then
        file:write(os.date("!%Y-%m-%dT%H:%M:%SZ", clock()), " ", text, "\n")
        file:close()
    end
    pcall(say, "[Wax] " .. text .. "\n")
end

-- Things a later frame deletes: "root <name>" beside Scripts, "stage <folder>" under run/net/stage.
local function discard(lines)
    if #lines == 0 then return end
    local file = io.open(net .. "/wax-old.txt", "ab")
    if not file then return end
    for _, line in ipairs(lines) do file:write(line, "\n") end
    file:close()
end

local function write_trial(trial)
    local lines = { "version=" .. trial.version, "from=" .. trial.from, "state=" .. trial.state, "tries=" .. trial.tries, "time=" .. clock() }
    for _, name in ipairs(trial.names) do lines[#lines + 1] = "name=" .. name end
    for _, name in ipairs(trial.fresh) do lines[#lines + 1] = "new=" .. name end
    return write(net .. "/wax-trial.txt", table.concat(lines, "\n") .. "\n")
end

local function running_version()
    local word = (read(root .. "/VERSION") or ""):match("^%s*(%S+)")
    return triple(word) and word or nil
end

-- Puts the parts of the version before back where they were. A part that was never moved is left as it is.
local function take_back(trial, names)
    local done, set_aside = {}, {}
    for index = #names, 1, -1 do
        local name = names[index]
        local here, before, aside = root .. "/" .. name, root .. "/" .. name .. ".before-" .. trial.from, root .. "/" .. name .. ".failed-" .. trial.version
        local had_before, moved_away = exists(before), false
        local ok, why = true, nil
        if (had_before or trial.is_fresh[name]) and exists(here) then
            ok, why = rename(here, aside)
            moved_away = ok and true or false
        end
        if ok and had_before then
            ok, why = rename(before, here)
            if not ok and moved_away then rename(aside, here) end
        end
        if not ok then
            for back = #done, 1, -1 do
                local step = done[back]
                if step.had_before then rename(step.here, step.before) end
                if step.moved_away then rename(step.aside, step.here) end
            end
            return false, ("%s could not be moved (%s)"):format(name, tostring(why))
        end
        done[#done + 1] = { here = here, before = before, aside = aside, had_before = had_before, moved_away = moved_away }
        if moved_away then set_aside[#set_aside + 1] = "root " .. name .. ".failed-" .. trial.version end
    end
    return true, set_aside
end

-- A trial file still there means the version put in at the start before never got as far as running.
local function settle_trial(text)
    local found, lists = fields(text)
    local trial = { version = found.version, from = found.from, state = found.state, tries = tonumber(found.tries) or 0,
        names = {}, fresh = lists.new or {}, is_fresh = {} }
    for _, name in ipairs(lists.name or {}) do
        if known[name] then trial.names[#trial.names + 1] = name end
    end
    for _, name in ipairs(trial.fresh) do trial.is_fresh[name] = true end
    local path = net .. "/wax-trial.txt"
    if not triple(trial.version) or not triple(trial.from) or #trial.names == 0 then
        os.remove(path)
        return nil
    end
    local any = false
    for _, name in ipairs(trial.names) do
        if exists(root .. "/" .. name .. ".before-" .. trial.from) then any = true end
    end
    if not any then
        -- nothing was moved yet, or the installer has replaced the whole folder since
        os.remove(path)
        return nil
    end
    local ok, result = take_back(trial, trial.names)
    if not ok then
        trial.tries = trial.tries + 1
        if trial.tries >= MAX_RETURNS then
            os.remove(path)
            note(("Wax %s did not start and %s could not be put back: %s. Run Update Wax.cmd to repair it"):format(trial.version, trial.from, result))
        else
            write_trial(trial)
            note(("Wax %s did not start and %s could not be put back yet: %s"):format(trial.version, trial.from, result))
        end
        return { did = "stuck", version = trial.version, from = trial.from }
    end
    discard(result)
    os.remove(net .. "/wax-kept.txt")
    os.remove(path)
    if trial.state ~= "trial" then
        -- the game stopped while the folders were being moved. The download is asked for again by the running game
        note(("Wax %s was half put in when the game stopped, so %s was put back"):format(trial.version, trial.from))
        return { did = "undone", version = trial.version, from = trial.from }
    end
    write(net .. "/wax-bad.txt", ("version=%s\nwhy=start\ntries=1\n"):format(trial.version))
    note(("Wax %s did not start here, so %s was put back"):format(trial.version, trial.from))
    return { did = "rolled back", version = trial.version, from = trial.from }
end

-- What the marker lists, or nil and the reason it cannot be used.
local function read_marker(text, version)
    if not text:find("^wax%-ready 1\r?\n") or not text:find("\nend\r?\n?$") then return nil, "the marker is cut short" end
    local found, lists = fields(text)
    if not triple(found.version) or found.from ~= version then return nil, "it was made for another version than the one installed" end
    if not newer(found.version, version) then return nil, "it is not newer than the version installed" end
    local folder = "stage/wax-" .. found.version
    if found.folder ~= folder then return nil, "it names a folder it may not use" end
    local tops, is_top = {}, {}
    for _, name in ipairs(lists.top or {}) do
        if not known[name] or is_top[name] then return nil, "it names a part Wax does not have" end
        is_top[name] = true
        tops[#tops + 1] = name
    end
    if not is_top.VERSION then return nil, "it does not hold a VERSION file" end
    table.sort(tops, function(a, b) return known[a] < known[b] end)
    local files = lists.file or {}
    if #files == 0 or #files ~= tonumber(found.files) then return nil, "its list of files is not whole" end
    local staged, listed, filled = net .. "/" .. folder, {}, {}
    for _, line in ipairs(files) do
        local size, path = line:match("^(%d+) (.+)$")
        if not size or path:find("..", 1, true) or path:find("[:\\]") or path:sub(1, 1) == "/" then return nil, "it lists a path that is not allowed" end
        local top = path:match("^[^/]+")
        if not is_top[top] then return nil, "it lists a file outside the parts it names" end
        if size_of(staged .. "/" .. path) ~= tonumber(size) then return nil, path .. " is missing or cut short" end
        listed[path], filled[top] = true, true
    end
    for _, name in ipairs(tops) do
        if not filled[name] then return nil, "it names a part without files" end
    end
    if is_top.Scripts and not (listed["Scripts/main.lua"] and listed["Scripts/selfswap.lua"] and listed["Scripts/wax/loader.lua"] and listed["Scripts/wax/boot.lua"]) then
        return nil, "its Scripts folder could not start the game's Wax"
    end
    if (read(staged .. "/VERSION") or ""):match("^%s*(%S+)") ~= found.version then return nil, "the VERSION file it holds says another version" end
    return { version = found.version, from = version, folder = folder, staged = staged, tops = tops }
end

local function put_in(text, version)
    local marker_path = net .. "/wax-ready.txt"
    local marker, why = read_marker(text, version)
    if not marker then
        os.remove(marker_path)
        local named = text:match("\nversion=(%d+%.%d+%.%d+)\r?\n")
        if named then discard({ "stage wax-" .. named }) end
        note(("The Wax update that was waiting was not put in: %s. Nothing was changed"):format(why))
        return { did = "refused", why = why }
    end
    local bad = fields(read(net .. "/wax-bad.txt"))
    local tries = bad.version == marker.version and tonumber(bad.tries) or 0
    if bad.version == marker.version and (bad.why == "start" or tries >= MAX_TRIES) then
        os.remove(marker_path)
        discard({ "stage wax-" .. marker.version })
        return { did = "nothing", why = "this version did not work here before" }
    end

    local trial = { version = marker.version, from = version, state = "moving", tries = 0, names = marker.tops, fresh = {}, is_fresh = {} }
    if not write_trial(trial) then return { did = "nothing", why = "run/net cannot be written" } end
    local moved, failed = {}, nil
    for _, name in ipairs(marker.tops) do
        local here, before, staged = root .. "/" .. name, root .. "/" .. name .. ".before-" .. version, marker.staged .. "/" .. name
        local had, ok, reason = exists(here), true, nil
        if had then ok, reason = rename(here, before) end
        if ok then
            ok, reason = rename(staged, here)
            if not ok and had then rename(before, here) end
        end
        if not ok then
            failed = ("%s could not be moved (%s)"):format(name, tostring(reason))
            break
        end
        moved[#moved + 1] = { here = here, before = before, staged = staged, had = had }
        if not had then trial.fresh[#trial.fresh + 1] = name end
    end

    if failed then
        local undone = true
        for index = #moved, 1, -1 do
            local step = moved[index]
            if not rename(step.here, step.staged) then undone = false end
            if step.had and not rename(step.before, step.here) then undone = false end
        end
        -- when a part could not go back now, the trial file stays and the next start finishes the job
        if undone then os.remove(net .. "/wax-trial.txt") end
        tries = tries + 1
        write(net .. "/wax-bad.txt", ("version=%s\nwhy=move\ntries=%d\n"):format(marker.version, tries))
        if tries >= MAX_TRIES then
            os.remove(marker_path)
            discard({ "stage wax-" .. marker.version })
        end
        note(("Wax %s could not be put in: %s. The game starts on %s"):format(marker.version, failed, version))
        return { did = "failed", version = marker.version, from = version, why = failed }
    end

    trial.state = "trial"
    write_trial(trial)
    write(net .. "/wax-applied.txt", ("from=%s\nversion=%s\ntime=%d\nwhen=%s\n"):format(version, marker.version, clock(),
        os.date("!%Y-%m-%dT%H:%M:%SZ", clock())))
    -- only the set made now is kept. The one before it is deleted by a later frame
    local kept, kept_lists = fields(read(net .. "/wax-kept.txt"))
    local old = { "stage wax-" .. marker.version }
    if triple(kept.version) and kept.version ~= version then
        for _, name in ipairs(kept_lists.name or {}) do
            if known[name] then old[#old + 1] = "root " .. name .. ".before-" .. kept.version end
        end
    end
    discard(old)
    local lines = { "version=" .. version }
    for _, step in ipairs(moved) do
        if step.had then lines[#lines + 1] = "name=" .. step.here:match("[^/]+$") end
    end
    write(net .. "/wax-kept.txt", table.concat(lines, "\n") .. "\n")
    os.remove(marker_path)
    os.remove(net .. "/wax-bad.txt")
    pcall(say, ("[Wax] Wax %s was put in. %s is kept beside it until the next update\n"):format(marker.version, version))
    return { did = "swapped", version = marker.version, from = version }
end

local function run()
    local version = running_version()
    if not version then return { did = "nothing", why = "no VERSION file" } end
    if exists(root .. "/dev.txt") then return { did = "nothing", why = "dev.txt" } end
    local outcome = nil
    local trial = read(net .. "/wax-trial.txt")
    if trial then
        outcome = settle_trial(trial)
        version = running_version()
        if not version then return outcome or { did = "nothing", why = "no VERSION file" } end
    end
    local ready = read(net .. "/wax-ready.txt")
    if ready and not (outcome and outcome.did == "stuck") then
        local put = put_in(ready, version)
        if not outcome or put.did == "swapped" then outcome = put end
    end
    return outcome or { did = "nothing" }
end

local ok, result = pcall(run)
if not ok then
    pcall(say, "[Wax] the check for a waiting Wax update failed: " .. tostring(result) .. "\n")
    return { did = "error", why = tostring(result) }
end
return result
