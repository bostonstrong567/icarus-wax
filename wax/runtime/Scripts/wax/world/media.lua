-- The game's animations, particle effects, sounds and camera shakes by name, read from data/media.lua on first use

local Wax = ...
local log = Wax.import("core.log").channel("wax.media")

local M = {}

M.MOST = 200                -- the most paths one search gives

local lists = nil           -- kind -> { paths, lowered }

local function load_lists()
    if lists then return lists end
    lists = {}
    local chunk, why = loadfile(Wax.root .. "/data/media.lua")
    local ok, data = pcall(chunk or error, why)
    if not ok or type(data) ~= "table" then
        log:warn("the list of the game's animations, effects and sounds could not be read: %s", tostring(data))
        return lists
    end
    for kind, folders in pairs(data) do
        local paths, lowered = {}, {}
        for folder, names in pairs(folders) do
            for name in names:gmatch("%S+") do
                local suffix = kind == "shakes" and (name .. "_C") or name
                paths[#paths + 1] = folder .. "/" .. name .. "." .. suffix
            end
        end
        table.sort(paths)
        for index = 1, #paths do lowered[index] = paths[index]:lower() end
        lists[kind] = { paths = paths, lowered = lowered }
    end
    return lists
end

-- The paths of one kind whose name holds every word of `text`. At most M.MOST, then how many there were in all.
function M.find(kind, text, what)
    if type(text) ~= "string" then error(("%s expects words to look for, such as \"whoosh\""):format(what or "Find"), 3) end
    local list = load_lists()[kind]
    if not list then return {}, 0 end
    local words = {}
    for word in text:lower():gmatch("%S+") do words[#words + 1] = word end
    local found, total = {}, 0
    for index = 1, #list.paths do
        local path, fits = list.lowered[index], true
        for w = 1, #words do
            if not path:find(words[w], 1, true) then fits = false break end
        end
        if fits then
            total = total + 1
            if total <= M.MOST then found[total] = list.paths[index] end
        end
    end
    return found, total
end

function M.count(kind)
    local list = load_lists()[kind]
    return list and #list.paths or 0
end

return M
