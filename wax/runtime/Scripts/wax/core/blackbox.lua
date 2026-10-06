-- What Wax was doing, written as it happens so it survives a crash: run/session.log, and run/previous.log from the run before

local Wax = ...

local blackbox = {}

-- One file per game process: a real global keeps it open across restarts of the core.
local file = rawget(_G, "WaxBlackboxFile")
if file == nil and not rawget(_G, "WaxStage0") then file = false end     -- not in the game (tests): keep no log
if file == nil then
    local path = Wax.root .. "/run/session.log"
    os.remove(Wax.root .. "/run/previous.log")
    os.rename(path, Wax.root .. "/run/previous.log")
    file = io.open(path, "w")
    rawset(_G, "WaxBlackboxFile", file or false)
end

function blackbox.note(text)
    if not file then return end
    file:write(os.date("%H:%M:%S "), tostring(text), "\n")
    file:flush()
end

return blackbox
