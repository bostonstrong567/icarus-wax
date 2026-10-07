-- Offline tests for Scripts/selfswap.lua: it runs on real folders under a scratch directory, with plain Lua and nothing of Wax.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\selfswap_test.lua [scratch dir]

local t = dofile("wax/tests/offline/harness.lua")

local SWAP = "wax/runtime/Scripts/selfswap.lua"
local function win(path) return (path:gsub("/", "\\")) end
local here = io.popen("cd"):read("l"):gsub("\\", "/")
local base = (arg[1] or "build/selfswap-test"):gsub("\\", "/")
if not base:match("^%a:") then base = here .. "/" .. base end
os.execute(('rmdir /s /q "%s" >nul 2>nul'):format(win(base)))

local function mkdir(path) os.execute(('mkdir "%s" >nul 2>nul'):format(win(path))) end

local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("a")
    file:close()
    return text
end

local function write(path, text)
    local file = io.open(path, "wb")
    if not file then
        mkdir(path:match("^(.*)/[^/]+$"))
        file = assert(io.open(path, "wb"))
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

-- Every file under a folder with its content, as one text. Folders named in skip are left out.
local function snapshot(dir, skip)
    local names, prefix = {}, #dir + 2
    local pipe = io.popen(('dir /b /s /a:-d "%s" 2>nul'):format(win(dir)))
    for line in pipe:lines() do
        local name = line:sub(prefix):gsub("\\", "/")
        local left_out = false
        for _, folder in ipairs(skip or {}) do
            if name:sub(1, #folder + 1) == folder .. "/" then left_out = true end
        end
        if not left_out then names[#names + 1] = name end
    end
    pipe:close()
    table.sort(names)
    for index, name in ipairs(names) do names[index] = name .. "=" .. read(dir .. "/" .. name) end
    return table.concat(names, "\n")
end

local function installed(version)
    return {
        ["VERSION"] = version .. "\r\n",
        ["Wax-Import.ps1"] = "Write-Host 'import " .. version .. "'\r\n",
        ["Scripts/main.lua"] = "return 'main " .. version .. "'",
        ["Scripts/selfswap.lua"] = read(SWAP),
        ["Scripts/wax/boot.lua"] = "return 'boot " .. version .. "'",
        ["Scripts/wax/loader.lua"] = "return 'loader " .. version .. "'",
        ["Scripts/wax/only in " .. version .. ".lua"] = "return 1",
        ["data/libraries.lua"] = "return { '" .. version .. "' }",
        ["assets/round6.png"] = "png of " .. version,
        ["assets/lucide/32/arrow-up.png"] = "icon of " .. version,
        ["bin/waxco.dll"] = "coroutines " .. version,
        ["bin/waxnet.dll"] = "downloads " .. version,
    }
end

local function top_of(path) return path:match("^[^/]+") end

local count = 0

-- A scratch copy of an installed Wax with the player's own folders beside it.
local function world(version)
    count = count + 1
    local root = ("%s/%d/ue4ss/Mods/Wax"):format(base, count)
    local w = { root = root, net = root .. "/run/net", said = {}, now = 1800000000 }
    local files = installed(version or "0.2.0")
    files["enabled.txt"] = ""
    files["mods/Mine/init.lua"] = "return 'my mod'"
    files["mods/RecipeBrowser/wax.origin"] = "id=RecipeBrowser\nversion=0.9.0\n"
    files["saved/wax.mods.lua"] = "return { order = {} }"
    files["run/session.log"] = "started"
    files["run/net/stage/keep"] = ""
    write_all(root, files)
    os.remove(root .. "/run/net/stage/keep")

    -- Lays a downloaded version out as mods.selfupdate does: the files of the named parts and the marker that lists them.
    function w.stage(new, from, tops, change)
        local lines, files, total = {}, {}, 0
        for path, text in pairs(installed(new)) do
            for _, top in ipairs(tops) do
                if top_of(path) == top then files[#files + 1] = { path = path, text = text } end
            end
        end
        table.sort(files, function(a, b) return a.path < b.path end)
        local staged = {}
        for _, file in ipairs(files) do
            staged[file.path] = file.text
            lines[#lines + 1] = ("file=%d %s"):format(#file.text, file.path)
            total = total + 1
        end
        write_all(("%s/stage/wax-%s"):format(w.net, new), staged)
        local head = { "wax-ready 1", "version=" .. new, "from=" .. from, "folder=stage/wax-" .. new, "files=" .. total }
        for _, top in ipairs(tops) do head[#head + 1] = "top=" .. top end
        local marker = { head = head, files = lines, tail = { "end" } }
        if change then change(marker) end
        local all = {}
        for _, part in ipairs({ marker.head, marker.files, marker.tail }) do
            for _, line in ipairs(part) do all[#all + 1] = line end
        end
        write(w.net .. "/wax-ready.txt", table.concat(all, "\n") .. "\n")
    end

    function w.start(options)
        options = options or {}
        options.root = options.root or root
        options.print = function(text) w.said[#w.said + 1] = text end
        options.time = function() return w.now end
        w.now = w.now + 100
        return assert(loadfile(SWAP))(options)
    end

    -- What boot does once the new version has run its first frames.
    function w.confirm() os.remove(w.net .. "/wax-trial.txt") end
    function w.file(name) return read(root .. "/" .. name) end
    function w.state(name) return read(w.net .. "/" .. name) end
    function w.own() return snapshot(root .. "/mods") .. snapshot(root .. "/saved") .. read(root .. "/enabled.txt") .. read(root .. "/run/session.log") end
    w.mine = w.own()
    return w
end

t.test("a version that is ready is put in, and the one before is kept beside it", function()
    local w = world()
    w.stage("0.2.1", "0.2.0", { "Scripts", "VERSION" })
    local result = w.start()
    t.eq(result.did, "swapped")
    t.eq(result.version, "0.2.1")
    t.eq(result.from, "0.2.0")
    t.eq(w.file("VERSION"), "0.2.1\r\n")
    t.eq(w.file("Scripts/main.lua"), "return 'main 0.2.1'")
    t.eq(w.file("Scripts/wax/boot.lua"), "return 'boot 0.2.1'")
    t.eq(w.file("Scripts/wax/only in 0.2.1.lua"), "return 1")
    t.eq(w.file("Scripts/wax/only in 0.2.0.lua"), nil, "a file the new version does not have is gone")
    t.eq(w.file("Scripts.before-0.2.0/main.lua"), "return 'main 0.2.0'")
    t.eq(w.file("Scripts.before-0.2.0/wax/only in 0.2.0.lua"), "return 1")
    t.eq(w.file("VERSION.before-0.2.0"), "0.2.0\r\n")
    t.eq(w.file("data/libraries.lua"), "return { '0.2.0' }", "a part that was not downloaded stays")
    t.eq(w.file("bin/waxnet.dll"), "downloads 0.2.0")
    t.ok(not exists(w.root .. "/data.before-0.2.0") and not exists(w.root .. "/bin.before-0.2.0"))
    t.eq(w.own(), w.mine, "mods, saved, enabled.txt and run are as they were")
    t.eq(w.state("wax-ready.txt"), nil, "the marker is gone")
    t.eq(w.state("wax-trial.txt"), "version=0.2.1\nfrom=0.2.0\nstate=trial\ntries=0\ntime=1800000100\nname=Scripts\nname=VERSION\n")
    t.eq(w.state("wax-applied.txt"), "from=0.2.0\nversion=0.2.1\ntime=1800000100\nwhen=2027-01-15T08:01:40Z\n")
    t.eq(w.state("wax-kept.txt"), "version=0.2.0\nname=Scripts\nname=VERSION\n")
    t.eq(w.state("wax-old.txt"), "stage wax-0.2.1\n", "the used download folder is left for a later frame to delete")
    t.eq(w.state("wax-failed.txt"), nil)
    t.eq(w.state("wax-bad.txt"), nil)
    t.eq(#w.said, 1)
    t.ok(w.said[1]:find("Wax 0.2.1 was put in", 1, true))
end)

t.test("every part of Wax can be swapped, the two helpers included", function()
    local w = world()
    w.stage("0.3.0", "0.2.0", { "VERSION", "bin", "Wax-Import.ps1", "assets", "data", "Scripts" })
    t.eq(w.start().did, "swapped")
    for path, text in pairs(installed("0.3.0")) do t.eq(w.file(path), text, path) end
    for _, name in ipairs({ "Scripts", "data", "assets", "bin" }) do t.ok(exists(w.root .. "/" .. name .. ".before-0.2.0"), name) end
    t.eq(w.file("bin.before-0.2.0/waxnet.dll"), "downloads 0.2.0")
    t.eq(w.file("Wax-Import.ps1.before-0.2.0"), "Write-Host 'import 0.2.0'\r\n")
    t.eq(w.state("wax-trial.txt"):match("name=.*"), "name=Scripts\nname=data\nname=assets\nname=bin\nname=Wax-Import.ps1\nname=VERSION\n", "VERSION is moved last")
    t.eq(snapshot(w.net .. "/stage"), "", "nothing is left in the download folder")
    t.eq(w.own(), w.mine)
end)

t.test("a second start after a good one changes nothing", function()
    local w = world()
    w.stage("0.2.1", "0.2.0", { "Scripts", "VERSION" })
    t.eq(w.start().did, "swapped")
    w.confirm()
    local before = snapshot(w.root)
    for _ = 1, 3 do
        local result = w.start()
        t.eq(result.did, "nothing")
        t.eq(snapshot(w.root), before)
    end
    t.eq(w.file("Scripts.before-0.2.0/main.lua"), "return 'main 0.2.0'", "the one set from before is kept")
    t.eq(#w.said, 1)
end)

t.test("a third version takes the place of the kept set, and the older set is left for a later frame", function()
    local w = world()
    w.stage("0.2.1", "0.2.0", { "Scripts", "VERSION" })
    t.eq(w.start().did, "swapped")
    w.confirm()
    os.remove(w.net .. "/wax-old.txt")
    w.stage("0.2.2", "0.2.1", { "Scripts", "data", "VERSION" })
    t.eq(w.start().did, "swapped")
    t.eq(w.file("VERSION"), "0.2.2\r\n")
    t.eq(w.file("Scripts.before-0.2.1/main.lua"), "return 'main 0.2.1'")
    t.eq(w.file("Scripts.before-0.2.0/main.lua"), "return 'main 0.2.0'", "start-up deletes nothing itself")
    t.eq(w.state("wax-kept.txt"), "version=0.2.1\nname=Scripts\nname=data\nname=VERSION\n")
    t.eq(w.state("wax-old.txt"), "stage wax-0.2.2\nroot Scripts.before-0.2.0\nroot VERSION.before-0.2.0\n")
    t.eq(w.state("wax-applied.txt"):match("^[^\n]+\n[^\n]+"), "from=0.2.1\nversion=0.2.2")
end)

local function refused_case(name, reason, tops, change, after)
    t.test("nothing is moved when " .. name, function()
        local w = world()
        w.stage("0.2.1", "0.2.0", tops or { "Scripts", "VERSION" }, change)
        if after then after(w) end
        local before = snapshot(w.root, { "run" })
        local staged = snapshot(w.net .. "/stage")
        local result = w.start()
        t.eq(result.did, "refused")
        t.eq(result.why, reason)
        t.eq(snapshot(w.root, { "run" }), before, "Wax is as it was")
        t.eq(snapshot(w.net .. "/stage"), staged, "and so is the download")
        t.eq(w.file("VERSION"), "0.2.0\r\n")
        t.eq(w.state("wax-ready.txt"), nil, "the marker is not tried again")
        t.eq(w.state("wax-trial.txt"), nil)
        t.eq(w.state("wax-bad.txt"), nil, "the version is not held against the catalogue")
        t.ok(w.state("wax-failed.txt"):find("was not put in: " .. reason .. ". Nothing was changed", 1, true), w.state("wax-failed.txt"))
        t.eq(w.own(), w.mine)
        t.eq(w.start().did, "nothing")
    end)
end

local function drop(lines, pattern)
    for index = #lines, 1, -1 do
        if lines[index]:find(pattern) then table.remove(lines, index) end
    end
end

local function replace(lines, pattern, with)
    for index, line in ipairs(lines) do
        if line:find(pattern) then lines[index] = with end
    end
end

local function recount(marker) replace(marker.head, "^files=", "files=" .. #marker.files) end

refused_case("a staged file is missing", "Scripts/wax/boot.lua is missing or cut short", nil, nil,
    function(w) os.remove(w.net .. "/stage/wax-0.2.1/Scripts/wax/boot.lua") end)
refused_case("a staged file is cut short", "Scripts/main.lua is missing or cut short", nil, nil,
    function(w) write(w.net .. "/stage/wax-0.2.1/Scripts/main.lua", "return") end)
refused_case("the whole download is gone", "Scripts/main.lua is missing or cut short", nil, nil,
    function(w) os.execute(('rmdir /s /q "%s" >nul 2>nul'):format(win(w.net .. "/stage"))) end)
refused_case("the marker is cut short", "the marker is cut short", nil, function(marker) marker.tail = {} end)
refused_case("the marker is not a marker", "the marker is cut short", nil, function(marker) marker.head[1] = "something else" end)
refused_case("the marker was made for another installed version", "it was made for another version than the one installed", nil,
    function(marker) replace(marker.head, "^from=", "from=0.1.9") end)
refused_case("the staged version is the one installed", "it is not newer than the version installed", nil, function(marker)
    replace(marker.head, "^version=", "version=0.2.0")
    replace(marker.head, "^folder=", "folder=stage/wax-0.2.0")
end)
refused_case("the staged version is older than the one installed", "it is not newer than the version installed", nil, function(marker)
    replace(marker.head, "^version=", "version=0.1.9")
    replace(marker.head, "^folder=", "folder=stage/wax-0.1.9")
end)
refused_case("the version is not three numbers", "it was made for another version than the one installed", nil,
    function(marker) replace(marker.head, "^version=", "version=0.2.1-beta") end)
refused_case("the marker names a folder elsewhere", "it names a folder it may not use", nil,
    function(marker) replace(marker.head, "^folder=", "folder=../../mods/Mine") end)
for _, name in ipairs({ "mods", "saved", "run", "enabled.txt", "dev.txt", "scripts", "..", "Scripts/wax", "" }) do
    refused_case(("the marker names %q as a part"):format(name), "it names a part Wax does not have", nil,
        function(marker) marker.head[#marker.head + 1] = "top=" .. name end)
end
refused_case("a part is named twice", "it names a part Wax does not have", nil, function(marker) marker.head[#marker.head + 1] = "top=Scripts" end)
refused_case("there is no VERSION file among the parts", "it does not hold a VERSION file", { "Scripts" })
refused_case("a part is named without files", "it names a part without files", nil, function(marker) marker.head[#marker.head + 1] = "top=bin" end)
refused_case("a file is listed under the player's mods", "it lists a file outside the parts it names", nil, function(marker)
    marker.files[#marker.files + 1] = "file=15 mods/Mine/init.lua"
    recount(marker)
end)
for _, path in ipairs({ "Scripts/../mods/Mine/init.lua", "../VERSION", "Scripts\\main.lua", "C:/Windows/win.ini", "/Scripts/main.lua", "Scripts/a..b.lua" }) do
    refused_case(("a file is listed as %q"):format(path), "it lists a path that is not allowed", nil, function(marker)
        marker.files[#marker.files + 1] = "file=1 " .. path
        recount(marker)
    end)
end
refused_case("the list of files is shorter than the marker says", "its list of files is not whole", nil, function(marker) table.remove(marker.files, 2) end)
refused_case("the list of files is empty", "its list of files is not whole", nil, function(marker) marker.files = {} end)
refused_case("the VERSION file says another version", "the VERSION file it holds says another version", nil, nil,
    function(w) write(w.net .. "/stage/wax-0.2.1/VERSION", "0.2.9\r\n") end)
refused_case("the new Scripts folder has no main.lua", "its Scripts folder could not start the game's Wax", nil, function(marker)
    drop(marker.files, " Scripts/main%.lua$")
    recount(marker)
end)
refused_case("the new Scripts folder has no selfswap.lua", "its Scripts folder could not start the game's Wax", nil, function(marker)
    drop(marker.files, " Scripts/selfswap%.lua$")
    recount(marker)
end)

t.test("a rename that fails half way puts everything back", function()
    local w = world()
    w.stage("0.2.1", "0.2.0", { "Scripts", "data", "bin", "VERSION" })
    local before, staged = snapshot(w.root, { "run" }), snapshot(w.net .. "/stage")
    local moves = 0
    local function failing(from, to)
        moves = moves + 1
        if from:find("/bin$") and to:find("%.before%-0%.2%.0$") then return nil, "Permission denied" end
        return os.rename(from, to)
    end
    local result = w.start({ rename = failing })
    t.eq(result.did, "failed")
    t.eq(result.why, "bin could not be moved (Permission denied)")
    t.ok(moves >= 9, "two parts were moved and moved back: " .. moves)
    t.eq(snapshot(w.root, { "run" }), before, "every part is back where it was")
    t.eq(snapshot(w.net .. "/stage"), staged, "and the download is whole again")
    t.eq(w.state("wax-trial.txt"), nil)
    t.eq(w.state("wax-bad.txt"), "version=0.2.1\nwhy=move\ntries=1\n")
    t.ok(w.state("wax-ready.txt"), "the marker stays for one more try")
    t.eq(w.state("wax-failed.txt"), "2027-01-15T08:01:40Z Wax 0.2.1 could not be put in: bin could not be moved (Permission denied). The game starts on 0.2.0\n")
    t.eq(w.own(), w.mine)

    -- the second failure is the last try
    result = w.start({ rename = failing })
    t.eq(result.did, "failed")
    t.eq(snapshot(w.root, { "run" }), before)
    t.eq(w.state("wax-bad.txt"), "version=0.2.1\nwhy=move\ntries=2\n")
    t.eq(w.state("wax-ready.txt"), nil)
    t.eq(w.state("wax-old.txt"), "stage wax-0.2.1\n")
    t.eq(w.start().did, "nothing")
    -- and a marker for the same version that turns up again is not acted on
    w.stage("0.2.1", "0.2.0", { "Scripts", "VERSION" })
    result = w.start()
    t.eq(result.did, "nothing")
    t.eq(result.why, "this version did not work here before")
    t.eq(snapshot(w.root, { "run" }), before)
    t.eq(w.state("wax-ready.txt"), nil)
end)

t.test("each step that can fail leaves Wax as it was", function()
    for _, case in ipairs({
        { "/Scripts$", "%.before%-", "Scripts" }, { "/stage/wax%-0%.2%.1/Scripts$", "/Scripts$", "Scripts" },
        { "/data$", "%.before%-", "data" }, { "/stage/wax%-0%.2%.1/data$", "/data$", "data" },
        { "/VERSION$", "%.before%-", "VERSION" }, { "/stage/wax%-0%.2%.1/VERSION$", "/VERSION$", "VERSION" },
    }) do
        local w = world()
        w.stage("0.2.1", "0.2.0", { "Scripts", "data", "VERSION" })
        local before, staged = snapshot(w.root, { "run" }), snapshot(w.net .. "/stage")
        local result = w.start({ rename = function(from, to)
            if from:find(case[1]) and to:find(case[2]) then return nil, "Permission denied" end
            return os.rename(from, to)
        end })
        local label = case[1] .. " to " .. case[2]
        t.eq(result.did, "failed", label)
        t.eq(result.why, case[3] .. " could not be moved (Permission denied)", label)
        t.eq(snapshot(w.root, { "run" }), before, label)
        t.eq(snapshot(w.net .. "/stage"), staged, label)
        t.eq(w.state("wax-trial.txt"), nil, label)
        -- the next start, with nothing in the way, puts it in
        t.eq(w.start().did, "swapped", label)
        t.eq(w.file("VERSION"), "0.2.1\r\n", label)
        t.eq(w.state("wax-bad.txt"), nil, label)
    end
end)

t.test("a folder that Windows will not let go of stops the swap, and the next start does it", function()
    local w = world()
    w.stage("0.2.1", "0.2.0", { "Scripts", "data", "VERSION" })
    local before = snapshot(w.root, { "run" })
    local held = assert(io.open(w.root .. "/data/libraries.lua", "rb"))
    local result = w.start()
    held:close()
    t.eq(result.did, "failed")
    t.ok(result.why:find("^data could not be moved"), result.why)
    t.eq(snapshot(w.root, { "run" }), before, "Scripts went back although it had been swapped already")
    t.eq(w.file("VERSION"), "0.2.0\r\n")
    t.eq(w.start().did, "swapped")
    t.eq(w.file("data/libraries.lua"), "return { '0.2.1' }")
    t.eq(w.own(), w.mine)
end)

t.test("a version that never got as far as running is taken back at the next start, and not tried again", function()
    local w = world()
    local before = snapshot(w.root, { "run" })
    w.stage("0.2.1", "0.2.0", { "Scripts", "bin", "VERSION" })
    t.eq(w.start().did, "swapped")
    -- the trial file is still there: the core never ran its first frames
    local result = w.start()
    t.eq(result.did, "rolled back")
    t.eq(result.version, "0.2.1")
    t.eq(w.file("VERSION"), "0.2.0\r\n")
    t.eq(w.file("Scripts/main.lua"), "return 'main 0.2.0'")
    t.eq(w.file("bin/waxnet.dll"), "downloads 0.2.0")
    t.eq(w.file("Scripts.failed-0.2.1/main.lua"), "return 'main 0.2.1'")
    t.eq(w.file("VERSION.failed-0.2.1"), "0.2.1\r\n")
    t.ok(not exists(w.root .. "/Scripts.before-0.2.0") and not exists(w.root .. "/VERSION.before-0.2.0") and not exists(w.root .. "/bin.before-0.2.0"))
    os.execute(('rmdir /s /q "%s" "%s" >nul 2>nul'):format(win(w.root .. "/Scripts.failed-0.2.1"), win(w.root .. "/bin.failed-0.2.1")))
    os.remove(w.root .. "/VERSION.failed-0.2.1")
    t.eq(snapshot(w.root, { "run" }), before, "apart from the set that failed, Wax is as it was before the update")
    t.eq(w.state("wax-trial.txt"), nil)
    t.eq(w.state("wax-kept.txt"), nil)
    t.eq(w.state("wax-bad.txt"), "version=0.2.1\nwhy=start\ntries=1\n")
    t.eq(w.state("wax-old.txt"), "stage wax-0.2.1\nroot VERSION.failed-0.2.1\nroot bin.failed-0.2.1\nroot Scripts.failed-0.2.1\n")
    t.ok(w.state("wax-failed.txt"):find("Wax 0.2.1 did not start here, so 0.2.0 was put back", 1, true))
    t.eq(w.own(), w.mine)
    t.eq(w.start().did, "nothing")

    -- the same version staged again is left alone
    w.stage("0.2.1", "0.2.0", { "Scripts", "VERSION" })
    result = w.start()
    t.eq(result.did, "nothing")
    t.eq(w.file("VERSION"), "0.2.0\r\n")
    t.eq(w.state("wax-ready.txt"), nil)
    -- a higher one is tried
    w.stage("0.2.2", "0.2.0", { "Scripts", "VERSION" })
    t.eq(w.start().did, "swapped")
    t.eq(w.file("VERSION"), "0.2.2\r\n")
    t.eq(w.state("wax-bad.txt"), nil)
    w.confirm()
    t.eq(w.start().did, "nothing")
    t.eq(w.file("VERSION"), "0.2.2\r\n")
end)

t.test("taking a version back that cannot be moved is tried three times, then given up", function()
    local w = world()
    w.stage("0.2.1", "0.2.0", { "Scripts", "VERSION" })
    t.eq(w.start().did, "swapped")
    local swapped = snapshot(w.root, { "run" })
    local function failing(from, to)
        if from:find("/Scripts$") then return nil, "Permission denied" end
        return os.rename(from, to)
    end
    for try = 1, 3 do
        local result = w.start({ rename = failing })
        t.eq(result.did, "stuck")
        t.eq(snapshot(w.root, { "run" }), swapped, "what could be moved was moved back, so the parts fit each other")
        t.eq(w.state("wax-trial.txt") ~= nil, try < 3)
    end
    t.ok(w.state("wax-failed.txt"):find("could not be put back: Scripts could not be moved (Permission denied). Run Update Wax.cmd to repair it", 1, true))
    t.eq(w.start().did, "nothing")
    t.eq(snapshot(w.root, { "run" }), swapped)
end)

t.test("a swap the game died in the middle of is undone at the next start", function()
    local w = world()
    local before = snapshot(w.root, { "run" })
    w.stage("0.2.1", "0.2.0", { "Scripts", "data", "VERSION" })
    -- what selfswap had done when the game stopped: its note, and the first part moved
    write(w.net .. "/wax-trial.txt", "version=0.2.1\nfrom=0.2.0\nstate=moving\ntries=0\ntime=1\nname=Scripts\nname=data\nname=VERSION\n")
    assert(os.rename(w.root .. "/Scripts", w.root .. "/Scripts.before-0.2.0"))
    assert(os.rename(w.net .. "/stage/wax-0.2.1/Scripts", w.root .. "/Scripts"))
    local result = w.start()
    t.eq(result.did, "undone")
    t.eq(w.file("Scripts/main.lua"), "return 'main 0.2.0'")
    t.eq(w.file("Scripts.failed-0.2.1/main.lua"), "return 'main 0.2.1'")
    os.execute(('rmdir /s /q "%s" >nul 2>nul'):format(win(w.root .. "/Scripts.failed-0.2.1")))
    t.eq(snapshot(w.root, { "run" }), before)
    t.eq(w.state("wax-trial.txt"), nil)
    t.eq(w.state("wax-bad.txt"), nil, "the version is not blamed for it")
    t.eq(w.state("wax-ready.txt"), nil, "the download is no longer whole, so the running game fetches it again")
    t.ok(w.state("wax-old.txt"):find("root Scripts.failed-0.2.1", 1, true))

    -- stopped before anything was moved: the note alone means nothing
    w = world()
    w.stage("0.2.1", "0.2.0", { "Scripts", "VERSION" })
    write(w.net .. "/wax-trial.txt", "version=0.2.1\nfrom=0.2.0\nstate=moving\ntries=0\ntime=1\nname=Scripts\nname=VERSION\n")
    t.eq(w.start().did, "swapped")
    t.eq(w.file("VERSION"), "0.2.1\r\n")
end)

t.test("a trial file left behind after the installer replaced Wax is dropped", function()
    local w = world("0.2.1")
    write(w.net .. "/wax-trial.txt", "version=0.2.1\nfrom=0.2.0\nstate=trial\ntries=0\ntime=1\nname=Scripts\nname=VERSION\n")
    local before = snapshot(w.root, { "run" })
    t.eq(w.start().did, "nothing")
    t.eq(snapshot(w.root, { "run" }), before)
    t.eq(w.state("wax-trial.txt"), nil)
    t.eq(w.state("wax-bad.txt"), nil)
    t.eq(w.state("wax-failed.txt"), nil)
    for _, text in ipairs({ "", "version=what\nname=Scripts\n", "version=0.2.1\nfrom=0.2.0\nname=mods\nname=saved\n" }) do
        write(w.net .. "/wax-trial.txt", text)
        t.eq(w.start().did, "nothing")
        t.eq(snapshot(w.root, { "run" }), before)
        t.eq(w.state("wax-trial.txt"), nil)
    end
end)

t.test("a copy with dev.txt, or without a VERSION file, is never touched", function()
    local w = world()
    w.stage("0.2.1", "0.2.0", { "Scripts", "VERSION" })
    write(w.root .. "/dev.txt", "")
    local before, state = snapshot(w.root, { "run" }), snapshot(w.net)
    local result = w.start()
    t.eq(result.did, "nothing")
    t.eq(result.why, "dev.txt")
    t.eq(snapshot(w.root, { "run" }), before)
    t.eq(snapshot(w.net), state, "not even the marker")
    -- a trial file does not make it move anything either
    assert(os.rename(w.root .. "/Scripts", w.root .. "/Scripts.before-0.1.9"))
    assert(os.rename(w.root .. "/Scripts.before-0.1.9", w.root .. "/Scripts"))
    write(w.net .. "/wax-trial.txt", "version=0.2.0\nfrom=0.1.9\nstate=trial\ntries=0\ntime=1\nname=Scripts\n")
    t.eq(w.start().why, "dev.txt")
    t.ok(w.state("wax-trial.txt"))
    t.eq(#w.said, 0)

    w = world()
    w.stage("0.2.1", "0.2.0", { "Scripts", "VERSION" })
    os.remove(w.root .. "/VERSION")
    before, state = snapshot(w.root, { "run" }), snapshot(w.net)
    result = w.start()
    t.eq(result.why, "no VERSION file")
    t.eq(snapshot(w.root, { "run" }), before)
    t.eq(snapshot(w.net), state)
    write(w.root .. "/VERSION", "a development copy\r\n")
    t.eq(w.start().why, "no VERSION file")
    t.eq(snapshot(w.net), state)
end)

t.test("this workspace's own runtime is one of those copies", function()
    t.eq(read("wax/runtime/VERSION"), nil, "wax/runtime has no VERSION file")
    t.ok(read("wax/runtime/dev.txt"), "wax/runtime/dev.txt is there")
    local before = read("wax/runtime/Scripts/main.lua")
    local result = assert(loadfile(SWAP))({ root = "wax/runtime", print = function() end })
    t.eq(result.did, "nothing")
    t.eq(read("wax/runtime/Scripts/main.lua"), before)
end)

t.test("it runs as main.lua runs it, from the folder it replaces", function()
    local w = world()
    local line = 'pcall(dofile, (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\\\][^/\\\\]*$") or "ue4ss\\\\Mods\\\\Wax\\\\Scripts") .. "\\\\selfswap.lua")\n'
    write(w.root .. "/Scripts/main.lua", line .. "return 'main 0.2.0 ran'")
    w.stage("0.2.1", "0.2.0", { "Scripts", "VERSION" })
    local said = {}
    local real_print = print
    print = function(text) said[#said + 1] = text end
    -- main.lua and selfswap.lua are both in the Scripts folder that is renamed while they run
    local ok, result = pcall(dofile, win(w.root) .. "\\Scripts\\main.lua")
    print = real_print
    t.ok(ok, tostring(result))
    t.eq(result, "main 0.2.0 ran", "the main.lua that was loaded runs to its end")
    t.eq(w.file("VERSION"), "0.2.1\r\n")
    t.eq(w.file("Scripts/main.lua"), "return 'main 0.2.1'")
    t.eq(w.file("Scripts.before-0.2.0/main.lua"), line .. "return 'main 0.2.0 ran'")
    t.eq(w.file("Scripts.before-0.2.0/selfswap.lua"), read(SWAP))
    t.eq(#said, 1)
    t.ok(said[1]:find("^%[Wax%] Wax 0%.2%.1 was put in"), said[1])
    t.eq(w.own(), w.mine)

    -- with forward slashes in the path, as some launchers give it
    w = world()
    w.stage("0.2.1", "0.2.0", { "Scripts", "VERSION" })
    print = function() end
    local swapped = dofile(w.root .. "/Scripts/selfswap.lua")
    print = real_print
    t.eq(swapped.did, "swapped")
    t.eq(w.file("VERSION"), "0.2.1\r\n")
end)

t.test("it does nothing when Wax is already running in this Lua state", function()
    local w = world()
    w.stage("0.2.1", "0.2.0", { "Scripts", "VERSION" })
    local before, state = snapshot(w.root, { "run" }), snapshot(w.net)
    for _, name in ipairs({ "WaxStage0", "Wax" }) do
        _G[name] = {}
        local result = dofile(w.root .. "/Scripts/selfswap.lua")
        _G[name] = nil
        t.eq(result.did, "running", name)
        t.eq(snapshot(w.root, { "run" }), before, name)
        t.eq(snapshot(w.net), state, name)
    end
end)

t.test("it uses nothing but plain Lua", function()
    local seen = {}
    local env = setmetatable({}, { __index = function(_, name)
        seen[name] = true
        return _G[name]
    end })
    local w = world()
    w.stage("0.2.1", "0.2.0", { "Scripts", "VERSION" })
    local chunk = assert(loadfile(SWAP, "t", env))
    t.eq(chunk({ root = w.root, print = function() end }).did, "swapped")
    local allowed = { rawget = true, os = true, io = true, debug = true, ipairs = true, pairs = true, type = true, tonumber = true, tostring = true,
        table = true, pcall = true, print = true, string = true }
    for name in pairs(seen) do t.ok(allowed[name], "it reached for the global " .. name) end
end)

t.finish("selfswap")
