-- Builds demo windows with one of every control. Run again to rebuild them.
local ui = Wax.ui
for _, name in ipairs({ "WaxGuiDemo", "WaxGuiDemoPages", "WaxGuiDemoHud" }) do
    local previous = rawget(_G, name)
    if previous then previous:Destroy() end
end

local seen = { clicks = 0 }
WaxGuiDemoSeen = seen

local window = ui.Window({ title = "Wax demo", icon = "sparkles", width = 360, height = 520, x = 700, y = 90 })
WaxGuiDemo = window
window:Label("Every control in the library. Long text wraps inside the window instead of spilling over its edge, however long it gets.", { dim = true })
local buttons = window:Row()
buttons:Button("Primary", function() seen.clicks = seen.clicks + 1 end, { primary = true })
buttons:Button("Save", function() ui.Notify("Saved.", { title = "Demo", kind = "good" }) end, { icon = "save" })
window:Toggle("God mode", true, function(on) seen.toggle = on end)
window:Slider("Walk speed", { min = 0, max = 10, value = 4, step = 0.5 }, function(value) seen.slider = value end)
window:Input("Name", { hint = "type here" }, function(text) seen.input = text end)
window:Dropdown("Weather", { "Clear", "Rain", "Storm", "Snow" }, "Clear", function(choice) seen.choice = choice end)
window:Keybind("Quick save", "F5", function(key) seen.key = key end)
window:Progress("Stamina", 0.62)
local section = window:Section("Advanced")
section:Toggle("Verbose logging", false)
section:Slider("Volume", { min = 0, max = 100, value = 60, step = 1 })
section:Field("Build", "25621870")
section:Button("Reset", function() seen.reset = true end)

local paged = ui.Window({ title = "Pages demo", nav = "side", width = 500, height = 300, x = 1100, y = 90 })
WaxGuiDemoPages = paged
local main = paged:Page("Main", { icon = "home" })
main:Heading("Main")
main:Label("A window with navigation down the side. Each page scrolls on its own.", { dim = true })
main:Toggle("Enabled", true)
local tools = paged:Page("Tools", { icon = "box" })
tools:Button("Do a thing", function() seen.thing = true end)
ui.AddSettings(paged:Page("Settings", { icon = "settings", bottom = true }))

local hud = ui.Overlay({ anchor = "top-right", title = "Demo overlay", width = 220, y = 120 })
WaxGuiDemoHud = hud
hud:Field("Map", tostring(game and game.MapName or Wax.game.MapName))
hud:Progress("Health", 0.8, { color = ui.Theme().good })
return ui.stats()
