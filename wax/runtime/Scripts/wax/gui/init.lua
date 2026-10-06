-- The GUI library: the menu (windows you click), overlays (panels you only read) and notifications

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local events = Wax.import("gui.events")
local tween = Wax.import("gui.tween")
local input = Wax.import("gui.input")
local kit = Wax.import("gui.kit")
local icons = Wax.import("gui.icons")
local controls = Wax.import("gui.controls")
local window_module = Wax.import("gui.window")
local overlay_module = Wax.import("gui.overlay")
local notify = Wax.import("gui.notify")
local tags = Wax.import("gui.tags")
local picker = Wax.import("gui.picker")
local pictures = Wax.import("gui.pictures")
local slots = Wax.import("gui.slots")
local tip = Wax.import("gui.tip")
local fit = Wax.import("gui.fit")
local sched = Wax.import("core.sched")
local storage = Wax.import("core.storage")
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local log = Wax.import("core.log").channel("wax.gui")

local ui = {}

local V = style.Visibility
local windows = window_module.windows
local menu_open, preview = false, false
local toggle_key = "F8"
local layer_animation = nil
local last_error_notice = -math.huge
local frames = 0

-- what the player chose, kept between sessions in saved/wax.interface.lua
local saved = { theme = "Midnight", accent = "From the theme", scale = 1, key = "F8", animations = true, windows = {}, overlays = {} }
local function remember() storage.save("wax", "interface", saved) end

ui.Opened = sched.Signal.new("Opened")
ui.Closed = sched.Signal.new("Closed")

local function show_layer(shown)
    local layer = root.layer("windows")
    if layer_animation then layer_animation.cancel() end
    if shown then
        layer:SetVisibility(V.SelfHitTestInvisible)
        layer_animation = tween.run(style.theme.animation, function(progress) layer:SetRenderOpacity(progress) end)
    else
        layer_animation = tween.run(style.theme.animation, function(progress) layer:SetRenderOpacity(1 - progress) end,
            function() layer:SetVisibility(V.Collapsed) end)
    end
end

local function any_window_shown()
    for i = 1, #windows do
        if windows[i].shown then return true end
    end
    return false
end

-- Opens the menu: windows appear and the mouse is freed to use them. options: { windows = false } frees the mouse for panels only.
function ui.Open(options)
    if menu_open or not root.exists() then return end
    menu_open = true
    log:info("menu opened")
    local bare = type(options) == "table" and options.windows == false
    if not bare and not any_window_shown() then
        for i = 1, #windows do
            if windows[i].closed_by_user then windows[i]:Show() end
        end
    end
    if not preview and not bare then show_layer(true) end
    overlay_module.set_moving(true)
    input.set_cursor(true)
    ui.Opened:Fire()
end

-- Closes the menu and gives the mouse back to the game.
function ui.Close()
    if not menu_open then return end
    menu_open = false
    log:info("menu closed")
    input.capture(nil)
    controls.close_list()
    overlay_module.set_moving(false)
    input.set_cursor(false)
    if not preview and root.exists() then show_layer(false) end
    ui.Closed:Fire()
end

function ui.Toggle() if menu_open then ui.Close() else ui.Open() end end

-- Puts text on the clipboard, for pasting anywhere (the game's own function does it).
function ui.Copy(text)
    if text == ui then error("write ui.Copy(...) with a dot, not a colon", 2) end
    root.library("UMGFunctionLibrary", "Icarus"):CopyToClipboard(tostring(text))
end
function ui.IsOpen() return menu_open end

-- Shows the windows without taking the mouse (for screenshots and for looking while you play).
function ui.SetPreview(on)
    on = on and true or false
    if preview == on then return end
    preview = on
    if not menu_open and root.exists() then show_layer(on) end
end
function ui.IsPreview() return preview end

function ui.SetToggleKey(key)
    toggle_key = key
    saved.key = key
    remember()
    ui.KeyChanged:Fire(key)
end
function ui.GetToggleKey() return toggle_key end
ui.KeyChanged = sched.Signal.new("KeyChanged")

-- options: { title, width, height, x, y, closable = true, visible = true, nav = nil | "side" | "top" }
function ui.Window(options)
    if options == ui then error("write ui.Window({ ... }) with a dot, not a colon", 2) end
    local window = window_module.create(options)
    if not menu_open and not rawget(_G, "WaxGuiHintShown") and toggle_key then
        rawset(_G, "WaxGuiHintShown", true)
        notify.show(("Press %s to open the menu."):format(toggle_key), { title = "Wax", seconds = 6 })
    end
    return window
end

ui.Overlay = overlay_module.create
ui.Panel = overlay_module.panel
-- The value of the slot under the mouse, then its look and its control.
ui.Hovered = slots.hovered
ui.IsTyping = controls.typing
-- The size of the screen in the units windows and panels are laid out in.
function ui.ScreenSize()
    local width, height = root.viewport_size()
    return width / style.scale, height / style.scale
end
ui.Pictures = { Check = pictures.check, Stats = pictures.stats }
-- ui.FitGame({ scale = 0.85, corner = "bottom-left" }) draws the game's own menus smaller, which leaves room beside them.
ui.FitGame = fit.create
-- The game's own menu screen that is showing now, and the main menu's tab number. Nothing when none shows.
ui.GameScreen = fit.screen

-- ui.Tag(creature, { text = "Wolf" }) keeps a line of text over something in the world: :Set, :SetColor, :Remove
ui.Tag = tags.create

-- Every Lucide icon by name ("shield", "wrench", ...), plus images a mod registers: ui.Icons.Register("logo", mod.dir .. "/logo.png")
ui.Icons = { Names = icons.list, Has = icons.has, Find = icons.find, Register = icons.register }

-- ui.Notify("Saved.", { title = "Garage", kind = "good" }) returns the notification: :SetText, :SetProgress, :Close
ui.Notify = notify.show
ui.Notifications = { SetCorner = notify.set_corner, SetLimit = notify.set_limit, Clear = notify.clear, Count = notify.count }
function ui.Windows() return table.move(windows, 1, #windows, 1, {}) end

-- Runs callback() when the key ("F6", "K", "MiddleMouseButton" ...) is pressed during play, and in the menu too with options.in_menu.
local hotkeys = {}
-- A key that also puts something in a text box. A function key or a mouse button does not, so it works while one has the keyboard.
local function writes(key)
    local want = input.parse(key)
    if want.ctrl or want.alt then return false end
    key = want.key
    return not (key:match("^F%d+$") or key:find("Mouse", 1, true) or key:find("Gamepad", 1, true))
end

-- A plain key gives way to the same key with Ctrl, Shift or Alt: "3" does not run while Ctrl is held if "Ctrl+3" is bound.
local function taken_with_modifiers(entry)
    local plain = input.parse(entry.key)
    if plain.held then return false end
    local ctrl, shift, alt = nil, nil, nil
    for index = 1, #hotkeys do
        local other = input.parse(hotkeys[index].key)
        if other.held and other.key == plain.key then
            if ctrl == nil then ctrl, shift, alt = input.modifiers() end
            if other.ctrl == ctrl and other.shift == shift and other.alt == alt then return true end
        end
    end
    return false
end
function ui.Hotkey(key, callback, options)
    if type(key) ~= "string" or key == "" then error("ui.Hotkey expects a key name such as \"F6\"", 2) end
    if type(callback) ~= "function" then error("ui.Hotkey expects a function to run", 2) end
    -- typing = true lets it run while a text box has the keyboard (a key such as Tab that is meant for the box).
    -- hover = true makes it a key for the slot under the mouse: it is not even looked at while no slot is under it.
    local entry = { key = key, run = guard.wrap("hotkey " .. key, function() sched.task.spawn(callback) end),
        in_menu = options and options.in_menu or false, typing = options and options.typing or false,
        hover = options and options.hover or false, writes = writes(key) }
    hotkeys[#hotkeys + 1] = entry
    local function disconnect()
        for index, other in ipairs(hotkeys) do
            if other == entry then
                table.remove(hotkeys, index)
                break
            end
        end
    end
    scope.own(disconnect)
    return { Disconnect = disconnect, SetKey = function(_, new_key) entry.key, entry.writes = new_key, writes(new_key) end }
end

-- Closing the last window closes the menu, so the mouse never stays free with nothing to click.
window_module.on_hidden = function()
    if menu_open and not any_window_shown() then ui.Close() end
end

local MIN_SHARP, MAX_SCALE = 0.9, 2
local wanted_scale, screen_scale, screen_known = 1, 1, false

-- The smallest scale that still draws text at a readable size on this screen.
function ui.MinScale() return math.max(0.7, MIN_SHARP / screen_scale) end

-- 1 is the normal size. A value this screen cannot show sharply is raised to ui.MinScale().
function ui.SetScale(scale)
    if type(scale) ~= "number" then error("ui.SetScale expects a number such as 1.25", 2) end
    wanted_scale = scale
    if saved.scale ~= scale then
        saved.scale = scale
        remember()
    end
    local applied = math.max(ui.MinScale(), math.min(MAX_SCALE, scale))
    if applied == style.scale then return applied end
    style.scale = applied
    window_module.rescale()
    overlay_module.rescale()
    notify.rescale()
    tags.rescale()
    tip.rescale()
    return applied
end
function ui.GetScale() return style.scale end

local function watch_screen()
    local _, _, scale = root.viewport_size()
    local width = root.viewport_size()
    if width >= 200 and not screen_known then
        -- the first frame the screen has a size: windows made before that are checked against it now
        screen_known = true
        window_module.rescale()
    end
    if scale ~= screen_scale then
        screen_scale = scale
        style.screen_scale = scale
        ui.SetScale(wanted_scale)
    end
end

local ACCENTS = { Blue = { "#2F81F7", "#58A6FF" }, Green = { "#2EA043", "#3FB950" }, Orange = { "#D4762C", "#F0883E" },
    Purple = { "#8957E5", "#A371F7" }, Red = { "#DA3633", "#F85149" }, Teal = { "#1FA890", "#4FE0C6" },
    Amber = { "#D99A2B", "#F2BC57" }, Pink = { "#D6409F", "#F06CC0" } }
local ACCENT_ORDER = { "From the theme", "Blue", "Green", "Teal", "Amber", "Orange", "Red", "Pink", "Purple" }
local accent_choice = "From the theme"

ui.ThemeChanged = sched.Signal.new("ThemeChanged")

-- The accent the player picked, as overrides on top of a theme, or nil when the theme's own accent is used.
local function accent_overrides()
    local pair = ACCENTS[accent_choice]
    return pair and { accent = pair[1], accent_hover = pair[2] } or nil
end

-- ui.SetTheme("Dune") or a table of single settings. What is on screen is recoloured in place.
function ui.SetTheme(theme)
    if theme == ui then error("write ui.SetTheme(...) with a dot, not a colon", 2) end
    if theme == style.theme_name then return end
    if type(theme) == "string" then
        style.set_theme(theme, accent_overrides())
        log:info("theme %s", theme)
        saved.theme = theme
        remember()
    else
        style.set_theme(theme)
    end
    ui.ThemeChanged:Fire(style.theme_name)
end

function ui.ResetTheme()
    style.reset_theme()
    accent_choice = "From the theme"
    saved.theme, saved.accent = "Midnight", accent_choice
    remember()
    ui.ThemeChanged:Fire(style.theme_name)
end

ui.Themes = style.theme_names
ui.AddTheme = style.add_theme
function ui.ThemeName() return style.theme_name end
ui.Color = style.color
function ui.Theme() return style.theme end


-- Adds the menu's own settings (key, theme, accent, animation, size) to a container, e.g. a "Settings" page.
function ui.AddSettings(container)
    container:Keybind("Menu key", toggle_key, function(key) ui.SetToggleKey(key) end)
    container:Dropdown("Theme", ui.Themes(), style.theme_name, function(name) ui.SetTheme(name) end)
    container:Dropdown("Accent colour", ACCENT_ORDER, accent_choice, function(name)
        accent_choice = name
        saved.accent = name
        remember()
        style.set_theme(style.theme_name, accent_overrides())
    end)
    container:Toggle("Animations", style.theme.animation > 0, function(on)
        style.theme.animation = on and 0.16 or 0
        saved.animations = on
        remember()
    end)
    local sizes, current = {}, nil
    for _, percent in ipairs({ 70, 80, 90, 100, 110, 125, 150, 175, 200 }) do
        if percent / 100 >= ui.MinScale() - 0.001 then
            sizes[#sizes + 1] = percent .. "%"
            if not current or math.abs(percent / 100 - style.scale) < math.abs(tonumber((current:gsub("%%", ""))) / 100 - style.scale) then
                current = percent .. "%"
            end
        end
    end
    container:Dropdown("Interface size", sizes, current, function(choice)
        ui.SetScale(tonumber((choice:gsub("%%", ""))) / 100)
    end)
end

function ui.start()
    root.start()
    tags.start()
    saved = storage.load("wax", "interface", saved)
    if type(saved.windows) ~= "table" then saved.windows = {} end
    if type(saved.overlays) ~= "table" then saved.overlays = {} end
    picker.copy = ui.Copy
    slots.on_hover(function(look)
        if look and look.tip then tip.show(look.tip) else tip.hide() end
    end)
    overlay_module.recall = function(key) return saved.overlays[key] end
    overlay_module.remember = function(key, place)
        saved.overlays[key] = place
        remember()
    end
    if saved.theme ~= style.theme_name and pcall(style.set_theme, saved.theme) then style.theme_name = saved.theme end
    if ACCENTS[saved.accent] then
        accent_choice = saved.accent
        style.set_theme(accent_overrides())
    end
    style.theme.animation = saved.animations == false and 0 or 0.16
    if type(saved.key) == "string" then toggle_key = saved.key end
    if type(saved.scale) == "number" then wanted_scale = saved.scale end
    window_module.recall = function(key) return saved.windows[key] end
    window_module.remember = function(key, geometry)
        saved.windows[key] = geometry
        remember()
    end
    root.layer("windows"):SetVisibility(V.Collapsed)
    root.layer("windows"):SetRenderOpacity(0)
    watch_screen()
    -- an error anywhere in Wax or a mod shows as a notification. The sink is added once and survives reloads.
    Wax.gui_error_notice = function(entry)
        local now = os.clock()
        if now - last_error_notice < 2 then return end
        last_error_notice = now
        local first_line = tostring(entry.message):match("^[^\r\n]*")
        notify.show(#first_line > 160 and first_line:sub(1, 157) .. "..." or first_line, { title = entry.channel, kind = "bad", seconds = 8 })
    end
    if not Wax.gui_error_sink then
        Wax.gui_error_sink = true
        Wax.import("core.log").add_sink(function(entry, repeated)
            local notice = Wax.gui_error_notice
            if notice and entry.level == "error" and not repeated then pcall(notice, entry) end
        end)
    end
    log:info("GUI ready (menu key %s)", tostring(toggle_key))
end

-- The game can remove the whole interface (seen when leaving a prospect). The old one is not touched: a new root is made and mods reload.
local function recover()
    log:warn("the game removed the interface, so Wax is building it again")
    window_module.forget_all()
    overlay_module.forget_all()
    tags.forget_all()
    slots.forget_all()
    pictures.forget_all()
    tip.forget()
    notify.destroy_all()
    events.forget_all()
    input.forget()
    hotkeys = {}
    menu_open, preview, layer_animation = false, false, nil
    root.abandon()
    root.start()
    root.layer("windows"):SetVisibility(V.Collapsed)
    root.layer("windows"):SetRenderOpacity(0)
    local panel = Wax.debug_panel
    if panel then
        panel.forget()
        panel.start()
    end
    if Wax.mods then
        for _, mod in ipairs(Wax.mods.list()) do Wax.mods.request_reload(mod.id) end
    end
end

-- Runs first in every frame, before mods and tasks: if the game removed the interface, everything is marked gone here.
local checked, usable = false, false
function ui.check()
    checked = true
    usable = root.check()
    if not usable and root.lost() then recover() end
    return usable
end

function ui.step()
    if not checked then ui.check() end
    checked = false
    if not usable then return end
    root.step()
    frames = frames + 1
    if frames % 120 == 0 or (not screen_known and frames % 10 == 0) then watch_screen() end
    tween.step()
    controls.warm()
    slots.warm()
    pictures.step()
    -- panels show beside the game's own screens: they wait for the game's mouse as well as for the menu
    local cursor = false
    if not menu_open and overlay_module.wants_cursor() then
        local player = input.controller()
        cursor = player ~= nil and player.bShowMouseCursor == true
    end
    local panels = overlay_module.watch(menu_open or preview, cursor)
    slots.step(menu_open or panels)
    tip.step()
    fit.step()
    if menu_open or preview then controls.step() end
    notify.step()
    tags.step()
    input.step()
    if menu_open then
        window_module.step()
        overlay_module.step()
        -- the controller is replaced on a map change, so take the cursor again on the new one
        if not input.cursor_active() then input.set_cursor(true) end
    end
    if #hotkeys > 0 and not input.capturing() then
        for index = #hotkeys, 1, -1 do
            local entry = hotkeys[index]
            if (entry.in_menu or not menu_open) and (not entry.hover or slots.hovered() ~= nil) then
                local ok, pressed = pcall(input.just_pressed, entry.key)
                if ok and pressed and (entry.typing or not entry.writes or not controls.typing()) and not taken_with_modifiers(entry) then
                    entry.run()
                end
            end
        end
    end
    if toggle_key and not input.capturing() then
        local ok, pressed = pcall(input.just_pressed, toggle_key)
        if ok and pressed then ui.Toggle() end
    end
    -- Escape closes an open list first, then the menu (the game does not see keys while the menu is open)
    if menu_open and not input.capturing() then
        local ok, pressed = pcall(input.just_pressed, "Escape")
        if ok and pressed and not controls.close_list() then ui.Close() end
    end
    -- give the game its keys back once the menu is closed
    if not menu_open and input.blocking() then input.unblock() end
end

function ui.stop()
    pcall(ui.Close)
    hotkeys = {}
    window_module.destroy_all()
    overlay_module.destroy_all()
    tags.destroy_all()
    slots.forget_all()
    pictures.forget_all()
    tip.forget()
    fit.restore()
    notify.destroy_all()
    root.stop()
end

function ui.stats()
    return { windows = #windows, overlays = #overlay_module.overlays, handlers = events.count(), animations = tween.count(),
             notifications = notify.count(), open = menu_open, preview = preview, cursor = input.cursor_active(), scale = style.scale,
             painted = style.painted(), hook_calls = events.calls() }
end

return ui
