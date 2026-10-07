-- Tests for waxnet.dll. First the signature check, which needs no catalogue: on the DLL as built, and on a copy built with a key
-- made for the test (scripts\Build-WaxNative.ps1 -SigningTest, which needs gcc and Node). Then against the live catalogue: status
-- files, checksums, refused paths, runs one after another. That part skips itself when the catalogue cannot be reached.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\waxnet_test.lua

local t = dofile("wax/tests/offline/harness.lua")

local SUITE = "waxnet"

-- Ends the suite here with what ran so far.
local function skip(why)
    for _, failure in ipairs(t.failures) do io.stderr:write("FAIL ", failure, "\n") end
    print(("%s: %d passed, %d failed (the rest skipped: %s)"):format(SUITE, t.passed, t.failed, why))
    os.exit(t.failed == 0 and 0 or 1)
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

-- Another build of the helper can be named, for one that could not be put in wax/runtime/bin while the game had that file open.
local DLL = arg[1] or "wax/runtime/bin/waxnet.dll"
local built = read(DLL)
if not built then skip(DLL .. " is not built") end

-- The DLL takes the folder above its own bin as its root, so a copy in a scratch folder keeps everything in there.
local here = io.popen("cd"):read("l"):gsub("\\", "/")
local function win(path) return (path:gsub("/", "\\")) end
local function mkdir(path) os.execute(('mkdir "%s" >nul 2>nul'):format(win(path))) end

local ROOT, NET, ready, run = nil, nil, nil, nil

-- Loads the copy of the helper under a root. Every request after this goes to that copy.
local function use(root)
    local made, why = package.loadlib(root .. "/bin/waxnet.dll", "wax_net_ready")
    local start = made and package.loadlib(root .. "/bin/waxnet.dll", "wax_net_run")
    if not start then return false, why end
    ROOT, NET, ready, run = root, root .. "/run/net", made, start
    ready()
    return true
end

local REAL = here .. "/build/waxnet-test"
os.execute(('rmdir /s /q "%s" >nul 2>nul'):format(win(REAL)))
mkdir(REAL .. "/bin")
write(REAL .. "/bin/waxnet.dll", built)

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

-- Puts a list and a signature under run/net as the game's Lua does, has the helper check them, and returns the status in its parts.
local function check(name, list, signature)
    for path, content in pairs({ [NET .. "/" .. name] = list or false, [NET .. "/" .. name .. ".sig"] = signature or false }) do
        if content then write(path, content) else os.remove(path) end
    end
    write(NET .. "/" .. name .. ".status", "200 1 an answer from an earlier check\n")
    ask({ "=\t" .. name })
    return status(name)
end

-- Says that the check refused, and why.
local function refused(why, code, bytes, hash, reason)
    t.eq(code, 0, why)
    t.eq(bytes, 0, why)
    t.eq(hash, "-", why)
    t.eq(reason, why)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- The same base64 text with one bit of the bytes it stands for turned over, in the character at `place`.
local function flip(text, place, bit)
    local value = B64:find(text:sub(place, place), 1, true) - 1
    local other = value ~ (bit or 1)
    return text:sub(1, place - 1) .. B64:sub(other + 1, other + 1) .. text:sub(place + 1)
end

local has_key = not (read("wax/native/waxnet.c") or ""):find("#define WAX_PUBLIC_KEY WAX_NO_PUBLIC_KEY", 1, true)
local SIGNING = here .. "/build/waxnet-signing"
local fixture, no_fixture = nil, nil
for _, tool in ipairs({ "gcc", "node", "pwsh" }) do
    if not os.execute(("where %s >nul 2>nul"):format(tool)) then no_fixture = no_fixture or (tool .. " is not here") end
end
if not no_fixture then
    local built_copy = os.execute("pwsh -NoProfile -File scripts\\Build-WaxNative.ps1 -SigningTest >build\\waxnet-signing.log 2>&1")
    fixture = { list = read(SIGNING .. "/fixture/list.txt"), good = read(SIGNING .. "/fixture/good.sig"), other = read(SIGNING .. "/fixture/other.sig"),
        empty = read(SIGNING .. "/fixture/empty.sig"), key = read(SIGNING .. "/fixture/key.txt") }
    t.test("a copy of the helper is built with a key made for this test", function()
        t.ok(built_copy, "scripts\\Build-WaxNative.ps1 -SigningTest failed: see build\\waxnet-signing.log")
        t.ok(fixture.list and fixture.good and fixture.other and fixture.empty and fixture.key, "the list and its signatures are there")
        t.eq(#fixture.good, 89)
        t.ok(fixture.good ~= fixture.other)
        t.ok(use(SIGNING), "the copy loads")
        t.eq(ROOT, SIGNING)
        t.ok((read(SIGNING .. "/bin/waxnet.dll") or ""):find(fixture.key, 1, true), "the key a copy was built with can be read out of its file")
        t.ok(not built:find(fixture.key, 1, true), "and the helper for the game does not hold it")
        t.eq(read(SIGNING .. "/fixture/key.pem"), nil, "the private half was never written")
    end)
    if t.failed > 0 then fixture = nil end
else
    print("waxnet: the signature tests on a keyed copy are skipped (" .. no_fixture .. ")")
end

if fixture then
    mkdir(NET .. "/plan")
    local good = fixture.good:sub(1, 88)

    t.test("a list with the owner's signature is good", function()
        local code, bytes, hash, why = check("plan/wax-own.list", fixture.list, fixture.good)
        t.eq(code, 200)
        t.eq(bytes, #fixture.list)
        t.eq(hash, sha256(NET .. "/plan/wax-own.list"), "the checksum in the answer is the list's")
        t.eq(why, "")
        t.eq(read(NET .. "/plan/wax-own.list"), fixture.list, "the list stays as it was")
        t.eq(read(NET .. "/plan/wax-own.list.sig"), fixture.good)
        t.eq(read(NET .. "/request.txt"), nil)
    end)

    t.test("one changed bit in the list makes it bad", function()
        for _, place in ipairs({ 1, 5, 9, 76, #fixture.list // 2, #fixture.list - 1, #fixture.list }) do
            for _, bit in ipairs({ 1, 128 }) do
                local changed = fixture.list:sub(1, place - 1) .. string.char(fixture.list:byte(place) ~ bit) .. fixture.list:sub(place + 1)
                refused("the signature does not match", check("plan/wax-own.list", changed, fixture.good))
            end
        end
        for what, changed in pairs({ ["a byte more"] = fixture.list .. "\n", ["a byte less"] = fixture.list:sub(1, -2), ["other line endings"] = fixture.list:gsub("\n", "\r\n"),
            ["two lines the other way round"] = fixture.list:gsub("^(.-\n)(.-\n)(.-\n)", "%1%3%2"), ["nothing"] = "" }) do
            t.ok(changed ~= fixture.list, what)
            refused("the signature does not match", check("plan/wax-own.list", changed, fixture.good))
        end
        t.eq((check("plan/wax-own.list", fixture.list, fixture.good)), 200, "and the list as it was signed is still good")
    end)

    t.test("one changed bit in the signature makes it bad", function()
        for _, place in ipairs({ 1, 2, 43, 44, 85 }) do
            for _, bit in ipairs({ 1, 32 }) do refused("the signature does not match", check("plan/wax-own.list", fixture.list, flip(good, place, bit) .. "\n")) end
        end
        refused("the signature does not match", check("plan/wax-own.list", fixture.list, flip(good, 86, 16) .. "\n"))
        local code, bytes, hash = check("plan/wax-own.list", fixture.list, ("A"):rep(86) .. "==\n")
        t.eq(code, 0, "a signature of nothing but zeros")
        t.eq(bytes, 0)
        t.eq(hash, "-")
    end)

    t.test("a signature that is cut short, or is not 64 bytes in base64, is not read", function()
        local hex = good:gsub(".", function(char) return ("%02x"):format(char:byte()) end)
        for what, text in pairs({ ["cut by one"] = good:sub(1, 87), ["cut in half"] = good:sub(1, 44), ["empty"] = "", ["one more"] = good .. "A", ["no padding"] = good:sub(1, 86),
            ["bits left over"] = flip(good, 86, 1), ["a space in it"] = good:sub(1, 40) .. " " .. good:sub(42), ["a line break in it"] = good:sub(1, 44) .. "\n" .. good:sub(45),
            ["written for a web address"] = good:gsub("[+/]", { ["+"] = "-", ["/"] = "_" }):sub(1, 86), ["hex"] = hex:sub(1, 128), ["a space after it"] = good .. " \n",
            ["a line before it"] = "\n" .. good, ["twice"] = good .. "\n" .. good .. "\n" }) do
            refused("the signature is not 64 bytes in base64", check("plan/wax-own.list", fixture.list, text))
            t.ok(text ~= good, what)
        end
        refused("the signature is missing", check("plan/wax-own.list", fixture.list, nil))
        refused("the signature is missing", check("plan/wax-own.list", fixture.list, ("A"):rep(300)))
        for _, ending in ipairs({ "", "\n", "\r\n", "\n\n" }) do t.eq((check("plan/wax-own.list", fixture.list, good .. ending)), 200, ("%q"):format(ending)) end
    end)

    t.test("a signature by another key, or over another text, is bad", function()
        refused("the signature does not match", check("plan/wax-own.list", fixture.list, fixture.other))
        refused("the signature does not match", check("plan/wax-own.list", fixture.list, fixture.empty))
        refused("the signature does not match", check("plan/wax-own.list", "", fixture.good))
        local code, bytes = check("plan/wax-own.list", "", fixture.empty)
        t.eq(code, 200, "each signature is good for the text it was made over, an empty one too")
        t.eq(bytes, 0)
    end)

    t.test("a list that is missing or larger than 4 MB is not checked", function()
        refused("the list is missing or too large", check("plan/wax-own.list", nil, fixture.good))
        refused("the list is missing or too large", check("plan/wax-own.list", ("x"):rep(4 * 1024 * 1024 + 1), fixture.good))
        mkdir(NET .. "/plan/a folder.list")
        ask({ "=\tplan/a folder.list" })
        refused("the list is missing or too large", status("plan/a folder.list"))
    end)

    t.test("a list or a signature outside run/net is not looked at", function()
        local outside = { ROOT .. "/outside.list", ROOT .. "/run/outside.list", ROOT .. "/elsewhere/list.txt" }
        mkdir(ROOT .. "/elsewhere")
        for _, path in ipairs(outside) do
            write(path, fixture.list)
            write(path .. ".sig", fixture.good)
        end
        local linked = os.execute(('mklink /J "%s" "%s" >nul 2>nul'):format(win(NET .. "/link"), win(ROOT .. "/elsewhere")))
        write(NET .. "/kept.list", fixture.list)
        write(NET .. "/kept.list.sig", fixture.good)
        local lines = {}
        for _, name in ipairs({ "../outside.list", "../../outside.list", "plan/../../outside.list", "/outside.list", ROOT .. "/outside.list", "..\\outside.list",
            "plan\\..\\..\\outside.list", win(ROOT .. "/outside.list"), "link/list.txt", "nul", "con.list", "plan/wax-own.list.status", "plan/wax-own.list.part",
            "request.txt", "done", "" }) do
            lines[#lines + 1] = "=\t" .. name
        end
        lines[#lines + 1] = "=\tkept.list"
        t.eq(ask(lines), "#" .. number .. "\n")
        t.eq((status("kept.list")), 200, "the one good line in the request is still done")
        for _, path in ipairs(outside) do
            t.eq(read(path .. ".status"), nil, path)
            t.eq(read(path), fixture.list, path)
        end
        t.ok(linked, "a link from run/net to a folder outside it could be made for the test")
        t.eq(read(NET .. "/link/list.txt.status"), nil, "a link out of run/net is not followed")
        for _, path in ipairs({ ROOT .. "/run/outside.list.status", NET .. "/outside.list.status", NET .. "/request.txt.status", NET .. "/done.status",
            NET .. "/plan/wax-own.list.status.status", NET .. "/plan/wax-own.list.part.status", NET .. "/nul.status", NET .. "/con.list.status" }) do
            t.eq(read(path), nil, path)
        end
        os.execute(('rmdir "%s" >nul 2>nul'):format(win(NET .. "/link")))
        t.eq(read(ROOT .. "/elsewhere/list.txt"), fixture.list, "taking the link away left the folder it pointed at")
    end)

    t.test("checks, clearing and addresses go in one request, each with its own answer", function()
        mkdir(NET .. "/stage/Thing")
        write(NET .. "/stage/Thing/left.txt", "left over")
        write(NET .. "/plan/a.list", fixture.list)
        write(NET .. "/plan/a.list.sig", fixture.good)
        write(NET .. "/plan/b.list", fixture.list)
        write(NET .. "/plan/b.list.sig", fixture.other)
        t.eq(ask({ "=\tplan/a.list", "-\tstage/Thing", "/other\tother.json", "=\tplan/b.list", "=\tplan/a.list" }, 3), "#" .. number .. "\n")
        t.eq((status("plan/a.list")), 200)
        refused("the signature does not match", status("plan/b.list"))
        t.eq((status("stage/Thing")), 200)
        t.eq(read(NET .. "/stage/Thing/left.txt"), nil)
        refused("this address is not allowed", status("other.json"))
    end)
end

t.test("the helper as it is built for the game accepts no signature made with a key from a test", function()
    t.ok(use(REAL), "the DLL loads")
    mkdir(NET .. "/plan")
    local list = fixture and fixture.list or "wax 0.2.1\n"
    local cases = fixture and { fixture.good, fixture.other, fixture.empty } or {}
    cases[#cases + 1] = ("A"):rep(86) .. "==\n"
    -- a file built before signatures takes the line for an address, which is a refusal too. The last line of this suite says so
    local _, _, _, first_answer = check("plan/wax-own.list", list, cases[1])
    local stale = first_answer == "this address is not allowed"
    if stale then SUITE = ("waxnet (%s is older than wax/native/waxnet.c and checks no signatures: rebuild it with the game closed)"):format(DLL) end
    for _, signature in ipairs(cases) do
        for _, text in ipairs({ list, "" }) do
            local code, bytes, hash, why = check("plan/wax-own.list", text, signature)
            t.eq(code, 0)
            t.eq(bytes, 0)
            t.eq(hash, "-")
            -- until the owner's key is in waxnet.c nothing at all is good, whatever it is signed with
            if not has_key and not stale then t.eq(why, "this build has no signing key") end
        end
    end
    if not has_key and not stale then
        t.ok(built:find(("0"):rep(128), 1, true), "the placeholder is what the file holds in place of a key")
        refused("this build has no signing key", check("plan/wax-own.list", nil, nil))
    end
end)

if ROOT ~= REAL then skip("the DLL does not load") end
if not pcall(write, NET .. "/request.txt", "") then
    t.test("wax_net_ready makes run/net", function() error("run/net was not made") end)
    t.finish(SUITE)
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

t.finish(SUITE)
