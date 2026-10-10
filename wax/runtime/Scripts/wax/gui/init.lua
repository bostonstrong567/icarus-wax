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
local model = Wax.import("gui.model")
local tip = Wax.import("gui.tip")
local fit = Wax.import("gui.fit")
local grab = Wax.import("gui.drag")
local sched = Wax.import("core.sched")
local storage = Wax.import("core.storage")
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local log = Wax.import("core.log").channel("wax.gui")

local ui = {}

local V = style.Visibility
local windows = window_module.windows
local menu_open, preview = false, false
local pinned_before = false
local toggle_key = "F8"
local layer_animation, layer_shown = nil, false
local last_error_notice = -math.huge
local frames = 0

local WAX = "Wax"
local DEFAULT_KEYS = { "F6", "F9", "F10", "F11", "F5", "F4", "F3", "F2" }
local GRACE = 30        -- frames an owner whose windows were destroyed keeps its place: its mod may be loading again
-- taking the mouse again after the game took it from the open menu: how often in a row, frames between, and frames that count as kept
local CURSOR_TRIES, CURSOR_PAUSE, CURSOR_SETTLED = 5, 30, 120
local cursor_taken, cursor_wait = 0, 0

-- what the player chose, kept between sessions in saved/wax.interface.lua
local saved = { theme = "Midnight", accent = "From the theme", scale = 1, key = "F8", animations = true, windows = {}, overlays = {},
    keys = {}, default_keys = {} }
local function remember() storage.save("wax", "interface", saved) end

ui.Opened = sched.Signal.new("Opened")
ui.Closed = sched.Signal.new("Closed")
ui.KeyChanged = sched.Signal.new("KeyChanged")
ui.Keys = { Changed = sched.Signal.new("Changed") }

-- Windows belong to an owner, "Wax" or a mod's id, with one key. open: its windows are up. bare: it opened the menu without windows.
local owners = { [WAX] = { id = WAX, open = false, bare = false, key = toggle_key, count = 0 } }
local hotkeys = {}
local recheck_at = nil
local announce_due = false

-- Who is asking: the mod whose code is running, or Wax for its own code, the command bar and Lua sent from outside.
local function caller()
    local at = scope.current()
    while at and at.parent do at = at.parent end
    local mods = Wax.mods
    local mod = at and mods and mods.get and mods.get(at.name)
    if mod and mod.scope == at then return at.name end
    return WAX
end

local function name_of(id)
    if id == WAX then return WAX end
    local mods = Wax.mods
    local mod = mods and mods.get and mods.get(id)
    local name = mod and mod.manifest and mod.manifest.name
    return type(name) == "string" and name:find("%S") and name or id
end

local declared_key      -- the key a mod's mod.lua gives for its windows: set further down

-- A key as one text, however its Ctrl, Shift and Alt were ordered or spelt. nil for what is not a key.
local function key_id(key)
    if type(key) ~= "string" or key == "" then return nil end
    local ok, want = pcall(input.parse, key)
    if not ok or want.key == "" then return nil end
    return (want.ctrl and "c" or "") .. (want.shift and "s" or "") .. (want.alt and "a" or "") .. "+" .. want.key
end

-- A key that also puts something in a text box. A function key or a mouse button does not, so it works while one has the keyboard.
local function writes(key)
    local want = input.parse(key)
    if want.ctrl or want.alt then return false end
    key = want.key
    return not (key:match("^F%d+$") or key:find("Mouse", 1, true) or key:find("Gamepad", 1, true))
end

-- The name of who has this key already: another owner with windows, or another owner's hotkey. nil when `id` can have it.
local function taken_by(key, id)
    local wanted = key_id(key)
    if not wanted then return nil end
    for other_id, other in pairs(owners) do
        if other_id ~= id and other.key and (other.count > 0 or other_id == WAX) and key_id(other.key) == wanted then
            return name_of(other_id)
        end
    end
    for index = 1, #hotkeys do
        local entry = hotkeys[index]
        if entry.owner ~= id and key_id(entry.key) == wanted then return name_of(entry.owner) end
    end
    return nil
end

local function hotkey_on(key)
    local wanted = key_id(key)
    for index = 1, #hotkeys do
        if key_id(hotkeys[index].key) == wanted then return true end
    end
    return false
end

-- The first of the default keys that nobody has: no owner, and no hotkey of any mod, the asking one's own included.
local function free_key(id)
    for _, key in ipairs(DEFAULT_KEYS) do
        if not taken_by(key, id) and not hotkey_on(key) then return key end
    end
    return nil
end

-- A mod's key: what the player chose, else what the mod asked for, else a default that is given once and remembered.
local function resolve(owner)
    local id = owner.id
    local key = nil
    owner.given = false
    if id == WAX then
        key = toggle_key
    else
        local chosen, kept = saved.keys[id], saved.default_keys[id]
        if chosen == false then
            key = nil
        elseif type(chosen) == "string" and key_id(chosen) then
            key = chosen
        elseif owner.asked and not taken_by(owner.asked, id) then
            key = owner.asked
        else
            owner.given = true
            if type(kept) == "string" and key_id(kept) and not taken_by(kept, id) and not hotkey_on(kept) then
                key = kept
            else
                key = free_key(id)
                if key then
                    saved.default_keys[id] = key
                    remember()
                    owner.announce, announce_due = true, true
                end
            end
        end
    end
    owner.key = key
    owner.writes = key ~= nil and writes(key)
end

-- A key Wax gave by itself moves on when a hotkey takes it, whoever makes the hotkey.
local function yield_defaults(key)
    local wanted = key_id(key)
    if not wanted then return end
    local moved = {}
    for _, owner in pairs(owners) do
        if owner.given and owner.count > 0 and owner.key and key_id(owner.key) == wanted then
            resolve(owner)
            moved[#moved + 1] = owner
        end
    end
    for index = 1, #moved do ui.Keys.Changed:Fire(moved[index].id, moved[index].key) end
end

local function owner_of(id)
    local owner = owners[id]
    if not owner then
        owner = { id = id, open = false, bare = false, count = 0 }
        owners[id] = owner
    end
    return owner
end

local function count_windows()
    for _, owner in pairs(owners) do owner.count = 0 end
    for i = 1, #windows do
        local owner = owners[windows[i].owner_id]
        if owner then owner.count = owner.count + 1 end
    end
end

local function shows_a_window(id)
    for i = 1, #windows do
        if windows[i].owner_id == id and windows[i].shown then return true end
    end
    return false
end

-- True while some owner's windows are up, or (unless windows_only) one has the menu open without windows.
local function anyone(windows_only)
    for _, owner in pairs(owners) do
        if owner.open or (not windows_only and owner.bare) then return true end
    end
    return false
end

window_module.interactive = function() return menu_open or preview end

window_module.visible_for = function(id)
    local owner = owners[id]
    return preview or (menu_open and owner ~= nil and owner.open)
end

local function show_layer(shown)
    local layer = root.layer("windows")
    layer_shown = shown
    if layer_animation then layer_animation.cancel() end
    if shown then
        layer:SetVisibility(V.SelfHitTestInvisible)
        layer_animation = tween.run(style.theme.animation, function(progress) layer:SetRenderOpacity(progress) end)
    else
        layer_animation = tween.run(style.theme.animation, function(progress) layer:SetRenderOpacity(1 - progress) end,
            function() layer:SetVisibility(V.Collapsed) end)
    end
end

-- Puts on screen what should be there now. The layer of the windows fades as a whole. With it staying up, single owners fade.
local function arrange(fade)
    local wanted = preview or window_module.any_pinned() or (menu_open and anyone(true))
    if wanted ~= layer_shown then
        window_module.sync(not wanted and "logic" or nil)
        show_layer(wanted)
    else
        window_module.sync(fade and wanted and "fade" or nil)
    end
end

-- A mod that opened the menu without windows hears ui.Closed when its own part of it ends and the menu stays open for others.
local closed_for = setmetatable({}, { __mode = "k" })
local connect_closed = ui.Closed.Connect
function ui.Closed:Connect(fn)
    local connection = connect_closed(self, fn)
    closed_for[connection] = caller()
    return connection
end

local function tell_closed(id)
    local told = {}
    for connection, who in pairs(closed_for) do
        if who == id and connection.Connected then told[#told + 1] = connection end
    end
    for index = 1, #told do
        local connection = told[index]
        if connection.Connected then
            local previous = scope.enter(connection.owner or nil)
            guard.call("Closed", sched.task.spawn, connection.fn)
            scope.leave(previous)
        end
    end
end

local function close_menu()
    if not menu_open then return end
    menu_open, recheck_at = false, nil
    for _, owner in pairs(owners) do owner.open, owner.bare = false, false end
    log:info("menu closed")
    pcall(input.cancel)
    controls.close_list()
    overlay_module.set_moving(false)
    input.set_cursor(false)
    if root.exists() then arrange() end
    ui.Closed:Fire()
end

-- With none of its windows shown, the ones the player closed come back. True when the owner then has a window to show.
local function bring_windows(id)
    if shows_a_window(id) then return true end
    local any = false
    for i = 1, #windows do
        local window = windows[i]
        if window.owner_id == id and window.closed_by_user then
            window.making = true
            window:Show()
            window.making = nil
            any = true
        end
    end
    return any
end

-- What an owner opened without windows is over, because its mod is gone: the menu closes if that was all that held it open.
local function end_bare(id)
    local owner = owners[id]
    if not owner or not owner.bare then return end
    owner.bare = false
    if menu_open and not anyone() then close_menu() end
end

-- Shows one owner's windows and frees the mouse. bare: the mouse only. by_key: an owner with nothing to show stays as it is.
local function open_for(id, bare, by_key)
    if not root.exists() then return end
    local owner = owner_of(id)
    if not bare then
        if bring_windows(id) then
            owner.open = true
        elseif by_key then
            return
        else
            bare = true
        end
    end
    if bare then
        owner.bare = true
        -- it ends with whoever asked for it: a mod that is switched off or loads again cannot close it any more
        local asker = scope.current()
        while asker and asker.parent do asker = asker.parent end
        if asker and owner.bare_for ~= asker then
            owner.bare_for = asker
            asker:add(function()
                if owner.bare_for == asker then owner.bare_for = nil end
                end_bare(id)
            end)
        end
    end
    local opening = not menu_open
    if opening then
        menu_open, cursor_taken, cursor_wait = true, 0, 0
        log:info("menu opened")
        overlay_module.set_moving(true)
        input.set_cursor(true)
    end
    arrange(not opening)
    if opening then ui.Opened:Fire() end
end

-- Hides one owner's windows. bare_too: what it opened without windows ends as well. The menu closes with its last owner.
local function close_for(id, bare_too)
    local owner = owners[id]
    if not menu_open or not owner then return end
    local was_bare = bare_too and owner.bare
    if not owner.open and not was_bare then return end
    owner.open = false
    if was_bare then owner.bare = false end
    if not anyone() then return close_menu() end
    -- a key that was being waited for in a window that is going away is not waited for any more
    pcall(input.cancel)
    arrange(true)
    if was_bare then tell_closed(id) end
end

-- An owner none of whose windows is shown any more is not up. With nobody left, the menu closes.
local function settle()
    if not menu_open then return end
    local changed = false
    for id, owner in pairs(owners) do
        if owner.open and not shows_a_window(id) then owner.open, changed = false, true end
    end
    if not anyone() then return close_menu() end
    if changed then arrange(true) end
end

-- Shows the caller's windows (a mod's own, or Wax's panel) and frees the mouse. options: { windows = false } frees the mouse only.
function ui.Open(options)
    open_for(caller(), type(options) == "table" and options.windows == false)
end

-- Hides the caller's windows again. The menu closes, and the game has the mouse back, once nobody's windows are up.
function ui.Close()
    close_for(caller(), true)
end

function ui.Toggle()
    local id = caller()
    local owner = owners[id]
    if menu_open and owner and (owner.open or owner.bare) then close_for(id, true) else open_for(id) end
end

-- Puts text on the clipboard, for pasting anywhere (the game's own function does it).
function ui.Copy(text)
    if text == ui then error("write ui.Copy(...) with a dot, not a colon", 2) end
    root.library("UMGFunctionLibrary", "Icarus"):CopyToClipboard(tostring(text))
end
function ui.IsOpen() return menu_open end

-- How wide a line of text is in the interface font, in the units controls are sized in. options: { size, face = "Bold", family = "mono" }
function ui.TextWidth(text, options)
    if text == ui then error("write ui.TextWidth(...) with a dot, not a colon", 2) end
    options = options or {}
    return kit.text_width(text, options.size, options.family, options.face)
end
-- The text if it fits in `width`, else its start with "..." after it. Then whether it was cut. Same options.
function ui.Shorten(text, width, options)
    if text == ui then error("write ui.Shorten(...) with a dot, not a colon", 2) end
    options = options or {}
    return kit.shorten(text, (tonumber(width) or 0) * kit.FIT, options.size, options.family, nil, options.face)
end

-- Shows every window without taking the mouse (for screenshots and for looking while you play).
function ui.SetPreview(on)
    on = on and true or false
    if preview == on then return end
    preview = on
    if root.exists() then arrange() end
end
function ui.IsPreview() return preview end

-- The key that shows and hides an owner's windows: "Wax" or a mod's id. Left out, the mod that asks.
function ui.Keys.Get(id)
    if id == ui.Keys then error("write ui.Keys.Get(...) with a dot, not a colon", 2) end
    id = id or caller()
    if id == WAX then return toggle_key end
    local owner = owners[id]
    if owner and owner.count > 0 then return owner.key end
    local chosen = saved.keys[id]
    if chosen == false then return nil end
    return type(chosen) == "string" and chosen or declared_key(id) or saved.default_keys[id]
end

-- The key a mod's mod.lua names for its windows, as the player has it now. nil when mod.lua names none: for a mod that is not running.
function ui.Keys.Named(id)
    if id == ui.Keys then error("write ui.Keys.Named(...) with a dot, not a colon", 2) end
    local named = declared_key(id)
    if not named then return nil end
    local chosen = saved.keys[id]
    if chosen == false then return nil end
    return type(chosen) == "string" and key_id(chosen) and chosen or named
end

-- Gives an owner another key (nil: none). A key somebody has already is taken all the same: a notice says who else has it, and the second answer names them.
function ui.Keys.Set(id, key)
    if id == ui.Keys then error("write ui.Keys.Set(...) with a dot, not a colon", 2) end
    if type(id) ~= "string" or id == "" then error("ui.Keys.Set expects an owner: \"Wax\" or a mod's id", 2) end
    if key ~= nil and not key_id(key) then error("ui.Keys.Set expects a key name such as \"F6\" or \"Ctrl+K\", or nil for none", 2) end
    -- a key somebody else has is taken all the same: the player is told, and the Mods page shows the clash
    local holder = key and taken_by(key, id)
    if holder then
        notify.show(("%s is also used by %s. One press acts on both: change one of them."):format(key, holder),
            { title = "Key clash", kind = "warn", seconds = 7 })
    end
    if id == WAX then
        toggle_key = key
        saved.key = key or false
    else
        saved.keys[id] = key or false
    end
    if owners[id] then resolve(owners[id]) end
    remember()
    if id == WAX then ui.KeyChanged:Fire(key) end
    ui.Keys.Changed:Fire(id, key)
    return true, holder or nil
end

-- Every owner that has a window: { id, name, key, open }, Wax first. open: its windows are up now.
function ui.Keys.Owners()
    local out = {}
    for id, owner in pairs(owners) do
        if owner.count > 0 then out[#out + 1] = { id = id, name = name_of(id), key = owner.key, open = menu_open and owner.open } end
    end
    table.sort(out, function(a, b)
        if (a.id == WAX) ~= (b.id == WAX) then return a.id == WAX end
        if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
        return a.id < b.id
    end)
    return out
end

-- The key of Wax's own panel. Every mod has a key of its own for its windows (ui.Keys).
function ui.SetToggleKey(key)
    if key ~= nil and not key_id(key) then error("ui.SetToggleKey expects a key name such as \"F8\", or nil for none", 2) end
    return ui.Keys.Set(WAX, key)
end
function ui.GetToggleKey() return toggle_key end

-- options: { title, width, height, x, y, closable = true, visible = true, nav = nil | "side" | "top", key = the mod's open key }
function ui.Window(options)
    if options == ui then error("write ui.Window({ ... }) with a dot, not a colon", 2) end
    local asked = type(options) == "table" and options.key or nil
    if asked ~= nil and not key_id(asked) then error("key is a key name such as \"F6\" or \"Ctrl+K\"", 2) end
    local id = caller()
    if asked == nil and id ~= WAX then asked = declared_key(id) end
    local owner = owner_of(id)
    local first = owner.count == 0
    local window = window_module.create(options, id)
    count_windows()
    if first and id ~= WAX then
        owner.asked = asked
        resolve(owner)
    end
    if owner.key and not menu_open and not rawget(_G, "WaxGuiHintShown") then
        rawset(_G, "WaxGuiHintShown", true)
        owner.announce = nil
        notify.show(("Press %s to open the menu."):format(owner.key), { title = "Wax", seconds = 6 })
    end
    return window
end

ui.Overlay = overlay_module.create
ui.Panel = overlay_module.panel
-- The value of the slot under the mouse, then its look and its control.
ui.Hovered = slots.hovered
ui.IsTyping = controls.typing
local changing_since = nil  -- the clock at the last change of the screen or the interface scale that mods have not been told of
local answered = nil        -- the size ui.ScreenSize last gave out while it was still changing
local function screen_size()
    local width, height = root.viewport_size()
    return width / style.scale, height / style.scale
end
-- The size of the screen in the units windows and panels are laid out in. Until the game has a screen it is 1920 by 1080.
function ui.ScreenSize()
    local width, height = screen_size()
    if changing_since then answered = { width, height } end
    return width, height
end
-- Fires once with the new size, when the screen or the interface scale has stopped changing.
ui.ScreenChanged = sched.Signal.new("ScreenChanged")
ui.Pictures = { Check = pictures.check, Stats = pictures.stats }
-- ui.FitGame({ scale = 0.85, corner = "bottom-left" }) draws the game's own menus smaller, which leaves room beside them.
ui.FitGame = fit.create
-- The game's own menu screen that is showing now, and the main menu's tab number. Nothing when none shows.
ui.GameScreen = fit.screen
-- Fires with that name and tab in the frame another screen of the game shows, or none any more.
ui.GameScreenChanged = fit.Changed

-- ui.Tag(creature, { text = "Wolf" }) keeps a line of text over something in the world: :Set, :SetColor, :Remove
ui.Tag = tags.create

-- Every Lucide icon by name ("shield", "wrench", ...), plus images a mod registers: ui.Icons.Register("logo", mod.dir .. "/logo.png")
ui.Icons = { Names = icons.list, Has = icons.has, Find = icons.find, Register = icons.register }

-- ui.Notify("Saved.", { title = "Garage", kind = "good" }) returns the notification: :SetText, :SetProgress, :Close
ui.Notify = notify.show
ui.Notifications = { SetCorner = notify.set_corner, SetLimit = notify.set_limit, Clear = notify.clear, Count = notify.count }
function ui.Windows() return table.move(windows, 1, #windows, 1, {}) end

-- A plain key gives way to the same key with Ctrl, Shift or Alt: "3" does not run while Ctrl is held if "Ctrl+3" is bound.
local function gives_way(key)
    local plain = input.parse(key)
    if plain.held then return false end
    local ctrl, shift, alt = nil, nil, nil
    local function bound(other_key)
        local other = input.parse(other_key)
        if not other.held or other.key ~= plain.key then return false end
        if ctrl == nil then ctrl, shift, alt = input.modifiers() end
        return other.ctrl == ctrl and other.shift == shift and other.alt == alt
    end
    for index = 1, #hotkeys do
        if bound(hotkeys[index].key) then return true end
    end
    for _, owner in pairs(owners) do
        if owner.key and owner.count > 0 and bound(owner.key) then return true end
    end
    return false
end

-- Every key a mod makes can be changed by the player on the mod's card: the named ones (ui.Bind) and the plain ones (ui.Hotkey).
local binds, binds_stamp = {}, 0
local find_bind, bind_apply

-- Runs callback() when the key ("F6", "K", "MiddleMouseButton" ...) is pressed during play, and in the menu too with options.in_menu.
function ui.Hotkey(key, callback, options)
    if type(key) ~= "string" or key == "" then error("ui.Hotkey expects a key name such as \"F6\"", 2) end
    if type(callback) ~= "function" then error("ui.Hotkey expects a function to run", 2) end
    -- typing = true lets it run while a text box has the keyboard (a key such as Tab that is meant for the box).
    -- hover = true makes it a key for the slot under the mouse: it is not even looked at while no slot is under it.
    -- name = what the mod's card calls the key.
    local owner = caller()
    local entry = { key = key, run = guard.wrap("hotkey " .. key, function() sched.task.spawn(callback) end),
        in_menu = options and options.in_menu or false, typing = options and options.typing or false,
        hover = options and options.hover or false, writes = writes(key), owner = owner }
    local record = nil
    if owner ~= WAX then
        -- a mod's key: listed on its card under a name, and what the player chose there is used
        local name = options and options.name
        if type(name) ~= "string" or name == "" then name = "Key " .. key end
        local base, count = name, 1
        while find_bind(owner, name) do
            count = count + 1
            name = ("%s (%d)"):format(base, count)
        end
        record = { owner = owner, name = name, label = name, default = key, changed = sched.Signal.new("Changed"), entry = entry }
        entry.bind = record
        binds[#binds + 1] = record
        binds_stamp = binds_stamp + 1
        bind_apply(record)
    else
        hotkeys[#hotkeys + 1] = entry
        yield_defaults(key)
    end
    local function disconnect()
        for index = #hotkeys, 1, -1 do
            if hotkeys[index] == entry then table.remove(hotkeys, index) end
        end
        if record then
            for index = #binds, 1, -1 do
                if binds[index] == record then
                    table.remove(binds, index)
                    binds_stamp = binds_stamp + 1
                end
            end
        end
    end
    scope.own(disconnect)
    return { Disconnect = disconnect, Changed = record and record.changed or nil,
        Get = function() if record then return record.key end return entry.key end,
        SetKey = function(_, new_key)
            if record then return ui.Keys.SetBind(owner, record.name, new_key) end
            entry.key, entry.writes = new_key, writes(new_key)
            yield_defaults(new_key)
        end }
end

-- A mod's named keys: the player sees each on the mod's card and can change it there.
ui.Keys.BindChanged = sched.Signal.new("BindChanged")

local function bind_key(record)
    local of = type(saved.binds) == "table" and saved.binds[record.owner] or nil
    local chosen = nil
    if type(of) == "table" then chosen = of[record.name] end
    if chosen == false then return nil end
    if type(chosen) == "string" and key_id(chosen) then return chosen end
    return record.default
end

function bind_apply(record)
    local key, entry, listed = bind_key(record), record.entry, false
    record.key = key
    for index = #hotkeys, 1, -1 do
        if hotkeys[index] == entry then
            listed = true
            if not key then table.remove(hotkeys, index) end
        end
    end
    if not key then return end
    entry.key, entry.writes = key, writes(key)
    if not listed then hotkeys[#hotkeys + 1] = entry end
    yield_defaults(key)
end

local function manifest_of(id)
    local mods = Wax.mods
    local mod = mods and mods.get and mods.get(id)
    return mod and type(mod.manifest) == "table" and mod.manifest or nil, mod
end

-- The keys a mod's mod.lua names: keys = { "F10: Show or hide the panels" }. Known before the mod has run.
local function declared(id)
    local manifest = manifest_of(id)
    local list = manifest and manifest.keys
    local out = {}
    if type(list) ~= "table" then return out end
    for index = 1, #list do
        local key, name = tostring(list[index]):match("^%s*([^:]-)%s*:%s*(.-)%s*$")
        if name and name ~= "" and key_id(key) then
            local record = { owner = id, name = name, label = name, default = key }
            record.key = bind_key(record)
            out[#out + 1] = record
        end
    end
    return out
end

-- The key mod.lua gives for the mod's windows: key = "F6".
function declared_key(id)
    local manifest = manifest_of(id)
    local key = manifest and manifest.key
    return key_id(key) and key or nil
end

function find_bind(id, name)
    for index = 1, #binds do
        if binds[index].owner == id and binds[index].name == name then return binds[index], index end
    end
    return nil
end

-- Everything that acts on a key, grouped by key: the Wax menu, each mod's windows, each named key, each plain hotkey of a mod.
local function key_users()
    local groups, seen = {}, {}
    local function add(key, owner, what)
        local id = key_id(key)
        if not id or seen[id .. "|" .. owner .. "|" .. what] then return end
        seen[id .. "|" .. owner .. "|" .. what] = true
        local group = groups[id]
        if not group then
            group = { key = key, users = {}, owners = {}, count = 0 }
            groups[id] = group
        end
        group.users[#group.users + 1] = { owner = owner, what = what }
        if not group.owners[owner] then group.owners[owner], group.count = true, group.count + 1 end
    end
    if toggle_key then add(toggle_key, WAX, "the Wax menu") end
    for id, owner in pairs(owners) do
        if id ~= WAX and owner.count > 0 and owner.key then add(owner.key, id, name_of(id) .. " (its windows)") end
    end
    for index = 1, #hotkeys do
        local entry = hotkeys[index]
        if entry.hover then
            -- a key for the slot under the mouse acts nowhere else, so it clashes with nobody
        elseif entry.bind then
            add(entry.key, entry.owner, ("%s (%s)"):format(name_of(entry.owner), entry.bind.label))
        elseif entry.owner ~= WAX then
            add(entry.key, entry.owner, name_of(entry.owner))
        end
    end
    -- a mod that is not running: the keys its mod.lua names, so a clash shows before it is switched on
    local mods = Wax.mods
    local listed, list = pcall(function() return mods.list() end)
    if listed and type(list) == "table" then
        for index = 1, #list do
            local mod = list[index]
            if mod.status ~= "loaded" then
                local id = mod.id
                local chosen = saved.keys[id]
                local windows = declared_key(id) and chosen ~= false and (type(chosen) == "string" and chosen or declared_key(id)) or nil
                if windows then add(windows, id, name_of(id) .. " (its windows)") end
                for _, record in ipairs(declared(id)) do
                    if record.key then add(record.key, id, ("%s (%s)"):format(name_of(id), record.label)) end
                end
            end
        end
    end
    return groups
end

-- The engine's own keys give way to a key Wax or a mod uses, and come back when nobody uses it any more: the keys that
-- open the engine's console (a list in the engine's input settings), F11 for fullscreen and Alt+Enter for the same.
-- The engine asks those settings at every key press, so taking a key out of them is all it takes.
-- What was taken is kept in a real global, so a reload of the interface still knows what to give back.
local engine_keys = rawget(_G, "WaxEngineKeys")
if not engine_keys then
    engine_keys = { console = {}, said = "" }
    rawset(_G, "WaxEngineKeys", engine_keys)
end
local engine_checked = -1000
ui.ENGINE_KEYS = true       -- false leaves the engine's keys alone

-- Which plain keys are in use (no Ctrl, Shift or Alt with them), whether F11 is, and whether Alt+Enter is.
local function keys_in_use()
    local plain, f11, alt_enter = {}, false, false
    local function add(key)
        if type(key) ~= "string" or key == "" then return end
        local ok, want = pcall(input.parse, key)
        if not ok or want.key == "" then return end
        if not (want.ctrl or want.shift or want.alt) then plain[want.key] = true end
        if want.key == "F11" and not (want.ctrl or want.alt) then f11 = true end
        if want.key == "Enter" and want.alt then alt_enter = true end
    end
    add(toggle_key)
    for id, owner in pairs(owners) do
        if id ~= WAX and owner.count > 0 then add(owner.key) end
    end
    for index = 1, #hotkeys do
        if hotkeys[index].owner ~= WAX then add(hotkeys[index].key) end
    end
    return plain, f11, alt_enter
end

local function sync_engine_keys()
    local plain, f11, alt_enter = keys_in_use()
    if not ui.ENGINE_KEYS then plain, f11, alt_enter = {}, false, false end
    local names = {}
    for name in pairs(plain) do names[#names + 1] = name end
    table.sort(names)
    local said = table.concat(names, ",") .. (f11 and "|f11" or "") .. (alt_enter and "|altenter" or "")
    if said == engine_keys.said then return end
    local settings = StaticFindObject("/Script/Engine.Default__InputSettings")
    if not settings:IsValid() then
        engine_keys.said = said
        return
    end
    local console = settings.ConsoleKeys
    local count = #console
    -- a console key that is one of ours is blanked where it stands, and one nobody uses any more gets its name back
    for index = 1, count do
        local name = console[index].KeyName:ToString()
        if plain[name] then
            console[index].KeyName = FName("None")
            engine_keys.console[index] = name
            log:info("%s is a key of the mod manager now, so the game's console no longer opens on it", name)
        end
    end
    for index, name in pairs(engine_keys.console) do
        if not plain[name] then
            if index <= count and console[index].KeyName:ToString() == "None" then console[index].KeyName = FName(name) end
            engine_keys.console[index] = nil
        end
    end
    -- the two fullscreen keys are switches of the same settings
    if f11 and engine_keys.f11 == nil and settings.bF11TogglesFullscreen == true then
        settings.bF11TogglesFullscreen = false
        engine_keys.f11 = true
    elseif not f11 and engine_keys.f11 then
        settings.bF11TogglesFullscreen = true
        engine_keys.f11 = nil
    end
    if alt_enter and engine_keys.alt_enter == nil and settings.bAltEnterTogglesFullscreen == true then
        settings.bAltEnterTogglesFullscreen = false
        engine_keys.alt_enter = true
    elseif not alt_enter and engine_keys.alt_enter then
        settings.bAltEnterTogglesFullscreen = true
        engine_keys.alt_enter = nil
    end
    engine_keys.said = said
end

-- Looked at a few times a second: the keys in use are few, and the engine is only touched when they changed.
local function engine_keys_step()
    if frames - engine_checked < 30 then return end
    engine_checked = frames
    local ok, problem = pcall(sync_engine_keys)
    if not ok and not engine_keys.warned then
        engine_keys.warned = true
        log:warn("the engine's own keys could not be looked at, so they stay as they are: %s", (tostring(problem):match("^[^\r\n]*")))
    end
end

-- The keys more than one owner acts on, as lines of text. With an id, only that owner's, said from its side.
function ui.Keys.Clashes(id)
    if id == ui.Keys then error("write ui.Keys.Clashes(...) with a dot, not a colon", 2) end
    local out = {}
    for _, group in pairs(key_users()) do
        if group.count > 1 and (id == nil or group.owners[id]) then
            local names = {}
            for _, user in ipairs(group.users) do
                if user.owner ~= id then names[#names + 1] = user.what end
            end
            table.sort(names)
            if id then
                out[#out + 1] = ("%s is also used by %s. One press acts on both: change one of them."):format(group.key, table.concat(names, " and "))
            else
                -- for the whole list, who shares the key is enough: each owner once, by its name
                local who, seen = {}, {}
                for _, user in ipairs(group.users) do
                    if not seen[user.owner] then
                        seen[user.owner] = true
                        who[#who + 1] = user.owner == WAX and "the Wax menu" or name_of(user.owner)
                    end
                end
                table.sort(who)
                local last = table.remove(who)
                out[#out + 1] = ("%s is used by %s%s and %s."):format(group.key, #who == 1 and "both " or "", table.concat(who, ", "), last)
            end
        end
    end
    table.sort(out)
    return out
end

-- Who shares a key right now, as one function to ask many times: clashing(id, key) is true when somebody else acts on
-- that key of that owner too. It answers for the moment it was made.
function ui.Keys.Clashing()
    local groups = key_users()
    return function(id, key)
        local wanted = key_id(key)
        local group = wanted and groups[wanted]
        return group ~= nil and group ~= false and group.count > 1 and group.owners[id] == true
    end
end

-- The named keys of one mod, or of every mod: { Id, Name, Label, Key, Default }.
function ui.Keys.Binds(id)
    if id == ui.Keys then error("write ui.Keys.Binds(...) with a dot, not a colon", 2) end
    local out = {}
    for index = 1, #binds do
        local record = binds[index]
        if id == nil or record.owner == id then
            out[#out + 1] = { Id = record.owner, Name = record.name, Label = record.label, Key = record.key, Default = record.default }
        end
    end
    if id ~= nil and #out == 0 then
        for _, record in ipairs(declared(id)) do
            out[#out + 1] = { Id = id, Name = record.name, Label = record.label, Key = record.key, Default = record.default, Declared = true }
        end
    end
    return out
end

-- The name of the key that brings a mod's interface up: the first one its mod.lua names in `keys`. nil when it names none.
function ui.Keys.Main(id)
    if id == ui.Keys then error("write ui.Keys.Main(...) with a dot, not a colon", 2) end
    local first = declared(id)[1]
    return first and first.name or nil
end

-- Goes up whenever a named key comes or goes.
function ui.Keys.BindsStamp() return binds_stamp end

-- Gives a named key of a mod another key (nil: none). A key somebody else uses is taken all the same, and a notice says who has it.
function ui.Keys.SetBind(id, name, key)
    if id == ui.Keys then error("write ui.Keys.SetBind(...) with a dot, not a colon", 2) end
    if type(id) ~= "string" or type(name) ~= "string" then error("ui.Keys.SetBind expects a mod's id and the name of one of its keys", 2) end
    if key ~= nil and not key_id(key) then error("ui.Keys.SetBind expects a key name such as \"F6\" or \"Ctrl+K\", or nil for none", 2) end
    if type(saved.binds) ~= "table" then saved.binds = {} end
    if type(saved.binds[id]) ~= "table" then saved.binds[id] = {} end
    saved.binds[id][name] = key or false
    remember()
    local record = find_bind(id, name)
    if record then
        bind_apply(record)
        record.changed:Fire(record.key)
    end
    ui.Keys.BindChanged:Fire(id, name, key)
    if key and record then
        local lines = ui.Keys.Clashes(id)
        local wanted = key_id(key)
        for _, line in ipairs(lines) do
            if key_id(line:match("^(%S+) is also")) == wanted then
                notify.show(line, { title = "Key clash", kind = "warn", seconds = 7 })
                break
            end
        end
    end
    return true
end

-- ui.Bind("Open", "F10", fn, { label = "Open the panels", in_menu = true }): a hotkey with a name, which the player can change.
function ui.Bind(name, key, callback, options)
    if type(name) ~= "string" or name == "" then error("ui.Bind expects a name for the key, such as \"Open\"", 2) end
    if key ~= nil and not key_id(key) then error("ui.Bind expects a key name such as \"F10\" or \"Ctrl+K\", or nil for no key until the player gives one", 2) end
    if type(callback) ~= "function" then error("ui.Bind expects a function to run", 2) end
    if options ~= nil and type(options) ~= "table" then error("the options of ui.Bind are a table such as { label = \"Open the panels\" }", 2) end
    local owner = caller()
    if find_bind(owner, name) then error(("this mod already has a key named '%s'"):format(name), 2) end
    local label = options and options.label
    if type(label) ~= "string" or label == "" then label = name end
    if key == nil then
        for _, named in ipairs(declared(owner)) do
            if named.name == name then key = named.default end
        end
    end
    local record = { owner = owner, name = name, label = label, default = key, changed = sched.Signal.new("Changed") }
    record.entry = { key = key, run = guard.wrap("key " .. name, function() sched.task.spawn(callback) end),
        in_menu = options and options.in_menu or false, typing = options and options.typing or false, hover = false,
        writes = false, owner = owner, bind = record }
    binds[#binds + 1] = record
    binds_stamp = binds_stamp + 1
    bind_apply(record)
    local function disconnect()
        local found, index = find_bind(owner, name)
        if found ~= record then return end
        table.remove(binds, index)
        binds_stamp = binds_stamp + 1
        for at = #hotkeys, 1, -1 do
            if hotkeys[at] == record.entry then table.remove(hotkeys, at) end
        end
    end
    scope.own(disconnect)
    return { Changed = record.changed, Disconnect = disconnect,
        Get = function() return record.key end,
        Set = function(_, new_key) return ui.Keys.SetBind(owner, name, new_key) end }
end

-- True while the key is held, by the names ui.Hotkey takes. It asks the game each time, so it is for a loop that runs while something is held.
function ui.IsKeyDown(key)
    if type(key) ~= "string" or key == "" or not pcall(input.parse, key) then
        error("ui.IsKeyDown expects a key name such as \"A\" or \"Ctrl+K\"", 2)
    end
    return input.is_down(key)
end

-- Closing an owner's last window takes that owner down, and the last owner the menu: the mouse never stays free with nothing to click.
window_module.on_hidden = function(window, destroyed)
    if destroyed then count_windows() end
    local owner = owners[window.owner_id]
    if not menu_open or not owner or not owner.open or shows_a_window(owner.id) then return end
    if destroyed and owner.id ~= WAX and window.owner and not window.owner.alive then
        -- it went with what its mod set up, so the mod may be loading again: a window it makes in the next moment shows at once
        recheck_at = frames + GRACE
    else
        close_for(owner.id)
    end
end

-- A window its mod shows while the menu is open comes up there and then, with its owner's others.
window_module.on_shown = function(window)
    local owner = owners[window.owner_id]
    if menu_open and owner and not owner.open then
        owner.open = true
        arrange(true)
    end
end

local MIN_SHARP, SMALLEST, MAX_SCALE = 0.9, 0.7, 2
local SETTLE = 0.4          -- seconds the screen has to stay as it is before mods are told of its new size
local wanted_scale = 1
local told_width, told_height = 1920, 1080
local size_followers = {}   -- each brings one "Interface size" control up to date and answers false once it is gone

-- The smallest scale that still draws text at a readable size on this screen. Before the game has a screen: the smallest there is.
function ui.MinScale()
    if not root.screen_known() then return SMALLEST end
    local _, _, pixels = root.viewport_size()
    return math.max(SMALLEST, MIN_SHARP / pixels)
end

local function follow_size()
    for index = #size_followers, 1, -1 do
        if not size_followers[index]() then table.remove(size_followers, index) end
    end
end

-- Puts on the size the player asked for, kept to what this screen can show. True when it changed.
local function apply_scale()
    local applied = math.max(ui.MinScale(), math.min(MAX_SCALE, wanted_scale))
    if applied == style.scale then return false end
    style.scale = applied
    window_module.rescale()
    overlay_module.rescale()
    notify.rescale()
    tags.rescale()
    tip.rescale()
    changing_since = sched.clock()
    return true
end

-- 1 is the normal size. A value this screen cannot show sharply is raised to ui.MinScale().
function ui.SetScale(scale)
    if type(scale) ~= "number" then error("ui.SetScale expects a number such as 1.25", 2) end
    wanted_scale = scale
    if saved.scale ~= scale then
        saved.scale = scale
        remember()
    end
    apply_scale()
    follow_size()
    return style.scale
end
function ui.GetScale() return style.scale end

local function differs(width, height, from_width, from_height)
    return math.abs(width - from_width) > 0.5 or math.abs(height - from_height) > 0.5
end

-- The screen has stayed as it is: mods that laid themselves out for another size are told, once.
local function screen_settled()
    changing_since = nil
    follow_size()
    local width, height = screen_size()
    local given = answered
    answered = nil
    if differs(width, height, told_width, told_height) or (given and differs(width, height, given[1], given[2])) then
        told_width, told_height = width, height
        ui.ScreenChanged:Fire(width, height)
    end
end

-- Every frame: what Wax draws follows the screen in the frame it changes. Nothing is built again for it.
local function watch_screen()
    if root.watch(changing_since ~= nil) then
        local _, _, pixels = root.viewport_size()
        style.screen_scale = pixels
        if not apply_scale() then window_module.keep_on_screen() end
        overlay_module.place_all()
        changing_since = sched.clock()
    end
    if changing_since and sched.clock() - changing_since >= SETTLE then screen_settled() end
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


local SIZES = { 70, 80, 90, 100, 110, 125, 150, 175, 200 }

-- The interface sizes this screen can show, and the one nearest to the size in use.
local function sizes_now()
    local offered, current, nearest = {}, nil, math.huge
    local least = math.min(ui.MinScale(), MAX_SCALE) - 0.001
    for _, percent in ipairs(SIZES) do
        if percent / 100 >= least then
            offered[#offered + 1] = percent .. "%"
            local away = math.abs(percent / 100 - style.scale)
            if away < nearest then current, nearest = percent .. "%", away end
        end
    end
    return offered, current
end

-- The key that shows and hides Wax's own panel, as a control that follows the key wherever it is changed.
-- ui.AddSettings adds Wax's own settings (that key, theme, accent, animation, size) to a container, e.g. a "Settings" page.
function ui.AddPanelKey(container, caption)
    local key_control, follow
    key_control = container:Keybind(caption or "Wax panel key", toggle_key, function(key)
        if not ui.Keys.Set(WAX, key) then key_control:Set(toggle_key) end
    end)
    follow = ui.Keys.Changed:Connect(function(id, key)
        if key_control.destroyed then return follow:Disconnect() end
        if id == WAX then key_control:Set(key) end
    end)
    return key_control
end

function ui.AddSettings(container)
    ui.AddPanelKey(container)
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
    local names = {}
    for index, percent in ipairs(SIZES) do names[index] = percent .. "%" end
    local offered, current = sizes_now()
    local size_control = container:Dropdown("Interface size", names, current, function(choice)
        ui.SetScale(tonumber((choice:gsub("%%", ""))) / 100)
    end)
    size_control.offer(offered)
    -- what this screen can show changes with the screen, and so does the size in use
    size_followers[#size_followers + 1] = function()
        if size_control.destroyed then return false end
        local offered_now, current_now = sizes_now()
        size_control.offer(offered_now)
        if size_control:Get() ~= current_now then size_control:Set(current_now) end
        return true
    end
end

function ui.start()
    root.start()
    tags.start()
    saved = storage.load("wax", "interface", saved)
    for _, name in ipairs({ "windows", "overlays", "keys", "default_keys" }) do
        if type(saved[name]) ~= "table" then saved[name] = {} end
    end
    picker.copy = ui.Copy
    input.screen = fit.key
    slots.on_hover(function(look, _, whole)
        local content = look and look.tip
        if look and whole then content = tip.plus(content, whole) end
        if content then tip.show(content) else tip.hide() end
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
    if type(saved.key) == "string" and key_id(saved.key) then toggle_key = saved.key elseif saved.key == false then toggle_key = nil end
    resolve(owners[WAX])
    if type(saved.scale) == "number" then wanted_scale = saved.scale end
    window_module.recall = function(key) return saved.windows[key] end
    window_module.remember = function(key, geometry)
        saved.windows[key] = geometry
        remember()
    end
    root.layer("windows"):SetVisibility(V.Collapsed)
    root.layer("windows"):SetRenderOpacity(0)
    -- a first look: in a game that is running the screen is known at once, in one that is starting it comes later
    root.watch(true)
    style.screen_scale = select(3, root.viewport_size())
    apply_scale()
    changing_since, answered = nil, nil
    told_width, told_height = screen_size()
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
    model.forget_all()
    pictures.forget_all()
    local held = Wax.modules["world.assets"]
    if type(held) == "table" and held.forget_all then held.forget_all() end
    tip.forget()
    notify.destroy_all()
    events.forget_all()
    input.forget()
    hotkeys, size_followers = {}, {}
    binds, binds_stamp = {}, binds_stamp + 1
    menu_open, preview, layer_animation, layer_shown, recheck_at = false, false, nil, false, nil
    for _, owner in pairs(owners) do owner.open, owner.bare, owner.count = false, false, 0 end
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

local function step()
    root.step()
    frames = frames + 1
    engine_keys_step()
    watch_screen()
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
    local panels, over_panel = overlay_module.watch(menu_open or preview, cursor)
    -- One question says whether any key or button went down in this frame. Only then is each key asked for by name.
    local key_down = false
    if not input.capturing() then
        local asked, any = pcall(input.any)
        key_down = not asked or any == true
    end
    -- with the windows away and the mouse over no panel, no slot can be under it
    slots.step(menu_open or panels, key_down, over_panel or menu_open or preview)
    -- a pinned window came or went: the layer of the windows is put up or taken down for it
    local pinned_now = window_module.any_pinned()
    if pinned_now ~= pinned_before then
        pinned_before = pinned_now
        arrange()
    end
    model.step()
    tip.step()
    fit.step()
    if menu_open or preview then controls.step() end
    notify.step()
    tags.step()
    input.step()
    if recheck_at and frames >= recheck_at then
        recheck_at = nil
        settle()
    end
    if announce_due then
        announce_due = false
        -- a key Wax gave a mod by itself is said once, after the mod has made its hotkeys, and only if it has a window to bring up
        for id, owner in pairs(owners) do
            if owner.announce then
                owner.announce = nil
                if owner.key and shows_a_window(id) then
                    notify.show(("Press %s to open %s."):format(owner.key, name_of(id)), { title = "Wax", seconds = 8 })
                end
            end
        end
    end
    if menu_open then
        window_module.step()
        overlay_module.step()
        -- the mouse is the menu's while it is open: the game takes it back when a screen of its own closes, and a new map has a new controller
        if input.cursor_active() then
            if cursor_taken > 0 and frames > cursor_wait + CURSOR_SETTLED then cursor_taken = 0 end
        elseif frames >= cursor_wait and cursor_taken < CURSOR_TRIES and input.set_cursor(true) then
            -- once at once. A game that takes it straight back again is asked a few more times, a while apart, and then left alone
            cursor_taken = cursor_taken + 1
            cursor_wait = frames + (cursor_taken > 1 and CURSOR_PAUSE or 0)
            if cursor_taken == CURSOR_TRIES then log:warn("the game keeps taking the mouse back from the open menu. Close the menu and open it again") end
        end
    end
    if key_down and #hotkeys > 0 and not input.capturing() then
        for index = #hotkeys, 1, -1 do
            local entry = hotkeys[index]
            if (entry.in_menu or not menu_open) and (not entry.hover or slots.hovered() ~= nil) then
                local ok, pressed = pcall(input.just_pressed, entry.key)
                if ok and pressed and (entry.typing or not entry.writes or not controls.typing()) and not gives_way(entry.key) then
                    -- a press its mod's own hotkey takes is not also the key of that mod's windows
                    local owner = owners[entry.owner]
                    if owner and owner.key and key_id(owner.key) == key_id(entry.key) then owner.handled = frames end
                    entry.run()
                end
            end
        end
    end
    -- each owner's key shows or hides that owner's windows, and nobody else's
    if key_down and not input.capturing() then
        for _, owner in pairs(owners) do
            if owner.key and owner.count > 0 and owner.handled ~= frames then
                local ok, pressed = pcall(input.just_pressed, owner.key)
                if ok and pressed and not (owner.writes and controls.typing()) and not gives_way(owner.key) then
                    if owner.open then close_for(owner.id) else open_for(owner.id, false, true) end
                    break
                end
            end
        end
    end
    -- Escape puts back a card that is being dragged, else closes an open list, else everything (the game does not see keys while the menu is open)
    if key_down and menu_open and not input.capturing() then
        local ok, pressed = pcall(input.just_pressed, "Escape")
        if ok and pressed and not grab.cancel() and not controls.close_list() then close_menu() end
    end
    -- give the game its keys back once the menu is closed
    if not menu_open and input.blocking() then input.unblock() end
end

function ui.step()
    if not checked then ui.check() end
    checked = false
    if not usable then return end
    -- one read of the player's controller serves every key looked at in this step, and is dropped whatever happens in it
    input.hold(true)
    local ok, problem = xpcall(step, guard.handler)
    input.hold(false)
    if not ok then error(problem, 0) end
end

function ui.stop()
    pcall(close_menu)
    hotkeys = {}
    binds, binds_stamp = {}, binds_stamp + 1
    window_module.destroy_all()
    overlay_module.destroy_all()
    model.stop()
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
