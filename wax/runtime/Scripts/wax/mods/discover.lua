-- Finds mods: every folder in <Wax>/mods and, in developer mode only, what the command-line tool listed in run/mods.index.lua

local Wax = ...

local discover = {}

local ID_PATTERN = "^[%w_%-]+$"
local MAX_ID, MAX_INDEXED, MAX_FILES, MAX_NAME = 64, 200, 2000, 200

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

-- UE4SS lists the game's folders, and Wax's own is reached by its path below Binaries. Returns the mods folder, and true when Wax's folder was listed.
local function mods_folder()
    local list_folders = rawget(_G, "IterateGameDirectories")
    if type(list_folders) ~= "function" then return nil, false end
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
    if not start then return nil, false end
    local node = list_folders().Game
    for i = start, #segments do
        if type(node) ~= "table" then return nil, false end
        node = node[segments[i]]
    end
    if type(node) ~= "table" then return nil, false end
    return type(node.mods) == "table" and node.mods or nil, true
end

-- True when the folders could be listed, so that what is not in `found` is really not there.
local function from_folder(found, notes)
    local ok, folder, listed = pcall(mods_folder)
    if not ok then
        notes[#notes + 1] = "could not list the mods folder: " .. tostring(folder)
        return false
    end
    if type(folder) ~= "table" then return listed == true end
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
    return true
end

-- Developer mode is a file named dev.txt in Wax's own folder. A player's install has none.
function discover.developer()
    local file = io.open(Wax.root .. "/dev.txt", "rb")
    if file then file:close() end
    return file ~= nil
end

-- A file as the index names it: a path inside the mod's folder, with nothing in it that leads out.
local function inside(name)
    return type(name) == "string" and name ~= "" and #name <= MAX_NAME and not name:find("[%c:\\]")
        and name:sub(1, 1) ~= "/" and not name:find("..", 1, true) and not name:find("//", 1, true)
end

-- One entry of the index as a mod, or nil and what is wrong with it.
local function from_entry(entry)
    if type(entry) ~= "table" then return nil, "it is not a table" end
    local id, dir = entry.id, entry.dir
    if type(id) ~= "string" or #id > MAX_ID or not id:match(ID_PATTERN) then return nil, "its id may only use letters, digits, _ and -" end
    if type(dir) ~= "string" or dir:find("%c") then return nil, "it names no folder" end
    dir = dir:gsub("\\", "/"):gsub("/+$", "")
    if not dir:match("^%a:/") or dir:find(":", 3, true) then return nil, "its folder is not a full path on a drive" end
    for part in dir:sub(3):gmatch("/([^/]*)") do
        if part == "" or part == "." or part == ".." then return nil, "its folder is not a plain path" end
    end
    if dir:match("([^/]+)$") ~= id then return nil, "its folder is not named after the mod" end
    if type(entry.files) ~= "table" then return nil, "it lists no files" end
    local files, count = {}, 0
    for _, name in ipairs(entry.files) do
        if not inside(name) then return nil, "it lists a file that is not inside its folder" end
        count = count + 1
        if count > MAX_FILES then return nil, ("it lists more than %d files"):format(MAX_FILES) end
        files[name] = true
    end
    if not (files["init.lua"] or files["mod.lua"]) then return nil, "it has no init.lua" end
    local file = (files["mod.lua"] and io.open(dir .. "/mod.lua", "rb")) or (files["init.lua"] and io.open(dir .. "/init.lua", "rb"))
    if not file then return nil, "its folder is not there" end
    file:close()
    return { id = id, dir = dir, files = files }
end

local function from_index(found, notes)
    if not discover.developer() then return end
    local file = io.open(Wax.root .. "/run/mods.index.lua", "rb")
    if not file then return end
    local text = file:read("a")
    file:close()
    local chunk = load(text, "=mods.index", "t", {})
    local ok, index = pcall(chunk or error)
    if not ok or type(index) ~= "table" or type(index.mods) ~= "table" then
        notes[#notes + 1] = "run/mods.index.lua could not be read and was ignored"
        return
    end
    local known = {}
    for _, entry in ipairs(found) do known[entry.id] = true end
    for position, entry in ipairs(index.mods) do
        if position > MAX_INDEXED then
            notes[#notes + 1] = ("run/mods.index.lua lists more than %d mods. The rest were ignored"):format(MAX_INDEXED)
            break
        end
        local mod, why = from_entry(entry)
        if not mod then
            notes[#notes + 1] = ("skipped entry %d of run/mods.index.lua: %s"):format(position, why)
        elseif not known[mod.id] then
            known[mod.id] = true
            found[#found + 1] = mod
        end
    end
end

-- Returns a list of { id, dir, files = { ["relative/path.lua"] = true } }, notes for the log, and whether the mods folder could be listed.
function discover.all()
    local found, notes = {}, {}
    local listed = from_folder(found, notes)
    from_index(found, notes)
    return found, notes, listed
end

return discover
