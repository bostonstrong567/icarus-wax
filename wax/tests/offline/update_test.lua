-- Offline tests for mods.update: which mods it may touch, what it checks before a swap, and what it leaves alone.
-- The helper DLL and the catalogue are stand-ins. The mods folders are real folders under a scratch directory.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\update_test.lua [scratch dir]

local t = dofile("wax/tests/offline/harness.lua")

local function win(path) return (path:gsub("/", "\\")) end
local here = io.popen("cd"):read("l"):gsub("\\", "/")
local base = (arg[1] or "build/update-test"):gsub("\\", "/")
if not base:match("^%a:") then base = here .. "/" .. base end
os.execute(('rmdir /s /q "%s" >nul 2>nul'):format(win(base)))

local real_open, real_rename = io.open, os.rename
local opens, current = 0, nil
io.open = function(...)
    opens = opens + 1
    return real_open(...)
end
os.rename = function(from, to)
    local refused = current and current.rename and current.rename(from, to)
    if refused then return nil, refused end
    return real_rename(from, to)
end

local function mkdir(path) os.execute(('mkdir "%s" >nul 2>nul'):format(win(path))) end

local function read(path)
    local file = real_open(path, "rb")
    if not file then return nil end
    local text = file:read("a")
    file:close()
    return text
end

local function write(path, text)
    local file = real_open(path, "wb")
    if not file then
        mkdir(path:match("^(.*)/[^/]+$"))
        file = assert(real_open(path, "wb"))
    end
    file:write(text)
    file:close()
end

-- Every file under a folder, as { ["relative/path"] = true }.
local function files_under(dir)
    local found, prefix = {}, #dir + 2
    local pipe = io.popen(('dir /b /s /a:-d "%s" 2>nul'):format(win(dir)))
    for line in pipe:lines() do found[(line:sub(prefix):gsub("\\", "/"))] = true end
    pipe:close()
    return found
end

-- The folder with every file's content, as one text that can be compared.
local function snapshot(dir)
    local names = {}
    for name in pairs(files_under(dir)) do names[#names + 1] = name end
    table.sort(names)
    for index, name in ipairs(names) do names[index] = name .. "=" .. read(dir .. "/" .. name) end
    return table.concat(names, "\n")
end

-- A folder the way UE4SS's IterateGameDirectories lists one.
local function tree_of(dir)
    local top = { __absolute_path = win(dir), __files = {} }
    for relative in pairs(files_under(dir)) do
        local at, path = top, dir
        for folder in relative:gmatch("([^/]+)/") do
            path = path .. "/" .. folder
            at[folder] = at[folder] or { __absolute_path = win(path), __files = {} }
            at = at[folder]
        end
        at.__files[#at.__files + 1] = { __name = relative:match("[^/]+$") }
    end
    return top
end

-- What IterateGameDirectories gives, built from the scratch folder. Wax\run is only listed when it is asked for.
local function listing(root)
    local wax = setmetatable({ mods = tree_of(root .. "/mods") }, { __index = function(_, name)
        return name == "run" and tree_of(root .. "/run") or nil
    end })
    return { Game = { Binaries = { Win64 = { ue4ss = { Mods = { Wax = wax } } } } } }
end
IterateGameDirectories = function() return listing(current.root) end

local NULL, NONE = {}, {}
local function encode(value)
    local kind = type(value)
    if value == NULL then return "null" end
    if value == NONE then return "[]" end
    if kind == "string" then
        return '"' .. value:gsub('[%c"\\]', function(char) return ("\\u%04x"):format(char:byte()) end) .. '"'
    elseif kind ~= "table" then
        return tostring(value)
    end
    local parts = {}
    if #value > 0 then
        for index, item in ipairs(value) do parts[index] = encode(item) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for key, item in pairs(value) do parts[#parts + 1] = encode(tostring(key)) .. ":" .. encode(item) end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Stands in for SHA-256: 64 hex digits that depend on the content.
local function digest(text)
    local a, b = 1, 0
    for index = 1, #text do
        a = (a + text:byte(index)) % 65521
        b = (b + a) % 65521
    end
    return ("%08x"):format(b * 65536 + a):rep(8)
end

-- Stands in for the owner's signature: 88 characters that depend on the text and on who signed it.
local function sign(text, key)
    return digest((key or "the owner") .. "\n" .. text) .. ("A"):rep(22) .. "=="
end

local function bytes_before(a, b)
    for index = 1, math.min(#a, #b) do
        if a:byte(index) ~= b:byte(index) then return a:byte(index) < b:byte(index) end
    end
    return #a < #b
end

-- The text the files of a mod are signed over, put together apart from the code under test.
local function signed_text(id, version, files, head)
    local lines = {}
    for index, file in ipairs(files) do lines[index] = { file.path, ("%s %d %s\n"):format(file.sha256, file.size, file.path) } end
    table.sort(lines, function(a, b) return bytes_before(a[1], b[1]) end)
    for index, line in ipairs(lines) do lines[index] = line[2] end
    return (head or ("mod %s %s"):format(id, version)) .. "\n" .. table.concat(lines)
end

local OLD = {
    ["mod.lua"] = 'return { name = "Listed Mod", version = "1.0.0" }',
    ["init.lua"] = 'return { made = "old" }',
    ["old only.lua"] = "return 1",
}
local NEW = {
    ["mod.lua"] = 'return { name = "Listed Mod", version = "1.1.0" }',
    ["init.lua"] = 'return { made = "new", data = require("lib.util") }',
    ["lib/util.lua"] = 'return "util 1.1"',
    ["data/items.json"] = '{"a":1}',
    ["read me.txt"] = "hello",
}

local count = 0

-- A fresh Wax core over its own scratch folders. setup(w) writes mods and files before anything loads.
local function world(setup)
    count = count + 1
    local root = ("%s/%d/Binaries/Win64/ue4ss/Mods/Wax"):format(base, count)
    os.execute(('mkdir "%s\\mods" "%s\\saved" "%s\\run" >nul 2>nul'):format(win(root), win(root), win(root)))
    local w = { root = root, mods = root .. "/mods", net = root .. "/run/net", now = 1000, notes = {}, asked = {}, checked = {}, published = {},
        runs = 0, calls = 0, changes = 0 }
    current = w

    -- What the owner's tool sends with a list. A list too broken to sign gets a signature of nothing.
    local function signature_of(plan)
        local ok, text = pcall(signed_text, plan.id, plan.version, plan.files)
        return sign(ok and text or "")
    end

    function w.mod(id, files, origin)
        for name, text in pairs(files) do write(w.mods .. "/" .. id .. "/" .. name, text) end
        if origin then write(w.mods .. "/" .. id .. "/wax.origin", origin:find("=") and origin or ("id=%s\nversion=%s\n"):format(id, origin)) end
    end

    -- The catalogue: answers an address with a status and a body.
    function w.catalogue(address)
        if address == "/api/versions" then
            local mods = {}
            for id, entry in pairs(w.published) do mods[id] = { version = entry.version, wax = entry.wax or NULL, published_at = "2026-10-06T10:00:00.000Z" } end
            return 200, encode({ mods = next(mods) and mods or NULL })
        end
        local id, version, rest = address:match("^/api/mods/([^/]+)/files/([^/?]+)(.*)$")
        local entry = id and w.published[id]
        if not entry or version ~= entry.version then return 404, "" end
        if rest == "?update=1" then
            local plan = { id = id, version = version, total = 0, files = {} }
            for path, text in pairs(entry.files) do
                plan.files[#plan.files + 1] = { path = path, size = #text, sha256 = digest(text) }
                plan.total = plan.total + #text
            end
            table.sort(plan.files, function(a, b) return a.path < b.path end)
            local signed = signature_of(plan)
            if w.plan then plan = w.plan(plan) or plan end
            -- the owner signs what the catalogue lists, unless the test has the catalogue change the list afterwards
            local signature = w.changed_after_signing and signed or signature_of(plan)
            if w.signature then signature = w.signature(signature, plan) end
            plan.signature = signature or nil
            return 200, encode(plan)
        end
        local path = rest:match("^/(.+)$")
        path = path and path:gsub("%%(%x%x)", function(code) return string.char(tonumber(code, 16)) end)
        local text = path and (w.served or entry.files)[path]
        if not text then return 404, "" end
        return 200, text
    end

    -- The helper: does what request.txt asks, the way waxnet.dll does, when the frame loop lets it.
    local function serve(text)
        local broken = false
        for line in text:gmatch("[^\n]+") do
            local address, output = line:match("^([^\t]*)\t(.*)$")
            if address == "-" then
                w.asked[#w.asked + 1] = "clear " .. output
                if w.cannot_clear then
                    write(w.net .. "/" .. output .. ".status", "0 0 - the folder could not be cleared\n")
                else
                    os.execute(('rmdir /s /q "%s" >nul 2>nul'):format(win(w.net .. "/" .. output)))
                    write(w.net .. "/" .. output .. ".status", "200 0 -\n")
                end
            elseif address == "=" and w.old_helper then
                w.asked[#w.asked + 1] = "verify " .. output
                write(w.net .. "/" .. output .. ".status", "0 0 - this address is not allowed\n")
            elseif address == "=" then
                w.asked[#w.asked + 1] = "verify " .. output
                local list, signature = read(w.net .. "/" .. output), read(w.net .. "/" .. output .. ".sig")
                local said = ("200 %d %s\n"):format(#(list or ""), digest(list or ""))
                if w.no_key then
                    said = "0 0 - this build has no signing key\n"
                elseif not list then
                    said = "0 0 - the list is missing or too large\n"
                elseif not signature then
                    said = "0 0 - the signature is missing\n"
                elseif signature ~= sign(list) .. "\n" then
                    said = "0 0 - the signature does not match\n"
                end
                w.checked[#w.checked + 1] = { output = output, list = list, signature = signature, good = said:sub(1, 4) == "200 " }
                if w.verify then said = w.verify(output, said) end
                if said then write(w.net .. "/" .. output .. ".status", said) end
            elseif address then
                w.asked[#w.asked + 1] = address
                local code, body = 0, ""
                if not w.offline then code, body = w.catalogue(address) end
                if w.offline then
                    write(w.net .. "/" .. output .. ".status", broken and "0 0 - not tried after an earlier failure\n" or "0 0 - no connection (12007)\n")
                    broken = true
                elseif code == 200 then
                    write(w.net .. "/" .. output, body)
                    local said = w.status and w.status(output, body)
                    write(w.net .. "/" .. output .. ".status", said or ("200 %d %s\n"):format(#body, digest(body)))
                else
                    os.remove(w.net .. "/" .. output)
                    write(w.net .. "/" .. output .. ".status", ("%d 0 -\n"):format(code))
                end
            end
        end
        if w.leave then
            for name, content in pairs(w.leave) do write(w.net .. "/" .. name, content) end
        end
        write(w.net .. "/done", (text:match("^(#%d+)") or "#0") .. "\n")
    end
    w.lib = {
        ready = function()
            if not w.net_made then mkdir(w.net) end
            w.net_made = true
        end,
        run = function()
            w.calls = w.calls + 1
            if (w.busy or 0) > 0 then
                w.busy = w.busy - 1
                return
            end
            local text = read(w.net .. "/request.txt")
            if not text or w.silent then return end
            os.remove(w.net .. "/request.txt")
            os.remove(w.net .. "/done")
            w.runs = w.runs + 1
            serve(text)
        end,
    }

    if setup then setup(w) end
    local Wax = t.new_wax()
    Wax.root = root
    w.Wax, w.log, w.sched = Wax, Wax.import("core.log"), Wax.import("core.sched")
    w.sched.clock = function() return w.now end
    w.storage, w.loader = Wax.import("core.storage"), Wax.import("mods.loader")
    Wax.mods, Wax.log, Wax.sched, Wax.storage = w.loader, w.log, w.sched, w.storage
    Wax.ui = { Notify = function(text, options) w.notes[#w.notes + 1] = { text = text, options = options } end }
    w.loader.sync()
    w.before = snapshot(w.mods)
    w.update = Wax.import("mods.update")
    w.update.time = function() return 1800000000 + math.floor(w.now) end
    w.update.loadlib = function(path, name)
        w.loaded_from = path
        if w.no_helper then return nil, "The specified module could not be found." end
        return name == "wax_net_ready" and w.lib.ready or w.lib.run
    end
    w.update.Changed:Connect(function() w.changes = w.changes + 1 end)
    w.update.start()

    function w.frame()
        w.now = w.now + 0.05
        w.loader.step()
        w.storage.step()
        w.sched.step()
    end
    function w.run(seconds)
        for _ = 1, math.floor(seconds / 0.05 + 0.5) do w.frame() end
    end
    -- Jumps the clock ahead, then runs frames for a while. Six hours ahead brings the next check.
    function w.later(seconds, tail)
        w.now = w.now + seconds
        w.run(tail or 40)
    end
    -- How many log lines of that level hold the text.
    function w.logged(fragment, level)
        local found = 0
        for _, entry in ipairs(w.log.since(0)) do
            if entry.message:find(fragment, 1, true) and (not level or entry.level == level) then found = found + entry.count end
        end
        return found
    end
    function w.made(id)
        local mod = w.loader.get(id or "Listed")
        return mod and mod.exports and mod.exports.made
    end
    function w.kept(id)
        for name in pairs(files_under(w.mods)) do
            local folder = name:match("^(%.removed%-" .. (id or "Listed") .. "%-%d+%-%d+)/")
            if folder then return folder end
        end
        return nil
    end
    function w.count_asked(pattern)
        local found = 0
        for _, address in ipairs(w.asked) do
            if address:find(pattern) then found = found + 1 end
        end
        return found
    end
    return w
end

local function listed(w)
    w.mod("Listed", OLD, "1.0.0")
    w.published.Listed = { version = "1.1.0", files = NEW }
end

-- Nothing in the mods folder changed, the old version still runs, and the reason was said once.
local function untouched(w, reason)
    t.eq(snapshot(w.mods), w.before, "the mods folder is as it was, with no copy under another name")
    t.eq(w.made(), "old", "the installed version still runs")
    t.eq(#w.notes, 0, "nothing was announced")
    if reason then
        t.eq(w.logged("Listed could not be updated to 1.1.0", "warn"), 1, "said once")
        t.eq(w.logged(reason, "warn"), 1, "the log says why: " .. reason)
        t.eq(w.logged("The installed version stays as it is"), 1)
        t.eq(w.update.state().problem, "Listed Mod could not be updated.")
    end
    t.eq(w.logged("", "error"), 0, "no errors in the log")
end

t.test("versions are compared as numbers", function()
    local newer = world().update.newer
    t.ok(newer("1.10.0", "1.9.9"))
    t.ok(not newer("1.9.9", "1.10.0"))
    t.ok(not newer("1.2.3", "1.2.3"))
    t.ok(newer("2.0.0", "1.99.99"))
    t.ok(newer("0.10.0", "0.9.0"))
    t.ok(newer("1.2.0", "1.2.0-beta.1"), "the plain version is newer than its own beta")
    t.ok(not newer("1.2.0-beta.1", "1.2.0"))
    t.ok(newer("1.2.0-beta.10", "1.2.0-beta.9"))
    t.ok(newer("1.2.0-rc.1", "1.2.0-beta.9"))
    t.ok(not newer("1.0.1+build5", "1.0.1"))
    t.ok(not newer("1.2", "1.1.0"), "not three numbers: never newer")
    t.ok(not newer("abc", "1.0.0"))
    t.ok(not newer(nil, "1.0.0"))
    t.ok(not newer("9.0.0", "what"))
    t.ok(not newer("1.0.0..1", "0.1.0"))
end)

t.test("a mod without wax.origin is never touched, whatever the catalogue lists", function()
    local w = world(function(w)
        w.mod("Mine", { ["init.lua"] = 'return { made = "mine" }', ["mod.lua"] = 'return { version = "0.1.0" }' })
        w.published.Mine = { version = "9.0.0", files = NEW }
    end)
    w.run(60)
    t.eq(snapshot(w.mods), w.before)
    t.eq(w.made("Mine"), "mine")
    t.eq(w.calls, 0, "with no mod from the catalogue installed, nothing is asked at all")
    t.eq(w.loaded_from, nil, "and the helper is not even loaded")
    t.eq(next(w.update.state().available), nil)
    t.ok(w.update.state().last > 0, "the check still counts as done")

    -- the same with a catalogue mod beside it, so the list of versions is in hand
    w = world(function(w)
        w.mod("Mine", { ["init.lua"] = 'return { made = "mine" }', ["mod.lua"] = 'return { version = "0.1.0" }' })
        w.mod("Listed", OLD, "1.0.0")
        w.published.Mine = { version = "9.0.0", files = NEW }
        w.published.Listed = { version = "1.0.0", files = OLD }
    end)
    w.run(60)
    t.eq(w.count_asked("^/api/versions$"), 1)
    t.eq(#w.asked, 1, "only the list of versions was asked for")
    t.eq(snapshot(w.mods), w.before)
    t.eq(w.made("Mine"), "mine")
    t.eq(next(w.update.state().available), nil)
    t.eq(w.update.install("Mine"), false, "and it cannot be asked for either")
end)

t.test("a newer version is checked, swapped in, and the old folder is kept", function()
    local w = world(listed)
    w.loader.set_enabled("Listed", true)
    w.run(19)
    t.eq(w.calls, 0, "nothing is asked in the first 20 seconds")
    w.run(40)
    t.eq(w.made(), "new", "the new version runs")
    t.eq(w.loader.get("Listed").exports.data, "util 1.1")
    t.eq(read(w.mods .. "/Listed/data/items.json"), '{"a":1}')
    t.eq(read(w.mods .. "/Listed/read me.txt"), "hello")
    t.eq(read(w.mods .. "/Listed/old only.lua"), nil, "a file the new version does not have is gone")
    t.eq(read(w.mods .. "/Listed/wax.origin"), "id=Listed\nversion=1.1.0\n")
    t.eq(read(w.mods .. "/Listed/wax.new"), nil, "a mod the player had switched on gets no mark from an update")
    for name in pairs(files_under(w.mods .. "/Listed")) do
        t.ok(not name:find("%.status$") and not name:find("%.part$"), "no helper file went along: " .. name)
    end
    local kept = w.kept()
    t.ok(kept, "the version before is kept under a dot name")
    t.eq(read(w.mods .. "/" .. kept .. "/init.lua"), OLD["init.lua"])
    t.eq(read(w.mods .. "/" .. kept .. "/wax.origin"), "id=Listed\nversion=1.0.0\n")
    t.eq(next(files_under(w.net .. "/stage")), nil, "nothing is left in the staging folder")
    t.eq(#w.notes, 1)
    t.eq(w.notes[1].text, "Listed Mod was updated to 1.1.0.")
    t.eq(w.asked[1], "/api/versions")
    t.eq(w.asked[2], "/api/mods/Listed/files/1.1.0?update=1")
    t.eq(w.asked[3], "verify plan/Listed.list", "the owner's signature on the list is checked before anything else is asked for")
    t.eq(w.asked[4], "clear stage/Listed", "the staging folder is emptied before anything is fetched into it")
    t.eq(w.count_asked("^/api/mods/Listed/files/1%.1%.0/read%%20me%.txt$"), 1, "each part of a path is encoded")
    t.eq(w.count_asked("^/api/mods/Listed/files/1%.1%.0/lib/util%.lua$"), 1)
    t.eq(#w.asked, 4 + 5)
    t.eq(#w.checked, 1)
    t.ok(w.checked[1].good, "the list the helper was given carries the owner's signature")
    t.ok(w.loaded_from:find("/bin/waxnet.dll", 1, true))
    local state = w.update.state()
    t.eq(next(state.available), nil)
    t.eq(next(state.installing), nil)
    t.eq(state.checking, false)
    t.eq(state.problem, nil)
    t.eq(state.auto, true)
    t.ok(state.last >= 1800001020)
    t.ok(w.changes >= 2, "the change signal fired")
    t.eq(w.logged("", "error"), 0)
    t.eq(w.logged("", "warn"), 0)
    -- the next check finds nothing to do
    local asked = #w.asked
    w.later(6 * 3600)
    t.eq(#w.asked, asked + 1, "six hours later the versions are asked for again, and that is all")
    t.eq(#w.notes, 1)
end)

t.test("a mod that is switched off is updated and stays switched off, and saved settings stay", function()
    local w = world(function(w)
        listed(w)
        write(w.root .. "/saved/wax.mods.lua", 'return { disabled = { Listed = true } }')
        write(w.root .. "/saved/Listed.settings.lua", 'return { volume = 3 }')
    end)
    t.eq(w.loader.list()[1].status, "disabled")
    w.run(60)
    t.eq(read(w.mods .. "/Listed/init.lua"), NEW["init.lua"])
    t.eq(w.loader.list()[1].status, "disabled", "still switched off")
    t.eq(w.loader.list()[1].enabled, false)
    t.eq(w.loader.list()[1].fresh, nil, "and not treated as a mod that was just added")
    t.eq(read(w.root .. "/saved/Listed.settings.lua"), 'return { volume = 3 }')
    t.eq(w.logged("stays switched off until you switch it on"), 0)
end)

t.test("an update of a mod that still carries wax.new keeps the mark, so an update never switches anything on", function()
    for _, name in ipairs({ "wax.new", "WAX.NEW" }) do
        local w = world(function(w)
            listed(w)
            write(w.mods .. "/Listed/" .. name, "new\n")
        end)
        t.eq(w.loader.list()[1].status, "disabled", name)
        t.eq(w.loader.list()[1].fresh, true, "the mark holds it, though nothing was written down about it")
        t.eq(w.made(), nil)
        w.run(60)
        t.eq(read(w.mods .. "/Listed/init.lua"), NEW["init.lua"], "the new version is in")
        t.eq(read(w.mods .. "/Listed/wax.origin"), "id=Listed\nversion=1.1.0\n")
        t.eq(files_under(w.mods .. "/Listed")["wax.new"], true, "and carries the mark")
        t.eq(read(w.mods .. "/Listed/wax.new"), "new\n")
        t.eq(w.loader.list()[1].status, "disabled", "it is still held")
        t.eq(w.loader.list()[1].fresh, true)
        t.eq(w.made(), nil, "none of its code has run")
        t.eq(w.loader.get("Listed").exports, nil)
        t.eq(read(w.mods .. "/" .. w.kept() .. "/" .. name), "new\n", "the copy before is kept as it was")
        t.eq(next(files_under(w.net .. "/stage")), nil, "nothing is left in the staging folder")
        t.eq(w.notes[1].text, "Listed Mod was updated to 1.1.0.")
        t.eq(w.logged("", "warn") + w.logged("", "error"), 0)
        -- the player switches it on: the mark goes and the new version runs
        w.loader.set_enabled("Listed", true)
        w.run(1)
        t.eq(read(w.mods .. "/Listed/wax.new"), nil)
        t.eq(w.made(), "new")
        t.eq(w.loader.list()[1].fresh, nil)
    end
end)

t.test("with the mark carried along, files are still handled one a frame", function()
    local w = world(function(w)
        listed(w)
        write(w.mods .. "/Listed/wax.new", "new\n")
    end)
    local most = 0
    for _ = 1, 60 / 0.05 do
        w.now = w.now + 0.05
        w.loader.step()
        w.storage.step()
        local before = opens
        w.sched.step()
        most = math.max(most, opens - before)
    end
    t.eq(read(w.mods .. "/Listed/wax.new"), "new\n")
    t.eq(read(w.mods .. "/Listed/wax.origin"), "id=Listed\nversion=1.1.0\n")
    t.eq(most, 1, "never more than one file opened by the updater in a frame")
end)

t.test("an updated mod is not a new mod: it runs on, and stays on the list of mods the player has seen", function()
    local w = world(listed)
    w.run(60)
    t.eq(w.made(), "new")
    t.eq(w.loader.list()[1].fresh, nil)
    t.eq(w.logged("is new here"), 0)
    w.storage.flush()
    local saved = load(read(w.root .. "/saved/wax.mods.lua"), "=saved", "t", {})()
    t.eq(saved.known.Listed, true)
    t.eq(saved.disabled.Listed, nil)
end)

t.test("a mod that depends on the updated one loads again with it", function()
    local w = world(function(w)
        listed(w)
        w.mod("User", { ["mod.lua"] = 'return { dependencies = { "Listed" } }', ["init.lua"] = 'return { made = require("@Listed").made }' })
    end)
    t.eq(w.made("User"), "old")
    w.run(60)
    t.eq(w.made("Listed"), "new")
    t.eq(w.made("User"), "new")
end)

t.test("the same version or an older one changes nothing", function()
    local w = world(function(w)
        w.mod("Listed", OLD, "1.0.0")
        w.mod("Ahead", { ["init.lua"] = 'return { made = "ahead" }' }, "2.0.0")
        w.published.Listed = { version = "1.0.0", files = NEW }
        w.published.Ahead = { version = "1.5.0", files = NEW }
    end)
    w.run(60)
    t.eq(#w.asked, 1)
    t.eq(snapshot(w.mods), w.before)
    t.eq(next(w.update.state().available), nil)
    t.eq(#w.notes, 0)
end)

t.test("a wax.origin that names another mod, or no version, leaves the folder alone", function()
    local w = world(function(w)
        w.mod("Listed", OLD, "id=Other\nversion=1.0.0\n")
        w.mod("Second", { ["init.lua"] = "return {}" }, "id=Second\nversion=soon\n")
        w.published.Listed = { version = "1.1.0", files = NEW }
        w.published.Other = { version = "1.1.0", files = NEW }
        w.published.Second = { version = "1.1.0", files = NEW }
    end)
    w.run(60)
    w.later(6 * 3600)
    t.eq(snapshot(w.mods), w.before)
    t.eq(w.calls, 0)
    t.eq(w.logged("mods/Listed has a wax.origin that names another mod or no version", "warn"), 1)
    t.eq(w.logged("mods/Second has a wax.origin", "warn"), 1)
end)

local function plan_case(name, reason, tamper, extra, leaves)
    t.test("nothing changes when " .. name, function()
        local w = world(function(w)
            listed(w)
            if extra then extra(w) end
            w.plan = tamper
        end)
        w.run(60)
        untouched(w, reason)
        -- a second look says nothing new
        w.later(6 * 3600)
        untouched(w, reason)
        if not leaves then t.eq(next(files_under(w.net .. "/stage")), nil, "what was downloaded is not left behind") end
    end)
end

-- One refused entry after another, each as a new version of the same mod.
local function refused_entries(name, paths, reason)
    t.test("nothing changes when " .. name, function()
        local w = world(function(w) w.mod("Listed", OLD, "1.0.0") end)
        for index, path in ipairs(paths) do
            local version = "1.1." .. index
            w.published.Listed = { version = version, files = NEW }
            w.plan = function(plan)
                plan.files[#plan.files + 1] = { path = path, size = 8, sha256 = digest("return 1") }
                plan.total = plan.total + 8
            end
            w.later(index == 1 and 0 or 6 * 3600)
            t.eq(w.logged(("Listed could not be updated to %s: %s"):format(version, reason(path)), "warn"), 1, ("%q"):format(path))
            t.eq(snapshot(w.mods), w.before, ("%q"):format(path))
            t.eq(w.made(), "old")
            t.eq(w.count_asked("^clear "), 0, "nothing was fetched for a list that is refused")
        end
        t.eq(#w.notes, 0)
        t.eq(w.logged("", "error"), 0)
        t.eq(w.logged("", "warn"), #paths)
    end)
end

plan_case("a file does not match its checksum", "init.lua does not match its checksum", function(plan)
    for _, file in ipairs(plan.files) do
        if file.path == "init.lua" then file.sha256 = ("0"):rep(64) end
    end
end)
plan_case("a file has another size than the list says", "read me.txt does not match its checksum", function(plan)
    for _, file in ipairs(plan.files) do
        if file.path == "read me.txt" then file.size = file.size + 1 end
    end
    plan.total = plan.total + 1
end)
plan_case("a listed file is missing on the server", "extra.lua was not downloaded (the catalogue answered 404)", function(plan)
    plan.files[#plan.files + 1] = { path = "extra.lua", size = 8, sha256 = digest("return 1") }
    plan.total = plan.total + 8
end)
plan_case("a file is listed twice", "it lists the same file twice: Init.lua", function(plan)
    plan.files[#plan.files + 1] = { path = "Init.lua", size = 8, sha256 = digest("return 1") }
    plan.total = plan.total + 8
end)
plan_case("the sizes do not add up to the total", "its sizes do not add up", function(plan) plan.total = plan.total + 5 end)
plan_case("an old download is in the way and cannot be cleared", "the folder the download goes to could not be emptied", nil, function(w)
    w.cannot_clear = true
    write(w.net .. "/stage/Listed/left over.lua", "return 'an extra file'")
end, true)
plan_case("a file the catalogue does not list turns up in the download", "the download holds a file the catalogue does not list: sub/extra.lua",
    nil, function(w) w.leave = { ["stage/Listed/sub/extra.lua"] = "return 'not listed'" } end, true)
plan_case("a file arrives cut short", "data/items.json is missing or cut short", nil, function(w)
    w.status = function(output, body)
        if output:find("items.json", 1, true) then
            write(w.net .. "/" .. output, body:sub(1, 3))
            return ("200 %d %s\n"):format(#body, digest(body))
        end
    end
end)
plan_case("a Lua file does not compile", "lib/util.lua does not compile", nil, function(w)
    local files = {}
    for name, text in pairs(NEW) do files[name] = text end
    files["lib/util.lua"] = "return return"
    w.published.Listed = { version = "1.1.0", files = files }
end)
plan_case("there is no init.lua", "it has no init.lua", function(plan)
    for index, file in ipairs(plan.files) do
        if file.path == "init.lua" then
            plan.total = plan.total - file.size
            table.remove(plan.files, index)
            break
        end
    end
end)
plan_case("the list is for another mod", "the catalogue answered for another mod or version", function(plan) plan.id = "Other" end)
plan_case("the list is for another version", "the catalogue answered for another mod or version", function(plan) plan.version = "1.2.0" end)
plan_case("the list is empty", "the catalogue listed no files", function(plan) plan.files, plan.total = NONE, 0 end)
plan_case("a file has no checksum", "it gives no checksum for init.lua", function(plan)
    for _, file in ipairs(plan.files) do
        if file.path == "init.lua" then file.sha256 = "abc" end
    end
end)
plan_case("there are more than 500 files", "it has more than 500 files", function(plan)
    for index = 1, 500 do plan.files[#plan.files + 1] = { path = ("more/%d.txt"):format(index), size = 0, sha256 = digest("") } end
end)
plan_case("it is larger than 20 MB in all", "it is larger than 20 MB", function(plan)
    plan.files[#plan.files + 1] = { path = "big.png", size = 20 * 1024 * 1024, sha256 = digest("") }
    plan.total = plan.total + 20 * 1024 * 1024
end)

refused_entries("a path is not allowed", { "../evil.lua", "sub/../../evil.lua", "/abs.lua", "C:/abs.lua", "sub\\evil.lua", "a//b.lua",
    "trail./x.lua", "nul.lua", "sub/COM1.txt/x.lua", "caf\195\169.lua", "semi;colon.lua", " lead.lua", "a..b.lua", "tab\there.lua", "" },
    function() return "it holds a path that is not allowed" end)
refused_entries("a kind of file is not allowed", { "tool.exe", "lib/native.dll", "run.bat", "noextension", "wax.old",
    "init.lua.status", "script.LUAC", "page.html" },
    function(path) return "it holds a kind of file that is not allowed: " .. path end)
-- wax.origin says where a mod came from and wax.new that the player has not switched it on: neither can come with a mod's own files
refused_entries("a file is named as one of the two that are Wax's own", { "wax.new", "WAX.NEW", "Wax.New", "wax.origin", "WAX.ORIGIN",
    "Wax.Origin", "sub/wax.new", "lib/deep/Wax.Origin" },
    function(path) return "it holds a file under a name that is Wax's own: " .. path end)

t.test("a refused list is refused before any file is fetched", function()
    local w = world(function(w)
        listed(w)
        w.plan = function(plan) plan.files[#plan.files + 1] = { path = "../evil.lua", size = 1, sha256 = digest("x") } end
    end)
    w.run(60)
    t.eq(w.count_asked("^/api/mods/Listed/files/1%.1%.0/"), 0)
    t.eq(w.count_asked("^clear "), 0)
    t.eq(read(w.root .. "/run/evil.lua"), nil)
end)

local NOT_SIGNED = "the catalogue gives no signature for the list of its files"
local NOT_OURS = "the list of its files is not signed with Wax's key (the signature does not match)"

-- Nothing is fetched and the installed mod stays, with the reason said once. setup(w) makes the signature of the new version's list bad.
local function signature_case(name, reason, setup, checks)
    t.test("nothing is downloaded when " .. name, function()
        local w = world(function(w)
            listed(w)
            setup(w)
        end)
        w.run(60)
        untouched(w, reason)
        w.later(6 * 3600)
        untouched(w, reason)
        t.eq(w.count_asked("^/api/mods/Listed/files/1%.1%.0/"), 0, "not one file was asked for")
        t.eq(w.count_asked("^clear "), 0, "and no folder was made for a download")
        t.eq(w.count_asked("^verify plan/Listed%.list$"), checks, "times the helper was asked")
        t.eq(next(files_under(w.net .. "/stage")), nil)
        t.eq(w.logged("", "warn"), 1, "one line in the log")
    end)
end

local function with_signature(make)
    return function(w) w.signature = function(signature, plan) return make(signature, plan) end end
end

signature_case("the list of files comes without a signature", NOT_SIGNED, with_signature(function() return false end), 0)
signature_case("the signature is empty in the answer", NOT_SIGNED, with_signature(function() return NULL end), 0)
signature_case("the signature is not 64 bytes in base64", NOT_SIGNED, with_signature(function(signature) return signature:sub(1, 87) end), 0)
signature_case("the signature holds something that is not base64", NOT_SIGNED,
    with_signature(function(signature) return signature:sub(1, 40) .. "*" .. signature:sub(42) end), 0)
signature_case("the signature was made with another key", NOT_OURS,
    with_signature(function(_, plan) return sign(signed_text(plan.id, plan.version, plan.files), "someone else") end), 2)
signature_case("the signature is the one of another version of the mod", NOT_OURS,
    with_signature(function(_, plan) return sign(signed_text(plan.id, "1.0.9", plan.files)) end), 2)
signature_case("the signature is over the same files under another mod's name", NOT_OURS,
    with_signature(function(_, plan) return sign(signed_text("Other", plan.version, plan.files)) end), 2)
signature_case("the signature is one for Wax's own files, over the same list", NOT_OURS,
    with_signature(function(_, plan) return sign(signed_text(nil, nil, plan.files, "wax " .. plan.version)) end), 2)
signature_case("the signature is the one of the mod's zip", NOT_OURS,
    with_signature(function(_, plan) return sign(("zip %s %s\n%s %d\n"):format(plan.id, plan.version, digest("the zip"), 1234)) end), 2)
signature_case("a file was changed in the list after the owner signed it", NOT_OURS, function(w)
    w.changed_after_signing = true
    w.plan = function(plan)
        for _, file in ipairs(plan.files) do
            if file.path == "init.lua" then file.sha256 = digest("return os.execute('calc')") end
        end
    end
end, 2)
signature_case("a file was added to the list after the owner signed it", NOT_OURS, function(w)
    w.changed_after_signing = true
    w.plan = function(plan)
        plan.files[#plan.files + 1] = { path = "extra.lua", size = 8, sha256 = digest("return 1") }
        plan.total = plan.total + 8
    end
end, 2)
signature_case("this copy of the helper was built without the owner's key", "the list of its files is not signed with Wax's key (this build has no signing key)",
    function(w) w.no_key = true end, 2)
signature_case("the helper is one from before signatures", "the list of its files is not signed with Wax's key (this address is not allowed)",
    function(w) w.old_helper = true end, 2)
signature_case("the helper answers for a list of another size", "the helper checked another list than the one written for it", function(w)
    w.verify = function() return ("200 5 %s\n"):format(digest("other")) end
end, 2)
signature_case("the helper says nothing about the list", "the list of its files is not signed with Wax's key (no answer)", function(w)
    w.verify = function() return nil end
end, 2)

t.test("the text the helper checks is the one the owner signs: the mod, the version, then every file in the order of its path's bytes", function()
    local files = {
        ["init.lua"] = "return {}",
        ["Zed.lua"] = "return 1",
        ["a_b.lua"] = "return 2",
        ["a-b.lua"] = "return 3",
        ["a b.lua"] = "return 4",
        ["lib/util.lua"] = "return 5",
        ["lib.lua"] = "return 6",
    }
    local w = world(function(w)
        w.mod("Listed", OLD, "1.0.0")
        w.published.Listed = { version = "1.1.0-beta.2", files = files }
        -- the catalogue may list the files in any order
        w.plan = function(plan) table.sort(plan.files, function(a, b) return a.path > b.path end) end
    end)
    w.run(60)
    local lines = { "mod Listed 1.1.0-beta.2" }
    for _, path in ipairs({ "Zed.lua", "a b.lua", "a-b.lua", "a_b.lua", "init.lua", "lib.lua", "lib/util.lua" }) do
        lines[#lines + 1] = ("%s %d %s"):format(digest(files[path]), #files[path], path)
    end
    t.eq(#w.checked, 1)
    t.eq(w.checked[1].output, "plan/Listed.list")
    t.eq(w.checked[1].list, table.concat(lines, "\n") .. "\n")
    t.eq(w.checked[1].signature, sign(w.checked[1].list) .. "\n", "the signature goes to the helper as the catalogue gave it, with a line ending")
    t.eq(read(w.mods .. "/Listed/Zed.lua"), "return 1", "and with a good signature the version is put in")
    t.eq(read(w.mods .. "/Listed/wax.origin"), "id=Listed\nversion=1.1.0-beta.2\n")
end)

t.test("a version that needs a newer Wax is skipped, and that is said once", function()
    local w = world(function(w)
        listed(w)
        w.published.Listed.wax = "0.3.0"
        write(w.root .. "/VERSION", "0.2.0\r\n")
    end)
    w.run(60)
    w.later(6 * 3600)
    t.eq(w.count_asked("^/api/versions$"), 2)
    t.eq(#w.asked, 2, "its files were never asked for")
    t.eq(snapshot(w.mods), w.before)
    t.eq(next(w.update.state().available), nil, "and it is not offered")
    t.eq(w.logged("Listed 1.1.0 needs Wax 0.3.0 or newer and this is Wax 0.2.0, so it was not updated"), 1)

    -- a version that asks for the Wax that runs, or an older one, goes in
    w = world(function(w)
        listed(w)
        w.published.Listed.wax = "0.2.0"
        write(w.root .. "/VERSION", "0.2.0\r\n")
    end)
    w.run(60)
    t.eq(w.made(), "new")
end)

t.test("with updates switched off a newer version is only offered, and install puts it in", function()
    local w = world(function(w)
        listed(w)
        write(w.root .. "/saved/wax.updates.lua", "return { auto = false, last = 5 }")
    end)
    t.eq(w.update.state().auto, false, "the setting is read from its own file")
    t.eq(w.update.state().last, 5)
    w.run(60)
    t.eq(w.update.state().available.Listed, "1.1.0")
    t.eq(#w.asked, 1, "only the versions were asked for")
    t.eq(snapshot(w.mods), w.before)
    t.eq(w.made(), "old")
    t.eq(w.update.install("Nothing"), false)
    t.eq(w.update.install("Listed"), true)
    t.eq(w.update.state().installing.Listed, true)
    w.run(20)
    t.eq(w.made(), "new")
    t.eq(next(w.update.state().available), nil)
    t.eq(next(w.update.state().installing), nil)
    t.eq(w.notes[1].text, "Listed Mod was updated to 1.1.0.")
    t.ok(read(w.root .. "/saved/wax.updates.lua"):find("%[\"auto\"%] = false"), "the switch stays off")
end)

t.test("switching updates on puts in what was only offered, and the switch is remembered", function()
    local w = world(listed)
    w.update.set_auto(false)
    w.run(60)
    t.eq(w.made(), "old")
    t.eq(w.update.state().available.Listed, "1.1.0")
    t.ok(read(w.root .. "/saved/wax.updates.lua"):find("%[\"auto\"%] = false"))
    t.ok(not (read(w.root .. "/saved/wax.mods.lua") or ""):find("auto", 1, true), "it is not kept in the loader's file")
    w.update.set_auto(true)
    w.run(20)
    t.eq(w.made(), "new")
    t.ok(read(w.root .. "/saved/wax.updates.lua"):find("%[\"auto\"%] = true"))
end)

t.test("with looking for updates switched off nothing is asked, the helper is not loaded and no request file is written", function()
    local w = world(function(w)
        listed(w)
        write(w.root .. "/saved/wax.updates.lua", "return { look = false }")
    end)
    t.eq(w.update.state().look, false, "the setting is read from the updater's file")
    t.eq(w.update.state().auto, true)
    w.run(60)
    w.later(6 * 3600)
    w.later(6 * 3600)
    t.eq(w.calls, 0, "the helper was not called")
    t.eq(w.loaded_from, nil, "or even loaded")
    t.eq(#w.asked, 0)
    t.eq(next(files_under(w.root .. "/run")), nil, "no request file, and nothing else, was written")
    t.eq(snapshot(w.mods), w.before)
    t.eq(next(w.update.state().available), nil, "nothing is offered")
    t.eq(w.update.state().last, 0, "and nothing counts as a check")
    t.eq(w.update.check_now(), false)
    t.eq(w.update.install("Listed"), false)
    t.eq(w.logged("", "warn") + w.logged("", "error"), 0)
    t.eq(#w.notes, 0)
    -- Auto Update on or off makes no difference to that
    w.update.set_auto(false)
    w.update.set_auto(true)
    w.later(6 * 3600)
    t.eq(w.calls, 0)
    -- switched on, the catalogue is asked at once and the newer version is put in
    w.update.set_looking(true)
    w.run(20)
    t.eq(w.made(), "new")
    t.ok(read(w.root .. "/saved/wax.updates.lua"):find('%["look"%] = true'), "the switch is remembered")
end)

t.test("switching looking for updates off takes back what was offered, and a download under way is not put in", function()
    local w = world(function(w)
        listed(w)
        write(w.root .. "/saved/wax.updates.lua", "return { auto = false }")
    end)
    t.eq(w.update.state().look, true, "a file from before the switch means it is on")
    w.run(60)
    t.eq(w.update.state().available.Listed, "1.1.0")
    local asked = #w.asked
    w.update.set_looking(false)
    t.eq(next(w.update.state().available), nil)
    t.eq(w.update.install("Listed"), false)
    w.later(6 * 3600)
    t.eq(#w.asked, asked, "nothing more is asked")
    t.ok(read(w.root .. "/saved/wax.updates.lua"):find('%["look"%] = false'))
    t.ok(read(w.root .. "/saved/wax.updates.lua"):find('%["auto"%] = false'), "the other switch is left as it was")

    -- switched off while the files of a version are on the way
    w = world(function(w)
        listed(w)
        w.status = function(output)
            if output:find("init.lua", 1, true) then w.update.set_looking(false) end
        end
    end)
    w.run(60)
    t.eq(snapshot(w.mods), w.before, "the mods folder is as it was")
    t.eq(w.made(), "old")
    t.eq(#w.notes, 0)
    t.eq(w.logged("Listed could not be updated to 1.1.0: looking for updates was switched off while it was downloaded", "warn"), 1)
    t.eq(w.update.state().problem, nil, "what the player switched off is not shown as something that went wrong")
    local calls = w.calls
    w.later(6 * 3600)
    t.eq(w.calls, calls, "and the helper is left alone from then on")
    t.eq(w.made(), "old")
end)

t.test("when the new folder cannot be moved in, the old one is put back", function()
    local w = world(function(w)
        listed(w)
        w.rename = function(from, to)
            if from:find("/stage/Listed", 1, true) and to:find("mods/Listed$") then return "Permission denied" end
        end
    end)
    w.run(60)
    t.eq(snapshot(w.mods), w.before, "the mods folder is as it was")
    t.eq(w.made(), "old", "and the old version runs again")
    t.eq(w.loader.list()[1].status, "loaded")
    t.eq(w.kept(), nil, "no copy under a dot name is left")
    t.eq(#w.notes, 0)
    t.eq(w.logged("the new files could not be moved into the mods folder (Permission denied). The version before was put back", "warn"), 1)
    t.eq(next(files_under(w.net .. "/stage")), nil)
    t.eq(w.update.state().available.Listed, "1.1.0", "it is still offered")
    -- once the folder can be moved, asking again puts it in
    w.rename = nil
    t.eq(w.update.install("Listed"), true)
    w.run(20)
    t.eq(w.made(), "new")
end)

t.test("when the old folder cannot be moved away, nothing changes", function()
    local w = world(function(w)
        listed(w)
        w.rename = function(from) if from:find("mods/Listed$") then return "Permission denied" end end
    end)
    w.run(60)
    untouched(w, "the folder could not be renamed (Permission denied)")
end)

t.test("a folder that stops being a catalogue mod during the download is left alone", function()
    local w = world(function(w)
        listed(w)
        -- the player replaces the mod with their own work while its files are on the way
        w.status = function(output)
            if output:find("init.lua", 1, true) then os.remove(w.mods .. "/Listed/wax.origin") end
        end
    end)
    w.run(60)
    t.eq(w.made(), "old")
    t.eq(read(w.mods .. "/Listed/init.lua"), OLD["init.lua"])
    t.eq(w.kept(), nil)
    t.eq(#w.notes, 0)
end)

t.test("without the helper it says so once and stays quiet", function()
    local w = world(function(w)
        listed(w)
        w.no_helper = true
    end)
    w.run(60)
    t.eq(w.logged("bin/waxnet.dll could not be loaded (The specified module could not be found.)", "warn"), 1)
    t.eq(w.update.state().problem, "The helper that downloads updates is missing, so mods are not updated.")
    t.eq(w.update.state().stopped, true)
    t.eq(w.update.check_now(), false)
    t.eq(w.update.install("Listed"), false)
    w.later(7 * 3600)
    t.eq(w.logged("", "warn"), 1, "one line, and no more after it")
    t.eq(w.logged("", "error"), 0)
    t.eq(snapshot(w.mods), w.before)
    t.eq(read(w.net .. "/request.txt"), nil)
end)

t.test("when the catalogue cannot be reached it says so once, and tries again at the next check", function()
    local w = world(function(w)
        listed(w)
        w.offline = true
    end)
    w.run(60)
    t.eq(w.update.state().problem, "Updates could not be checked.")
    t.eq(w.update.state().last, 0, "a check that failed is not a check")
    t.eq(w.logged("could not check for updates: the list of versions: no connection (12007)", "warn"), 1)
    w.later(6 * 3600)
    t.eq(w.count_asked("^/api/versions$"), 2)
    t.eq(w.logged("could not check for updates", "warn"), 1)
    t.eq(snapshot(w.mods), w.before)
    w.offline = false
    w.later(6 * 3600)
    t.eq(w.made(), "new")
    t.eq(w.update.state().problem, nil)
end)

t.test("an answer that is not what was asked for is not used", function()
    local w = world(function(w)
        listed(w)
        w.catalogue = function() return 200, "<html>not json</html>" end
    end)
    w.run(60)
    t.eq(w.logged("could not check for updates: the list of versions: the answer could not be read", "warn"), 1)
    t.eq(snapshot(w.mods), w.before)

    w = world(function(w)
        listed(w)
        w.catalogue = function() return 503, "" end
    end)
    w.run(60)
    t.eq(w.logged("could not check for updates: the list of versions: the catalogue answered 503", "warn"), 1)
end)

t.test("an answer left over from an older request is thrown away, and the request is started again", function()
    local w = world(function(w)
        listed(w)
        w.busy = 1
        write(w.net .. "/done", "#7\n")
    end)
    w.run(60)
    t.eq(w.made(), "new")
    t.ok(w.calls > w.runs, "the helper was called again after the stale answer")
end)

t.test("a request that is never answered is given up, and the next check works", function()
    local w = world(function(w)
        listed(w)
        w.silent = true
    end)
    w.run(400)
    t.eq(w.update.state().problem, "Updates could not be checked.")
    t.eq(w.update.state().checking, false)
    t.eq(w.logged("could not check for updates: no answer came in time", "warn"), 1)
    w.silent = false
    w.later(6 * 3600)
    t.eq(w.made(), "new")
end)

t.test("check_now asks at once, but not more often than once a minute", function()
    local w = world(function(w)
        w.mod("Listed", OLD, "1.0.0")
        w.published.Listed = { version = "1.0.0", files = OLD }
    end)
    t.eq(w.update.check_now(), true, "before the first check it brings it forward")
    w.run(5)
    t.eq(w.count_asked("^/api/versions$"), 1)
    local ok, wait = w.update.check_now()
    t.eq(ok, false)
    t.ok(wait > 50 and wait <= 60, "it says how long to wait: " .. tostring(wait))
    w.run(61)
    t.eq(w.count_asked("^/api/versions$"), 1)
    t.eq(w.update.check_now(), true)
    w.run(5)
    t.eq(w.count_asked("^/api/versions$"), 2)
    w.published.Listed = { version = "1.1.0", files = NEW }
    w.run(61)
    t.eq(w.update.check_now(), true)
    w.run(20)
    t.eq(w.made(), "new", "a check asked for by hand installs like any other")
end)

t.test("between checks nothing reads or writes a file", function()
    local w = world(function(w)
        w.mod("Listed", OLD, "1.0.0")
        w.published.Listed = { version = "1.0.0", files = OLD }
    end)
    w.loader.set_watching(false)
    w.run(60)
    t.eq(w.count_asked("^/api/versions$"), 1)
    local before, calls = opens, w.calls
    w.run(3600)
    t.eq(opens - before, 0, "no file was opened in an hour of frames")
    t.eq(w.calls, calls, "and the helper was not called")
    -- while a request is out, the answer is looked for every 30 frames and nothing else is read
    w.silent = true
    w.later(6 * 3600, 5)
    local started = opens
    w.run(30)
    t.ok(opens - started <= 30 / 0.05 / 30 + 1, "at most one look every 30 frames: " .. (opens - started))
    t.ok(opens - started >= 15, "and it does look: " .. (opens - started))
end)

t.test("files are handled one a frame", function()
    local w = world(listed)
    local most, frames_with = 0, 0
    for _ = 1, 60 / 0.05 do
        w.now = w.now + 0.05
        w.loader.step()
        w.storage.step()
        local before = opens
        w.sched.step()
        local used = opens - before
        if used > 0 then frames_with = frames_with + 1 end
        if used > most then most = used end
    end
    t.eq(w.made(), "new")
    t.eq(most, 1, "never more than one file opened by the updater in a frame")
    t.ok(frames_with > 15, "the work was spread over many frames: " .. frames_with)
end)

t.finish("update")
