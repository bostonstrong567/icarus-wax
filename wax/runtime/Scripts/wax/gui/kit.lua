-- Small builders the controls and windows are made from

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")

local kit = {}

local H, VA = style.HAlign, style.VAlign
local WHITE = style.WHITE

-- Nothing at all shows as no text, never as the word "nil".
local function written(value) return value == nil and "" or tostring(value) end
function kit.text(value) return FText(written(value)) end

-- What each text block was made with, the text it was given and the room it was told it has (kit.fit).
local labels = setmetatable({}, { __mode = "k" })

function kit.label(content, options)
    options = options or {}
    local theme = style.theme
    local widget = root.new("TextBlock")
    local size = options.size or theme.font_size
    widget:SetFont(style.font(size, options.face, options.family))
    style.tint(widget, "text", style.to_color(options.color) or theme.text)
    local text = written(content)
    widget:SetText(FText(text))
    -- text never draws outside its own box. Right-aligned text is clipped by its row instead.
    if options.justify ~= style.Justify.Right then widget:SetClipping(style.Clip.ClipToBounds) end
    if options.wrap then
        widget.WrappingPolicy = style.Wrapping.AnyCharacter
        widget:SetAutoWrapText(true)
    end
    if options.justify then widget:SetJustification(options.justify) end
    labels[widget] = { text = text, shown = text, size = size, drawn = size, face = options.face, family = options.family,
        wraps = options.wrap and true or false, free = options.free and true or nil }
    return widget
end

-- The text block wraps at a width its maker keeps right (SetWrapTextAt).
function kit.wraps(widget)
    local info = labels[widget]
    if info then info.wraps = true end
end

-- Which rule keeps a text block's letters whole: "wraps", "fitted" (kit.fit gave it a room), "free" (it is as wide as its text
-- and what holds it gives it that: said with free = true, or by kit.fit with no room). Nothing: no rule, and it can be cut mid-letter.
function kit.rule(info)
    if info.wraps then return "wraps" end
    if info.room then return "fitted" end
    if info.free then return "free" end
    return nil
end

-- Widths of the interface font's letters, as the game measured them at size 11 on a 1440p screen: one letter of these
-- strings for each letter from the space to "~", "a" for nothing and one step for each pixel there.
local WIDTHS = {
    Medium = "ffipmmnfhhikeiejmhllmmmlmmeekkklsnmmnllmnflmlqnnmmmmlnmrmmlhjhllkklklkhllffkfqllllikhlkokkjigik",
    Bold = "ffjpmmnfhhikfifkmillmmmlmmffkkkltnmmnllmnglnlqonmmmmlnmsmmlhkholillklkhllffkfqllllikhlkpkkjjhjk",
    Book = "fghommnehhikeiejmhllmmmkmmeekkklsmmmnllmnflmlqnmmmmmlnmrmllhjhkllklklkhlleekeqllllhkhljojkjhghk",
}
local STEP = 0.0717     -- one such pixel, in units, for a font of size 1
local OTHER = 11        -- a letter outside those
local EDGE = 0.8        -- what a text block is wider than its letters
local MONO = 0.8        -- of the size: every letter of the fixed-width font

kit.FIT = 0.95          -- letters are drawn on whole pixels: on another screen a line is up to this much wider or narrower than is worked out here

-- What the letters of a text add up to.
local function letters_width(text, size, family, face)
    if family == "mono" then return (utf8.len(text) or #text) * MONO * size end
    local widths, total = WIDTHS[face or "Medium"] or WIDTHS.Medium, 0
    for at = 1, #text do
        local byte = text:byte(at)
        if byte >= 32 and byte < 127 then
            total = total + widths:byte(byte - 31) - 97
        elseif byte < 128 or byte >= 192 then
            -- the later bytes of a letter outside ASCII add nothing
            total = total + OTHER
        end
    end
    return total * STEP * size
end

-- How wide a line of text is, worked out from its letters: within a few hundredths of what the game answers once it is drawn.
function kit.text_width(content, size, family, face)
    local text = written(content)
    if text == "" then return 0 end
    return letters_width(text, size or style.theme.font_size, family, face) + (family == "mono" and 0 or EDGE)
end

-- The text if it fits in `width`, else its start with "..." after it (its end, with from_end). Also returns whether it was cut.
function kit.shorten(content, width, size, family, from_end, face)
    local text = written(content)
    size = size or style.theme.font_size
    if kit.text_width(text, size, family, face) <= width then return text, false end
    local room = width - kit.text_width("...", size, family, face)
    if room <= 0 then return "", true end
    local letters = {}
    for letter in text:gmatch(utf8.charpattern) do letters[#letters + 1] = letter end
    local first, last, step = 1, #letters, 1
    if from_end then first, last, step = #letters, 1, -1 end
    local used, kept = 0, 0
    for at = first, last, step do
        used = used + letters_width(letters[at], size, family, face)
        if used > room then break end
        kept = kept + 1
    end
    if kept == 0 then return "", true end
    if from_end then return "..." .. table.concat(letters, "", #letters - kept + 1), true end
    return (table.concat(letters, "", 1, kept):gsub("%s+$", "")) .. "...", true
end

-- The widest line of a text.
local function widest(text, size, family, face)
    if not text:find("\n", 1, true) then return kit.text_width(text, size, family, face) end
    local most = 0
    for line in text:gmatch("[^\n]*") do most = math.max(most, kit.text_width(line, size, family, face)) end
    return most
end

-- Each line of a text cut to a width.
local function shorten_lines(text, room, size, family, from_end, face)
    if not text:find("\n", 1, true) then return kit.shorten(text, room, size, family, from_end, face) end
    local lines, cut = {}, false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local shown, was = kit.shorten(line, room, size, family, from_end, face)
        lines[#lines + 1], cut = shown, cut or was
    end
    return table.concat(lines, "\n"), cut
end

kit.MEASURE = true      -- close cases are decided by the game's own measure of the text block (the tests switch it off)
kit.measured = 0        -- how often it was asked

-- How wide the game says a text block is with the text it has now. Nothing when it cannot say (the block is not built yet).
local function measure(widget)
    if not kit.MEASURE then return nil end
    kit.measured = kit.measured + 1
    widget:ForceLayoutPrepass()
    local size = widget:GetDesiredSize()
    local wide = size and size.X
    if type(wide) ~= "number" or wide <= 0 then return nil end
    return wide
end

-- Whether `text` at `size` fits in `room`. Worked out from the letters where that is clear. Where it is close (the letters
-- of another screen or interface size are a few percent wider or narrower), the text is put on and the game is asked.
local function fits(widget, info, text, size, room)
    local wide = widest(text, size, info.family, info.face)
    if wide <= room * kit.FIT then return true end
    if wide > room / kit.FIT then return false end
    if size ~= info.drawn then
        info.drawn = size
        widget:SetFont(style.font(size, info.face, info.family))
    end
    if text ~= info.shown then
        info.shown = text
        widget:SetText(FText(text))
    end
    local real = measure(widget)
    if real then return real <= room + 0.25 end
    return wide <= room
end

-- Shows a text block's text in the room it has: whole when it fits, at the largest of its sizes that it fits at, and each
-- line cut with dots only when it is wider than its room at the smallest.
local function show(widget, info)
    local shown, cut, size = info.text, false, info.size
    if info.room and not info.wraps then
        local room, whole = info.room, false
        for _, try in ipairs(info.sizes or { info.size }) do
            size = try
            if fits(widget, info, info.text, try, room) then
                whole = true
                break
            end
        end
        -- the dots go on with a little to spare, so what is cut is never cut a second time by its own box
        if not whole then shown, cut = shorten_lines(info.text, room * kit.FIT, size, info.family, info.from_end, info.face) end
    end
    if size ~= info.drawn then
        info.drawn = size
        widget:SetFont(style.font(size, info.face, info.family))
    end
    if shown ~= info.shown then
        info.shown = shown
        widget:SetText(FText(shown))
    end
    info.cut = cut
    return cut
end

-- Changes the text of a text block made by kit.label. In the room it was given (kit.fit) it is cut with dots when it does not
-- fit. True when it shows cut.
function kit.set_text(widget, content)
    local info = labels[widget]
    local text = written(content)
    if not info then
        widget:SetText(FText(text))
        return false
    end
    info.text = text
    return show(widget, info)
end

-- Says how wide a one-line text block may be, in its own units, now and whenever its text changes. nil: as wide as it likes.
-- options: sizes (font sizes it may be drawn at, the largest first), from_end (keep the end of the text).
-- A text of several lines has each line cut on its own, and keeps its number of lines. True when it shows cut.
function kit.fit(widget, room, options)
    local info = labels[widget]
    if not info then return false end
    info.room = room and math.max(0, room) or nil
    if not room then info.free = true end
    if options then info.sizes, info.from_end = options.sizes, options.from_end end
    return show(widget, info)
end

-- The whole text of a text block that shows cut. Nothing for one that shows whole.
function kit.whole(widget)
    local info = labels[widget]
    return info and info.cut and info.text or nil
end

-- What a text block was last given to say, cut or not.
function kit.said(widget)
    local info = labels[widget]
    return info and info.text or nil
end

-- For the tests: every text block alive and what is kept of it.
function kit.labels() return labels end

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
        local content = button:SetContent(kit.label(caption, { size = options.size, color = options.text, free = true }))
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
