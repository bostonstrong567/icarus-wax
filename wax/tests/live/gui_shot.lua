-- Development aid: arrange the demo so one capture shows several states. Argument via WaxShot = "a" | "b".
local ui = Wax.ui
local which = rawget(_G, "WaxShot") or "a"
local events = Wax.import("gui.events")
local panel = Wax.debug_panel.Window()
if which == "a" then
    panel:SelectPage("Log")
    WaxGuiDemoPages:SetMinimized(true)
    WaxGuiDemoPages:SetPosition(1100, 90)
else
    panel:SelectPage("Performance")
    WaxGuiDemoPages:SetMinimized(false)
    WaxGuiDemoPages:SelectPage("Settings")
end
ui.SetPreview(true)
return ui.stats()
