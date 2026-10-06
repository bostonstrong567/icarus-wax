-- The controls: everything a mod can put in a window, a page, a section or an overlay

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")
local events = Wax.import("gui.events")
local tween = Wax.import("gui.tween")
local input = Wax.import("gui.input")
local picker = Wax.import("gui.picker")
local sched = Wax.import("core.sched")
local guard = Wax.import("core.guard")
local scope = Wax.import("core.scope")

local controls = {}
local open_list = nil      -- the parts of the dropdown whose list is showing

local V, H, VA = style.Visibility, style.HAlign, style.VAlign
local MAX_DROPDOWN_ROWS, LONG_DROPDOWN_ROWS = 10, 8.5      -- a longer list scrolls, showing this many rows

local Control = {}
Control.__index = Control

local function gone() error("this control no longer exists (its window was closed or its mod reloaded)", 2) end

-- After this, nothing the control offers reaches the engine any more.
function controls.retire(control)
    control.destroyed = true
    for key, value in pairs(control) do
        if type(value) == "function" then control[key] = gone end
    end
    control.SetVisible, control.SetEnabled = gone, gone
    control.Destroy = function() end
end

-- Destroys every control in this container and in containers inside it, so Lua holds no widget the engine is about to free.
function controls.destroy_within(host, container)
    local list = host.controls
    for index = #list, 1, -1 do
        local control = list[index]
        if control and control.container == container and not control.destroyed then control:Destroy() end
    end
end

function Control:Destroy()
    if self.destroyed then return end
    if self.inner then controls.destroy_within(self.window, self.inner) end
    for _, inner in ipairs(self.inners or {}) do controls.destroy_within(self.window, inner) end
    self.destroyed = true
    for _, disconnect in ipairs(self.disconnects) do disconnect() end
    pcall(function() (self.cell or self.widget):RemoveFromParent() end)
    local list = self.window.controls
    for index = #list, 1, -1 do
        if list[index] == self then
            table.remove(list, index)
            break
        end
    end
    controls.retire(self)
end

function Control:SetVisible(shown)
    (self.cell or self.widget):SetVisibility(shown and V.Visible or V.Collapsed)
end

function Control:SetEnabled(enabled)
    self.widget:SetIsEnabled(enabled and true or false)
    self.widget:SetRenderOpacity(enabled and 1 or 0.45)
    -- no hand cursor over a control that cannot be pressed
    if self.source and self.pointer ~= false then
        self.source:SetCursor(enabled and style.Cursor.Hand or style.Cursor.Default)
    end
end

local function blank_control()
    return setmetatable({ disconnects = {}, Changed = sched.Signal.new("Changed") }, Control)
end

-- The control a builder is making: the one its build was started for (see the end of this file).
local function new_control(container, widget)
    local host = container.window
    local control = style.owner()
    if getmetatable(control) ~= Control or control.widget then control = blank_control() end
    control.window, control.container, control.widget = host, container, widget
    host.controls[#host.controls + 1] = control
    control.cell, container.pending_cell = container.pending_cell, nil
    return control
end

-- Runs a callback given by a mod as a task: it may call task.wait, and an error in it is reported, not raised.
local function call(callback, ...)
    if callback then sched.task.spawn(callback, ...) end
end

-- Each thing the user does to a control is noted first, so a crash report can be matched to the last action.
local blackbox = Wax.import("core.blackbox")
local function listen(control, widget, delegate, handler)
    local quiet = delegate == "OnHovered" or delegate == "OnUnhovered" or delegate == "OnValueChanged" or delegate == "OnTextChanged"
    local function noted(...)
        if not quiet then blackbox.note(("gui %s in '%s'"):format(delegate, tostring(control.window.title or "overlay"))) end
        return handler(...)
    end
    local disconnect, address = events.connect(widget, delegate, control.window.parking, noted)
    control.disconnects[#control.disconnects + 1] = disconnect
    control.addresses = control.addresses or {}
    control.addresses[address] = true
end

-- A container that controls can be added to: a window, a page, a section, a row or an overlay.
local Container = {}
Container.__index = Container
controls.Container = Container

function controls.container(host, box, options)
    options = options or {}
    return setmetatable({ window = host, box = box, horizontal = options.horizontal or false, inset = options.inset or 0, count = 0,
        parent = options.parent }, Container)
end

-- The width text may use before it has to wrap.
function controls.wrap_width(container)
    if container.fixed_width then return math.max(20, container.fixed_width) end
    local host = container.window
    return math.max(60, host.width - (host.nav_width or 0) - container.inset)
end

-- text draws a few percent wider than it measures at a fractional screen scale, so wrap a little early
local WRAP_SAFETY = 0.94

-- In a grid, as many cells as fit share the width exactly, so the grid lines up with what is above and below it.
local function cell_width(container)
    local width, gap = controls.wrap_width(container), style.theme.spacing
    local count = math.max(1, math.floor((width + gap) / (container.cell_size + gap)))
    return (width - (count - 1) * gap) / count - 0.25
end

local function place(container, widget, options)
    options = options or {}
    local theme = style.theme
    if container.window.destroyed then error("this window no longer exists", 3) end
    local box = container.box or container:DefaultBox()
    -- whatever a control draws stays inside the cell it is given
    widget:SetClipping(style.Clip.ClipToBounds)
    local layout_slot
    if container.cell_size then
        local cell = kit.sized(widget, cell_width(container))
        container.cells[#container.cells + 1] = style.claim({ box = cell })
        container.pending_cell = cell
        layout_slot = box:AddChild(cell)
    else
        layout_slot = box:AddChild(widget)
    end
    if container.fills then
        kit.slot(layout_slot, { h = H.Fill, v = VA.Fill, fill = 1 })
    elseif container.flow then
        kit.slot(layout_slot, { v = VA.Center })
    elseif container.horizontal then
        -- cells share the width, except ones that ask to be only as wide as their content
        local gap = container.count > 0 and (options.gap or (options.snug and theme.spacing * 2 or theme.spacing)) or 0
        kit.slot(layout_slot, { pad = style.margin(gap, 0, 0, 0), v = options.v or VA.Center, h = H.Fill,
            fill = not options.snug and (options.weight or 1) or nil })
    else
        kit.slot(layout_slot, { pad = options.pad or style.margin(0, 0, 0, theme.spacing), h = options.h or H.Fill,
            v = options.fill and VA.Fill or nil, fill = options.fill and 1 or nil })
    end
    container.count = container.count + 1
    return layout_slot
end

-- Text that sizes itself wraps at a share of its container. It must not also wrap automatically, or it breaks off its last letter.
local function wrap_at(container, widget, share)
    widget.WrappingPolicy = style.Wrapping.AnyCharacter
    widget:SetWrapTextAt(controls.wrap_width(container) * share * WRAP_SAFETY)
    local host = container.window
    host.wrapped = host.wrapped or {}
    host.wrapped[#host.wrapped + 1] = style.claim({ widget = widget, container = container, share = share })
end

-- Called by the host when its width changes.
function controls.rewrap(host)
    local kept = {}
    for _, entry in ipairs(host.wrapped or {}) do
        if style.alive(entry) then
            entry.widget:SetWrapTextAt(controls.wrap_width(entry.container) * entry.share * WRAP_SAFETY)
            kept[#kept + 1] = entry
        end
    end
    host.wrapped = kept
    local resizers = {}
    for _, entry in ipairs(host.resizers or {}) do
        if style.alive(entry) then
            entry.apply()
            resizers[#resizers + 1] = entry
        end
    end
    host.resizers = resizers
    if host.frame then host.frame:InvalidateLayoutAndVolatility() end
end

-- A row that starts with a caption. share is the part of the row the caption may use. top keeps it level with the control's first line.
local function caption_row(container, caption, share, top)
    local row = root.new("HorizontalBox")
    local name = kit.label(caption, { wrap = true })
    if not container.horizontal then wrap_at(container, name, share) end
    kit.slot(row:AddChild(name), { v = top and VA.Top or VA.Center, pad = style.margin(0, top and 7 or 0, 10, 0), fill = 1 })
    return row, name
end

-- Side by side needs room. In a narrow container, or with a long caption, the caption goes on a line of its own.
local function stacks(container, caption, choice)
    if choice ~= nil then return choice end
    if container.horizontal then return false end
    return controls.wrap_width(container) < 300 or #tostring(caption) > 34
end

local function caption_above(container, caption)
    local column = root.new("VerticalBox")
    local name = kit.label(caption, { wrap = true })
    wrap_at(container, name, 1)
    kit.slot(column:AddChild(name), { h = H.Fill, pad = style.margin(0, 0, 0, 5) })
    return column
end

-- options: { dim, color, size, face, family }
function Container:Label(content, options)
    options = options or {}
    local widget = kit.label(content, { wrap = not self.horizontal, color = options.dim and style.theme.dim or options.color,
        size = options.size, face = options.face, family = options.family })
    if not self.horizontal then wrap_at(self, widget, 1) end
    place(self, widget)
    local control = new_control(self, widget)
    function control:Set(value) widget:SetText(kit.text(value)) end
    function control:SetColor(color) style.tint(widget, "text", style.to_color(color)) end
    return control
end

-- A title for a page or a group of controls: large text, an optional line of explanation, and a rule under it.
function Container:Title(content, description)
    local theme = style.theme
    local column = root.new("VerticalBox")
    local title = kit.label(content, { size = theme.title_size + 3, face = "Bold", wrap = true })
    wrap_at(self, title, 1)
    kit.slot(column:AddChild(title), { h = H.Fill })
    local note = nil
    if description then
        note = kit.label(description, { color = theme.dim, wrap = true })
        wrap_at(self, note, 1)
        kit.slot(column:AddChild(note), { h = H.Fill, pad = style.margin(0, 3, 0, 0) })
    end
    local rule = kit.image(theme.line, nil, 1, 1)
    kit.slot(column:AddChild(rule), { h = H.Fill, pad = style.margin(0, 9, 0, 0) })
    place(self, column, { pad = style.margin(0, self.count > 0 and 8 or 0, 0, theme.spacing + 2) })
    local control = new_control(self, column)
    function control:Set(value) title:SetText(kit.text(value)) end
    function control:SetDescription(value) if note then note:SetText(kit.text(value)) end end
    return control
end

function Container:Heading(content)
    local theme = style.theme
    local widget = kit.label(content, { size = theme.title_size, face = "Bold", wrap = not self.horizontal })
    if not self.horizontal then wrap_at(self, widget, 1) end
    place(self, widget, { pad = style.margin(0, self.count > 0 and 6 or 0, 0, theme.spacing) })
    local control = new_control(self, widget)
    function control:Set(value) widget:SetText(kit.text(value)) end
    return control
end

function Container:Separator()
    local theme = style.theme
    local line = kit.image(theme.line, nil, 1, 1)
    place(self, line, { pad = style.margin(0, 2, 0, theme.spacing + 2) })
    return new_control(self, line)
end

function Container:Spacer(height)
    local gap = kit.sized(nil, nil, height or style.theme.spacing)
    place(self, gap, { pad = style.margin(0) })
    return new_control(self, gap)
end

-- options: { primary, stretch = true (false keeps it as wide as its caption), icon, spin }. An icon with no caption makes an icon button.
function Container:Button(caption, on_click, options)
    options = options or {}
    local theme = style.theme
    local look = options.primary and { color = style.WHITE, hover = { R = 0.8, G = 0.8, B = 0.8, A = 1 },
        press = { R = 0.62, G = 0.62, B = 0.62, A = 1 } } or {}
    local button, picture
    if options.icon then
        look.padding = caption and style.margin(10, 5, 12, 5) or style.margin(7, 6)
        button = kit.button(nil, look)
        local content = root.new("HorizontalBox")
        local ink = options.primary and theme.on_accent or theme.text
        picture = kit.icon(options.icon, 16, ink)
        kit.slot(content:AddChild(picture), { v = VA.Center, pad = style.margin(0, 0, caption and 7 or 0, 0) })
        if caption then kit.slot(content:AddChild(kit.label(caption, { color = ink })), { v = VA.Center }) end
        kit.slot(button:SetContent(content), { h = H.Center, v = VA.Center })
    else
        if options.primary then look.text = theme.on_accent end
        button = kit.button(caption, look)
    end
    if options.primary then style.follow(function() button:SetBackgroundColor(style.theme.accent) end) end
    local natural = options.stretch == false or (options.stretch == nil and options.icon ~= nil and caption == nil)
    place(self, button, { h = natural and H.Left or H.Fill, snug = natural, gap = theme.spacing })
    local control = new_control(self, button)
    control.source = button
    control.Activated = control.Changed
    function control:SetIcon(name)
        if not picture then error("this button was made without an icon", 2) end
        kit.set_icon(picture, name, 16)
    end
    local turning = nil
    -- Turns the icon round once, to show that something has started.
    function control:Spin()
        if not picture or theme.animation <= 0 then return end
        if turning then turning.cancel() end
        turning = tween.run(0.55, function(progress) picture:SetRenderTransformAngle(360 * progress) end,
            function() picture:SetRenderTransformAngle(0) end, "in_out", control)
    end
    listen(control, button, "OnClicked", function()
        if options.spin then control:Spin() end
        call(on_click)
        control.Changed:Fire()
    end)
    return control
end

-- An icon on its own. options: { size = 20, color }. control:Set(name) changes it.
function Container:Icon(name, options)
    options = options or {}
    local size = options.size or 20
    local picture = kit.icon(name, size, options.color or style.theme.text)
    local holder = kit.sized(picture, size, size)
    place(self, holder, { h = H.Left, snug = true })
    local control = new_control(self, holder)
    function control:Set(new_name) kit.set_icon(picture, new_name, size) end
    return control
end

-- A switch. on_change(on) runs when the user flips it.
function Container:Toggle(caption, initial, on_change)
    local theme = style.theme
    -- on its own line the switch sits at the right edge. In a row it stays next to its label.
    local compact = self.horizontal
    local row, name
    if compact then row = root.new("HorizontalBox") else row, name = caption_row(self, caption, 0.78) end
    local button = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear, padding = style.margin(0) })
    local switch = root.new("Overlay")
    local track = kit.box(theme.raised, style.capsule(18))
    kit.slot(switch:AddChild(kit.sized(track, 34, 18)), { h = H.Left, v = VA.Center })
    local knob = kit.image(theme.on_accent, style.capsule(12), 12, 12)
    kit.slot(switch:AddChild(knob), { h = H.Left, v = VA.Center, pad = style.margin(3, 0, 0, 0) })
    button:SetContent(switch)
    kit.slot(row:AddChild(button), { v = VA.Center })
    if compact then
        name = kit.label(caption)
        kit.slot(row:AddChild(name), { v = VA.Center, pad = style.margin(8, 0, 0, 0) })
    end
    place(self, row, { snug = compact })

    local control = new_control(self, row)
    control.source = button
    local value = initial and true or false
    local position, animation = value and 1 or 0, nil
    local function show(progress)
        position = progress
        knob:SetRenderTranslation({ X = 16 * progress, Y = 0 })
        style.tint(track, "box", style.mix(theme.raised, theme.accent, progress))
    end
    local function animate()
        if animation then animation.cancel() end
        local from, to = position, value and 1 or 0
        animation = tween.run(theme.animation, function(progress) show(from + (to - from) * progress) end, nil, nil, control)
    end
    show(position)
    function control:Get() return value end
    function control:Set(on, instant)
        value = on and true or false
        if not instant then return animate() end
        if animation then animation.cancel() end
        show(value and 1 or 0)
    end
    function control:SetCaption(text) name:SetText(kit.text(text)) end
    listen(control, button, "OnClicked", function()
        value = not value
        animate()
        call(on_change, value)
        control.Changed:Fire(value)
    end)
    return control
end

-- options: { min = 0, max = 1, value = min, step, format = "%.2f", stacked, live = true (false: on_change runs once, on release) }
function Container:Slider(caption, options, on_change)
    options = options or {}
    local theme = style.theme
    local minimum, maximum = options.min or 0, options.max or 1
    local format = options.format or (options.step and options.step >= 1 and "%d" or "%.2f")
    local function shown(value) return format == "%d" and ("%d"):format(math.floor(value + 0.5)) or format:format(value) end

    local stacked = stacks(self, caption, options.stacked)
    local slider = root.new("Slider")
    local look = slider.WidgetStyle
    style.paint(look.NormalBarImage, theme.raised, style.capsule(4), 4, 4)
    style.paint(look.HoveredBarImage, theme.hover, style.capsule(4), 4, 4)
    style.paint(look.DisabledBarImage, theme.panel, style.capsule(4), 4, 4)
    style.paint(look.NormalThumbImage, style.WHITE, style.capsule(14), 14, 14)
    style.paint(look.HoveredThumbImage, { R = 0.8, G = 0.8, B = 0.8, A = 1 }, style.capsule(14), 14, 14)
    style.follow(function() slider:SetSliderHandleColor(style.theme.accent) end)
    style.paint(look.DisabledThumbImage, theme.dim, style.capsule(14), 14, 14)
    look.BarThickness = 4
    slider.IsFocusable = false
    slider:SetCursor(style.Cursor.Hand)
    slider:SetMinValue(minimum)
    slider:SetMaxValue(maximum)
    if options.step then slider:SetStepSize(options.step) end
    local value = options.value or minimum
    slider:SetValue(value)
    -- the number is a small text box: click it to type a value
    local readout = root.new("EditableTextBox")
    local box_look = readout.WidgetStyle
    style.paint(box_look.BackgroundImageNormal, theme.clear)
    style.paint(box_look.BackgroundImageHovered, theme.raised, theme.control_shape)
    style.paint(box_look.BackgroundImageFocused, theme.raised, theme.control_shape)
    style.paint(box_look.BackgroundImageReadOnly, theme.clear)
    box_look.Font = style.font(theme.small_size, nil, "mono")
    style.tint(box_look, "ink", theme.dim)
    box_look.Padding = style.margin(5, 3)
    readout:SetJustification(style.Justify.Right)
    readout:SetText(kit.text(shown(value)))
    local readout_box = kit.sized(readout)
    readout_box:SetMinDesiredWidth(52)
    local row
    if stacked then
        -- caption and number on one line, the track across the full width under them
        local top = caption_row(self, caption, 0.68)
        kit.slot(top:AddChild(readout_box), { v = VA.Center })
        row = root.new("VerticalBox")
        kit.slot(row:AddChild(top), { h = H.Fill })
        kit.slot(row:AddChild(slider), { h = H.Fill, pad = style.margin(0, 6, 0, 2) })
    else
        row = caption_row(self, caption, 0.46)
        local right = root.new("HorizontalBox")
        kit.slot(right:AddChild(slider), { v = VA.Center, fill = 1 })
        kit.slot(right:AddChild(readout_box), { v = VA.Center, pad = style.margin(8, 0, 0, 0) })
        kit.slot(row:AddChild(right), { v = VA.Center, fill = 1 })
    end
    place(self, row)

    local control = new_control(self, row)
    control.source = slider
    local function snap(raw)
        if options.step and options.step > 0 then raw = minimum + math.floor((raw - minimum) / options.step + 0.5) * options.step end
        return math.max(minimum, math.min(maximum, raw))
    end
    local unreported = false
    function control:Get() return value end
    function control:Set(new_value)
        value = snap(new_value)
        slider:SetValue(value)
        readout:SetText(kit.text(shown(value)))
    end
    listen(control, slider, "OnValueChanged", function(raw)
        local snapped = snap(raw)
        if snapped == value then return end
        value = snapped
        readout:SetText(kit.text(shown(value)))
        if options.live == false then
            unreported = true
            return
        end
        call(on_change, value)
        control.Changed:Fire(value)
    end)
    listen(control, readout, "OnTextCommitted", function(typed)
        local number = tonumber((typed:gsub("[^%d%.%-]", "")))
        if not number or snap(number) == value then
            readout:SetText(kit.text(shown(value)))
            return
        end
        value, unreported = snap(number), false
        slider:SetValue(value)
        readout:SetText(kit.text(shown(value)))
        call(on_change, value)
        control.Changed:Fire(value)
    end)
    control.Released = sched.Signal.new("Released")
    listen(control, slider, "OnMouseCaptureEnd", function()
        if unreported then
            unreported = false
            call(on_change, value)
            control.Changed:Fire(value)
        end
        control.Released:Fire(value)
    end)
    return control
end

-- options: { text, hint, stacked, mono (a fixed-width font, for code) }. on_commit(text) runs on Enter or when the box loses focus.
function Container:Input(caption, options, on_commit)
    options = options or {}
    local theme = style.theme
    local captioned = caption ~= nil and caption ~= ""
    local stacked = captioned and stacks(self, caption, options.stacked)
    local row = stacked and caption_above(self, caption) or root.new("HorizontalBox")
    if captioned and not stacked then
        local name = kit.label(caption, { wrap = true })
        if not self.horizontal then wrap_at(self, name, 0.46) end
        kit.slot(row:AddChild(name), { v = VA.Center, pad = style.margin(0, 0, 10, 0), fill = 1 })
    end
    local box = root.new("EditableTextBox")
    local look = box.WidgetStyle
    style.paint(look.BackgroundImageNormal, theme.panel, theme.control_shape)
    style.paint(look.BackgroundImageHovered, theme.raised, theme.control_shape)
    style.paint(look.BackgroundImageFocused, theme.raised, theme.control_shape)
    style.paint(look.BackgroundImageReadOnly, theme.panel, theme.control_shape)
    look.Font = options.mono and style.font(theme.font_size, nil, "mono") or style.font(theme.font_size, "Book")
    style.tint(look, "ink", theme.text)
    look.Padding = options.mono and style.margin(9, 6.5, 9, 5.5) or style.margin(9, 6)
    if options.hint then box:SetHintText(kit.text(options.hint)) end
    if options.text then box:SetText(kit.text(options.text)) end
    local field, ghost = box, nil
    if options.mono then
        -- greyed text laid over the box, starting where the typed text ends (in this font every letter is as wide as a space)
        field = root.new("Overlay")
        field:SetClipping(style.Clip.ClipToBounds)
        kit.slot(field:AddChild(box), { h = H.Fill, v = VA.Fill })
        ghost = kit.label("", { family = "mono", size = theme.font_size, color = style.with_alpha(theme.dim, 0.75) })
        ghost:SetVisibility(V.HitTestInvisible)
        kit.slot(field:AddChild(ghost), { h = H.Left, v = VA.Center, pad = style.margin(9, 6.5, 9, 5.5) })
    end
    if stacked then
        kit.slot(row:AddChild(field), { h = H.Fill })
    else
        kit.slot(row:AddChild(field), { v = self.horizontal and VA.Fill or VA.Center, fill = 1 })
    end
    place(self, row, { v = VA.Fill })

    local control = new_control(self, row)
    control.source, control.pointer = box, false
    local value = options.text or ""
    function control:Get() return box:GetText():ToString() end
    function control:Set(new_text)
        value = tostring(new_text)
        box:SetText(kit.text(value))
    end
    control.Typed = sched.Signal.new("Typed")
    listen(control, box, "OnTextChanged", function(typed) control.Typed:Fire(typed) end)
    control.Entered = sched.Signal.new("Entered")
    local last_commit, last_at = nil, -1
    function control:Focus() box:SetKeyboardFocus() end
    function control:HasFocus() return box:HasKeyboardFocus() == true end
    -- Greyed text after what is typed (a preview of a completion). Only a box made with mono = true shows it.
    function control:SetGhost(text)
        if not ghost then return end
        local typed = box:GetText():ToString()
        text = tostring(text or "")
        ghost:SetText(kit.text(text == "" and "" or (" "):rep(utf8.len(typed) or #typed) .. text))
    end
    listen(control, box, "OnTextCommitted", function(committed)
        -- Enter is reported twice in a row (the commit, then the box losing the keyboard). Clicking away is reported once.
        local now = os.clock()
        if committed == last_commit and now - last_at < 0.2 then
            last_commit = nil
            control.Entered:Fire(committed)
        else
            last_commit, last_at = committed, now
        end
        if committed == value then return end
        value = committed
        call(on_commit, value)
        control.Changed:Fire(value)
    end)
    return control
end

-- Opens or closes an animated holder. parts: holder, content, chevron, angles, open, owner, fade, settled(), opened(height)
local function set_expanded(parts, open)
    if parts.open == open then return end
    parts.open = open
    if parts.animation then parts.animation.cancel() end
    parts.content:ForceLayoutPrepass()
    local full = math.max(parts.content:GetDesiredSize().Y, 1)
    -- an interrupted animation continues from the height it had reached
    local from, to = parts.height or (open and 0 or full), open and full or 0
    parts.holder:SetVisibility(V.Visible)
    parts.closing = not open        -- still showing its content until the animation ends
    if parts.settled then parts.settled() end
    parts.animation = tween.run(style.theme.animation, function(progress)
        local height = from + (to - from) * progress
        local share = math.min(1, height / full)
        parts.height = height
        parts.holder:SetHeightOverride(height)
        if parts.fade then parts.holder:SetRenderOpacity(share) end
        if parts.sized then parts.sized(share) end
        parts.chevron:SetRenderTransformAngle(parts.closed_angle + (parts.open_angle - parts.closed_angle) * share)
    end, function()
        parts.height = nil
        if open then
            parts.holder:ClearHeightOverride()      -- follow the content from here on
        else
            parts.holder:SetVisibility(V.Collapsed)
        end
        parts.closing = false
        if parts.settled then parts.settled() end
        if open and parts.opened then parts.opened(full) end
    end, nil, parts.owner)
end

-- The scroll box a container's controls are in, if any.
local function scroller_of(container)
    while container do
        if container.scroller then return container.scroller end
        container = container.parent
    end
end

local function holder_for(content, open)
    local holder = root.new("SizeBox")
    holder:SetClipping(style.Clip.ClipToBounds)
    holder:SetContent(content)
    if not open then
        holder:SetHeightOverride(0)
        holder:SetVisibility(V.Collapsed)
    end
    return holder
end

-- A dropdown that opens in place. on_change(choice) runs when the user picks one.
function Container:Dropdown(caption, choices, selected, on_change)
    local theme = style.theme
    local value = selected or choices[1]
    local longest = 0
    for _, choice in ipairs(choices) do longest = math.max(longest, #tostring(choice)) end
    local stacked = stacks(self, tostring(caption) .. (" "):rep(longest), nil)
    -- the header shows the chosen value. With room, the caption sits to its left and the header fills the right half.
    local outer, column
    if stacked then
        column = caption_above(self, caption)
        outer = column
    else
        outer = caption_row(self, caption, 0.46, true)
        column = root.new("VerticalBox")
        kit.slot(outer:AddChild(column), { v = VA.Top, fill = 1 })
    end
    -- header and list are one piece: the header's lower corners are square for as long as the list shows
    local head = root.new("Overlay")
    local back_closed, back_open = kit.box(theme.raised, "round6"), kit.box(theme.raised, "top6")
    back_open:SetVisibility(V.Hidden)
    kit.slot(head:AddChild(back_closed), { h = H.Fill, v = VA.Fill })
    kit.slot(head:AddChild(back_open), { h = H.Fill, v = VA.Fill })
    local header = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear,
        padding = style.margin(10, 6, 10, 6) })
    local header_row = root.new("HorizontalBox")
    local shown = kit.label(value, { wrap = true })
    wrap_at(self, shown, stacked and 0.8 or 0.36)
    kit.slot(header_row:AddChild(shown), { v = VA.Center, pad = style.margin(0, 0, 8, 0), fill = 1 })
    local chevron = kit.icon("chevron-down", 14, theme.dim)
    kit.slot(header_row:AddChild(chevron), { v = VA.Center, pad = style.margin(0, 1, 0, 0) })
    kit.fill_content(header, header_row)
    kit.slot(head:AddChild(header), { h = H.Fill, v = VA.Fill })
    kit.slot(column:AddChild(head), { h = H.Fill })

    local panel = kit.box(theme.raised, "bottom6", style.margin(4, 0, 4, 4))
    local stack = root.new("VerticalBox")
    kit.slot(stack:AddChild(kit.image(theme.hover, nil, 1, 1)), { h = H.Fill, pad = style.margin(6, 4, 6, 6) })
    local list = root.new("VerticalBox")
    if #choices > MAX_DROPDOWN_ROWS then
        local scroller = kit.scroll_box()
        kit.slot(scroller:AddChild(list), { pad = style.margin(0, 0, kit.GUTTER - 2, 0) })
        local limit = kit.sized(scroller)
        limit:SetMaxDesiredHeight(LONG_DROPDOWN_ROWS * theme.row_height)
        kit.slot(stack:AddChild(limit), { h = H.Fill })
    else
        kit.slot(stack:AddChild(list), { h = H.Fill })
    end
    panel:SetContent(stack)
    local holder = holder_for(panel, false)
    kit.slot(column:AddChild(holder), { h = H.Fill })
    place(self, outer)

    local control = new_control(self, outer)
    local parts = { holder = holder, content = panel, chevron = chevron, closed_angle = 0, open_angle = 180, open = false,
        owner = control, column = column }
    control.source, control.items, control.parts = header, {}, parts
    parts.settled = function()
        local joined = parts.open or parts.closing
        back_open:SetVisibility(joined and V.HitTestInvisible or V.Hidden)
        back_closed:SetVisibility(joined and V.Hidden or V.HitTestInvisible)
    end
    -- once open, the page scrolls far enough to show the whole list (when the window is tall enough to hold it)
    parts.opened = function(height)
        local scroller, host = scroller_of(self), self.window
        if scroller and host.height and height < host.height - 150 then scroller:ScrollWidgetIntoView(holder, true, 0, 10) end
    end
    local rows = {}
    local function mark()
        for choice, row in pairs(rows) do
            local on = choice == value
            row.check:SetVisibility(on and V.HitTestInvisible or V.Hidden)
            row.chosen:SetVisibility(on and V.HitTestInvisible or V.Hidden)
        end
        shown:SetText(kit.text(value))
    end
    local function choose(choice)
        value = choice
        mark()
        set_expanded(parts, false)
        call(on_change, value)
        control.Changed:Fire(value)
    end
    for index, choice in ipairs(choices) do
        local cell = root.new("Overlay")
        local chosen = kit.box(style.with_alpha(theme.accent, 0.18), "round4")
        kit.slot(cell:AddChild(chosen), { h = H.Fill, v = VA.Fill })
        -- the highlight under the mouse is a faint layer of the text colour, so it shows on a chosen row too
        local item = kit.button(nil, { shape = "round4", color = theme.clear, hover = style.with_alpha(theme.text, 0.07),
            press = style.with_alpha(theme.text, 0.12), padding = style.margin(8, 5, 8, 5) })
        local item_row = root.new("HorizontalBox")
        kit.slot(item_row:AddChild(kit.label(choice, { wrap = true })), { v = VA.Center, pad = style.margin(0, 0, 8, 0), fill = 1 })
        local check = kit.icon("check", 14, theme.accent_hover)
        kit.slot(item_row:AddChild(check), { v = VA.Center, pad = style.margin(0, 1, 0, 0) })
        kit.fill_content(item, item_row)
        kit.slot(cell:AddChild(item), { h = H.Fill, v = VA.Fill })
        kit.slot(list:AddChild(cell), { h = H.Fill, pad = style.margin(0, 0, 0, index < #choices and 2 or 0) })
        control.items[choice], rows[choice] = item, { check = check, chosen = chosen }
        listen(control, item, "OnClicked", function() choose(choice) end)
    end
    mark()
    local function tint_head(color)
        style.tint(back_closed, "box", color)
        style.tint(back_open, "box", color)
    end
    listen(control, header, "OnHovered", function() tint_head(theme.hover) end)
    listen(control, header, "OnUnhovered", function() tint_head(theme.raised) end)
    listen(control, header, "OnClicked", function()
        -- any other list was closed on the way here (see events.seen at the end of this file)
        open_list = parts
        set_expanded(parts, not parts.open)
    end)
    function control:Get() return value end
    function control:Set(choice)
        value = choice
        mark()
    end
    return control
end

-- A card of controls with a title. Returns a container. options: { open = true, collapsible = true (false: a plain titled group) }
function Container:Section(title, options)
    options = options or {}
    local theme = style.theme
    local fixed = options.collapsible == false
    local open = fixed or options.open ~= false
    local card = root.new("Overlay")
    kit.slot(card:AddChild(kit.box(theme.card, "round8")), { h = H.Fill, v = VA.Fill })
    local column = root.new("VerticalBox")
    kit.slot(card:AddChild(column), { h = H.Fill, v = VA.Fill })
    local outline = kit.image(theme.card_line, "frame8", 1, 1)
    outline:SetVisibility(V.HitTestInvisible)
    kit.slot(card:AddChild(outline), { h = H.Fill, v = VA.Fill })

    -- the highlight under the mouse is rounded all round on a closed card, and only on top when the card is open
    local glow_open = kit.box(style.with_alpha(theme.hover, 0.45), "top8")
    local glow_closed = kit.box(style.with_alpha(theme.hover, 0.45), "round8")
    glow_open:SetVisibility(V.Hidden)
    glow_closed:SetVisibility(V.Hidden)
    local header = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear, padding = style.margin(10, 8) })
    local header_row = root.new("HorizontalBox")
    local chevron = kit.icon("chevron-down", 14, theme.dim)
    kit.slot(header_row:AddChild(chevron), { v = VA.Center, pad = style.margin(0, 0, 8, 0) })
    if fixed then
        chevron:SetVisibility(V.Collapsed)
        header:SetVisibility(V.HitTestInvisible)
    end
    kit.slot(header_row:AddChild(kit.label(title, { face = "Bold", wrap = true })), { v = VA.Center, fill = 1 })
    kit.fill_content(header, header_row)
    local header_stack = root.new("Overlay")
    kit.slot(header_stack:AddChild(glow_open), { h = H.Fill, v = VA.Fill })
    kit.slot(header_stack:AddChild(glow_closed), { h = H.Fill, v = VA.Fill })
    kit.slot(header_stack:AddChild(header), { h = H.Fill, v = VA.Fill })
    kit.slot(column:AddChild(header_stack), { h = H.Fill })

    local body = root.new("VerticalBox")
    local padded = kit.box(theme.clear, nil, style.margin(12, 2, 12, 12 - theme.spacing))
    padded:SetContent(body)
    local holder = holder_for(padded, open)
    kit.slot(column:AddChild(holder), { h = H.Fill })
    place(self, card)

    local control = new_control(self, card)
    local parts = { holder = holder, content = padded, chevron = chevron, closed_angle = -90, open_angle = 0, open = open,
        owner = control, fade = true }
    chevron:SetRenderTransformAngle(open and 0 or -90)
    control.source, control.parts = header, parts
    local section = controls.container(self.window, body, { inset = self.inset + 24, parent = self })
    section.parts, section.control = parts, control
    control.inner = section
    local hovered = false
    -- square bottom corners for as long as the content below is showing, including while it slides shut
    local function glow()
        local joined = parts.open or parts.closing
        glow_open:SetVisibility(hovered and joined and V.HitTestInvisible or V.Hidden)
        glow_closed:SetVisibility(hovered and not joined and V.HitTestInvisible or V.Hidden)
    end
    parts.settled = glow
    listen(control, header, "OnHovered", function()
        hovered = true
        glow()
    end)
    listen(control, header, "OnUnhovered", function()
        hovered = false
        glow()
    end)
    listen(control, header, "OnClicked", function()
        set_expanded(parts, not parts.open)
        glow()
    end)
    function section:SetOpen(value)
        set_expanded(parts, value and true or false)
        glow()
    end
    function section:IsOpen() return parts.open end
    return section
end

-- Controls added to the returned container keep their size and wrap onto new lines. options: { cell = width } gives every control the same width.
function Container:Flow(options)
    local theme = style.theme
    local box = root.new("WrapBox")
    box:SetInnerSlotPadding({ X = theme.spacing, Y = theme.spacing })
    place(self, box)
    local container = controls.container(self.window, box, { horizontal = true, inset = self.inset, parent = self })
    container.flow = true
    container.is_inner = true
    if options and options.cell then
        container.cell_size, container.cells = options.cell, {}
        local host = self.window
        host.resizers = host.resizers or {}
        host.resizers[#host.resizers + 1] = style.claim({ apply = function()
            local width, kept = cell_width(container), {}
            for _, entry in ipairs(container.cells) do
                if style.alive(entry) then
                    entry.box:SetWidthOverride(width)
                    kept[#kept + 1] = entry
                end
            end
            container.cells = kept
        end })
    end
    container.control = new_control(self, box)
    container.control.inner = container
    return container
end

-- Controls added to the returned container sit side by side and share the width.
function Container:Row()
    local row = root.new("HorizontalBox")
    place(self, row)
    local container = controls.container(self.window, row, { horizontal = true, inset = self.inset, parent = self })
    container.control = new_control(self, row)
    container.control.inner = container
    return container
end

-- A progress bar. value is 0..1. options: { color }
function Container:Progress(caption, value, options)
    options = options or {}
    local theme = style.theme
    local column = root.new("VerticalBox")
    local head = caption_row(self, caption, 0.8)
    local percent = kit.label("", { color = theme.dim, family = "mono", size = theme.small_size })
    kit.slot(head:AddChild(percent), { v = VA.Center })
    kit.slot(column:AddChild(head), { h = H.Fill })
    -- two cells sharing the track's width: the filled part and the rest
    local track = kit.box(theme.raised, style.capsule(6))
    local cells = root.new("HorizontalBox")
    local fill = kit.box(style.to_color(options.color) or theme.accent, style.capsule(6))
    local fill_slot = cells:AddChild(fill)
    local rest_slot = cells:AddChild(root.new("Spacer"))
    track:SetContent(cells)
    kit.slot(column:AddChild(kit.sized(track, nil, 6)), { h = H.Fill, pad = style.margin(0, 5, 0, 0) })
    place(self, column)

    local control = new_control(self, column)
    local current, shown, animation = 0, 0, nil
    local function show(amount)
        shown = amount
        fill:SetVisibility(amount > 0.002 and V.HitTestInvisible or V.Collapsed)
        fill_slot:SetSize({ SizeRule = style.SizeRule.Fill, Value = math.max(amount, 0.0001) })
        rest_slot:SetSize({ SizeRule = style.SizeRule.Fill, Value = math.max(1 - amount, 0.0001) })
    end
    function control:Get() return current end
    function control:Set(new_value)
        current = math.max(0, math.min(1, new_value or 0))
        percent:SetText(kit.text(("%d%%"):format(math.floor(current * 100 + 0.5))))
        if animation then animation.cancel() end
        local from, to = shown, current
        animation = tween.run(theme.animation, function(progress) show(from + (to - from) * progress) end, nil, nil, control)
    end
    function control:SetColor(color) style.tint(fill, "box", style.to_color(color)) end
    show(0)
    control:Set(value)
    return control
end

-- A name with a value on the right, for read-outs. control:Set(value) updates it. options: { mono } for changing numbers
function Container:Field(name, value, options)
    local theme = style.theme
    local row = root.new("HorizontalBox")
    local title = kit.label(name, { color = theme.dim })
    wrap_at(self, title, 0.38)
    kit.slot(row:AddChild(title), { v = VA.Center })
    local mono = options and options.mono
    local shown = kit.label(value == nil and "" or value, { wrap = true, justify = style.Justify.Right,
        family = mono and "mono" or nil, size = mono and theme.small_size or nil })
    wrap_at(self, shown, 0.6)
    kit.slot(row:AddChild(shown), { v = VA.Center, pad = style.margin(10, 0, 4, 0), fill = 1 })
    place(self, row)
    local control = new_control(self, row)
    function control:Set(new_value) shown:SetText(kit.text(new_value == nil and "" or new_value)) end
    function control:SetColor(color) style.tint(shown, "text", style.to_color(color)) end
    return control
end

-- A key the user can rebind: click it, then press the new key. on_change(key) gets the engine's key name.
function Container:Keybind(caption, key, on_change)
    local theme = style.theme
    local row = caption_row(self, caption, 0.46)
    local button = kit.button(nil, { padding = style.margin(10, 5) })
    local shown = kit.label(key or "none", { family = "mono", size = theme.small_size })
    local content = button:SetContent(shown)
    content:SetHorizontalAlignment(H.Center)
    content:SetVerticalAlignment(VA.Center)
    kit.slot(row:AddChild(button), { v = VA.Center, fill = 1 })
    place(self, row)

    local control = new_control(self, row)
    control.source = button
    local value = key
    local function show(text, color)
        shown:SetText(kit.text(text))
        style.tint(shown, "text", color)
    end
    function control:Get() return value end
    function control:Set(new_key)
        value = new_key
        show(value or "none", theme.text)
    end
    listen(control, button, "OnClicked", function()
        show("press a key", theme.accent_hover)
        input.capture(function(pressed)
            if control.destroyed then return end
            if pressed then value = pressed end
            show(value or "none", theme.text)
            if pressed then
                call(on_change, value)
                control.Changed:Fire(value)
            end
        end)
    end)
    return control
end

-- A scrolling list of text lines (a log) that can be selected and copied. options: { height = 220, max = 150 }
function Container:Console(options)
    options = options or {}
    local theme = style.theme
    local frame = kit.box(theme.panel, theme.control_shape, style.margin(8, 6, 4, 6))
    frame:SetClipping(style.Clip.ClipToBounds)
    local scroller = kit.scroll_box()
    -- two layers laid out alike: coloured text that takes no clicks, and over it the same text, see-through, to select
    local layers = root.new("Overlay")
    local list = root.new("VerticalBox")
    list:SetVisibility(V.HitTestInvisible)
    kit.slot(layers:AddChild(list), { h = H.Fill, v = VA.Top })
    kit.slot(scroller:AddChild(layers), { h = H.Fill, pad = style.margin(0, 0, kit.GUTTER, 0) })
    frame:SetContent(scroller)
    local fills = self.bounded and not options.height
    local holder = kit.sized(frame, nil, not fills and (options.height or 220) or nil)
    place(self, holder, fills and { fill = true } or nil)

    local control = new_control(self, holder)
    local blocks, shown_lines, last_runs, follow, limit = {}, {}, nil, true, options.max or 150
    local cover, cover_text, wrap, settling = nil, nil, 0, nil
    -- a text box takes its colours and wrap width when it is first shown, so each one is made with them
    local function text_box(text, color)
        local widget = root.new("MultiLineEditableText")
        local look = widget.WidgetStyle
        look.Font = style.font(theme.small_size, nil, "mono")
        look.ColorAndOpacity = style.slate(color)
        look.SelectedBackgroundColor = style.slate(style.with_alpha(style.theme.accent, 0.45))
        widget.bIsReadOnly, widget.AllowContextMenu = true, false
        -- a set width, not automatic wrapping: that only learns its width once the box has been drawn
        widget.WrapTextAt, widget.WrappingPolicy = wrap, style.Wrapping.AnyCharacter
        widget:SetText(kit.text(text))
        return widget
    end
    local function show(runs, anew)
        local width = math.max(60, (controls.wrap_width(self) - 12 - kit.GUTTER) * WRAP_SAFETY)
        if width ~= wrap then wrap, anew = width, true end
        -- existing boxes are kept while the runs still have the same colours in the same order
        local same = not anew and #runs >= #blocks
        for index = 1, #blocks do
            if not same or blocks[index].color ~= runs[index].color then
                same = false
                break
            end
        end
        if not same then
            list:ClearChildren()
            blocks = {}
        end
        for index, run in ipairs(runs) do
            local entry = blocks[index]
            if not entry then
                local widget = text_box(run.text, run.color)
                kit.slot(list:AddChild(widget), { h = H.Fill })
                blocks[index] = { widget = widget, color = run.color, text = run.text }
            elseif entry.text ~= run.text then
                entry.text = run.text
                entry.widget:SetText(kit.text(run.text))
            end
        end
        local all = table.concat(shown_lines, "\n")
        if anew and cover then
            cover:RemoveFromParent()
            cover = nil
        end
        if not cover then
            cover = text_box(all, style.with_alpha(theme.text, 0))
            kit.slot(layers:AddChild(cover), { h = H.Fill, v = VA.Fill })
            control.source = cover
        elseif cover_text ~= all then
            cover:SetText(kit.text(all))
        end
        cover_text, last_runs = all, runs
    end
    control.pointer = false
    -- lines: a list of { text, color }. Only the last `max` are shown.
    function control:SetLines(lines)
        local runs = {}
        shown_lines = {}
        for index = math.max(1, #lines - limit + 1), #lines do
            local line = lines[index]
            local text, color = tostring(line[1]), line[2] or theme.text
            shown_lines[#shown_lines + 1] = text
            local run = runs[#runs]
            if run and run.color == color then
                run[#run + 1] = text
            else
                runs[#runs + 1] = { text, color = color }
            end
        end
        for _, run in ipairs(runs) do run.text = table.concat(run, "\n") end
        show(runs, false)
        if follow then scroller:ScrollToEnd() end
    end
    -- Everything being shown, as one text (for copying).
    function control:GetText() return table.concat(shown_lines, "\n") end
    function control:SetFollow(on) follow = on and true or false end
    style.follow(function()
        if last_runs then show(last_runs, true) end
    end)
    -- a new width needs new boxes, made once, shortly after the resizing stops
    local host = self.window
    host.resizers = host.resizers or {}
    host.resizers[#host.resizers + 1] = style.claim({ apply = function()
        if settling or not last_runs then return end
        settling = sched.task.delay(0.15, function()
            settling = nil
            if control.destroyed then return end
            show(last_runs, false)
            if follow then scroller:ScrollToEnd() end
        end)
    end })
    return control
end

local grids = {}
local MAKE_PER_FRAME = 24

-- A grid for any number of items. Only the cells in view exist. options: { cell, cell_height, height, items, make, show }
function Container:Grid(options)
    options = options or {}
    if type(options.make) ~= "function" or type(options.show) ~= "function" then
        error("a grid needs make = function(cell) ... end and show = function(made, item, index) ... end", 2)
    end
    local theme, host = style.theme, self.window
    -- cells are made later, from the frame loop. What a cell sets up must still belong to whoever made the grid.
    local maker = scope.current()
    local function as_maker(label, fn, ...)
        local previous = scope.enter(maker)
        local ok, result = guard.call(label, fn, ...)
        scope.leave(previous)
        return ok, result
    end
    local gap, least = theme.spacing, options.cell or 38
    local cell_h = options.cell_height or least
    local pitch = cell_h + gap
    local fills = self.bounded and not options.height
    local fixed_view = options.height or 300
    local scroller = kit.scroll_box()
    local canvas = root.new("CanvasPanel")
    local content = kit.sized(canvas, nil, 1)
    kit.slot(scroller:AddChild(content), { h = H.Fill })
    local holder = kit.sized(scroller, nil, not fills and fixed_view or nil)
    -- its scroll bar goes in the page's gutter when it fills the page, and inside its own width otherwise
    place(self, holder, fills and { fill = true, pad = style.margin(0, 0, -kit.GUTTER, 0) } or nil)

    local control = new_control(self, holder)
    local items = options.items or {}
    local cells, columns, cell_w, total = {}, 1, least, 1
    local bound, pool_rows, measured = {}, 0, false      -- bound: place in the pool -> the row it is showing
    control.inners = {}
    local page = self
    while page and not page.holder do page = page.parent end
    if not page and host.nav then page = host.page end

    local function measure()
        local width = controls.wrap_width(self) - (fills and 0 or kit.GUTTER)
        columns = math.max(1, math.floor((width + gap) / (least + gap)))
        cell_w = (width - (columns - 1) * gap) / columns
        total = math.max(1, math.ceil(#items / columns) * pitch - gap)
        content:SetHeightOverride(total)
        for _, cell in pairs(cells) do
            cell.slot:SetSize({ X = cell_w, Y = cell_h })
            cell.container.fixed_width = cell_w
        end
        bound, measured = {}, true
    end

    local function cell_at(index)
        local cell = cells[index]
        if cell then return cell end
        local box = root.new("VerticalBox")
        local slot = canvas:AddChild(box)
        slot:SetAutoSize(false)
        slot:SetSize({ X = cell_w, Y = cell_h })
        local container = controls.container(host, box, { parent = self })
        container.fills, container.fixed_width = true, cell_w
        cell = { box = box, slot = slot, container = container, shown = true }
        cells[index] = cell
        control.inners[#control.inners + 1] = container
        local ok, made = as_maker("grid make", options.make, container)
        if ok then cell.made = made end
        return cell
    end

    local function step()
        if not measured then measure() end
        -- how much is in view: its own height, or what the engine reports once the page has been laid out
        local view = fixed_view
        if fills then view = math.min(math.max(total - scroller:GetScrollOffsetOfEnd(), pitch), host.height or 600) end
        local rows = math.ceil(view / pitch) + 2
        if rows ~= pool_rows then
            pool_rows, bound = rows, {}
            for index, cell in pairs(cells) do
                if index > rows * columns and cell.shown then
                    cell.box:SetVisibility(V.Collapsed)
                    cell.shown = false
                end
            end
        end
        local first = math.max(0, math.floor(scroller:GetViewOffsetFraction() * total / pitch) - 1)
        -- after the list got shorter the engine may still report the old place, which is past the end
        first = math.max(0, math.min(first, math.ceil(#items / columns) - pool_rows + 2))
        local made_now = 0
        for row = first, first + pool_rows - 1 do
            local place_in_pool = row % pool_rows
            if bound[place_in_pool] ~= row then
                local complete = true
                for column = 0, columns - 1 do
                    local index = place_in_pool * columns + column + 1
                    if not cells[index] then
                        if made_now >= MAKE_PER_FRAME then
                            complete = false
                            break
                        end
                        made_now = made_now + 1
                    end
                    local cell = cell_at(index)
                    local item_index = row * columns + column + 1
                    local item = items[item_index]
                    if item == nil then
                        if cell.shown then
                            cell.box:SetVisibility(V.Collapsed)
                            cell.shown = false
                        end
                    else
                        cell.slot:SetPosition({ X = column * (cell_w + gap), Y = row * pitch })
                        if not cell.shown then
                            cell.box:SetVisibility(V.Visible)
                            cell.shown = true
                        end
                        if cell.made ~= nil then as_maker("grid show", options.show, cell.made, item, item_index) end
                    end
                end
                if complete then bound[place_in_pool] = row end
            end
        end
    end

    host.resizers = host.resizers or {}
    host.resizers[#host.resizers + 1] = style.claim({ apply = function() measured = false end })
    grids[#grids + 1] = { control = control, host = host, page = page, step = step }
    -- Any list, of any length. The grid goes back to the top.
    function control:SetItems(list)
        items = list or {}
        measured = false
        scroller:ScrollToStart()
    end
    -- Shows every cell again (after the items themselves changed).
    function control:Refresh() bound = {} end
    function control:Count() return #items end
    control.step = step
    return control
end

-- Closes the one dropdown list that is open. Any action elsewhere calls this.
local function close_list()
    local parts = open_list
    open_list = nil
    if parts and parts.open and not parts.owner.destroyed then
        set_expanded(parts, false)
        return true
    end
    return false
end

-- Closes whatever is open on top of a window: a dropdown's list or a colour wheel. True when something was.
function controls.close_list()
    local closed_list, closed_wheel = close_list(), picker.close()
    return closed_list or closed_wheel
end

events.seen = function(delegate, address)
    picker.seen(delegate, address)
    local parts = open_list
    if not parts or delegate == "OnHovered" or delegate == "OnUnhovered" or delegate == "OnUserScrolled" then return end
    local own = parts.owner.addresses
    if not (own and own[address]) then close_list() end
end

-- Once per frame while the menu shows: grids follow their scrolling, and a click the game saw closes an open list.
function controls.step()
    for index = #grids, 1, -1 do
        local grid = grids[index]
        local host = grid.host
        if grid.control.destroyed then
            table.remove(grids, index)
        elseif host.shown ~= false and not host.minimized and (not host.nav or host.page == grid.page) then
            guard.call("grid", grid.step)
        end
    end
    local parts = open_list
    if parts and parts.open and not parts.owner.destroyed then
        local ok, pressed = pcall(input.just_pressed, "LeftMouseButton")
        if ok and pressed and not parts.column:IsHovered() then close_list() end
    end
    picker.step()
end

picker.install(Container, { place = place, new_control = new_control, listen = listen, caption_row = caption_row,
    caption_above = caption_above, wrap_width = controls.wrap_width, set_expanded = set_expanded, holder_for = holder_for,
    scroller_of = scroller_of })

-- Every builder above runs as the build of one control, so what it paints is owned by that control.
for name, make in pairs(Container) do
    if type(make) == "function" and name:find("^%u") then
        Container[name] = function(self, ...)
            local control = blank_control()
            local made = style.build(control, make, self, ...)
            if not control.widget then control.destroyed = true end
            return made
        end
    end
end

return controls
