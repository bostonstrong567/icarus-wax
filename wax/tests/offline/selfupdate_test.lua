-- Offline tests for mods.selfupdate: what it downloads beside the running Wax, what it checks before it writes the marker,
-- and what it never touches. The helper DLL and the catalogue are stand-ins. The Wax folder is a real one under a scratch directory.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\selfupdate_test.lua [scratch dir]

local t = dofile("wax/tests/offline/harness.lua")

local SWAP = "wax/runtime/Scripts/selfswap.lua"
local function win(path) return (path:gsub("/", "\\")) end
local here = io.popen("cd"):read("l"):gsub("\\", "/")
local base = (arg[1] or "build/selfupdate-test"):gsub("\\", "/")
if not base:match("^%a:") then base = here .. "/" .. base end
os.execute(('rmdir /s /q "%s" >nul 2>nul'):format(win(base)))

local real_open = io.open
local opens, current = 0, nil
io.open = function(...)
    opens = opens + 1
    return real_open(...)
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

local function exists(path)
    local ok, _, code = os.rename(path, path)
    return ok and true or (code ~= nil and code ~= 2)
end

-- Writes { [path] = text } under a folder, making every folder they need with one command.
local function write_all(dir, files)
    local seen, folders = {}, {}
    for path in pairs(files) do
        local folder = (dir .. "/" .. path):match("^(.*)/[^/]+$")
        if not seen[folder] then
            seen[folder] = true
            folders[#folders + 1] = '"' .. win(folder) .. '"'
        end
    end
    os.execute("mkdir " .. table.concat(folders, " ") .. " >nul 2>nul")
    for path, text in pairs(files) do write(dir .. "/" .. path, text) end
end

local function files_under(dir)
    local found, prefix = {}, #dir + 2
    local pipe = io.popen(('dir /b /s /a:-d "%s" 2>nul'):format(win(dir)))
    for line in pipe:lines() do found[(line:sub(prefix):gsub("\\", "/"))] = true end
    pipe:close()
    return found
end

-- Every file under a folder with its content, as one text. Folders named in skip are left out.
local function snapshot(dir, skip)
    local names = {}
    for name in pairs(files_under(dir)) do
        local left_out = false
        for _, folder in ipairs(skip or {}) do
            if name:sub(1, #folder + 1) == folder .. "/" then left_out = true end
        end
        if not left_out then names[#names + 1] = name end
    end
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

IterateGameDirectories = function()
    local root = current.root
    local wax = setmetatable({ mods = tree_of(root .. "/mods") }, { __index = function(_, name)
        return name == "run" and tree_of(root .. "/run") or nil
    end })
    return { Game = { Binaries = { Win64 = { ue4ss = { Mods = { Wax = wax } } } } } }
end

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

-- The text a list of files is signed over, put together apart from the code under test. head: the first line, for a list that is not Wax's own.
local function signed_text(version, files, head)
    local lines = {}
    for index, file in ipairs(files) do lines[index] = { file.path, ("%s %d %s\n"):format(file.sha256, file.size, file.path) } end
    table.sort(lines, function(a, b) return a[1] < b[1] end)
    for index, line in ipairs(lines) do lines[index] = line[2] end
    return (head or ("wax " .. version)) .. "\n" .. table.concat(lines)
end

local MAIN = 'pcall(dofile, "selfswap.lua")\nreturn "main %s"'

-- Wax's own files of one version. Between two versions only Scripts and VERSION differ, unless changes says otherwise.
local function runtime(version, changes)
    local files = {
        ["VERSION"] = version .. "\r\n",
        ["Wax-Import.ps1"] = "Write-Host 'import'\r\n",
        ["Scripts/main.lua"] = MAIN:format(version),
        ["Scripts/selfswap.lua"] = 'return "swap ' .. version .. '"',
        ["Scripts/wax/boot.lua"] = 'return "boot ' .. version .. '"',
        ["Scripts/wax/loader.lua"] = 'return "loader ' .. version .. '"',
        ["Scripts/wax/mods/update.lua"] = 'return "update ' .. version .. '"',
        ["Scripts/wax/mods/selfupdate.lua"] = 'return "selfupdate ' .. version .. '"',
        ["data/libraries.lua"] = "return { 'libraries' }",
        ["assets/round6.png"] = "a png",
        ["assets/lucide/32/arrow up.png"] = "an icon",
        ["assets/lucide/LICENSE.txt"] = "ISC License",
        ["bin/waxco.dll"] = "coroutines",
        ["bin/waxnet.dll"] = "downloads",
    }
    for path, text in pairs(changes or {}) do files[path] = text or nil end
    return files
end

local count = 0

-- A fresh Wax core over a scratch copy of an installed Wax. setup(w) changes files and the catalogue before anything loads.
local function world(setup, reuse)
    count = count + 1
    local root = reuse or ("%s/%d/Binaries/Win64/ue4ss/Mods/Wax"):format(base, count)
    local w = { root = root, mods = root .. "/mods", net = root .. "/run/net", now = 1000, notes = {}, asked = {}, checked = {}, calls = 0, runs = 0,
        listed = { ["0.2.0"] = runtime("0.2.0"), ["0.2.1"] = runtime("0.2.1") }, newest = { version = "0.2.1" }, published = {}, wax_asked = 0 }
    current = w
    if not reuse then
        local files = runtime("0.2.0")
        files["enabled.txt"] = ""
        files["mods/Mine/init.lua"] = 'return { made = "mine" }'
        files["saved/Mine.settings.lua"] = "return { volume = 3 }"
        files["run/keep"] = ""
        write_all(root, files)
        os.remove(root .. "/run/keep")
    end

    local function plan_of(version)
        local plan = { version = version, total = 0, files = {} }
        for path, text in pairs(w.listed[version]) do
            plan.files[#plan.files + 1] = { path = path, size = #text, sha256 = digest(text) }
            plan.total = plan.total + #text
        end
        table.sort(plan.files, function(a, b) return a.path < b.path end)
        return plan
    end
    w.plan_of = plan_of

    -- What the owner's tool sends with a list. A list too broken to sign gets a signature of nothing.
    local function signature_of(plan)
        local ok, text = pcall(signed_text, plan.version, plan.files)
        return sign(ok and text or "")
    end

    -- The catalogue: answers an address with a status and a body.
    function w.catalogue(address)
        if address == "/api/versions" then
            local mods = {}
            for id, entry in pairs(w.published) do mods[id] = { version = entry.version, wax = NULL, published_at = "2026-10-06T10:00:00.000Z" } end
            return 200, encode({ mods = next(mods) and mods or NULL })
        end
        if address == "/api/wax" then
            w.wax_asked = w.wax_asked + 1
            local newest = w.newest
            if w.withdrawn_after and w.wax_asked > w.withdrawn_after then newest = w.newest_then end
            if not newest then return 404, '{"error":"No version of Wax is listed."}' end
            return 200, encode({ version = newest.version, published_at = "2026-10-06T10:00:00.000Z", notes = "A fix.", needs_restart = true,
                needs_installer = newest.needs_installer or false, installer_from = newest.installer_from or NULL })
        end
        local version, rest = address:match("^/api/wax/files/([^/?]+)(.*)$")
        if version then
            local files = w.listed[version]
            if not files then return 404, '{"error":"Wax has no such version."}' end
            if rest == "" or rest == "?update=1" then
                local plan = plan_of(version)
                local signed = signature_of(plan)
                if rest ~= "" and w.plan then plan = w.plan(plan) or plan end
                if rest == "" and w.running_plan then plan = w.running_plan(plan) or plan end
                -- the owner signs what the catalogue lists, unless the test has the catalogue change the list afterwards
                local signature = w.changed_after_signing and signed or signature_of(plan)
                if w.signature then signature = w.signature(signature, version, rest) end
                plan.signature = signature or nil
                return 200, encode(plan)
            end
            local path = rest:match("^/(.+)$")
            path = path and path:gsub("%%(%x%x)", function(code) return string.char(tonumber(code, 16)) end)
            local text = path and (w.served or files)[path]
            if not text then return 404, "" end
            return 200, text
        end
        local id, mod_version, tail = address:match("^/api/mods/([^/]+)/files/([^/?]+)(.*)$")
        local entry = id and w.published[id]
        if not entry or mod_version ~= entry.version then return 404, "" end
        if tail == "?update=1" then
            local plan = { id = id, version = mod_version, total = 0, files = {} }
            for path, text in pairs(entry.files) do
                plan.files[#plan.files + 1] = { path = path, size = #text, sha256 = digest(text) }
                plan.total = plan.total + #text
            end
            plan.signature = sign(signed_text(nil, plan.files, ("mod %s %s"):format(id, mod_version)))
            return 200, encode(plan)
        end
        local text = entry.files[tail:match("^/(.+)$")]
        if not text then return 404, "" end
        return 200, text
    end

    -- The helper: does what request.txt asks, the way waxnet.dll does.
    local function serve(text)
        local broken = false
        for line in text:gmatch("[^\n]+") do
            local address, output = line:match("^([^\t]*)\t(.*)$")
            if address == "-" then
                w.asked[#w.asked + 1] = "clear " .. output
                if w.cannot_clear or not output:find("^stage/.") then
                    write(w.net .. "/" .. output .. ".status", "0 0 - the folder could not be cleared\n")
                else
                    os.execute(('rmdir /s /q "%s" >nul 2>nul'):format(win(w.net .. "/" .. output)))
                    write(w.net .. "/" .. output .. ".status", "200 0 -\n")
                end
            elseif address == "=" and not w.old_helper then
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
            elseif address == "=" then
                w.asked[#w.asked + 1] = "verify " .. output
                write(w.net .. "/" .. output .. ".status", "0 0 - this address is not allowed\n")
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
            if not text then return end
            os.remove(w.net .. "/request.txt")
            os.remove(w.net .. "/done")
            w.runs = w.runs + 1
            serve(text)
        end,
    }

    if setup then setup(w) end
    w.before = snapshot(root, { "run", "saved" })
    local Wax = t.new_wax()
    Wax.root = root
    w.Wax, w.log, w.sched = Wax, Wax.import("core.log"), Wax.import("core.sched")
    w.sched.clock = function() return w.now end
    w.storage, w.loader = Wax.import("core.storage"), Wax.import("mods.loader")
    Wax.mods, Wax.log, Wax.sched, Wax.storage = w.loader, w.log, w.sched, w.storage
    Wax.ui = { Notify = function(text, options) w.notes[#w.notes + 1] = { text = text, options = options } end }
    w.loader.sync()
    w.update = Wax.import("mods.update")
    w.update.time = function() return 1800000000 + math.floor(w.now) end
    w.update.loadlib = function(path, name)
        w.loaded_from = path
        if w.no_helper then return nil, "The specified module could not be found." end
        return name == "wax_net_ready" and w.lib.ready or w.lib.run
    end
    w.update.start()
    w.self = Wax.import("mods.selfupdate")
    w.self.start()

    function w.frame()
        w.now = w.now + 0.05
        w.loader.step()
        w.storage.step()
        w.sched.step()
    end
    function w.run(seconds)
        for _ = 1, math.floor(seconds / 0.05 + 0.5) do w.frame() end
    end
    function w.later(seconds, tail)
        w.now = w.now + seconds
        w.run(tail or 60)
    end
    function w.logged(fragment, level)
        local found = 0
        for _, entry in ipairs(w.log.since(0)) do
            if entry.message:find(fragment, 1, true) and (not level or entry.level == level) then found = found + entry.count end
        end
        return found
    end
    function w.count_asked(pattern)
        local found = 0
        for _, address in ipairs(w.asked) do
            if address:find(pattern) then found = found + 1 end
        end
        return found
    end
    function w.marker() return read(w.net .. "/wax-ready.txt") end
    return w
end

-- No marker, Wax's own files as they were, nothing announced, and the reason said once.
local function untouched(w, reason)
    t.eq(w.marker(), nil, "no marker was written")
    t.eq(snapshot(w.root, { "run", "saved" }), w.before, "nothing of the installed Wax changed")
    t.eq(#w.notes, 0, "nothing was announced")
    t.eq(w.self.state().ready, nil)
    if reason then
        t.eq(w.logged("Wax 0.2.1 could not be downloaded: " .. reason, "warn"), 1, "the log says why, once: " .. reason)
        t.eq(w.self.state().problem, "Wax could not be updated.")
    end
    t.eq(w.logged("", "error"), 0, "no errors in the log")
end

t.test("a newer version is downloaded beside the running one, checked, and marked for the next start", function()
    local w = world()
    w.run(29)
    t.eq(w.calls, 0, "nothing is asked in the first 30 seconds")
    w.run(60)
    local lines = { "wax-ready 1", "version=0.2.1", "from=0.2.0", "folder=stage/wax-0.2.1", "files=7", "top=Scripts", "top=VERSION" }
    for _, path in ipairs({ "Scripts/main.lua", "Scripts/selfswap.lua", "Scripts/wax/boot.lua", "Scripts/wax/loader.lua", "Scripts/wax/mods/selfupdate.lua",
        "Scripts/wax/mods/update.lua", "VERSION" }) do
        lines[#lines + 1] = ("file=%d %s"):format(#runtime("0.2.1")[path], path)
    end
    lines[#lines + 1] = "end"
    t.eq(w.marker(), table.concat(lines, "\n") .. "\n")
    t.ok(w.marker():find("\nfile=7 VERSION\n", 1, true))
    local staged = w.net .. "/stage/wax-0.2.1"
    for path, text in pairs(runtime("0.2.1")) do
        local top = path:match("^[^/]+")
        t.eq(read(staged .. "/" .. path), (top == "Scripts" or top == "VERSION") and text or nil, path)
    end
    for name in pairs(files_under(staged)) do
        t.ok(not name:find("%.status$") and not name:find("%.part$"), "no helper file is left in the download: " .. name)
    end
    t.eq(snapshot(w.root, { "run", "saved" }), w.before, "nothing of the running Wax changed")
    t.eq(read(w.root .. "/VERSION"), "0.2.0\r\n")
    t.eq(#w.notes, 1)
    t.eq(w.notes[1].text, "Wax 0.2.1 is ready. It is put in the next time you start ICARUS.")
    t.eq(w.notes[1].options.title, "Wax")
    t.eq(w.asked[1], "/api/wax")
    t.eq(w.asked[2], "/api/wax/files/0.2.1?update=1")
    t.eq(w.asked[3], "verify plan/wax-own.list", "the owner's signature on that list is checked before anything else is asked for")
    t.eq(w.asked[4], "/api/wax/files/0.2.0", "the files of the running version, to see which parts changed")
    t.eq(w.asked[5], "verify plan/wax-running.list", "and that list is only believed with the owner's signature too")
    t.eq(w.asked[6], "clear stage/wax-0.2.1", "the download folder is emptied before anything is fetched into it")
    t.eq(#w.checked, 2)
    t.eq(w.checked[1].list, signed_text("0.2.1", w.plan_of("0.2.1").files), "what was checked is the list every download is held against")
    t.eq(w.checked[1].signature, sign(w.checked[1].list) .. "\n")
    t.eq(w.checked[2].list, signed_text("0.2.0", w.plan_of("0.2.0").files))
    t.ok(w.checked[1].good and w.checked[2].good)
    t.eq(read(w.net .. "/plan/wax-own.list.status"), nil, "the helper's answer is taken away once it is read")
    t.eq(w.count_asked("^/api/wax/files/0%.2%.1/Scripts/"), 6)
    t.eq(w.count_asked("^/api/wax/files/0%.2%.1/VERSION$"), 1)
    t.eq(w.count_asked("^/api/wax/files/0%.2%.1/assets/") + w.count_asked("/bin/") + w.count_asked("/data/") + w.count_asked("Wax%-Import"), 0,
        "the parts that did not change are not downloaded")
    t.eq(w.asked[#w.asked], "/api/wax", "the catalogue is asked once more before the marker is written")
    t.eq(#w.asked, 6 + 7 + 1)
    for _, address in ipairs(w.asked) do t.ok(address:find("^/api/wax") or address:find("^clear stage/") or address:find("^verify plan/"), address) end
    local state = w.self.state()
    t.eq(state.ready, "0.2.1")
    t.eq(state.running, "0.2.0")
    t.eq(state.auto, true)
    t.eq(state.off, nil)
    t.eq(state.problem, nil)
    t.eq(state.checking, false)
    t.ok(state.last >= 1800001030)
    t.eq(w.logged("", "warn") + w.logged("", "error"), 0)

    -- six hours later it only asks whether that version is still the one offered
    local asked = #w.asked
    w.later(6 * 3600)
    t.eq(#w.asked, asked + 1)
    t.eq(w.asked[#w.asked], "/api/wax")
    t.eq(#w.notes, 1, "and says nothing a second time")
    t.eq(w.self.state().ready, "0.2.1")

    -- the marker is what selfswap.lua acts on at the next start
    local swapped = assert(loadfile(SWAP))({ root = w.root, print = function() end })
    t.eq(swapped.did, "swapped")
    t.eq(read(w.root .. "/VERSION"), "0.2.1\r\n")
    t.eq(read(w.root .. "/Scripts/wax/boot.lua"), 'return "boot 0.2.1"')
    t.eq(read(w.root .. "/Scripts.before-0.2.0/wax/boot.lua"), 'return "boot 0.2.0"')
    t.eq(read(w.root .. "/assets/round6.png"), "a png")
    t.eq(read(w.root .. "/mods/Mine/init.lua"), 'return { made = "mine" }')
end)

t.test("every part is downloaded when the catalogue does not know the running version", function()
    local w = world(function(w) w.listed["0.2.0"] = nil end)
    w.run(120)
    local marker = w.marker()
    t.ok(marker, "it is still marked")
    t.eq(marker:match("files=(%d+)"), "14")
    t.eq(table.concat({ marker:match("(top=[^\n]+)\n(top=[^\n]+)\n(top=[^\n]+)\n(top=[^\n]+)\n(top=[^\n]+)\n(top=[^\n]+)\n") }, " "),
        "top=Scripts top=data top=assets top=bin top=Wax-Import.ps1 top=VERSION")
    t.eq(w.count_asked("^/api/wax/files/0%.2%.1/assets/lucide/32/arrow%%20up%.png$"), 1, "each part of a path is encoded")
    local staged = files_under(w.net .. "/stage/wax-0.2.1")
    for path, text in pairs(runtime("0.2.1")) do
        t.eq(read(w.net .. "/stage/wax-0.2.1/" .. path), text, path)
        staged[path] = nil
    end
    t.eq(next(staged), nil, "and nothing else is in the download")
    t.eq(assert(loadfile(SWAP))({ root = w.root, print = function() end }).did, "swapped")
    t.eq(read(w.root .. "/bin/waxnet.dll"), "downloads")
    t.ok(exists(w.root .. "/bin.before-0.2.0"))
end)

t.test("a part that is not here as the catalogue lists it is downloaded whole", function()
    local w = world(function(w)
        os.remove(w.root .. "/assets/lucide/LICENSE.txt")
        write(w.root .. "/data/libraries.lua", "return { 'changed by hand' }")
    end)
    w.run(120)
    local marker = w.marker()
    t.ok(marker:find("\ntop=assets\n", 1, true), "assets, where a file is missing")
    t.ok(marker:find("\ntop=data\n", 1, true), "data, where a file has another size")
    t.ok(not marker:find("\ntop=bin\n", 1, true))
    t.eq(w.count_asked("^/api/wax/files/0%.2%.1/assets/"), 3)
    t.eq(read(w.net .. "/stage/wax-0.2.1/data/libraries.lua"), "return { 'libraries' }")
end)

t.test("a part the new version changes is downloaded, and one it drops a file from as well", function()
    local w = world(function(w)
        w.listed["0.2.1"] = runtime("0.2.1", { ["assets/round7.png"] = "a new png", ["bin/waxnet.dll"] = "downloads better", ["data/extra.json"] = "{}" })
    end)
    w.run(120)
    local marker = w.marker()
    for _, name in ipairs({ "Scripts", "data", "assets", "bin", "VERSION" }) do t.ok(marker:find("\ntop=" .. name .. "\n", 1, true), name) end
    t.ok(not marker:find("top=Wax-Import.ps1", 1, true))
    t.eq(read(w.net .. "/stage/wax-0.2.1/bin/waxnet.dll"), "downloads better")
    t.eq(read(w.net .. "/stage/wax-0.2.1/bin/waxco.dll"), "coroutines", "the whole part comes, not only the file that changed")

    w = world(function(w) w.listed["0.2.1"] = runtime("0.2.1", { ["assets/lucide/LICENSE.txt"] = false }) end)
    w.run(120)
    t.ok(w.marker():find("\ntop=assets\n", 1, true))
    t.eq(read(w.net .. "/stage/wax-0.2.1/assets/lucide/LICENSE.txt"), nil)
end)

t.test("the same version or an older one changes nothing", function()
    for _, version in ipairs({ "0.2.0", "0.1.9", "0.1.10", "0.2", "latest", "0.2.1-beta.1", "0.2.1+build" }) do
        local w = world(function(w)
            w.newest = { version = version }
            w.listed[version] = runtime("0.2.1")
        end)
        w.run(120)
        w.later(6 * 3600)
        t.eq(w.count_asked("^/api/wax$"), 2, version)
        t.eq(#w.asked, 2, "only the newest version was asked for: " .. version)
        t.eq(w.marker(), nil, version)
        t.eq(#w.notes, 0, version)
        t.eq(snapshot(w.root, { "run", "saved" }), w.before, version)
        t.eq(w.self.state().ready, nil)
    end
    -- nothing listed at all
    local w = world(function(w) w.newest = nil end)
    w.run(120)
    t.eq(#w.asked, 1)
    t.eq(w.marker(), nil)
    t.eq(w.self.state().problem, nil)
    t.eq(w.logged("", "warn"), 0)
end)

local function plan_case(name, reason, tamper, extra, leaves)
    t.test("no marker is written when " .. name, function()
        local w = world(function(w)
            if extra then extra(w) end
            w.plan = tamper
        end)
        w.run(120)
        untouched(w, reason)
        w.later(6 * 3600)
        untouched(w, reason)
        if not leaves then t.eq(next(files_under(w.net .. "/stage")), nil, "what was downloaded is not left behind") end
    end)
end

local function change(plan, path, with)
    for _, file in ipairs(plan.files) do
        if file.path == path then
            for key, value in pairs(with) do file[key] = value end
        end
    end
end

plan_case("a file does not match its checksum", "Scripts/wax/boot.lua does not match its checksum",
    function(plan) change(plan, "Scripts/wax/boot.lua", { sha256 = ("0"):rep(64) }) end)
plan_case("a file has another size than the list says", "VERSION does not match its checksum", function(plan)
    change(plan, "VERSION", { size = 8 })
    plan.total = plan.total + 1
end)
plan_case("a file arrives changed on the way", "Scripts/main.lua does not match its checksum", nil, function(w)
    w.served = runtime("0.2.1", { ["Scripts/main.lua"] = 'os.execute("anything")' })
end)
plan_case("a listed file is missing on the server", "Scripts/extra.lua was not downloaded (the catalogue answered 404)", function(plan)
    plan.files[#plan.files + 1] = { path = "Scripts/extra.lua", size = 8, sha256 = digest("return 1") }
    plan.total = plan.total + 8
end)
plan_case("a file arrives cut short", "Scripts/wax/loader.lua is missing or cut short", nil, function(w)
    w.status = function(output, body)
        if output:find("loader.lua", 1, true) then
            write(w.net .. "/" .. output, body:sub(1, 3))
            return ("200 %d %s\n"):format(#body, digest(body))
        end
    end
end)
plan_case("a Lua file does not compile", "Scripts/wax/boot.lua does not compile", nil, function(w)
    w.listed["0.2.1"] = runtime("0.2.1", { ["Scripts/wax/boot.lua"] = "return return" })
end)
plan_case("a Lua file is compiled code", "Scripts/wax/boot.lua does not compile", nil, function(w)
    w.listed["0.2.1"] = runtime("0.2.1", { ["Scripts/wax/boot.lua"] = string.dump(function() return 1 end) })
end)
plan_case("a file the catalogue does not list turns up in the download", "the download holds a file the catalogue does not list: Scripts/wax/extra.lua",
    nil, function(w) w.leave = { ["stage/wax-0.2.1/Scripts/wax/extra.lua"] = "return 'not listed'" } end, true)
plan_case("the download folder cannot be emptied first", "the folder the download goes to could not be emptied", nil, function(w)
    w.cannot_clear = true
    write(w.net .. "/stage/wax-0.2.1/Scripts/left over.lua", "return 'an extra file'")
end, true)
plan_case("the list is for another version", "the catalogue answered for another version", function(plan) plan.version = "0.2.2" end)
plan_case("the list is empty", "the catalogue listed no files", function(plan) plan.files, plan.total = NONE, 0 end)
plan_case("the sizes do not add up to the total", "its sizes do not add up", function(plan) plan.total = plan.total + 5 end)
plan_case("a file is listed twice", "it lists the same file twice: Scripts/Main.lua", function(plan)
    plan.files[#plan.files + 1] = { path = "Scripts/Main.lua", size = 8, sha256 = digest("return 1") }
    plan.total = plan.total + 8
end)
plan_case("a file has no checksum", "it gives no checksum for VERSION", function(plan) change(plan, "VERSION", { sha256 = "abc" }) end)
plan_case("there are more than 6000 files", "it has more than 6000 files", function(plan)
    for index = 1, 6000 do plan.files[#plan.files + 1] = { path = ("assets/more/%d.png"):format(index), size = 0, sha256 = digest("") } end
end)
plan_case("it is larger than 64 MB in all", "it is larger than 64 MB", function(plan)
    plan.files[#plan.files + 1] = { path = "assets/big.png", size = 64 * 1024 * 1024, sha256 = digest("") }
    plan.total = plan.total + 64 * 1024 * 1024
end)
for _, needed in ipairs({ "VERSION", "Scripts/main.lua", "Scripts/selfswap.lua", "Scripts/wax/boot.lua", "Scripts/wax/loader.lua",
    "Scripts/wax/mods/selfupdate.lua", "bin/waxnet.dll" }) do
    plan_case("the list has no " .. needed, "it has no " .. needed, function(plan)
        for index, file in ipairs(plan.files) do
            if file.path == needed then
                plan.total = plan.total - file.size
                table.remove(plan.files, index)
                break
            end
        end
    end)
end
plan_case("its main.lua does not run selfswap.lua", "its main.lua does not run selfswap.lua, so it could not be taken back", nil, function(w)
    w.listed["0.2.1"] = runtime("0.2.1", { ["Scripts/main.lua"] = 'return "main without it"' })
end)
plan_case("its VERSION file says another version", "its VERSION file says another version", nil, function(w)
    w.listed["0.2.1"] = runtime("0.2.1", { ["VERSION"] = "0.2.5\r\n" })
end)

t.test("no marker is written when the catalogue takes the version back while it is downloaded", function()
    for _, now in ipairs({ { version = "0.2.0" }, { version = "0.2.1", needs_installer = true }, { version = "0.2.2" }, false }) do
        local w = world(function(w) w.withdrawn_after, w.newest_then = 1, now or nil end)
        w.run(120)
        untouched(w, "the catalogue stopped offering it while it was downloaded")
        t.eq(w.asked[#w.asked - 1], "/api/wax", "the second question is what stopped it")
        t.eq(w.asked[#w.asked], "clear stage/wax-0.2.1")
        t.eq(next(files_under(w.net .. "/stage")), nil, "what was downloaded is not left behind")
    end
end)

t.test("no marker is written, and nothing is fetched, when the list holds a file outside Wax's own folders", function()
    local paths = { "mods/Evil/init.lua", "mods/RecipeBrowser/init.lua", "saved/wax.mods.lua", "run/in/0.lua", "run/net/wax-ready.txt", "enabled.txt", "dev.txt",
        "../evil.lua", "Scripts/../../evil.lua", "Scripts/../mods/Evil/init.lua", "/Scripts/abs.lua", "C:/Scripts/abs.lua", "Scripts\\evil.lua", "Scripts//evil.lua",
        "scripts/evil.lua", "SCRIPTS/evil.lua", "Mods/Evil/init.lua", "extra/tool.lua", "notes.txt", "main.lua", "Scripts", "Scripts/", "Scripts/tool.exe",
        "Scripts/run.bat", "Scripts/data.json", "Scripts/noending", "assets/helper.dll", "data/helper.dll", "bin/script.lua", "bin/tool.exe", "Wax-Import.ps1/x.lua",
        "VERSION/x.lua", "Scripts/nul.lua", "Scripts/trail./x.lua", "Scripts/caf\195\169.lua", "Scripts/semi;colon.lua", "Scripts/a..b.lua", "ue4ss/UE4SS.dll",
        "../../UE4SS.dll", "../../../dwmapi.dll", "" }
    local w = world()
    for index, path in ipairs(paths) do
        local version = "0.2." .. index
        w.newest = { version = version }
        w.listed[version] = runtime(version)
        w.plan = function(plan)
            plan.files[#plan.files + 1] = { path = path, size = 8, sha256 = digest("return 1") }
            plan.total = plan.total + 8
        end
        w.later(index == 1 and 0 or 6 * 3600, 120)
        t.eq(w.logged(("Wax %s could not be downloaded: it holds a file that is not part of Wax"):format(version), "warn"), 1, ("%q"):format(path))
        t.eq(w.marker(), nil, ("%q"):format(path))
        t.eq(snapshot(w.root, { "run", "saved" }), w.before, ("%q"):format(path))
    end
    t.eq(w.count_asked("^/api/wax/files/[%d.]+/."), 0, "not one file was fetched for a list that is refused")
    t.eq(next(files_under(w.net .. "/stage")), nil)
    t.eq(#w.notes, 0)
    t.eq(w.logged("", "error"), 0)
    t.eq(read(w.root .. "/mods/Evil/init.lua"), nil)
    t.eq(read(w.root .. "/run/evil.lua"), nil)
end)

t.test("every file of this workspace's own runtime passes the rules for a download", function()
    local real = {}
    for _, folder in ipairs({ "Scripts", "data", "assets", "bin" }) do
        for name in pairs(files_under(here .. "/wax/runtime/" .. folder)) do real[#real + 1] = folder .. "/" .. name end
    end
    real[#real + 1], real[#real + 2] = "VERSION", "Wax-Import.ps1"
    table.sort(real)
    t.ok(#real > 1000, #real .. " files")
    local w = world(function(w)
        w.plan = function()
            -- the list is refused at its last entry, so every entry before it was accepted
            local plan = { version = "0.2.1", files = {} }
            for index, path in ipairs(real) do plan.files[index] = { path = path, size = 1, sha256 = digest(path) } end
            plan.files[#real + 1] = { path = "mods/the last entry.lua", size = 1, sha256 = digest("") }
            return plan
        end
    end)
    w.run(120)
    t.eq(w.logged("Wax 0.2.1 could not be downloaded: it holds a file that is not part of Wax: mods/the last entry.lua", "warn"), 1)
    t.eq(w.count_asked("^clear "), 0)
end)

t.test("with updates of Wax switched off no request is made", function()
    local w = world(function(w) write(w.root .. "/saved/wax.selfupdate.lua", "return { auto = false }") end)
    t.eq(w.self.state().auto, false, "the setting is read from its own file")
    w.run(120)
    w.later(6 * 3600)
    w.later(6 * 3600)
    t.eq(#w.asked, 0, "nothing was asked of the catalogue")
    t.eq(w.calls, 0, "and the helper was not called")
    t.eq(w.loaded_from, nil, "or even loaded")
    t.eq(w.marker(), nil)
    t.eq(#w.notes, 0)
    t.eq(w.self.check_now(), false)
    t.eq(w.update.state().auto, true, "this setting of its own is apart from the Mods page's switches")

    -- switching it on asks soon, and the switch is remembered
    w.self.set_auto(true)
    w.run(120)
    t.eq(w.self.state().ready, "0.2.1")
    t.ok(read(w.root .. "/saved/wax.selfupdate.lua"):find('%["auto"%] = true'))
    t.ok(not read(w.root .. "/saved/wax.updates.lua"):find("told", 1, true), "it is not kept in the mod updater's file")
end)

t.test("switching updates of Wax off takes back a version that is waiting", function()
    local w = world()
    w.run(120)
    t.ok(w.marker())
    w.self.set_auto(false)
    t.eq(w.marker(), nil, "the marker is gone, so the next start changes nothing")
    t.eq(w.self.state().ready, nil)
    t.eq(assert(loadfile(SWAP))({ root = w.root, print = function() end }).did, "nothing")
    t.eq(read(w.root .. "/VERSION"), "0.2.0\r\n")
    local asked = #w.asked
    w.later(6 * 3600)
    t.eq(#w.asked, asked)
    t.ok(read(w.root .. "/saved/wax.selfupdate.lua"):find('%["auto"%] = false'))
end)

t.test("Wax's own update does not hang on the mod updater's general value, which no control changes any more", function()
    local w = world(function(w) write(w.root .. "/saved/wax.updates.lua", "return { auto = false }") end)
    t.eq(w.update.state().auto, false, "the general value was kept switched off")
    w.run(120)
    t.ok(w.count_asked("^/api/wax") > 0, "Wax was asked about all the same")
    t.eq(w.self.state().ready, "0.2.1", "and the newer version was fetched")
    t.eq(w.self.state().auto, true, "its own value is on unless it was switched off")
    -- neither that value nor one mod's own Auto Update takes back what is waiting
    w.update.set_auto(false)
    w.update.set_auto("RecipeBrowser", false)
    t.ok(w.marker(), "the marker is still there")
    t.eq(w.self.state().ready, "0.2.1")
    -- and with Wax's own value switched off, switching those on fetches nothing
    w = world(function(w) write(w.root .. "/saved/wax.selfupdate.lua", "return { auto = false }") end)
    w.update.set_auto(true)
    w.run(120)
    w.later(6 * 3600)
    t.eq(w.count_asked("^/api/wax"), 0, "nothing was asked about Wax")
    t.eq(w.marker(), nil)
end)

t.test("with looking for updates switched off nothing is asked about Wax, the helper is not loaded and no request file is written", function()
    local w = world(function(w) write(w.root .. "/saved/wax.updates.lua", "return { look = false }") end)
    w.run(120)
    w.later(6 * 3600)
    w.later(6 * 3600)
    t.eq(#w.asked, 0, "nothing was asked of the catalogue or of the helper")
    t.eq(w.calls, 0)
    t.eq(w.loaded_from, nil, "the helper was not even loaded")
    t.eq(next(files_under(w.root .. "/run")), nil, "no request file, and nothing else, was written")
    t.eq(w.marker(), nil)
    t.eq(w.self.check_now(), false)
    t.eq(#w.notes, 0)
    t.eq(w.logged("", "warn") + w.logged("", "error"), 0)
    -- switched on, Wax is asked about soon and the newer version is fetched
    w.update.set_looking(true)
    w.run(120)
    t.eq(w.self.state().ready, "0.2.1")

    -- what the start of the game did is still said, from the files it left, and old folders wait for the helper
    w = world(function(w)
        write(w.root .. "/saved/wax.updates.lua", "return { look = false }")
        write(w.net .. "/wax-bad.txt", "version=0.2.1\nwhy=start\ntries=1\n")
        write(w.root .. "/data.before-0.1.8/libraries.lua", "return {}")
        write(w.net .. "/wax-old.txt", "root data.before-0.1.8\n")
    end)
    w.run(120)
    t.eq(w.notes[1].text, "Wax 0.2.1 did not start here, so the version before was put back.")
    t.eq(#w.notes, 1)
    t.eq(w.calls, 0)
    t.eq(w.loaded_from, nil)
    t.ok(exists(w.root .. "/data.before-0.1.8"))
    t.eq(read(w.net .. "/request.txt"), nil)
end)

t.test("switching looking for updates off takes back a version of Wax that is waiting", function()
    local w = world()
    w.run(120)
    t.ok(w.marker())
    w.update.set_looking(false)
    t.eq(w.marker(), nil, "the marker is gone, so the next start changes nothing")
    t.eq(w.self.state().ready, nil)
    t.eq(assert(loadfile(SWAP))({ root = w.root, print = function() end }).did, "nothing")
    t.eq(w.logged("the Wax update that was waiting is not put in: updates of Wax were switched off"), 1)
    local asked = w.count_asked("^/api/wax")
    w.later(6 * 3600)
    t.eq(w.count_asked("^/api/wax"), asked, "and Wax is not asked about again")
    w.update.set_looking(true)
    w.run(120)
    t.eq(w.self.state().ready, "0.2.1", "switched back on, it is fetched again")
end)

t.test("a version that needs the installer is only announced", function()
    local w = world(function(w) w.newest = { version = "0.2.1", needs_installer = true } end)
    w.run(120)
    t.eq(#w.asked, 1, "only the newest version was asked for")
    t.eq(w.asked[1], "/api/wax")
    t.eq(#w.notes, 1)
    t.eq(w.notes[1].text, "Wax 0.2.1 is out. Run Update Wax.cmd to get it.")
    t.eq(w.marker(), nil)
    t.eq(snapshot(w.root, { "run", "saved" }), w.before)
    t.eq(next(files_under(w.net .. "/stage")), nil)
    t.eq(w.self.state().installer, "0.2.1")
    t.eq(w.self.state().ready, nil)
    w.later(6 * 3600)
    t.eq(#w.notes, 1, "it is said once")
    t.eq(#w.asked, 2)
    -- and not again in the next session
    local again = world(nil, w.root)
    again.newest = { version = "0.2.1", needs_installer = true }
    again.run(120)
    t.eq(#again.notes, 0)
    t.eq(again.self.state().installer, "0.2.1")
    t.eq(again.marker(), nil)
    -- a later one is said
    again.newest = { version = "0.2.2", needs_installer = true }
    again.later(6 * 3600)
    t.eq(#again.notes, 1)
    t.eq(again.notes[1].text, "Wax 0.2.2 is out. Run Update Wax.cmd to get it.")
end)

t.test("a version after one that needed the installer needs it too, until that one is installed", function()
    local w = world(function(w)
        w.newest = { version = "0.3.1", installer_from = "0.3.0" }
        w.listed["0.3.1"] = runtime("0.3.1")
    end)
    w.run(120)
    t.eq(#w.asked, 1)
    t.eq(w.notes[1].text, "Wax 0.3.1 is out. Run Update Wax.cmd to get it.")
    t.eq(w.marker(), nil)

    w = world(function(w)
        w.newest = { version = "0.2.1", installer_from = "0.2.0" }
    end)
    w.run(120)
    t.eq(w.self.state().ready, "0.2.1", "the installer version is the one that runs, so this one is downloaded")
    t.eq(w.notes[1].text, "Wax 0.2.1 is ready. It is put in the next time you start ICARUS.")
end)

t.test("a copy with dev.txt, or without a VERSION file, never asks and never downloads", function()
    for _, case in ipairs({ { "dev", function(w) write(w.root .. "/dev.txt", "") end },
        { "no version", function(w) os.remove(w.root .. "/VERSION") end },
        { "no version", function(w) write(w.root .. "/VERSION", "a development copy\r\n") end } }) do
        local w = world(function(w)
            case[2](w)
            write(w.net .. "/wax-trial.txt", "version=0.2.0\nfrom=0.1.9\nstate=trial\n")
            write(w.net .. "/wax-old.txt", "root Scripts.before-0.1.9\n")
            write(w.net .. "/wax-bad.txt", "version=0.2.1\nwhy=start\ntries=1\n")
            write(w.root .. "/Scripts.before-0.1.9/main.lua", "return 1")
        end)
        local run_before = snapshot(w.root .. "/run")
        w.run(120)
        w.later(6 * 3600)
        t.eq(w.self.state().off, case[1])
        t.eq(#w.asked, 0, case[1])
        t.eq(w.calls, 0, case[1])
        t.eq(w.marker(), nil)
        t.eq(#w.notes, 0)
        t.eq(snapshot(w.root, { "run", "saved" }), w.before)
        t.eq(snapshot(w.root .. "/run"), run_before, "nothing under run was read into action or removed")
        for _ = 1, 300 do t.eq(w.self.settle(), false) end
        t.ok(read(w.net .. "/wax-trial.txt"), "the trial file is not its to remove")
        t.eq(w.self.check_now(), false)
        w.self.set_auto(true)
        w.run(120)
        t.eq(#w.asked, 0)
    end
end)

t.test("this workspace's own runtime is such a copy", function()
    t.eq(read("wax/runtime/VERSION"), nil)
    t.ok(read("wax/runtime/dev.txt"))
    local Wax = t.new_wax()
    Wax.import("core.storage").directory = nil
    local own = Wax.import("mods.selfupdate")
    own.start()
    t.eq(own.state().off, "no version")
    t.eq(own.settle(), false)
end)

t.test("the version put in at this start is kept once whole frames have run", function()
    local w = world(function(w) write(w.net .. "/wax-trial.txt", "version=0.2.0\nfrom=0.1.9\nstate=trial\n") end)
    for frame = 1, 119 do
        t.eq(w.self.settle(), true, "frame " .. frame)
    end
    t.ok(read(w.net .. "/wax-trial.txt"), "the trial file stays for 119 frames")
    t.eq(w.self.settle(), false)
    t.eq(read(w.net .. "/wax-trial.txt"), nil, "and is removed at the 120th")
end)

t.test("a version that did not start here is said once, and not downloaded again", function()
    local w = world(function(w) write(w.net .. "/wax-bad.txt", "version=0.2.1\nwhy=start\ntries=1\n") end)
    w.run(120)
    t.eq(#w.notes, 1)
    t.eq(w.notes[1].text, "Wax 0.2.1 did not start here, so the version before was put back.")
    t.eq(w.notes[1].options.kind, "warn")
    t.eq(#w.asked, 1, "the catalogue still offers it, and it is left there")
    t.eq(w.marker(), nil)
    w.later(6 * 3600)
    t.eq(#w.notes, 1)
    t.eq(#w.asked, 2)
    -- the next session says nothing
    local again = world(nil, w.root)
    again.run(120)
    t.eq(#again.notes, 0)
    t.eq(again.marker(), nil)
    -- a higher version is tried
    again.newest = { version = "0.2.2" }
    again.listed["0.2.2"] = runtime("0.2.2")
    again.later(6 * 3600, 120)
    t.eq(again.self.state().ready, "0.2.2")
    t.eq(again.notes[1].text, "Wax 0.2.2 is ready. It is put in the next time you start ICARUS.")
    -- with updates switched off it is still said, from the files on disk alone
    w = world(function(w)
        write(w.net .. "/wax-bad.txt", "version=0.2.1\nwhy=start\ntries=1\n")
        write(w.root .. "/saved/wax.selfupdate.lua", "return { auto = false }")
    end)
    w.run(120)
    t.eq(w.notes[1].text, "Wax 0.2.1 did not start here, so the version before was put back.")
    t.eq(#w.asked, 0)
end)

t.test("a version whose folders could not be moved is left to the installer", function()
    local w = world(function(w) write(w.net .. "/wax-bad.txt", "version=0.2.1\nwhy=move\ntries=2\n") end)
    w.run(120)
    t.eq(#w.notes, 1)
    t.eq(w.notes[1].text, "Wax 0.2.1 is out. Run Update Wax.cmd to get it.")
    t.eq(w.marker(), nil)
    t.eq(#w.asked, 1)
    t.eq(w.self.state().installer, "0.2.1")
    -- after one failed try the marker is still there, and it waits for the second
    w = world(function(w)
        write(w.net .. "/wax-bad.txt", "version=0.2.1\nwhy=move\ntries=1\n")
        write(w.net .. "/wax-ready.txt", "wax-ready 1\nversion=0.2.1\nfrom=0.2.0\nfolder=stage/wax-0.2.1\nfiles=1\ntop=VERSION\nfile=7 VERSION\nend\n")
        write(w.net .. "/stage/wax-0.2.1/VERSION", "0.2.1\r\n")
    end)
    w.run(120)
    t.eq(#w.notes, 0)
    t.eq(#w.asked, 1)
    t.ok(w.marker())
    t.eq(w.self.state().ready, "0.2.1")
end)

t.test("a marker for a version the catalogue took back is removed", function()
    local function staged(w)
        write(w.net .. "/wax-ready.txt", "wax-ready 1\nversion=0.2.1\nfrom=0.2.0\nfolder=stage/wax-0.2.1\nfiles=1\ntop=VERSION\nfile=7 VERSION\nend\n")
        write(w.net .. "/stage/wax-0.2.1/VERSION", "0.2.1\r\n")
    end
    for _, newest in ipairs({ { version = "0.2.0" }, false, { version = "0.2.1", needs_installer = true } }) do
        local w = world(function(w)
            staged(w)
            w.newest = newest or nil
        end)
        w.run(120)
        t.eq(w.marker(), nil)
        t.eq(next(files_under(w.net .. "/stage")), nil, "and what was downloaded for it")
        t.eq(w.self.state().ready, nil)
        t.eq(snapshot(w.root, { "run", "saved" }), w.before)
    end
    -- a higher version replaces it
    local w = world(function(w)
        staged(w)
        w.newest = { version = "0.2.2" }
        w.listed["0.2.2"] = runtime("0.2.2")
    end)
    w.run(120)
    t.ok(w.marker():find("version=0.2.2\n", 1, true))
    t.eq(next(files_under(w.net .. "/stage/wax-0.2.1")), nil)
    -- when the catalogue cannot be reached the marker stays
    w = world(function(w)
        staged(w)
        w.offline = true
    end)
    w.run(120)
    t.ok(w.marker())
    t.eq(w.self.state().problem, "Updates of Wax could not be checked.")
end)

t.test("when the catalogue cannot be reached it says so once, and tries again at the next check", function()
    local w = world(function(w) w.offline = true end)
    w.run(120)
    t.eq(w.self.state().problem, "Updates of Wax could not be checked.")
    t.eq(w.self.state().last, 0, "a check that failed is not a check")
    t.eq(w.logged("could not check for a newer Wax: the newest version of Wax: no connection (12007)", "warn"), 1)
    w.later(6 * 3600)
    t.eq(w.count_asked("^/api/wax$"), 2)
    t.eq(w.logged("could not check for a newer Wax", "warn"), 1)
    t.eq(w.marker(), nil)
    w.offline = false
    w.later(6 * 3600, 120)
    t.eq(w.self.state().ready, "0.2.1")
    t.eq(w.self.state().problem, nil)

    w = world(function(w) w.catalogue = function() return 200, "<html>not json</html>" end end)
    w.run(120)
    t.eq(w.logged("could not check for a newer Wax: the newest version of Wax: the answer could not be read", "warn"), 1)
    t.eq(w.marker(), nil)
end)

t.test("without the helper nothing is asked and nothing is written", function()
    local w = world(function(w) w.no_helper = true end)
    w.run(120)
    w.later(7 * 3600)
    t.eq(w.self.state().stopped, true)
    t.eq(w.marker(), nil)
    t.eq(read(w.net .. "/request.txt"), nil)
    t.eq(w.logged("", "error"), 0)
    t.eq(w.logged("bin/waxnet.dll could not be loaded", "warn"), 1)
    t.eq(w.self.check_now(), false)
end)

t.test("what start-up left for later is deleted: older sets of folders and used download folders", function()
    local w = world(function(w)
        w.newest = nil
        write(w.root .. "/Scripts.before-0.1.8/main.lua", "return 'older'")
        write(w.root .. "/Scripts.before-0.1.8/wax/boot.lua", "return 'older'")
        write(w.root .. "/VERSION.before-0.1.8", "0.1.8\r\n")
        write(w.root .. "/bin.failed-0.1.9/waxnet.dll", "a bad one")
        write(w.root .. "/Scripts.before-0.1.9/main.lua", "return 'the kept set'")
        write(w.net .. "/stage/wax-0.2.0/Scripts/left.lua", "return 1")
        write(w.net .. "/wax-old.txt", table.concat({ "stage wax-0.2.0", "root Scripts.before-0.1.8", "root VERSION.before-0.1.8", "root bin.failed-0.1.9",
            "root gone.before-0.1.8", "root mods", "root saved", "root Scripts", "root VERSION", "root ../../UE4SS.dll", "root mods/Mine.before-0.1.8",
            "root mods.before-0.1.8", "root Scripts.kept-0.1.8", "stage ../../mods", "stage wax-0.2.0/../../../mods", "other thing", "" }, "\n"))
    end)
    w.run(120)
    t.ok(not exists(w.root .. "/Scripts.before-0.1.8"), "the older set of Scripts is gone")
    t.ok(not exists(w.root .. "/VERSION.before-0.1.8"))
    t.ok(not exists(w.root .. "/bin.failed-0.1.9"))
    t.eq(next(files_under(w.net .. "/stage")), nil, "nothing is left under the download folder")
    t.eq(read(w.root .. "/Scripts.before-0.1.9/main.lua"), "return 'the kept set'", "the set that was not listed stays")
    t.eq(read(w.net .. "/wax-old.txt"), nil, "the list is done")
    t.eq(read(w.root .. "/mods/Mine/init.lua"), 'return { made = "mine" }')
    t.eq(read(w.root .. "/saved/Mine.settings.lua"), "return { volume = 3 }")
    t.eq(read(w.root .. "/Scripts/main.lua"), MAIN:format("0.2.0"))
    t.eq(read(w.root .. "/VERSION"), "0.2.0\r\n")
    for _, address in ipairs(w.asked) do t.ok(address == "/api/wax" or address:find("^clear stage/wax%-0%.2%.0$") or address:find("^clear stage/old%-%d+%-%d+$"), address) end
    t.eq(w.count_asked("^clear stage/old%-"), 4, "each folder is handed to the helper, which deletes it off the game thread")

    -- with updates switched off this still happens, and still without a request to the catalogue
    w = world(function(w)
        write(w.root .. "/saved/wax.selfupdate.lua", "return { auto = false }")
        write(w.root .. "/data.before-0.1.8/libraries.lua", "return {}")
        write(w.net .. "/wax-old.txt", "root data.before-0.1.8\n")
    end)
    w.run(120)
    t.ok(not exists(w.root .. "/data.before-0.1.8"))
    t.eq(w.count_asked("^/api/"), 0)

    -- what cannot be deleted now stays on the list
    w = world(function(w)
        w.newest, w.cannot_clear = nil, true
        write(w.root .. "/data.before-0.1.8/libraries.lua", "return {}")
        write(w.root .. "/VERSION.before-0.1.8", "0.1.8\r\n")
        write(w.net .. "/wax-old.txt", "root data.before-0.1.8\nroot VERSION.before-0.1.8\n")
    end)
    w.run(120)
    t.eq(read(w.net .. "/wax-old.txt"), "root data.before-0.1.8\n")
    t.ok(exists(w.root .. "/data.before-0.1.8"))
end)

t.test("a download folder that a waiting marker uses is not deleted", function()
    local w = world(function(w)
        write(w.net .. "/wax-ready.txt", "wax-ready 1\nversion=0.2.1\nfrom=0.2.0\nfolder=stage/wax-0.2.1\nfiles=1\ntop=VERSION\nfile=7 VERSION\nend\n")
        write(w.net .. "/stage/wax-0.2.1/VERSION", "0.2.1\r\n")
        write(w.net .. "/wax-old.txt", "stage wax-0.2.1\n")
    end)
    w.run(120)
    t.eq(read(w.net .. "/stage/wax-0.2.1/VERSION"), "0.2.1\r\n")
    t.ok(w.marker())
end)

t.test("mods and Wax are updated through the one helper without getting in each other's way", function()
    local w = world(function(w)
        w.newest = nil
        write(w.mods .. "/Listed/init.lua", 'return { made = "old" }')
        write(w.mods .. "/Listed/mod.lua", 'return { name = "Listed Mod", version = "1.0.0" }')
        write(w.mods .. "/Listed/wax.origin", "id=Listed\nversion=1.0.0\n")
        w.published.Listed = { version = "1.0.0", files = {} }
    end)
    w.run(120)
    t.eq(#w.notes, 0)
    w.published.Listed = { version = "1.1.0", files = { ["init.lua"] = 'return { made = "new" }', ["mod.lua"] = 'return { name = "Listed Mod", version = "1.1.0" }' } }
    w.newest = { version = "0.2.1" }
    w.busy = 4
    t.eq(w.update.check_now(), true)
    t.eq(w.self.check_now(), true)
    w.run(200)
    t.eq(w.loader.get("Listed").exports.made, "new", "the mod was updated")
    t.eq(w.self.state().ready, "0.2.1", "and the new Wax is waiting")
    local texts = {}
    for _, shown in ipairs(w.notes) do texts[#texts + 1] = shown.text end
    table.sort(texts)
    t.eq(table.concat(texts, " | "), "Listed Mod was updated to 1.1.0. | Wax 0.2.1 is ready. It is put in the next time you start ICARUS.")
    t.eq(w.logged("", "warn") + w.logged("", "error"), 0)
end)

t.test("files are handled one a frame, and between checks nothing is read or written", function()
    local w = world(function(w) w.listed["0.2.0"] = nil end)
    w.loader.set_watching(false)
    local most, frames_with = 0, 0
    for _ = 1, 120 / 0.05 do
        w.now = w.now + 0.05
        w.loader.step()
        w.storage.step()
        local before = opens
        w.sched.step()
        local used = opens - before
        if used > 0 then frames_with = frames_with + 1 end
        if used > most then most = used end
    end
    t.eq(w.self.state().ready, "0.2.1")
    t.eq(most, 1, "never more than one file opened in a frame")
    t.ok(frames_with > 40, "the work was spread over many frames: " .. frames_with)
    local before, calls = opens, w.calls
    w.run(3600)
    t.eq(opens - before, 0, "no file was opened in an hour of frames")
    t.eq(w.calls, calls, "and the helper was not called")
end)

local NOT_SIGNED = "the catalogue gives no signature for the list of its files"
local NOT_OURS = "the list of its files is not signed with Wax's key (the signature does not match)"

-- Nothing is fetched and nothing is marked, with the reason said once. setup(w) makes the signature of the new version's list bad.
local function signature_case(name, reason, setup, checks)
    t.test("no marker is written when " .. name, function()
        local w = world(setup)
        w.run(120)
        untouched(w, reason)
        t.eq(w.count_asked("^/api/wax/files/0%.2%.1/"), 0, "not one file was fetched")
        t.eq(w.count_asked("^/api/wax/files/0%.2%.0"), 0, "and the running version was not asked about")
        t.eq(w.count_asked("^clear "), 0, "and the download folder was not touched")
        t.eq(w.count_asked("^verify plan/wax%-own%.list$"), checks, "times the helper was asked")
        t.eq(next(files_under(w.net .. "/stage")), nil)
        w.later(6 * 3600)
        untouched(w, reason)
        t.eq(assert(loadfile(SWAP))({ root = w.root, print = function() end }).did, "nothing", "and the next start changes nothing")
    end)
end

-- Gives the new version's list another signature and leaves the running version's as it is.
local function with_signature(make)
    return function(w)
        w.signature = function(signature, version, rest)
            if rest == "" then return signature end
            return make(w, version, signature)
        end
    end
end

signature_case("the list of files comes without a signature", NOT_SIGNED, with_signature(function() return false end), 0)
signature_case("the signature is empty in the answer", NOT_SIGNED, with_signature(function() return NULL end), 0)
signature_case("the signature was made with another key", NOT_OURS, with_signature(function(w, version)
    return sign(signed_text(version, w.plan_of(version).files), "someone else")
end), 1)
signature_case("the signature is the one of another version", NOT_OURS, with_signature(function(w)
    return sign(signed_text("0.2.0", w.plan_of("0.2.0").files))
end), 1)
signature_case("the signature is over the same files under another version number", NOT_OURS, with_signature(function(w)
    return sign(signed_text("0.2.2", w.plan_of("0.2.1").files))
end), 1)
signature_case("this copy of the helper was built without the owner's key", "the list of its files is not signed with Wax's key (this build has no signing key)",
    function(w) w.no_key = true end, 1)
signature_case("the helper is one from before signatures", "the list of its files is not signed with Wax's key (this address is not allowed)",
    function(w) w.old_helper = true end, 1)
signature_case("the helper answers for a list of another size", "the helper checked another list than the one written for it", function(w)
    w.verify = function() return ("200 5 %s\n"):format(digest("other")) end
end, 1)
signature_case("the helper says nothing and an answer from an earlier check is still there", "the list of its files is not signed with Wax's key (no answer)", function(w)
    local text = signed_text("0.2.1", w.plan_of("0.2.1").files)
    write(w.net .. "/plan/wax-own.list.status", ("200 %d %s\n"):format(#text, digest(text)))
    w.verify = function() return nil end
end, 1)

t.test("no marker is written when the signature is not 64 bytes in base64", function()
    for _, odd in ipairs({ "", "abc", ("A"):rep(88), ("A"):rep(85) .. "==", ("A"):rep(87) .. "==", ("A"):rep(84) .. "!A==", ("A"):rep(86) .. "\n=", 64, { "a" } }) do
        local w = world(with_signature(function() return odd end))
        w.run(120)
        untouched(w, NOT_SIGNED)
        t.eq(#w.checked, 0, "the helper is not asked about it")
        t.eq(w.count_asked("^/api/wax/files/0%.2%.1/"), 0)
    end
end)

local EVIL = 'os.execute("anything")'

-- Changes what the list says of one file to fit another content.
local function swap(plan, path, text)
    for _, file in ipairs(plan.files) do
        if file.path == path then
            plan.total = plan.total - file.size + #text
            file.size, file.sha256 = #text, digest(text)
        end
    end
end

-- The catalogue hands out a list that is not the one the owner signed, with files that fit its own list.
local function takeover_case(name, tamper, served)
    t.test("no marker is written when the catalogue " .. name .. " after the owner signed the list", function()
        local w = world(function(w)
            w.changed_after_signing = true
            w.plan = tamper
            w.served = served
        end)
        w.run(120)
        untouched(w, NOT_OURS)
        t.eq(#w.checked, 1)
        t.eq(w.checked[1].good, false)
        t.eq(w.count_asked("^/api/wax/files/0%.2%.1/"), 0, "not one file was fetched")
        t.eq(next(files_under(w.net .. "/stage")), nil)
        w.later(6 * 3600)
        untouched(w, NOT_OURS)
    end)
end

takeover_case("swaps a file for its own", function(plan) swap(plan, "Scripts/wax/boot.lua", EVIL) end, runtime("0.2.1", { ["Scripts/wax/boot.lua"] = EVIL }))
takeover_case("swaps the helper for its own", function(plan) swap(plan, "bin/waxnet.dll", "one that accepts anything") end,
    runtime("0.2.1", { ["bin/waxnet.dll"] = "one that accepts anything" }))
takeover_case("adds a file", function(plan)
    plan.files[#plan.files + 1] = { path = "Scripts/wax/extra.lua", size = #EVIL, sha256 = digest(EVIL) }
    plan.total = plan.total + #EVIL
end, runtime("0.2.1", { ["Scripts/wax/extra.lua"] = EVIL }))
takeover_case("leaves a file out", function(plan)
    for index, file in ipairs(plan.files) do
        if file.path == "data/libraries.lua" then
            plan.total = plan.total - file.size
            table.remove(plan.files, index)
            break
        end
    end
end)
takeover_case("changes one digit of a checksum", function(plan)
    for _, file in ipairs(plan.files) do
        if file.path == "assets/round6.png" then file.sha256 = (file.sha256:sub(1, 1) == "0" and "1" or "0") .. file.sha256:sub(2) end
    end
end)
takeover_case("moves a file", function(plan)
    for _, file in ipairs(plan.files) do
        if file.path == "data/libraries.lua" then file.path = "Scripts/libraries.lua" end
    end
end)

t.test("the signature is what stops a swapped file: the same list, signed by the owner, goes through", function()
    local w = world(function(w)
        w.plan = function(plan) swap(plan, "Scripts/wax/boot.lua", EVIL) end
        w.served = runtime("0.2.1", { ["Scripts/wax/boot.lua"] = EVIL })
    end)
    w.run(120)
    t.ok(w.marker(), "every other check passes for it")
    t.eq(read(w.net .. "/stage/wax-0.2.1/Scripts/wax/boot.lua"), EVIL)
end)

t.test("no marker is written when the catalogue passes one version off as a newer one", function()
    local w = world(function(w)
        w.newest = { version = "0.2.2" }
        w.listed["0.2.2"] = runtime("0.2.1", { VERSION = "0.2.2\r\n" })
        w.signature = function(signature, version)
            if version ~= "0.2.2" then return signature end
            return sign(signed_text("0.2.1", w.plan_of("0.2.2").files))
        end
    end)
    w.run(120)
    t.eq(w.marker(), nil)
    t.eq(w.logged("Wax 0.2.2 could not be downloaded: " .. NOT_OURS, "warn"), 1)
    t.eq(w.count_asked("^/api/wax/files/0%.2%.2/"), 0)
    t.eq(snapshot(w.root, { "run", "saved" }), w.before)
end)

t.test("a part is only left where it is when the owner signed the list of the running version too", function()
    -- without a signature the list of the running version is not used, and every part comes
    local w = world(function(w)
        w.signature = function(signature, _, rest) return rest ~= "" and signature end
    end)
    w.run(120)
    t.eq(w.marker():match("files=(%d+)"), "14")
    t.eq(w.count_asked("^verify plan/wax%-running%.list$"), 0)
    t.eq(w.logged("", "warn") + w.logged("", "error"), 0, "that is no fault: the update itself is signed")

    -- a list that calls Scripts unchanged, which every size on disk agrees with
    local function forged(w)
        w.running_plan = function(plan)
            local new = {}
            for _, file in ipairs(w.plan_of("0.2.1").files) do new[file.path] = file end
            for index, file in ipairs(plan.files) do
                if file.path:find("^Scripts/") then plan.files[index] = new[file.path] end
            end
        end
    end
    w = world(function(w)
        w.changed_after_signing = true
        forged(w)
    end)
    w.run(120)
    t.eq(#w.checked, 2)
    t.eq(w.checked[2].output, "plan/wax-running.list")
    t.eq(w.checked[2].good, false)
    t.eq(w.marker():match("files=(%d+)"), "14", "it is not believed, so every part comes")
    t.ok(w.marker():find("\ntop=Scripts\n", 1, true))
    t.eq(read(w.net .. "/stage/wax-0.2.1/Scripts/wax/boot.lua"), 'return "boot 0.2.1"')

    -- what believing it would do: the new VERSION over the Scripts of the version before
    w = world(forged)
    w.run(120)
    t.eq(w.marker():match("files=(%d+)"), "1")
    t.ok(not w.marker():find("top=Scripts", 1, true))
end)

t.test("the text that is checked is the one the owner's tool signs, byte for byte", function()
    -- the same text is spelled out in wax\market\test\wax.test.mjs and made by waxnet_fixture.mjs
    local TEXT = "wax 0.2.1\n"
        .. "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef 1234 Scripts/main.lua\n"
        .. "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 0 Scripts/wax/boot.lua\n"
        .. "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 7 VERSION\n"
        .. "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd 10 Wax-Import.ps1\n"
        .. "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 412 assets/lucide/32/arrow up.png\n"
        .. "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc 63345 bin/waxnet.dll\n"
    local w = world(function(w)
        write(w.root .. "/VERSION", "0.2.1\r\n")
        w.newest = { version = "0.2.2" }
        w.listed["0.2.2"] = runtime("0.2.2")
        w.running_plan = function(plan)
            plan.files = {
                { path = "bin/waxnet.dll", size = 63345, sha256 = ("c"):rep(64) },
                { path = "VERSION", size = 7, sha256 = ("A"):rep(64) },
                { path = "Scripts/wax/boot.lua", size = 0, sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
                { path = "assets/lucide/32/arrow up.png", size = 412, sha256 = ("b"):rep(64) },
                { path = "Scripts/main.lua", size = 1234, sha256 = ("0123456789abcdef"):rep(4) },
                { path = "Wax-Import.ps1", size = 10, sha256 = ("d"):rep(64) },
            }
            plan.total = 63345 + 7 + 412 + 1234 + 10
        end
        w.signature = function(signature, _, rest) return rest == "" and sign(TEXT) or signature end
    end)
    w.run(120)
    t.eq(w.checked[2].output, "plan/wax-running.list")
    t.eq(w.checked[2].list, TEXT)
    t.eq(w.checked[2].signature, sign(TEXT) .. "\n", "the signature goes to the helper as the catalogue gave it, with a line ending")
    t.eq(w.checked[2].good, true)
    t.eq(read(w.net .. "/plan/wax-running.list"), TEXT)
    t.eq(w.self.state().ready, "0.2.2")
end)

t.finish("selfupdate")
