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

-- Every text block the library makes in this suite is kept, with where it was made: the last test but one looks at them all.
local kit_module = Wax.import("gui.kit")
kit_module.MEASURE = false      -- the stand-in engine gives every widget one size: close cases go by the letters here
local text_blocks = {}
do
    local make = kit_module.label
    kit_module.label = function(content, options)
        local widget = make(content, options)
        local from = debug.getinfo(2, "Sl")
        text_blocks[#text_blocks + 1] = { info = kit_module.labels()[widget], where = from.short_src:match("[^/\\]+$") .. ":" .. from.currentline }
        return widget
    end
end

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

t.test("a box resized by an edge keeps the edges across from it, its smallest size and the limits it is given", function()
    local drag = Wax.import("gui.drag")
    local box = { x = 200, y = 100, width = 500, height = 300 }
    local function check(from, edges, dx, dy, limits, x, y, width, height)
        local got = { drag.resize(from, edges, dx, dy, limits) }
        for index, want in ipairs({ x, y, width, height }) do
            t.eq(got[index], want, ("%s by %d, %d: value %d"):format(edges, dx, dy, index))
        end
    end
    check(box, "e", 40, 99, nil, 200, 100, 540, 300)
    check(box, "s", 99, 60, nil, 200, 100, 500, 360)
    check(box, "w", -30, 99, nil, 170, 100, 530, 300)
    check(box, "n", 99, -20, nil, 200, 80, 500, 320)
    check(box, "nw", -30, -20, nil, 170, 80, 530, 320)
    check(box, "ne", 40, -20, nil, 200, 80, 540, 320)
    check(box, "sw", -30, 60, nil, 170, 100, 530, 360)
    check(box, "se", 40, 60, nil, 200, 100, 540, 360)
    t.eq(box.x, 200, "the box it is given is left as it was")
    t.eq(box.width, 500)

    local least = { min_width = 240, min_height = 140 }
    check(box, "e", -1000, 0, least, 200, 100, 240, 300)
    check(box, "s", 0, -1000, least, 200, 100, 500, 140)
    check(box, "w", 1000, 0, least, 460, 100, 240, 300)
    check(box, "n", 0, 1000, least, 200, 260, 500, 140)

    local screen = { min_width = 240, min_height = 140, left = 0, top = 0, right = 1920, bottom = 1080 }
    check(box, "nw", -5000, -5000, screen, 0, 0, 700, 400)
    check(box, "se", 5000, 5000, screen, 200, 100, 1720, 980)

    -- an edge that starts past a limit comes back, and goes no further out
    local beyond = { x = 1600, y = 900, width = 500, height = 300 }
    check(beyond, "se", 50, 50, screen, 1600, 900, 500, 300)
    check(beyond, "se", -100, -60, screen, 1600, 900, 400, 240)
    -- the left and the top edge stop where the rest of the box could no longer be reached
    screen.reach_x, screen.reach_y = 1840, 1044
    check(beyond, "nw", 1000, 1000, screen, 1840, 1044, 260, 156)
end)

t.test("a window is resized by every edge and corner: the edges across from the one held stay, and it is saved once at the end", function()
    local style, window_module = Wax.import("gui.style"), Wax.import("gui.window")
    local sized
    scope.run(owner, function() sized = ui.Window({ title = "Edges", width = 500, height = 300, x = 600, y = 400 }) end)
    ui.Open()
    local saves, keep = {}, window_module.remember
    window_module.remember = function(_, geometry) saves[#saves + 1] = geometry end
    local C = style.Cursor
    local cursors = { n = C.ResizeUpDown, s = C.ResizeUpDown, e = C.ResizeLeftRight, w = C.ResizeLeftRight,
        nw = C.ResizeSouthEast, se = C.ResizeSouthEast, ne = C.ResizeSouthWest, sw = C.ResizeSouthWest }
    for edges, cursor in pairs(cursors) do
        t.ok(sized.edge_handles[edges], "no handle for " .. edges)
        t.eq(fake.last(sized.edge_handles[edges], "SetCursor")[2], cursor, "the cursor over " .. edges)
    end
    t.ok(rawequal(sized.edge_handles.se, sized.grip_button), "the grip is the handle of the bottom right corner")
    t.eq(fake.last(sized.resize_layer, "SetVisibility")[2], style.Visibility.SelfHitTestInvisible, "what lies between the handles is not covered")

    local function pull(edges, dx, dy, held)
        sized:SetPosition(600, 400)
        sized:SetSize(500, 300)
        fake.mouse.X, fake.mouse.Y = 900, 500
        events.simulate(sized.edge_handles[edges], "OnPressed")
        fake.pressed = true
        fake.mouse.X, fake.mouse.Y = 900 + dx, 500 + dy
        frames(1)
        if held then held() end
        fake.pressed = false
        frames(1)
    end
    local function is(what, x, y, width, height)
        t.eq(sized.x, x, what .. ": x")
        t.eq(sized.y, y, what .. ": y")
        t.eq(sized.width, width, what .. ": width")
        t.eq(sized.height, height, what .. ": height")
        t.eq(sized.slot:GetPosition().X, x, what .. ": drawn at x")
        t.eq(sized.slot:GetPosition().Y, y, what .. ": drawn at y")
        t.eq(sized.slot:GetSize().X, width, what .. ": drawn width")
        t.eq(sized.slot:GetSize().Y, height, what .. ": drawn height")
    end
    local after = {
        n = { 600, 380, 500, 320 }, s = { 600, 400, 500, 280 }, w = { 570, 400, 530, 300 }, e = { 600, 400, 470, 300 },
        nw = { 570, 380, 530, 320 }, ne = { 600, 380, 470, 320 }, sw = { 570, 400, 530, 280 }, se = { 600, 400, 470, 280 },
    }
    for edges, want in pairs(after) do
        pull(edges, -30, -20)
        is(edges, want[1], want[2], want[3], want[4])
    end
    t.eq(#saves, 8, "each drag was saved once, when it ended")
    t.eq(saves[8].width, sized.width)
    t.eq(saves[8].x, sized.x)

    -- held for several frames it follows the mouse, and nothing is saved meanwhile
    pull("w", -10, 0, function()
        for step = 2, 5 do
            fake.mouse.X = 900 - step * 10
            frames(1)
            t.eq(sized.width, 500 + step * 10)
            t.eq(sized.x + sized.width, 1100, "the right edge stays")
        end
        local laid = fake.count(sized.sizer, "SetWidthOverride")
        frames(3)
        t.eq(fake.count(sized.sizer, "SetWidthOverride"), laid, "while the mouse rests the window is not laid out again")
        t.eq(#saves, 8)
        t.eq(sized.lights.w.level, 1, "the piece of the outline by the held edge glows")
        t.eq(sized.lights.e.level, 0, "and no other piece does")
    end)
    t.eq(#saves, 9)
    t.eq(sized.lights.w.level, 0, "let go, the glow is gone")
    t.ok(math.abs(fake.last(sized.outline, "SetColorAndOpacity")[2].B - style.theme.outline.B) < 1e-9, "the outline as a whole was never lit")

    -- never smaller than the window may be: the edge stops, and the one across from it has not moved
    pull("w", 5000, 0)
    is("left edge to the right", 860, 400, 240, 300)
    pull("n", 0, 5000)
    is("top edge down", 600, 560, 500, 140)
    pull("se", -5000, -5000)
    is("grip to the top left", 600, 400, 240, 140)
    -- and no edge leaves the screen
    pull("nw", -5000, -5000)
    is("top left corner off the screen", 0, 0, 1100, 700)
    pull("se", 5000, 5000)
    is("grip off the screen", 600, 400, 1320, 680)
    pull("ne", 5000, -5000)
    is("top right corner off the screen", 600, 0, 1320, 700)

    -- at double scale the mouse goes twice as far for the same change, and the window is taken from where it is drawn
    t.eq(ui.SetScale(2), 2)
    pull("w", -40, 0)
    t.eq(sized.width, 520)
    t.eq(sized.x, 560)
    t.eq(sized.slot:GetPosition().X + sized.slot:GetSize().X, 1600, "the right edge stays where it was drawn")
    pull("n", 0, 5000)
    t.eq(sized.height, 140)
    t.eq(sized.y, 400 + (300 - 140) * 2)
    ui.SetScale(1)

    -- minimised it is only its title bar: the handles are gone with the grip, and a press that came anyway does nothing
    sized:SetPosition(600, 400)
    sized:SetSize(500, 300)
    sized:SetMinimized(true)
    t.eq(fake.last(sized.resize_layer, "SetVisibility")[2], style.Visibility.Collapsed)
    t.eq(fake.last(sized.grip, "SetVisibility")[2], style.Visibility.Collapsed)
    events.simulate(sized.edge_handles.n, "OnPressed")
    t.eq(sized.drag, nil)
    sized:SetMinimized(false)
    t.eq(fake.last(sized.resize_layer, "SetVisibility")[2], style.Visibility.SelfHitTestInvisible)

    window_module.remember = keep
    ui.Close()
    sized:Destroy()
end)

t.test("a window made with resizable = false has no grip and no handles, and is the size its mod gave it", function()
    local window_module = Wax.import("gui.window")
    local recall = window_module.recall
    window_module.recall = function(key)
        if key == "gui-test/Fixed" then return { x = 300, y = 200, width = 900, height = 700 } end
        return recall(key)
    end
    local fixed, loose
    scope.run(owner, function()
        fixed = ui.Window({ title = "Fixed", width = 400, height = 300, resizable = false })
        loose = ui.Window({ title = "Loose", width = 400, height = 300 })
    end)
    window_module.recall = recall
    t.eq(fixed.edge_handles, nil)
    t.eq(fixed.resize_layer, nil)
    t.eq(fixed.grip, nil)
    t.eq(fixed.grip_button, nil)
    t.eq(#fixed.chrome.disconnects + 24, #loose.chrome.disconnects, "eight presses and each handle's two hovers are not listened for")
    t.eq(fixed.width, 400, "a size saved while it could be resized is not used")
    t.eq(fixed.height, 300)
    t.eq(fixed.x, 300, "its saved place is")
    t.eq(fixed.y, 200)
    fixed:SetSize(450, 320)
    t.eq(fixed.width, 450, "its mod can still give it another size")
    fixed:SetMinimized(true)
    fixed:SetMinimized(false)
    ui.Open()
    fake.mouse.X, fake.mouse.Y = 400, 210
    events.simulate(fixed.bar, "OnPressed")
    fake.pressed = true
    fake.mouse.X, fake.mouse.Y = 425, 215
    frames(1)
    fake.pressed = false
    frames(1)
    ui.Close()
    t.eq(fixed.x, 325, "and the title bar still moves it")
    t.eq(fixed.width, 450)
    fixed:Destroy()
    loose:Destroy()
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

t.test("the Mods page has the updater's button, a switch on the card of each mod from the catalogue, and offers an update there", function()
    local panel = Wax.import("gui.debug")
    t.eq(panel.updates, nil, "without the updater the page has none of this")
    local state = { available = {}, installing = {}, checking = false, last = 0, auto = true, mods = { Hello = { version = "0.1.0", auto = true } } }
    local asked, put, switched = 0, {}, {}
    Wax.update = {
        state = function() return state end,
        set_auto = function(id, on)
            switched[#switched + 1] = tostring(id) .. "=" .. tostring(on)
            state.mods[id].auto = on
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
    -- what a label was given to say, whether or not all of it shows
    local function text_of(control) return Wax.import("gui.kit").said(control.widget) end
    local function refresh()
        local started = os.clock()
        while os.clock() - started < 0.55 do end
        panel.step()
    end
    local before = fake.mark()
    panel.start()
    ui.SetPreview(true)
    local shown = panel.updates
    t.ok(shown and shown.check and shown.line and shown.note, "the controls are there")
    t.eq(panel.Window().title, "Wax", "the name stays as it was")
    t.eq(panel.Window().version, "0.3.12", "the version sits beside it")
    t.eq(shown.switch, nil, "there is no one switch for every mod any more")
    t.eq(text_of(shown.line), "Not checked yet.")
    refresh()
    t.eq(next(shown.buttons), nil, "no update button while nothing newer is known")

    local card = panel.card("Hello")
    t.ok(card and card.auto, "the mod came from the catalogue, so its card has an Auto Update switch")
    t.eq(card.auto:Get(), true)
    click(card.auto.source)
    frames(1)
    t.eq(switched[1], "Hello=false", "the switch tells the updater which mod, and what")
    state.mods.Hello.auto = true
    refresh()
    t.eq(card.auto:Get(), true, "and follows it when the setting is changed elsewhere")
    t.ok(rawequal(panel.card("Hello"), card), "without the card being built again")

    click(shown.check.source)
    frames(1)
    t.eq(asked, 1)
    t.eq(text_of(shown.line), "Checking ...")
    click(shown.check.source)
    frames(1)
    t.eq(text_of(shown.line), "Try again in 42 seconds.", "asked again too soon, it says how long to wait")

    shown.hold = 0
    state.mods.Hello.auto = false
    state.available.Hello, state.last = "0.2.0", os.time() - 600
    refresh()
    t.eq(text_of(shown.line), "Last checked 10 minutes ago.")
    t.ok(shown.buttons.Hello, "a mod with a newer version gets a button on its card, also with its switch off")
    t.eq(panel.card("Hello").auto:Get(), false)
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
    t.eq(shown.check.disabled or false, false)
    state.stopped = true
    refresh()
    t.eq(shown.check.disabled, true, "without the helper the button is disabled")
    t.eq(panel.card("Hello").auto.disabled, true, "and so is the mod's switch")
    -- a mod that did not come from the catalogue has no switch
    state.mods = {}
    refresh()
    t.eq(panel.card("Hello").auto, nil)

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

t.test("the Mods page says which Wax this is, and when a newer one is waiting", function()
    local panel = Wax.import("gui.debug")
    local state = { running = "0.3.12", ready = nil, installer = nil }
    Wax.selfupdate = { state = function() return state end }
    Wax.update = {
        state = function() return { available = {}, installing = {}, checking = false, last = 0, look = true, mods = {} } end,
        set_looking = function() end,
        check_now = function() return true end,
        install = function() return true end,
    }
    local function refresh()
        local started = os.clock()
        while os.clock() - started < 0.55 do end
        panel.step()
    end
    panel.start()
    ui.SetPreview(true)
    t.eq(panel.Window().title, "Wax")
    t.eq(panel.Window().version, "0.3.12")
    state.ready = "0.3.13"
    refresh()
    t.eq(panel.Window().version, "0.3.12  ·  0.3.13 at next start")
    state.ready, state.installer = nil, "0.4.0"
    refresh()
    t.eq(panel.Window().version, "0.3.12  ·  0.4.0 needs Update Wax.cmd")
    ui.SetPreview(false)
    panel.stop()
    Wax.selfupdate, Wax.update = nil, nil
end)

t.test("the Mods page has one switch for looking for updates: off, Check now and every mod's Auto Update are greyed", function()
    local panel = Wax.import("gui.debug")
    local state = { available = {}, installing = {}, checking = false, last = 0, look = true, auto = true,
        mods = { Hello = { version = "0.1.0", auto = true } } }
    local looked = {}
    local function auto() return panel.card("Hello").auto end
    Wax.update = {
        state = function() return state end,
        set_auto = function(id, on) state.mods[id].auto = on end,
        set_looking = function(on)
            looked[#looked + 1] = on
            state.look = on
        end,
        check_now = function() return true end,
        install = function() return true end,
    }
    -- what a label was given to say, whether or not all of it shows
    local function text_of(control) return Wax.import("gui.kit").said(control.widget) end
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
    t.eq(auto().disabled or false, false, "while it is on nothing is greyed")
    t.eq(text_of(shown.line), "Not checked yet.")

    click(shown.look.source)
    frames(1)
    t.eq(looked[1], false, "the switch tells the updater")
    refresh()
    t.eq(auto().disabled, true, "the mod's Auto Update is greyed")
    t.eq(shown.check.disabled, true, "and so is Check now")
    t.eq(shown.look.disabled or false, false, "the switch itself stays in reach")
    t.eq(text_of(shown.line), "Not looking for updates. Nothing is asked of the catalogue.")

    state.look = true
    refresh()
    t.eq(shown.look:Get(), true, "it follows the setting when that is changed elsewhere")
    t.eq(auto().disabled, false)
    t.eq(shown.check.disabled, false)
    t.eq(text_of(shown.line), "Not checked yet.")

    -- without the helper the switch does nothing either
    state.stopped = true
    refresh()
    t.eq(shown.look.disabled, true)

    ui.SetPreview(false)
    panel.stop()
    Wax.update = nil

    -- a page that starts with the setting off shows it off, with the rest greyed from the first look
    state = { available = {}, installing = {}, checking = false, last = 0, look = false, auto = true,
        mods = { Hello = { version = "0.1.0", auto = true } } }
    Wax.update = { state = function() return state end, set_auto = function() end, set_looking = function() end,
        check_now = function() return false end, install = function() return false end }
    panel.start()
    ui.SetPreview(true)
    shown = panel.updates
    t.eq(shown.look:Get(), false)
    refresh()
    t.eq(auto().disabled, true)
    t.eq(shown.check.disabled, true)
    -- a card that is built again while nothing is looked for starts greyed too
    state.available.Hello = "0.2.0"
    refresh()
    t.eq(auto().disabled, true)
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
    -- twice the size is twice the letters; what a text block is wider than its letters does not grow
    t.ok(math.abs((kit.text_width("abc", 22) - 0.8) - 2 * (kit.text_width("abc", 11) - 0.8)) < 0.001)
    t.ok(math.abs(kit.text_width("5-10", 11) - 31.77) < 1, "as the game measured it: 31.77")
    t.ok(math.abs(kit.text_width("100-200", 11) - 59.38) < 1, "59.38")
    t.ok(math.abs(kit.text_width("More Cargo Slots!  0.1.0", 11) - 163.51) < 1, "163.51")
    t.ok(kit.text_width("aaaa", 11, nil, "Bold") > kit.text_width("aaaa", 11), "the bold face is wider")
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

t.test("text put in a box by code is not the user doing something: an open list stays open, and typing still closes it", function()
    local host = ui.Window({ title = "Quiet" })
    local pick = host:Dropdown("Pick", { "A", "B", "C" }, "B")
    local box = host:Input("Name", {})
    local typed = {}
    box.Typed:Connect(function(text) typed[#typed + 1] = text end)
    -- the engine reports text put in a box as a change of its text, in the middle of the call that put it there
    local real = fake.react.SetText
    fake.react.SetText = function(self, text)
        if rawequal(self, box.source) then events.simulate(box.source, "OnTextChanged", text:ToString()) end
    end
    ui.Open()
    click(pick.source)
    t.ok(pick.parts.open)
    for count = 1, 5 do
        box:Set("value " .. count)
        frames(1)
    end
    t.eq(typed[#typed], "value 5", "whoever listens to the box still hears of it")
    t.ok(pick.parts.open, "the list is still open")
    -- a setter that fails leaves the next real event counting again
    t.raises(function() events.quietly(error, "on purpose") end, "on purpose")
    t.eq(events.quietly(function(a, b) return a + b end, 2, 3), 5)
    events.simulate(box.source, "OnTextChanged", "typed by hand")
    t.ok(not pick.parts.open, "typing in the box closes it, as it always did")
    fake.react.SetText = real
    ui.Close()
    host:Destroy()
end)

-- Mods as the loader has them, for the tests of who owns a window.
local loaded = {}
Wax.mods.get = function(id) return loaded[id] end
local function mod(id, name)
    local record = { id = id, scope = scope.new(id), manifest = { name = name } }
    loaded[id] = record
    return record
end
local function press(key)
    fake.key_pressed = key
    frames(1)
    fake.key_pressed = nil
end
local function owner_entry(id)
    for _, entry in ipairs(ui.Keys.Owners()) do
        if entry.id == id then return entry end
    end
    return nil
end

t.test("every window has an owner with a key of its own: Wax's panel, and each mod", function()
    Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
    local garage, radar = mod("Garage", "Garage Tools"), mod("Radar")
    local own = ui.Window({ title = "Own" })
    local garage_window, radar_window
    scope.run(garage.scope, function() garage_window = ui.Window({ title = "Garage" }) end)
    scope.run(radar.scope, function() radar_window = ui.Window({ title = "Radar", key = "K" }) end)
    local list = ui.Keys.Owners()
    t.eq(#list, 3)
    t.eq(list[1].id, "Wax", "Wax comes first")
    t.eq(list[2].id, "Garage")
    t.eq(list[2].name, "Garage Tools", "a mod is named as its mod.lua names it")
    t.eq(list[3].name, "Radar", "or by its id")
    t.eq(ui.Keys.Get("Wax"), "F8")
    t.eq(ui.GetToggleKey(), "F8")
    t.eq(ui.Keys.Get("Garage"), "F6", "a mod that asked for no key is given the first of the default ones")
    t.eq(ui.Keys.Get("Radar"), "K", "a mod gets the key it asked for")
    t.eq(scope.run(radar.scope, ui.Keys.Get), "K", "asked without a name, it is the asking mod's own")
    t.eq(ui.Keys.Get("Nobody"), nil)

    -- a key shows and hides its owner's windows and nobody else's
    local opened, closed = 0, 0
    local on_open, on_close = ui.Opened:Connect(function() opened = opened + 1 end), ui.Closed:Connect(function() closed = closed + 1 end)
    press("F6")
    t.ok(ui.IsOpen(), "the mouse is free")
    t.ok(garage_window:IsShowing())
    t.ok(not radar_window:IsShowing() and not own:IsShowing(), "the others stay away")
    t.ok(radar_window:IsVisible(), "a window that is not up is still a shown window: it comes with its own key")
    t.eq(owner_entry("Garage").open, true)
    t.eq(owner_entry("Radar").open, false)
    local style = Wax.import("gui.style")
    t.eq(fake.last(radar_window.outer, "SetVisibility")[2], style.Visibility.Collapsed)
    t.eq(fake.last(garage_window.outer, "SetVisibility")[2], style.Visibility.Visible)
    press("K")
    t.ok(garage_window:IsShowing() and radar_window:IsShowing(), "several owners can be up at once")
    press("F8")
    t.ok(own:IsShowing())
    press("F6")
    t.ok(not garage_window:IsShowing() and radar_window:IsShowing() and own:IsShowing())
    t.ok(ui.IsOpen(), "the menu stays open for the others")
    press("K")
    press("F8")
    t.ok(not ui.IsOpen(), "hiding the last one closes the menu")
    t.eq(opened, 1, "the menu opened once")
    t.eq(closed, 1, "and closed once")

    -- Escape hides everything
    press("F6")
    press("K")
    press("Escape")
    t.ok(not ui.IsOpen())
    t.ok(not garage_window:IsShowing() and not radar_window:IsShowing())
    t.eq(closed, 2)

    -- ui.Open, ui.Close and ui.Toggle are about the caller's own windows
    scope.run(garage.scope, ui.Open)
    t.ok(garage_window:IsShowing() and not own:IsShowing() and not radar_window:IsShowing())
    ui.Open()
    t.ok(own:IsShowing(), "called by Wax, it is Wax's panel")
    scope.run(radar.scope, ui.Close)
    t.ok(ui.IsOpen() and garage_window:IsShowing(), "a mod that closes what is not open closes nothing")
    scope.run(garage.scope, ui.Close)
    t.ok(not garage_window:IsShowing() and own:IsShowing() and ui.IsOpen())
    scope.run(radar.scope, ui.Toggle)
    t.ok(radar_window:IsShowing())
    scope.run(radar.scope, ui.Toggle)
    t.ok(not radar_window:IsShowing())
    ui.Close()
    t.ok(not ui.IsOpen())

    -- preview shows every window, whoever owns it
    ui.SetPreview(true)
    t.ok(own:IsShowing() and garage_window:IsShowing() and radar_window:IsShowing())
    t.ok(not ui.IsOpen())
    ui.SetPreview(false)
    t.ok(not own:IsShowing() and not garage_window:IsShowing())

    -- a window closed with its cross takes its owner down, and the last owner the menu
    press("F6")
    press("K")
    click(garage_window.close_button)
    t.ok(ui.IsOpen() and radar_window:IsShowing())
    t.eq(owner_entry("Garage").open, false)
    click(radar_window.close_button)
    t.ok(not ui.IsOpen())
    press("F6")
    t.ok(garage_window:IsShowing(), "its key brings back the window the player closed")
    t.ok(not radar_window:IsVisible(), "and not another owner's")
    press("F6")
    radar_window:Show()
    t.ok(not radar_window:IsShowing(), "a window shown while the menu is closed waits for its key")
    -- a window its mod shows while the menu is open comes up there and then
    radar_window:Hide()
    press("F8")
    radar_window:Show()
    t.ok(radar_window:IsShowing())
    t.eq(owner_entry("Radar").open, true)
    press("Escape")

    on_open:Disconnect()
    on_close:Disconnect()
    own:Destroy()
    t.eq(owner_entry("Wax"), nil, "an owner with no window is not listed")
    garage.scope:destroy()
    radar.scope:destroy()
    t.eq(#ui.Keys.Owners(), 0)
    Wax.game = nil
end)

t.test("a mod's named key runs on its key, can be changed by the player, and a clash is said and not refused", function()
    Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
    local codex, lamp = mod("Codex", "The Codex"), mod("Lamp")
    local opened, lit = 0, 0
    local open, light
    scope.run(codex.scope, function() open = ui.Bind("Open", "F10", function() opened = opened + 1 end, { label = "Open the panels" }) end)
    scope.run(lamp.scope, function() light = ui.Bind("Light", "L", function() lit = lit + 1 end) end)
    t.eq(open:Get(), "F10")
    press("F10")
    frames(1)
    t.eq(opened, 1)
    local list = ui.Keys.Binds("Codex")
    t.eq(#list, 1)
    t.eq(list[1].Label, "Open the panels")
    t.eq(list[1].Key, "F10")
    t.eq(#ui.Keys.Binds(), 2)
    t.eq(#ui.Keys.Clashes(), 0)
    t.raises(function() scope.run(codex.scope, function() ui.Bind("Open", "F9", function() end) end) end, "already has a key named 'Open'")
    -- the same key as another mod's is taken, and both sides are told
    t.eq(ui.Keys.SetBind("Lamp", "Light", "F10"), true)
    t.eq(light:Get(), "F10")
    t.eq(#ui.Keys.Clashes(), 1)
    t.ok(ui.Keys.Clashes("Lamp")[1]:find("F10 is also used by The Codex (Open the panels)", 1, true), ui.Keys.Clashes("Lamp")[1])
    t.ok(ui.Keys.Clashes("Codex")[1]:find("Lamp (Light)", 1, true))
    press("F10")
    frames(1)
    t.eq(opened, 2)
    t.eq(lit, 1, "one press acts on both")
    -- the Wax menu's key clashes too
    open:Set("F8")
    t.ok(ui.Keys.Clashes("Codex")[1]:find("the Wax menu", 1, true), ui.Keys.Clashes("Codex")[1])
    ui.Keys.SetBind("Codex", "Open", nil)
    t.eq(open:Get(), nil, "no key at all")
    t.eq(#ui.Keys.Clashes(), 0)
    codex.scope:destroy()
    lamp.scope:destroy()
    t.eq(#ui.Keys.Binds(), 0)
    -- a mod that has not run yet: the keys its mod.lua names are known all the same
    local sleeper = mod("Sleeper")
    sleeper.manifest.key, sleeper.manifest.keys = "F9", { "F11: Wake up", "not a key line" }
    local named = ui.Keys.Binds("Sleeper")
    t.eq(#named, 1)
    t.eq(named[1].Name, "Wake up")
    t.eq(named[1].Key, "F11")
    t.eq(named[1].Declared, true)
    t.eq(ui.Keys.Get("Sleeper"), "F9", "and the key of its windows")
    local woke, wake = 0, nil
    scope.run(sleeper.scope, function() wake = ui.Bind("Wake up", nil, function() woke = woke + 1 end) end)
    t.eq(wake:Get(), "F11", "ui.Bind with no key takes the one mod.lua names")
    sleeper.scope:destroy()
    Wax.game = nil
end)

t.test("a key is chosen for an owner with ui.Keys.Set: one that is taken is given all the same, with a notice of who else has it", function()
    Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
    ui.Notifications.Clear()
    local garage, radar, scout = mod("Garage", "Garage Tools"), mod("Radar"), mod("Scout")
    local own = ui.Window({ title = "Own" })
    local garage_window, radar_window
    scope.run(garage.scope, function() garage_window = ui.Window({ title = "Garage" }) end)
    scope.run(radar.scope, function()
        radar_window = ui.Window({ title = "Radar", key = "K" })
        ui.Hotkey("J", function() end)
    end)
    t.eq(ui.Keys.Get("Garage"), "F6", "the default it was given is remembered")
    local told = {}
    local listening = ui.Keys.Changed:Connect(function(id, key) told[#told + 1] = id .. "=" .. tostring(key) end)
    local wax_told = {}
    local wax_listening = ui.KeyChanged:Connect(function(key) wax_told[#wax_told + 1] = tostring(key) end)

    local ok, who = ui.Keys.Set("Garage", "K")
    t.eq(ok, true, "a key somebody has is given all the same")
    t.eq(who, "Radar", "and the answer names who else has it")
    t.eq(ui.Keys.Get("Garage"), "K")
    t.eq(ui.Notifications.Count(), 1, "and a notice says so")
    t.eq(told[1], "Garage=K")
    t.ok(ui.Keys.Clashes("Garage")[1]:find("K is also used by Radar", 1, true), ui.Keys.Clashes("Garage")[1])
    ok, who = ui.Keys.Set("Garage", "F8")
    t.eq(who, "Wax")
    ok, who = ui.Keys.Set("Garage", "J")
    t.eq(who, "Radar", "a key another mod uses as a hotkey is named too")
    t.eq(ui.Keys.Set("Garage", "F6"), true)
    t.eq(#ui.Keys.Clashes(), 0)
    told = {}
    ui.Notifications.Clear()

    t.eq(ui.Keys.Set("Garage", "Ctrl+Shift+G"), true)
    t.eq(ui.Keys.Get("Garage"), "Ctrl+Shift+G")
    t.eq(told[1], "Garage=Ctrl+Shift+G")
    ok, who = ui.Keys.Set("Radar", "shift+ctrl+G")
    t.eq(who, "Garage Tools", "the same key spelt another way is the same key")
    t.eq(ui.Keys.Set("Garage", "F6"), true)
    t.eq(ui.Keys.Set("Radar", "K"), true, "an owner can be given the key it has")
    t.eq(ui.Keys.Set("Wax", "F7"), true)
    t.eq(ui.GetToggleKey(), "F7")
    t.eq(wax_told[1], "F7", "ui.KeyChanged still tells of Wax's own key")
    t.eq(#wax_told, 1, "and of no other")
    press("F7")
    t.ok(own:IsShowing(), "the new key works")
    press("F8")
    t.ok(own:IsShowing(), "and the old one does nothing")
    press("F7")
    t.eq(ui.Keys.Set("Wax", "F8"), true)
    t.raises(function() ui.Keys.Set("Garage", "Meta+K") end, "key name")
    t.raises(function() ui.Keys.Set(nil, "K") end, "an owner")
    t.raises(function() ui.Keys:Set("Garage", "K") end, "with a dot")
    t.raises(function() scope.run(scout.scope, function() ui.Window({ title = "Scout", key = "Meta+K" }) end) end, "key name")

    -- what the player chose stays through a reload of the mod, whatever the mod asks for
    t.eq(ui.Keys.Set("Radar", "L"), true)
    radar.scope:destroy()
    radar.scope = scope.new("Radar")
    scope.run(radar.scope, function() radar_window = ui.Window({ title = "Radar", key = "K" }) end)
    t.eq(ui.Keys.Get("Radar"), "L")
    -- a mod that asks for a key somebody has gets a default one, and so does one that asks for nothing
    ui.Notifications.Clear()
    local scout_window
    scope.run(scout.scope, function() scout_window = ui.Window({ title = "Scout", key = "L" }) end)
    t.eq(ui.Keys.Get("Scout"), "F9", "F6 is Garage's, so the next of the default keys")
    t.eq(ui.Notifications.Count(), 0, "it is not said while the mod is still loading: a hotkey it makes may move it")
    frames(1)
    t.eq(ui.Notifications.Count(), 1, "a key that was given is said once")
    ui.Notifications.Clear()
    scout.scope:destroy()
    scout.scope = scope.new("Scout")
    scope.run(scout.scope, function() scout_window = ui.Window({ title = "Scout" }) end)
    t.eq(ui.Keys.Get("Scout"), "F9", "and it is the same one the next time")
    frames(1)
    t.eq(ui.Notifications.Count(), 0, "said once, not every time")
    -- no key at all
    t.eq(ui.Keys.Set("Scout", nil), true)
    t.eq(ui.Keys.Get("Scout"), nil)
    press("F9")
    t.ok(not ui.IsOpen())
    t.eq(owner_entry("Scout").key, nil)

    -- a plain key gives way when the same key with Ctrl is another owner's
    t.eq(ui.Keys.Set("Scout", "Ctrl+K"), true)
    t.eq(ui.Keys.Set("Radar", "K"), true)
    fake.react.IsInputKeyDown = function(_, key) return key.KeyName == "LeftControl" end
    press("K")
    t.ok(scout_window:IsShowing(), "Ctrl+K is Scout's")
    t.ok(not radar_window:IsShowing(), "and K alone, with Ctrl held, is not pressed")
    fake.react.IsInputKeyDown = nil
    press("K")
    t.ok(radar_window:IsShowing())
    press("Escape")

    -- a letter key is not taken while a text box has the keyboard
    local box = own:Input("Name", {})
    fake.focused = box.source
    press("K")
    t.ok(not ui.IsOpen(), "typing a k in a box opens nothing")
    fake.focused = nil

    listening:Disconnect()
    wax_listening:Disconnect()
    own:Destroy()
    for _, record in ipairs({ garage, radar, scout }) do record.scope:destroy() end
    ui.Notifications.Clear()
    Wax.game = nil
end)

t.test("a mod's own hotkey and the key of its windows never both act on one press", function()
    Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
    ui.Notifications.Clear()
    local tools, sonar, lamp, bench = mod("Tools", "Tool Box"), mod("Sonar"), mod("Lamp"), mod("Bench")
    local own = ui.Window({ title = "Own" })

    -- a window that starts hidden and the mod's own key to show it, as the guide writes it
    local tools_window
    scope.run(tools.scope, function()
        tools_window = ui.Window({ title = "Tools", visible = false })
        t.eq(ui.Keys.Get(), "F6", "the first default, while nothing else is on it")
        ui.Hotkey("F6", function()
            tools_window:Show()
            ui.Open()
        end)
    end)
    t.eq(ui.Keys.Get("Tools"), "F9", "the default steps aside for the mod's own hotkey")
    frames(1)
    t.eq(ui.Notifications.Count(), 0, "and is not announced while the mod keeps its window hidden")
    press("F9")
    t.ok(not ui.IsOpen(), "a key with nothing to show opens nothing")
    press("F6")
    t.ok(ui.IsOpen() and tools_window:IsShowing(), "the mod's hotkey shows its window, and it stays up")
    press("F9")
    t.ok(not ui.IsOpen(), "the key Wax gave hides it")
    press("F9")
    t.ok(tools_window:IsShowing(), "and shows it again")
    press("F9")

    -- a mod that asks for the key its own hotkey is on: the hotkey acts when it runs, the key at other times
    local sonar_window
    scope.run(sonar.scope, function()
        sonar_window = ui.Window({ title = "Sonar", key = "K", visible = false })
        ui.Hotkey("K", function()
            sonar_window:Show()
            ui.Open()
        end)
    end)
    t.eq(ui.Keys.Get("Sonar"), "K", "a key the mod asked for stays")
    press("K")
    t.ok(ui.IsOpen() and sonar_window:IsShowing(), "one press opens it and does not close it again")
    press("K")
    t.ok(not ui.IsOpen(), "with the menu open the hotkey rests and the key hides the window")
    press("K")
    t.ok(sonar_window:IsShowing())
    press("K")
    t.ok(not ui.IsOpen())

    -- a hotkey that also works in the menu does the whole job itself
    local lamp_window
    scope.run(lamp.scope, function()
        lamp_window = ui.Window({ title = "Lamp", key = "L" })
        ui.Hotkey("L", function() ui.Toggle() end, { in_menu = true })
    end)
    press("L")
    t.ok(ui.IsOpen() and lamp_window:IsShowing())
    press("L")
    t.ok(not ui.IsOpen() and not lamp_window:IsShowing())

    -- a hotkey another mod makes later takes a default key from the mod that had it, and the player is told
    local bench_window
    scope.run(bench.scope, function() bench_window = ui.Window({ title = "Bench" }) end)
    local given = ui.Keys.Get("Bench")
    t.ok(given ~= nil and given ~= "F6" and given ~= "F9", "F6 is a hotkey and F9 another mod's key")
    frames(1)
    t.eq(ui.Notifications.Count(), 1, "a mod with a window to show is told its key")
    ui.Notifications.Clear()
    local told = {}
    local listening = ui.Keys.Changed:Connect(function(id, key) told[#told + 1] = id .. "=" .. tostring(key) end)
    local hotkey
    scope.run(lamp.scope, function() hotkey = ui.Hotkey("J", function() end) end)
    t.eq(ui.Keys.Get("Bench"), given, "a hotkey on another key changes nothing")
    hotkey:SetKey(given)
    local moved = ui.Keys.Get("Bench")
    t.ok(moved ~= nil and moved ~= given, "the default moved on")
    t.eq(told[1], "Bench=" .. tostring(moved))
    frames(1)
    t.eq(ui.Notifications.Count(), 1, "the new key is said")
    press(moved)
    t.ok(bench_window:IsShowing(), "and it works")
    press(moved)
    bench.scope:destroy()
    bench.scope = scope.new("Bench")
    scope.run(bench.scope, function() bench_window = ui.Window({ title = "Bench" }) end)
    t.eq(ui.Keys.Get("Bench"), moved, "the key it moved to is the one remembered")

    -- what the player chose is theirs: it stays when a hotkey comes on the same key
    t.eq(ui.Keys.Set("Bench", "F3"), true)
    scope.run(lamp.scope, function() ui.Hotkey("F3", function() end) end)
    t.eq(ui.Keys.Get("Bench"), "F3")
    t.eq(#told, 2, "one move and one choice were told of")

    listening:Disconnect()
    own:Destroy()
    for _, record in ipairs({ tools, sonar, lamp, bench }) do record.scope:destroy() end
    ui.Notifications.Clear()
    Wax.game = nil
end)

t.test("a mod that opens the menu without windows keeps the mouse free until it closes it again", function()
    Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
    local browser, garage = mod("Browser"), mod("Garage")
    local own = ui.Window({ title = "Own" })
    local garage_window
    scope.run(garage.scope, function() garage_window = ui.Window({ title = "Garage" }) end)
    local heard = { browser = 0, garage = 0, wax = 0 }
    scope.run(browser.scope, function() ui.Closed:Connect(function() heard.browser = heard.browser + 1 end) end)
    scope.run(garage.scope, function() ui.Closed:Connect(function() heard.garage = heard.garage + 1 end) end)
    local listening = ui.Closed:Connect(function() heard.wax = heard.wax + 1 end)

    scope.run(browser.scope, function() ui.Open({ windows = false }) end)
    t.ok(ui.IsOpen())
    t.ok(not own:IsShowing() and not garage_window:IsShowing(), "no window comes with it")
    scope.run(browser.scope, ui.Close)
    t.ok(not ui.IsOpen())
    t.eq(heard.browser, 1)
    t.eq(heard.wax, 1)

    -- with another owner's windows up as well, each ends on its own
    scope.run(browser.scope, function() ui.Open({ windows = false }) end)
    press("F8")
    t.ok(own:IsShowing())
    press("F8")
    t.ok(ui.IsOpen(), "Wax's key hides Wax's panel: the mod still has the mouse free")
    press("F8")
    scope.run(browser.scope, ui.Close)
    t.ok(ui.IsOpen() and own:IsShowing(), "the mod gave up its part: the panel stays")
    t.eq(heard.browser, 2, "and the mod is told that its menu is over")
    t.eq(heard.wax, 1, "nobody else is: the menu is still open")
    t.eq(heard.garage, 1)
    press("F8")
    t.ok(not ui.IsOpen())
    t.eq(heard.wax, 2)
    t.eq(heard.browser, 3)

    -- a mod with no window that asks for the menu gets the mouse, as it always did
    scope.run(browser.scope, ui.Open)
    t.ok(ui.IsOpen())
    scope.run(browser.scope, ui.Toggle)
    t.ok(not ui.IsOpen())
    -- a key of an owner with nothing to show opens nothing
    garage_window:Hide()
    press("F6")
    t.ok(not ui.IsOpen())
    garage_window:Show()

    -- a mod that is switched off while it has the menu open this way does not leave it open
    scope.run(browser.scope, function() ui.Open({ windows = false }) end)
    t.ok(ui.IsOpen())
    browser.scope:destroy()
    t.ok(not ui.IsOpen(), "the menu closes with the mod that opened it")
    browser.scope = scope.new("Browser")
    scope.run(browser.scope, function() ui.Open({ windows = false }) end)
    press("F8")
    browser.scope:destroy()
    t.ok(ui.IsOpen() and own:IsShowing(), "Wax's panel is still up")
    press("F8")
    t.ok(not ui.IsOpen(), "and nothing of the mod that is gone holds the menu open after it")

    listening:Disconnect()
    own:Destroy()
    browser.scope:destroy()
    garage.scope:destroy()
    Wax.game = nil
end)

t.test("a mod that loads again while its window is up has its new window up at once", function()
    Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
    local garage = mod("Garage")
    local own = ui.Window({ title = "Own" })
    local window
    scope.run(garage.scope, function() window = ui.Window({ title = "Garage" }) end)
    press("F6")
    t.ok(window:IsShowing())
    -- the loader destroys what the mod made and runs it again, in one frame or a few frames apart
    garage.scope:destroy()
    t.ok(ui.IsOpen(), "the menu does not close under a mod that is loading again")
    frames(5)
    garage.scope = scope.new("Garage")
    scope.run(garage.scope, function() window = ui.Window({ title = "Garage" }) end)
    t.ok(window:IsShowing(), "the new window shows without its key being pressed")
    frames(60)
    t.ok(ui.IsOpen() and window:IsShowing())
    -- a mod that is switched off does not come back: its place is given up after a moment
    garage.scope:destroy()
    frames(20)
    t.ok(ui.IsOpen())
    frames(20)
    t.ok(not ui.IsOpen(), "with nothing left to show the menu closes")
    -- and with another owner up, only that mod goes
    garage.scope = scope.new("Garage")
    scope.run(garage.scope, function() window = ui.Window({ title = "Garage" }) end)
    press("F6")
    press("F8")
    garage.scope:destroy()
    frames(40)
    t.ok(ui.IsOpen() and own:IsShowing())
    garage.scope = scope.new("Garage")
    scope.run(garage.scope, function() window = ui.Window({ title = "Garage" }) end)
    t.ok(not window:IsShowing(), "a window made later waits for its key")
    press("Escape")
    own:Destroy()
    garage.scope:destroy()
    Wax.game = nil
end)

t.test("the game takes the mouse back when a screen of its own closes: the open menu puts it there again", function()
    local player = fake.new_object("PlayerController")
    Wax.game = { LocalPlayer = { Raw = player } }
    -- the game's own stack of menus, as PushUIInput, PopUIInput and ClearUIInput keep it
    local stack, pops = 0, 0
    local function show(self) rawget(self, "__members").bShowMouseCursor = stack > 0 end
    local reacts = {
        IsA = function() return true end,
        PushUIInput = function(self)
            stack = stack + 1
            show(self)
        end,
        PopUIInput = function(self)
            pops = pops + 1
            stack = math.max(0, stack - 1)
            show(self)
        end,
        ClearUIInput = function(self)
            stack = 0
            show(self)
        end,
    }
    for name, react in pairs(reacts) do fake.react[name] = react end
    show(player)
    local host = ui.Window({ title = "Cursor" })
    ui.Open()
    t.eq(stack, 1, "opening the menu asks the game for the mouse")
    frames(5)
    t.eq(stack, 1, "once")
    -- Alt+Tab: the game puts its escape menu up, and closing that empties the game's whole stack
    player:PushUIInput()
    t.eq(stack, 2)
    player:ClearUIInput()
    t.eq(player.bShowMouseCursor, false)
    t.ok(ui.IsOpen(), "the menu is still open, and has no mouse")
    frames(1)
    t.eq(stack, 1, "the next frame it has it again")
    t.eq(player.bShowMouseCursor, true)
    frames(5)
    t.eq(stack, 1)
    t.eq(ui.stats().cursor, true)
    ui.Close()
    t.eq(stack, 0, "closing the menu gives the mouse back")
    t.eq(pops, 1)
    -- emptied and closed in the same frame: nothing of the menu's is left to take off
    ui.Open()
    player:ClearUIInput()
    ui.Close()
    t.eq(pops, 1, "nothing is popped from a stack the game has emptied")
    t.eq(stack, 0)
    -- a screen of the game's own opens while the menu is up: the game empties its stack and puts its own entry there
    local screen = nil
    local real_screen = input.screen
    input.screen = function() return screen end
    ui.Open()
    t.eq(stack, 1)
    player:ClearUIInput()
    player:PushUIInput()
    screen = "UMG_MainMenu 1"
    frames(3)
    t.eq(stack, 1, "the game's entry shows the mouse, so the menu asks for nothing")
    ui.Close()
    t.eq(stack, 1, "the entry on top is the game's now: closing the menu leaves it where it is")
    t.eq(player.bShowMouseCursor, true, "and the game's screen keeps its mouse")
    t.eq(pops, 1)
    -- opened over a screen that was there already, the menu's entry is the top one and comes off again
    ui.Open()
    t.eq(stack, 2)
    frames(3)
    ui.Close()
    t.eq(stack, 1)
    t.eq(pops, 2)
    -- the game's screen closes while the menu is up, and the menu is closed afterwards
    ui.Open()
    player:ClearUIInput()
    screen = nil
    frames(1)
    t.eq(stack, 1, "the mouse is taken again")
    ui.Close()
    t.eq(stack, 0, "and given back: that entry was the menu's")
    input.screen = real_screen
    -- the same for a menu a mod opened without windows
    local browser = mod("Browser")
    scope.run(browser.scope, function() ui.Open({ windows = false }) end)
    t.eq(stack, 1)
    player:ClearUIInput()
    frames(1)
    t.eq(stack, 1)
    scope.run(browser.scope, ui.Close)
    t.eq(stack, 0)
    for name in pairs(reacts) do fake.react[name] = nil end
    browser.scope:destroy()
    host:Destroy()
    Wax.game = nil
end)

t.test("a game that takes the mouse back every frame is asked for it a few times, not for ever", function()
    local player = fake.new_object("PlayerController")
    Wax.game = { LocalPlayer = { Raw = player } }
    local pushes = 0
    local reacts = {
        IsA = function() return true end,
        PushUIInput = function(self)
            pushes = pushes + 1
            rawget(self, "__members").bShowMouseCursor = true
        end,
        PopUIInput = function(self) rawget(self, "__members").bShowMouseCursor = false end,
    }
    for name, react in pairs(reacts) do fake.react[name] = react end
    rawget(player, "__members").bShowMouseCursor = false
    local host = ui.Window({ title = "Fight" })
    ui.Open()
    t.eq(pushes, 1)
    for _ = 1, 600 do
        rawget(player, "__members").bShowMouseCursor = false
        frames(1)
    end
    t.eq(pushes, 6, "the first time, then five more tries a while apart")
    -- closing and opening the menu starts afresh
    ui.Close()
    ui.Open()
    t.eq(pushes, 7)
    rawget(player, "__members").bShowMouseCursor = false
    frames(1)
    t.eq(pushes, 8)
    -- a mouse that is kept for a while and then lost once more is taken again at once
    frames(200)
    rawget(player, "__members").bShowMouseCursor = false
    frames(1)
    t.eq(pushes, 9)
    ui.Close()
    for name in pairs(reacts) do fake.react[name] = nil end
    host:Destroy()
    Wax.game = nil
end)

t.test("the Mods page: a mod from the catalogue has its own Auto Update on its card, and a mod with a window its Open key", function()
    local panel = Wax.import("gui.debug")
    local player = fake.new_object("PlayerController")
    Wax.game = { LocalPlayer = { Raw = player } }
    ui.Notifications.Clear()
    local hello = mod("Hello", "Hello")
    local state = { available = {}, installing = {}, checking = false, last = 0, look = true, auto = true, mods = {} }
    local switched = {}
    Wax.update = {
        state = function() return state end,
        set_auto = function(id, on)
            switched[#switched + 1] = tostring(id) .. "=" .. tostring(on)
            if state.mods[id] then state.mods[id].auto = on end
        end,
        set_looking = function(on) state.look = on end,
        check_now = function() return true end,
        install = function() return true end,
    }
    local refresh = panel.refresh       -- what the panel does by itself every half second
    local before = fake.mark()
    panel.start()
    ui.SetPreview(true)
    refresh()
    local shown = panel.updates
    t.eq(shown.switch, nil, "the one switch for every mod is gone")
    t.ok(shown.look and shown.check and shown.line, "looking for updates and asking now are still there")
    local card = panel.card("Hello")
    t.ok(card, "the mod has its card")
    t.eq(card.auto, nil, "a mod that did not come from the catalogue has no such switch")
    t.eq(card.keybind, nil, "and a mod without a window has no key")

    -- the updater learns that the mod came from the catalogue
    state.mods.Hello = { version = "0.1.0", auto = true }
    refresh()
    card = panel.card("Hello")
    t.ok(card.auto, "now its card has the switch")
    t.eq(card.auto:Get(), true)
    click(card.auto.source)
    frames(1)
    t.eq(switched[1], "Hello=false", "the switch tells the updater which mod, and what")
    state.mods.Hello.auto = true
    refresh()
    t.eq(panel.card("Hello").auto:Get(), true, "and follows it when it is changed elsewhere")
    state.mods.Hello.auto = false
    state.available.Hello = "0.2.0"
    refresh()
    t.ok(shown.buttons.Hello, "with its switch off a newer version is still offered, with its button")
    t.eq(panel.card("Hello").auto:Get(), false)
    -- while nothing is looked for the switch does nothing, and says so by being greyed
    state.look = false
    refresh()
    card = panel.card("Hello")
    t.eq(card.auto.disabled, true)
    t.eq(shown.check.disabled, true)
    state.look = true
    refresh()
    t.eq(card.auto.disabled, false)
    -- a card that is built while nothing is looked for starts greyed
    state.look = false
    refresh()
    state.available.Hello = nil
    refresh()
    t.eq(panel.card("Hello").auto.disabled, true)
    state.look = true
    refresh()

    -- the mod makes a window: its card gets the key
    local hello_window
    scope.run(hello.scope, function() hello_window = ui.Window({ title = "Hello window" }) end)
    refresh()
    card = panel.card("Hello")
    t.ok(card.keybind, "now its card has the key")
    t.eq(card.keybind:Get(), ui.Keys.Get("Hello"))
    t.ok(card.auto, "and still its switch")
    click(card.keybind.source)
    t.ok(input.capturing())
    fake.key_pressed = "K"
    frames(1)
    fake.key_pressed = nil
    frames(3)
    t.eq(ui.Keys.Get("Hello"), "K", "the key that was pressed is the mod's key now")
    t.eq(card.keybind:Get(), "K")
    -- a key somebody has: given all the same, and said
    ui.Notifications.Clear()
    click(card.keybind.source)
    fake.key_pressed = "F8"
    frames(1)
    fake.key_pressed = nil
    frames(3)
    t.eq(ui.Keys.Get("Hello"), "F8")
    t.eq(card.keybind:Get(), "F8")
    t.eq(ui.Notifications.Count(), 1)
    -- changed elsewhere, the card follows
    t.eq(ui.Keys.Set("Hello", "L"), true)
    refresh()
    t.eq(panel.card("Hello").keybind:Get(), "L")
    t.ok(rawequal(panel.card("Hello"), card), "without the card being built again")

    -- the Settings page says whose key it is
    local labelled = false
    for _, object in ipairs(fake.made(before)) do
        if rawget(object, "__text") == "Wax panel key" then labelled = true end
        t.ok(rawget(object, "__text") ~= "Menu key", "the old name is gone")
    end
    t.ok(labelled, "the key on the Settings page is named as the key of Wax's panel")

    -- a mod that asks for the panel gets the panel
    ui.SetPreview(false)
    scope.run(hello.scope, panel.Show)
    t.ok(panel.Window():IsShowing(), "the panel is up")
    t.ok(not hello_window:IsShowing(), "and the mod's own window is not")
    ui.Close()

    panel.stop()
    Wax.update = nil
    hello.scope:destroy()
    ui.Notifications.Clear()
    Wax.game = nil
end)

local function header_of(dropdown) return fake.last(dropdown.parts.label, "SetText")[2]:ToString() end
local function scale_of(box) return fake.last(box, "SetUserSpecifiedScale")[2] end

t.test("the game's window changes size: what Wax draws follows at once, and mods are told once, when it has stopped", function()
    local real_clock, now = sched.clock, sched.clock()
    sched.clock = function() return now end
    local function pass(seconds, count)
        count = count or 1
        for _ = 1, count do
            now = now + seconds / count
            frames(1)
        end
    end
    fake.set_screen(1920, 1080, 1)
    pass(1, 4)
    local gui_root = Wax.import("gui.root")
    local host_scope = scope.new("resize")
    local window, panel, plain, sizes
    local asked, resized = 0, {}
    scope.run(host_scope, function()
        window = ui.Window({ title = "Resize", x = 1500, y = 600, width = 300, height = 200 })
        ui.AddSettings(window)
        sizes = window.controls[#window.controls]
        -- a panel that spans the room beside a column 300 wide, and is drawn smaller on a lower screen
        panel = ui.Panel({ anchor = "top-left", width = 1, place = function(wide, high)
            asked = asked + 1
            return { x = 2, y = 3, width = wide - 300, height = 100, zoom = high / 1080 }
        end })
        panel.Resized:Connect(function(wide, high) resized[#resized + 1] = { wide, high } end)
        plain = ui.Overlay({ anchor = "top-left", width = 200 })
    end)
    t.eq(asked, 1, "the place function is asked when the panel is made")
    t.eq(panel.width, 1620)
    t.eq(panel.x, 2)
    local told = {}
    local listening = ui.ScreenChanged:Connect(function(width, height) told[#told + 1] = { width, height } end)
    t.eq(window.slot:GetPosition().X, 1500)
    t.eq(header_of(sizes), "100%")

    -- dragged narrower, a little each frame: 40 steps from 1920 wide to 1440
    fake.set_screen(1908, 1080, 1)
    pass(2 / 60, 2)
    for step = 2, 40 do
        local width = 1920 - step * 12
        fake.set_screen(width, 1080, 1)
        pass(1 / 60)
        if window.slot:GetPosition().X ~= math.min(1500, width - 80) then
            error(("at %d wide the window is drawn at %s"):format(width, tostring(window.slot:GetPosition().X)))
        end
        if panel.width ~= width - 300 or fake.last(panel.sizers[1], "SetWidthOverride")[2] ~= width - 300 then
            error(("at %d wide the placed panel is %s wide"):format(width, tostring(panel.width)))
        end
    end
    t.eq(window.slot:GetPosition().X, 1360, "the window stayed on the screen in every frame")
    t.eq(window.x, 1500, "and its own place is kept")
    t.eq(window.slot:GetSize().X, 300, "at the size it had")
    t.eq(asked, 41, "the place function was asked once for every size, and at no other time")
    t.eq(#resized, 40, "and the panel said its new size each time")
    t.eq(resized[40][1], 1140)
    t.eq(#told, 0, "nobody is told while the size is changing")
    pass(0.3, 6)
    t.eq(#told, 0, "nor straight after")
    pass(0.2, 6)
    t.eq(#told, 1, "once it has stayed as it is for a moment, mods are told")
    t.eq(told[1][1], 1440)
    t.eq(told[1][2], 1080)
    pass(2, 20)
    t.eq(#told, 1, "once")

    -- wider again: the window goes back to where the player had it
    fake.set_screen(1920, 1080, 1)
    pass(2 / 60, 2)
    t.eq(window.slot:GetPosition().X, 1500)
    pass(0.5, 6)
    t.eq(#told, 2)

    -- smaller with the same shape: below what text can be read at, the interface size goes up, at once and not in steps
    fake.set_screen(960, 540, 0.5)
    pass(2 / 60, 2)
    t.eq(ui.GetScale(), 1.8)
    t.eq(window.slot:GetSize().X, 540, "the window is drawn at the new size")
    t.eq(scale_of(plain.outer), 1.8, "and so is an overlay")
    t.ok(math.abs(scale_of(panel.outer) - 1) < 1e-9, "a placed panel is asked again: here it stays as large on the screen as it was")
    fake.set_screen(1280, 720, 2 / 3)
    pass(1 / 60)
    t.ok(math.abs(ui.GetScale() - 1.35) < 1e-9, "every size on the way is followed")
    fake.set_screen(960, 540, 0.5)
    pass(1 / 60)
    t.eq(#told, 2)
    pass(0.5, 6)
    t.eq(#told, 3, "the screen is another size in the units mods lay out in, so they are told")
    t.eq(header_of(sizes), "200%", "the Settings page shows the size in use, from the sizes this screen can show")
    t.eq(sizes:Get(), "200%")

    -- a window with no real size (minimised, or a sliver) changes nothing
    fake.set_screen(160, 28, 0.444)
    pass(1, 40)
    t.eq(ui.GetScale(), 1.8)
    t.eq(#told, 3)
    fake.set_screen(1920, 1080, 1)
    pass(1, 40)
    t.eq(ui.GetScale(), 1)
    t.eq(header_of(sizes), "100%")
    t.eq(#told, 4)

    -- the interface size changed by the player is told the same way
    click(sizes.source)
    click(sizes.items["125%"])
    t.eq(ui.GetScale(), 1.25)
    t.eq(header_of(sizes), "125%")
    t.eq(#told, 4)
    pass(0.5, 6)
    t.eq(#told, 5)
    t.eq(told[5][1], 1536)
    ui.SetScale(1)
    t.eq(header_of(sizes), "100%", "a size set from code shows on the Settings page too")
    pass(0.5, 6)
    t.eq(#told, 6)

    -- a mod that asked for the size in the middle of a change is told when the change ends, even where it ends where it began
    fake.set_screen(1600, 1080, 1)
    pass(2 / 60, 2)
    t.eq(ui.ScreenSize(), 1600)
    fake.set_screen(1920, 1080, 1)
    pass(0.5, 6)
    t.eq(#told, 7)
    t.eq(told[7][1], 1920)

    listening:Disconnect()
    host_scope:destroy()
    sched.clock = real_clock
end)

t.test("a text block that is given a room shows its text whole, in smaller letters, or cut with dots, and never wider than its room", function()
    local kit = Wax.import("gui.kit")
    local label = kit.label("5-10", { size = 10 })
    local info = kit.labels()[label]
    t.eq(kit.rule(info), nil, "a text block nobody has given a rule has none")
    t.eq(kit.fit(label, 33, { sizes = { 10, 9, 8 } }), false)
    t.eq(kit.rule(info), "fitted")
    t.eq(info.shown, "5-10")
    t.eq(info.drawn, 10)
    t.eq(kit.set_text(label, "10-20"), false)
    t.eq(info.shown, "10-20")
    t.eq(info.drawn, 8, "a longer text is drawn smaller before it is cut")
    t.eq(fake.last(label, "SetFont")[2].Size, 8)
    t.eq(kit.set_text(label, "100-200"), true, "one too long for the smallest size is cut")
    t.eq(info.shown:sub(-3), "...")
    t.ok(kit.text_width(info.shown, info.drawn) <= 33, info.shown)
    t.eq(kit.whole(label), "100-200", "and its whole text is there for a tip")
    t.eq(kit.said(label), "100-200")
    t.eq(kit.set_text(label, "7"), false)
    t.eq(info.drawn, 10, "a short text is back at the full size")
    t.eq(kit.whole(label), nil)
    -- every line of a text of several lines is cut on its own
    local lines = kit.label("Health\nThe longest name a thing could have\nJog")
    t.eq(kit.fit(lines, 70), true)
    local shown = {}
    for line in (kit.labels()[lines].shown .. "\n"):gmatch("([^\n]*)\n") do shown[#shown + 1] = line end
    t.eq(shown[1], "Health")
    t.eq(shown[2]:sub(-3), "...")
    t.eq(shown[3], "Jog")
    -- more room, and the text is whole again
    t.eq(kit.fit(lines, 400), false)
    t.eq(kit.labels()[lines].shown, "Health\nThe longest name a thing could have\nJog")
    -- no room given: it is as wide as its text, and says so
    kit.fit(lines, nil)
    t.eq(kit.rule(kit.labels()[lines]), "free")
    t.eq(kit.rule(kit.labels()[kit.label("x", { wrap = true })]), "wraps")
    -- the two that mods can ask
    t.eq(ui.TextWidth("5-10"), kit.text_width("5-10"))
    local cut_text, was_cut = ui.Shorten("A very long name of a thing", 60)
    t.eq(was_cut, true)
    t.ok(ui.TextWidth(cut_text) <= 60, cut_text)
end)

t.test("a pair of labels in a row, names at the left and figures at the right, several lines each: what fits is whole, and a line too long is the only one cut", function()
    local kit = Wax.import("gui.kit")
    local host
    local host_scope = scope.new("pairs")
    scope.run(host_scope, function() host = ui.Panel({ anchor = "top-left", width = 224, padding = 6, when = "always" }) end)
    local function lines_of(text)
        local out = {}
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
        return out
    end
    for _, split in ipairs({ { 3, 2 }, { 1, 1 }, { 2, 3 } }) do
        local before = #text_blocks
        local pair = host:Row()
        local names = pair:Label("", { weight = split[1] })
        local values = pair:Label("", { align = "right", weight = split[2] })
        local left, right = text_blocks[before + 1].info, text_blocks[before + 2].info
        -- the creature page as the owner had it: eight lines, every one with room to spare
        local said_names = "Health\nWalk\nJog\nRun\nSprint\nAttacking\nSight\nHearing"
        local said_values = "325\n2.2 m/s\n4.4 m/s\n6.6 m/s\n12 m/s\n4.4 m/s\n50 m\n25 m"
        names:Set(said_names)
        values:Set(said_values)
        t.eq(left.shown, said_names, "every name is whole")
        t.eq(right.shown, said_values, "and every figure")
        t.eq(left.cut, false)
        t.eq(right.cut, false)
        t.eq(kit.rule(left), "fitted")
        -- one name too long for its share: that line ends in dots, the others are as they were, and no line is lost
        names:Set("Health\nMovement speed while sprinting downhill in the rain\nJog")
        values:Set("325\n12.5 m/s\n4.4 m/s")
        local shown = lines_of(left.shown)
        t.eq(#shown, 3, "the names keep their three lines, so each figure stays beside its name")
        t.eq(shown[1], "Health")
        t.eq(shown[2]:sub(-3), "...")
        t.eq(shown[3], "Jog")
        t.eq(right.shown, "325\n12.5 m/s\n4.4 m/s")
        t.eq(#lines_of(right.shown), 3)
        -- and whole again when the long one is gone
        names:Set("Health\nWalk\nJog")
        t.eq(left.shown, "Health\nWalk\nJog")
        t.eq(left.cut, false)
    end
    host_scope:destroy()
end)

t.test("a text that is close to its room is decided by the game's own measure of it: what fits is never cut, and what does not is never left whole", function()
    local kit = Wax.import("gui.kit")
    local label = kit.label("Bestiary")
    local worked_out = kit.text_width("Bestiary")
    local says, asked = nil, 0
    local real = fake.react.GetDesiredSize
    fake.react.GetDesiredSize = function(self)
        if rawequal(self, label) then
            asked = asked + 1
            return { X = says, Y = 19 }
        end
        return { X = 120, Y = 48 }
    end
    kit.MEASURE = true
    -- plenty of room, and far too little: the letters say so, and the game is not asked
    t.eq(kit.fit(label, worked_out * 2), false)
    t.eq(kit.fit(label, worked_out * 0.5), true)
    t.eq(asked, 0)
    -- a room two percent under what the letters add up to: the game says the text is narrower than that, so it is whole
    says = worked_out * 0.97
    t.eq(kit.fit(label, worked_out * 0.98), false, "it fits, so it is not cut")
    t.eq(kit.labels()[label].shown, "Bestiary")
    t.eq(asked, 1)
    -- a room two percent over: the game says the text is wider still, so it is cut with dots
    says = worked_out * 1.04
    t.eq(kit.fit(label, worked_out * 1.02), true, "it does not fit, so it is not left to be cut mid-letter")
    t.eq(kit.labels()[label].shown:sub(-3), "...")
    t.eq(asked, 2)
    -- a text block that is not built yet cannot be measured: the letters decide
    says = 0
    t.eq(kit.fit(label, worked_out * 1.02), false)
    t.eq(kit.fit(label, worked_out * 0.98), true)
    kit.MEASURE = false
    fake.react.GetDesiredSize = real
end)

t.test("a slot's count stays in its cell: smaller letters for a long one, dots for one too long, and the whole count beside the mouse", function()
    local kit = Wax.import("gui.kit")
    local slots = Wax.import("gui.slots")
    local tip = Wax.import("gui.tip")
    local host
    local host_scope = scope.new("counts")
    scope.run(host_scope, function() host = ui.Panel({ anchor = "top-left", width = 400, when = "always" }) end)
    local before = #text_blocks
    local row = host:Slots({ columns = 4, rows = 1, size = 36, gap = 2 })
    frames(3)
    row:Set({ { icon = "home", count = "5-10", value = 1 }, { icon = "home", count = "10-20", value = 2 },
        { icon = "home", count = "100-200", value = 3, tip = "Stone" }, { icon = "home", count = "x1000", value = 4 } })
    local counts = {}
    for index = before + 1, #text_blocks do counts[text_blocks[index].info.text] = text_blocks[index].info end
    local room = 36 - slots.COUNT_EDGE
    for _, text in ipairs({ "5-10", "10-20", "100-200", "x1000" }) do
        local info = counts[text]
        t.ok(info, "the count " .. text .. " is a text block")
        t.eq(kit.rule(info), "fitted")
        t.ok(kit.text_width(info.shown, info.drawn) <= room, text .. " shows as " .. info.shown .. " at size " .. info.drawn)
    end
    t.eq(counts["5-10"].shown, "5-10")
    t.eq(counts["5-10"].drawn, 10)
    t.eq(counts["10-20"].shown, "10-20")
    t.ok(counts["10-20"].drawn < 10, "the longer count is drawn smaller")
    t.eq(counts["x1000"].shown, "x1000")
    t.eq(counts["100-200"].cut, true, "seven letters do not fit a cell of 36")
    t.eq(counts["100-200"].shown:sub(-3), "...")
    -- a larger cell: the same counts again, whole where they now fit
    row:SetLayout(4, 60)
    t.eq(counts["100-200"].shown, "100-200")
    t.eq(counts["100-200"].cut, false)
    t.eq(counts["10-20"].drawn, 10)
    row:SetLayout(4, 36)
    t.eq(counts["100-200"].cut, true)
    -- the whole count goes under a slot's own tip, or stands alone
    t.eq(tip.plus(nil, "100-200"), "100-200")
    local both = tip.plus("Stone", "100-200")()
    t.eq(both.title, "Stone")
    t.eq(both.lines[1][1], "100-200")
    local more = tip.plus(function() return { title = "Stone", lines = { "a rock" } } end, "100-200")()
    t.eq(#more.lines, 2)
    t.eq(more.lines[2][1], "100-200")
    host_scope:destroy()
end)

t.test("one-line text in a control has the room the control has: a caption, a label in a row and a dropdown's header are cut with dots, never mid-letter", function()
    local kit = Wax.import("gui.kit")
    local host
    local host_scope = scope.new("room")
    scope.run(host_scope, function() host = ui.Window({ title = "A window with a very long title that cannot fit its bar", width = 340, height = 300 }) end)
    local before = #text_blocks
    local long = "A caption that is much too long for the button it is on in this window"
    local button, label, natural, tab
    scope.run(host_scope, function()
        button = host:Button(long, function() end)
        local row = host:Row()
        natural = row:Button("Check now", function() end, { icon = "refresh-cw", stretch = false })
        label = row:Label("Last checked a very long time ago, longer than this row is wide")
        local tabs = host:Row()
        tab = tabs:Button("About", function() end, { tab = true })
        tabs:Button("Drops", function() end, { tab = true })
    end)
    local by_text = {}
    for index = before + 1, #text_blocks do by_text[text_blocks[index].info.text] = text_blocks[index].info end
    local caption = by_text[long]
    t.eq(caption.cut, true)
    t.eq(caption.shown:sub(-3), "...")
    t.ok(kit.text_width(caption.shown) <= 340 - 26 - 32, caption.shown)
    t.eq(by_text["Check now"].cut, false, "a button that keeps its own width shows its caption whole")
    local said = by_text["Last checked a very long time ago, longer than this row is wide"]
    t.eq(said.cut, true, "the label beside it has what the button leaves")
    t.eq(by_text["About"].cut, false)
    -- the title of the window is one line in its bar
    local title = kit.labels()[host.title_label]
    t.eq(title.cut, true)
    t.eq(title.shown:sub(-3), "...")
    -- a wider window: everything is whole again, and a new caption is fitted like the first
    host:SetSize(900, 300)
    t.eq(caption.cut, false)
    t.eq(caption.shown, long)
    t.eq(said.cut, false)
    t.eq(title.cut, false)
    button:SetCaption("Short")
    t.eq(caption.shown, "Short")
    host:SetSize(340, 300)
    button:SetCaption(long)
    t.eq(caption.cut, true)
    host_scope:destroy()
end)

t.test("a row of slots can be set out again with another number of cells and another cell size: no cell is made twice", function()
    local host
    local host_scope = scope.new("reflow")
    scope.run(host_scope, function() host = ui.Panel({ anchor = "top-left", width = 400, when = "always" }) end)
    local row = host:Slots({ columns = 4, rows = 1, size = 30, gap = 2 })
    frames(3)
    t.ok(row:Ready())
    row:Set({ { icon = "home", value = 1 }, { icon = "home", value = 2 }, { icon = "home", value = 3 }, { icon = "home", value = 4 } })
    local made = fake.objects
    row:SetLayout(3, 34)
    t.eq(row:Capacity(), 3)
    t.eq(row:GetLook(4), nil, "what no longer has a cell is not kept")
    t.eq(row:GetLook(3).value, 3)
    t.eq(fake.last(row.widget, "SetWidthOverride")[2], 3 * 34 + 2 * 2, "the row is as wide as its cells")
    row:SetLayout(6, 32)
    t.eq(row:Capacity(), 6)
    t.ok(not row:Ready(), "the cells that are missing are made over the next frames")
    frames(3)
    t.ok(row:Ready())
    row:SetLayout(6, 32)
    row:SetLayout(4, 30)
    t.eq(row:Capacity(), 4)
    t.eq(fake.dead_touches, 0)
    host_scope:destroy()
    t.ok(made > 0)
end)

t.test("a held row passes another once its leading edge is over that row's middle, and the rows between give way by its height", function()
    local drag = Wax.import("gui.drag")
    local heights = { 40, 40, 100, 40 }
    t.eq(drag.target(heights, 8, 1, 0), 1)
    t.eq(drag.target(heights, 8, 1, 28), 1, "the gap and half of the next row: not past it yet")
    t.eq(drag.target(heights, 8, 1, 29), 2)
    t.eq(drag.target(heights, 8, 1, 106), 2, "a tall row is passed at its own middle")
    t.eq(drag.target(heights, 8, 1, 107), 3)
    t.eq(drag.target(heights, 8, 1, 5000), 4, "never past the end")
    t.eq(drag.target(heights, 8, 4, -58), 4)
    t.eq(drag.target(heights, 8, 4, -59), 3)
    t.eq(drag.target(heights, 8, 4, -5000), 1)
    local offset, give = drag.landing(heights, 8, 1, 3)
    t.eq(offset, 156, "it lands below the two rows it passed")
    t.eq(give, -48, "and each of them moves up by its height and the gap")
    offset, give = drag.landing(heights, 8, 4, 2)
    t.eq(offset, -156)
    t.eq(give, 48)
    offset, give = drag.landing(heights, 8, 2, 2)
    t.eq(offset, 0)
    t.eq(give, 0)
end)

t.test("a slot that is held and moved is dragged: its picture follows the mouse, and letting go is not a click", function()
    local slots, layer = Wax.import("gui.slots"), Wax.import("gui.root").layer("toasts")
    local host
    local host_scope = scope.new("shelf")
    scope.run(host_scope, function() host = ui.Panel({ anchor = "top-left", width = 400, when = "always" }) end)
    local row = host:Slots({ columns = 4, rows = 1, size = 30, gap = 2, drag = true })
    frames(3)
    row:Set({ { icon = "home", value = "a" }, { icon = "home", value = "b" } })
    local seen = { moved = 0, clicks = 0 }
    row.DragStarted:Connect(function(value, index) seen.started = value .. index end)
    row.DragMoved:Connect(function(dx, dy) seen.moved, seen.dx, seen.dy = seen.moved + 1, dx, dy end)
    row.DragEnded:Connect(function(dx, dy) seen.ended = { dx, dy } end)
    row.Activated:Connect(function() seen.clicks = seen.clicks + 1 end)
    local floats = fake.count(layer, "AddChild")
    local function drag_once()
        fake.hovered, fake.mouse.X, fake.mouse.Y = true, 100, 100
        frames(1)
        fake.pressed = true
        frames(1)
        fake.mouse.X = 100 + slots.DRAG_AFTER
        frames(1)
        t.eq(slots.dragging(), false, "not further than the threshold: still a press")
        fake.mouse.X = 120
        frames(1)
        t.eq(slots.dragging(), true)
        fake.mouse.X, fake.mouse.Y = 130, 110
        frames(1)
        fake.pressed = false
        frames(2)
    end
    drag_once()
    t.eq(seen.started, "a1", "the cell under the mouse, with its value and its place")
    t.ok(seen.moved >= 1)
    t.eq(seen.dx, 30, "how far the mouse is from where the button went down")
    t.eq(seen.dy, 10)
    t.eq(seen.ended[1], 30)
    t.eq(seen.ended[2], 10)
    t.eq(seen.clicks, 0, "letting go after a drag is not a click")
    t.eq(slots.dragging(), false)
    t.eq(fake.count(layer, "AddChild"), floats + 1, "the picture under the mouse is one widget over everything else")
    seen.started = nil
    drag_once()
    t.eq(seen.started, "a1")
    t.eq(fake.count(layer, "AddChild"), floats + 1, "and the same one the next time")
    -- held and let go without moving is a click, as before
    fake.pressed = true
    frames(1)
    fake.pressed = false
    frames(1)
    t.eq(seen.clicks, 1)
    fake.hovered = nil
    frames(1)
    host_scope:destroy()
    t.eq(fake.dead_touches, 0)
end)

do
    local style, drag, kit = Wax.import("gui.style"), Wax.import("gui.drag"), Wax.import("gui.kit")
    local names = { Axx = "Alpha", Byy = "Beta", Axz = "Gamma" }
    local order, moves, extra, real_list
    local panel, mods_window, before

    -- The Mods page over a list the test holds: three mods, moved one place at a time as the loader does.
    local function open_mods(ids)
        panel = Wax.import("gui.debug")
        order, moves, extra, real_list = ids or { "Axx", "Byy", "Axz" }, {}, {}, Wax.mods.list
        Wax.mods.list = function()
            local list = {}
            for index, id in ipairs(order) do
                list[index] = { id = id, name = names[id], version = "1.0.0", status = "loaded", generation = extra[id] or 1 }
            end
            return list
        end
        Wax.mods.move = function(id, by)
            for index, other in ipairs(order) do
                if other == id and order[index + by] then
                    order[index], order[index + by] = order[index + by], order[index]
                    moves[#moves + 1] = id .. (by > 0 and "+" or "-")
                    return true
                end
            end
            return false
        end
        before = fake.mark()
        panel.start()
        ui.SetPreview(true)
        panel.refresh()
        mods_window = panel.Window()
        t.eq(style.scale, 1)
    end
    local function close_mods()
        fake.pressed = false
        ui.SetPreview(false)
        panel.stop()
        Wax.mods.list, Wax.mods.move = real_list, nil
        -- everything the page made is freed with the window, and nothing of it is used afterwards
        fake.free(before, fake.mark())
        local touches = fake.dead_touches
        frames(3)
        panel.step()
        t.eq(fake.dead_touches, touches, fake.dead_where)
    end
    -- The grip of a card goes down with the mouse at x, y, and the mouse then goes to each place given, a frame at a time.
    local function pick_up(id, x, y, ...)
        fake.mouse.X, fake.mouse.Y = x, y
        events.simulate(panel.card(id).grip, "OnPressed")
        fake.pressed = true
        panel.step()
        for _, to in ipairs({ ... }) do
            fake.mouse.X, fake.mouse.Y = to[1], to[2]
            panel.step()
            panel.step()
        end
        return drag.sorting()
    end
    local function let_go()
        fake.pressed = false
        panel.step()
    end
    local function shift_of(id)
        local last = fake.last(panel.card(id).control.widget, "SetRenderTranslation")
        return last and last[2].Y or 0
    end
    local function opacity_of(id)
        local last = fake.last(panel.card(id).control.widget, "SetRenderOpacity")
        return last and last[2] or 1
    end
    local real_icon, real_perf = kit.icon, Wax.perf
    -- One test of the Mods page. A test that fails still takes its page down, so the next one starts clean.
    local function mods_test(name, body)
        t.test(name, function()
            local ok, problem = xpcall(body, debug.traceback)
            if ok then return end
            kit.icon, Wax.perf = real_icon, real_perf
            fake.react.SetScrollOffset, fake.react.GetDesiredSize, fake.scroll_offset, fake.scroll_end = nil, nil, nil, nil
            pcall(close_mods)
            error(problem, 0)
        end)
    end

    mods_test("a mod's card is dragged by the grip at the left of its title: the others give way, and where it is let go is saved", function()
        local icons = {}
        kit.icon = function(name, ...)
            icons[name] = (icons[name] or 0) + 1
            return real_icon(name, ...)
        end
        open_mods()
        kit.icon = real_icon
        t.eq(icons["wax-dots"], 3, "every card has a grip: six dots")
        t.eq(icons["grip-vertical"], nil)
        t.eq(icons["arrow-up"], nil, "and the two arrows are gone")
        t.eq(icons["arrow-down"], nil)
        local first = panel.card("Axx")
        t.eq(fake.last(first.grip, "SetCursor")[2], style.Cursor.Move)
        t.eq(fake.last(first.section.parts.chevron.Slot, "SetPadding")[2].Left, 12, "the arrow and the title make room for it")
        t.eq(fake.last(first.grip, "SetVisibility")[2], style.Visibility.Visible)

        -- a press without a move does nothing
        t.eq(pick_up("Axx", 230, 200), nil)
        t.eq(pick_up("Axx", 230, 200, { 233, 204 }), nil, "a few units are not a drag")
        let_go()
        t.eq(#moves, 0)
        t.eq(fake.count(first.control.widget, "SetRenderOpacity"), 0, "the card was never touched")

        -- 40 down is past the middle of the next card (the gap of 8 and half of 48)
        local held = pick_up("Axx", 230, 200, { 230, 240 })
        t.ok(held, "held and moved, the card is being dragged")
        t.eq(held.at, 2)
        t.eq(opacity_of("Axx"), 0, "the card itself is not drawn while it is held")
        t.eq(shift_of("Byy"), -56, "the card it passed moves up by one card and one gap")
        t.eq(shift_of("Axz"), 0)
        local place = held.float.slot:GetPosition()
        t.eq(place.X, mods_window.at_x + mods_window.nav_width + style.theme.padding, "what is drawn for it stands in the cards' own column")
        t.eq(place.Y, 200 - 24 + 40, "and has gone as far as the mouse")
        t.eq(fake.last(held.float.outer, "SetVisibility")[2], style.Visibility.HitTestInvisible)
        t.eq(rawget(fake.last(held.float.title, "SetText")[2], "__text"), "Alpha  1.0.0", "it shows the card's title")
        -- back up again: the card that gave way goes home
        fake.mouse.Y = 205
        panel.step()
        t.eq(held.at, 1)
        t.eq(shift_of("Byy"), 0)
        -- past both
        fake.mouse.Y = 300
        panel.step()
        t.eq(held.at, 3)
        t.eq(shift_of("Byy"), -56)
        t.eq(shift_of("Axz"), -56)
        -- the list is not built again under a card that is held
        local second = panel.card("Byy")
        extra.Byy = 2
        panel.refresh()
        t.ok(rawequal(panel.card("Byy"), second), "a mod that reloaded meanwhile waits for the drag to end")
        t.eq(#moves, 0, "nothing is saved before it is let go")
        let_go()
        t.eq(table.concat(moves, " "), "Axx+ Axx+", "let go at the end of the list: two places down")
        t.eq(table.concat(order, " "), "Byy Axz Axx")
        t.eq(drag.sorting(), nil)
        t.eq(first.control.destroyed, true, "the cards are built again in the new order")
        t.ok(not rawequal(panel.card("Byy"), second))
        t.eq(fake.last(held.float.outer, "SetVisibility")[2], style.Visibility.Collapsed, "and what was drawn for the held one is gone")
        t.eq(opacity_of("Axx"), 1)

        -- and back up to the top, from where it stands now
        pick_up("Axx", 230, 300, { 230, 180 })
        let_go()
        t.eq(table.concat(moves, " "), "Axx+ Axx+ Axx- Axx-")
        t.eq(table.concat(order, " "), "Axx Byy Axz")
        close_mods()
    end)

    mods_test("a card that is held goes back where it was: asked to, let go outside the list, or kept there by the loader", function()
        open_mods()
        local card = panel.card("Axx")
        local held = pick_up("Axx", 230, 200, { 230, 240 })
        t.eq(held.at, 2)
        t.eq(drag.cancel(), true, "the Escape key asks this: true says the key has done its work")
        panel.step()
        t.eq(drag.sorting(), nil)
        t.eq(drag.cancel(), false, "with nothing held the key is free for the menu")
        t.eq(#moves, 0)
        t.eq(opacity_of("Axx"), 1)
        t.eq(shift_of("Byy"), 0)
        t.ok(rawequal(panel.card("Axx"), card), "no card was built again")
        -- the button is still down: nothing follows it any more
        fake.mouse.Y = 320
        panel.step()
        t.eq(drag.sorting(), nil)
        let_go()

        -- let go to the left of the list, over the page names
        held = pick_up("Axx", 230, 200, { 230, 240 }, { mods_window.at_x + 20, 240 })
        t.eq(held.at, 2, "the mouse may leave the list while the button is down")
        let_go()
        t.eq(drag.sorting(), nil)
        t.eq(#moves, 0)
        t.eq(opacity_of("Axx"), 1)

        -- the loader keeps a mod after the ones it needs: the card goes back, and the player is told why
        ui.Notifications.Clear()
        Wax.mods.move = function(id, by)
            moves[#moves + 1] = id .. (by > 0 and "+" or "-")
            return true
        end
        pick_up("Axx", 230, 200, { 230, 240 })
        let_go()
        t.eq(table.concat(moves, " "), "Axx+")
        t.eq(ui.Notifications.Count(), 1)
        ui.Notifications.Clear()
        frames(2)
        t.ok(rawequal(panel.card("Axx"), card), "the list is as it was, so no card is built again")
        t.eq(opacity_of("Axx"), 1)
        t.eq(shift_of("Byy"), 0)

        -- the menu closes under a held card
        held = pick_up("Axx", 230, 200, { 230, 240 })
        t.ok(held)
        ui.SetPreview(false)
        panel.step()
        t.eq(drag.sorting(), nil)
        t.eq(opacity_of("Axx"), 1)
        t.eq(shift_of("Byy"), 0)
        ui.SetPreview(true)
        close_mods()
    end)

    mods_test("an open card is folded to its title while it is held, and is open again where it is put down", function()
        open_mods()
        local card = panel.card("Byy")
        click(card.control.source)
        t.eq(card.section:IsOpen(), true)
        local held = pick_up("Byy", 230, 200, { 230, 150 })
        t.eq(held.at, 1)
        t.eq(card.section:IsOpen(), false, "folded while it is held")
        drag.cancel()
        panel.step()
        t.eq(card.section:IsOpen(), true, "put back, it is open as it was")
        pick_up("Byy", 230, 200, { 230, 150 })
        let_go()
        t.eq(table.concat(order, " "), "Byy Axx Axz")
        t.eq(panel.card("Byy").section:IsOpen(), true, "put down, its new card is built open")
        t.eq(panel.card("Axx").section:IsOpen(), false)
        close_mods()
    end)

    mods_test("holding a card at the edge of a list longer than the page scrolls it, and what scrolls into view is measured again", function()
        open_mods()
        local clock, scrolls = 100, 0
        Wax.perf = { now = function() return clock end }
        fake.react.SetScrollOffset = function(_, value)
            scrolls = scrolls + 1
            fake.scroll_offset = value
        end
        fake.scroll_offset, fake.scroll_end = 0, 300
        local bottom = mods_window.at_y + mods_window.height - 48
        local held = pick_up("Axx", 230, 200, { 230, 240 })
        t.eq(scrolls, 0, "in the middle of the page nothing scrolls")
        fake.mouse.Y = bottom - 14
        clock = clock + 0.02
        panel.step()
        t.eq(scrolls, 1, "near the bottom edge the list goes down")
        t.ok(math.abs(fake.scroll_offset - 0.5 * drag.SPEED * 0.02) < 1e-6, "half way into the edge, at half the speed")
        fake.mouse.Y = bottom + 200
        clock = clock + 1
        panel.step()
        t.ok(math.abs(fake.scroll_offset - (4.8 + drag.SPEED * 0.05)) < 1e-6, "a long frame scrolls as far as a short one")
        t.ok(math.abs(held.float.slot:GetPosition().Y - (200 - 24 + 2 * 56 - fake.scroll_offset)) < 1e-6,
            "what is drawn for the card goes no lower than the list's last place")
        t.eq(held.at, 3)
        let_go()
        t.eq(#moves, 0, "let go that far below the list, it goes back")
        -- a card above the held one turns out taller once it is seen: the held one's own place is that much lower
        held = pick_up("Axz", 230, 400, { 230, 360 })
        t.eq(held.at, 2)
        fake.react.GetDesiredSize = function(self)
            return { X = 120, Y = rawequal(self, panel.card("Axx").control.widget) and 68 or 48 }
        end
        fake.scroll_offset = fake.scroll_offset + 5
        clock = clock + 0.02
        panel.step()
        t.eq(held.pushed, 20)
        t.eq(held.at, 2)
        fake.react.GetDesiredSize = nil
        let_go()
        t.eq(table.concat(order, " "), "Axx Axz Byy")
        -- at the end of the list there is nowhere to scroll to
        fake.scroll_offset, scrolls = 300, 0
        pick_up("Axx", 230, 200, { 230, bottom - 2 })
        clock = clock + 0.02
        panel.step()
        t.eq(scrolls, 0)
        let_go()
        fake.react.SetScrollOffset, fake.scroll_offset, fake.scroll_end, Wax.perf = nil, nil, nil, real_perf
        close_mods()
    end)

    mods_test("with a search typed the cards that show can still be put in order, and one card alone cannot be dragged", function()
        open_mods()
        local search
        for _, control in ipairs(mods_window.controls) do
            if control.Typed then
                search = control
                break
            end
        end
        search.Typed:Fire("ax")
        t.eq(fake.last(panel.card("Byy").control.widget, "SetVisibility")[2], style.Visibility.Collapsed)
        local held = pick_up("Axx", 230, 200, { 230, 240 })
        t.eq(#held.rows, 2, "only the cards that show take part")
        let_go()
        t.eq(table.concat(order, " "), "Byy Axz Axx", "it goes where the card it passed stands in the whole list")
        -- typing ends a drag at once
        held = pick_up("Axz", 230, 200, { 230, 240 })
        t.ok(held)
        search.Typed:Fire("axx")
        t.eq(drag.sorting(), nil)
        t.eq(opacity_of("Axz"), 1)
        t.eq(fake.last(panel.card("Axx").grip, "SetVisibility")[2], style.Visibility.HitTestInvisible, "one card: its grip takes no press")
        search.Typed:Fire("")
        t.eq(fake.last(panel.card("Axx").grip, "SetVisibility")[2], style.Visibility.Visible)
        -- the page goes away under a held card: nothing of it is used again
        t.ok(pick_up("Axz", 230, 200, { 230, 240 }))
        close_mods()
        t.eq(drag.sorting(), nil)
    end)

    mods_test("a held card stays in its list and is drawn where the mouse is from its first frame, and cards do not flip at a boundary", function()
        open_mods()
        -- the second card, with the mouse 30 below where the button went down by the time it counts as a drag
        fake.mouse.X, fake.mouse.Y = 230, 200
        events.simulate(panel.card("Byy").grip, "OnPressed")
        fake.pressed = true
        panel.step()
        fake.mouse.Y = 230
        panel.step()
        local held = drag.sorting()
        t.ok(held)
        t.eq(held.float.slot:GetPosition().Y, 200 - 24 + 30, "it is drawn where the mouse took it at once, with no jump a frame later")
        -- far above the list: no higher than the first card's place, so it never lies over what stands above the cards
        fake.mouse.Y = -400
        panel.step()
        t.eq(held.float.slot:GetPosition().Y, 200 - 24 - 56, "no higher than the place of the first card")
        t.eq(held.at, 1)
        -- far below: no lower than the last card's place
        fake.mouse.Y = 5000
        panel.step()
        t.eq(held.float.slot:GetPosition().Y, 200 - 24 + 56, "no lower than the place of the last card")
        t.eq(held.at, 3)
        let_go()
        t.eq(#moves, 0, "let go that far from the list, it goes back")

        -- a mouse that rests where two cards change places does not send them back and forth
        held = pick_up("Axx", 230, 200, { 230, 200 + 32 + drag.SLACK + 1 })
        t.eq(held.at, 2)
        fake.mouse.Y = 200 + 32 - drag.SLACK + 1
        panel.step()
        t.eq(held.at, 2, "a little back over the point leaves them as they are")
        fake.mouse.Y = 200 + 32 - drag.SLACK - 1
        panel.step()
        t.eq(held.at, 1, "further back, the card it had passed comes home")
        fake.mouse.Y = 200 + 32 + drag.SLACK - 1
        panel.step()
        t.eq(held.at, 1, "and a little past the point again does not move it")
        drag.cancel()
        panel.step()
        close_mods()
    end)

    mods_test("putting a card down builds nothing again: the cards that are there change places on the page", function()
        open_mods()
        local cards = { Axx = panel.card("Axx"), Byy = panel.card("Byy"), Axz = panel.card("Axz") }
        local box = cards.Axx.control.container.box
        local added = fake.count(box, "AddChild")
        pick_up("Axx", 230, 200, { 230, 300 })
        let_go()
        t.eq(table.concat(order, " "), "Byy Axz Axx")
        for id, card in pairs(cards) do
            t.ok(rawequal(panel.card(id), card), id .. " is the card it was")
            t.ok(not card.control.destroyed, id .. " was not made again")
        end
        t.eq(fake.count(box, "AddChild"), added + 3, "from the first card that changed place on, they were put back on the page in order")
        t.ok(rawequal(fake.last(box, "AddChild")[2], cards.Axx.control.widget), "the card that was put down stands last")
        t.eq(opacity_of("Axx"), 1)
        t.eq(shift_of("Byy"), 0)
        t.eq(shift_of("Axz"), 0)
        -- the next drag starts from the order that shows
        pick_up("Byy", 230, 200, { 230, 240 })
        let_go()
        t.eq(table.concat(order, " "), "Axz Byy Axx")
        t.eq(fake.count(box, "AddChild"), added + 6)
        panel.refresh()
        t.ok(rawequal(panel.card("Axx"), cards.Axx), "and a later look at the mods finds nothing to build")
        close_mods()
    end)

    mods_test("a card's title keeps to one line beside its grip, and the mods folder is looked at when the page comes up and every ten seconds", function()
        names.Axx = "A mod with a name that is much too long to fit on one line of its card"
        open_mods()
        names.Axx = "Alpha"
        local card = panel.card("Axx")
        local shown = card.section.parts.shown
        t.ok(shown:sub(-3) == "..." and #shown < #card.title, "cut with dots: " .. shown)
        t.eq(card.section.parts.before, 12, "the room is what is left beside the grip")
        t.eq(panel.card("Byy").section.parts.shown, "Beta  1.0.0")
        local held = pick_up("Axx", 230, 200, { 230, 240 })
        t.eq(rawget(fake.last(held.float.title, "SetText")[2], "__text"), shown, "what is drawn for it while held shows the same line")
        drag.cancel()
        panel.step()
        -- the folder: not at every look at the page, which was a stutter every two seconds
        local looked = syncs
        for _ = 1, 19 do panel.refresh() end
        t.ok(syncs - looked <= 1)
        looked = syncs
        for _ = 1, 20 do panel.refresh() end
        t.eq(syncs - looked, 1, "once in twenty looks, which is ten seconds")
        mods_window:SelectPage("Log")
        looked = syncs
        for _ = 1, 40 do panel.refresh() end
        t.eq(syncs, looked, "never while another page shows")
        mods_window:SelectPage("Mods")
        t.eq(syncs, looked + 1, "and at once when the Mods page is turned to")

        -- the Performance page's own figures, its moving bar among them, are only written while it shows
        local perf_module, page, bar = Wax.import("core.perf"), nil, nil
        for _, other in ipairs(mods_window.pages) do
            if other.name == "Performance" then page = other end
        end
        for _, control in ipairs(mods_window.controls) do
            if control.container == page and control.Get and control.Set then bar = control end
        end
        t.ok(bar, "the bar of the Performance page")
        local totals, count = perf_module.totals, 0
        perf_module.totals = function()
            count = count + 100
            return { frames = count, seconds = count * 0.01, sections = { gui = count * 0.001 } }
        end
        panel.refresh()
        panel.refresh()
        t.eq(bar:Get(), 0, "not written while the Mods page shows")
        mods_window:SelectPage("Performance")
        panel.refresh()
        t.ok(math.abs(bar:Get() - 0.1) < 1e-6, "written once its page shows: " .. bar:Get())
        perf_module.totals = totals
        close_mods()
    end)
end

do
    local slots, style, fit = Wax.import("gui.slots"), Wax.import("gui.style"), Wax.import("gui.fit")
    local gui_root, overlay_module = Wax.import("gui.root"), Wax.import("gui.overlay")

    -- Every time the game is asked `name` from here on: { object, arguments ... }. The second result ends the watch.
    local function watch(name)
        local default, asked = fake.new_object("probe")[name], {}
        fake.react[name] = function(self, ...)
            asked[#asked + 1] = { self, ... }
            return default(self, ...)
        end
        return asked, function() fake.react[name] = nil end
    end
    -- The objects made since `mark` whose name is that of a widget of this kind.
    local function made_of(mark, kind)
        local out = {}
        for _, object in ipairs(fake.made(mark)) do
            if tostring(rawget(object, "__name")):match("^/Script/UMG%." .. kind .. ":Wax_" .. kind .. "_%d+$") then out[#out + 1] = object end
        end
        return out
    end

    t.test("while no key goes down the game is asked one question about keys a frame, not one for every key", function()
        Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
        local host_scope, ran = scope.new("keys"), 0
        scope.run(host_scope, function()
            ui.Hotkey("R", function() ran = ran + 1 end, { in_menu = true })
            ui.Hotkey("U", function() end, { in_menu = true })
            ui.Hotkey("Ctrl+Three", function() end, { in_menu = true })
        end)
        local asked, stop = watch("WasInputKeyJustPressed")
        frames(3)
        t.eq(#asked, 3, "one question a frame")
        for _, call in ipairs(asked) do t.eq(call[2].KeyName, "AnyKey") end
        fake.keys.R = true
        frames(1)
        fake.keys.R = nil
        t.eq(ran, 1, "the frame a key goes down the keys are asked for by name, and the hotkey runs")
        local named = false
        for _, call in ipairs(asked) do named = named or call[2].KeyName == "R" end
        t.ok(named)
        local count = #asked
        frames(1)
        t.eq(#asked, count + 1, "and the frame after it is one question again")
        stop()
        host_scope:destroy()
        Wax.game = nil
    end)

    t.test("slots: nothing is asked about the mouse while it is over no panel, a row is found before its cells, and a hidden block is not asked", function()
        Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
        local host, host_scope = nil, scope.new("hover")
        scope.run(host_scope, function() host = ui.Panel({ anchor = "top-left", width = 400, when = "always" }) end)
        local mark = fake.mark()
        local grid = host:Slots({ columns = 5, rows = 4, size = 30, gap = 2 })
        local lines = made_of(mark, "HorizontalBox")
        t.eq(#lines, 4)
        mark = fake.mark()
        frames(12)
        t.ok(grid:Ready())
        local buttons = made_of(mark, "Button")
        t.eq(#buttons, 20)
        local looks = {}
        for index = 1, 20 do looks[index] = { icon = "home", value = index } end
        grid:Set(looks)
        local seen = { hovered = 0, right = {} }
        grid.Hovered:Connect(function() seen.hovered = seen.hovered + 1 end)
        grid.RightClicked:Connect(function(value) seen.right[#seen.right + 1] = value end)

        local keep = slots.GRACE
        slots.GRACE = -1
        local asked, over = {}, {}
        fake.react.IsHovered = function(self)
            asked[#asked + 1] = self
            return over[self] == true
        end
        local function count(list)
            local found = 0
            for _, object in ipairs(asked) do
                for _, wanted in ipairs(list) do
                    if rawequal(object, wanted) then found = found + 1 end
                end
            end
            return found
        end
        local released, stop = watch("WasInputKeyJustReleased")
        frames(2)
        t.eq(count({ gui_root.layer("hud") }), 2, "one question a frame: is the mouse over any panel")
        t.eq(count({ host.holder, grid.widget }) + count(lines) + count(buttons), 0, "and nothing else of the panel is asked")
        t.eq(#released, 0, "nor is the game asked about the mouse buttons")

        -- the mouse comes to the 13th cell, in the third row
        over = { [gui_root.layer("hud")] = true, [host.holder] = true, [grid.widget] = true, [lines[3]] = true, [buttons[13]] = true }
        asked = {}
        frames(1)
        t.eq(ui.Hovered(), 13)
        t.eq(seen.hovered, 1)
        t.eq(count(lines), 3, "the rows are asked until the one under the mouse")
        t.eq(count(buttons), 3, "and then that row's cells, not the ten cells before it")
        -- while it rests there, the cell itself is asked first and nothing is looked for
        asked = {}
        frames(1)
        t.eq(count(lines), 0)
        t.eq(count(buttons), 1)
        t.eq(#released, 2, "over a cell the game is asked whether a button came up: one question while none did")
        t.eq(released[1][2].KeyName, "AnyKey")
        fake.released.RightMouseButton = true
        frames(1)
        fake.released.RightMouseButton = nil
        t.eq(seen.right[1], 13, "a right click is the button coming up over the cell")

        -- hidden, the block is not asked, whatever the mouse is over
        grid:SetVisible(false)
        over = setmetatable({}, { __index = function() return true end })
        asked = {}
        frames(1)
        t.eq(ui.Hovered(), nil)
        t.eq(count({ grid.widget }) + count(lines) + count(buttons), 0)
        grid:SetVisible(true)
        frames(1)
        t.eq(ui.Hovered(), 1, "shown again, it is")

        slots.GRACE = keep
        stop()
        fake.react.IsHovered = nil
        host_scope:destroy()
        frames(1)
        Wax.game = nil
    end)

    t.test("a faint slot fades its icon as well as its picture, and a block that is switched off takes no mouse and shows no hand", function()
        Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
        local host, host_scope = nil, scope.new("faint")
        scope.run(host_scope, function() host = ui.Panel({ anchor = "top-left", width = 400, when = "always" }) end)
        local first = fake.mark()
        local row = host:Slots({ columns = 3, rows = 1, size = 30, gap = 2 })
        local line = made_of(first, "HorizontalBox")[1]
        local mark = fake.mark()
        frames(12)
        t.ok(row:Ready())
        local buttons = made_of(mark, "Button")
        t.eq(#buttons, 3)
        local function faint()
            local found = 0
            for _, image in ipairs(made_of(first, "Image")) do
                local last = fake.last(image, "SetRenderOpacity")
                if last and last[2] == 0.35 then found = found + 1 end
            end
            return found
        end
        row:Set({ { icon = "home", value = 1, dim = true }, { icon = "star", value = 2 } })
        t.eq(faint(), 2, "the picture and the icon of the faint cell")
        row:SetLook(2, { icon = "star", value = 2, dim = true })
        t.eq(faint(), 4)
        row:SetLook(1, { icon = "home", value = 1 })
        t.eq(faint(), 2, "and both are whole again")
        -- a cell that is faint before it has an icon: the icon is faint from the moment it is made
        row:SetLook(3, { value = 3, dim = true })
        t.eq(faint(), 3)
        row:SetLook(3, { icon = "axe", value = 3, dim = true })
        t.eq(faint(), 4)

        local over, right = {}, {}
        fake.react.IsHovered = function(self) return over[self] == true end
        row.RightClicked:Connect(function(value) right[#right + 1] = value end)
        over = { [gui_root.layer("hud")] = true, [host.holder] = true, [row.widget] = true, [line] = true, [buttons[2]] = true }
        frames(1)
        t.eq(ui.Hovered(), 2)
        row:SetEnabled(false)
        for _, button in ipairs(buttons) do t.eq(fake.last(button, "SetCursor")[2], style.Cursor.Default, "no hand over a cell that cannot be pressed") end
        frames(1)
        t.eq(ui.Hovered(), nil, "switched off, no cell is under the mouse")
        fake.released.RightMouseButton = true
        frames(1)
        fake.released.RightMouseButton = nil
        t.eq(#right, 0, "and a right click is nobody's, though the mouse was over a cell a moment ago")
        row:SetEnabled(true)
        t.eq(fake.last(buttons[1], "SetCursor")[2], style.Cursor.Hand)
        frames(1)
        t.eq(ui.Hovered(), 2, "switched on again, it is")

        -- cells that are made after their block was switched off have no hand either
        mark = fake.mark()
        local late = host:Slots({ columns = 2, rows = 1, size = 30 })
        late:SetEnabled(false)
        frames(12)
        t.ok(late:Ready())
        local made = made_of(mark, "Button")
        t.eq(#made, 2)
        for _, button in ipairs(made) do t.eq(fake.last(button, "SetCursor")[2], style.Cursor.Default) end

        fake.react.IsHovered = nil
        host_scope:destroy()
        frames(1)
        Wax.game = nil
    end)

    t.test("with slots.FOLLOW_HELD on, the cell under the mouse is worked out from where the mouse is while the middle button is held", function()
        Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
        local host, host_scope = nil, scope.new("follow")
        scope.run(host_scope, function() host = ui.Panel({ anchor = "top-left", width = 400, when = "always" }) end)
        local mark = fake.mark()
        local grid = host:Slots({ columns = 5, rows = 2, size = 30, gap = 2 })
        local lines = made_of(mark, "HorizontalBox")
        mark = fake.mark()
        frames(12)
        t.ok(grid:Ready())
        local buttons = made_of(mark, "Button")
        local looks = {}
        for index = 1, 9 do looks[index] = { icon = "home", value = index } end
        grid:Set(looks)
        local middle = {}
        grid.MiddleClicked:Connect(function(value) middle[#middle + 1] = value end)
        local over, held, asked = {}, {}, 0
        fake.react.IsHovered = function(self) return over[self] == true end
        fake.react.IsInputKeyDown = function(_, key)
            asked = asked + 1
            return held[key.KeyName] == true
        end
        -- where the block's top left corner is on the screen. A cell is 30 and the gap after it 2.
        local left, top, pitch = 100, 50, 32
        local function at(index, dx, dy)
            fake.mouse.X, fake.mouse.Y = left + (index - 1) % 5 * pitch + dx, top + (index - 1) // 5 * pitch + dy
        end
        -- the mouse comes to a place in a cell, and the cell says so
        local function point(index, dx, dy)
            at(index, dx, dy)
            over = { [gui_root.layer("hud")] = true, [host.holder] = true, [grid.widget] = true, [lines[(index - 1) // 5 + 1]] = true,
                [buttons[index]] = true }
            frames(1)
        end
        -- the same with a button held: the game has the mouse, and nothing says the mouse is over it
        local function fly(index, dx, dy)
            at(index, dx, dy)
            over = {}
            frames(1)
        end

        -- it comes switched on. Switched off, no cell is under the mouse while the button is held, and the click goes to the cell it left
        t.eq(slots.FOLLOW_HELD, true)
        slots.FOLLOW_HELD = false
        point(2, 15, 15)
        t.eq(ui.Hovered(), 2)
        held.MiddleMouseButton = true
        fly(3, 15, 15)
        t.eq(ui.Hovered(), nil)
        t.eq(asked, 0, "and the game is not asked which buttons are held")
        held.MiddleMouseButton = nil
        fake.released.MiddleMouseButton = true
        frames(1)
        fake.released.MiddleMouseButton = nil
        t.eq(middle[1], 2)

        slots.FOLLOW_HELD = true
        -- every cell the mouse is seen over says where the block must be: three looks near the edges of cells pin it down
        point(2, 2, 3)
        point(3, 1, 28)
        point(1, 29, 1)
        t.eq(ui.Hovered(), 1)
        held.MiddleMouseButton = true
        fly(4, 15, 15)
        t.eq(ui.Hovered(), 4, "held and moved along the row")
        fly(9, 15, 15)
        t.eq(ui.Hovered(), 9, "and down to the next row")
        fly(9, 31, 15)
        t.eq(ui.Hovered(), nil, "between two cells there is no cell")
        fly(10, 15, 15)
        t.eq(ui.Hovered(), nil, "nor is an empty cell one")
        fake.mouse.X, fake.mouse.Y = 900, 700
        frames(3)
        t.eq(ui.Hovered(), nil, "nor is there one off the block")
        fly(7, 10, 10)
        t.eq(ui.Hovered(), 7, "back over it while still held")
        held.MiddleMouseButton = nil
        fake.released.MiddleMouseButton = true
        frames(1)
        fake.released.MiddleMouseButton = nil
        t.eq(middle[2], 7, "the click is the cell the mouse was let go over")
        t.eq(ui.Hovered(), nil, "and with the button up a cell has to say so itself again")

        -- a block that does not show is not found this way either
        point(7, 10, 10)
        grid:SetVisible(false)
        held.MiddleMouseButton = true
        fly(8, 15, 15)
        t.eq(ui.Hovered(), nil)
        held.MiddleMouseButton = nil
        grid:SetVisible(true)

        -- the block is somewhere else now (its panel moved): the first look that cannot be true of the old place starts again
        left = 300
        point(1, 15, 15)
        held.MiddleMouseButton = true
        fly(2, 15, 15)
        t.eq(ui.Hovered(), 2)
        -- set out anew, where its cells are has to be seen again
        held.MiddleMouseButton = nil
        point(1, 15, 15)
        grid:SetLayout(4, 30)
        held.MiddleMouseButton = true
        fly(2, 15, 15)
        t.eq(ui.Hovered(), nil)
        held.MiddleMouseButton = nil
        frames(1)

        -- a panel drawn twice as large: a cell and its gap are 64 on the screen
        local large = nil
        scope.run(host_scope, function() large = ui.Panel({ anchor = "top-left", width = 400, when = "always", zoom = 2 }) end)
        mark = fake.mark()
        local big = large:Slots({ columns = 4, rows = 1, size = 30, gap = 2 })
        local big_line = made_of(mark, "HorizontalBox")[1]
        mark = fake.mark()
        frames(12)
        local big_buttons = made_of(mark, "Button")
        big:Set({ { icon = "home", value = "a" }, { icon = "home", value = "b" }, { icon = "home", value = "c" } })
        fake.mouse.X, fake.mouse.Y = 500 + 64 + 30, 200 + 30
        over = { [gui_root.layer("hud")] = true, [large.holder] = true, [big.widget] = true, [big_line] = true, [big_buttons[2]] = true }
        frames(1)
        t.eq(ui.Hovered(), "b")
        held.RightMouseButton = true
        fake.mouse.X = 500 + 128 + 30
        over = {}
        frames(1)
        t.eq(ui.Hovered(), "c", "the right button held counts the same")
        held.RightMouseButton = nil
        frames(1)

        slots.FOLLOW_HELD = false
        fake.react.IsHovered, fake.react.IsInputKeyDown = nil, nil
        host_scope:destroy()
        frames(1)
        Wax.game = nil
    end)

    t.test("an icon button can be a square of a given side, for a line that is lower than a button", function()
        local host, host_scope = nil, scope.new("compact")
        scope.run(host_scope, function() host = ui.Window({ title = "Compact", width = 300, height = 300 }) end)
        local clicks = 0
        local small = host:Button(nil, function() clicks = clicks + 1 end, { icon = "chevron-left", size = 24 })
        t.ok(not rawequal(small.widget, small.source), "the button sits in a box of that size")
        t.eq(fake.last(small.widget, "SetWidthOverride")[2], 24)
        t.eq(fake.last(small.widget, "SetHeightOverride")[2], 24)
        click(small.source)
        t.eq(clicks, 1)
        small:SetIcon("chevron-right")
        small:SetEnabled(false)
        t.eq(fake.last(small.source, "SetCursor")[2], style.Cursor.Default)
        t.eq(small.disabled, true)
        local plain = host:Button(nil, function() end, { icon = "chevron-left" })
        t.ok(rawequal(plain.widget, plain.source), "without a size it is the button it always was")
        local worded = host:Button("Go", function() end, { icon = "play", size = 24 })
        t.ok(rawequal(worded.widget, worded.source), "and a button with a caption keeps its own size")
        host_scope:destroy()
    end)

    t.test("a panel's wheel is only read while the mouse is over the panel, and once more in the frame it leaves", function()
        local host, host_scope = nil, scope.new("wheel")
        scope.run(host_scope, function() host = ui.Panel({ anchor = "top-left", width = 200, when = "always" }) end)
        local turned = {}
        host.Scrolled:Connect(function(by) turned[#turned + 1] = by end)
        fake.scroll_offset, fake.hovered = overlay_module.WHEEL_ROOM, true
        frames(2)
        local read, stop = watch("GetScrollOffset")
        local function reads()
            local found = 0
            for _, call in ipairs(read) do
                if rawequal(call[1], host.catcher) then found = found + 1 end
            end
            return found
        end
        frames(2)
        t.eq(reads(), 2, "read every frame under the mouse")
        fake.hovered = false
        frames(1)
        t.eq(reads(), 3, "and once more in the frame the mouse leaves")
        frames(5)
        t.eq(reads(), 3, "then not at all")
        fake.hovered, fake.scroll_offset = true, overlay_module.WHEEL_ROOM + 30
        frames(1)
        t.eq(turned[1], 1, "the wheel turned down over the panel")
        fake.scroll_offset = overlay_module.WHEEL_ROOM
        stop()
        fake.hovered, fake.scroll_offset = nil, nil
        host_scope:destroy()
    end)

    t.test("the game's screen is read once a frame however often it is asked for, and whoever listens is told when it changes", function()
        Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
        local screen, tab = fake.new_object("UMG_MainMenu"), 1
        fake.props.bShowMouseCursor = true
        fake.react.GetChildrenCount = function() return 1 end
        fake.react.GetChildAt = function() return screen end
        fake.react.GetVisibility = function() return 0 end
        fake.react.GetFullName = function() return "UMG_MainMenu_C /Engine/Transient.Interface:WidgetTree.UMG_MainMenu" end
        fake.react.GetActiveWidgetIndex = function() return tab end
        frames(1)
        local name, at = ui.GameScreen()
        t.eq(name, "UMG_MainMenu")
        t.eq(at, 1)
        local touches = fake.touches
        ui.GameScreen()
        ui.GameScreen()
        t.eq(fake.touches, touches, "asked again in the same frame, nothing of the game is read")

        local told = {}
        local listening = ui.GameScreenChanged:Connect(function(which, number) told[#told + 1] = tostring(which) .. " " .. tostring(number) end)
        frames(1)
        t.eq(told[1], "UMG_MainMenu 1", "whoever starts to listen is told what shows")
        frames(12)
        t.eq(#told, 1, "and nothing more while it stays")
        tab = 2
        frames(fit.LOOK + 1)
        t.eq(told[2], "UMG_MainMenu 2", "another tab of the game's menu")
        fake.props.bShowMouseCursor = false
        frames(1)
        t.eq(told[3], "nil nil", "in the frame the game takes the mouse back there is no screen any more")
        fake.props.bShowMouseCursor = true
        frames(1)
        t.eq(told[4], "UMG_MainMenu 2", "and in the frame it frees it again the screen is looked at straight away")
        listening:Disconnect()
        -- with nobody listening the game is not looked at for this
        fake.props.bShowMouseCursor = false
        frames(2)
        t.eq(#told, 4)
        for _, answer in ipairs({ "GetChildrenCount", "GetChildAt", "GetVisibility", "GetFullName", "GetActiveWidgetIndex" }) do fake.react[answer] = nil end
        fake.props.bShowMouseCursor = nil
        Wax.game = nil
    end)

    t.test("each edge and corner of a window lights its own piece of the outline: under the mouse, and brighter while it is held", function()
        local sized, host_scope = nil, scope.new("lights")
        scope.run(host_scope, function() sized = ui.Window({ title = "Lights", width = 500, height = 300, x = 600, y = 400 }) end)
        ui.Open()
        local handles = 0
        for edges, handle in pairs(sized.edge_handles) do
            handles = handles + 1
            local part = sized.lights[edges]
            t.eq(part.glow, nil, edges .. ": nothing is made for a handle before it first lights up")
            events.simulate(handle, "OnHovered")
            t.eq(part.level, 0.5, edges .. " under the mouse")
            t.ok(part.glow and part.soft, edges .. ": its two pictures are there now")
            fake.mouse.X, fake.mouse.Y = 900, 500
            events.simulate(handle, "OnPressed")
            fake.pressed = true
            frames(1)
            t.eq(part.level, 1, edges .. " held")
            t.ok(fake.last(part.soft, "SetColorAndOpacity")[2].A > 0, edges .. ": the soft glow shows only while it is held")
            for other, light in pairs(sized.lights) do
                if other ~= edges then t.eq(light.level, 0, "while " .. edges .. " is held, " .. other .. " is dark") end
            end
            fake.pressed = false
            frames(1)
            t.eq(part.level, 0.5, edges .. " let go with the mouse still on it")
            t.eq(fake.last(part.soft, "SetColorAndOpacity")[2].A, 0)
            events.simulate(handle, "OnUnhovered")
            t.eq(part.level, 0, edges .. " left")
            t.eq(fake.last(part.glow, "SetColorAndOpacity")[2].A, 0)
        end
        t.eq(handles, 8)
        t.ok(math.abs(fake.last(sized.outline, "SetColorAndOpacity")[2].B - style.theme.outline.B) < 1e-9,
            "the outline as a whole is not lit by a resize")
        -- the grip's own icon: accent under the mouse, the muted colour again when the mouse leaves
        events.simulate(sized.grip_button, "OnHovered")
        t.ok(math.abs(fake.last(sized.grip_icon, "SetColorAndOpacity")[2].B - style.theme.accent.B) < 1e-9)
        events.simulate(sized.grip_button, "OnUnhovered")
        t.ok(math.abs(fake.last(sized.grip_icon, "SetColorAndOpacity")[2].A - 0.55) < 1e-9)
        -- moving the window by its bar still lights the whole outline, as before
        events.simulate(sized.bar, "OnPressed")
        t.ok(math.abs(fake.last(sized.outline, "SetColorAndOpacity")[2].B - style.theme.accent.B) < 1e-9)
        fake.pressed = false
        frames(1)
        sized:SetMinimized(true)
        t.eq(fake.last(sized.glow_layer, "SetVisibility")[2], style.Visibility.Collapsed, "minimised, nothing glows")
        ui.Close()
        host_scope:destroy()
    end)

    t.test("a section made with fit = true keeps its title on one line: one too long is cut with dots and follows the room it has", function()
        local host, host_scope = nil, scope.new("fit")
        scope.run(host_scope, function() host = ui.Window({ title = "Fit", width = 300, height = 300 }) end)
        local long = "A title that is far too long for a card this narrow to show on one line"
        local section = host:Section(long, { fit = true })
        local narrow = section.parts.shown
        t.ok(#narrow < #long and narrow:sub(-3) == "...", narrow)
        t.eq(section.parts.title, long, "the whole title is kept, for the tip")
        t.eq(host:Section("Short", { fit = true }).parts.shown, "Short", "one that fits is left as it is")
        host:SetSize(600, 300)
        local wide = section.parts.shown
        t.ok(#wide > #narrow, "with more room more of it shows")
        section.parts.before = 150
        section.parts.fit()
        t.ok(#section.parts.shown < #wide, "what its maker puts before the title takes from the room")
        t.eq(host:Section("Plain").parts.fit, nil, "without the option a title wraps as before")
        host_scope:destroy()
    end)

    t.test("the root is still found alive, and its loss still seen at once, with the game instance's list kept between looks", function()
        local least, most = math.huge, 0
        for _ = 1, 70 do
            local reads = fake.touches
            t.eq(gui_root.check(), true)
            least, most = math.min(least, fake.touches - reads), math.max(most, fake.touches - reads)
        end
        t.ok(least <= 4, "a check with the list kept asks the game little: " .. least)
        t.ok(most > least, "and now and then the list is reached anew")
        ui.check()
    end)
end

t.test("a control never shows the word nil: what is missing shows as nothing", function()
    local host
    local host_scope = scope.new("nothing")
    scope.run(host_scope, function() host = ui.Window({ title = "Nothing" }) end)
    local function text_of(widget) return fake.last(widget, "SetText")[2]:ToString() end
    local empty = host:Dropdown("Empty", {}, nil)
    t.eq(empty:Get(), nil)
    t.eq(header_of(empty), "", "a dropdown with nothing to choose from has an empty header")
    local pick = host:Dropdown("Pick", { "A", "B" }, nil)
    t.eq(header_of(pick), "A")
    pick:Set(nil)
    t.eq(header_of(pick), "")
    pick.offer({ "B" })
    t.eq(pick:Get(), nil, "what is offered does not change the value")
    pick:Set("B")
    t.eq(header_of(pick), "B")
    local label = host:Label(nil)
    t.eq(text_of(label.widget), "")
    label:Set(nil)
    t.eq(text_of(label.widget), "")
    host:SetTitle(nil)
    t.eq(host.title, "")
    local note = ui.Notify(nil)
    t.eq(note.text, "")
    note:Close()
    host_scope:destroy()
end)

t.test("the keys looked at in one frame share one read of the player's controller, and it is not kept after the frame", function()
    local reads, player = 0, fake.new_object("PlayerController")
    Wax.game = setmetatable({}, { __index = function(_, key)
        if key ~= "LocalPlayer" then return nil end
        reads = reads + 1
        return { Raw = player }
    end })
    local host_scope = scope.new("keys")
    scope.run(host_scope, function()
        ui.Window({ title = "Keys" })
        ui.Hotkey("F1", function() end)
        ui.Hotkey("F2", function() end)
        ui.Hotkey("F3", function() end)
    end)
    reads = 0
    frames(1)
    t.eq(reads, 1, "three hotkeys and the key of the panel were looked at with one read")
    input.controller()
    input.controller()
    t.eq(reads, 3, "outside the frame step every look is a new read")
    -- a step that fails half way leaves nothing held
    local tween = Wax.import("gui.tween")
    local real = tween.step
    tween.step = function() error("this step fails") end
    local ok, problem = pcall(frames, 1)
    tween.step = real
    t.ok(not ok and tostring(problem):find("this step fails", 1, true), "the error is passed on as it was")
    reads = 0
    input.controller()
    t.eq(reads, 1)
    host_scope:destroy()
    Wax.game = nil
end)

t.test("ui.IsKeyDown says whether a key is held, counts Ctrl, Shift and Alt exactly, and asks the game only when it is called", function()
    t.eq(ui.IsKeyDown("A"), false, "with no local player nothing is held")
    Wax.game = { LocalPlayer = { Raw = fake.new_object("PlayerController") } }
    local held, asked = {}, 0
    fake.react.IsInputKeyDown = function(_, key)
        asked = asked + 1
        return held[key.KeyName] == true
    end
    t.eq(ui.IsKeyDown("A"), false)
    held.A = true
    t.eq(ui.IsKeyDown("A"), true)
    t.eq(ui.IsKeyDown("MiddleMouseButton"), false, "another key is not held")
    held.LeftShift = true
    t.eq(ui.IsKeyDown("A"), true, "a plain key counts whatever else is held")
    t.eq(ui.IsKeyDown("Shift+A"), true)
    t.eq(ui.IsKeyDown("shift+A"), true, "however the word is spelt")
    t.eq(ui.IsKeyDown("Ctrl+A"), false, "Ctrl is not held")
    t.eq(ui.IsKeyDown("Ctrl+Shift+A"), false)
    held.LeftShift, held.RightControl = nil, true
    t.eq(ui.IsKeyDown("Ctrl+A"), true, "either Ctrl key is Ctrl")
    t.eq(ui.IsKeyDown("Shift+A"), false, "Shift came up and Ctrl is held instead")
    held.A = nil
    t.eq(ui.IsKeyDown("Ctrl+A"), false, "the key itself came up")
    t.eq(ui.IsKeyDown("NoSuchKey"), false, "a name the game does not know is never held")
    held = {}
    asked = 0
    frames(3)
    t.eq(asked, 0, "no frame asks the game whether a key is held")
    ui.IsKeyDown("A")
    t.eq(asked, 1, "a plain key is one question")
    t.raises(function() ui.IsKeyDown(nil) end, "key name")
    t.raises(function() ui.IsKeyDown("") end, "key name")
    t.raises(function() ui.IsKeyDown(ui, "A") end, "key name")
    t.raises(function() ui.IsKeyDown("Meta+A") end, "key name")
    fake.react.IsInputKeyDown = nil
    Wax.game = nil
end)

t.test("stopping the GUI leaves nothing behind", function()
    scope.run(scope.new("late"), function() ui.Window({ title = "Late" }) end)
    ui.stop()
    t.eq(ui.stats().windows, 0)
    t.raises(function() ui.Window({}) end, "not running")
end)

-- The game starting: every GUI module from nothing, with a screen that has no size for the first frames.
t.test("no text block is made without a rule: each one wraps, is fitted to a room, or is free where what holds it is as wide as its text", function()
    local kit = Wax.import("gui.kit")
    local without, counted = {}, { wraps = 0, fitted = 0, free = 0 }
    for _, made in ipairs(text_blocks) do
        local rule = made.info and kit.rule(made.info)
        if rule then
            counted[rule] = counted[rule] + 1
        elseif made.info and not made.where:find("gui_test", 1, true) then
            without[made.where] = (without[made.where] or 0) + 1
        end
    end
    local list = {}
    for where, count in pairs(without) do list[#list + 1] = where .. " (" .. count .. ")" end
    table.sort(list)
    t.eq(table.concat(list, ", "), "", "text blocks made with no rule")
    t.ok(counted.wraps > 0 and counted.fitted > 0 and counted.free > 0 and counted.wraps + counted.fitted + counted.free > 100,
        ("%d wrap, %d are fitted, %d are free"):format(counted.wraps, counted.fitted, counted.free))
end)

t.test("a cold start: nothing is worked out from a screen that is not there yet", function()
    local storage = Wax.import("core.storage")
    local real_load, real_clock, now = storage.load, sched.clock, sched.clock()
    sched.clock = function() return now end
    local function cold_start(places)
        for name in pairs(Wax.modules) do
            if name:find("^gui%.") then Wax.modules[name] = nil end
        end
        fake.set_screen(1, 1, 0.444)
        storage.load = function(owner, name, defaults)
            local out = real_load(owner, name, defaults)
            if owner == "wax" and name == "interface" then out.windows = places end
            return out
        end
        local fresh = Wax.import("gui.init")
        fresh.start()
        Wax.ui = fresh
        return fresh
    end
    local function run(fresh, seconds, count)
        for _ = 1, count do
            now = now + seconds / count
            sched.step()
            fresh.step()
        end
    end

    -- a 2560 by 1440 screen, which comes to 1920 by 1080 in the units of the interface
    local cold = cold_start({ ["early/Tools"] = { x = 1500, y = 700 } })
    run(cold, 0.2, 12)
    t.eq(cold.GetScale(), 1, "the interface is not made larger for a screen that is not there")
    t.eq(cold.MinScale(), 0.7)
    local early, told = scope.new("early"), {}
    local tools, sizes
    scope.run(early, function()
        -- a mod that loads while the game is starting asks for the size and lays itself out
        local width, height = cold.ScreenSize()
        t.eq(width, 1920)
        t.eq(height, 1080)
        cold.ScreenChanged:Connect(function(wide, high) told[#told + 1] = { wide, high } end)
        tools = cold.Window({ title = "Tools", width = 320, height = 260 })
        cold.AddSettings(tools)
        sizes = tools.controls[#tools.controls]
    end)
    t.ok(sizes.items["100%"] ~= nil, "the last control of the settings is the interface size")
    t.eq(header_of(sizes), "100%", "the Settings page shows a size, not the word nil")
    t.eq(tools.slot:GetPosition().X, 1500, "a window is where its saved place says")
    t.eq(tools.slot:GetPosition().Y, 700)
    fake.set_screen(2560, 1440, 1.333)
    run(cold, 0.2, 12)
    t.eq(cold.GetScale(), 1)
    t.ok(math.abs(cold.MinScale() - 0.7) < 1e-9)
    t.eq(header_of(sizes), "100%")
    t.eq(sizes:Get(), "100%")
    t.eq(tools.slot:GetPosition().X, 1500)
    t.eq(tools.slot:GetPosition().Y, 700)
    run(cold, 2, 20)
    t.eq(#told, 0, "1920 by 1080 was the right answer for this screen, so there is nothing to tell")
    early:destroy()
    cold.stop()

    -- a wider screen: the mod that asked too early is told the real size, once, and a place beyond 1920 is kept
    cold = cold_start({ ["early/Tools"] = { x = 2300, y = 700 } })
    early, told = scope.new("early"), {}
    scope.run(early, function()
        t.eq(cold.ScreenSize(), 1920)
        cold.ScreenChanged:Connect(function(wide, high) told[#told + 1] = { wide, high } end)
        tools = cold.Window({ title = "Tools", width = 320, height = 260 })
    end)
    run(cold, 0.2, 12)
    t.eq(tools.slot:GetPosition().X, 2300, "a saved place is not pulled in to fit a screen that is only assumed")
    fake.set_screen(3440, 1440, 4 / 3)
    run(cold, 0.2, 12)
    t.eq(#told, 0, "not while the screen has only just appeared")
    t.eq(tools.slot:GetPosition().X, 2300)
    run(cold, 0.5, 10)
    t.eq(#told, 1)
    t.ok(math.abs(told[1][1] - 2580) < 0.01 and math.abs(told[1][2] - 1080) < 0.01, "got " .. told[1][1] .. " by " .. told[1][2])
    t.ok(math.abs(cold.ScreenSize() - 2580) < 0.01)
    run(cold, 2, 20)
    t.eq(#told, 1, "once")

    -- a small screen, where text needs a larger interface to be read: the Settings page offers and shows a size that fits
    early:destroy()
    cold.stop()
    cold = cold_start({})
    early = scope.new("early")
    scope.run(early, function()
        tools = cold.Window({ title = "Tools", width = 320, height = 260 })
        cold.AddSettings(tools)
        sizes = tools.controls[#tools.controls]
    end)
    fake.set_screen(1280, 720, 2 / 3)
    run(cold, 1, 20)
    t.ok(math.abs(cold.GetScale() - 1.35) < 1e-9)
    t.eq(header_of(sizes), "150%")

    early:destroy()
    cold.stop()
    storage.load, sched.clock = real_load, real_clock
    fake.set_screen(1920, 1080, 1)
    Wax.ui = ui
end)

t.finish("gui")
