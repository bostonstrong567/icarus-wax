-- Small builders the controls and windows are made from

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")

local kit = {}

local H, VA = style.HAlign, style.VAlign
local WHITE = style.WHITE

function kit.text(value) return FText(tostring(value)) end

function kit.label(content, options)
    options = options or {}
    local theme = style.theme
    local widget = root.new("TextBlock")
    widget:SetFont(style.font(options.size or theme.font_size, options.face, options.family))
    style.tint(widget, "text", style.to_color(options.color) or theme.text)
    widget:SetText(kit.text(content))
    -- text never draws outside its own box. Right-aligned text is clipped by its row instead.
    if options.justify ~= style.Justify.Right then widget:SetClipping(style.Clip.ClipToBounds) end
    if options.wrap then
        widget.WrappingPolicy = style.Wrapping.AnyCharacter
        widget:SetAutoWrapText(true)
    end
    if options.justify then widget:SetJustification(options.justify) end
    return widget
end

-- options: pad (margin), h, v (alignment), fill (a weight for sharing the leftover space)
function kit.slot(layout_slot, options)
    if not options then return layout_slot end
    if options.pad then layout_slot:SetPadding(options.pad) end
    if options.h then layout_slot:SetHorizontalAlignment(options.h) end
    if options.v then layout_slot:SetVerticalAlignment(options.v) end
    if options.fill then layout_slot:SetSize({ SizeRule = style.SizeRule.Fill, Value = options.fill }) end
    return layout_slot
end

-- A flat or 9-slice image. Its brush is white. Change the colour later with SetColorAndOpacity.
function kit.image(color, shape, width, height)
    local image = root.new("Image")
    style.paint(image.Brush, WHITE, shape, width, height)
    style.tint(image, "image", color)
    return image
end

function kit.icon(name, size, color)
    local image = root.new("Image")
    style.paint_icon(image.Brush, name, WHITE, size)
    style.tint(image, "image", style.to_color(color) or style.theme.dim)
    return image
end

-- Shows another icon in an image made by kit.icon, without making a new widget.
function kit.set_icon(image, name, size)
    local texture, region = style.icon_source(name, size)
    image:SetBrushResourceObject(texture)
    image.Brush.UVRegion = region
end

-- A coloured box that holds one child. Change the colour later with SetBrushColor.
function kit.box(color, shape, padding)
    local border = root.new("Border")
    style.paint(border.Background, WHITE, shape)
    style.tint(border, "box", color)
    border:SetPadding(padding or style.margin(0))
    return border
end

function kit.sized(widget, width, height)
    local box = root.new("SizeBox")
    if width then box:SetWidthOverride(width) end
    if height then box:SetHeightOverride(height) end
    if widget then box:SetContent(widget) end
    return box
end

-- options: flat (no rounding), shape, color, hover, press, padding, size, text, align, cursor (the hand by default)
function kit.button(caption, options)
    options = options or {}
    local theme = style.theme
    local button = root.new("Button")
    local look = button.WidgetStyle
    local shape = options.shape or (not options.flat and theme.control_shape or nil)
    style.paint(look.Normal, options.color or theme.raised, shape)
    style.paint(look.Hovered, options.hover or theme.hover, shape)
    style.paint(look.Pressed, options.press or theme.press, shape)
    -- a see-through button stays see-through when it is switched off
    style.paint(look.Disabled, options.color == theme.clear and theme.clear or theme.panel, shape)
    look.NormalPadding = options.padding or style.margin(12, 5)
    look.PressedPadding = options.padding or style.margin(12, 5)
    button.IsFocusable = false
    button:SetCursor(options.cursor or style.Cursor.Hand)
    button:SetClipping(style.Clip.ClipToBounds)
    if caption then
        local content = button:SetContent(kit.label(caption, { size = options.size, color = options.text }))
        content:SetHorizontalAlignment(options.align or H.Center)
        content:SetVerticalAlignment(VA.Center)
    end
    return button
end

-- Wraps content so it is drawn at the interface scale and stays sharp at any size. h, v: where it sits in its slot.
function kit.scaled(content, h, v)
    local box = root.new("ScaleBox")
    box:SetStretch(style.Stretch.UserSpecified)
    box:SetUserSpecifiedScale(style.scale)
    kit.slot(box:SetContent(content), { h = h or H.Left, v = v or VA.Top })
    return box
end

-- A square button showing one icon (or options.content). Returns the sized wrapper and the button.
function kit.icon_button(icon, options)
    options = options or {}
    local theme = style.theme
    local button = kit.button(nil, { color = theme.clear, hover = options.hover or theme.hover, press = options.press or theme.press,
        shape = "round6", padding = style.margin(0) })
    local content = button:SetContent(options.content or kit.icon(icon, options.icon_size or 12, options.color or theme.dim))
    content:SetHorizontalAlignment(H.Center)
    content:SetVerticalAlignment(VA.Center)
    return kit.sized(button, options.width or 26, options.height or 24), button
end

function kit.fill_content(button, row)
    local content = button:SetContent(row)
    content:SetHorizontalAlignment(H.Fill)
    content:SetVerticalAlignment(VA.Center)
    return content
end

-- What a scroll box's content keeps free on the right: the bar is drawn there, so it never takes width.
kit.GUTTER = 12

-- Replaces the engine's default scroll-box look: thin rounded bar, no track, no edge shadows, animated wheel scrolling.
function kit.scroll_box()
    local theme = style.theme
    local box = root.new("ScrollBox")
    local bar = box.WidgetBarStyle
    style.paint(bar.NormalThumbImage, theme.hover, style.capsule(6), 6, 6)
    style.paint(bar.HoveredThumbImage, theme.press, style.capsule(6), 6, 6)
    style.paint(bar.DraggedThumbImage, theme.dim, style.capsule(6), 6, 6)
    style.paint(bar.VerticalBackgroundImage, theme.clear)
    style.paint(bar.HorizontalBackgroundImage, theme.clear)
    -- the track above and below the thumb: nothing, and no size of its own (the bar is as wide as these are)
    for _, part in ipairs({ "VerticalTopSlotImage", "VerticalBottomSlotImage", "HorizontalTopSlotImage", "HorizontalBottomSlotImage" }) do
        style.paint_nothing(bar[part])
    end
    box:SetScrollbarPadding(style.margin(-8, 0, 2, 0))
    box:SetAnimateWheelScrolling(true)
    box:SetWheelScrollMultiplier(1.6)
    local look = box.WidgetStyle
    for _, edge in ipairs({ "TopShadowBrush", "BottomShadowBrush", "LeftShadowBrush", "RightShadowBrush" }) do
        style.paint(look[edge], theme.clear)
    end
    box:SetScrollbarThickness({ X = 6, Y = 6 })
    return box
end

return kit
