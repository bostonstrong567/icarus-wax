-- The list line: one row of a list or a tree, with an arrow, an icon, a name, a note and a value

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")
local sched = Wax.import("core.sched")

local item = {}

local V, H, VA = style.Visibility, style.HAlign, style.VAlign
local INDENT, ARROW, ICON = 12, 16, 14
local TONES = { text = true, dim = true, accent = true, accent_hover = true, good = true, warn = true, bad = true }
local FIT = 0.90        -- text draws a few percent wider than its letters add up to, more at a fractional screen scale
local TIP_LINE = 56     -- letters in one line of the tip that shows a cut line whole
local VALUE_LEAST = 96  -- in a table a value is not cut below this (twelve letters) while its type could give way instead

-- The name, note and value of a line that is `width` wide, each cut short with "..." where it has to be, and whether any was.
local function fitted(width, columns, text, remark, shown, indent, icon, name_width)
    local theme = style.theme
    local size, small = theme.font_size, theme.small_size
    local room = width - indent * INDENT - ARROW - 10 - (icon and ICON + 6 or 0)
    local name, note, value, cut_name, cut_other = text, remark, shown, false, false
    if columns then
        name, cut_name = kit.shorten(text, (name_width or room) * FIT, size)
        local left = (room - (name_width or kit.text_width(name, size)) - 18) * FIT
        local wanted, type_width = kit.text_width(shown, small, "mono"), kit.text_width(remark, small)
        if wanted + type_width > left then
            -- the value comes first: a type that leaves it too little room is cut instead, or left to the tip
            if left - type_width < math.min(wanted, VALUE_LEAST) then
                note = kit.shorten(remark, left - math.min(wanted, VALUE_LEAST), small)
                if #note < 7 then note = "" end
                type_width = kit.text_width(note, small)
            end
            value = kit.shorten(shown, left - type_width, small, "mono")
            cut_other = true
        end
    else
        local left = room - 16 - kit.text_width(shown, small, "mono")
        name, cut_name = kit.shorten(text, left * FIT, size)
        -- a name that had to be cut leaves no room for a note
        if cut_name then
            note, cut_other = "", remark ~= ""
        elseif remark ~= "" then
            note, cut_other = kit.shorten(remark, (left - kit.text_width(name, size)) * FIT, small)
            -- a note cut down to a letter or two says nothing: the tip has it whole
            if cut_other and #note < 8 then note = "" end
        end
    end
    return name, note, value, cut_name or cut_other
end

-- The whole of a line that was cut, for its tip.
local function whole(text, remark, shown)
    local lines = {}
    if remark ~= "" then lines[1] = remark end
    for at = 1, math.min(#shown, TIP_LINE * 4), TIP_LINE do lines[#lines + 1] = { shown:sub(at, at + TIP_LINE - 1), "text" } end
    return { title = text, lines = lines }
end

-- Adds Container:Item. `tools` are the helpers every control in controls.lua is built with.
function item.install(Container, tools)
    local place, new_control, listen = tools.place, tools.new_control, tools.listen

    -- One line of a list or a tree. options: { text, note, value, icon, indent, arrow, selected, tone, faint, weight }
    -- arrow is true (open), false (closed) or left out for none. on_click() runs for the line, on_arrow() for its arrow.
    -- columns = true makes it a line of a table: the name is name_width wide, the value starts where the name ends and
    -- the note sits at the right edge. divider = true draws a thin line under it.
    -- fit = true cuts what is too long short with "..." and shows it whole as a tip. `width` is for a line narrower than its container.
    function Container:Item(options, on_click, on_arrow)
        options = options or {}
        local theme = style.theme
        local line = root.new("Overlay")
        local chosen = kit.box(style.with_alpha(theme.accent, 0.18), "round4")
        chosen:SetVisibility(V.Hidden)
        kit.slot(line:AddChild(chosen), { h = H.Fill, v = VA.Fill })
        -- the line is one button from edge to edge, so it has one shape under the mouse. Its arrow sits inside and draws no shape.
        local button = kit.button(nil, { shape = "round4", color = theme.clear, hover = style.with_alpha(theme.text, 0.07),
            press = style.with_alpha(theme.text, 0.12), padding = style.margin(0, 0, 6, 0) })
        local content = root.new("HorizontalBox")
        local gap = kit.sized(nil, 0)
        kit.slot(content:AddChild(gap), { v = VA.Fill })
        local arrow_icon = kit.icon("chevron-right", 12, theme.dim)
        local arrow_box, arrow = kit.icon_button(nil, { content = arrow_icon, width = ARROW, height = ARROW, hover = theme.clear,
            press = theme.clear })
        arrow_box:SetVisibility(V.Hidden)
        kit.slot(content:AddChild(arrow_box), { v = VA.Center, pad = style.margin(0, 0, 4, 0) })
        local picture = kit.icon("circle", ICON, theme.dim)
        picture:SetVisibility(V.Collapsed)
        kit.slot(content:AddChild(picture), { v = VA.Center, pad = style.margin(0, 0, 6, 0) })
        local name = kit.label("", { free = true })
        local name_box = options.columns and kit.sized(name) or nil
        kit.slot(content:AddChild(name_box or name), { v = VA.Center })
        local note = kit.label("", { color = theme.dim, size = theme.small_size, free = true })
        local value = kit.label("", { family = "mono", size = theme.small_size, free = true })
        if options.columns then
            kit.slot(content:AddChild(value), { v = VA.Center, pad = style.margin(10, 0, 0, 0), fill = 1 })
            kit.slot(content:AddChild(note), { v = VA.Center, pad = style.margin(8, 1, 0, 0) })
        else
            kit.slot(content:AddChild(note), { v = VA.Center, pad = style.margin(8, 1, 0, 0), fill = 1 })
            kit.slot(content:AddChild(value), { v = VA.Center, pad = style.margin(8, 0, 0, 0) })
        end
        kit.fill_content(button, content)
        kit.slot(line:AddChild(button), { h = H.Fill, v = VA.Fill })
        if options.divider then
            local rule = kit.image(theme.line, nil, 1, 1)
            rule:SetVisibility(V.HitTestInvisible)
            kit.slot(line:AddChild(rule), { h = H.Fill, v = VA.Bottom })
        end
        place(self, line, { weight = options.weight, v = VA.Fill })

        local control = new_control(self, line)
        control.source, control.arrow = button, arrow
        control.Activated = control.Changed
        control.Toggled = sched.Signal.new("Toggled")
        local now = { text = "", note = "", value = "", icon = false, indent = 0, arrow = nil, selected = false, tone = "text",
            faint = false, name_width = false }
        local drawn = { text = "", note = "", value = "" }      -- what the three texts show, which is less when they were cut
        local fits, container, last = options.fit == true, self, nil
        local set_tip = fits and tools.hover_tip(control, button) or nil
        local fit = {}      -- what the texts were last cut from, and what came of it
        control.drawn = drawn

        -- Describes the whole line: what is left out goes back to nothing. Only what changed reaches the engine.
        function control:Set(fields)
            fields = fields or {}
            local text, remark, shown = tostring(fields.text or ""), tostring(fields.note or ""), tostring(fields.value or "")
            now.text, now.note, now.value, last = text, remark, shown, fields
            if fits then
                local width, indent = fields.width or tools.wrap_width(container), fields.indent or 0
                local pictured, column = fields.icon and true or false, name_box and fields.name_width or false
                -- a line that is told the same again is not worked out again
                if text ~= fit.text or remark ~= fit.note or shown ~= fit.value or width ~= fit.width or indent ~= fit.indent
                    or pictured ~= fit.pictured or column ~= fit.column then
                    fit.text, fit.note, fit.value, fit.width, fit.indent, fit.pictured, fit.column = text, remark, shown, width, indent,
                        pictured, column
                    local cut
                    fit.name_cut, fit.note_cut, fit.value_cut, cut = fitted(width, options.columns, text, remark, shown, indent, pictured,
                        column or nil)
                    set_tip(cut and whole(text, remark, shown) or nil)
                end
                text, remark, shown = fit.name_cut, fit.note_cut, fit.value_cut
            end
            if text ~= drawn.text then
                drawn.text = text
                kit.set_text(name, text)
            end
            if remark ~= drawn.note then
                drawn.note = remark
                kit.set_text(note, remark)
            end
            if shown ~= drawn.value then
                drawn.value = shown
                kit.set_text(value, shown)
            end
            local icon = fields.icon or false
            if icon ~= now.icon then
                if icon then kit.set_icon(picture, icon, ICON) end
                if (icon and true) ~= (now.icon and true) then picture:SetVisibility(icon and V.HitTestInvisible or V.Collapsed) end
                now.icon = icon
            end
            local indent = fields.indent or 0
            if indent ~= now.indent then
                now.indent = indent
                gap:SetWidthOverride(indent * INDENT)
            end
            local width = name_box and fields.name_width or false
            if width and width ~= now.name_width then
                now.name_width = width
                name_box:SetWidthOverride(width)
            end
            local open = fields.arrow
            if open ~= now.arrow then
                if (open ~= nil) ~= (now.arrow ~= nil) then arrow_box:SetVisibility(open ~= nil and V.Visible or V.Hidden) end
                arrow_icon:SetRenderTransformAngle(open and 90 or 0)
                now.arrow = open
            end
            local tone = fields.tone or "text"
            if tone ~= now.tone then
                if not TONES[tone] then error("a tone is \"text\", \"dim\", \"accent\", \"good\", \"warn\" or \"bad\"", 2) end
                now.tone = tone
                style.tint(value, "text", style.theme[tone])
            end
            local faint = fields.faint and true or false
            if faint ~= now.faint then
                now.faint = faint
                style.tint(name, "text", faint and style.theme.dim or style.theme.text)
            end
            self:SetSelected(fields.selected)
        end

        function control:SetSelected(selected)
            selected = selected and true or false
            if selected == now.selected then return end
            now.selected = selected
            chosen:SetVisibility(selected and V.HitTestInvisible or V.Hidden)
        end

        -- What the line is showing, as a table like the one Set takes.
        function control:Get()
            local out = {}
            for key, shown in pairs(now) do out[key] = shown end
            return out
        end

        listen(control, button, "OnClicked", function()
            if on_click then sched.task.spawn(on_click) end
            control.Changed:Fire()
        end)
        listen(control, arrow, "OnClicked", function()
            if on_arrow then sched.task.spawn(on_arrow) end
            control.Toggled:Fire()
        end)
        if on_arrow then
            -- the arrow answers the mouse by getting brighter
            listen(control, arrow, "OnHovered", function() style.tint(arrow_icon, "image", style.theme.text) end)
            listen(control, arrow, "OnUnhovered", function() style.tint(arrow_icon, "image", style.theme.dim) end)
        end
        control:Set(options)
        -- a line that cuts its text to fit does so again when it gets another width
        if fits then tools.fit_later(self, function() control:Set(last) end) end
        return control
    end
end

return item
