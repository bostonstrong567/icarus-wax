-- Language-server plugin: require("name") and require(mod.name) find name.lua or name/init.lua in the same mod, and require("@Other") another mod's init.lua.
-- A class name the editor has no members for is read as a plain Instance.

local furi = require 'file-uri'

local function exists(uri)
    local file = io.open(furi.decode(uri), 'rb')
    if file then file:close() end
    return file ~= nil
end

local FINDERS = { Find = true, FindAll = true, FindFirstChildOfClass = true, FindFirstChildWhichIsA = true, Library = true }
local known

-- The game classes the editor has members for: the list written with the generated definitions.
local function known_classes()
    if known ~= nil then return known end
    known = false
    local wax = debug.getinfo(1, 'S').source:match('^@(.*)[/\\][^/\\]+[/\\][^/\\]+$')
    local file = wax and io.open(wax .. '/types/icarus/classes.txt', 'rb')
    if file then
        known = {}
        for name in file:read('a'):gmatch('%S+') do known[name] = true end
        file:close()
    end
    return known
end

-- require(mod.extras.Utils) is read as require("extras.Utils"), which the rest of this file knows how to find.
-- game:Find("BP_NotListed_C") is read as game:Find("WaxInstance"), so the result is a plain Instance.
---@param _ string the file
---@param text string its contents
function OnSetText(_, text)
    local changes = {}
    if text:find('require%s*%(%s*mod%.') then
        for start, path, finish in text:gmatch('require%s*%(%s*()mod%.([%a_][%w_%.]*)()%s*%)') do
            changes[#changes + 1] = { start = start, finish = finish - 1, text = '"' .. path .. '"' }
        end
    end
    if text:find('[:.]Find') or text:find(':Library', 1, true) then
        local classes = known_classes()
        for method, _, start, name, finish in text:gmatch('[:.](%a+)%s*%(%s*(["\'])()([%w_]+)()%2') do
            if FINDERS[method] and classes and not classes[name] and name ~= 'WaxInstance' then
                changes[#changes + 1] = { start = start, finish = finish - 1, text = 'WaxInstance' }
            end
        end
    end
    if #changes == 0 then return nil end
    table.sort(changes, function(a, b) return a.start < b.start end)
    return changes
end

---@param _ string the workspace the file belongs to
---@param name string what was passed to require
---@param source string the file that called require
function ResolveRequire(_, name, source)
    local mods, id = source:match('^(.*)/([^/]+)/[^@]*$')
    if not mods or not exists(mods .. '/' .. id .. '/init.lua') then
        -- not directly inside a mod folder: look upwards for the folder that holds init.lua
        local folder = source:match('^(.*)/[^/]+$')
        while folder and not exists(folder .. '/init.lua') do folder = folder:match('^(.*)/[^/]+$') end
        if not folder then return nil end
        mods, id = folder:match('^(.*)/([^/]+)$')
    end
    local candidates
    if name:sub(1, 1) == '@' then
        candidates = { mods .. '/' .. name:sub(2) .. '/init.lua' }
    else
        local relative = name:gsub('%.', '/')
        candidates = { mods .. '/' .. id .. '/' .. relative .. '.lua', mods .. '/' .. id .. '/' .. relative .. '/init.lua' }
    end
    local found = {}
    for _, uri in ipairs(candidates) do
        if exists(uri) then found[#found + 1] = uri end
    end
    return found
end
