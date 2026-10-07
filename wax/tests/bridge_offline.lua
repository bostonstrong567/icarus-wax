-- Offline check of the bridge against a fake UE4SS: one frame loop, a request file in, a reply file out,
-- commands for everyone, and Lua only while dev.txt stands in Wax's folder.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\bridge_offline.lua <scratch dir>
-- <scratch dir> must contain run/in and run/out.

local root = assert(arg[1], "usage: bridge_offline.lua <scratch dir>")
local run = root .. "/run"

local loops, handoffs, lookups = {}, 0, 0
function ExecuteInGameThread(fn) handoffs = handoffs + 1; fn() end
function LoopInGameThreadAfterFrames(_, fn) loops[#loops + 1] = fn end
function StaticFindObject()
    lookups = lookups + 1
    if lookups < 3 then error("engine not ready") end
    return {}
end
-- Anything that would run Lua off the game thread is a failure.
for _, name in ipairs({ "LoopAsync", "ExecuteAsync", "ExecuteWithDelay", "RegisterKeyBind" }) do
    _G[name] = function() error(name .. " must not be used by the bridge") end
end

-- The bridge locates its run folder from its own path, so present it as living next to the scratch run folder.
local real_getinfo = debug.getinfo
debug.getinfo = function() return { source = "@" .. root .. "/Scripts/main.lua" } end
dofile("wax/runtime/Scripts/main.lua")

local checks = 0
local function check(condition, what)
    checks = checks + 1
    if not condition then error(what, 2) end
end

check(handoffs == 1, "expected exactly one hand-off to the game thread, got " .. handoffs)
check(#loops == 1, "expected exactly one frame loop, got " .. #loops)

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

local function send(slot, text, wake)
    local request = assert(io.open(run .. "/in/" .. slot .. ".lua", "wb"))
    request:write(text)
    request:close()
    if wake then assert(io.open(run .. "/in/wake", "wb")):close() end
end

local function frames(count)
    for _ = 1, count do loops[1]() end
end

local function replies()
    local names = {}
    local pipe = io.popen(('dir /b /a:-d "%s" 2>nul'):format((run .. "/out"):gsub("/", "\\")))
    for line in pipe:lines() do names[#names + 1] = line end
    pipe:close()
    return names
end

local function take(id)
    local path = run .. "/out/" .. id .. ".json"
    local f = io.open(path, "rb")
    if not f then return nil end
    local body = f:read("a")
    f:close()
    os.remove(path)
    return body
end

local sent = 0
-- Sends what follows the id line as one request and returns the reply, or nil when the bridge wrote none.
local function ask(rest, ending)
    sent = sent + 1
    local id = ("%012x"):format(sent)
    send(sent % 8, "--id:" .. id .. (ending or "\n") .. rest, true)
    frames(8)
    check(not exists(run .. "/in/" .. (sent % 8) .. ".lua"), "the request file was not consumed: " .. rest:sub(1, 60))
    check(not exists(run .. "/in/wake"), "the wake file was not consumed")
    local body = take(id)
    check(#replies() == 0, "a reply was written under another name than the request's id")
    return body
end

local function has(body, fragment) return body ~= nil and body:find(fragment, 1, true) ~= nil end

-- A reply that refuses, with that code.
local function refused(body, code, what)
    check(has(body, '"ok":false'), what .. ": expected a refusal, got " .. tostring(body))
    check(has(body, '"code":"' .. code .. '"'), what .. ": expected the code " .. code .. ", got " .. tostring(body))
end

local function dev(on)
    if on then assert(io.open(root .. "/dev.txt", "wb")):close() else os.remove(root .. "/dev.txt") end
end

-- Idle: nothing is written to disk, however long the game runs.
local writes = 0
local real_open = io.open
io.open = function(path, mode)
    if mode and mode:find("[wa+]") then writes = writes + 1 end
    return real_open(path, mode)
end
frames(600)
io.open = real_open
check(writes == 0, "the idle bridge wrote to disk " .. writes .. " times")
check(not exists(run .. "/alive.json"), "the bridge must not write a heartbeat file")

-- Idle, the bridge does not look for dev.txt either: one probe for the wake file every fourth frame and nothing else.
local opened = {}
io.open = function(path, mode)
    opened[#opened + 1] = path
    return real_open(path, mode)
end
frames(40)
io.open = real_open
check(#opened == 10, "expected 10 probes in 40 frames, got " .. #opened)
for _, path in ipairs(opened) do check(path:find("wake", 1, true), "an idle frame opened " .. path) end

-- A player's install: no dev.txt. Lua is refused and none of it runs.
dev(false)
BRIDGE_RAN = nil
local body = ask("BRIDGE_RAN = true return 6 * 7")
refused(body, "dev-off", "Lua without developer mode")
check(has(body, "dev.txt") and has(body, "Developer mode is off"), "the refusal does not say how developer mode is switched on: " .. body)
check(BRIDGE_RAN == nil, "Lua ran without developer mode")
for _, sneaky in ipairs({
    " --wax:ping\nBRIDGE_RAN = true",
    "\n--wax:ping\nBRIDGE_RAN = true",
    "--WAX:ping\nBRIDGE_RAN = true",
    "-- wax:ping\nBRIDGE_RAN = true",
    "\239\187\191--wax:ping\nBRIDGE_RAN = true",
    "BRIDGE_RAN = true --wax:ping",
    "",
}) do
    refused(ask(sneaky), "dev-off", "Lua dressed as a command")
    check(BRIDGE_RAN == nil, "Lua ran without developer mode: " .. sneaky)
end

-- Commands are answered without it.
body = ask("--wax:ping")
check(has(body, '"ok":true') and has(body, '"thread":"game"'), "ping was not answered: " .. tostring(body))
check(has(body, '"dev":false') and has(body, '"core":false'), "ping does not say that developer mode is off and the core is not up: " .. body)
check(has(ask("--wax:ping\n"), '"ok":true'), "ping with a line ending after it")
check(has(ask("--wax:ping\r\n", "\r\n"), '"ok":true'), "ping with Windows line endings")
check(has(ask("--wax:ping\n\n\n"), '"ok":true'), "ping with empty lines after it")

-- A command that needs the core says so while there is none.
body = ask("--wax:mod-added\nid=Hello")
refused(body, "not-ready", "mod-added before the core is up")
check(has(body, '"error":"not ready'), "the answer does not start with the words not ready: " .. body)

-- What is not a command exactly is refused, and nothing in it runs.
refused(ask("--wax:run\nBRIDGE_RAN = true"), "unknown-command", "an unknown command")
refused(ask("--wax:"), "unknown-command", "a command without a name")
refused(ask("--wax:ping now"), "unknown-command", "a command with words after its name")
refused(ask("--wax:Ping"), "unknown-command", "a command in capitals")
refused(ask("--wax:ping\nBRIDGE_RAN = true"), "bad-request", "ping with Lua after it")
refused(ask("--wax:ping\nid=Hello"), "bad-request", "ping with a line it does not take")
refused(ask("--wax:ping\n\nid=Hello"), "bad-request", "ping with an empty line in the middle")
refused(ask("--wax:mod-added"), "bad-request", "mod-added without an id")
refused(ask("--wax:mod-added\nid=Hello\nid=Other"), "bad-request", "mod-added with two ids")
refused(ask("--wax:mod-added\nid=Hello\nname=A nicer name"), "bad-request", "mod-added with a name")
refused(ask("--wax:mod-added\nid=Hello\nBRIDGE_RAN = true"), "bad-request", "mod-added with Lua after it")
refused(ask("--wax:mod-added\nID=Hello"), "bad-request", "mod-added with the key in capitals")
check(BRIDGE_RAN == nil, "a line of a refused command ran")

-- A core that is up: mod-added reaches it with a checked id, and only then.
local calls, answer = {}, nil
Wax = { frame = function() end, mods = { added = function(id)
    calls[#calls + 1] = id
    if answer then return answer() end
    return { id = id, name = "Hello Mod", version = "1.0.0", status = "disabled", enabled = false, fresh = true }
end } }
body = ask("--wax:mod-added\nid=Hello")
check(has(body, '"ok":true') and has(body, '"id":"Hello"') and has(body, '"fresh":true') and has(body, '"name":"Hello Mod"'),
    "mod-added was not answered with what the loader said: " .. tostring(body))
check(#calls == 1 and calls[1] == "Hello", "the loader was not asked once, for Hello")
check(has(ask("--wax:mod-added\r\nid=Hello_2\r\n", "\r\n"), '"id":"Hello_2"'), "mod-added with Windows line endings")
check(has(ask("--wax:mod-added\nid=" .. ("a"):rep(64)), '"ok":true'), "an id of 64 characters")
calls = {}
for _, bad in ipairs({ "", " ", "1Hello", "_Hello", "Hello World", "Hello-World", "Hello.lua", "../Hello", "..\\Hello", "C:/Hello", "Hello/init",
    "Hello;os.exit()", "Hello\"", "Hello'", "H\195\169llo", "Hello\t", " Hello", "Hello ", ("a"):rep(65), "%s", "Hello\0" }) do
    refused(ask("--wax:mod-added\nid=" .. bad), "bad-request", ("the id %q"):format(bad))
end
check(#calls == 0, "the loader was asked about an id that is not one")
answer = function() return nil, "no mod named 'Ghost' is in the mods folder" end
body = ask("--wax:mod-added\nid=Ghost")
refused(body, "no-mod", "a mod that is not there")
check(has(body, "no mod named 'Ghost'"), "the answer does not say which mod is missing: " .. body)
answer = function() error("the loader broke") end
body = ask("--wax:mod-added\nid=Hello")
refused(body, "failed", "a loader that raises")
check(has(body, "bridge failure") and has(body, "the loader broke"), "the answer does not say what failed: " .. body)
answer = nil
Wax.frame = nil
refused(ask("--wax:mod-added\nid=Hello"), "not-ready", "a core that did not finish starting")
check(has(ask("--wax:ping"), '"core":false'), "ping said the core is up while it did not finish starting")
Wax.frame = function() end
check(has(ask("--wax:ping"), '"core":true'), "ping does not say the core is up")
Wax = nil

-- A request that is too large is refused whole. A command is small, so a large one is never even read.
calls = {}
refused(ask("--wax:mod-added\nid=Hello\n" .. ("x=1\n"):rep(500000)), "too-large", "a command of 2 MB")
refused(ask("--wax:ping" .. (" "):rep(2000)), "too-large", "a command padded past its limit")
local reads = {}
local real_read = getmetatable(io.stdout).__index.read
getmetatable(io.stdout).__index.read = function(file, ...)
    local got = real_read(file, ...)
    reads[#reads + 1] = type(got) == "string" and #got or 0
    return got
end
refused(ask("BRIDGE_RAN = true --" .. ("x"):rep(3000000)), "dev-off", "3 MB of Lua without developer mode")
getmetatable(io.stdout).__index.read = real_read
local most = 0
for _, size in ipairs(reads) do most = math.max(most, size) end
check(most <= 1025, "without developer mode more than the head of a request was read: " .. most .. " bytes")
check(BRIDGE_RAN == nil, "Lua ran without developer mode")

-- A request without a proper id line gets no answer, and nothing is written anywhere for it.
local function unanswered(text, what)
    send(3, text, true)
    frames(8)
    check(not exists(run .. "/in/3.lua"), what .. ": the request file was not consumed")
    check(#replies() == 0, what .. ": something was written to run/out")
    check(BRIDGE_RAN == nil, what .. ": it ran")
end
unanswered("BRIDGE_RAN = true", "no id line")
unanswered("--id:t1\nBRIDGE_RAN = true", "an id that is not 12 hex digits")
unanswered("--id:00000000000g\n--wax:ping", "an id with a letter that is not hex")
unanswered("--id:0000000000001\n--wax:ping", "an id of 13 digits")
unanswered("--id:..\\..\\evil0\n--wax:ping", "an id that is a path")
unanswered("--id:../../../evil\n--wax:ping", "an id that is a path")
unanswered("--id:000000000001 thread:game\n--wax:ping", "words after the id")
unanswered(" --id:000000000001\n--wax:ping", "a space before the id line")
unanswered("", "an empty request")
check(not exists(root .. "/evil.json") and not exists(run .. "/evil.json") and not exists(run .. "/evil0.json"), "a reply was written outside run/out")

-- Developer mode: dev.txt beside Scripts. Lua runs, and the reply carries what it returned and printed.
dev(true)
body = ask("print('hi') return 6 * 7, { a = 1 }")
check(has(body, '"values":[42,{"a":1}]'), "unexpected values in reply: " .. tostring(body))
check(has(body, '"output":["hi"]'), "print output was not captured: " .. body)
check(has(ask("--wax:ping"), '"dev":true'), "ping does not say that developer mode is on")

-- Two clients at once: both slots are answered from one wake.
send(1, "--id:aaaaaaaaaaa1\nreturn 'one'", false)
send(5, "--id:AAAAAAAAAAA2\nreturn WaxStage0.info().thread", true)
frames(8)
check(has(take("aaaaaaaaaaa1"), '"values":["one"]') and has(take("AAAAAAAAAAA2"), '"values":["game"]'), "a request in another slot was missed")

-- A command stays a command in developer mode: what follows it is never run.
refused(ask("--wax:ping\nBRIDGE_RAN = true"), "bad-request", "ping with Lua after it, in developer mode")
check(BRIDGE_RAN == nil, "a line of a refused command ran in developer mode")
refused(ask("BRIDGE_RAN = true --" .. ("x"):rep(4 * 1024 * 1024)), "too-large", "more than 4 MB of Lua")
check(BRIDGE_RAN == nil, "a request that is too large ran")
check(has(ask("return #" .. ("%q"):format(("x"):rep(1000000))), '"values":[1000000]'), "1 MB of Lua was not run")

-- The file is looked for at each request, so taking it away switches Lua off at once.
dev(false)
refused(ask("BRIDGE_RAN = true"), "dev-off", "Lua after dev.txt was taken away")
check(BRIDGE_RAN == nil, "Lua ran after dev.txt was taken away")
dev(true)
check(has(ask("return 1 + 1"), '"values":[2]'), "Lua was not run after dev.txt came back")

-- Running the file again in the same Lua state swaps the code in without a second loop.
local before = WaxStage0.frame
dofile("wax/runtime/Scripts/main.lua")
debug.getinfo = real_getinfo
check(handoffs == 1 and #loops == 1, "re-running the bridge registered another loop")
loops[1]()
check(WaxStage0.frame == before + 1, "the frame count did not carry over a re-run")
check(has(ask("return 'still here'"), '"values":["still here"]'), "the bridge did not answer after a re-run")
dev(false)

print(("bridge offline test: PASS (%d checks, start-up frames skipped while the engine was not ready: %d)"):format(checks, lookups - 1))
