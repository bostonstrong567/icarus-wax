-- Wax stage 0: runs Lua sent from outside the game, and owns the one frame loop

local SLOTS = 8
local POLL_EVERY_FRAMES = 4

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = source:match("^(.*)[/\\][^/\\]*$") or "ue4ss\\Mods\\Wax\\Scripts"
local run_dir = script_dir .. "\\..\\run"
local wake_path = run_dir .. "\\in\\wake"

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

local function handle(text)
    local id = text:match("^%-%-id:(%S+)")
    if not id then return end
    stage.requests = stage.requests + 1
    local ok, reply = pcall(evaluate, text)
    if not ok then reply = { ok = false, error = "bridge failure: " .. tostring(reply), output = {} } end
    reply.id = id
    local okj, body = pcall(to_json, reply)
    if not okj then body = to_json({ ok = false, id = id, error = "unserializable result: " .. tostring(body), output = {} }) end
    write_file(run_dir .. "\\out\\" .. id .. ".json", body)
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
            local text = f:read("a")
            f:close()
            os.remove(path)
            local ok, err = pcall(handle, text)
            if not ok then print("[Wax] bridge error: " .. tostring(err) .. "\n") end
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
