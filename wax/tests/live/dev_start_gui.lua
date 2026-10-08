-- Development aid: (re)load the GUI modules in a running game without reloading the whole core.
if rawget(_G, "Wax") == nil then error("the Wax core is not running") end
local was_open = Wax.ui and Wax.ui.IsOpen and Wax.ui.IsOpen()
if Wax.debug_panel then pcall(Wax.debug_panel.stop) end
Wax.debug_panel = nil
if Wax.ui then pcall(Wax.ui.stop) end
local held = Wax.modules["world.assets"]
if type(held) == "table" and held.forget_all then pcall(held.forget_all) end
Wax.ui = nil
for _, name in ipairs({ "root", "icons", "style", "kit", "events", "tween", "input", "picker", "tags", "pictures", "item", "split", "drag", "slots", "tip", "fit", "model", "controls", "window",
    "overlay", "notify", "init", "explorer_index", "explorer_path", "explorer_members", "explorer", "browse", "debug" }) do
    Wax.modules["gui." .. name] = nil
end
Wax.modules["engine.inspect"] = nil
local ui = Wax.import("gui.init")
ui.start()
Wax.ui = ui
Wax.mods.provide("ui", ui)
local panel = Wax.import("gui.debug")
panel.start()
Wax.debug_panel = panel
ui.Debug = panel
-- mods built their windows with the old library; let them build again
for _, mod in ipairs(Wax.mods.list()) do Wax.mods.request_reload(mod.id) end
if was_open then ui.Open() end
return ui.stats()
