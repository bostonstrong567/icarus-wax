-- Asks the game to do something with its mods; the loader acts on it at the start of the next frame
local action, id = ...
if not (rawget(_G, "Wax") and Wax.mods) then error("Wax is not running in the game", 0) end

if action == "sync" then
    Wax.mods.request_sync(true)
elseif action == "reload" then
    Wax.mods.request_reload(id)
elseif action == "enable" or action == "disable" then
    local ok, problem = Wax.mods.set_enabled(id, action == "enable")
    if not ok then error(problem, 0) end
else
    error("unknown action: " .. tostring(action), 0)
end
return true
