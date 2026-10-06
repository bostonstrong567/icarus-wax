-- Creates the Wax table and the loader for Wax's own modules

return function(root)
    local Wax = {}
    Wax.root = (root:gsub("\\", "/"))       -- the Mods/Wax folder
    Wax.scripts = Wax.root .. "/Scripts"
    Wax.modules = {}

    local LOADING = {}

    function Wax.import(name)
        local cached = Wax.modules[name]
        if cached == LOADING then error("circular import of wax module '" .. name .. "'", 2) end
        if cached ~= nil then return cached end
        local path = Wax.scripts .. "/wax/" .. name:gsub("%.", "/") .. ".lua"
        local chunk, err = loadfile(path)
        if not chunk then error("cannot load wax module '" .. name .. "': " .. tostring(err), 2) end
        Wax.modules[name] = LOADING
        local ok, value = xpcall(chunk, debug.traceback, Wax)
        if not ok then
            Wax.modules[name] = nil
            error("wax module '" .. name .. "' failed while loading:\n" .. tostring(value), 0)
        end
        if value == nil then value = true end
        Wax.modules[name] = value
        return value
    end

    return Wax
end
