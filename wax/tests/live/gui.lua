-- Live test of the GUI library in the running game. Clicks go through the engine's own delegates; no real input is used.
local ui = Wax.ui
local events = Wax.import("gui.events")
local scope = Wax.import("core.scope")
local guard = Wax.guard

local checks = {}
local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end
local function attempt(name, fn)
    local ok, a, b = pcall(fn)
    if ok then check(name, a, b) else check(name, false, "raised: " .. tostring(a)) end
end
-- The engine fires the delegate, which calls the hidden receiver, which reaches the handler.
local function click(widget) widget.OnClicked:Broadcast() end

local theme = ui.Theme()
local saved_animation = theme.animation
theme.animation = 0
local baseline = ui.stats()
local foreign_before = events.calls().foreign
local owner = scope.new("gui-test")
local seen = { clicks = 0, commits = 0 }
local window, button, toggle, slider, input, dropdown, section, failing, progress, paged, hud

attempt("a window with every control builds", function()
    scope.run(owner, function()
        window = ui.Window({ title = "GUI test", width = 320, height = 420, x = 900, y = 120 })
        window:Label("A long line of text that has to wrap inside the window rather than widen it, whatever its length may be.")
        button = window:Button("Go", function() seen.clicks = seen.clicks + 1 end)
        toggle = window:Toggle("Flag", true, function(on) seen.toggle = on end)
        slider = window:Slider("Amount", { min = 0, max = 10, value = 4, step = 0.5 }, function(v) seen.slider = v end)
        input = window:Input("Name", { hint = "name" }, function(text) seen.input = text seen.commits = seen.commits + 1 end)
        dropdown = window:Dropdown("Mode", { "One", "Two", "Three" }, "One", function(choice) seen.choice = choice end)
        window:Keybind("Key", "F5")
        progress = window:Progress("Load", 0.25)
        local row = window:Row()
        row:Button("A")
        row:Button("B")
        section = window:Section("More", { open = false })
        section:Toggle("Inner", false)
        failing = window:Button("Breaks", function() error("handler blew up on purpose") end)
        window:Console({ height = 80 }):SetLines({ { "one" }, { "two", theme.bad } })
    end)
    return window:IsVisible() and ui.stats().windows == baseline.windows + 1
end)

attempt("a click fired by the engine reaches the handler and its signal", function()
    local signalled = 0
    button.Activated:Connect(function() signalled = signalled + 1 end)
    local before = events.calls().handled
    click(button.source)
    click(button.source)
    return seen.clicks == 2 and signalled == 2 and events.calls().handled == before + 2,
        ("clicks=%d signal=%d handled=%d"):format(seen.clicks, signalled, events.calls().handled - before)
end)

attempt("toggle flips on a click; Set changes it without firing", function()
    click(toggle.source)
    local after_click = toggle:Get()
    seen.toggle = "untouched"
    toggle:Set(true)
    return after_click == false and toggle:Get() == true and seen.toggle == "untouched"
end)

attempt("slider snaps to its step, clamps, and updates the readout", function()
    events.simulate(slider.source, "OnValueChanged", 7.26)
    local snapped = slider:Get()
    slider:Set(99)
    return snapped == 7.5 and seen.slider == 7.5 and slider:Get() == 10, ("snapped=%s clamped=%s"):format(tostring(snapped), tostring(slider:Get()))
end)

attempt("text input commits once per change", function()
    events.simulate(input.source, "OnTextCommitted", "Bob")
    events.simulate(input.source, "OnTextCommitted", "Bob")
    input:Set("Alice")
    return seen.input == "Bob" and seen.commits == 1 and input:Get() == "Alice", ("input=%s commits=%d"):format(tostring(seen.input), seen.commits)
end)

attempt("dropdown opens in place, picks a choice and closes", function()
    click(dropdown.source)
    local opened = dropdown.parts.open
    click(dropdown.items.Three)
    return opened and not dropdown.parts.open and dropdown:Get() == "Three" and seen.choice == "Three"
end)

attempt("section expands and collapses", function()
    local started_closed = not section:IsOpen()
    click(section.control.source)
    local opened = section:IsOpen()
    section:SetOpen(false)
    return started_closed and opened and not section:IsOpen()
end)

attempt("a handler that raises is reported, and the control keeps working", function()
    click(failing.source)
    click(button.source)
    local reported = false
    for _, record in ipairs(guard.errors()) do
        if record.trace:find("handler blew up on purpose", 1, true) then reported = true end
    end
    return reported and seen.clicks == 3
end)

attempt("minimise, restore, close and show", function()
    click(window.minimize_button)
    local minimized_height = window.slot:GetSize().Y
    click(window.minimize_button)
    local restored_height = window.slot:GetSize().Y
    local closed = 0
    window.Closed:Connect(function() closed = closed + 1 end)
    click(window.close_button)
    local hidden = not window:IsVisible()
    window:Show()
    return minimized_height == theme.bar_height and restored_height == 420 and hidden and closed == 1 and window:IsVisible(),
        ("minimised=%d restored=%d"):format(minimized_height, restored_height)
end)

attempt("position and size are clamped and applied", function()
    window:SetPosition(-500, -500)
    local position = window.slot:GetPosition()
    window:SetSize(10, 10)
    local size = window.slot:GetSize()
    window:SetPosition(900, 120)
    window:SetSize(320, 420)
    return position.X == 0 and position.Y == 0 and size.X >= 240 and size.Y >= 140, ("pos=%d,%d size=%dx%d"):format(position.X, position.Y, size.X, size.Y)
end)

attempt("content never grows wider than the window", function()
    window.box:ForceLayoutPrepass()
    local wanted = window.box:GetDesiredSize().X
    return wanted <= 320, ("content wants %.0f of 320"):format(wanted)
end)

attempt("pages: selecting by click and by name, and removing one", function()
    scope.run(owner, function() paged = ui.Window({ title = "Pages", nav = "side", x = 900, y = 560, width = 460, height = 220 }) end)
    local first = paged:Page("First", { icon = "home" })
    local second = paged:Page("Second", { icon = "box" })
    first:Label("first page")
    second:Progress("Second page", 0.5)
    click(second.button)
    local by_click = paged.page == second
    paged:SelectPage("First")
    local by_name = paged.page == first
    paged:RemovePage(first)
    return by_click and by_name and paged.page == second and second.index == 0
end)

attempt("an overlay and a notification build", function()
    scope.run(owner, function() hud = ui.Overlay({ anchor = "bottom-left", title = "Test overlay" }) end)
    hud:Field("Map", Wax.game.MapName)
    hud:Progress("Health", 0.5)
    ui.Notify("A test notification.", { title = "GUI test", kind = "good", seconds = 1 })
    return ui.stats().overlays == baseline.overlays + 1
end)

attempt("progress clamps", function()
    progress:Set(3)
    return progress:Get() == 1
end)

attempt("the hooks see no calls from anything but Wax", function()
    local during = events.calls().foreign - foreign_before
    return during == 0, ("foreign calls during the test: %d (since the game started: %d)"):format(during, events.calls().foreign)
end)

attempt("destroying the owner removes its windows, overlays and every handler it registered", function()
    owner:destroy()
    local after = ui.stats()
    return after.windows == baseline.windows and after.overlays == baseline.overlays and after.handlers == baseline.handlers,
        ("windows %d->%d handlers %d->%d"):format(baseline.windows, after.windows, baseline.handlers, after.handlers)
end)

theme.animation = saved_animation
local passed, failures, details = 0, {}, {}
for _, c in ipairs(checks) do
    if c.ok then passed = passed + 1 else failures[#failures + 1] = c.name .. " :: " .. tostring(c.detail) end
    details[#details + 1] = (c.ok and "ok   " or "FAIL ") .. c.name .. (c.detail and ("  [" .. tostring(c.detail):sub(1, 140) .. "]") or "")
end
return { passed = passed, failed = #failures, failures = failures, details = details, stats = ui.stats() }
