-- Probe: is wrapped text measured at a different size than it is drawn when it sits inside the scale box?
-- Reads the height the Icons page description asks for, with the window's scale box on and then switched off.
local window = Wax.debug_panel.Window()
local page
for _, candidate in ipairs(window.pages) do
    if candidate.name == "Icons" then page = candidate end
end
local label
for _, control in ipairs(window.controls) do
    if control.container == page and control.SetColor and not control.source then
        label = control
        break
    end
end
if not label then error("could not find the description label") end
local step = rawget(_G, "WaxProbeStep") or "read"
if step == "off" then
    window.outer:SetStretch(0)
elseif step == "on" then
    window.outer:SetStretch(7)
    window.outer:SetUserSpecifiedScale(Wax.ui.GetScale())
end
local size = label.widget:GetDesiredSize()
return { step = step, wants_height = size.Y, wants_width = size.X, window_width = window.width, nav = window.nav_width,
    wrap_at = Wax.import("gui.controls").wrap_width(page) * 0.94 }
