-- The colour control: a selector that opens a panel with a shade box, a hue bar and the colour as text

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")
local input = Wax.import("gui.input")
local sched = Wax.import("core.sched")

local picker = {}

local V, H, VA = style.Visibility, style.HAlign, style.VAlign
local BOX, ROWS, RING, THUMB = 120, 48, 14, 16
local ROW = BOX / ROWS
local CROSSHAIRS = 8
local SEEN, UNSEEN = { R = 1, G = 1, B = 1, A = 1 }, { R = 1, G = 1, B = 1, A = 0 }
local open = nil            -- the parts of the control whose panel is showing

-- init.lua sets this to the clipboard.
picker.copy = function() end

local function hsv_to_rgb(h, s, v)
    local i = math.floor(h * 6)
    local f = h * 6 - i
    local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    i = i % 6
    if i == 0 then return v, t, p end
    if i == 1 then return q, v, p end
    if i == 2 then return p, v, t end
    if i == 3 then return p, q, v end
    if i == 4 then return t, p, v end
    return v, p, q
end

local function rgb_to_hsv(r, g, b)
    local high, low = math.max(r, g, b), math.min(r, g, b)
    local spread = high - low
    local h = 0
    if spread > 0 then
        if high == r then h = ((g - b) / spread) % 6 elseif high == g then h = (b - r) / spread + 2 else h = (r - g) / spread + 4 end
        h = h / 6
    end
    return h, high > 0 and spread / high or 0, high
end

local function to_hex(r, g, b)
    return ("#%02x%02x%02x"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local function from_hex(text)
    local r, g, b = tostring(text):match("^%s*#?(%x%x)(%x%x)(%x%x)%s*$")
    if not r then return nil end
    return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
end

-- A screen colour (0 to 1 for each of red, green, blue) as the linear colour the engine draws with.
local function engine_color(r, g, b)
    local function linear(c) return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
    return { R = linear(r), G = linear(g), B = linear(b), A = 1 }
end

-- The marker in the shade box is the handle of the row it is on, so the engine places it.
local function mark(parts)
    local row = math.floor((1 - parts.v) * (ROWS - 1) + 0.5) + 1
    local strip = parts.strips[row]
    if parts.marked ~= strip then
        for _, state in ipairs({ "NormalThumbImage", "HoveredThumbImage" }) do
            if parts.marked then parts.marked.WidgetStyle[state].TintColor = style.slate(UNSEEN) end
            strip.WidgetStyle[state].TintColor = style.slate(SEEN)
        end
        parts.marked = strip
    end
    if strip:GetValue() ~= parts.s then strip:SetValue(parts.s) end
end

-- Shows the control's colour on everything that displays it.
local function show(parts)
    parts.swatch:SetBrushColor(engine_color(hsv_to_rgb(parts.h, parts.s, parts.v)))
    parts.hex:SetText(kit.text(parts.value))
    if not parts.holder then return end
    parts.shade:SetColorAndOpacity(engine_color(hsv_to_rgb(parts.h, 1, 1)))
    if parts.hue:GetValue() ~= parts.h then parts.hue:SetValue(parts.h) end
    mark(parts)
end

local function take(parts, r, g, b)
    local h, s, v = rgb_to_hsv(r, g, b)
    -- grey and black have no hue of their own, so the hue bar stays where it was
    if s > 0 and v > 0 then parts.h = h end
    if v > 0 then parts.s = s end
    parts.v = v
    parts.value = to_hex(r, g, b)
end

local function report(parts)
    local value = to_hex(hsv_to_rgb(parts.h, parts.s, parts.v))
    if value == parts.value then return show(parts) end
    parts.value = value
    show(parts)
    if parts.field then parts.field:SetText(kit.text(value)) end
    if parts.on_change then sched.task.spawn(parts.on_change, value) end
    parts.control.Changed:Fire(value)
end

local function picture(name)
    local image = kit.image(style.WHITE, nil, 1, 1)
    image:SetBrushResourceObject(root.texture("picker/" .. name))
    image:SetVisibility(V.HitTestInvisible)
    return image
end

-- Drawn over a square image in the colour of what is behind it, this rounds the image's corners.
local function rounding(radius, color)
    local image = root.new("Image")
    local brush = image.Brush
    brush.ResourceObject = root.texture("picker/corners" .. radius)
    brush.DrawAs = style.DrawAs.Box
    brush.Margin = style.margin(radius / 64)
    brush.ImageSize = { X = 64, Y = 64 }
    style.tint(image, "image", color)
    image:SetVisibility(V.HitTestInvisible)
    return image
end

-- One row of the shade box: a slider nobody sees, which tells how far along it was pressed.
local function sensor_row()
    local slider = root.new("Slider")
    local look = slider.WidgetStyle
    for _, brush in ipairs({ "NormalBarImage", "HoveredBarImage", "DisabledBarImage", "DisabledThumbImage" }) do
        style.paint_nothing(look[brush])
    end
    for _, state in ipairs({ "NormalThumbImage", "HoveredThumbImage" }) do
        local brush = look[state]
        brush.ResourceObject = root.texture("picker/ring")
        brush.DrawAs = style.DrawAs.Image
        brush.Margin = style.margin(0)
        brush.ImageSize = { X = RING, Y = RING }
        brush.TintColor = style.slate(UNSEEN)
    end
    look.BarThickness = 0
    slider.IsFocusable = false
    slider.IndentHandle = false
    slider:SetCursor(CROSSHAIRS)
    return slider
end

local function build(parts, tools)
    local theme, control, listen = style.theme, parts.control, tools.listen
    local stack = root.new("VerticalBox")

    -- the shade box: every shade of one hue, white to the left and black at the bottom
    local area = root.new("Overlay")
    parts.shade = kit.image(style.WHITE, nil, 1, 1)
    parts.shade:SetVisibility(V.HitTestInvisible)
    kit.slot(area:AddChild(parts.shade), { h = H.Fill, v = VA.Fill })
    kit.slot(area:AddChild(picture("fade_white")), { h = H.Fill, v = VA.Fill })
    kit.slot(area:AddChild(picture("fade_black")), { h = H.Fill, v = VA.Fill })
    kit.slot(area:AddChild(rounding(6, theme.raised)), { h = H.Fill, v = VA.Fill })
    local sensors = root.new("VerticalBox")
    parts.strips = {}
    for index = 1, ROWS do
        local strip = sensor_row()
        parts.strips[index] = strip
        kit.slot(sensors:AddChild(kit.sized(strip, nil, ROW)), { h = H.Fill })
    end
    -- the rows reach half a marker past each side, so the marker's middle can sit on the very edge
    kit.slot(area:AddChild(sensors), { h = H.Fill, v = VA.Fill, pad = style.margin(-RING / 2, 0, -RING / 2, 0) })
    parts.area = area
    kit.slot(stack:AddChild(kit.sized(area, nil, BOX)), { h = H.Fill })

    -- the hue bar
    local bar = root.new("Overlay")
    kit.slot(bar:AddChild(kit.sized(picture("hues"), nil, 10)), { h = H.Fill, v = VA.Center })
    kit.slot(bar:AddChild(kit.sized(rounding(5, theme.raised), nil, 10)), { h = H.Fill, v = VA.Center })
    local hue = root.new("Slider")
    local look = hue.WidgetStyle
    for _, brush in ipairs({ "NormalBarImage", "HoveredBarImage", "DisabledBarImage" }) do style.paint_nothing(look[brush]) end
    style.paint(look.NormalThumbImage, style.WHITE, style.capsule(THUMB), THUMB, THUMB)
    style.paint(look.HoveredThumbImage, style.WHITE, style.capsule(THUMB), THUMB, THUMB)
    style.paint(look.DisabledThumbImage, theme.dim, style.capsule(THUMB), THUMB, THUMB)
    look.BarThickness = 0
    hue.IsFocusable = false
    hue.IndentHandle = false
    hue:SetCursor(style.Cursor.Hand)
    hue:SetValue(parts.h)
    parts.hue = hue
    kit.slot(bar:AddChild(hue), { h = H.Fill, v = VA.Fill, pad = style.margin(-THUMB / 2, 0, -THUMB / 2, 0) })
    kit.slot(stack:AddChild(kit.sized(bar, nil, THUMB + 2)), { h = H.Fill, pad = style.margin(0, 10, 0, 0) })

    -- the colour as text: type or paste one, or copy it
    local field = root.new("EditableTextBox")
    local box = field.WidgetStyle
    style.paint(box.BackgroundImageNormal, theme.panel, theme.control_shape)
    style.paint(box.BackgroundImageHovered, theme.panel, theme.control_shape)
    style.paint(box.BackgroundImageFocused, theme.panel, theme.control_shape)
    box.Font = style.font(theme.small_size, nil, "mono")
    style.tint(box, "ink", theme.text)
    box.Padding = style.margin(8, 4)
    field:SetText(kit.text(parts.value))
    parts.field = field
    local text_row = root.new("HorizontalBox")
    kit.slot(text_row:AddChild(kit.sized(field, nil, 24)), { v = VA.Center, fill = 1 })
    local copy_icon = kit.icon("copy", 12, theme.dim)
    local copy_box, copy = kit.icon_button(nil, { content = copy_icon, width = 26, height = 24 })
    parts.copy = copy
    kit.slot(text_row:AddChild(copy_box), { v = VA.Center, pad = style.margin(4, 0, 0, 0) })
    kit.slot(stack:AddChild(text_row), { h = H.Fill, pad = style.margin(0, 10, 0, 0) })

    -- the panel and the selector above its right end are one shape: same colour, and square where they meet.
    -- The shape is as tall as the panel is at that moment, so it keeps its round lower corners while it opens and shuts.
    local card = root.new("Overlay")
    kit.slot(card:AddChild(kit.box(theme.raised, "round8")), { h = H.Fill, v = VA.Fill })
    local corner = kit.image(theme.raised, nil, 8, 8)
    corner:SetVisibility(V.HitTestInvisible)
    kit.slot(card:AddChild(kit.sized(corner, 8, 8)), { h = H.Right, v = VA.Top })
    kit.slot(card:AddChild(stack), { h = H.Fill, v = VA.Top, pad = style.margin(12) })
    parts.content = card
    parts.holder = tools.holder_for(card, false)
    kit.slot(parts.column:AddChild(parts.holder), { h = H.Fill })

    listen(control, hue, "OnValueChanged", function(value)
        parts.h = math.max(0, math.min(1, value))
        if parts.v < 0.02 then parts.v = 1 end
        report(parts)
    end)
    listen(control, hue, "OnMouseCaptureEnd", function() control.Released:Fire(parts.value) end)
    listen(control, field, "OnTextCommitted", function(text)
        local r, g, b = from_hex(text)
        if not r then return field:SetText(kit.text(parts.value)) end
        take(parts, r, g, b)
        parts.value = ""
        report(parts)
        control.Released:Fire(parts.value)
    end)
    listen(control, copy, "OnClicked", function()
        picker.copy(parts.value)
        kit.set_icon(copy_icon, "check", 12)
        sched.task.delay(1.2, function()
            if not control.destroyed then kit.set_icon(copy_icon, "copy", 12) end
        end)
    end)
end

function picker.close()
    local parts = open
    open = nil
    if not parts or parts.control.destroyed then return false end
    parts.dragging = nil
    parts.expand(false)
    return true
end

-- Called before every widget event: one that is not the open panel's own closes it.
function picker.seen(delegate, address)
    local parts = open
    if not parts or delegate == "OnHovered" or delegate == "OnUnhovered" or delegate == "OnUserScrolled" then return end
    local own = parts.control.addresses
    if not (own and own[address]) then picker.close() end
end

-- Once per frame while the menu shows: the shade follows the mouse while the box is held, and a click elsewhere closes the panel.
function picker.step()
    local parts = open
    if not parts then return end
    if parts.control.destroyed then
        open = nil
        return
    end
    local drag = parts.dragging
    if drag then
        if not drag.strip:HasMouseCapture() then
            parts.dragging = nil
            parts.control.Released:Fire(parts.value)
            return
        end
        local _, mouse_y = root.mouse()
        local down = drag.y + (mouse_y - drag.mouse_y) / style.scale
        parts.s = math.max(0, math.min(1, drag.strip:GetValue()))
        parts.v = 1 - math.max(0, math.min(1, down / BOX))
        return report(parts)
    end
    if parts.area and parts.area:IsHovered() then
        for index, strip in ipairs(parts.strips) do
            if strip:HasMouseCapture() then
                local _, mouse_y = root.mouse()
                parts.dragging = { strip = strip, y = (index - 1) / (ROWS - 1) * BOX, mouse_y = mouse_y }
                parts.s = math.max(0, math.min(1, strip:GetValue()))
                parts.v = 1 - (index - 1) / (ROWS - 1)
                return report(parts)
            end
        end
    end
    local ok, pressed = pcall(input.just_pressed, "LeftMouseButton")
    if ok and pressed and not parts.column:IsHovered() then picker.close() end
end

-- Adds Container:Color. `tools` are the helpers every control in controls.lua is built with.
function picker.install(Container, tools)
    local place, new_control, listen = tools.place, tools.new_control, tools.listen

    -- A colour the user can change: Color("Outline", "#ff8800", function(color) ... end). The value is "#rrggbb".
    function Container:Color(caption, color, on_change)
        local theme = style.theme
        local r, g, b = from_hex(color or "#ffffff")
        if not r then error("a colour is written \"#rrggbb\", got " .. tostring(color), 3) end
        -- the caption and the selector share a line. The panel opens under both, as wide as the row.
        local column = root.new("VerticalBox")
        local row = tools.caption_row(self, caption, 0.5)
        local head = root.new("Overlay")
        local back, back_open = kit.box(theme.raised, "round6"), kit.box(theme.raised, "top6")
        back_open:SetVisibility(V.HitTestInvisible)
        back_open:SetRenderOpacity(0)
        kit.slot(head:AddChild(back), { h = H.Fill, v = VA.Fill })
        kit.slot(head:AddChild(back_open), { h = H.Fill, v = VA.Fill })
        local header = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear,
            padding = style.margin(8, 6, 10, 6) })
        local header_row = root.new("HorizontalBox")
        local swatch = kit.box(style.WHITE, "round4")
        local edge = kit.box(theme.line, "round5", style.margin(1))
        edge:SetContent(swatch)
        kit.slot(header_row:AddChild(kit.sized(edge, 18, 18)), { v = VA.Center, pad = style.margin(0, 0, 8, 0) })
        local hex = kit.label("", { family = "mono", size = theme.small_size })
        kit.slot(header_row:AddChild(hex), { v = VA.Center, fill = 1 })
        local chevron = kit.icon("chevron-down", 14, theme.dim)
        kit.slot(header_row:AddChild(chevron), { v = VA.Center, pad = style.margin(0, 1, 0, 0) })
        kit.fill_content(header, header_row)
        kit.slot(head:AddChild(header), { h = H.Fill, v = VA.Fill })
        kit.slot(row:AddChild(kit.sized(head, 128)), { v = VA.Center })
        kit.slot(column:AddChild(row), { h = H.Fill })
        place(self, column)

        local control = new_control(self, column)
        control.source = header
        control.Released = sched.Signal.new("Released")
        local parts = { control = control, owner = control, swatch = swatch, hex = hex, column = column, chevron = chevron,
            closed_angle = 0, open_angle = 180, open = false, fade = true, on_change = on_change, h = 0, s = 0, v = 1 }
        take(parts, r, g, b)
        show(parts)
        control.parts = parts
        -- the selector's lower corners turn square as the panel grows out of it, and round again as it goes back in
        parts.sized = function(share) back_open:SetRenderOpacity(math.min(1, share * 4)) end
        local container = self
        parts.opened = function(height)
            local scroller, host = tools.scroller_of(container), container.window
            if scroller and host.height and height < host.height - 150 then scroller:ScrollWidgetIntoView(parts.holder, true, 0, 10) end
        end
        parts.expand = function(on)
            if on and not parts.holder then style.extend(control, build, parts, tools) end
            if on then show(parts) end
            if parts.holder then tools.set_expanded(parts, on) end
        end

        function control:Get() return parts.value end
        function control:Set(new_color)
            local nr, ng, nb = from_hex(new_color)
            if not nr then error("a colour is written \"#rrggbb\", got " .. tostring(new_color), 2) end
            take(parts, nr, ng, nb)
            show(parts)
            if parts.field then parts.field:SetText(kit.text(parts.value)) end
        end
        listen(control, header, "OnHovered", function()
            if not (parts.open or parts.closing) then style.tint(back, "box", theme.hover) end
        end)
        listen(control, header, "OnUnhovered", function() style.tint(back, "box", theme.raised) end)
        listen(control, header, "OnClicked", function()
            if open == parts then return picker.close() end
            picker.close()
            open = parts
            parts.expand(true)
        end)
        return control
    end
end

return picker
