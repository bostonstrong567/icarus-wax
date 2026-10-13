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

-- The saved folder the way the game lists it, or nil when that list has no such folder.
local function saved_node()
    local list_folders = rawget(_G, "IterateGameDirectories")
    if type(list_folders) ~= "function" or not storage.directory then return nil end
    local segments = {}
    for part in storage.directory:gmatch("[^/\\]+") do
        if part == ".." then segments[#segments] = nil elseif part ~= "." then segments[#segments + 1] = part end
    end
    local start = nil
    for index = #segments, 1, -1 do
        if segments[index] == "Binaries" then start = index break end
    end
    if not start then return nil end
    local ok, listed = pcall(list_folders)
    if not ok or type(listed) ~= "table" then return nil end
    local node = listed.Game
    for index = start, #segments do
        if type(node) ~= "table" then return nil end
        node = node[segments[index]]
    end
    return type(node) == "table" and node or nil
end

-- File names in the saved folder. The game's own list wins. A folder it does not show is read from disk.
local function saved_file_names()
    local names = {}
    local node = saved_node()
    if node and type(node.__files) == "table" then
        for index = 1, #node.__files do
            local name = node.__files[index] and node.__files[index].__name
            if type(name) == "string" and name ~= "" then names[#names + 1] = name end
        end
        return names
    end
    if not storage.directory then return names end
    local handle = io.popen('cmd /c dir /b /a-d "' .. storage.directory:gsub("/", "\\") .. '" 2>nul')
    if not handle then return names end
    for line in handle:lines() do
        line = line:gsub("\r", "")
        if line ~= "" then names[#names + 1] = line end
    end
    handle:close()
    return names
end

-- owner -> { name, ... } for saved/<owner>.<name>.lua. Anything else in the folder is left alone.
function storage.owners()
    local owners = {}
    for _, file in ipairs(saved_file_names()) do
        local owner, name = file:match("^([%w_%-]+)%.([%w_%-]+)%.lua$")
        if owner then
            local list = owners[owner]
            if not list then list = {} owners[owner] = list end
            list[#list + 1] = name
        end
    end
    return owners
end

function storage.names(owner)
    if type(owner) ~= "string" then return {} end
    return storage.owners()[owner] or {}
end

-- Deletes saved/<owner>.*.lua and drops a save that was still waiting to be written.
-- Wax's own files (owner "wax") stay: those are the mod list, the window, and update settings.
function storage.discard(owner)
    if type(owner) ~= "string" or not owner:match(NAME_PATTERN) then return nil, "a storage owner must be a simple name" end
    if owner == "wax" then return nil, "Wax's own saved files stay" end
    local removed = 0
    for _, name in ipairs(storage.names(owner)) do
        local path = path_of(owner, name)
        if path then
            pending[path] = nil
            if os.remove(path) then removed = removed + 1 end
        end
    end
    return removed
end

return storage
