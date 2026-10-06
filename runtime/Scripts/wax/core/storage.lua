-- Small files of settings that survive restarting the game: <Wax>/saved/<owner>.<name>.lua

local Wax = ...
local sched = Wax.import("core.sched")
local log = Wax.import("core.log").channel("wax.storage")

local storage = {}

local SETTLE_SECONDS = 0.6          -- several saves in a row become one write
local NAME_PATTERN = "^[%w_%-]+$"

storage.directory = Wax.root .. "/saved"    -- nil switches storage off (tests)
local pending = {}                  -- path -> { text, at }

local function serialize(value, indent, seen)
    local kind = type(value)
    if kind == "string" then return ("%q"):format(value) end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "0" end
        return math.type(value) == "integer" and tostring(value) or ("%.17g"):format(value)
    end
    if kind == "boolean" then return tostring(value) end
    if kind ~= "table" then return "nil" end
    if seen[value] then error("a table that contains itself cannot be saved", 0) end
    seen[value] = true
    local keys = {}
    for key in pairs(value) do
        if type(key) == "string" or type(key) == "number" then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    local inner, lines = indent .. "    ", {}
    for _, key in ipairs(keys) do
        local name = type(key) == "string" and ("[%q]"):format(key) or ("[%s]"):format(tostring(key))
        lines[#lines + 1] = inner .. name .. " = " .. serialize(value[key], inner, seen) .. ","
    end
    seen[value] = nil
    if #lines == 0 then return "{}" end
    return "{\n" .. table.concat(lines, "\n") .. "\n" .. indent .. "}"
end

local function path_of(owner, name)
    if type(owner) ~= "string" or not owner:match(NAME_PATTERN) then error("storage owner must be a simple name", 3) end
    if type(name) ~= "string" or not name:match(NAME_PATTERN) then
        error("a storage name may only use letters, digits, _ and - (got " .. tostring(name) .. ")", 3)
    end
    return storage.directory and (storage.directory .. "/" .. owner .. "." .. name .. ".lua") or nil
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = copy(item) end
    return out
end

-- Returns a copy of `defaults` with whatever was saved before laid over it.
function storage.load(owner, name, defaults)
    local out = copy(defaults or {})
    local path = path_of(owner, name)
    local queued = path and pending[path]
    local text = queued and queued.text
    if not text and path then
        local file = io.open(path, "rb")
        if file then
            text = file:read("a")
            file:close()
        end
    end
    if not text then return out end
    local chunk = load(text, "=saved", "t", {})
    local ok, saved = pcall(chunk or error)
    if not ok or type(saved) ~= "table" then
        log:warn("%s.%s could not be read and was ignored", owner, name)
        return out
    end
    for key, value in pairs(saved) do out[key] = value end
    return out
end

-- Queues the table to be written. Only plain data is kept: numbers, strings, booleans and tables of them.
function storage.save(owner, name, value)
    if type(value) ~= "table" then error("storage saves a table, got " .. type(value), 2) end
    local path = path_of(owner, name)
    if not path then return end
    pending[path] = { text = "return " .. serialize(value, "", {}) .. "\n", at = sched.clock() }
end

local function write(path, entry)
    local file = io.open(path, "wb")
    if not file then
        log:warn("could not write %s (check that the saved folder exists)", path)
        return
    end
    file:write(entry.text)
    file:close()
end

-- Called every frame. Writes what has waited long enough.
function storage.step()
    if next(pending) == nil then return end
    local now = sched.clock()
    for path, entry in pairs(pending) do
        if now - entry.at >= SETTLE_SECONDS then
            pending[path] = nil
            write(path, entry)
        end
    end
end

function storage.flush()
    for path, entry in pairs(pending) do write(path, entry) end
    pending = {}
end

return storage
