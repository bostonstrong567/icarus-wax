-- Slots: a block of square cells that each show a picture, a count and a mark, the way an inventory does

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")
local pictures = Wax.import("gui.pictures")
local input = Wax.import("gui.input")
local sched = Wax.import("core.sched")
local guard = Wax.import("core.guard")
local scope = Wax.import("core.scope")
local tween = Wax.import("gui.tween")

local slots = {}

slots.MAKE_SECONDS = 0.0015     -- cells are made for this long a frame until every block has all of its cells

local V, H, VA = style.Visibility, style.HAlign, style.VAlign
local blocks = {}               -- every live block
local over = nil                -- { block, index } under the mouse
local held = nil                -- the cell whose button went down, until it comes up
local press = nil               -- where the mouse was when it went down: { x, y }
local drag = nil                -- a cell being dragged: { block, index, x, y, dx, dy }
local ghost = nil               -- the picture that follows the mouse during a drag

slots.DRAG_AFTER = 6            -- how far the mouse moves with the button down before it is a drag
local on_hover = nil            -- called with (look, block) when what is under the mouse changes
local last = nil                -- the cell the mouse was over a moment ago, and when: { block, index, at }
local seen = { right = 0, fired = 0, late = 0, lost = 0, gaps = {} }

slots.GRACE = 0.25              -- seconds a cell still counts as under the mouse after the game took the mouse from it

local function now() return (Wax.perf and Wax.perf.now or os.clock)() end

-- Adds Container:Slots. `tools` are the helpers every control in controls.lua is built with.
function slots.install(Container, tools)
    local place, new_control = tools.place, tools.new_control

    -- options: { columns = 9, rows = 1, size = 36, gap = 2, backing = true, align = "left", below (space under it),
    -- drag (cells can be dragged: see DragStarted) }.
    -- Shows a list of looks, one per cell:
    -- { image = "/Game/...", icon = "name", count = "12", mark = "star", value = anything, tip = text, table or function,
    --   dim = bool, selected = bool, plain = bool (a picture only: no box, and the mouse passes over it),
    --   tone = "good" | "warn" | "bad" | "accent" (a short line of that colour under the picture) }.
    -- A cell with no look is empty.
    function Container:Slots(options)
        options = options or {}
        local theme = style.theme
        local columns, rows = math.max(1, options.columns or 9), math.max(1, options.rows or 1)
        local size, gap = options.size or 36, options.gap or 2
        local column = root.new("VerticalBox")
        local lines = {}
        for row = 1, rows do
            local line = root.new("HorizontalBox")
            kit.slot(column:AddChild(line), { pad = style.margin(0, row > 1 and gap or 0, 0, 0) })
            lines[row] = line
        end
        local holder = kit.sized(column, columns * size + (columns - 1) * gap, rows * size + (rows - 1) * gap)
        local sides = { left = H.Left, center = H.Center, right = H.Right }
        place(self, holder, { h = sides[options.align] or H.Left, snug = true,
            pad = options.below and style.margin(0, 0, 0, options.below) or nil })

        local control = new_control(self, holder)
        local cells, looks = {}, {}
        local block = { control = control, cells = cells, looks = looks, count = columns * rows, host = self.window,
            drag = options.drag and true or false, size = size }
        control.Activated = control.Changed
        control.RightClicked = sched.Signal.new("RightClicked")
        control.MiddleClicked = sched.Signal.new("MiddleClicked")
        control.Hovered = sched.Signal.new("Hovered")
        -- with drag = true: (value, index, look) when a cell starts to be dragged, (dx, dy) as it moves and when it is let go
        control.DragStarted = sched.Signal.new("DragStarted")
        control.DragMoved = sched.Signal.new("DragMoved")
        control.DragEnded = sched.Signal.new("DragEnded")
        block.maker = scope.current()

        local function show(cell, look)
            if not look then
                if cell.shown then
                    cell.button:SetVisibility(V.Hidden)
                    if cell.back then cell.back:SetVisibility(V.Collapsed) end
                    cell.shown = false
                end
                return
            end
            local plain = look.plain and true or false
            if not cell.shown or plain ~= cell.plain then
                cell.button:SetVisibility(plain and V.HitTestInvisible or V.Visible)
                if cell.back then cell.back:SetVisibility(plain and V.Collapsed or V.HitTestInvisible) end
                cell.shown, cell.plain = true, plain
            end
            -- only what changed reaches the engine
            local image, icon = look.image or false, look.icon or false
            if image ~= cell.image then
                cell.image = image
                if image then pictures.show(cell.picture, image, control) else pictures.clear(cell.picture) end
            end
            if icon ~= cell.icon then
                if icon and not cell.glyph then
                    cell.glyph = style.extend(control, kit.icon, icon, math.floor(size * 0.5), theme.dim)
                    kit.slot(cell.layers:AddChild(cell.glyph), { h = H.Center, v = VA.Center })
                elseif icon then
                    kit.set_icon(cell.glyph, icon, math.floor(size * 0.5))
                end
                if cell.glyph then cell.glyph:SetVisibility(icon and V.HitTestInvisible or V.Collapsed) end
                cell.icon = icon
            end
            local count = look.count and tostring(look.count) or false
            if count ~= cell.count then
                if count and not cell.count_text then
                    cell.count_text = style.extend(control, kit.label, count, { size = theme.small_size, family = "mono" })
                    cell.count_box = style.extend(control, kit.box, style.with_alpha(theme.window, 0.8), "round4", style.margin(3, 0))
                    cell.count_box:SetContent(cell.count_text)
                    kit.slot(cell.layers:AddChild(cell.count_box), { h = H.Right, v = VA.Bottom, pad = style.margin(0, 0, 1, 1) })
                elseif count then
                    cell.count_text:SetText(kit.text(count))
                end
                if cell.count_box then cell.count_box:SetVisibility(count and V.HitTestInvisible or V.Collapsed) end
                cell.count = count
            end
            local mark = look.mark or false
            if mark ~= cell.mark then
                if mark and not cell.mark_icon then
                    cell.mark_icon = style.extend(control, kit.icon, mark, 10, theme.accent)
                    kit.slot(cell.layers:AddChild(cell.mark_icon), { h = H.Left, v = VA.Top, pad = style.margin(2, 2, 0, 0) })
                elseif mark then
                    kit.set_icon(cell.mark_icon, mark, 10)
                end
                if cell.mark_icon then cell.mark_icon:SetVisibility(mark and V.HitTestInvisible or V.Collapsed) end
                cell.mark = mark
            end
            local selected = look.selected and true or false
            if selected ~= cell.selected then
                -- the chosen cell is lighter and has a short line of the accent colour under its picture
                if selected and not cell.wash then
                    cell.wash = style.extend(control, kit.image, style.with_alpha(theme.text, 0.13), "round6", 1, 1)
                    kit.slot(cell.layers:AddChild(cell.wash), { h = H.Fill, v = VA.Fill })
                    cell.line = style.extend(control, kit.image, theme.accent, nil, math.floor(size * 0.46), 2)
                    kit.slot(cell.layers:AddChild(cell.line), { h = H.Center, v = VA.Bottom, pad = style.margin(0, 0, 0, 2) })
                end
                if cell.wash then
                    cell.wash:SetVisibility(selected and V.HitTestInvisible or V.Collapsed)
                    cell.line:SetVisibility(selected and V.HitTestInvisible or V.Collapsed)
                end
                cell.selected = selected
            end
            local tone = look.tone or false
            if tone ~= cell.tone then
                if tone and not cell.tone_line then
                    cell.tone_line = style.extend(control, kit.image, theme[tone] or theme.accent, nil, math.floor(size * 0.46), 2)
                    kit.slot(cell.layers:AddChild(cell.tone_line), { h = H.Center, v = VA.Bottom, pad = style.margin(0, 0, 0, 2) })
                elseif tone then
                    style.tint(cell.tone_line, "image", theme[tone] or theme.accent)
                end
                if cell.tone_line then cell.tone_line:SetVisibility(tone and V.HitTestInvisible or V.Collapsed) end
                cell.tone = tone
            end
            local dim = look.dim and true or false
            if dim ~= cell.dim then
                cell.dim = dim
                cell.picture:SetRenderOpacity(dim and 0.35 or 1)
            end
        end

        local function make(index)
            local button = kit.button(nil, { shape = "round6", color = theme.clear, hover = theme.hover, press = theme.press,
                padding = style.margin(0) })
            -- the box of a cell is its own picture under the button, so one cell can be shown without it
            local stack, back = root.new("Overlay"), nil
            if options.backing ~= false then
                back = kit.image(theme.raised, "round6", 1, 1)
                back:SetVisibility(V.HitTestInvisible)
                kit.slot(stack:AddChild(back), { h = H.Fill, v = VA.Fill })
            end
            kit.slot(stack:AddChild(button), { h = H.Fill, v = VA.Fill })
            local layers = root.new("Overlay")
            local inset = math.max(2, math.floor(size * 0.08))
            local picture = kit.image(style.WHITE, nil, size - inset * 2, size - inset * 2)
            picture:SetVisibility(V.Hidden)
            kit.slot(layers:AddChild(picture), { h = H.Fill, v = VA.Fill, pad = style.margin(inset) })
            local content = button:SetContent(layers)
            content:SetHorizontalAlignment(H.Fill)
            content:SetVerticalAlignment(VA.Fill)
            local row = math.floor((index - 1) / columns) + 1
            local cell_box = kit.sized(stack, size, size)
            kit.slot(lines[row]:AddChild(cell_box), { pad = style.margin((index - 1) % columns > 0 and gap or 0, 0, 0, 0) })
            local cell = { button = button, layers = layers, picture = picture, back = back, stack = stack, shown = true, plain = false,
                image = false,
                icon = false, count = false, mark = false, selected = false, dim = false, tone = false }
            cells[index] = cell
            show(cell, looks[index])
        end
        block.make = function(index) style.extend(control, make, index) end

        -- Shows these looks, the first in the first cell. Cells past the end of the list are empty.
        function control:Set(list)
            list = list or {}
            for index = 1, block.count do
                looks[index] = list[index]
                local cell = cells[index]
                if cell then show(cell, looks[index]) end
            end
            if over and over.block == block then over.changed = true end
        end
        -- Changes one cell.
        function control:SetLook(index, look)
            if index < 1 or index > block.count then return end
            looks[index] = look
            if cells[index] then show(cells[index], look) end
            if over and over.block == block and over.index == index then over.changed = true end
        end
        function control:GetLook(index) return looks[index] end
        function control:Capacity() return block.count end
        -- True once every cell exists. Until then the cells made so far show.
        function control:Ready() return #cells >= block.count end
        -- A cell is drawn dx, dy away from its place and slides home: what it shows seems to have come from there.
        function control:Slide(index, dx, dy, seconds)
            local cell = cells[index]
            if not cell then return end
            if cell.sliding then cell.sliding.cancel() end
            local home = { X = 0, Y = 0 }
            cell.sliding = tween.run(seconds or 0.14, function(progress)
                cell.stack:SetRenderTranslation({ X = dx * (1 - progress), Y = dy * (1 - progress) })
            end, function()
                cell.sliding = nil
                cell.stack:SetRenderTranslation(home)
            end, "out", control)
        end

        blocks[#blocks + 1] = block
        if options.looks then control:Set(options.looks) end
        return control
    end
end

local function showing(block)
    local host = block.host
    if block.control.destroyed or host.destroyed then return false end
    if host.visible_now ~= nil then return host.visible_now end
    return host.shown ~= false and not host.minimized
end

-- Fires a signal of a block with these values, as the code of whoever made the block.
local function emit(block, signal, ...)
    local values = table.pack(...)
    local previous = scope.enter(block.maker)
    guard.call("slot", function() signal:Fire(table.unpack(values, 1, values.n)) end)
    scope.leave(previous)
end

-- The picture of the cell being dragged, drawn under the mouse over everything else.
local function ghost_show(block, look, x, y)
    if not ghost then
        local made = { destroyed = false }
        style.build(made, function()
            made.layers = root.new("Overlay")
            made.picture = kit.image(style.WHITE, nil, 1, 1)
            kit.slot(made.layers:AddChild(made.picture), { h = H.Fill, v = VA.Fill })
            made.glyph = kit.icon("package", 20, style.theme.text)
            kit.slot(made.layers:AddChild(made.glyph), { h = H.Center, v = VA.Center })
            made.box = kit.sized(made.layers, 36, 36)
            made.outer = kit.scaled(made.box)
            made.outer:SetVisibility(V.Collapsed)
            made.slot = root.layer("toasts"):AddChild(made.outer)
            made.slot:SetAutoSize(true)
            made.slot:SetZOrder(1001)
            made.slot:SetAlignment({ X = 0.5, Y = 0.5 })
        end)
        ghost = made
    end
    local size = block.size or 36
    ghost.box:SetWidthOverride(size)
    ghost.box:SetHeightOverride(size)
    ghost.outer:SetUserSpecifiedScale(style.scale * (block.host.zoom or 1))
    if look.image then
        pictures.show(ghost.picture, look.image, ghost)
        ghost.glyph:SetVisibility(V.Collapsed)
    else
        pictures.clear(ghost.picture)
        kit.set_icon(ghost.glyph, look.icon or "package", math.floor(size * 0.5))
        ghost.glyph:SetVisibility(V.HitTestInvisible)
    end
    ghost.slot:SetPosition({ X = x, Y = y })
    ghost.outer:SetRenderOpacity(0.9)
    ghost.outer:SetVisibility(V.HitTestInvisible)
end

local function ghost_hide()
    if ghost then ghost.outer:SetVisibility(V.Collapsed) end
end

local function fire(block, signal, index)
    local look = block.looks[index]
    if not look then return end
    local previous = scope.enter(block.maker)
    guard.call("slot", function() signal:Fire(look.value, index, look) end)
    scope.leave(previous)
end

-- Every frame: makes cells that do not exist yet, a few at a time, shown or not.
function slots.warm()
    local started = nil
    for at = #blocks, 1, -1 do
        local block = blocks[at]
        if block.control.destroyed or block.host.destroyed then
            table.remove(blocks, at)
        elseif #block.cells < block.count then
            started = started or now()
            repeat
                local ok = guard.call("slot make", block.make, #block.cells + 1)
                if not ok then
                    block.count = #block.cells
                    break
                end
            until #block.cells >= block.count or now() - started > slots.MAKE_SECONDS
            if now() - started > slots.MAKE_SECONDS then return end
        end
    end
end

-- Every frame while something that takes the mouse is showing: which cell is under the mouse, and what was pressed on it.
function slots.step(active)
    if not active then
        if over then
            over = nil
            if on_hover then on_hover(nil, nil) end
        end
        held = nil
        return
    end
    if drag then
        local cell = showing(drag.block) and drag.block.cells[drag.index] or nil
        local x, y = root.mouse()
        local scale = style.scale * (drag.block.host.zoom or 1)
        local dx, dy = (x - drag.x) / scale, (y - drag.y) / scale
        if cell and cell.button:IsPressed() then
            ghost.slot:SetPosition({ X = x, Y = y })
            if dx ~= drag.dx or dy ~= drag.dy then
                drag.dx, drag.dy = dx, dy
                emit(drag.block, drag.block.control.DragMoved, dx, dy)
            end
        else
            local block = drag.block
            drag, held, press = nil, nil, nil
            ghost_hide()
            if not block.control.destroyed then emit(block, block.control.DragEnded, dx, dy) end
        end
        return
    end
    local found_block, found_index = nil, nil
    -- the cell that was under the mouse last frame is asked first: the mouse seldom moves far in a frame
    if over and showing(over.block) then
        local cell = over.block.cells[over.index]
        if cell and cell.shown and cell.button:IsHovered() then found_block, found_index = over.block, over.index end
    end
    if not found_block then
        for at = 1, #blocks do
            local block = blocks[at]
            if showing(block) and block.control.widget:IsHovered() then
                for index = 1, #block.cells do
                    local cell = block.cells[index]
                    if cell.shown and cell.button:IsHovered() then
                        found_block, found_index = block, index
                        break
                    end
                end
                if found_block then break end
            end
        end
    end
    -- The right and the middle button are read from the game, and count when they come up again: beside the game's own
    -- screens it is not told of the press itself, only of the release. The game also takes the mouse for itself while
    -- a button is down, so a cell may stop saying the mouse is over it: the cell it was over a moment ago gets the click.
    local ok, right = pcall(input.just_released, "RightMouseButton")
    local fine, middle = pcall(input.just_released, "MiddleMouseButton")
    right, middle = ok and right == true, fine and middle == true
    local told, pressed = pcall(input.just_pressed, "RightMouseButton")
    if told and pressed == true then seen.pressed = (seen.pressed or 0) + 1 end
    local time = now()
    if found_block then
        last = { block = found_block, index = found_index, at = time }
    elseif (right or middle) and last and time - last.at <= slots.GRACE and showing(last.block) and last.block.cells[last.index] then
        if right then
            seen.right, seen.late = seen.right + 1, seen.late + 1
            fire(last.block, last.block.control.RightClicked, last.index)
        end
        if middle then fire(last.block, last.block.control.MiddleClicked, last.index) end
        right, middle = false, false
    elseif right then
        seen.right, seen.lost = seen.right + 1, seen.lost + 1
    end
    if right then
        seen.gaps[#seen.gaps + 1] = math.floor((time - (seen.at or time)) * 1000)
        if #seen.gaps > 12 then table.remove(seen.gaps, 1) end
        seen.at = time
    end
    local moved = (over and over.block) ~= found_block or (over and over.index) ~= found_index
    if moved or (over and over.changed) then
        over = found_block and { block = found_block, index = found_index } or nil
        held = nil
        local look = over and over.block.looks[over.index] or nil
        if found_block then
            local value = look and look.value
            guard.call("slot hover", function() found_block.control.Hovered:Fire(value, found_index, look) end)
        end
        if on_hover then on_hover(look, found_block) end
    end
    if not over then return end
    local block, index = over.block, over.index
    local cell = block.cells[index]
    -- a click is the button going down and coming up again over the same cell
    local down = cell.button:IsPressed()
    if down then
        if held ~= cell then
            held = cell
            local x, y = root.mouse()
            press = { x = x, y = y }
        elseif block.drag and press and block.looks[index] then
            -- held and moved far enough: from here on it is a drag, and letting go is not a click
            local x, y = root.mouse()
            if math.abs(x - press.x) > slots.DRAG_AFTER or math.abs(y - press.y) > slots.DRAG_AFTER then
                local look = block.looks[index]
                drag = { block = block, index = index, x = press.x, y = press.y, dx = 0, dy = 0 }
                ghost_show(block, look, x, y)
                if on_hover then on_hover(nil, nil) end
                emit(block, block.control.DragStarted, look.value, index, look)
            end
        end
    elseif held == cell then
        held, press = nil, nil
        fire(block, block.control.Activated, index)
    end
    if right then
        seen.right, seen.fired = seen.right + 1, seen.fired + 1
        fire(block, block.control.RightClicked, index)
    end
    if middle then fire(block, block.control.MiddleClicked, index) end
end

-- The value of the slot under the mouse, then its look and its control. Nothing when no slot is under it.
function slots.hovered()
    if not over then return nil end
    local look = over.block.looks[over.index]
    if not look then return nil end
    return look.value, look, over.block.control
end

function slots.on_hover(fn) on_hover = fn end

-- The interface was rebuilt: nothing kept here may be touched again.
function slots.forget_all()
    blocks, over, held, last, press, drag = {}, nil, nil, nil, nil, nil
    if ghost then ghost.destroyed = true end
    ghost = nil
end

-- True while a cell is being dragged.
function slots.dragging() return drag ~= nil end

function slots.stats()
    local cells = 0
    for _, block in ipairs(blocks) do cells = cells + #block.cells end
    -- right: releases of the right button seen while a panel showed. pressed: presses the game told of. fired: over a
    -- cell. late: given to the cell the mouse had just been over. lost: over no cell. gaps: milliseconds between releases.
    return { blocks = #blocks, cells = cells, right = seen.right, pressed = seen.pressed or 0, fired = seen.fired, late = seen.late,
        lost = seen.lost,
        gaps = table.concat(seen.gaps, " ") }
end

return slots
