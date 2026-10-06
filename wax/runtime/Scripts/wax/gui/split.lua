-- The split: two areas side by side with a divider to drag, or one at a time when there is no room for both

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")

local split = {}

local V, H, VA = style.Visibility, style.HAlign, style.VAlign
local DIVIDER, RIGHT_PAD = 7, 8
local dragging = {}     -- the splits whose divider is held

-- Adds Container:Split. `tools` are the helpers every control in controls.lua is built with.
function split.install(Container, tools)
    local place, new_control, listen = tools.place, tools.new_control, tools.listen

    -- Two areas side by side. Returns the control: .Left and .Right are containers.
    -- options: { share = 0.42 (of the width, for the left one), least = 240 (the narrowest an area may be), height = 300 }
    function Container:Split(options)
        options = options or {}
        local theme, host, parent = style.theme, self.window, self
        local least = options.least or 240
        local fills = self.bounded and not options.height
        local state = { share = options.share or 0.42, shown = "left", single = nil }

        local row = root.new("HorizontalBox")
        local function area(pad)
            local box = root.new("VerticalBox")
            local padded = kit.box(theme.clear, nil, style.margin(pad, 0, kit.GUTTER, 0))
            padded:SetClipping(style.Clip.ClipToBounds)
            padded:SetContent(box)
            local container = tools.container(host, box, { inset = parent.inset, parent = parent })
            container.bounded = true
            return container, kit.sized(padded), padded
        end
        local left, left_sizer = area(0)
        local right, right_sizer, right_padded = area(RIGHT_PAD)
        kit.slot(row:AddChild(left_sizer), { v = VA.Fill })
        local handle = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear,
            padding = style.margin(0), cursor = style.Cursor.ResizeLeftRight })
        local rule = kit.image(theme.line, nil, 1, 1)
        rule:SetVisibility(V.HitTestInvisible)
        local rule_box = kit.sized(rule, 1)
        kit.slot(handle:SetContent(rule_box), { h = H.Center, v = VA.Fill })
        local handle_box = kit.sized(handle, DIVIDER)
        kit.slot(row:AddChild(handle_box), { v = VA.Fill })
        kit.slot(row:AddChild(right_sizer), { v = VA.Fill, h = H.Fill, fill = 1 })
        local outer = row
        if fills then
            -- the right area's scroll bars go where the page keeps room for one
            place(self, row, { fill = true, pad = style.margin(0, 0, -kit.GUTTER, 0) })
        else
            outer = kit.sized(row, nil, options.height or 300)
            place(self, outer)
        end

        local control = new_control(self, outer)
        control.source, control.pointer = handle, false
        control.Left, control.Right = left, right
        control.inners = { left, right }

        -- the width of each area, and whether only one can show
        local function widths()
            local total = tools.wrap_width(parent) + (fills and kit.GUTTER or 0)
            if total < least * 2 + DIVIDER then return total, total, true end
            local room = total - DIVIDER
            local first = math.max(least, math.min(room - least, room * state.share))
            return first, room - first, false
        end
        left.fixed_width = function() return (widths()) - kit.GUTTER end
        right.fixed_width = function()
            local _, second, single = widths()
            return second - kit.GUTTER - (single and 0 or RIGHT_PAD)
        end

        local put = {}
        local function apply()
            local first, _, single = widths()
            local flipped = single ~= state.single
            state.single = single
            local see_left, see_right = not single or state.shown == "left", not single or state.shown == "right"
            if put.left ~= see_left then
                put.left = see_left
                left_sizer:SetVisibility(see_left and V.Visible or V.Collapsed)
            end
            if put.right ~= see_right then
                put.right = see_right
                right_sizer:SetVisibility(see_right and V.Visible or V.Collapsed)
            end
            if put.single ~= single then
                put.single = single
                handle_box:SetVisibility(single and V.Collapsed or V.Visible)
                right_padded:SetPadding(style.margin(single and 0 or RIGHT_PAD, 0, kit.GUTTER, 0))
            end
            if put.width ~= first then
                put.width = first
                left_sizer:SetWidthOverride(first)
            end
            return flipped
        end

        local function light(on)
            local held = state.drag ~= nil
            style.tint(rule, "image", held and theme.accent_hover or (on and theme.accent or theme.line))
            rule_box:SetWidthOverride((on or held) and 2 or 1)
        end

        -- Changed fires with true when only one area fits and false when both do
        host.resizers = host.resizers or {}
        host.resizers[#host.resizers + 1] = style.claim({ apply = function()
            if apply() then control.Changed:Fire(state.single) end
        end })

        -- True while there is only room for one area.
        function control:IsSingle() return state.single end
        -- Which area shows while there is only room for one: "left" or "right".
        function control:Show(which)
            if which ~= "left" and which ~= "right" then error("Show expects \"left\" or \"right\"", 2) end
            if state.shown == which then return end
            state.shown = which
            apply()
        end
        function control:Shown() return state.shown end
        -- The left area's share of the width, 0 to 1.
        function control:SetShare(share)
            if type(share) ~= "number" then error("SetShare expects a number from 0 to 1", 2) end
            state.share = math.max(0.05, math.min(0.95, share))
            tools.rewrap(host)
        end
        function control:GetShare() return state.share end

        listen(control, handle, "OnPressed", function()
            local mouse_x = root.mouse()
            state.drag = { mouse_x = mouse_x, width = (widths()) }
            dragging[control] = { state = state, handle = handle, widths = widths, host = host, light = light, rewrap = tools.rewrap }
            light(true)
        end)
        listen(control, handle, "OnHovered", function()
            state.hover = true
            light(true)
        end)
        listen(control, handle, "OnUnhovered", function()
            state.hover = false
            if not state.drag then light(false) end
        end)
        apply()
        return control
    end
end

-- Once per frame while the menu shows: a held divider follows the mouse.
function split.step()
    for control, held in pairs(dragging) do
        local state = held.state
        if control.destroyed then
            dragging[control] = nil
        elseif not held.handle:IsPressed() then
            dragging[control], state.drag = nil, nil
            held.light(state.hover)
        else
            local mouse_x = root.mouse()
            local first, second = held.widths()
            local wanted = state.drag.width + (mouse_x - state.drag.mouse_x) / style.scale
            local share = math.max(0.05, math.min(0.95, wanted / (first + second)))
            if share ~= state.share then
                state.share = share
                held.rewrap(held.host)
            end
        end
    end
end

return split
