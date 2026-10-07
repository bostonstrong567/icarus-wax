-- Offline tests for the GUI library against the fake engine: the library's own logic, not the engine's drawing.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\gui_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_engine.lua")
fake.install()

local Wax = t.new_wax()
_G.Wax = Wax
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local log = Wax.import("core.log")
local sched = Wax.import("core.sched")
Wax.log, Wax.guard, Wax.sched = log, guard, sched
local reloads, syncs = {}, 0
Wax.mods = {
    list = function() return { { id = "Hello", name = "Hello", version = "0.1.0", status = "loaded", generation = 1, loadMs = 2 } } end,
    request_reload = function(id) reloads[#reloads + 1] = id end,
    request_sync = function() syncs = syncs + 1 end,
}

Wax.import("core.storage").directory = nil      -- the tests must not read or write the player's saved settings
local ui = Wax.import("gui.init")
local events = Wax.import("gui.events")
local input = Wax.import("gui.input")
ui.start()
Wax.ui = ui
ui.Theme().animation = 0        -- transitions finish at once, so results can be checked straight away

local function frames(count)
    for _ = 1, count or 1 do
        sched.step()
        ui.step()
    end
end
local function click(widget) events.simulate(widget, "OnClicked") end

local owner = scope.new("gui-test")
local seen = { clicks = 0, commits = 0 }
local window, button, toggle, slider, text, dropdown, section, failing, keybind, progress, field

t.test("a window with every control builds", function()
    scope.run(owner, function()
        window = ui.Window({ title = "Test", width = 320, height = 400, x = 100, y = 90 })
        window:Heading("Heading")
        window:Label("Some long text that wraps.", { dim = true })
        button = window:Button("Go", function() seen.clicks = seen.clicks + 1 end, { primary = true })
        toggle = window:Toggle("Flag", true, function(on) seen.toggle = on end)
        slider = window:Slider("Amount", { min = 0, max = 10, value = 4, step = 0.5 }, function(v) seen.slider = v end)
        text = window:Input("Name", { hint = "name" }, function(value) seen.input = value seen.commits = seen.commits + 1 end)
        dropdown = window:Dropdown("Mode", { "One", "Two", "Three" }, "One", function(choice) seen.choice = choice end)
        keybind = window:Keybind("Key", "F5", function(key) seen.key = key end)
        progress = window:Progress("Load", 0.25)
        field = window:Field("Build", 1)
        window:Separator()
        window:Spacer(4)
        local row = window:Row()
        row:Button("A")
        row:Button("B")
        section = window:Section("More", { open = false })
        section:Toggle("Inner", false)
        failing = window:Button("Breaks", function() error("handler blew up on purpose") end)
        local long = {}
        for i = 1, 12 do long[i] = "Choice " .. i end
        window:Dropdown("Long", long, "Choice 3")
        window:Console({ height = 100 }):SetLines({ { "one" }, { "two", ui.Theme().bad } })
    end)
    t.ok(window:IsVisible())
    t.eq(ui.stats().windows, 1)
end)

t.test("what can be pressed shows the hand cursor, and stops showing it while disabled", function()
    local style = Wax.import("gui.style")
    t.eq(fake.last(button.source, "SetCursor")[2], style.Cursor.Hand)
    t.eq(fake.last(toggle.source, "SetCursor")[2], style.Cursor.Hand)
    t.eq(fake.last(dropdown.items.Two, "SetCursor")[2], style.Cursor.Hand)
    t.eq(fake.last(window.bar, "SetCursor")[2], style.Cursor.Default, "the title bar drags, it is not pressed")
    t.eq(fake.count(text.source, "SetCursor"), 0, "a text box keeps its own cursor")
    button:SetEnabled(false)
    t.eq(fake.last(button.source, "SetCursor")[2], style.Cursor.Default)
    text:SetEnabled(false)
    t.eq(fake.count(text.source, "SetCursor"), 0)
    button:SetEnabled(true)
    text:SetEnabled(true)
    t.eq(fake.last(button.source, "SetCursor")[2], style.Cursor.Hand)
end)

t.test("button click reaches the handler and its signal", function()
    local signalled = 0
    button.Activated:Connect(function() signalled = signalled + 1 end)
    click(button.source)
    click(button.source)
    t.eq(seen.clicks, 2)
    t.eq(signalled, 2)
end)

t.test("toggle flips on a click; Set changes it without firing", function()
    click(toggle.source)
    t.eq(toggle:Get(), false)
    t.eq(seen.toggle, false)
    seen.toggle = "untouched"
    toggle:Set(true)
    t.eq(toggle:Get(), true)
    t.eq(seen.toggle, "untouched")
end)

t.test("slider snaps to its step and clamps", function()
    events.simulate(slider.source, "OnValueChanged", 7.26)
    t.eq(slider:Get(), 7.5)
    t.eq(seen.slider, 7.5)
    slider:Set(99)
    t.eq(slider:Get(), 10)
end)

t.test("text input commits once per change and reports typing", function()
    local typed
    text.Typed:Connect(function(value) typed = value end)
    events.simulate(text.source, "OnTextChanged", "Bo")
    events.simulate(text.source, "OnTextCommitted", "Bob")
    events.simulate(text.source, "OnTextCommitted", "Bob")
    t.eq(typed, "Bo")
    t.eq(seen.input, "Bob")
    t.eq(seen.commits, 1)
end)

t.test("dropdown opens in place, picks a choice and closes", function()
    click(dropdown.source)
    t.ok(dropdown.parts.open, "open after a click on the header")
    click(dropdown.items.Three)
    t.ok(not dropdown.parts.open, "closed after picking")
    t.eq(dropdown:Get(), "Three")
    t.eq(seen.choice, "Three")
end)

t.test("section expands and collapses", function()
    t.ok(not section:IsOpen())
    click(section.control.source)
    t.ok(section:IsOpen())
    section:SetOpen(false)
    t.ok(not section:IsOpen())
end)

t.test("progress clamps and a field updates", function()
    progress:Set(3)
    t.eq(progress:Get(), 1)
    field:Set("two")
end)

t.test("a keybind waits for a key and closing the menu cancels it", function()
    click(keybind.source)
    t.ok(input.capturing())
    ui.Open()
    ui.Close()
    t.ok(not input.capturing())
    t.eq(keybind:Get(), "F5")
end)

t.test("a handler that raises is reported, and the control keeps working", function()
    click(failing.source)
    click(button.source)
    local reported = false
    for _, record in ipairs(guard.errors()) do
        if record.trace:find("handler blew up on purpose", 1, true) then reported = true end
    end
    t.ok(reported)
    t.eq(seen.clicks, 3)
    t.ok(ui.Notifications.Count() >= 1, "the error is also shown to the player as a notification")
end)

t.test("minimise, restore, close and show", function()
    click(window.minimize_button)
    t.ok(window:IsMinimized())
    t.eq(window.slot:GetSize().Y, ui.Theme().bar_height)
    click(window.minimize_button)
    t.eq(window.slot:GetSize().Y, 400)
    local closed = 0
    window.Closed:Connect(function() closed = closed + 1 end)
    click(window.close_button)
    t.ok(not window:IsVisible())
    t.eq(closed, 1)
    window:Show()
    t.ok(window:IsVisible())
end)

t.test("position and size are clamped and applied", function()
    window:SetPosition(-500, -500)
    t.eq(window.slot:GetPosition().X, 0)
    window:SetSize(10, 10)
    t.ok(window.slot:GetSize().X >= 240 and window.slot:GetSize().Y >= 140)
    window:SetPosition(100, 90)
    window:SetSize(320, 400)
end)

t.test("the menu opens and closes, and closing the last window closes the menu", function()
    t.ok(not ui.IsOpen())
    ui.Toggle()
    t.ok(ui.IsOpen())
    local closed = 0
    local connection = ui.Closed:Connect(function() closed = closed + 1 end)
    click(window.close_button)
    t.ok(not ui.IsOpen(), "menu closed with its last window")
    t.eq(closed, 1)
    ui.Open()
    t.ok(window:IsVisible(), "opening the menu brings back the window the user closed")
    ui.Close()
    connection:Disconnect()
end)

t.test("pages: side navigation, selecting, a default page, and removal", function()
    local paged
    scope.run(owner, function() paged = ui.Window({ title = "Pages", nav = "side" }) end)
    local first = paged:Page("First", { icon = "home" })
    local second = paged:Page("Second")
    local bottom = paged:Page("Settings", { bottom = true })
    ui.AddSettings(bottom)
    first:Label("on the first page")
    t.eq(paged.page, first)
    local changed
    paged.PageChanged:Connect(function(name) changed = name end)
    click(second.button)
    t.eq(paged.page, second)
    t.eq(changed, "Second")
    paged:SelectPage("First")
    t.eq(paged.page, first)
    paged:RemovePage(first)
    t.eq(paged.page, second)
    t.eq(second.index, 0)
    t.raises(function() paged:SelectPage("Nope") end, "no page named")
    t.raises(function() window:Page("x") end, "has no pages")

    local direct
    scope.run(owner, function() direct = ui.Window({ title = "Tabs", nav = "top" }) end)
    direct:Button("straight in")
    t.eq(direct.pages[1].name, "Main")
end)

t.test("dragging moves a window, resizes it, and resizes the navigation column", function()
    local dragged
    scope.run(owner, function() dragged = ui.Window({ title = "Drag", nav = "side", width = 500, height = 300, x = 200, y = 200 }) end)
    dragged:Page("One")
    ui.Open()
    local function drag(widget, dx, dy)
        fake.mouse.X, fake.mouse.Y = 400, 400
        events.simulate(widget, "OnPressed")
        fake.pressed = true
        fake.mouse.X, fake.mouse.Y = 400 + dx, 400 + dy
        frames(1)
        fake.pressed = false
        frames(1)
    end
    drag(dragged.bar, 30, -20)
    t.eq(dragged.x, 230)
    t.eq(dragged.y, 180)
    drag(dragged.grip_button, 40, 60)
    t.eq(dragged.width, 540)
    t.eq(dragged.height, 360)
    local side = dragged.side_width
    drag(dragged.splitter, 25, 0)
    t.eq(dragged.side_width, side + 25)
    drag(dragged.splitter, -1000, 0)
    t.eq(dragged.side_width, 96, "the column keeps a minimum width")
    drag(dragged.splitter, 5000, 0)
    t.eq(dragged.side_width, dragged.width - 220, "the page keeps a minimum width")
    dragged:SetNavWidth(150)
    t.eq(dragged.nav_width, 157)
    t.raises(function() window:SetNavWidth(100) end, "no side navigation")
    ui.Close()
    dragged:Destroy()
end)

t.test("the interface scale applies to windows and never drops below what the screen can show sharply", function()
    t.eq(ui.GetScale(), 1)
    t.eq(ui.SetScale(2), 2)
    t.eq(window.slot:GetSize().X, 640, "a 320 wide window takes 640 at double scale")
    ui.Open()
    fake.mouse.X, fake.mouse.Y = 0, 0
    events.simulate(window.grip_button, "OnPressed")
    fake.pressed = true
    fake.mouse.X, fake.mouse.Y = 40, 40
    frames(1)
    fake.pressed = false
    frames(1)
    ui.Close()
    t.eq(window.width, 340, "a 40 pixel drag at double scale grows the window by 20")
    window:SetSize(320, 400)
    t.eq(ui.SetScale(0.1), 0.9, "on a screen with no scaling of its own the floor is 0.9")
    fake.screen_scale = 2
    frames(120)
    t.eq(ui.GetScale(), 0.7, "a high-resolution screen allows a smaller interface")
    fake.screen_scale = 0.5
    frames(120)
    t.eq(ui.GetScale(), 1.8, "a low-resolution screen forces a larger one")
    t.raises(function() ui.SetScale("big") end, "expects a number")
    fake.screen_scale = 1
    frames(120)
    ui.SetScale(1)
end)

t.test("a minimised window shows a plus to expand it", function()
    click(window.minimize_button)
    t.ok(window:IsMinimized())
    click(window.minimize_button)
    t.ok(not window:IsMinimized())
end)

t.test("overlays and notifications", function()
    local hud
    scope.run(owner, function() hud = ui.Overlay({ anchor = "bottom-left", title = "HUD" }) end)
    hud:Field("Map", "Olympus")
    hud:Progress("Health", 0.5)
    t.eq(ui.stats().overlays, 1)
    hud:SetVisible(false)
    t.ok(not hud:IsVisible())
    hud:SetAnchor("top")
    t.raises(function() ui.Overlay({ anchor = "middle" }) end, "unknown anchor")
end)

t.test("notifications: repeats, progress, limit, corner, expiry and closing", function()
    ui.Notifications.Clear()
    local first = ui.Notify("Saved.", { title = "Demo", kind = "good" })
    t.eq(ui.Notifications.Count(), 1)
    t.eq(ui.Notify("Saved.", { title = "Demo", kind = "good" }), first, "the same message does not stack")
    t.eq(first.count, 2)
    local task = ui.Notify("Working", { seconds = 0, progress = 0 })
    task:SetProgress(0.5)
    task:SetText("Half way")
    t.eq(task.progress, 0.5)
    ui.Notifications.SetLimit(3)
    ui.Notify("a")
    ui.Notify("b")
    t.eq(ui.Notifications.Count(), 3, "the oldest makes room")
    t.ok(first.closed)
    local brief = ui.Notify("gone soon", { seconds = 0.01 })
    local started = os.clock()
    while os.clock() - started < 0.03 do end
    frames(1)
    t.ok(brief.closed, "a notification closes when its time is up")
    t.ok(not task.closed, "one showing progress stays until closed")
    task:Close()
    t.raises(function() ui.Notify("x", { kind = "loud" }) end, "kind")
    ui.Notifications.SetCorner("top-left")
    t.eq(ui.Notifications.Count(), 0)
    t.raises(function() ui.Notifications.SetCorner("middle") end, "unknown corner")
    ui.Notifications.SetCorner("bottom-right")
    ui.Notifications.SetLimit(5)
end)

t.test("theme overrides accept colour strings and reject unknown settings", function()
    local theme = ui.Theme()
    local original = theme.accent
    ui.SetTheme({ accent = "#FF8800" })
    t.ok(theme.accent.R > 0.9 and theme.accent.B < 0.01)
    ui.SetTheme({ accent = original })
    t.raises(function() ui.SetTheme({ no_such_setting = 1 }) end, "unknown theme setting")
end)

t.test("icons: every bundled name works, a wrong one suggests the right one, and a mod can add its own", function()
    t.ok(#ui.Icons.Names() > 1500)
    t.ok(ui.Icons.Has("shield"))
    t.eq(ui.Icons.Find("arrow-down-to", 10)[1], "arrow-down-to-dot")
    local icon_window
    scope.run(owner, function() icon_window = ui.Window({ title = "Icons", icon = "sparkles" }) end)
    icon_window:Button("Save", nil, { icon = "save" })
    icon_window:Button(nil, nil, { icon = "trash-2" })
    icon_window:Icon("map", { size = 32 }):Set("map-pin")
    ui.Notify("with its own icon", { icon = "bell" })
    local err = t.raises(function() icon_window:Icon("sheild") end, "there is no icon named 'sheild'")
    t.ok(tostring(err):find("shield", 1, true), "the message suggests the nearest name: " .. tostring(err))
    ui.Icons.Register("my-logo", "C:/mods/Mine/logo.png")
    t.ok(ui.Icons.Has("my-logo"))
    icon_window:Icon("my-logo")
    t.raises(function() ui.Icons.Register("", "x.png") end, "needs a name")
    icon_window:Destroy()
    ui.Notifications.Clear()
end)

t.test("the accent colour applies to controls that already exist", function()
    local before = fake.calls
    local accent_window
    scope.run(owner, function() accent_window = ui.Window({ title = "Accent" }) end)
    accent_window:Button("Go", nil, { primary = true })
    accent_window:Toggle("Flag", true)
    accent_window:Slider("Amount", {})
    accent_window:Progress("Load", 0.5)
    local count = 0
    local style = Wax.import("gui.style")
    local real_follow_refresh = style.refresh
    style.refresh = function()
        count = count + 1
        return real_follow_refresh()
    end
    ui.SetTheme({ accent = "#FF8800", accent_hover = "#FFAA33" })
    t.eq(count, 1)
    t.ok(ui.Theme().accent.R > 0.9)
    ui.ResetTheme()
    t.eq(count, 2)
    t.ok(ui.Theme().accent.B > 0.9, "reset restores the default accent in the same theme table")
    style.refresh = real_follow_refresh
    ui.Theme().animation = 0
    accent_window:Destroy()
end)

t.test("the debug panel builds, lists mods, shows the log and takes pages from mods", function()
    local panel = Wax.import("gui.debug")
    panel.start()
    ui.SetPreview(true)
    log.write("warn", "test", "something to show")
    local started = os.clock()
    while os.clock() - started < 0.6 do end
    panel.step()
    local mod_scope = scope.new("some-mod")
    local page
    scope.run(mod_scope, function() page = panel.Page("Mine") end)
    page:Toggle("Option", false)
    local pages_with = #panel.Window().pages
    mod_scope:destroy()
    t.eq(#panel.Window().pages, pages_with - 1)
    ui.SetPreview(false)
    panel.stop()
end)

t.test("the Mods page has the updater's switch and button, and offers an update on a mod's card", function()
    local panel = Wax.import("gui.debug")
    t.eq(panel.updates, nil, "without the updater the page has none of this")
    local state = { available = {}, installing = {}, checking = false, last = 0, auto = true }
    local asked, put, switched = 0, {}, {}
    Wax.update = {
        state = function() return state end,
        set_auto = function(on)
            switched[#switched + 1] = on
            state.auto = on
        end,
        check_now = function()
            asked = asked + 1
            if asked == 1 then return true end
            return false, 42
        end,
        install = function(id)
            put[#put + 1] = id
            return true
        end,
    }
    local function text_of(control)
        local last = fake.last(control.widget, "SetText")
        return last and rawget(last[2], "__text") or nil
    end
    local function refresh()
        local started = os.clock()
        while os.clock() - started < 0.55 do end
        panel.step()
    end
    local before = fake.mark()
    panel.start()
    ui.SetPreview(true)
    local shown = panel.updates
    t.ok(shown and shown.switch and shown.check and shown.line and shown.note, "the controls are there")
    t.eq(shown.switch:Get(), true)
    t.eq(text_of(shown.line), "Not checked yet.")
    refresh()
    t.eq(next(shown.buttons), nil, "no update button while nothing newer is known")

    click(shown.switch.source)
    frames(1)
    t.eq(switched[1], false, "the switch tells the updater")
    state.auto = true
    refresh()
    t.eq(shown.switch:Get(), true, "and follows it when the setting is changed elsewhere")

    click(shown.check.source)
    frames(1)
    t.eq(asked, 1)
    t.eq(text_of(shown.line), "Checking ...")
    click(shown.check.source)
    frames(1)
    t.eq(text_of(shown.line), "Try again in 42 seconds.", "asked again too soon, it says how long to wait")

    shown.hold = 0
    state.available.Hello, state.last = "0.2.0", os.time() - 600
    refresh()
    t.eq(text_of(shown.line), "Last checked 10 minutes ago.")
    t.ok(shown.buttons.Hello, "a mod with a newer version gets a button on its card")
    click(shown.buttons.Hello.source)
    frames(1)
    t.eq(put[1], "Hello")

    state.installing.Hello = true
    refresh()
    t.eq(shown.buttons.Hello, nil, "while the update is being put in there is no button")
    t.eq(text_of(shown.line), "Updating ...")

    state.available, state.installing, state.problem = {}, {}, "Updates could not be checked."
    refresh()
    t.eq(text_of(shown.note), "Updates could not be checked.")
    state.checking = true
    refresh()
    t.eq(text_of(shown.line), "Checking ...")
    t.eq(fake.count(shown.check.widget, "SetIsEnabled"), 0)
    state.stopped = true
    refresh()
    t.eq(fake.last(shown.check.widget, "SetIsEnabled")[2], false, "without the helper the button is disabled")
    t.eq(fake.last(shown.switch.widget, "SetIsEnabled")[2], false, "and so is the switch")

    ui.SetPreview(false)
    panel.stop()
    t.eq(panel.updates, nil)
    Wax.update = nil
    -- everything the page made is freed with the window, and nothing of it is used afterwards
    fake.free(before, fake.mark())
    local touches = fake.dead_touches
    frames(3)
    t.eq(fake.dead_touches, touches, fake.dead_where)
end)

t.test("the Mods page has one switch for looking for updates: off, the two controls under it are greyed", function()
    local panel = Wax.import("gui.debug")
    local state = { available = {}, installing = {}, checking = false, last = 0, look = true, auto = true }
    local looked = {}
    Wax.update = {
        state = function() return state end,
        set_auto = function(on) state.auto = on end,
        set_looking = function(on)
            looked[#looked + 1] = on
            state.look = on
        end,
        check_now = function() return true end,
        install = function() return true end,
    }
    local function text_of(control)
        local last = fake.last(control.widget, "SetText")
        return last and rawget(last[2], "__text") or nil
    end
    local function refresh()
        local started = os.clock()
        while os.clock() - started < 0.55 do end
        panel.step()
    end
    panel.start()
    ui.SetPreview(true)
    local shown = panel.updates
    t.ok(shown.look, "the switch is there")
    t.eq(shown.look:Get(), true, "and on, as the setting is")
    refresh()
    t.eq(fake.count(shown.switch.widget, "SetIsEnabled"), 0, "while it is on nothing is greyed")
    t.eq(text_of(shown.line), "Not checked yet.")

    click(shown.look.source)
    frames(1)
    t.eq(looked[1], false, "the switch tells the updater")
    refresh()
    t.eq(fake.last(shown.switch.widget, "SetIsEnabled")[2], false, "Auto Update is greyed")
    t.eq(fake.last(shown.check.widget, "SetIsEnabled")[2], false, "and so is Check now")
    t.eq(fake.count(shown.look.widget, "SetIsEnabled"), 0, "the switch itself stays in reach")
    t.eq(text_of(shown.line), "Not looking for updates. Nothing is asked of the catalogue.")

    state.look = true
    refresh()
    t.eq(shown.look:Get(), true, "it follows the setting when that is changed elsewhere")
    t.eq(fake.last(shown.switch.widget, "SetIsEnabled")[2], true)
    t.eq(fake.last(shown.check.widget, "SetIsEnabled")[2], true)
    t.eq(text_of(shown.line), "Not checked yet.")

    -- without the helper the switch does nothing either
    state.stopped = true
    refresh()
    t.eq(fake.last(shown.look.widget, "SetIsEnabled")[2], false)

    ui.SetPreview(false)
    panel.stop()
    Wax.update = nil

    -- a page that starts with the setting off shows it off, with the rest greyed from the first look
    state = { available = {}, installing = {}, checking = false, last = 0, look = false, auto = true }
    Wax.update = { state = function() return state end, set_auto = function() end, set_looking = function() end,
        check_now = function() return false end, install = function() return false end }
    panel.start()
    ui.SetPreview(true)
    shown = panel.updates
    t.eq(shown.look:Get(), false)
    refresh()
    t.eq(fake.last(shown.switch.widget, "SetIsEnabled")[2], false)
    t.eq(fake.last(shown.check.widget, "SetIsEnabled")[2], false)
    ui.SetPreview(false)
    panel.stop()
    Wax.update = nil
end)

t.test("destroying a group destroys what is inside it, however deep", function()
    local host
    scope.run(owner, function() host = ui.Window({ title = "Groups", nav = "side" }) end)
    local page = host:Page("One")
    local handlers_before = ui.stats().handlers
    local section = page:Section("Outer")
    local label = section:Label("some text that wraps")
    local row = section:Row()
    local inner_button = row:Button("Inner", function() end)
    local grid = section:Flow({ cell = 40 })
    local cell = grid:Button(nil, function() end, { icon = "map" })
    local nested = section:Section("Nested")
    local deep = nested:Toggle("Deep", true)
    t.ok(ui.stats().handlers > handlers_before)
    section.control:Destroy()
    for _, control in ipairs({ label, inner_button, cell, deep, row.control, grid.control, nested.control }) do
        t.ok(control.destroyed, "a control inside the destroyed section is destroyed too")
    end
    t.eq(ui.stats().handlers, handlers_before, "and its handlers are gone")
    host:SetSize(700, 400)          -- re-wraps text: must not reach anything that was destroyed
    local extra = host:Page("Extra")
    local on_extra = extra:Button("On the page", function() end)
    local with_extra = ui.stats().handlers
    host:RemovePage(extra)
    t.ok(on_extra.destroyed, "removing a page destroys its controls")
    t.ok(ui.stats().handlers < with_extra)
    host:Destroy()
end)

t.test("a status bar shows text, activity, progress and a note", function()
    local status = window:StatusBar("Ready")
    t.eq(window:StatusBar(), status, "a window has one status bar")
    status:Busy("Working")
    status:Progress(0.4)
    status:Right("v1")
    status:Set("Done", { kind = "good", icon = "check" })
    status:Progress(nil)
    status:Clear()
    click(window.minimize_button)
    click(window.minimize_button)
end)

t.test("a theme switch recolours what is on screen in place: nothing is rebuilt and no mod reloads", function()
    local style = Wax.import("gui.style")
    local themed
    local themed_scope = scope.new("themed")
    scope.run(themed_scope, function() themed = ui.Window({ title = "Themed", nav = "side" }) end)
    local page = themed:Page("One", { icon = "map" })
    local label = page:Label("some text")
    local go = page:Button("Go", function() seen.themed = true end)
    local flag = page:Toggle("Flag", true)
    local pick = page:Dropdown("Pick", { "A", "B" }, "A")
    local status = themed:StatusBar("Ready")
    status:Set("Fine", { kind = "good", icon = "check" })
    ui.Open()
    local reloads_before = #reloads
    local text_red = style.theme.text.R
    local label_calls = fake.count(label.widget, "SetColorAndOpacity")
    local brush_writes = fake.writes(go.widget.WidgetStyle.Normal)
    ui.SetTheme("Daylight")
    frames(3)
    t.eq(ui.ThemeName(), "Daylight")
    t.ok(ui.IsOpen(), "the menu stays open")
    t.eq(#reloads, reloads_before, "no mod is reloaded for a theme")
    t.ok(not themed.destroyed and not go.destroyed, "the same window and controls are still there")
    t.ok(style.theme.text.R ~= text_red, "the theme's own colour tables hold the new colours")
    t.eq(fake.count(label.widget, "SetColorAndOpacity"), label_calls + 1, "text that was on screen got its colour again")
    t.eq(fake.last(label.widget, "SetColorAndOpacity")[2].SpecifiedColor.R, style.theme.text.R)
    t.ok(fake.writes(go.widget.WidgetStyle.Normal) > brush_writes, "and so did a button's background")
    click(go.source)
    frames(1)
    t.ok(seen.themed, "controls keep working after the switch")
    -- a colour set by hand survives a theme change; one taken from the theme follows it
    label:SetColor("#FF0000")
    ui.SetTheme("Dune")
    t.ok(fake.last(label.widget, "SetColorAndOpacity")[2].SpecifiedColor.R > 0.9)
    label:SetColor(ui.Theme().good)
    local good = ui.Theme().good.G
    ui.SetTheme("Daylight")
    t.ok(ui.Theme().good.G ~= good)
    t.eq(fake.last(label.widget, "SetColorAndOpacity")[2].SpecifiedColor.G, ui.Theme().good.G)
    t.eq(#ui.Themes(), 13)
    ui.AddTheme("Mine", { window = "#101010", accent = "#FF00FF" })
    ui.SetTheme("Mine")
    t.ok(ui.Theme().accent.R > 0.9 and ui.Theme().accent.G < 0.1)
    t.raises(function() ui.SetTheme("Nope") end, "no theme named")
    t.raises(function() ui.AddTheme("Bad", { nonsense = "#000000" }) end, "unknown theme setting")
    ui.SetTheme("Midnight")
    themed_scope:destroy()
    t.raises(function() go:SetVisible(true) end, "no longer exists")
    t.raises(function() flag:Set(false) end, "no longer exists")
    t.raises(function() themed:Label("late") end, "no longer exists")
    t.ok(not themed:IsVisible())
    t.ok(pick.destroyed)
    ui.Close()
end)

t.test("nothing that was destroyed or replaced is ever touched again, whatever happens afterwards", function()
    local style = Wax.import("gui.style")
    local host
    local host_scope = scope.new("lifetimes")
    scope.run(host_scope, function() host = ui.Window({ title = "Lifetimes", nav = "side" }) end)
    local page = host:Page("One")
    page:Label("stays")
    local status = host:StatusBar("Ready")
    local spans = {}
    local function span(make)
        local from = fake.mark()
        local made = make()
        spans[#spans + 1] = { from, fake.mark() }
        return made
    end
    -- a section with everything in it, destroyed
    local doomed = span(function()
        local section = page:Section("Doomed")
        section:Label("text")
        section:Field("Name", "value"):SetColor(ui.Theme().good)
        section:Toggle("Flag", true)
        section:Slider("Amount", {})
        section:Input("Name", {})
        section:Dropdown("Pick", { "A", "B", "C" }, "B")
        section:Progress("Load", 0.5)
        section:Keybind("Key", "F5")
        section:Console({ height = 60 }):SetLines({ { "one" }, { "two", ui.Theme().bad } })
        section:Flow({ cell = 40 }):Button(nil, nil, { icon = "map" })
        section:Row():Button("In a row")
        return section
    end)
    doomed.control:Destroy()
    -- a page with controls, removed
    local gone_page = span(function()
        local extra = host:Page("Extra", { icon = "map" })
        extra:Button("On it")
        return extra
    end)
    host:RemovePage(gone_page)
    -- icons that change keep their widget
    local picture = page:Icon("map")
    picture:Set("user")
    status:Set("One", { kind = "good", icon = "check" })
    status:Set("Two", { kind = "bad", icon = "x" })
    -- a grid with its reused cells, destroyed
    local gone_grid = span(function()
        local grid = page:Grid({ cell = 40, height = 120, items = { "map", "user", "home" },
            make = function(cell) return cell:Button(nil, nil, { icon = "circle" }) end,
            show = function(button, name) button:SetIcon(name) end })
        ui.Open()
        frames(3)
        ui.Close()
        return grid
    end)
    gone_grid:Destroy()
    -- a whole window, an overlay and a notification
    local other = span(function()
        local made
        scope.run(host_scope, function() made = ui.Window({ title = "Other" }) end)
        made:Button("Go")
        made:StatusBar("x")
        return made
    end)
    other:Destroy()
    local hud = span(function()
        local made
        scope.run(host_scope, function() made = ui.Overlay({ title = "Hud" }) end)
        made:Field("Speed", 1)
        return made
    end)
    hud:Destroy()
    local note = span(function() return ui.Notify("going away", { title = "Soon" }) end)
    note:Close()
    frames(2)
    -- a builder that fails half way
    local controls_before = #host.controls
    span(function() pcall(function() page:Button("Bad icon", nil, { icon = "definitely-not-an-icon" }) end) end)
    t.eq(#host.controls, controls_before, "a builder that fails registers no control")

    for _, range in ipairs(spans) do fake.free(range[1], range[2]) end
    fake.dead_touches = 0
    ui.Open()
    for _, name in ipairs({ "Dune", "Daylight", "Midnight" }) do ui.SetTheme(name) end
    ui.SetTheme({ accent = "#00FF00" })
    ui.ResetTheme()
    host:SetSize(700, 500)
    host:SetNavWidth(200)
    ui.SetScale(1.25)
    ui.SetScale(1)
    frames(4)
    ui.Close()
    t.ok(fake.dead_touches == 0, "touched something that was freed: " .. tostring(fake.dead_last))
    ui.Theme().animation = 0
    local painted = style.painted()
    host_scope:destroy()
    ui.SetTheme("Dune")
    ui.SetTheme("Midnight")
    t.ok(style.painted() < painted, "what a destroyed window painted is forgotten")
    t.ok(fake.dead_touches == 0, "touched something that was freed: " .. tostring(fake.dead_last))
end)

t.test("a page asks for more while its end is in view, scrolled or not", function()
    local host
    local host_scope = scope.new("more")
    scope.run(host_scope, function() host = ui.Window({ title = "More", nav = "side" }) end)
    local first, second = host:Page("First"), host:Page("Second")
    local asked = { first = 0, second = 0 }
    first.NearEnd:Connect(function() asked.first = asked.first + 1 end)
    second.NearEnd:Connect(function() asked.second = asked.second + 1 end)
    ui.Open()
    fake.scroll_end, fake.scroll_offset = 1000, 0
    frames(45)
    t.eq(asked.first, 0, "a long page that is at the top asks for nothing")
    fake.scroll_end = 0             -- everything fits: there is nothing to scroll
    frames(45)
    t.ok(asked.first > 0, "a page that is not full asks for more by itself")
    t.eq(asked.second, 0, "only the page being shown asks")
    fake.scroll_end = 1000
    ui.Close()
    host_scope:destroy()
end)

t.test("a grid shows any number of items with a handful of cells, reused as it scrolls", function()
    local host
    local host_scope = scope.new("grid")
    scope.run(host_scope, function() host = ui.Window({ title = "Grid", nav = "side", width = 520, height = 400 }) end)
    local page = host:Page("Many", { scroll = false })
    page:Title("Many")
    local items, made, shown = {}, 0, {}
    for index = 1, 5000 do items[index] = "item " .. index end
    local grid = page:Grid({ cell = 40,
        make = function(cell)
            made = made + 1
            return cell:Button("x", function() end)
        end,
        show = function(button, item, index)
            button.item = item
            shown[index] = item
        end })
    t.eq(grid:Count(), 0)
    grid:SetItems(items)
    ui.Open()
    fake.scroll_end, fake.scroll_fraction = 1000000, 0
    frames(30)
    t.ok(made > 0 and made < 400, "a few cells for 5000 items, not 5000: " .. made)
    t.eq(shown[1], "item 1")
    local made_at_top = made
    fake.scroll_fraction = 0.5
    frames(30)
    t.eq(made, made_at_top, "scrolling reuses the cells that exist")
    t.ok(shown[2500] ~= nil or shown[2496] ~= nil or shown[2504] ~= nil, "the middle of the list is being shown")
    grid:SetItems({ "only" })
    fake.scroll_fraction = 0
    shown = {}
    frames(5)
    t.eq(shown[1], "only")
    t.eq(grid:Count(), 1)
    t.raises(function() page:Grid({}) end, "a grid needs make")
    local handlers = ui.stats().handlers
    grid:Destroy()
    t.ok(ui.stats().handlers < handlers, "destroying the grid destroys the controls in its cells")
    fake.scroll_end, fake.scroll_fraction = 1000, 0
    ui.Close()
    host_scope:destroy()
end)

t.test("an open dropdown closes when the user does anything elsewhere", function()
    local host
    local host_scope = scope.new("away")
    scope.run(host_scope, function() host = ui.Window({ title = "Away" }) end)
    local pick = host:Dropdown("Pick", { "A", "B", "C" }, "B")
    local other = host:Button("Other", function() end)
    ui.Open()
    click(pick.source)
    t.ok(pick.parts.open)
    click(other.source)
    t.ok(not pick.parts.open, "pressing another control closes the list")
    t.eq(pick:Get(), "B", "and the choice stays as it was")
    click(pick.source)
    events.simulate(host.backdrop, "OnPressed")
    t.ok(not pick.parts.open, "so does a click on empty space in the window")
    click(pick.source)
    Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
    fake.key_pressed, fake.hovered = "LeftMouseButton", true
    frames(1)
    t.ok(pick.parts.open, "a click the game saw while the mouse is on the list is not a click away")
    fake.hovered = false
    frames(1)
    t.ok(not pick.parts.open, "a click out in the game is")
    fake.key_pressed, Wax.game = nil, nil
    click(pick.source)
    ui.Close()
    t.ok(not pick.parts.open, "closing the menu closes it too")
    host_scope:destroy()
end)

t.test("a window with tabs along the top is never narrower than its tabs need", function()
    local host
    local host_scope = scope.new("tabs")
    scope.run(host_scope, function()
        host = ui.Window({ title = "Tabs", nav = "top", width = 260, height = 400 })
        for _, name in ipairs({ "One", "Two", "Three" }) do host:Page(name, { icon = "home" }) end
    end)
    -- the fake engine says every tab wants 120: three of them, their gaps and the margin
    t.eq(host.min_width, 392)
    t.eq(host.width, 392, "it grew to fit the tabs it was given")
    host:SetSize(100, 100)
    t.eq(host.width, 392, "and cannot be made narrower")
    t.eq(host.height, 200, "a tabbed window keeps room for a row under its tabs")
    host:SetSize(700, 400)
    t.eq(host.width, 700)
    host:Page("Four", { icon = "home" })
    t.eq(host.min_width, 516, "another tab needs more room")
    host_scope:destroy()
end)

t.test("what a grid cell sets up belongs to whoever made the grid", function()
    local host
    local host_scope = scope.new("grid-owner")
    local owners = {}
    scope.run(host_scope, function()
        host = ui.Window({ title = "Owned" })
        host:Grid({ items = { 1, 2, 3 }, height = 120,
            make = function(cell)
                owners[#owners + 1] = scope.current()
                return cell:Button("x")
            end,
            show = function() owners.show = scope.current() end })
    end)
    ui.Open()
    frames(2)
    t.ok(#owners > 0, "cells were made")
    t.ok(owners[1] == host_scope, "a cell is made as its grid's maker")
    t.ok(owners.show == host_scope, "and shown as it")
    t.ok(scope.current() == nil, "the frame loop is left with no owner")
    host_scope:destroy()
end)

t.test("a colour control opens a panel under itself: a shade box that follows the mouse, a hue bar, and the colour as text", function()
    local host, color
    local host_scope = scope.new("colour")
    local got, released = {}, 0
    scope.run(host_scope, function()
        host = ui.Window({ title = "Colour", width = 420 })
        color = host:Color("Outline", "#ff0000", function(value) got[#got + 1] = value end)
    end)
    local other = host:Button("Other", function() end)
    t.eq(color:Get(), "#ff0000")
    color:Set("#00ff00")
    t.eq(color:Get(), "#00ff00")
    t.raises(function() color:Set("green") end, "#rrggbb")
    t.raises(function() host:Color("Bad", "red") end, "#rrggbb")
    color.Released:Connect(function() released = released + 1 end)
    ui.Open()
    frames(1)
    t.eq(#got, 0, "Set does not report a change")

    click(color.source)
    local parts = color.parts
    t.ok(parts.open, "the panel is showing")
    local scale = Wax.import("gui.style").scale
    -- pressing the left end of the top row: no colour at all, full brightness
    local top = parts.strips[1]
    top:SetValue(0)
    fake.mouse.X, fake.mouse.Y = 500, 300
    fake.hovered, fake.captured = true, top
    frames(1)
    t.eq(color:Get(), "#ffffff", "the top left corner is white")
    -- dragged to the right edge and half way down: the hue it had, half as bright
    top:SetValue(1)
    fake.mouse.Y = 300 + 60 * scale
    frames(1)
    t.eq(color:Get(), "#008000", "the hue is kept while the shade changes")
    fake.mouse.Y = 300 + 500 * scale
    frames(1)
    t.eq(color:Get(), "#000000", "below the box is the bottom of the box")
    t.eq(released, 0)
    fake.captured = nil
    frames(1)
    t.eq(released, 1, "letting go is reported once")
    fake.hovered = false

    events.simulate(parts.hue, "OnValueChanged", 0)
    t.eq(color:Get(), "#ff0000", "picking a hue while the colour is black gives that hue")
    t.eq(got[#got], "#ff0000")
    events.simulate(parts.hue, "OnMouseCaptureEnd")
    t.eq(released, 2)
    events.simulate(parts.field, "OnTextCommitted", "#336699")
    frames(1)
    t.eq(color:Get(), "#336699", "a colour that was typed or pasted")
    events.simulate(parts.field, "OnTextCommitted", "nonsense")
    t.eq(color:Get(), "#336699", "text that is not a colour changes nothing")
    click(parts.copy)
    t.ok(parts.open, "copying leaves the panel open")

    click(other.source)
    t.ok(not parts.open, "pressing another control closes the panel")
    click(color.source)
    t.ok(parts.open)
    click(color.source)
    t.ok(not parts.open, "pressing the selector again closes it")
    click(color.source)
    ui.Close()
    t.ok(not parts.open, "closing the menu closes it too")
    host_scope:destroy()
    frames(2)
    t.raises(function() color:Get() end, "no longer exists")
end)

t.test("a switch can be given another caption and be set without sliding", function()
    local host
    local host_scope = scope.new("caption")
    scope.run(host_scope, function() host = ui.Window({ title = "Caption" }) end)
    local flag = host:Toggle("First", false)
    flag:SetCaption("Second")
    flag:Set(true, true)
    t.eq(flag:Get(), true)
    host_scope:destroy()
end)

t.test("the log can be copied: the console hands back exactly the lines it shows", function()
    local host
    local host_scope = scope.new("copy")
    scope.run(host_scope, function() host = ui.Window({ title = "Copy" }) end)
    local console = host:Console({ height = 80, max = 3 })
    console:SetLines({ { "one" }, { "two", ui.Theme().bad }, { "three", ui.Theme().bad }, { "four" } })
    t.eq(console:GetText(), "two\nthree\nfour", "only the lines within its limit")
    ui.Copy("some text")
    t.raises(function() ui:Copy("x") end, "with a dot")
    host_scope:destroy()
end)

t.test("a text box tells Enter from clicking away, and a button's icon can turn", function()
    local host
    local host_scope = scope.new("enter")
    scope.run(host_scope, function() host = ui.Window({ title = "Enter" }) end)
    local box = host:Input("Command", {})
    local entered = {}
    box.Entered:Connect(function(text) entered[#entered + 1] = text end)
    events.simulate(box.source, "OnTextCommitted", "one")       -- the box lost the keyboard: one report
    frames(1)
    t.eq(#entered, 0, "clicking away is not Enter")
    local started = os.clock()
    while os.clock() - started < 0.25 do end
    events.simulate(box.source, "OnTextCommitted", "two")       -- Enter: the commit, then the box letting go
    events.simulate(box.source, "OnTextCommitted", "two")
    frames(1)
    t.eq(#entered, 1)
    t.eq(entered[1], "two")
    box:Focus()
    local spinner = host:Button(nil, function() end, { icon = "refresh-cw", spin = true })
    click(spinner.source)
    spinner:Spin()
    spinner:SetIcon("check")
    t.raises(function() host:Button("Plain"):SetIcon("check") end, "without an icon")
    host_scope:destroy()
end)

t.test("the command bar suggests one name as you type, and Tab takes it", function()
    local panel = Wax.import("gui.debug")
    -- the greyed preview is the rest of one name, never a list
    t.eq(panel.preview("pri"), "nt")
    t.eq(panel.preview("p"), "rint", "of everything starting with p, the everyday one")
    t.eq(panel.preview("print"), "", "nothing left to add")
    t.eq(panel.preview("math.ma"), "x", "nothing everyday fits: the shortest")
    t.eq(panel.preview("math."), "", "nothing until a letter is typed")
    t.eq(panel.preview("x = "), "")
    t.eq(panel.preview(""), "")
    t.eq(panel.preview("no_such_table.fie"), "")
    t.eq(panel.preview("STR"), "", "capitals that do not match are not continued on screen")
    -- Tab writes the suggestion; again straight away, the next name that fits, and round again
    t.eq((panel.tab("pri")), "print")
    t.eq((panel.tab("local x = string.for")), "local x = string.format", "only the last name is touched")
    t.eq((panel.tab("STR")), "string", "Tab forgives the capitals")
    t.eq((panel.tab("math.ma")), "math.max")
    t.eq((panel.tab("math.max")), "math.maxinteger")
    t.eq((panel.tab("math.maxinteger")), "math.max")
    t.eq((panel.tab("")), "")
    local same, there = panel.tab("math.")
    t.eq(same, "math.")
    t.ok(#there > 10, "after a dot with nothing typed it hands back what is there, to list")
    -- a name used in a recent command comes first
    table.insert(panel.history, "pcall(error)")
    t.eq(panel.preview("p"), "call")
    table.remove(panel.history)
    local host
    local host_scope = scope.new("ghost")
    scope.run(host_scope, function() host = ui.Window({ title = "Ghost" }) end)
    local box = host:Input(nil, { mono = true })
    box:SetGhost("nt")
    box:SetGhost("")
    host:Input("Plain", {}):SetGhost("ignored")
    host_scope:destroy()
end)

t.test("while the menu is open the game is kept from acting on input, and gets it back when the menu shuts", function()
    local settings = fake.new_object("WorldSettings")
    fake.world_settings = settings
    Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") }, World = { Raw = fake.new_object("World") } }
    local host_scope = scope.new("block")
    scope.run(host_scope, function() ui.Window({ title = "Block" }) end)
    ui.Open()
    t.eq(fake.count(settings, "EnableInput"), 1, "an input blocker goes on top of the game's own input")
    t.ok(input.blocking())
    t.eq(rawget(settings, "__members").bBlockInput, true)
    frames(2)
    fake.key_pressed = "Escape"
    frames(1)
    fake.key_pressed = nil
    t.ok(not ui.IsOpen(), "Escape shuts the menu")
    t.eq(fake.count(settings, "DisableInput"), 1, "and the game has its input back")
    t.ok(not input.blocking())
    host_scope:destroy()
    Wax.game, fake.world_settings = nil, nil
end)

t.test("a failing builder blames the line that called it", function()
    local host
    local host_scope = scope.new("blame")
    scope.run(host_scope, function() host = ui.Window({ title = "Blame" }) end)
    local section = host:Section("Inside")
    host:Destroy()
    local ok, message = pcall(function() section:Label("late") end)
    t.ok(not ok)
    t.ok(tostring(message):find("gui_test%.lua:%d+: this window no longer exists"), "got: " .. tostring(message))
    host_scope:destroy()
end)

t.test("a dropdown marks the chosen row, and only one list is open in a window at a time", function()
    local host
    local host_scope = scope.new("dropdowns")
    scope.run(host_scope, function() host = ui.Window({ title = "Dropdowns" }) end)
    local first = host:Dropdown("First", { "A", "B", "C" }, "B")
    local long = {}
    for i = 1, 30 do long[i] = "Choice " .. i end
    local second = host:Dropdown("Second", long, "Choice 2")
    click(first.source)
    t.ok(first.parts.open)
    click(second.source)
    t.ok(second.parts.open and not first.parts.open, "opening one closes the other")
    click(second.items["Choice 9"])
    t.eq(second:Get(), "Choice 9")
    t.ok(not second.parts.open)
    click(first.source)
    click(first.source)
    t.ok(not first.parts.open, "a second click on the header closes it")
    first:Set("C")
    t.eq(first:Get(), "C")
    host_scope:destroy()
end)

t.test("destroying the owner removes its windows, overlays and every handler", function()
    owner:destroy()
    local stats = ui.stats()
    t.eq(stats.windows, 0)
    t.eq(stats.overlays, 0)
    t.eq(stats.handlers, 0)
end)

t.test("a grid keeps rows ready on both sides, keeps its cells when the list changes, and can be ready before it shows", function()
    ui.Close()
    local host
    scope.run(scope.new("ready grid"), function() host = ui.Window({ title = "Ready", nav = "side", width = 520, height = 400 }) end)
    local page = host:Page("Ready", { scroll = false })
    local items, made, shown = {}, 0, {}
    for index = 1, 1000 do items[index] = index end
    local grid = page:Grid({ cell = 100000, cell_height = 26, gap = 1, warm = true, view = 270,
        make = function(cell)
            made = made + 1
            return cell:Label("")
        end,
        show = function(_, item, index) shown[index] = item end })
    grid:SetItems(items)
    frames(60)
    t.eq(made, 20, "10 rows that show and 5 spare on each side were made while the menu was closed")
    t.eq(next(shown), nil, "and nothing was shown in them yet")
    ui.Open()
    fake.scroll_end, fake.scroll_fraction = 1000 * 27 - 1 - 270, 0.5
    frames(3)
    local top = math.floor(0.5 * (1000 * 27 - 1) / 27) + 1
    t.eq(shown[top], top, "what is in view is shown")
    t.eq(shown[top - 5], top - 5, "with rows ready above it")
    t.eq(shown[top + 14], top + 14, "and below it")
    t.eq(made, 20, "opening made no cell")
    -- a list that is one shorter, as when something in the world went away
    shown = {}
    table.remove(items)
    grid:SetItems(items, true)
    fake.scroll_end = 999 * 27 - 1 - 270
    frames(3)
    t.eq(made, 20, "a list of another length uses the same cells")
    t.eq(shown[top], top, "and shows the same rows in them")
    fake.scroll_end, fake.scroll_fraction = nil, nil
    host:Destroy()
end)

t.test("a see-through button draws nothing behind it when it is switched off", function()
    local window = ui.Window({ title = "Switched off" })
    local flag = window:Toggle("Flag", false)
    local go = window:Button("Go", function() end)
    flag:SetEnabled(false)
    t.eq(flag.source.WidgetStyle.Disabled.TintColor.SpecifiedColor.A, 0, "the switch has no block behind it")
    t.ok(go.widget.WidgetStyle.Disabled.TintColor.SpecifiedColor.A > 0, "an ordinary button keeps its flat look")
    window:Destroy()
end)

t.test("text is cut to a width from its start or its end, and text that fits is left alone", function()
    local kit = Wax.import("gui.kit")
    t.eq(kit.text_width("abcd", 10, "mono"), 32, "every letter of the fixed-width font is 0.8 of the size")
    t.ok(kit.text_width("illi") < kit.text_width("mwmw"), "narrow letters take less than wide ones")
    t.eq(kit.text_width("abc", 22), kit.text_width("abc", 11) * 2)
    local text, cut = kit.shorten("Hello", 500)
    t.eq(text, "Hello")
    t.eq(cut, false)
    text, cut = kit.shorten("game.Character.Mesh", 80, 10, "mono")
    t.eq(text, "game.Ch...", "ten letters of 8 fit in 80")
    t.eq(cut, true)
    t.eq(kit.shorten("game.Character.Mesh", 80, 10, "mono", true), "...er.Mesh", "the end is kept when asked")
    t.eq(kit.shorten("one two three", 8 * 7, 10, "mono"), "one...", "no space is left before the dots")
    t.eq(kit.shorten("abc", 2), "", "with no room for the dots there is nothing")
    local long = ("BP_IcarusPlayerCharacter_C_"):rep(3)
    local short = kit.shorten(long, 150)
    t.ok(short:sub(-3) == "..." and kit.text_width(short) <= 150, short)
    t.eq(kit.shorten("héllo wörld", 8 * 8, 10, "mono"), "héllo...", "a letter outside ASCII is one letter and is never split")
end)

t.test("a dropdown's header is one line: a choice too long for it is cut short there, and is whole again when there is room", function()
    local kit = Wax.import("gui.kit")
    local host = ui.Window({ title = "Headers", width = 320, height = 300 })
    local long = "Within 250 metres of where you stand"
    local row = host:Row()
    local first = row:Dropdown(nil, { "Actors", "Creatures" }, "Actors")
    local second = row:Dropdown(nil, { "Any", long }, long)
    local function header(control) return fake.last(control.parts.label, "SetText")[2]:ToString() end
    t.eq(fake.count(second.parts.label, "SetAutoWrapText"), 0, "it is never told to wrap")
    t.eq(fake.count(second.parts.label, "SetWrapTextAt"), 0)
    t.eq(header(first), "Actors")
    local cut = header(second)
    t.ok(cut ~= long and cut:sub(-3) == "...", cut)
    t.eq(long:find(cut:sub(1, -4), 1, true), 1, "what is left is the start of the choice")
    -- half of the row each, less the gap, the padding and the arrow
    t.ok(kit.text_width(cut) <= (320 - 26 - 8) / 2 - 43, "it fits the header: " .. cut)
    t.eq(second:Get(), long, "the choice itself is not changed")
    -- one more in the row leaves each a third
    row:Button("Go")
    t.ok(#header(second) < #cut, "less room, less text: " .. header(second))
    host:SetSize(1400, 300)
    t.eq(header(second), long, "with room it is whole")
    host:SetSize(320, 300)
    t.ok(header(second) ~= long)
    click(second.items["Any"])
    frames(2)
    t.eq(header(second), "Any")
    -- on a line of its own it has the whole width, and still one line
    local alone = host:Dropdown(nil, { long .. " and then some more than that" }, nil)
    t.ok(header(alone):sub(-3) == "...", header(alone))
    t.eq(fake.count(alone.parts.label, "SetAutoWrapText"), 0)
    local wide = host:Dropdown(nil, { "Any distance from you" }, nil)
    t.eq(header(wide), "Any distance from you")
    host:Destroy()
end)

t.test("a button can carry a tip: it shows once the mouse has rested on it, and goes with the mouse, a click, the button or the menu", function()
    local controls, tip = Wax.import("gui.controls"), Wax.import("gui.tip")
    local delay = controls.TIP_DELAY
    controls.TIP_DELAY = 0
    local host = ui.Window({ title = "Tips" })
    local before = ui.stats().handlers
    local plain = host:Button(nil, function() end, { icon = "copy" })
    t.eq(ui.stats().handlers, before + 1, "a button without a tip listens for its click and nothing else")
    local copy = host:Button(nil, function() end, { icon = "copy", tip = "Copy as Lua" })
    local function rest(button)
        fake.hover(button.source)
        events.simulate(button.source, "OnHovered")
        frames(2)
    end
    local function leave(button)
        fake.hover(nil)
        events.simulate(button.source, "OnUnhovered")
        frames(1)
    end
    t.eq(tip.showing(), false)
    rest(copy)
    t.eq(select(2, tip.showing()), "Copy as Lua")
    frames(20)
    t.eq(tip.showing(), true, "it stays while the mouse does")
    leave(copy)
    t.eq(tip.showing(), false)
    -- a click takes it away, and it is not back until the mouse comes again
    rest(copy)
    click(copy.source)
    frames(3)
    t.eq(tip.showing(), false)
    leave(copy)
    -- a mouse that only passes over shows nothing
    controls.TIP_DELAY = 30
    rest(copy)
    t.eq(tip.showing(), false)
    leave(copy)
    controls.TIP_DELAY = 0
    frames(3)
    t.eq(tip.showing(), false, "the tip that was waiting was called off")
    -- the text can change, and a button made without one can be given one
    copy:SetTip("Copied")
    rest(copy)
    t.eq(select(2, tip.showing()), "Copied")
    copy:SetTip("Copy as Lua")
    t.eq(tip.showing(), false, "another text is shown the next time the mouse comes")
    leave(copy)
    plain:SetTip({ title = "Plain", lines = { "with a second line" } })
    rest(plain)
    t.eq(select(2, tip.showing()), "Plain")
    plain:SetTip(nil)
    t.eq(tip.showing(), false)
    leave(plain)
    rest(plain)
    t.eq(tip.showing(), false, "no text, no tip")
    leave(plain)
    -- the mouse is gone and nobody said so
    rest(copy)
    t.eq(tip.showing(), true)
    fake.hover(nil)
    frames(1)
    t.eq(tip.showing(), false)
    events.simulate(copy.source, "OnUnhovered")
    -- the menu closes under the mouse
    ui.Open()
    rest(copy)
    t.eq(tip.showing(), true)
    ui.Close()
    t.eq(tip.showing(), false)
    ui.Open()
    -- the button goes away under the mouse: the tip goes too, and the button is not asked anything again
    rest(copy)
    t.eq(tip.showing(), true)
    local hovers = fake.count(copy.source, "IsHovered")
    local widget = copy.source
    copy:Destroy()
    frames(3)
    t.eq(tip.showing(), false)
    t.eq(fake.count(widget, "IsHovered"), hovers, "a destroyed button is not asked whether the mouse is on it")
    fake.hover(nil)
    controls.TIP_DELAY = delay
    host:Destroy()
    t.eq(#guard.errors(), 1, "only the error an earlier test made on purpose")
end)

t.test("a text box made with clear has a cross while it holds text: one press empties it and leaves the keyboard in it", function()
    local host = ui.Window({ title = "Search" })
    local plain = host:Input(nil, { hint = "Plain" })
    t.eq(plain.cross, nil, "a box made without it has no cross")
    t.eq(plain.source.WidgetStyle.Padding.Right, 9)
    local typed = {}
    local box = host:Input(nil, { hint = "Search", clear = true })
    box.Typed:Connect(function(text) typed[#typed + 1] = text end)
    local style = Wax.import("gui.style")
    local function crossed() return fake.last(box.cross_box, "SetVisibility")[2] == style.Visibility.Visible end
    t.eq(crossed(), false, "an empty box has none")
    t.eq(box.source.WidgetStyle.Padding.Right, 29, "the text stops short of where the cross goes")
    t.eq(box.source.WidgetStyle.Padding.Left, 9, "and starts where it does in any box")
    t.eq(fake.last(box.cross, "SetCursor")[2], style.Cursor.Hand)
    events.simulate(box.source, "OnTextChanged", "wolf")
    t.eq(crossed(), true)
    t.eq(typed[1], "wolf")
    click(box.cross)
    t.eq(crossed(), false)
    t.eq(fake.last(box.source, "SetText")[2]:ToString(), "")
    t.eq(#typed, 2)
    t.eq(typed[2], "", "whoever listens to typing is told the box is empty")
    t.eq(fake.count(box.source, "SetKeyboardFocus"), 1, "typing can go straight on")
    -- an engine that reports the emptying itself is not echoed
    events.simulate(box.source, "OnTextChanged", "deer")
    local real = fake.react.SetText
    fake.react.SetText = function(self, text)
        if rawequal(self, box.source) then events.simulate(box.source, "OnTextChanged", text:ToString()) end
    end
    click(box.cross)
    fake.react.SetText = real
    t.eq(#typed, 4)
    t.eq(typed[4], "", "told once, not twice")
    t.eq(crossed(), false)
    -- text put there by code counts as text
    box:Set("tree")
    t.eq(crossed(), true)
    box:Set("")
    t.eq(crossed(), false)
    local filled = host:Input(nil, { text = "bear", clear = true })
    t.eq(fake.last(filled.cross_box, "SetVisibility")[2], style.Visibility.Visible, "a box that starts with text starts with the cross")
    -- the hint can be changed
    box:SetHint("Search by name")
    t.eq(fake.last(box.source, "SetHintText")[2]:ToString(), "Search by name")
    -- the cross says what it does
    local controls, tip = Wax.import("gui.controls"), Wax.import("gui.tip")
    local delay = controls.TIP_DELAY
    controls.TIP_DELAY = 0
    box:Set("x")
    fake.hover(box.cross)
    events.simulate(box.cross, "OnHovered")
    frames(2)
    t.eq(select(2, tip.showing()), "Clear")
    fake.hover(nil)
    events.simulate(box.cross, "OnUnhovered")
    controls.TIP_DELAY = delay
    host:Destroy()
end)

t.test("a row can be given a least height, so rows with different things in them are equally tall", function()
    local host = ui.Window({ title = "Rows" })
    local plain = host:Row()
    t.eq(fake.count(plain.control.widget, "SetMinDesiredHeight"), 0)
    local tall = host:Row({ height = 36 })
    t.eq(fake.last(tall.control.widget, "SetMinDesiredHeight")[2], 36)
    local inside = tall:Button("Go")
    t.ok(not inside.destroyed)
    tall.control:Destroy()
    t.eq(inside.destroyed, true, "what is in it goes with it")
    host:Destroy()
end)

t.test("a list line made with fit cuts what is too long for it short, and shows the whole of it under the mouse", function()
    local kit, controls, tip = Wax.import("gui.kit"), Wax.import("gui.controls"), Wax.import("gui.tip")
    local host = ui.Window({ title = "Lines", width = 320 })
    local class = "BP_IcarusPlayerCharacter_Survival_Prospect_C"
    local before = ui.stats().handlers
    local short = host:Item({ fit = true, text = "Engine", note = "GameEngine", icon = "box" })
    t.eq(short.drawn.note, "GameEngine", "what fits is left alone")
    t.eq(ui.stats().handlers, before + 2, "and a line that fits listens for its two presses only")
    local line = host:Item({ fit = true, text = "Character", note = class, icon = "user", indent = 1 })
    t.eq(line:Get().note, class, "the line knows the whole text")
    t.ok(line.drawn.note:sub(-3) == "..." and #line.drawn.note < #class, line.drawn.note)
    t.eq(line.drawn.text, "Character", "the name comes first and is whole")
    -- the window's 294, less the step in, the arrow, the icon and the padding
    local room = 294 - 12 - 16 - 10 - 20 - 16
    t.ok(kit.text_width("Character") + kit.text_width(line.drawn.note, 10) <= room, "name and note fit the line")
    -- a name that is itself too long loses its note
    line:Set({ text = class .. class, note = "Actor" })
    t.ok(line.drawn.text:sub(-3) == "...", line.drawn.text)
    t.eq(line.drawn.note, "")
    line:Set({ text = "Character", note = class, icon = "user", indent = 1 })
    -- the whole of it, as a tip
    local delay = controls.TIP_DELAY
    controls.TIP_DELAY = 0
    fake.hover(line.source)
    events.simulate(line.source, "OnHovered")
    frames(2)
    t.eq(select(2, tip.showing()), "Character")
    frames(5)
    line:Set({ text = "Character", note = class, icon = "user", indent = 1 })
    t.eq(tip.showing(), true, "saying the same again leaves the tip alone")
    line:Set({ text = "Engine", note = "GameEngine" })
    t.eq(tip.showing(), false, "a line that now fits has none")
    fake.hover(nil)
    events.simulate(line.source, "OnUnhovered")
    controls.TIP_DELAY = delay
    -- a wider window, and the line is whole again without being told
    line:Set({ text = "Character", note = class })
    t.ok(line.drawn.note ~= class)
    host:SetSize(1400, 300)
    t.eq(line.drawn.note, class)
    host:SetSize(320, 300)
    -- a line of a table: the name has its column, the value what is left before the note
    local cell = host:Item({ fit = true, columns = true })
    cell:Set({ text = "bReplicateMovementToEveryone", value = ("x"):rep(80), note = "string", name_width = 100 })
    t.ok(cell.drawn.text:sub(-3) == "..." and kit.text_width(cell.drawn.text) <= 100, cell.drawn.text)
    t.ok(cell.drawn.value:sub(-3) == "...", cell.drawn.value)
    local left = 294 - 16 - 10 - 100 - 18 - kit.text_width("string", 10)
    t.ok(kit.text_width(cell.drawn.value, 10, "mono") <= left, "the value stops before the note")
    t.eq(cell:Get().value, ("x"):rep(80))
    t.eq(cell.drawn.note, "string", "a short type stays beside a long value")
    t.ok(#cell.drawn.value >= 12, "which still has the width of twelve letters: " .. cell.drawn.value)
    local narrower = cell.drawn.value
    cell:Set({ text = "Name", value = ("x"):rep(80), note = "string", name_width = 100, width = 240 })
    t.ok(#cell.drawn.value < #narrower, "a line told it is narrower than its container cuts sooner")
    -- the value comes before its type: a short value is never cut to make room for a long type
    local long_type = "InventorySlotsFastArraySerializer"
    cell:Set({ text = "Slots", value = "not shown", note = long_type, name_width = 100 })
    t.eq(cell.drawn.value, "not shown", "the value is whole")
    t.ok(cell.drawn.note:sub(-3) == "..." and long_type:find(cell.drawn.note:sub(1, -4), 1, true) == 1, "and the type gives way: " .. cell.drawn.note)
    t.ok(kit.text_width("not shown", 10, "mono") + kit.text_width(cell.drawn.note, 10) <= 294 - 16 - 10 - 100 - 18, "both fit the line")
    cell:Set({ text = "Slots", value = "not shown", note = long_type, name_width = 100, width = 230 })
    t.eq(cell.drawn.value, "not shown")
    t.eq(cell.drawn.note, "", "a type with room for a letter or two only is left to the tip")
    cell:Set({ text = "Slots", value = "not shown", note = long_type, name_width = 100, width = 1200 })
    t.eq(cell.drawn.note, long_type)
    -- a line of a table that was cut shows its whole name, type and value under the mouse too
    cell:Set({ text = "ReplicatedModifierStackCountsForEveryone", value = "0 items", note = "array of float", name_width = 100 })
    t.ok(cell.drawn.text:sub(-3) == "...")
    controls.TIP_DELAY = 0
    fake.hover(cell.source)
    events.simulate(cell.source, "OnHovered")
    frames(2)
    t.eq(select(2, tip.showing()), "ReplicatedModifierStackCountsForEveryone")
    fake.hover(nil)
    events.simulate(cell.source, "OnUnhovered")
    controls.TIP_DELAY = delay
    -- a line made without fit is as it always was
    local old = host:Item({ text = "Character", note = class })
    t.eq(old.drawn.note, class)
    host:Destroy()
end)

t.test("a list line has one shape behind it, under the mouse or selected: its arrow sits inside it and draws none of its own", function()
    local style = Wax.import("gui.style")
    local host = ui.Window({ title = "One shape" })
    local handlers, before = ui.stats().handlers, fake.mark()
    local line = host:Item({ text = "Character", note = "Class", icon = "user", arrow = false }, function() end, function() end)
    local made = fake.made(before)
    local function is(object, class) return tostring(rawget(object, "__name")):find("UMG%." .. class .. ":[%w_]+$") ~= nil end
    -- under the mouse or pressed: the buttons that draw anything then
    local function answering()
        local found = {}
        for _, object in ipairs(made) do
            if is(object, "Button") then
                local look = object.WidgetStyle
                if look.Hovered.TintColor.SpecifiedColor.A > 0 or look.Pressed.TintColor.SpecifiedColor.A > 0 then found[#found + 1] = object end
            end
        end
        return found
    end
    -- selected: the boxes that show
    local function boxes()
        local found = {}
        for _, object in ipairs(made) do
            if is(object, "Border") then
                local seen, color = fake.last(object, "SetVisibility"), fake.last(object, "SetBrushColor")
                local hidden = seen ~= nil and (seen[2] == style.Visibility.Hidden or seen[2] == style.Visibility.Collapsed)
                if not hidden and color ~= nil and color[2].A > 0 then found[#found + 1] = object end
            end
        end
        return found
    end
    t.eq(#answering(), 1, "one shape under the mouse")
    t.ok(rawequal(answering()[1], line.source), "and it is the line itself")
    for _, state in ipairs({ "Normal", "Hovered", "Pressed", "Disabled" }) do
        t.eq(line.arrow.WidgetStyle[state].TintColor.SpecifiedColor.A, 0, "the arrow draws nothing behind itself: " .. state)
    end
    t.eq(fake.count(line.widget, "AddChild"), 2, "the line lies over the whole control, with only the selection's box under it")
    t.eq(line.source.WidgetStyle.NormalPadding.Left, 0, "it starts at the left edge, so the arrow is inside it")
    t.eq(#boxes(), 0, "nothing shows behind a line that is not selected")
    line:SetSelected(true)
    t.eq(#boxes(), 1, "one shape when it is selected")
    line:Set({ text = "Mesh", icon = "puzzle", arrow = true, indent = 2, selected = true })
    t.eq(#boxes(), 1, "and one when it is set in")
    t.eq(#answering(), 1)
    -- the arrow answers the mouse by its own colour only
    t.eq(ui.stats().handlers, handlers + 4, "two presses, and the mouse coming to the arrow and leaving it")
    events.simulate(line.arrow, "OnHovered")
    t.eq(#answering(), 1)
    t.eq(#boxes(), 1)
    events.simulate(line.arrow, "OnUnhovered")
    line:SetSelected(false)
    t.eq(#boxes(), 0)
    -- a line of a table is made the same way
    before = fake.mark()
    local cell = host:Item({ columns = true, divider = true, text = "Health", value = "87.5", note = "float", selected = true })
    made = fake.made(before)
    t.eq(#answering(), 1)
    t.eq(#boxes(), 1)
    t.eq(fake.count(cell.widget, "AddChild"), 3, "the selection's box, the line and the rule under it")
    host:Destroy()
end)

t.test("stopping the GUI leaves nothing behind", function()
    scope.run(scope.new("late"), function() ui.Window({ title = "Late" }) end)
    ui.stop()
    t.eq(ui.stats().windows, 0)
    t.raises(function() ui.Window({}) end, "not running")
end)

t.finish("gui")
