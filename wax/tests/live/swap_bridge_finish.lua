-- Second half of swap_bridge.lua: confirm the async poller is gone and put the real `io` back.
local state = rawget(_G, "WaxBridgeSwap")
if not state then return { error = "swap_bridge.lua has not been run" } end
if state.retired then _G.io = state.real_io end
return {
    asyncPollerRetired = state.retired,
    ioRestored = rawequal(_G.io, state.real_io),
    answeredOnGameThread = IsInGameThread(),
}
