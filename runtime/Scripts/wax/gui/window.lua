-- Windows: the frame, dragging and resizing, minimising, and pages with side or top navigation

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")
local events = Wax.import("gui.events")
local tween = Wax.import("gui.tween")
local controls = Wax.import("gui.controls")
local scope = Wax.import("core.scope")
local sched = Wax.import("core.sched")

local M = {}

local V, H, VA = style.Visibility, style.HAlign, style.VAlign
local MIN_WIDTH, MIN_HEIGHT = 240, 140
local SPLIT_WIDTH, MIN_SIDE, MIN_PAGE = 7, 96, 220
local windows = {}
local top_order = 0
M.windows = windows

local Window = setmetatable({}, { __index = controls.Container })
Window.__index = Window

-- What a destroyed window turns into: it still answers IsVisible and Destroy, and everything else raises an error.
local Gone = {}
Gone.__index = function(_, key)
    if key == "IsVisible" or key == "IsMinimized" then return function() return false end end
    if key == "Destroy" or key == "Hide" then return function() end end
    return function() error("this window no longer exists (it was destroyed or its mod reloaded)", 2) end
end

local function bar_height() return style.theme.bar_height end

local function clamp_to_viewport(window)
    local width, height = root.viewport_size()
    if width < 200 or height < 200 then return end      -- the screen has no size yet (the game is still starting)
    window.x = math.max(0, math.min(window.x, math.max(0, width - 80 * style.scale)))
    window.y = math.max(0, math.min(window.y, math.max(0, height - bar_height() * style.scale)))
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
    window.slot:SetPosition({ X = window.x, Y = window.y })
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
    self.title = tostring(title)
    self.title_label:SetText(kit.text(self.title))
end

function Window:SetPosition(x, y)
    self.x, self.y = x, y
    clamp_to_viewport(self)
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

-- The edges by the resize grip glow under the mouse (level 0.5) and brighter while resizing (level 1).
local function light_corner(window)
    local theme = style.theme
    local resizing = window.drag ~= nil and window.drag.kind == "size"
    local from, to = window.glow_level or 0, resizing and 1 or (window.grip_hover and 0.5 or 0)
    -- the grip itself: accent under the mouse, a brighter accent while resizing
    style.tint(window.grip_icon, "image", resizing and theme.accent_hover or (window.grip_hover and theme.accent)
        or style.with_alpha(theme.dim, 0.55))
    if window.glow_animation then window.glow_animation.cancel() end
    window.glow_animation = tween.run(theme.animation, function(progress)
        local level = from + (to - from) * progress
        window.glow_level = level
        local color = style.mix(theme.accent, theme.accent_hover, math.max(0, level - 0.5) * 2)
        style.tint(window.glow, "image", style.with_alpha(color, level > 0 and 0.4 + level * 0.3 or 0))
        style.tint(window.glow_soft, "image", style.with_alpha(color, math.max(0, level - 0.5) * 0.22))
    end, nil, nil, window)
end

-- The dividing line takes the accent colour and doubles in width while the mouse is on it or dragging it.
local function light_splitter(window, on)
    local theme = style.theme
    local dragging = window.drag ~= nil and window.drag.kind == "split"
    style.tint(window.split_line, "image", dragging and theme.accent_hover or (on and theme.accent or theme.line))
    window.split_line_box:SetWidthOverride((on or dragging) and 2 or 1)
end

-- Keeps the sidebar at least MIN_SIDE wide and leaves the page at least MIN_PAGE.
local function set_side_width(window, width)
    width = math.max(MIN_SIDE, math.min(width, window.width - MIN_PAGE))
    window.side_width, window.nav_width = width, width + SPLIT_WIDTH
    window.side_sizer:SetWidthOverride(width)
    window.wrapped_at = nil
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

function Window:SetMinimized(minimized)
    minimized = minimized and true or false
    if self.minimized == minimized then return end
    self.minimized = minimized
    if self.size_animation then self.size_animation.cancel() end
    local from, to = minimized and self.height or bar_height(), minimized and bar_height() or self.height
    local hidden = minimized and V.Collapsed or V.Visible
    self.rule:SetVisibility(minimized and V.Collapsed or V.HitTestInvisible)
    self.grip:SetVisibility(hidden)
    self.glow:SetVisibility(minimized and V.Collapsed or V.HitTestInvisible)
    self.glow_soft:SetVisibility(minimized and V.Collapsed or V.HitTestInvisible)
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
    local note = kit.label("", { color = theme.dim, size = theme.small_size })
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
        label:SetText(kit.text(message or ""))
        style.tint(label, "text", color)
        spinner_box:SetVisibility(busy and V.HitTestInvisible or V.Collapsed)
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
    function status:Right(message) note:SetText(kit.text(message or "")) end
    function status:Clear()
        show("", nil, false)
        show_progress(nil)
    end
    style.follow(function() spinner_box:SetContentColorAndOpacity(style.theme.accent) end)
    show_progress(nil)
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
    if M.on_hidden then M.on_hidden(self) end
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
    local caption = kit.label(name, { color = theme.dim })
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
    local unwatch = scroller and watch_scroll(self, scroller, page) or function() end
    local unclick = events.connect(button, "OnClicked", self.parking, function() select_page(self, page) end)
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
    window.glow_soft = kit.image(theme.clear, "glow12_soft", 1, 1)
    window.glow = kit.image(theme.clear, "glow12", 1, 1)
    for _, layer in ipairs({ window.glow_soft, window.glow }) do
        layer:SetVisibility(V.HitTestInvisible)
        kit.slot(frame:AddChild(layer), { h = H.Fill, v = VA.Fill })
    end

    -- resize grip: a see-through button. light_corner colours the icon inside it.
    local grip = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear, padding = style.margin(0) })
    window.grip_icon = kit.icon("wax-grip", 16, style.with_alpha(theme.dim, 0.55))
    kit.slot(grip:SetContent(window.grip_icon), { h = H.Fill, v = VA.Fill, pad = style.margin(0) })
    window.grip = kit.sized(grip, 16, 16)
    kit.slot(frame:AddChild(window.grip), { h = H.Right, v = VA.Bottom, pad = style.margin(0, 0, 5, 5) })

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
        window.width = math.max(window.min_width, remembered.width or window.width)
        window.height = math.max(window.min_height, remembered.height or window.height)
        if window.side_sizer and remembered.side then set_side_width(window, remembered.side) end
    end
    clamp_to_viewport(window)
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
        window.drag = { kind = "move", widget = bar, mouse_x = mouse_x, mouse_y = mouse_y, x = window.x, y = window.y }
        tint_outline(window, true)
    end)
    listen(window.backdrop, "OnPressed", function() end)
    listen(grip, "OnHovered", function()
        window.grip_hover = true
        light_corner(window)
    end)
    listen(grip, "OnUnhovered", function()
        window.grip_hover = false
        light_corner(window)
    end)
    listen(grip, "OnPressed", function()
        if window.minimized then return end
        local mouse_x, mouse_y = root.mouse()
        bring_to_front(window)
        window.drag = { kind = "size", widget = grip, mouse_x = mouse_x, mouse_y = mouse_y, width = window.width, height = window.height }
        light_corner(window)
    end)
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
    grip:SetCursor(style.Cursor.ResizeSouthEast)
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

-- options: { title, icon, width, height, x, y, closable = true, visible = true, nav = nil | "side" | "top", nav_width, remember = true }
function M.create(options)
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
        shown = false, minimized = false, horizontal = false, count = 0,
        inset = theme.padding * 2 + 2,
        Opened = sched.Signal.new("Opened"), Closed = sched.Signal.new("Closed"), PageChanged = sched.Signal.new("PageChanged"),
    }, Window)
    window.window = window
    style.build(window, build, window, options)
    windows[#windows + 1] = window
    window.owner, window.owner_slot = scope.own(function() window:Destroy() end)
    if options.visible ~= false then window:Show() end
    return window
end

-- Called every frame while the menu is open: follows the mouse for the window being moved or resized.
local step_count = 0
function M.step()
    step_count = step_count + 1
    for i = 1, #windows do
        local window = windows[i]
        if step_count % 20 == 0 and window.shown and not window.minimized then
            -- the page being shown, when its end is in view
            local target = window.nav and window.page or window
            local scroller = target and target.scroller
            if scroller and target.NearEnd and scroller:GetScrollOffsetOfEnd() - scroller:GetScrollOffset() < NEAR_END then
                target.NearEnd:Fire()
            end
        end
        local drag = window.drag
        if drag then
            if not drag.widget:IsPressed() then
                window.drag = nil
                if drag.kind == "split" then light_splitter(window, window.split_hover) end
                if drag.kind == "move" then tint_outline(window, false) end
                if drag.kind == "size" then light_corner(window) end
                if window.memory_key and M.remember then
                    M.remember(window.memory_key, { x = window.x, y = window.y, width = window.width, height = window.height,
                        side = window.side_width })
                end
            else
                local mouse_x, mouse_y = root.mouse()
                if drag.kind == "move" then
                    window.x, window.y = drag.x + mouse_x - drag.mouse_x, drag.y + mouse_y - drag.mouse_y
                    clamp_to_viewport(window)
                elseif drag.kind == "split" then
                    set_side_width(window, drag.side + (mouse_x - drag.mouse_x) / style.scale)
                else
                    window.width = math.max(window.min_width, drag.width + (mouse_x - drag.mouse_x) / style.scale)
                    window.height = math.max(window.min_height, drag.height + (mouse_y - drag.mouse_y) / style.scale)
                    if window.side_sizer then set_side_width(window, window.side_width) end
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
        clamp_to_viewport(windows[i])
        apply_geometry(windows[i])
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
