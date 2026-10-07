-- Wax stage 0: answers commands sent from outside the game, runs Lua sent that way in developer mode only, and owns the one frame loop

-- a newer Wax that was downloaded and checked is put in here, before anything of it is loaded
pcall(dofile, (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\][^/\\]*$") or "ue4ss\\Mods\\Wax\\Scripts") .. "\\selfswap.lua")

local SLOTS = 8
local POLL_EVERY_FRAMES = 4
local MAX_COMMAND, MAX_LUA = 1024, 4 * 1024 * 1024

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = source:match("^(.*)[/\\][^/\\]*$") or "ue4ss\\Mods\\Wax\\Scripts"
local run_dir = script_dir .. "\\..\\run"
local wake_path = run_dir .. "\\in\\wake"
local dev_path = script_dir .. "\\..\\dev.txt"

-- Running this file again in a live game swaps the functions in. The loop registered the first time keeps going.
local previous = rawget(_G, "WaxStage0")
local stage = {
    frame = previous and previous.frame or 0,
    ready = previous and previous.ready or false,
    requests = previous and previous.requests or 0,
    started = previous and previous.started or os.time(),
    failures = 0,
}

local function json_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
        return map[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function describe_userdata(v)
    local ok, full = pcall(function() return v:GetFullName() end)
    if ok and type(full) == "string" then return full end
    local ok2, s = pcall(tostring, v)
    return ok2 and s or "<userdata>"
end

local function to_json(v, depth, seen)
    depth, seen = depth or 0, seen or {}
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return json_string(tostring(v)) end
        return math.type(v) == "integer" and tostring(v) or string.format("%.14g", v)
    end
    if t == "string" then return json_string(v) end
    if t == "table" then
        if seen[v] then return json_string("<cycle>") end
        if depth >= 6 then return json_string("<table>") end
        seen[v] = true
        local n, count = #v, 0
        for _ in pairs(v) do count = count + 1 end
        local parts = {}
        if n > 0 and count == n then
            for i = 1, n do parts[i] = to_json(v[i], depth + 1, seen) end
            seen[v] = nil
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, val in pairs(v) do
            parts[#parts + 1] = json_string(tostring(k)) .. ":" .. to_json(val, depth + 1, seen)
        end
        seen[v] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end
    if t == "userdata" then return json_string(describe_userdata(v)) end
    return json_string("<" .. t .. ">")
end

local function write_file(path, text)
    local f = io.open(path .. ".part", "wb")
    if not f then return false end
    f:write(text)
    f:close()
    os.remove(path)
    return os.rename(path .. ".part", path)
end

local function evaluate(code)
    local output = {}
    local env = setmetatable({
        print = function(...)
            local parts = table.pack(...)
            for i = 1, parts.n do parts[i] = tostring(parts[i]) end
            output[#output + 1] = table.concat(parts, "\t")
        end,
    }, { __index = _G, __newindex = _G })

    local chunk, err = load("return " .. code, "=eval", "t", env)
    if not chunk then chunk, err = load(code, "=eval", "t", env) end
    if not chunk then return { ok = false, error = err, output = output } end

    local results = table.pack(xpcall(chunk, debug.traceback))
    if not results[1] then return { ok = false, error = tostring(results[2]), output = output } end
    local values = {}
    for i = 2, results.n do values[i - 1] = results[i] == nil and "<nil>" or results[i] end
    return { ok = true, values = values, output = output }
end

-- Developer mode is a file named dev.txt in Wax's folder, beside Scripts. It is looked for when a request arrives, never between requests.
local function developer()
    local f = io.open(dev_path, "rb")
    if f then f:close() end
    return f ~= nil
end

local DEV_OFF = "Developer mode is off, so this was not run. Wax runs Lua sent from outside the game only in developer mode. To switch it on, put a file named dev.txt in Wax's folder (the one that holds Scripts), or run the command \"Wax: Switch Developer Mode On\" of the Wax extension for VS Code. While it is on, any program on this PC can run Lua in the game."

local function refuse(code, text) return { ok = false, code = code, error = text, output = {} } end

-- What can be asked for without developer mode. takes: the keys a request may give, one "key=value" line each.
local commands = {
    ["ping"] = { takes = {}, run = function()
        local info = stage.info()
        local wax = rawget(_G, "Wax")
        info.core = type(wax) == "table" and wax.frame ~= nil
        info.dev = developer()
        return { ok = true, values = { info }, output = {} }
    end },
    ["mod-added"] = { takes = { id = true }, run = function(given)
        local id = given.id
        if not id or #id > 64 or not id:match("^[A-Za-z][A-Za-z0-9_]*$") then
            return refuse("bad-request", "mod-added needs one line id=<Id>, where <Id> is the id of a mod")
        end
        -- the words of the notification are the core's, made from the mod's own files
        local wax = rawget(_G, "Wax")
        local mods = type(wax) == "table" and wax.frame and wax.mods
        if not (mods and mods.added) then return refuse("not-ready", "not ready: Wax has not started in the game yet") end
        local mod, problem = mods.added(id)
        if not mod then return refuse("no-mod", tostring(problem)) end
        return { ok = true, values = { mod }, output = {} }
    end },
}

-- A command is "--wax:<name>" and then the lines it takes. Anything else in it is refused, and none of it is ever run as Lua.
local function run_command(request)
    if not request.whole then return refuse("too-large", ("a command is at most %d bytes"):format(MAX_COMMAND)) end
    local lines = {}
    for line in (request.command .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
    while lines[#lines] == "" do lines[#lines] = nil end
    local command = commands[(lines[1] or ""):match("^%-%-wax:([a-z%-]+)$") or ""]
    if not command then return refuse("unknown-command", "unknown command. This Wax takes ping and mod-added") end
    local given = {}
    for index = 2, #lines do
        local key, value = lines[index]:match("^([a-z]+)=(.*)$")
        if not key or not command.takes[key] or given[key] ~= nil then
            return refuse("bad-request", "a command takes only the lines it names, each once, as key=value")
        end
        given[key] = value
    end
    local ok, reply = pcall(command.run, given)
    if not ok then return refuse("failed", "bridge failure: " .. tostring(reply)) end
    return reply
end

-- A request starts with the line "--id:<12 hex digits>". What follows is a command, or Lua, which is only read in developer mode.
local function read_request(f)
    local head = f:read(MAX_COMMAND + 1) or ""
    local id, rest = head:match("^%-%-id:(%x+)[ \t]*\r?\n(.*)$")
    if not id then id, rest = head:match("^%-%-id:(%x+)[ \t]*$"), "" end
    if not id or #id ~= 12 then return nil end
    if rest:sub(1, 6) == "--wax:" then return { id = id, command = rest, whole = #head <= MAX_COMMAND } end
    if not developer() then return { id = id, refused = true } end
    local more = f:read(MAX_LUA + 1 - #head) or ""
    return { id = id, code = head .. more, whole = #head + #more <= MAX_LUA }
end

local function handle(request)
    stage.requests = stage.requests + 1
    local reply
    if request.command then
        reply = run_command(request)
    elseif request.refused then
        reply = refuse("dev-off", DEV_OFF)
    elseif not request.whole then
        reply = refuse("too-large", "the request is larger than 4 MB")
    else
        local ok, result = pcall(evaluate, request.code)
        reply = ok and result or { ok = false, error = "bridge failure: " .. tostring(result), output = {} }
    end
    reply.id = request.id
    local okj, body = pcall(to_json, reply)
    if not okj then body = to_json({ ok = false, id = request.id, error = "unserializable result: " .. tostring(body), output = {} }) end
    write_file(run_dir .. "\\out\\" .. request.id .. ".json", body)
end

-- A client drops its request in a slot, then creates the wake file. Idle cost here is one failed open.
function stage.poll()
    local wake = io.open(wake_path, "rb")
    if not wake then return end
    wake:close()
    os.remove(wake_path)
    for slot = 0, SLOTS - 1 do
        local path = run_dir .. "\\in\\" .. slot .. ".lua"
        local f = io.open(path, "rb")
        if f then
            local ok, request = pcall(read_request, f)
            f:close()
            os.remove(path)
            if ok and request then ok, request = pcall(handle, request) end
            if not ok then print("[Wax] bridge error: " .. tostring(request) .. "\n") end
        end
    end
end

function stage.info()
    return { frame = stage.frame, uptime = os.time() - stage.started, requests = stage.requests, lua = _VERSION, thread = "game" }
end

local function start_core()
    local ok, err = xpcall(function()
        Wax = dofile(script_dir .. "/wax/loader.lua")(script_dir .. "/..")
        Wax.import("boot").start()
    end, debug.traceback)
    if not ok then print("[Wax] core failed to start: " .. tostring(err) .. "\n") end
end

function stage.tick()
    local frame = stage.frame + 1
    stage.frame = frame
    if not stage.ready then
        -- Early in start-up, object lookups by path throw until the engine's name tables exist.
        if not pcall(StaticFindObject, "/Engine/Transient") then return end
        stage.ready = true
        print("[Wax] bridge ready on the game thread, lua=" .. _VERSION .. ", run_dir=" .. run_dir .. "\n")
        start_core()
    end
    if frame % POLL_EVERY_FRAMES == 0 then
        local ok, err = pcall(stage.poll)
        if not ok then print("[Wax] poll error: " .. tostring(err) .. "\n") end
    end
    local wax = rawget(_G, "Wax")
    local core_frame = wax and wax.frame
    if core_frame then
        local ok, err = pcall(core_frame)
        if not ok then
            stage.failures = stage.failures + 1
            if stage.failures <= 3 then print("[Wax] core frame error: " .. tostring(err) .. "\n") end
        end
    end
end

WaxStage0 = stage
if previous then return end

ExecuteInGameThread(function()
    LoopInGameThreadAfterFrames(1, function()
        pcall(rawget(_G, "WaxStage0").tick)
        return false
    end)
end)
