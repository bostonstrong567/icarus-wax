-- Asks the game to quit the normal way (as if the player chose Exit), so it shuts down and saves cleanly.
local library = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local controller = FindFirstOf("PlayerController")
if not (library:IsValid() and controller:IsValid()) then return { requested = false, reason = "library or player controller not found" } end
-- QuitGame(WorldContextObject, SpecificPlayer, QuitPreference, bIgnorePlatformRestrictions); QuitPreference 0 = Quit.
ExecuteInGameThreadWithDelay(200, function() library:QuitGame(controller, controller, 0, false) end)
return { requested = true }
