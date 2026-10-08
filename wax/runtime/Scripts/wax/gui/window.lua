-- Windows: the frame, dragging and resizing, minimising, and pages with side or top navigation

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")
local events = Wax.import("gui.events")
local tween = Wax.import("gui.tween")
local controls = Wax.import("gui.controls")
local grab = Wax.import("gui.drag")
local scope = Wax.import("core.scope")
local sched = Wax.import("core.sched")

local M = {}

local V, H, VA = style.Visibility, style.HAlign, style.VAlign
local MIN_WIDTH, MIN_HEIGHT = 240, 140
local SPLIT_WIDTH, MIN_SIDE, MIN_PAGE = 7, 96, 220
local MAX_SIDE_NEED = 220
local EDGE, CORNER, GRIP = 4, 8, 21     -- how far in from a window's edge its resize strips, its corner squares and its grip reach
-- What a window is resized by, besides the grip in its bottom right corner: a strip along each edge, then a square at each other corner.
local HANDLES = {
    { edges = "n", cursor = style.Cursor.ResizeUpDown, height = EDGE, h = H.Fill, v = VA.Top },
    { edges = "s", cursor = style.Cursor.ResizeUpDown, height = EDGE, h = H.Fill, v = VA.Bottom },
    { edges = "w", cursor = style.Cursor.ResizeLeftRight, width = EDGE, h = H.Left, v = VA.Fill },
    { edges = "e", cursor = style.Cursor.ResizeLeftRight, width = EDGE, h = H.Right, v = VA.Fill },
    { edges = "nw", cursor = style.Cursor.ResizeSouthEast, width = CORNER, height = CORNER, h = H.Left, v = VA.Top },
    { edges = "ne", cursor = style.Cursor.ResizeSouthWest, width = CORNER, height = CORNER, h = H.Right, v = VA.Top },
    { edges = "sw", cursor = style.Cursor.ResizeSouthWest, width = CORNER, height = CORNER, h = H.Left, v = VA.Bottom },
}
local windows = {}
local top_order = 0
M.windows = windows

local Window = setmetatable({}, { __index = controls.Container })
Window.__index = Window

-- What a destroyed window turns into: it still answers IsVisible and Destroy, and everything else raises an error.
local Gone = {}
Gone.__index = function(_, key)
    if key == "IsVisible" or key == "IsMinimized" or key == "IsShowing" then return function() return false end end
    if key == "Destroy" or key == "Hide" then return function() end end
    return function() error("this window no longer exists (it was destroyed or its mod reloaded)", 2) end
end

local function bar_height() return style.theme.bar_height end

-- Where a window is drawn: its own place, pulled in until its bar can be reached. The place itself is kept, for a larger screen.
local function place_on_screen(window)
    local x, y = window.x, window.y
    if root.screen_known() then
        local width, height = root.viewport_size()
        x = math.max(0, math.min(x, math.max(0, width - 80 * style.scale)))
        y = math.max(0, math.min(y, math.max(0, height - bar_height() * style.scale)))
    end
    window.at_x, window.at_y = x, y
end

-- A window is laid out at its own size and drawn at the interface scale, so its slot is the scaled size.
local function set_size(window, width, height)
    window.sizer:SetWidthOverride(width)
    window.sizer:SetHeightOverride(height)
    window.slot:SetSize({ X = width * style.scale, Y = height * style.scale })
end

local TAB_GAP, TAB_MARGIN = 4, 20

-- A window with tabs along the top is never narrower than its tabs need. The tabs are all as wide as the widest one,
-- and stay that size however wide the window is.
-- Returns true when the window had to grow.
local function fit_tabs(window)
    if window.nav ~= "top" then return false end
    local widest = 0
    for _, page in ipairs(window.pages) do
        if not page.tab_width then
            page.item:ForceLayoutPrepass()
            page.tab_width = page.item:GetDesiredSize().X
        end
        widest = math.max(widest, page.tab_width)
    end
    for _, page in ipairs(window.pages) do
        if page.tab_set ~= widest then
            page.tab_set = widest
            page.tab:SetWidthOverride(widest)
        end
    end
    local count = #window.pages
    window.min_width = math.max(MIN_WIDTH, math.ceil(count * (widest + TAB_GAP) + TAB_MARGIN))
    if window.width >= window.min_width then return false end
    window.width = window.min_width
    return true
end

local function apply_geometry(window)
    place_on_screen(window)
    window.slot:SetPosition({ X = window.at_x, Y = window.at_y })
    set_size(window, window.width, window.minimized and bar_height() or window.height)
    if window.wrapped_at ~= window.width then
        window.wrapped_at = window.width
        controls.rewrap(window)
    end
end

local function bring_to_front(window)
    top_order = top_order + 1
    window.slot:SetZOrder(top_order)
end

function Window:SetTitle(title)
    self.title = title == nil and "" or tostring(title)
    kit.set_text(self.title_label, self.title)
end

function Window:SetPosition(x, y)
    self.x, self.y = x, y
    apply_geometry(self)
end

-- The outline takes the accent colour while the window is being moved.
local function tint_outline(window, on)
    local theme = style.theme
    if window.outline_animation then window.outline_animation.cancel() end
    local from, to = window.outline_amount or 0, on and 1 or 0
    window.outline_animation = tween.run(theme.animation, function(progress)
        window.outline_amount = from + (to - from) * progress
        style.tint(window.outline, "image", style.mix(theme.outline, theme.accent, window.outline_amount))
    end, nil, nil, window)
end

-- The piece of the outline that glows for each resize handle: a corner's two edges near it, or an edge's whole length.
local LIGHTS = { se = "glow12", sw = "glow12_sw", ne = "glow12_ne", nw = "glow12_nw", n = "glow12_n", s = "glow12_s", e = "glow12_e",
    w = "glow12_w" }

local function make_light(window, part, shape)
    local clear = style.theme.clear
    part.soft, part.glow = kit.image(clear, shape .. "_soft", 1, 1), kit.image(clear, shape, 1, 1)
    for _, image in ipairs({ part.soft, part.glow }) do
        image:SetVisibility(V.HitTestInvisible)
        kit.slot(window.glow_layer:AddChild(image), { h = H.Fill, v = VA.Fill })
    end
end

-- The outline by a resize handle glows under the mouse (level 0.5) and brighter while that handle resizes the window (level 1).
-- All eight handles are lit by this one function. A handle's two pictures are made the first time it lights up.
local function light(window, edges)
    local theme = style.theme
    local part = window.lights[edges]
    local resizing = window.drag ~= nil and window.drag.kind == "size" and window.drag.edges == edges
    local from, to = part.level or 0, resizing and 1 or (part.hover and 0.5 or 0)
    if edges == "se" then
        -- the grip itself: accent under the mouse, a brighter accent while resizing
        style.tint(window.grip_icon, "image", resizing and theme.accent_hover or (part.hover and theme.accent)
            or style.with_alpha(theme.dim, 0.55))
    end
    if not part.glow then
        if to == 0 then return end
        style.extend(window, make_light, window, part, LIGHTS[edges])
    end
    if part.animation then part.animation.cancel() end
    part.animation = tween.run(theme.animation, function(progress)
        local level = from + (to - from) * progress
        part.level = level
        local color = style.mix(theme.accent, theme.accent_hover, math.max(0, level - 0.5) * 2)
        style.tint(part.glow, "image", style.with_alpha(color, level > 0 and 0.4 + level * 0.3 or 0))
        style.tint(part.soft, "image", style.with_alpha(color, math.max(0, level - 0.5) * 0.22))
    end, nil, nil, window)
end

-- The dividing line takes the accent colour and doubles in width while the mouse is on it or dragging it.
local function light_splitter(window, on)
    local theme = style.theme
    local dragging = window.drag ~= nil and window.drag.kind == "split"
    style.tint(window.split_line, "image", dragging and theme.accent_hover or (on and theme.accent or theme.line))
    window.split_line_box:SetWidthOverride((on or dragging) and 2 or 1)
end

-- Keeps the sidebar wide enough for its longest page name and leaves the page at least MIN_PAGE.
local function set_side_width(window, width)
    width = math.max(window.side_need or MIN_SIDE, math.min(width, window.width - MIN_PAGE))
    window.side_width, window.nav_width = width, width + SPLIT_WIDTH
    window.side_sizer:SetWidthOverride(width)
    window.wrapped_at = nil
end

-- A handle went down: its edges follow the mouse from now on (M.step), no smaller than the window may be and no further than the screen.
local function take_edge(window, handle, edges)
    if window.minimized then return end
    local scale = style.scale
    bring_to_front(window)
    local limits = { min_width = window.min_width, min_height = window.min_height }
    if root.screen_known() then
        local wide, high = root.viewport_size()
        limits.left, limits.top, limits.right, limits.bottom = 0, 0, wide / scale, high / scale
        limits.reach_x, limits.reach_y = wide / scale - 80, high / scale - bar_height()
    end
    window.drag = { kind = "size", widget = handle, edges = edges, hold = grab.hold(handle), limits = limits,
        west = edges:find("w", 1, true) ~= nil, north = edges:find("n", 1, true) ~= nil,
        box = { x = window.at_x / scale, y = window.at_y / scale, width = window.width, height = window.height } }
    light(window, edges)
end

-- The edges that are held go where the mouse is. Only the left and the top edge move the window's place. False while the mouse rests.
local function follow_edge(window, held)
    local scale = style.scale
    local dx, dy = grab.moved(held.hold, scale)
    if dx == held.dx and dy == held.dy then return false end
    held.dx, held.dy = dx, dy
    local x, y, width, height = grab.resize(held.box, held.edges, dx, dy, held.limits)
    if held.west then window.x = x * scale end
    if held.north then window.y = y * scale end
    local wider = width ~= window.width
    window.width, window.height = width, height
    if wider and window.side_sizer then set_side_width(window, window.side_width) end
    return true
end

function Window:SetSize(width, height)
    self.width, self.height = math.max(self.min_width, width), math.max(self.min_height, height)
    if self.side_sizer then set_side_width(self, self.side_width) end
    apply_geometry(self)
end

-- Width of the navigation column of a window made with nav = "side". The user can also drag its edge.
function Window:SetNavWidth(width)
    if not self.side_sizer then error("this window has no side navigation", 2) end
    set_side_width(self, width)
    apply_geometry(self)
end

function Window:Show()
    if self.destroyed or self.shown then return end
    self.shown, self.closed_by_user = true, false
    self.frame:SetVisibility(V.Visible)
    bring_to_front(self)
    if self.animation then self.animation.cancel() end
    self.animation = tween.run(style.theme.animation, function(progress)
        self.frame:SetRenderOpacity(progress)
        self.frame:SetRenderTranslation({ X = 0, Y = (1 - progress) * 10 })
    end, nil, nil, self)
    self.Opened:Fire()
    if M.on_shown and not self.making then M.on_shown(self) end
end

function Window:Hide()
    if self.destroyed or not self.shown then return end
    self.shown = false
    if self.animation then self.animation.cancel() end
    self.animation = tween.run(style.theme.animation, function(progress)
        self.frame:SetRenderOpacity(1 - progress)
        self.frame:SetRenderTranslation({ X = 0, Y = progress * 10 })
    end, function() self.frame:SetVisibility(V.Collapsed) end, nil, self)
    self.Closed:Fire()
    if M.on_hidden then M.on_hidden(self) end
end

function Window:SetVisible(shown) if shown then self:Show() else self:Hide() end end
function Window:IsVisible() return self.shown end
-- True while it is really on screen: shown, and its owner's windows are up (or the windows are in preview).
function Window:IsShowing() return self.shown == true and self.on_screen == true end

function Window:SetMinimized(minimized)
    minimized = minimized and true or false
    if self.minimized == minimized then return end
    self.minimized = minimized
    if self.size_animation then self.size_animation.cancel() end
    local from, to = minimized and self.height or bar_height(), minimized and bar_height() or self.height
    local hidden = minimized and V.Collapsed or V.Visible
    self.rule:SetVisibility(minimized and V.Collapsed or V.HitTestInvisible)
    if self.grip then self.grip:SetVisibility(hidden) end
    if self.resize_layer then self.resize_layer:SetVisibility(minimized and V.Collapsed or V.SelfHitTestInvisible) end
    self.glow_layer:SetVisibility(minimized and V.Collapsed or V.HitTestInvisible)
    if self.status_holder then self.status_holder:SetVisibility(hidden) end
    self.minus_icon:SetVisibility(minimized and V.Hidden or V.HitTestInvisible)
    self.plus_icon:SetVisibility(minimized and V.HitTestInvisible or V.Hidden)
    if not minimized then self.body:SetVisibility(V.Visible) end
    self.size_animation = tween.run(style.theme.animation, function(progress)
        set_size(self, self.width, from + (to - from) * progress)
        self.body:SetRenderOpacity(minimized and 1 - progress or progress)
    end, function()
        if minimized then self.body:SetVisibility(V.Collapsed) end
    end, nil, self)
end

function Window:IsMinimized() return self.minimized end

local function build_status(self, status, text)
    local theme = style.theme
    local holder = root.new("VerticalBox")
    holder:SetClipping(style.Clip.ClipToBounds)
    local rule = kit.image(theme.line, nil, 1, 1)
    rule:SetVisibility(V.HitTestInvisible)
    kit.slot(holder:AddChild(rule), { h = H.Fill })
    local cells = root.new("HorizontalBox")
    local fill = kit.box(theme.accent, nil)
    local fill_slot = cells:AddChild(fill)
    local rest_slot = cells:AddChild(root.new("Spacer"))
    local line = kit.sized(cells, nil, 2)
    kit.slot(holder:AddChild(line), { h = H.Fill })

    local row = root.new("HorizontalBox")
    local spinner = root.new("CircularThrobber")
    style.paint(spinner.Image, style.WHITE, style.capsule(4), 4, 4)
    spinner:SetNumberOfPieces(8)
    spinner:SetPeriod(0.9)
    spinner:SetRadius(6)
    local spinner_box = kit.box(theme.clear, nil, style.margin(0, 0, 8, 0))
    spinner_box:SetContent(spinner)
    spinner_box:SetVisibility(V.Collapsed)
    kit.slot(row:AddChild(spinner_box), { v = VA.Center })
    local icon_box = kit.sized(nil, 14, 14)
    icon_box:SetVisibility(V.Collapsed)
    kit.slot(row:AddChild(icon_box), { v = VA.Center, pad = style.margin(0, 0, 7, 0) })
    local label = kit.label(text or "", { color = theme.dim, size = theme.small_size })
    kit.slot(row:AddChild(label), { v = VA.Center, fill = 1 })
    local note = kit.label("", { color = theme.dim, size = theme.small_size, free = true })
    kit.slot(row:AddChild(note), { v = VA.Center, pad = style.margin(10, 0, 0, 0) })
    local padded = kit.box(theme.clear, nil, style.margin(14, 4, 28, 6))
    padded:SetContent(row)
    kit.slot(holder:AddChild(padded), { h = H.Fill })
    kit.slot(self.column:AddChild(holder), { h = H.Fill })
    if self.minimized then holder:SetVisibility(V.Collapsed) end
    self.status_holder = holder

    status.widget = holder
    self.controls[#self.controls + 1] = status
    local picture, picture_name = nil, nil
    local KIND = { info = "dim", good = "good", warn = "warn", bad = "bad" }
    -- one line: the note at the right shows whole, and the message has the room that is left, cut with dots when it is longer
    local window, marked = self, 0
    local function fit()
        local said = kit.said(note) or ""
        local taken = said ~= "" and kit.text_width(said, theme.small_size) / kit.FIT + 10 or 0
        kit.fit(label, window.width - 42 - marked - taken)
    end
    window.resizers = window.resizers or {}
    window.resizers[#window.resizers + 1] = style.claim({ apply = fit })
    local function show_progress(amount)
        line:SetVisibility(amount and V.HitTestInvisible or V.Hidden)
        if not amount then return end
        amount = math.max(0, math.min(1, amount))
        fill_slot:SetSize({ SizeRule = style.SizeRule.Fill, Value = math.max(amount, 0.0001) })
        rest_slot:SetSize({ SizeRule = style.SizeRule.Fill, Value = math.max(1 - amount, 0.0001) })
    end
    local function show(message, options, busy)
        options = options or {}
        local kind = KIND[options.kind or "info"]
        if not kind then error("a status kind is \"info\", \"good\", \"warn\" or \"bad\"", 3) end
        local color = style.theme[kind]
        kit.set_text(label, message or "")
        style.tint(label, "text", color)
        spinner_box:SetVisibility(busy and V.HitTestInvisible or V.Collapsed)
        marked = (busy or options.icon) and 21 or 0
        fit()
        if options.icon and not busy then
            if not picture then
                picture = style.extend(status, kit.icon, options.icon, 14, color)
                icon_box:SetContent(picture)
            elseif options.icon ~= picture_name then
                kit.set_icon(picture, options.icon, 14)
            end
            picture_name = options.icon
            style.tint(picture, "image", color)
            icon_box:SetVisibility(V.HitTestInvisible)
        else
            icon_box:SetVisibility(V.Collapsed)
        end
    end
    -- options: { kind = "info" | "good" | "warn" | "bad", icon }
    function status:Set(message, options) show(message, options, false) end
    -- Text with a turning indicator beside it, until the next Set.
    function status:Busy(message) show(message, nil, true) end
    -- A thin line across the top of the bar, 0..1. nil hides it.
    function status:Progress(amount) show_progress(amount) end
    function status:Right(message)
        if kit.said(note) == (message or "") then return end
        kit.set_text(note, message or "")
        fit()
    end
    function status:Clear()
        show("", nil, false)
        show_progress(nil)
    end
    style.follow(function() spinner_box:SetContentColorAndOpacity(style.theme.accent) end)
    show_progress(nil)
    fit()
end

-- A line along the bottom of the window for what is going on. Returns the status bar (Set, Busy, Progress, Right, Clear).
function Window:StatusBar(text)
    if self.status then
        if text then self.status:Set(text) end
        return self.status
    end
    local status = { window = self, disconnects = {}, destroyed = false }
    style.build(status, build_status, self, status, text)
    self.status = status
    return status
end

function Window:Destroy()
    if self.destroyed then return end
    self.destroyed = true
    for _, control in ipairs(self.controls) do
        for _, disconnect in ipairs(control.disconnects) do disconnect() end
        controls.retire(control)
    end
    for _, page in ipairs(self.pages or {}) do page.destroyed = true end
    self.drag = nil
    pcall(function() self.outer:RemoveFromParent() end)
    for index, other in ipairs(windows) do
        if other == self then
            table.remove(windows, index)
            break
        end
    end
    if self.owner and self.owner_slot then self.owner:remove(self.owner_slot) end
    if M.on_hidden then M.on_hidden(self, true) end
    setmetatable(self, Gone)
end

local function scrolling_column()
    local scroller = kit.scroll_box()
    local box = root.new("VerticalBox")
    kit.slot(scroller:AddChild(box), { pad = style.margin(0, 0, kit.GUTTER, 0) })
    return scroller, box
end

local function select_page(window, page)
    if window.page == page then return end
    local theme = style.theme
    for _, other in ipairs(window.pages) do
        local selected = other == page
        other.marker:SetVisibility(selected and V.HitTestInvisible or V.Hidden)
        other.backing:SetVisibility(selected and V.HitTestInvisible or V.Hidden)
        style.tint(other.caption, "text", selected and theme.text or theme.dim)
        if other.icon then style.tint(other.icon, "image", selected and theme.accent_hover or theme.dim) end
    end
    window.page = page
    window.switcher:SetActiveWidgetIndex(page.index)
    if page.animation then page.animation.cancel() end
    page.animation = tween.run(theme.animation, function(progress)
        page.holder:SetRenderOpacity(progress)
        page.holder:SetRenderTranslation({ X = 0, Y = (1 - progress) * 6 })
    end, nil, nil, page)
    window.PageChanged:Fire(page.name)
end

local NEAR_END = 160

-- Fires target.NearEnd when the user scrolls near the bottom (M.step also fires it while a page is not full). Returns the disconnect.
local function watch_scroll(window, scroller, target)
    target.NearEnd = sched.Signal.new("NearEnd")
    target.scroller = scroller
    local last = 0
    return events.connect(scroller, "OnUserScrolled", window.parking, function(offset)
        local now = os.clock()
        if now - last < 0.15 then return end
        if scroller:GetScrollOffsetOfEnd() - offset < NEAR_END then
            last = now
            target.NearEnd:Fire()
        end
    end)
end

local function build_page(self, page, name, options)
    local theme = style.theme
    local side = self.nav == "side"
    local scroller, box, holder
    if options.scroll == false then
        -- controls stack from the top and one of them (a grid) may take what is left
        box = root.new("VerticalBox")
        holder = kit.box(theme.clear, nil, style.margin(theme.padding, theme.padding, 2 + kit.GUTTER, theme.padding))
        holder:SetContent(box)
        page.bounded = true
    else
        scroller, box = scrolling_column()
        holder = kit.box(theme.clear, nil, style.margin(theme.padding, theme.padding, 2, theme.padding))
        holder:SetContent(scroller)
    end
    self.switcher:AddChild(holder)

    local item = root.new("Overlay")
    local backing = kit.box(theme.raised, "round6")
    kit.slot(item:AddChild(backing), { h = H.Fill, v = VA.Fill })
    local button = kit.button(nil, { shape = "round6", color = theme.clear, hover = style.with_alpha(theme.hover, 0.6),
        press = theme.press, padding = side and style.margin(10, 7) or style.margin(12, 7) })
    local row = root.new("HorizontalBox")
    local icon = nil
    if options.icon then
        icon = kit.icon(options.icon, 14, theme.dim)
        kit.slot(row:AddChild(icon), { v = VA.Center, pad = style.margin(0, 0, 8, 0) })
    end
    local caption = kit.label(name, { color = theme.dim, free = true })
    kit.slot(row:AddChild(caption), { v = VA.Center, fill = side and 1 or nil })
    if side then
        kit.fill_content(button, row)
    else
        -- a tab's icon and name sit in the middle of it
        kit.slot(button:SetContent(row), { h = H.Center, v = VA.Center })
    end
    kit.slot(item:AddChild(button), { h = H.Fill, v = VA.Fill })
    local marker = kit.image(theme.accent, style.capsule(3), side and 3 or 16, side and 14 or 3)
    marker:SetVisibility(V.Hidden)
    backing:SetVisibility(V.Hidden)
    kit.slot(item:AddChild(marker), side and { h = H.Left, v = VA.Center } or { h = H.Center, v = VA.Bottom })

    local list = options.bottom and side and self.nav_bottom or self.nav_list
    local tab = item
    if side then
        kit.slot(list:AddChild(item), { h = H.Fill, pad = style.margin(0, 0, 0, 2) })
    else
        tab = kit.sized(item)
        kit.slot(list:AddChild(tab), { v = VA.Center, pad = style.margin(0, 0, TAB_GAP, 0) })
    end
    page.tab = tab

    page.box, page.scroller = box, scroller
    page.name, page.index, page.holder = tostring(name), #self.pages, holder
    page.marker, page.backing, page.caption, page.icon, page.item = marker, backing, caption, icon, item
    page.button = button
    self.pages[#self.pages + 1] = page
    if side and self.side_sizer then
        -- the name must never be cut off: 60 for the padding and the icon, about 9 a letter
        local need = math.min(MAX_SIDE_NEED, 60 + math.ceil((utf8.len(page.name) or #page.name) * 9.2))
        if need > (self.side_need or MIN_SIDE) then
            self.side_need = need
            if self.side_width < need then set_side_width(self, need) end
        end
    end
    local unwatch = scroller and watch_scroll(self, scroller, page) or function() end
    -- fired when the page's own name is pressed while the page is already showing
    page.PressedAgain = sched.Signal.new("PressedAgain")
    local unclick = events.connect(button, "OnClicked", self.parking, function()
        if self.page == page then page.PressedAgain:Fire() end
        select_page(self, page)
    end)
    -- a page disconnects its own events when it is removed, while its widgets still exist
    page.disconnect = function()
        unwatch()
        unclick()
    end
    local chrome = self.chrome
    chrome.disconnects[#chrome.disconnects + 1] = function() if not page.destroyed then page.disconnect() end end
    if #self.pages == 1 then select_page(self, page) end
    if fit_tabs(self) then apply_geometry(self) end
end

-- A page of a window made with nav = "side" or "top". Returns a container. options: { icon, bottom, scroll = true }
function Window:Page(name, options)
    if not self.nav then error("this window has no pages. Create it with nav = \"side\" or nav = \"top\"", 2) end
    local page = controls.container(self, nil, { inset = style.theme.padding * 2 + 2 })
    style.build(page, build_page, self, page, name, options or {})
    return page
end

-- Removes a page made with Window:Page, with everything on it.
function Window:RemovePage(page)
    for index, other in ipairs(self.pages or {}) do
        if other == page then
            table.remove(self.pages, index)
            controls.destroy_within(self, page)
            page.destroyed = true
            if page.disconnect then page.disconnect() end
            pcall(function()
                page.tab:RemoveFromParent()
                page.holder:RemoveFromParent()
            end)
            for position, remaining in ipairs(self.pages) do remaining.index = position - 1 end
            fit_tabs(self)
            if self.page == page then
                self.page = nil
                if self.pages[1] then select_page(self, self.pages[1]) end
            elseif self.page then
                self.switcher:SetActiveWidgetIndex(self.page.index)
            end
            return
        end
    end
end

function Window:SelectPage(name)
    for _, page in ipairs(self.pages or {}) do
        if page.name == name then return select_page(self, page) end
    end
    error("no page named '" .. tostring(name) .. "'", 2)
end

-- Controls added straight to a window with pages go to a first page called "Main".
function Window:DefaultBox()
    if not self.nav then error("the window has no body", 2) end
    local page = self:Page("Main", { icon = "home" })
    self.box, self.inset, self.scroller = page.box, page.inset, page.scroller
    return self.box
end

local function build(window, options)
    local theme, nav = style.theme, window.nav
    local frame = root.new("Overlay")
    frame:SetClipping(style.Clip.ClipToBounds)
    window.frame = frame
    kit.slot(frame:AddChild(kit.box(theme.window, theme.window_shape)), { h = H.Fill, v = VA.Fill })
    local column = root.new("VerticalBox")
    kit.slot(frame:AddChild(column), { h = H.Fill, v = VA.Fill })
    window.column = column

    -- title bar: a button, so pressing and holding it drags the window
    local bar = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear,
        padding = style.margin(14, 0, 6, 0), cursor = style.Cursor.Default })
    local bar_row = root.new("HorizontalBox")
    if options.icon then
        local title_icon = kit.icon(options.icon, 16, theme.accent_hover)
        kit.slot(bar_row:AddChild(title_icon), { v = VA.Center, pad = style.margin(0, 0, 8, 0) })
    end
    window.title_label = kit.label(window.title, { size = theme.title_size, face = "Bold" })
    kit.slot(bar_row:AddChild(window.title_label), { v = VA.Center, fill = 1 })
    local minimize_icons = root.new("Overlay")
    window.minus_icon, window.plus_icon = kit.icon("minus", 14, theme.dim), kit.icon("plus", 14, theme.dim)
    minimize_icons:AddChild(window.minus_icon)
    minimize_icons:AddChild(window.plus_icon)
    window.plus_icon:SetVisibility(V.Hidden)
    local minimize_box, minimize = kit.icon_button(nil, { content = minimize_icons })
    kit.slot(bar_row:AddChild(minimize_box), { v = VA.Center, pad = style.margin(4, 0, 0, 0) })
    local close = nil
    if options.closable ~= false then
        local close_box
        close_box, close = kit.icon_button("x", { hover = theme.bad, press = theme.bad, icon_size = 14 })
        kit.slot(bar_row:AddChild(close_box), { v = VA.Center, pad = style.margin(2, 0, 0, 0) })
    end
    kit.fill_content(bar, bar_row)
    kit.slot(column:AddChild(kit.sized(bar, nil, bar_height())), { h = H.Fill })
    -- the title is one line in the bar, beside the icon and the buttons: one too long for it ends in dots
    local beside = 28 + (options.icon and 24 or 0) + 30 + (close and 28 or 0)
    window.resizers = window.resizers or {}
    window.resizers[#window.resizers + 1] = style.claim({ apply = function() kit.fit(window.title_label, window.width - beside) end })

    window.rule = kit.image(theme.line, nil, 1, 1)
    window.rule:SetVisibility(V.HitTestInvisible)
    kit.slot(column:AddChild(window.rule), { h = H.Fill })

    if nav == "side" then
        local body = root.new("HorizontalBox")
        local side = root.new("VerticalBox")
        window.nav_list = root.new("VerticalBox")
        window.nav_bottom = root.new("VerticalBox")
        local nav_scroll = kit.scroll_box()
        nav_scroll:AddChild(window.nav_list)
        kit.slot(side:AddChild(nav_scroll), { h = H.Fill, fill = 1 })
        kit.slot(side:AddChild(window.nav_bottom), { h = H.Fill })
        local side_box = kit.box(theme.clear, nil, style.margin(8, 10, 8, 10))
        side_box:SetContent(side)
        window.side_width = window.nav_width
        window.side_sizer = kit.sized(side_box, window.side_width)
        kit.slot(body:AddChild(window.side_sizer), { v = VA.Fill })
        -- the dividing line is a thin button: press and drag it to resize the navigation column
        local splitter = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear,
            padding = style.margin(0) })
        window.split_line = kit.image(theme.line, nil, 1, 1)
        window.split_line:SetVisibility(V.HitTestInvisible)
        window.split_line_box = kit.sized(window.split_line, 1)
        kit.slot(splitter:SetContent(window.split_line_box), { h = H.Center, v = VA.Fill })
        splitter.IsFocusable = false
        splitter:SetCursor(style.Cursor.ResizeLeftRight)
        window.splitter = splitter
        kit.slot(body:AddChild(kit.sized(splitter, SPLIT_WIDTH)), { v = VA.Fill })
        window.switcher = root.new("WidgetSwitcher")
        kit.slot(body:AddChild(window.switcher), { v = VA.Fill, h = H.Fill, fill = 1 })
        window.body = body
        window.nav_width = window.side_width + SPLIT_WIDTH
    elseif nav == "top" then
        local body = root.new("VerticalBox")
        window.nav_list = root.new("HorizontalBox")
        local tabs = kit.box(theme.clear, nil, style.margin(10, 6, 10, 6))
        tabs:SetContent(window.nav_list)
        kit.slot(body:AddChild(tabs), { h = H.Fill })
        local divider = kit.image(theme.line, nil, 1, 1)
        divider:SetVisibility(V.HitTestInvisible)
        kit.slot(body:AddChild(divider), { h = H.Fill })
        window.switcher = root.new("WidgetSwitcher")
        kit.slot(body:AddChild(window.switcher), { h = H.Fill, v = VA.Fill, fill = 1 })
        window.body = body
    else
        local scroller, box = scrolling_column()
        local holder = kit.box(theme.clear, nil, style.margin(theme.padding, theme.padding, 2, theme.padding))
        holder:SetContent(scroller)
        window.body, window.box, window.scroller = holder, box, scroller
    end
    -- the body sits in a see-through button, so the window is told of a click on empty space too
    local backdrop = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear,
        padding = style.margin(0), cursor = style.Cursor.Default })
    kit.slot(backdrop:SetContent(window.body), { h = H.Fill, v = VA.Fill, pad = style.margin(0) })
    window.backdrop = backdrop
    kit.slot(column:AddChild(backdrop), { h = H.Fill, v = VA.Fill, fill = 1 })

    local outline = kit.image(theme.outline, "frame12", 1, 1)
    outline:SetVisibility(V.HitTestInvisible)
    kit.slot(frame:AddChild(outline), { h = H.Fill, v = VA.Fill })
    window.outline = outline
    -- where the outline glows by a resize handle: each handle's pictures are put in here when it first lights up
    window.glow_layer = root.new("Overlay")
    window.glow_layer:SetVisibility(V.HitTestInvisible)
    kit.slot(frame:AddChild(window.glow_layer), { h = H.Fill, v = VA.Fill })
    window.lights = {}

    local grip = nil
    if window.resizable then
        -- see-through buttons over the edges and the corners: each one, held, resizes the window from there
        local layer = root.new("Overlay")
        layer:SetVisibility(V.SelfHitTestInvisible)
        kit.slot(frame:AddChild(layer), { h = H.Fill, v = VA.Fill })
        window.resize_layer, window.edge_handles = layer, {}
        for _, part in ipairs(HANDLES) do
            local handle = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear,
                padding = style.margin(0), cursor = part.cursor })
            kit.slot(layer:AddChild(kit.sized(handle, part.width, part.height)), { h = part.h, v = part.v })
            window.edge_handles[part.edges] = handle
        end
        -- the grip is the bottom right corner, and the one that shows. light() colours the icon inside it.
        grip = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear,
            padding = style.margin(0, 0, GRIP - 16, GRIP - 16), cursor = style.Cursor.ResizeSouthEast })
        window.grip_icon = kit.icon("wax-grip", 16, style.with_alpha(theme.dim, 0.55))
        kit.slot(grip:SetContent(window.grip_icon), { h = H.Fill, v = VA.Fill, pad = style.margin(0) })
        window.grip = kit.sized(grip, GRIP, GRIP)
        kit.slot(frame:AddChild(window.grip), { h = H.Right, v = VA.Bottom })
        window.edge_handles.se = grip
        for edges in pairs(window.edge_handles) do window.lights[edges] = { hover = false, level = 0 } end
    end

    window.parking = root.new("VerticalBox")
    window.parking:SetVisibility(V.Collapsed)
    frame:AddChild(window.parking)

    frame:SetRenderOpacity(0)
    frame:SetVisibility(V.Collapsed)
    window.sizer = kit.sized(frame, window.width, window.height)
    window.outer = kit.scaled(window.sizer)
    window.slot = root.layer("windows"):AddChild(window.outer)
    window.slot:SetAutoSize(false)
    local owner = scope.current()
    window.memory_key = options.remember ~= false and ((owner and owner.name or "wax") .. "/" .. window.title) or nil
    local remembered = window.memory_key and M.recall and M.recall(window.memory_key)
    if remembered then
        window.x, window.y = remembered.x or window.x, remembered.y or window.y
        -- a window the player cannot resize is the size its mod gave it
        if window.resizable then
            window.width = math.max(window.min_width, remembered.width or window.width)
            window.height = math.max(window.min_height, remembered.height or window.height)
        end
        if window.side_sizer and remembered.side then set_side_width(window, remembered.side) end
    end
    apply_geometry(window)

    local chrome = { window = window, widget = bar, disconnects = {}, destroyed = false }
    window.controls[1] = chrome
    window.chrome = chrome
    local function listen(widget, delegate, handler)
        chrome.disconnects[#chrome.disconnects + 1] = events.connect(widget, delegate, window.parking, handler)
    end
    listen(bar, "OnPressed", function()
        local mouse_x, mouse_y = root.mouse()
        bring_to_front(window)
        -- the player takes it from where it is drawn, and where they leave it is its place from then on
        window.x, window.y = window.at_x or window.x, window.at_y or window.y
        window.drag = { kind = "move", widget = bar, mouse_x = mouse_x, mouse_y = mouse_y, x = window.x, y = window.y }
        tint_outline(window, true)
    end)
    listen(window.backdrop, "OnPressed", function() end)
    if grip then
        -- every handle the same way: lit under the mouse, brighter while it is held
        for edges, handle in pairs(window.edge_handles) do
            local part = window.lights[edges]
            listen(handle, "OnHovered", function()
                part.hover = true
                light(window, edges)
            end)
            listen(handle, "OnUnhovered", function()
                part.hover = false
                light(window, edges)
            end)
            listen(handle, "OnPressed", function() take_edge(window, handle, edges) end)
        end
    end
    if window.splitter then
        listen(window.splitter, "OnPressed", function()
            local mouse_x = root.mouse()
            window.drag = { kind = "split", widget = window.splitter, mouse_x = mouse_x, side = window.side_width }
            light_splitter(window, true)
        end)
        listen(window.splitter, "OnHovered", function()
            window.split_hover = true
            light_splitter(window, true)
        end)
        listen(window.splitter, "OnUnhovered", function()
            window.split_hover = false
            if not (window.drag and window.drag.kind == "split") then light_splitter(window, false) end
        end)
    end
    window.bar, window.grip_button, window.minimize_button, window.close_button = bar, grip, minimize, close
    listen(minimize, "OnClicked", function() window:SetMinimized(not window.minimized) end)
    if close then
        listen(close, "OnClicked", function()
            window.closed_by_user = true
            window:Hide()
        end)
    end

    if window.scroller then chrome.disconnects[#chrome.disconnects + 1] = watch_scroll(window, window.scroller, window) end
end

-- Whose windows are on screen is the menu's business (gui.init): it answers here for one owner, "Wax" or a mod's id.
M.visible_for = function(_) return true end
-- True while the mouse belongs to the interface: a pinned window takes clicks then, and lets them through otherwise.
M.interactive = function() return true end

function M.any_pinned()
    for i = 1, #windows do
        if windows[i].pinned and windows[i].shown then return true end
    end
    return false
end

-- Puts every window on or off the screen as its owner is. mode "fade" animates what changes, "logic" leaves the widgets as they are.
function M.sync(mode)
    for i = 1, #windows do
        local window = windows[i]
        local on = (window.pinned or M.visible_for(window.owner_id)) and true or false
        window.on_screen = on
        -- a pinned window is there while you play, and only takes the mouse while the menu is open
        local looks = (not window.pinned or M.interactive()) and V.Visible or V.HitTestInvisible
        if on and window.outer_on and window.outer_looks ~= looks then
            window.outer_looks = looks
            window.outer:SetVisibility(looks)
        end
        if mode ~= "logic" and on ~= window.outer_on then
            window.outer_looks = looks
            window.outer_on = on
            if window.owner_animation then window.owner_animation.cancel() end
            if mode == "fade" then
                if on then window.outer:SetVisibility(looks) end
                window.owner_animation = tween.run(style.theme.animation, function(progress)
                    window.outer:SetRenderOpacity(on and progress or 1 - progress)
                end, function()
                    if not on then window.outer:SetVisibility(V.Collapsed) end
                end, nil, window)
            else
                window.outer:SetRenderOpacity(1)
                window.outer:SetVisibility(on and looks or V.Collapsed)
            end
        end
    end
end

-- options: { title, icon, width, height, x, y, closable = true, resizable = true, visible = true, nav = nil | "side" | "top", nav_width, remember = true }
function M.create(options, owner)
    if not root.exists() then error("the GUI is not running", 2) end
    options = options or {}
    local theme = style.theme
    local nav = options.nav
    if nav ~= nil and nav ~= "side" and nav ~= "top" then error("nav is \"side\", \"top\" or nil", 2) end
    local window = setmetatable({
        title = tostring(options.title or "Window"), controls = {}, nav = nav, pages = nav and {} or nil,
        nav_width = nav == "side" and (options.nav_width or theme.nav_width) or 0,
        min_width = nav == "side" and 420 or MIN_WIDTH,
        -- tabs along the top take a strip of their own, so such a window needs more height before it is of any use
        min_height = nav == "top" and MIN_HEIGHT + 60 or MIN_HEIGHT,
        width = math.max(nav == "side" and 420 or MIN_WIDTH, options.width or (nav == "side" and 520 or 340)),
        height = math.max(nav == "top" and MIN_HEIGHT + 60 or MIN_HEIGHT, options.height or (nav and 380 or 420)),
        x = options.x or (60 + #windows * 30), y = options.y or (70 + #windows * 30),
        shown = false, minimized = false, horizontal = false, count = 0, resizable = options.resizable ~= false,
        pinned = options.pinned == true,
        inset = theme.padding * 2 + 2,
        Opened = sched.Signal.new("Opened"), Closed = sched.Signal.new("Closed"), PageChanged = sched.Signal.new("PageChanged"),
    }, Window)
    window.window = window
    style.build(window, build, window, options)
    window.owner_id = owner or "Wax"
    local on = (window.pinned or M.visible_for(window.owner_id)) and true or false
    window.on_screen, window.outer_on = on, on
    if not on then
        window.outer:SetVisibility(V.Collapsed)
    elseif window.pinned and not M.interactive() then
        window.outer_looks = V.HitTestInvisible
        window.outer:SetVisibility(V.HitTestInvisible)
    end
    windows[#windows + 1] = window
    window.owner, window.owner_slot = scope.own(function() window:Destroy() end)
    if options.visible ~= false then
        -- a window that starts shown waits for its owner's key like any other: only a later Show() brings its owner up
        window.making = true
        window:Show()
        window.making = nil
    end
    return window
end

-- Called every frame while the menu is open: follows the mouse for the window being moved or resized.
local step_count = 0
function M.step()
    step_count = step_count + 1
    for i = 1, #windows do
        local window = windows[i]
        if step_count % 20 == 0 and window.shown and window.on_screen and not window.minimized then
            -- the page being shown, when its end is in view
            local target = window.nav and window.page or window
            local scroller = target and target.scroller
            if scroller and target.NearEnd and scroller:GetScrollOffsetOfEnd() - scroller:GetScrollOffset() < NEAR_END then
                target.NearEnd:Fire()
            end
        end
        local drag = window.drag
        if drag then
            if not grab.down(drag.widget) then
                window.drag = nil
                if drag.kind == "split" then light_splitter(window, window.split_hover) end
                if drag.kind == "move" then tint_outline(window, false) end
                if drag.kind == "size" then light(window, drag.edges) end
                if window.memory_key and M.remember then
                    M.remember(window.memory_key, { x = window.x, y = window.y, width = window.width, height = window.height,
                        side = window.side_width })
                end
            elseif drag.kind == "size" then
                if follow_edge(window, drag) then apply_geometry(window) end
            else
                local mouse_x, mouse_y = root.mouse()
                if drag.kind == "move" then
                    window.x, window.y = drag.x + mouse_x - drag.mouse_x, drag.y + mouse_y - drag.mouse_y
                    place_on_screen(window)
                    window.x, window.y = window.at_x, window.at_y
                else
                    set_side_width(window, drag.side + (mouse_x - drag.mouse_x) / style.scale)
                end
                apply_geometry(window)
            end
        end
    end
end

-- After the interface scale changed.
function M.rescale()
    for i = 1, #windows do
        windows[i].outer:SetUserSpecifiedScale(style.scale)
        apply_geometry(windows[i])
    end
end

-- After the screen changed size: a window that is no longer where it belongs is moved, and nothing else is touched.
function M.keep_on_screen()
    for i = 1, #windows do
        local window = windows[i]
        local x, y = window.at_x, window.at_y
        place_on_screen(window)
        if window.at_x ~= x or window.at_y ~= y then window.slot:SetPosition({ X = window.at_x, Y = window.at_y }) end
    end
end

-- Marks every window and control gone without touching a widget.
function M.forget_all()
    for i = #windows, 1, -1 do
        local window = windows[i]
        window.destroyed, window.drag = true, nil
        for _, control in ipairs(window.controls) do controls.retire(control) end
        for _, page in ipairs(window.pages or {}) do page.destroyed = true end
        if window.owner and window.owner_slot then window.owner:remove(window.owner_slot) end
        setmetatable(window, Gone)
        windows[i] = nil
    end
end

function M.destroy_all()
    for i = #windows, 1, -1 do windows[i]:Destroy() end
end

return M
