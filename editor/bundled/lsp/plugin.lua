-- Language-server plugin: require("name") finds name.lua or name/init.lua in the same mod, and require("@Other") another mod's init.lua.

local furi = require 'file-uri'

local function exists(uri)
    local file = io.open(furi.decode(uri), 'rb')
    if file then file:close() end
    return file ~= nil
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
