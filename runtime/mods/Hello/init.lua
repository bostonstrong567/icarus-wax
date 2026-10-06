-- A first Wax mod. Save this file while the game is running and it reloads in place.

-- persist() returns the same table after every reload, so the count is kept when you save this file.
local state = persist("state", { loads = 0 })
state.loads = state.loads + 1

-- storage keeps settings on disk, so they are still there the next time the game starts.
local settings = storage.Load("settings", { overlay = false })

-- `game` is where you reach the game's objects from. game.Character is your character, or nil at the main menu.
local function where_is_the_player()
    local character = game.Character
    if not character then return "no character yet" end
    local position = character:K2_GetActorLocation()
    return ("%.0f, %.0f, %.0f"):format(position.X, position.Y, position.Z)
end

-- An overlay stays on screen while you play and never takes the mouse. With the menu open you can drag it.
local hud = ui.Overlay({ anchor = "left", title = "Hello", width = 300 })
local map = hud:Field("Map", game.MapName or "none")
local spot = hud:Field("Position", where_is_the_player())
hud:SetVisible(settings.overlay)

-- A window shows while the menu is open (F8 by default). Everything made here is removed again when the mod reloads.
local window = ui.Window({ title = "Hello", icon = "hand", width = 330, height = 250, x = 700, y = 120 })
window:Label("This window is made by mods/Hello/init.lua. Change that file and save it, and the window is rebuilt.", { dim = true })
window:Field("Times loaded", state.loads)
window:Toggle("Show the overlay", settings.overlay, function(on)
    settings.overlay = on
    storage.Save("settings", settings)
    hud:SetVisible(on)
end)
window:Button("Show my position", function()
    spot:Set(where_is_the_player())
    ui.Notify(where_is_the_player(), { title = "You are at", kind = "good" })
end, { primary = true, icon = "map-pin" })

-- A task runs alongside the game and can pause without blocking it.
task.spawn(function()
    while true do
        if settings.overlay then spot:Set(where_is_the_player()) end
        task.wait(0.5)
    end
end)

-- A signal. This function runs when the map changes (when you enter or leave a prospect).
game.MapChanged:Connect(function(map_name)
    map:Set(map_name)
    print("now on map " .. map_name)
end)

return { where = where_is_the_player }
