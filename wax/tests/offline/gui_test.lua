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
    t.eq(#ui.Themes(), 5)
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

t.test("a see-through button draws nothing behind it when it is switched off", function()
    local window = ui.Window({ title = "Switched off" })
    local flag = window:Toggle("Flag", false)
    local go = window:Button("Go", function() end)
    flag:SetEnabled(false)
    t.eq(flag.source.WidgetStyle.Disabled.TintColor.SpecifiedColor.A, 0, "the switch has no block behind it")
    t.ok(go.widget.WidgetStyle.Disabled.TintColor.SpecifiedColor.A > 0, "an ordinary button keeps its flat look")
    window:Destroy()
end)

t.test("stopping the GUI leaves nothing behind", function()
    scope.run(scope.new("late"), function() ui.Window({ title = "Late" }) end)
    ui.stop()
    t.eq(ui.stats().windows, 0)
    t.raises(function() ui.Window({}) end, "not running")
end)

t.finish("gui")
