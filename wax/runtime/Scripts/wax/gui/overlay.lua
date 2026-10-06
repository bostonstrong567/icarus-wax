-- Overlays: panels drawn over the game that never take the mouse

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")
local controls = Wax.import("gui.controls")
local scope = Wax.import("core.scope")
local events = Wax.import("gui.events")
local sched = Wax.import("core.sched")
local guard = Wax.import("core.guard")

local M = {}

M.WHEEL_ROOM = 320      -- how far the wheel catcher of a panel can turn either way before it is put back

local V, H, VA = style.Visibility, style.HAlign, style.VAlign
local overlays = {}
local moving = false
local state = { menu = false, cursor = false }      -- what watch() last saw
M.overlays = overlays

-- "always", "menu" (while the Wax menu is open) or "cursor" (also while one of the game's own screens shows the mouse)
local function allowed(when)
    if when == "menu" then return state.menu end
    if when == "cursor" then return state.menu or state.cursor end
    return true
end

local function apply(overlay)
    local visible = overlay.shown and allowed(overlay.when)
    if visible ~= overlay.visible_now then
        overlay.visible_now = visible
        overlay.holder:SetVisibility(visible and V.SelfHitTestInvisible or V.Collapsed)
    end
end

-- anchor name -> { x, y } as fractions of the screen
local ANCHORS = {
    ["top-left"] = { 0, 0 }, ["top"] = { 0.5, 0 }, ["top-right"] = { 1, 0 },
    ["left"] = { 0, 0.5 }, ["center"] = { 0.5, 0.5 }, ["right"] = { 1, 0.5 },
    ["bottom-left"] = { 0, 1 }, ["bottom"] = { 0.5, 1 }, ["bottom-right"] = { 1, 1 },
}

-- Pins the overlay to its anchor. x, y push it inwards from that edge. The result is kept as the slot's own offset.
local function pin(overlay)
    local at, slot = ANCHORS[overlay.anchor], overlay.slot
    slot:SetAnchors({ Minimum = { X = at[1], Y = at[2] }, Maximum = { X = at[1], Y = at[2] } })
    slot:SetAlignment({ X = at[1], Y = at[2] })
    slot:SetAutoSize(true)
    overlay.offset_x = at[1] == 1 and -overlay.x or (at[1] == 0 and overlay.x or 0)
    overlay.offset_y = at[2] == 1 and -overlay.y or (at[2] == 0 and overlay.y or 0)
    slot:SetPosition({ X = overlay.offset_x, Y = overlay.offset_y })
end

local Overlay = setmetatable({}, { __index = controls.Container })
Overlay.__index = Overlay

function Overlay:SetVisible(shown)
    self.shown = shown and true or false
    apply(self)
end

function Overlay:IsVisible() return self.shown end
-- True while it is really on screen: switched on, and what it waits for (the menu, the mouse) is there.
function Overlay:IsShowing() return self.visible_now == true end

-- Moves it without changing its anchor: x and y push it inwards from that edge.
function Overlay:SetOffset(x, y)
    self.x, self.y = x or self.x, y or self.y
    pin(self)
end

function Overlay:SetAnchor(anchor, x, y)
    if not ANCHORS[anchor] then error("unknown anchor '" .. tostring(anchor) .. "'", 2) end
    self.anchor, self.x, self.y = anchor, x or self.x, y or self.y
    pin(self)
end

function Overlay:Destroy()
    if self.destroyed then return end
    self.destroyed = true
    for _, control in ipairs(self.controls) do
        for _, disconnect in ipairs(control.disconnects) do disconnect() end
        controls.retire(control)
    end
    pcall(function() self.outer:RemoveFromParent() end)
    for index, other in ipairs(overlays) do
        if other == self then
            table.remove(overlays, index)
            break
        end
    end
    if self.owner and self.owner_slot then self.owner:remove(self.owner_slot) end
end

local function build(overlay, options)
    local theme, anchor = style.theme, overlay.anchor
    local frame = root.new("Overlay")
    overlay.frame = frame
    if options.background ~= false then
        kit.slot(frame:AddChild(kit.box(style.with_alpha(theme.window, options.opacity or 0.82), "round8")), { h = H.Fill, v = VA.Fill })
        local outline = kit.image(style.with_alpha(theme.outline, 0.7), "frame8", 1, 1)
        kit.slot(frame:AddChild(outline), { h = H.Fill, v = VA.Fill })
    end
    -- a panel that is pressed where it has no control: a see-through button under its controls
    local catcher = nil
    if options.interactive and type(options.on_press) == "function" then
        catcher = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear, padding = style.margin(0),
            cursor = style.Cursor.Default })
        kit.slot(frame:AddChild(catcher), { h = H.Fill, v = VA.Fill })
    end
    overlay.box = root.new("VerticalBox")
    local pad = options.padding
    local padded = kit.box(theme.clear, nil, pad and style.margin(pad, pad, pad, math.max(0, pad - theme.spacing))
        or style.margin(12, 10, 12, 10 - theme.spacing + 4))
    padded:SetContent(overlay.box)
    local sized = kit.sized(padded, overlay.width, options.height)
    if options.interactive then
        -- A panel takes the mouse wheel, so the game under it does not act on it (it would turn the hotbar). The panel
        -- sits in a scroll box that scrolls sideways between two empty ends: the wheel moves it, watch() sees which way
        -- and puts it back before it is drawn.
        local catcher = root.new("ScrollBox")
        catcher.bAllowRightClickDragScrolling = false
        catcher:SetOrientation(0)
        catcher:SetConsumeMouseWheel(1)
        catcher:SetAnimateWheelScrolling(false)
        catcher:SetAllowOverscroll(false)
        catcher:SetScrollbarVisibility(V.Collapsed)
        for _, edge in ipairs({ "TopShadowBrush", "BottomShadowBrush", "LeftShadowBrush", "RightShadowBrush" }) do
            style.paint(catcher.WidgetStyle[edge], theme.clear)
        end
        local strip = root.new("HorizontalBox")
        strip:AddChild(kit.sized(nil, M.WHEEL_ROOM, 1))
        strip:AddChild(sized)
        strip:AddChild(kit.sized(nil, M.WHEEL_ROOM, 1))
        catcher:AddChild(strip)
        catcher:SetScrollOffset(M.WHEEL_ROOM)
        overlay.catcher = catcher
        sized = kit.sized(catcher, overlay.width, options.height)
    end
    kit.slot(frame:AddChild(sized), { h = H.Fill, v = VA.Fill })
    overlay.parking = root.new("VerticalBox")
    overlay.parking:SetVisibility(V.Collapsed)
    frame:AddChild(overlay.parking)
    if catcher then
        local chrome = { window = overlay, widget = catcher, disconnects = {}, destroyed = false }
        overlay.controls[#overlay.controls + 1] = chrome
        chrome.disconnects[1] = events.connect(catcher, "OnClicked", overlay.parking, function() sched.task.spawn(options.on_press) end)
    end
    -- a panel's own controls take the mouse. An overlay is only looked at
    frame:SetVisibility(options.interactive and V.SelfHitTestInvisible or V.HitTestInvisible)

    local holder = root.new("Overlay")
    holder:SetVisibility(V.SelfHitTestInvisible)
    kit.slot(holder:AddChild(frame), { h = H.Fill, v = VA.Fill })
    overlay.holder = holder
    if options.movable ~= false then
        -- a see-through button over the whole panel, there only while the menu is open
        local mover = kit.button(nil, { shape = "frame8", color = style.with_alpha(theme.accent, 0.55), hover = theme.accent,
            press = theme.accent_hover, padding = style.margin(0), cursor = style.Cursor.Move })
        mover:SetVisibility(moving and V.Visible or V.Collapsed)
        kit.slot(holder:AddChild(mover), { h = H.Fill, v = VA.Fill })
        overlay.mover = mover
        local chrome = { window = overlay, widget = mover, disconnects = {}, destroyed = false }
        overlay.controls[#overlay.controls + 1] = chrome
        chrome.disconnects[1] = events.connect(mover, "OnPressed", overlay.parking, function()
            local mouse_x, mouse_y = root.mouse()
            overlay.drag = { mouse_x = mouse_x, mouse_y = mouse_y, x = overlay.offset_x, y = overlay.offset_y }
        end)
    end

    overlay.outer = kit.scaled(holder)
    if overlay.zoom ~= 1 then overlay.outer:SetUserSpecifiedScale(style.scale * overlay.zoom) end
    overlay.slot = root.layer("hud"):AddChild(overlay.outer)
    pin(overlay)
    local owner = scope.current()
    overlay.memory_key = (owner and owner.name or "wax") .. "/" .. tostring(options.title or anchor)
    local remembered = overlay.mover and M.recall and M.recall(overlay.memory_key)
    if remembered and remembered.anchor == anchor then
        overlay.offset_x, overlay.offset_y = remembered.x or overlay.offset_x, remembered.y or overlay.offset_y
        overlay.slot:SetPosition({ X = overlay.offset_x, Y = overlay.offset_y })
    end
    if options.title then overlay:Heading(options.title) end
end

-- options: { anchor = "top-right", x = 16, y = 16, width = 240, title, background = true, movable = true (drag it while the menu is open) }
function M.create(options)
    if not root.exists() then error("the GUI is not running", 2) end
    if type(options) == "table" and type(options.Overlay) == "function" then error("write ui.Overlay({ ... }) with a dot, not a colon", 2) end
    options = options or {}
    local anchor = options.anchor or "top-right"
    if not ANCHORS[anchor] then error("unknown anchor '" .. tostring(anchor) .. "'", 2) end
    local when = options.when or "always"
    if when ~= "always" and when ~= "menu" and when ~= "cursor" then
        error("when is \"always\", \"menu\" or \"cursor\"", 2)
    end
    local inset = options.padding and options.padding * 2 or 24
    local overlay = setmetatable({ controls = {}, width = options.width or 240, nav_width = 0, anchor = anchor,
        x = options.x or 16, y = options.y or 16, shown = options.visible ~= false, horizontal = false, count = 0, inset = inset,
        when = when, interactive = options.interactive and true or false, height = options.height,
        zoom = tonumber(options.zoom) or 1 }, Overlay)
    overlay.window = overlay
    -- on a panel: fires with 1 when the wheel is turned down over it and -1 when it is turned up
    overlay.Scrolled = sched.Signal.new("Scrolled")
    overlay.maker = scope.current()
    style.build(overlay, build, overlay, options)
    overlay.visible_now = true
    apply(overlay)
    overlays[#overlays + 1] = overlay
    overlay.owner, overlay.owner_slot = scope.own(function() overlay:Destroy() end)
    return overlay
end

-- A panel: an overlay whose controls take the mouse. It has no title bar and is not dragged, and it shows beside the
-- game's own screens. options as for an overlay, plus when = "cursor" (the default), "menu" or "always", padding, height,
-- zoom (everything in it that much larger), opacity (of its background, 0.96 unless given) and on_press (run when it
-- is pressed where it has no control). A panel takes the mouse wheel while the mouse is over it: panel.Scrolled fires
-- with 1 (down) or -1 (up), and the game does not see the wheel.
function M.panel(options)
    if type(options) == "table" and type(options.Panel) == "function" then error("write ui.Panel({ ... }) with a dot, not a colon", 2) end
    local given = {}
    for key, value in pairs(options or {}) do given[key] = value end
    given.interactive = true
    if given.movable == nil then given.movable = false end
    given.when = given.when or "cursor"
    given.opacity = given.opacity or 0.96
    return M.create(given)
end

-- True when some overlay waits for the game's mouse, so the caller knows to look for it.
function M.wants_cursor()
    for i = 1, #overlays do
        if overlays[i].when == "cursor" and overlays[i].shown then return true end
    end
    return false
end

-- Every frame: overlays that wait for the menu or the mouse are shown and hidden. True when a panel is on screen now.
function M.watch(menu, cursor)
    state.menu, state.cursor = menu and true or false, cursor and true or false
    local interactive = false
    for i = 1, #overlays do
        local overlay = overlays[i]
        if overlay.when ~= "always" then apply(overlay) end
        if overlay.interactive and overlay.visible_now then
            interactive = true
            local catcher = overlay.catcher
            local offset = catcher and catcher:GetScrollOffset()
            if offset == M.WHEEL_ROOM then
                overlay.wheel_ready = true
            elseif offset then
                -- the wheel turned it: back to the middle, and whoever made the panel is told which way
                catcher:SetScrollOffset(M.WHEEL_ROOM)
                if overlay.wheel_ready then
                    local steps = offset > M.WHEEL_ROOM and 1 or -1
                    local previous = scope.enter(overlay.maker)
                    guard.call("panel wheel", function() overlay.Scrolled:Fire(steps) end)
                    scope.leave(previous)
                end
            end
        end
    end
    return interactive
end

-- While the menu is open, overlays can be dragged.
function M.set_moving(on)
    moving = on and true or false
    for i = 1, #overlays do
        local overlay = overlays[i]
        if overlay.mover then overlay.mover:SetVisibility(moving and V.Visible or V.Collapsed) end
        overlay.drag = nil
    end
end

function M.step()
    if not moving then return end
    for i = 1, #overlays do
        local overlay = overlays[i]
        local drag = overlay.drag
        if drag then
            if not overlay.mover:IsPressed() then
                overlay.drag = nil
                if M.remember then M.remember(overlay.memory_key, { anchor = overlay.anchor, x = overlay.offset_x, y = overlay.offset_y }) end
            else
                local mouse_x, mouse_y = root.mouse()
                overlay.offset_x, overlay.offset_y = drag.x + mouse_x - drag.mouse_x, drag.y + mouse_y - drag.mouse_y
                overlay.slot:SetPosition({ X = overlay.offset_x, Y = overlay.offset_y })
            end
        end
    end
end

function M.rescale()
    for i = 1, #overlays do overlays[i].outer:SetUserSpecifiedScale(style.scale * overlays[i].zoom) end
end

function M.forget_all()
    for i = #overlays, 1, -1 do
        local overlay = overlays[i]
        overlay.destroyed, overlay.drag = true, nil
        for _, control in ipairs(overlay.controls) do controls.retire(control) end
        if overlay.owner and overlay.owner_slot then overlay.owner:remove(overlay.owner_slot) end
        overlays[i] = nil
    end
end

function M.destroy_all()
    for i = #overlays, 1, -1 do overlays[i]:Destroy() end
end

return M
