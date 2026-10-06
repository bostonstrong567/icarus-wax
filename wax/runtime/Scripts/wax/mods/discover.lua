-- Finds mods: every folder in <Wax>/mods, plus anything the command-line tool listed in run/mods.index.lua

local Wax = ...

local discover = {}

local ID_PATTERN = "^[%w_%-]+$"

local function collect(node, prefix, files)
    local list = node.__files
    if list then
        for i = 1, #list do files[prefix .. list[i].__name] = true end
    end
    for name, child in pairs(node) do
        if type(name) == "string" and type(child) == "table" and name:sub(1, 2) ~= "__" then
            collect(child, prefix .. name .. "/", files)
        end
    end
end

-- UE4SS can list the game's folders. Wax's own folder is reached by its path below Binaries.
local function mods_folder()
    local list_folders = rawget(_G, "IterateGameDirectories")
    if type(list_folders) ~= "function" then return nil end
    local segments = {}
    for part in Wax.root:gmatch("[^/\\]+") do
        if part == ".." then segments[#segments] = nil elseif part ~= "." then segments[#segments + 1] = part end
    end
    local start = nil
    for i = #segments, 1, -1 do
        if segments[i] == "Binaries" then
            start = i
            break
        end
    end
    if not start then return nil end
    local node = list_folders().Game
    for i = start, #segments do
        if type(node) ~= "table" then return nil end
        node = node[segments[i]]
    end
    return type(node) == "table" and node.mods or nil
end

local function from_folder(found, notes)
    local ok, folder = pcall(mods_folder)
    if not ok then
        notes[#notes + 1] = "could not list the mods folder: " .. tostring(folder)
        return
    end
    if type(folder) ~= "table" then return end
    local names = {}
    for name, child in pairs(folder) do
        -- a folder whose name starts with a dot is one the user removed, kept so it can be put back
        if type(name) == "string" and type(child) == "table" and name:sub(1, 2) ~= "__" and name:sub(1, 1) ~= "." then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local node = folder[name]
        local files = {}
        collect(node, "", files)
        if not name:match(ID_PATTERN) then
            notes[#notes + 1] = ("skipped mods/%s: a mod folder's name may only use letters, digits, _ and -"):format(name)
        elseif not (files["init.lua"] or files["mod.lua"]) then
            notes[#notes + 1] = ("skipped mods/%s: it has no init.lua"):format(name)
        else
            found[#found + 1] = { id = name, dir = (tostring(node.__absolute_path):gsub("\\", "/")), files = files }
        end
    end
end

local function from_index(found)
    local file = io.open(Wax.root .. "/run/mods.index.lua", "rb")
    if not file then return end
    local text = file:read("a")
    file:close()
    local chunk = load(text, "=mods.index", "t", {})
    local ok, index = pcall(chunk or error)
    if not ok or type(index) ~= "table" then return end
    local known = {}
    for _, entry in ipairs(found) do known[entry.id] = true end
    for _, entry in ipairs(index.mods or {}) do
        if not known[entry.id] then
            local files = {}
            for _, name in ipairs(entry.files or {}) do files[name] = true end
            found[#found + 1] = { id = entry.id, dir = entry.dir, files = files }
        end
    end
end

-- Returns a list of { id, dir, files = { ["relative/path.lua"] = true } } and a list of notes for the log.
function discover.all()
    local found, notes = {}, {}
    from_folder(found, notes)
    from_index(found)
    return found, notes
end

return discover
