-- Mods that are not Wax's: UE4SS mods beside Wax, and pak mods the game loads at start. Listed so the player sees them, with a switch for the UE4SS ones.
local Wax = ...
local sched = Wax.import("core.sched")

local M = {}
M.CACHE_SECONDS = 10

local cached, cached_at = nil, nil

local function segments_of(path)
    local segments = {}
    for part in path:gmatch("[^/\\]+") do
        if part == ".." then segments[#segments] = nil elseif part ~= "." then segments[#segments + 1] = part end
    end
    return segments
end

-- The game's root folder as UE4SS lists it, and the ue4ss Mods folder Wax sits in.
local function nodes()
    local list = rawget(_G, "IterateGameDirectories")
    if type(list) ~= "function" then return nil end
    local ok, root = pcall(list)
    if not ok or type(root) ~= "table" or type(root.Game) ~= "table" then return nil end
    local segments = segments_of(Wax.root)
    local start = nil
    for i = #segments, 1, -1 do
        if segments[i] == "Binaries" then
            start = i
            break
        end
    end
    if not start then return nil end
    local node = root.Game
    for i = start, #segments - 1 do
        node = type(node) == "table" and node[segments[i]] or nil
    end
    if type(node) ~= "table" then return nil end
    return root.Game, node
end

local function files_of(node)
    local out = {}
    for _, file in ipairs(type(node) == "table" and node.__files or {}) do
        if type(file.__name) == "string" then out[file.__name] = true end
    end
    return out
end

local function list_path(mods_node)
    return tostring(mods_node.__absolute_path or ""):gsub("\\", "/") .. "/mods.txt"
end

-- Mods switched on in UE4SS's own list, mods.txt.
local function listed_on(mods_node)
    local on = {}
    local file = io.open(list_path(mods_node), "rb")
    if not file then return on end
    for line in file:lines() do
        local name, value = line:match("^%s*([%w_%-]+)%s*:%s*(%d)")
        if name and value == "1" then on[name] = true end
    end
    file:close()
    return on
end

-- A "Name : 1" line in mods.txt starts the mod too, so switching off turns that line to 0.
local function list_off(mods_node, name)
    local path = list_path(mods_node)
    local file = io.open(path, "rb")
    if not file then return true end
    local text = file:read("a")
    file:close()
    local pattern = "^(%s*" .. name:gsub("%W", "%%%0") .. "%s*:%s*)1(%s*)$"
    local lines, changed = {}, false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local head, tail = line:match(pattern)
        if head then
            line = head .. "0" .. tail
            changed = true
        end
        lines[#lines + 1] = line
    end
    if not changed then return true end
    local out, err = io.open(path, "wb")
    if not out then return false, ("mods.txt could not be written (%s)"):format(tostring(err)) end
    local ends_with_newline = text:sub(-1) == "\n"
    if ends_with_newline then lines[#lines] = nil end
    out:write(table.concat(lines, "\n"))
    if ends_with_newline then out:write("\n") end
    out:close()
    return true
end

local function paks_in(node)
    local out = {}
    for name in pairs(files_of(node)) do
        if name:lower():match("%.pak$") then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

function M.list(force)
    local now = sched.clock()
    if cached and not force and cached_at and now - cached_at < M.CACHE_SECONDS then return cached end
    local out = { ue4ss = {}, paks = {}, logic = {}, loader = "missing", listed = false }
    local game, mods_node = nodes()
    if mods_node then
        out.listed = true
        local on = listed_on(mods_node)
        for name, child in pairs(mods_node) do
            if type(name) == "string" and type(child) == "table" and name:sub(1, 2) ~= "__" and name ~= "Wax" then
                local files = files_of(child)
                local scripts = files_of(child.Scripts)
                if scripts["main.lua"] then
                    out.ue4ss[#out.ue4ss + 1] = { name = name, enabled = files["enabled.txt"] == true or on[name] == true, by_list = on[name] == true }
                end
            end
        end
        table.sort(out.ue4ss, function(a, b) return a.name < b.name end)
        local loader = mods_node.BPModLoaderMod
        if type(loader) == "table" then
            out.loader = (files_of(loader)["enabled.txt"] or on.BPModLoaderMod) and "on" or "off"
        end
        local paks = type(game) == "table" and type(game.Content) == "table" and game.Content.Paks or nil
        if type(paks) == "table" then
            out.paks = paks_in(paks.mods)
            out.logic = paks_in(paks.LogicMods)
        end
    end
    cached, cached_at = out, now
    return out
end

-- Switches a UE4SS mod on or off for the next start of the game: enabled.txt in its folder, and its line in mods.txt.
function M.set_enabled(name, on)
    local _, mods_node = nodes()
    local child = mods_node and type(name) == "string" and mods_node[name] or nil
    if type(child) ~= "table" or name:sub(1, 2) == "__" then return false, ("no UE4SS mod named %s"):format(tostring(name)) end
    local path = tostring(child.__absolute_path or ""):gsub("\\", "/") .. "/enabled.txt"
    if on then
        local file, err = io.open(path, "wb")
        if not file then return false, ("enabled.txt could not be written (%s)"):format(tostring(err)) end
        file:close()
    else
        local gone, err, errno = os.remove(path)
        if not gone and errno ~= 2 then return false, ("enabled.txt could not be removed (%s)"):format(tostring(err)) end
        local ok, problem = list_off(mods_node, name)
        if not ok then return false, problem end
    end
    cached = nil
    return true
end

function M.signature()
    local found = M.list()
    local parts = {}
    for _, entry in ipairs(found.ue4ss) do parts[#parts + 1] = entry.name .. (entry.enabled and "+" or "-") end
    for _, name in ipairs(found.paks) do parts[#parts + 1] = "pak:" .. name end
    for _, name in ipairs(found.logic) do parts[#parts + 1] = "bp:" .. name end
    parts[#parts + 1] = "loader:" .. found.loader
    return table.concat(parts, "|")
end

return M
