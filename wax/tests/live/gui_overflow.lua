-- Builds the narrowest window with far too much text in every control, to look for anything drawn outside its box.
local ui = Wax.ui
local previous = rawget(_G, "WaxGuiOverflow")
if previous then for _, item in ipairs(previous) do item:Destroy() end end

local long = "A_very_long_unbroken_identifier_like_BP_IcarusPlayerCharacterSurvival_C_2147459632 and then more words after it"
local window = ui.Window({ title = "A title that is much too long for a window this narrow", width = 240, height = 620, x = 900, y = 90 })
window:Heading("A heading that is too long for one line")
window:Label(long)
window:Button("A button caption far longer than the button can be", nil, { primary = true })
local row = window:Row()
row:Button("First long button")
row:Button("Second long button")
row:Button("Third")
window:Toggle("A toggle whose caption needs more room than there is", true)
window:Slider("A slider with a long caption", { min = 0, max = 100000, value = 99999.5, format = "%.3f" })
window:Input("An input with a long caption", { text = long })
window:Dropdown("A dropdown with a long caption", { long, "Short", "Another quite long choice text here" }, long)
window:Keybind("A keybind with a long caption too", "ThumbMouseButton2")
window:Progress("A progress bar with a long caption that goes on", 0.5)
window:Field("A long field name here", long)
window:Field("Position", "x=174560  y=-131984  z=-695")
local section = window:Section("A section title that is too long to fit on the line")
section:Field("Inner", long)
local toggles = section:Row()
toggles:Toggle("One long", true)
toggles:Toggle("Two long", true)
toggles:Toggle("Three long", true)

local paged = ui.Window({ title = "Pages", nav = "side", width = 420, height = 260, x = 1160, y = 90 })
paged:Page("A page name that is too long", { icon = "box" }):Field("Name", long)
paged:Page("Short", { icon = "home" })

local hud = ui.Overlay({ anchor = "top-left", title = "An overlay title that is too long for it", width = 200, x = 1160, y = 380 })
hud:Field("Map", "Terrain_019")
hud:Field("Position", "x=174560  y=-131984  z=-695")
hud:Field(long, long)
ui.Notify(long, { title = long, kind = "warn", seconds = 20 })

WaxGuiOverflow = { window, paged, hud }
return ui.stats()
