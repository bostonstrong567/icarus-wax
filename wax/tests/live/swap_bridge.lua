-- One-off: replace the old async-thread bridge poller with the game-thread bridge in a running game,
-- without restarting it. Send through the old bridge. Not needed once the game has been restarted.
--
-- The old poller is a LoopAsync callback with no handle. UE4SS removes a LoopAsync whose callback raises,
-- so make its next tick raise: it reads the global `io`, which is swapped for a proxy that refuses the async thread.

if rawget(_G, "WaxBridgeSwap") then return "already swapped" end

local real_io = io
local state = { retired = false, real_io = real_io }
_G.WaxBridgeSwap = state
_G.io = setmetatable({}, {
    __index = function(_, key)
        if IsInAsyncThread() then
            state.retired = true
            error("Wax: async bridge poller retired", 0)
        end
        return real_io[key]
    end,
})

dofile("C:/Program Files (x86)/Steam/steamapps/common/Icarus/Icarus/Binaries/Win64/ue4ss/Mods/Wax/Scripts/main.lua")
return "swap started"
