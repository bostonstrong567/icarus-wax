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

-- Adds Container:Item. `tools` are the helpers every control in controls.lua is built with.
function item.install(Container, tools)
    local place, new_control, listen = tools.place, tools.new_control, tools.listen

    -- One line of a list or a tree. options: { text, note, value, icon, indent, arrow, selected, tone, faint, weight }
    -- arrow is true (open), false (closed) or left out for none. on_click() runs for the line, on_arrow() for its arrow.
    -- columns = true makes it a line of a table: the name is name_width wide, the value starts where the name ends and
    -- the note sits at the right edge. divider = true draws a thin line under it.
    function Container:Item(options, on_click, on_arrow)
        options = options or {}
        local theme = style.theme
        local line = root.new("Overlay")
        local chosen = kit.box(style.with_alpha(theme.accent, 0.18), "round4")
        chosen:SetVisibility(V.Hidden)
        kit.slot(line:AddChild(chosen), { h = H.Fill, v = VA.Fill })
        local row = root.new("HorizontalBox")
        kit.slot(line:AddChild(row), { h = H.Fill, v = VA.Fill })
        local gap = kit.sized(nil, 0)
        kit.slot(row:AddChild(gap), { v = VA.Fill })
        local arrow_icon = kit.icon("chevron-right", 12, theme.dim)
        local arrow_box, arrow = kit.icon_button(nil, { content = arrow_icon, width = ARROW, height = ARROW })
        arrow_box:SetVisibility(V.Hidden)
        kit.slot(row:AddChild(arrow_box), { v = VA.Center })
        local button = kit.button(nil, { shape = "round4", color = theme.clear, hover = style.with_alpha(theme.text, 0.07),
            press = style.with_alpha(theme.text, 0.12), padding = style.margin(4, 0, 6, 0) })
        local content = root.new("HorizontalBox")
        local picture = kit.icon("circle", ICON, theme.dim)
        picture:SetVisibility(V.Collapsed)
        kit.slot(content:AddChild(picture), { v = VA.Center, pad = style.margin(0, 0, 6, 0) })
        local name = kit.label("")
        local name_box = options.columns and kit.sized(name) or nil
        kit.slot(content:AddChild(name_box or name), { v = VA.Center })
        local note = kit.label("", { color = theme.dim, size = theme.small_size })
        local value = kit.label("", { family = "mono", size = theme.small_size })
        if options.columns then
            kit.slot(content:AddChild(value), { v = VA.Center, pad = style.margin(10, 0, 0, 0), fill = 1 })
            kit.slot(content:AddChild(note), { v = VA.Center, pad = style.margin(8, 1, 0, 0) })
        else
            kit.slot(content:AddChild(note), { v = VA.Center, pad = style.margin(8, 1, 0, 0), fill = 1 })
            kit.slot(content:AddChild(value), { v = VA.Center, pad = style.margin(8, 0, 0, 0) })
        end
        kit.fill_content(button, content)
        kit.slot(row:AddChild(button), { v = VA.Fill, fill = 1 })
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

        -- Describes the whole line: what is left out goes back to nothing. Only what changed reaches the engine.
        function control:Set(fields)
            fields = fields or {}
            local text, remark, shown = tostring(fields.text or ""), tostring(fields.note or ""), tostring(fields.value or "")
            if text ~= now.text then
                now.text = text
                name:SetText(kit.text(text))
            end
            if remark ~= now.note then
                now.note = remark
                note:SetText(kit.text(remark))
            end
            if shown ~= now.value then
                now.value = shown
                value:SetText(kit.text(shown))
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
        control:Set(options)
        return control
    end
end

return item
