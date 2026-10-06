-- Overlays: panels drawn over the game that never take the mouse

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")
local controls = Wax.import("gui.controls")
local scope = Wax.import("core.scope")
local events = Wax.import("gui.events")

local M = {}

local V, H, VA = style.Visibility, style.HAlign, style.VAlign
local overlays = {}
local moving = false
M.overlays = overlays

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
    self.holder:SetVisibility(self.shown and V.SelfHitTestInvisible or V.Collapsed)
end

function Overlay:IsVisible() return self.shown end

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
        kit.slot(frame:AddChild(kit.box(style.with_alpha(theme.window, 0.82), "round8")), { h = H.Fill, v = VA.Fill })
        local outline = kit.image(style.with_alpha(theme.outline, 0.7), "frame8", 1, 1)
        kit.slot(frame:AddChild(outline), { h = H.Fill, v = VA.Fill })
    end
    overlay.box = root.new("VerticalBox")
    local padded = kit.box(theme.clear, nil, style.margin(12, 10, 12, 10 - theme.spacing + 4))
    padded:SetContent(overlay.box)
    kit.slot(frame:AddChild(kit.sized(padded, overlay.width)), { h = H.Fill, v = VA.Fill })
    overlay.parking = root.new("VerticalBox")
    overlay.parking:SetVisibility(V.Collapsed)
    frame:AddChild(overlay.parking)
    frame:SetVisibility(V.HitTestInvisible)

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
    local overlay = setmetatable({ controls = {}, width = options.width or 240, nav_width = 0, anchor = anchor,
        x = options.x or 16, y = options.y or 16, shown = true, horizontal = false, count = 0, inset = 24 }, Overlay)
    overlay.window = overlay
    style.build(overlay, build, overlay, options)
    overlays[#overlays + 1] = overlay
    overlay.owner, overlay.owner_slot = scope.own(function() overlay:Destroy() end)
    return overlay
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
    for i = 1, #overlays do overlays[i].outer:SetUserSpecifiedScale(style.scale) end
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
