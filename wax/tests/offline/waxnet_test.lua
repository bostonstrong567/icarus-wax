-- Tests for waxnet.dll against the live catalogue: status files, checksums, refused paths, runs one after another.
-- It skips itself when the DLL is not built or the catalogue cannot be reached.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\waxnet_test.lua

local t = dofile("wax/tests/offline/harness.lua")

local function skip(why)
    print(("waxnet: 0 passed, 0 failed (skipped: %s)"):format(why))
    os.exit(0)
end

local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("a")
    file:close()
    return text
end

local function write(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end

local function sleep(seconds)
    local stop = os.clock() + seconds
    while os.clock() < stop do end
end

local built = read("wax/runtime/bin/waxnet.dll")
if not built then skip("wax/runtime/bin/waxnet.dll is not built") end

-- The DLL takes the folder above its own bin as its root, so a copy in a scratch folder keeps everything in there.
local here = io.popen("cd"):read("l"):gsub("\\", "/")
local ROOT = here .. "/build/waxnet-test"
local NET = ROOT .. "/run/net"
os.execute(('rmdir /s /q "%s" >nul 2>nul'):format((ROOT:gsub("/", "\\"))))
os.execute(('mkdir "%s" >nul 2>nul'):format(((ROOT .. "/bin"):gsub("/", "\\"))))
write(ROOT .. "/bin/waxnet.dll", built)

local ready = package.loadlib(ROOT .. "/bin/waxnet.dll", "wax_net_ready")
local run, problem = package.loadlib(ROOT .. "/bin/waxnet.dll", "wax_net_run")
if not (ready and run) then skip("the DLL does not load: " .. tostring(problem)) end

local number = os.time() % 100000 * 1000

-- Writes a request, starts it `calls` times, and returns what the helper wrote into `done`.
local function ask(lines, calls)
    number = number + 1
    write(NET .. "/request.txt", "#" .. number .. "\n" .. table.concat(lines, "\n") .. "\n")
    for _ = 1, calls or 1 do run() end
    local stop = os.clock() + 90
    while os.clock() < stop do
        local text = read(NET .. "/done")
        if text then
            os.remove(NET .. "/done")
            return text
        end
        sleep(0.05)
    end
    return nil
end

-- The status file of an output, in its parts.
local function status(output)
    local text = read(NET .. "/" .. output .. ".status")
    if not text then return nil end
    local code, bytes, hash, why = text:match("^(%d+) (%d+) (%S+) ?([^\r\n]*)\n$")
    return tonumber(code), tonumber(bytes), hash, why
end

local function sha256(path)
    local pipe = io.popen(('certutil -hashfile "%s" SHA256'):format((path:gsub("/", "\\"))))
    local found = nil
    for line in pipe:lines() do
        local hex = line:gsub("%s", "")
        if #hex == 64 and not hex:find("%X") then found = hex:lower() end
    end
    pipe:close()
    return found
end

ready()
if not pcall(write, NET .. "/request.txt", "") then
    t.test("wax_net_ready makes run/net", function() error("run/net was not made") end)
    t.finish("waxnet")
end
os.remove(NET .. "/request.txt")

local first = ask({ "/api/healthz\thealthz.json" })
local code, _, _, why = status("healthz.json")
if code ~= 200 then skip("the catalogue cannot be reached: " .. tostring(why or code or "no answer")) end

t.test("an answer is saved with its status, size and checksum", function()
    t.eq(first, "#" .. number .. "\n", "done holds the number of the request")
    local status_code, bytes, hash = status("healthz.json")
    t.eq(status_code, 200)
    local body = read(NET .. "/healthz.json")
    t.ok(body and body:find('"ok"', 1, true), "the body is the catalogue's answer")
    t.eq(bytes, #body)
    t.eq(hash, sha256(NET .. "/healthz.json"), "the checksum is the one certutil works out")
    t.eq(read(NET .. "/request.txt"), nil, "the request is taken away once it is read")
    t.eq(read(NET .. "/healthz.json.part"), nil, "no half-written file is left")
end)

t.test("a longer answer, into folders that did not exist", function()
    local done = ask({ "/api/mods\tlists/first/mods.json", "/api/mods?per_page=1&page=1\tlists/one.json" })
    t.eq(done, "#" .. number .. "\n")
    for _, output in ipairs({ "lists/first/mods.json", "lists/one.json" }) do
        local status_code, bytes, hash = status(output)
        t.eq(status_code, 200, output)
        t.eq(bytes, #read(NET .. "/" .. output), output)
        t.eq(hash, sha256(NET .. "/" .. output), output)
    end
    t.ok(read(NET .. "/lists/first/mods.json"):find('"mods"', 1, true))
end)

t.test("an address outside /api/ is refused without asking", function()
    ask({ "/other\tother.json", "/api/../other\tdots.json", "/api//mods\tslashes.json", "/api/%2e%2e/x\tcoded.json",
        "/api/mods bad\tspace.json", "https://example.org/api/x\thost.json", "/api/mods#x\thash.json", "/api\tshort.json" })
    for _, output in ipairs({ "other", "dots", "slashes", "coded", "space", "host", "hash", "short" }) do
        local status_code, bytes, hash, reason = status(output .. ".json")
        t.eq(status_code, 0, output)
        t.eq(bytes, 0, output)
        t.eq(hash, "-", output)
        t.eq(reason, "this address is not allowed", output)
        t.eq(read(NET .. "/" .. output .. ".json"), nil, output)
    end
end)

t.test("an output outside run/net is refused, and so are names Windows treats specially", function()
    local outside = { "../escape.json", "../../escape.json", "sub/../../escape.json", "/escape.json", "C:/escape.json",
        "\\escape.json", "sub\\escape.json", "nul.json", "sub/con/x.json", "com1", "trail./x.json", "x.json ", "a:b.json",
        "done", "request.txt", "x.status", "x.part", "", "caf\195\169.json" }
    local lines = {}
    for _, output in ipairs(outside) do lines[#lines + 1] = "/api/healthz\t" .. output end
    lines[#lines + 1] = "/api/healthz\tkept.json"
    local done = ask(lines)
    t.eq(done, "#" .. number .. "\n")
    t.eq((status("kept.json")), 200, "the one good line in the request is still done")
    for _, path in ipairs({ ROOT .. "/run/escape.json", ROOT .. "/escape.json", here .. "/build/escape.json", ROOT .. "/run/escape.json.status",
        NET .. "/escape.json", NET .. "/sub/escape.json", NET .. "/x.json", NET .. "/x.status", NET .. "/x.part", NET .. "/com1",
        NET .. "/a", NET .. "/trail/x.json", NET .. "/request.txt" }) do
        t.eq(read(path), nil, path)
    end
    t.eq(read("C:/escape.json"), nil)
    t.eq(read(NET .. "/done"), nil, "done is only ever the helper's own file")
end)

t.test("an answer that is not 200 leaves a status and no file", function()
    ask({ "/api/healthz\tagain.json" })
    t.eq((status("again.json")), 200)
    ask({ "/api/mods/ThereIsNoSuchMod_zz\tagain.json" })
    local status_code, bytes, hash, reason = status("again.json")
    t.eq(status_code, 404)
    t.eq(bytes, 0)
    t.eq(hash, "-")
    t.eq(reason, "")
    t.eq(read(NET .. "/again.json"), nil, "the file from the run before is gone, so it cannot be taken for this answer")
end)

t.test("two runs after each other each say their own number", function()
    local one = ask({ "/api/healthz\tone.json" })
    local two = ask({ "/api/healthz\ttwo.json" })
    t.ok(one ~= two)
    t.eq(two, "#" .. number .. "\n")
    t.eq((status("one.json")), 200)
    t.eq((status("two.json")), 200)
end)

t.test("a call while a run is going does nothing", function()
    local done = ask({ "/api/healthz\tbusy1.json", "/api/mods\tbusy2.json", "/api/healthz\tbusy3.json" }, 6)
    t.eq(done, "#" .. number .. "\n")
    for index = 1, 3 do t.eq((status("busy" .. index .. ".json")), 200) end
    run()
    sleep(0.5)
    t.eq(read(NET .. "/done"), nil, "with no request waiting, a call writes nothing")
end)

t.test("a request without a number, and one with nothing to do", function()
    write(NET .. "/request.txt", "/api/healthz\tplain.json\r\n\r\nnot a job\n")
    run()
    local stop, done = os.clock() + 60, nil
    while not done and os.clock() < stop do
        sleep(0.05)
        done = read(NET .. "/done")
    end
    os.remove(NET .. "/done")
    t.eq(done, "#0\n")
    t.eq((status("plain.json")), 200, "Windows line endings are read")
    t.eq(ask({}), "#" .. number .. "\n")
end)

t.test("a folder under stage is emptied on request, and nothing else is", function()
    ask({ "/api/healthz\tstage/Thing/init.json", "/api/healthz\tstage/Thing/deep/er/two.json", "/api/healthz\tkeep/me.json" })
    t.ok(read(NET .. "/stage/Thing/deep/er/two.json"))
    ask({ "-\tstage/Thing", "-\tkeep", "-\tstage/NeverThere", "/api/healthz\tstage/Thing/fresh.json" })
    local status_code, _, hash = status("stage/Thing")
    t.eq(status_code, 200)
    t.eq(hash, "-")
    t.eq(read(NET .. "/stage/Thing/init.json"), nil)
    t.eq(read(NET .. "/stage/Thing/init.json.status"), nil)
    t.eq(read(NET .. "/stage/Thing/deep/er/two.json"), nil)
    t.ok(read(NET .. "/stage/Thing/fresh.json"), "what is fetched after the clearing is there")
    t.eq((status("stage/NeverThere")), 200, "a folder that is not there counts as empty")
    local refused, _, _, reason = status("keep")
    t.eq(refused, 0)
    t.eq(reason, "only folders under stage can be cleared")
    t.ok(read(NET .. "/keep/me.json"), "a folder outside stage is left alone")
end)

t.test("at most 600 jobs are done for one request", function()
    local lines = {}
    for index = 1, 605 do lines[index] = ("/other\tmany/%d.json"):format(index) end
    ask(lines)
    t.eq((status("many/1.json")), 0)
    t.eq((status("many/600.json")), 0)
    t.eq(status("many/601.json"), nil)
    t.eq(status("many/605.json"), nil)
end)

t.test("the updater in Lua and the real helper understand each other", function()
    os.execute(('mkdir "%s" >nul 2>nul'):format(((ROOT .. "/mods/Listed"):gsub("/", "\\"))))
    write(ROOT .. "/mods/Listed/wax.origin", "id=Listed\r\nversion=0.0.1\r\n")
    local Wax = t.new_wax()
    Wax.root = ROOT
    local log, sched = Wax.import("core.log"), Wax.import("core.sched")
    Wax.import("core.storage").directory = nil
    Wax.mods = {
        list = function() return { { id = "Listed", name = "Listed" } } end,
        get = function() return { dir = ROOT .. "/mods/Listed", manifest = {}, depends = {}, files = {} } end,
    }
    local update = Wax.import("mods.update")
    update.start()
    t.eq(update.check_now(), true)
    local stop, state = os.clock() + 60, nil
    repeat
        sleep(0.002)
        sched.step()
        state = update.state()
    until ((state.last > 0 or state.problem) and not state.checking) or os.clock() > stop
    update.stop()
    t.eq(state.checking, false, "the check came to an end")
    local answered = status("versions.json")
    t.ok(answered == 200 or answered == 404, "the helper took the request Lua wrote and answered it: " .. tostring(answered))
    local refused = false
    for _, entry in ipairs(log.since(0)) do
        refused = refused or entry.message:find("the catalogue answered 404", 1, true) ~= nil
        t.ok(not entry.message:find("no answer", 1, true) and not entry.message:find("could not be written", 1, true), entry.message)
    end
    -- until the catalogue has the list of versions it answers 404, which Lua has to read as that
    if answered == 200 then
        t.eq(state.problem, nil)
        t.ok(state.last > 0)
        t.eq(next(state.available), nil, "a mod the catalogue does not have is not offered")
    else
        t.eq(state.problem, "Updates could not be checked.")
        t.ok(refused, "the log says what the catalogue answered")
    end
end)

t.test("a mod of the catalogue is fetched whole, checked, and put in the place of an older copy", function()
    local json = dofile("wax/runtime/Scripts/wax/data/json.lua")
    local read_ok, versions = pcall(json.decode, read(NET .. "/versions.json") or "")
    if not read_ok or type(versions.mods) ~= "table" then return end     -- the catalogue has no list of versions yet
    local id = versions.mods.RecipeBrowser and "RecipeBrowser" or next(versions.mods)
    if not id then return end
    local version, dir = versions.mods[id].version, ROOT .. "/mods/" .. id
    os.execute(('mkdir "%s" >nul 2>nul'):format((dir:gsub("/", "\\"))))
    write(dir .. "/init.lua", "return 'the copy before'")
    write(dir .. "/wax.origin", ("id=%s\nversion=0.0.1\n"):format(id))

    local Wax = t.new_wax()
    Wax.root = ROOT
    local log, sched = Wax.import("core.log"), Wax.import("core.sched")
    Wax.import("core.storage").directory = nil
    local kept = nil
    Wax.mods = {
        list = function() return kept and {} or { { id = id, name = id } } end,
        get = function(which)
            if which == id and not kept then return { dir = dir, manifest = { name = id }, depends = {}, files = {} } end
        end,
        remove = function()
            kept = ".removed-" .. id .. "-test"
            assert(os.rename(dir, ROOT .. "/mods/" .. kept))
            return kept
        end,
        request_sync = function() end,
        request_reload = function() end,
    }
    local update = Wax.import("mods.update")
    -- the real helper, asked without "?update=1" so that a test run is not counted as a download of the mod
    update.loadlib = function(path, name)
        local call = package.loadlib(path, name)
        if name ~= "wax_net_run" then return call end
        return function()
            local text = read(NET .. "/request.txt")
            if text and text:find("?update=1", 1, true) then write(NET .. "/request.txt", (text:gsub("%?update=1", ""))) end
            return call()
        end
    end
    update.start()
    update.check_now()
    local stop, state = os.clock() + 120, nil
    repeat
        sleep(0.002)
        sched.step()
        state = update.state()
    until (state.last > 0 and not state.checking and next(state.installing) == nil) or state.problem or os.clock() > stop
    update.stop()

    for _, entry in ipairs(log.since(0)) do t.ok(entry.level == "info", entry.message) end
    t.eq(state.problem, nil)
    t.ok(kept, "the older copy was moved aside")
    t.eq(read(ROOT .. "/mods/" .. kept .. "/init.lua"), "return 'the copy before'")
    t.eq(read(dir .. "/wax.origin"), ("id=%s\nversion=%s\n"):format(id, version))
    local plan = json.decode(read(NET .. "/plan/" .. id .. ".json"))
    t.ok(#plan.files > 0)
    for _, file in ipairs(plan.files) do
        local body = read(dir .. "/" .. file.path)
        t.ok(body, file.path .. " is in the mod's folder")
        t.eq(#body, file.size, file.path)
        t.eq(sha256(dir .. "/" .. file.path), file.sha256, file.path .. " is what the catalogue lists, by certutil's count")
        t.eq(read(dir .. "/" .. file.path .. ".status"), nil, "no status file went along")
    end
    t.eq(read(NET .. "/stage/" .. id .. "/init.lua"), nil, "the staging folder is gone")
    t.eq(next(state.available), nil)
end)

t.finish("waxnet")
