-- One step of the theme stress test (see theme_stress.mjs). WaxStress = { action = ..., value = ... } says what to do.
-- Clicks go through the engine's own delegates, exactly as a mouse click would.
local ui = Wax.ui
local step = rawget(_G, "WaxStress") or {}
local window = Wax.debug_panel.Window()

local function settings_dropdown(choice)
    for _, control in ipairs(window.controls) do
        if control.items and control.items[choice] then return control end
    end
    error("no dropdown offers " .. tostring(choice))
end

if step.action == "open" then
    ui.Open()
elseif step.action == "close" then
    ui.Close()
elseif step.action == "page" then
    window:SelectPage(step.value)
elseif step.action == "pick" then
    local dropdown = settings_dropdown(step.value)
    dropdown.source.OnClicked:Broadcast()
    dropdown.items[step.value].OnClicked:Broadcast()
elseif step.action == "collect" then
    -- what the engine does by itself about once a minute: free every object nothing refers to any more
    StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage()
elseif step.action == "icons" then
    for _, control in ipairs(window.controls) do
        if control.Typed and control.source then
            Wax.import("gui.events").simulate(control.source, "OnTextChanged", step.value)
        end
    end
elseif step.action == "reload" then
    -- every mod builds its windows and overlays again; the old ones are freed at the next collection
    for _, mod in ipairs(Wax.mods.list()) do Wax.mods.request_reload(mod.id) end
elseif step.action == "notify" then
    ui.Notify("Stress test " .. tostring(step.value), { title = "Theme test", seconds = 1 })
end

local errors = {}
for _, record in ipairs(Wax.guard.errors()) do errors[#errors + 1] = record.message end
return { theme = ui.ThemeName(), accent = settings_dropdown("Teal"):Get(), open = ui.IsOpen(), windows = ui.stats().windows,
    handlers = ui.stats().handlers, painted = ui.stats().painted, page = window.page and window.page.name, errors = errors,
    frame = WaxStage0.frame }
