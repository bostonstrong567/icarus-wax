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
local grab = Wax.import("gui.drag")

local slots = {}

slots.MAKE_SECONDS = 0.0015     -- cells are made for this long a frame until every block has all of its cells

local V, H, VA = style.Visibility, style.HAlign, style.VAlign
local blocks = {}               -- every live block
local over = nil                -- { block, index } under the mouse
local held = nil                -- the cell whose button went down, until it comes up
local press = nil               -- the button that went down and where the mouse was then (gui.drag)
local drag = nil                -- a cell being dragged: { block, index, hold, dx, dy }
local ghost = nil               -- the picture that follows the mouse during a drag (gui.drag)

slots.DRAG_AFTER = 6            -- how far the mouse moves with the button down before it is a drag
local on_hover = nil            -- called with (look, block, the whole of a count that shows cut) when what is under the mouse changes
local last = nil                -- the cell the mouse was over a moment ago, and when: { block, index, at }
local seen = { right = 0, fired = 0, late = 0, lost = 0, gaps = {} }

slots.GRACE = 0.25              -- seconds a cell still counts as under the mouse after the game took the mouse from it
slots.FOLLOW_HELD = true        -- while the right or middle button is held, the cell under the mouse is worked out from where the mouse is
local following = false         -- such a button is held and no cell says the mouse is over it
local looked = 0                -- frames since a block's place was last learned

slots.COUNT_SIZES = { 10, 9, 8 }    -- the sizes a count is drawn at: the largest that fits its cell
slots.COUNT_EDGE = 3                -- what a cell keeps of its width beside the letters of its count

local unfinished = true         -- some block may still be short of cells: warm() looks at them all only then

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
        place(self, holder, { h = sides[options.align] or H.Left, snug = true, own = columns * size + (columns - 1) * gap,
            pad = options.below and style.margin(0, 0, 0, options.below) or nil })

        local control = new_control(self, holder)
        local cells, looks = {}, {}
        local block = { control = control, cells = cells, looks = looks, count = columns * rows, host = self.window,
            drag = options.drag and true or false, size = size, lines = lines, columns = columns, gap = gap }
        unfinished = true
        -- a block that was hidden is not asked about the mouse
        local set_visible = control.SetVisible
        function control:SetVisible(shown)
            block.hidden = not shown
            return set_visible(self, shown)
        end
        -- nor is one that was switched off, and its cells do not show the hand
        local set_enabled = control.SetEnabled
        function control:SetEnabled(enabled)
            enabled = enabled and true or false
            set_enabled(self, enabled)
            if block.off == not enabled then return end
            block.off = not enabled
            for index = 1, #cells do cells[index].button:SetCursor(enabled and style.Cursor.Hand or style.Cursor.Default) end
        end
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
                if cell.count then
                    cell.count_box:SetVisibility(V.Collapsed)
                    cell.count, cell.whole = false, nil
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
                    cell.count_text = style.extend(control, kit.label, count, { size = slots.COUNT_SIZES[1] })
                    cell.count_box = style.extend(control, kit.box, style.with_alpha(theme.window, 0.8), "round4", style.margin(1, 0))
                    cell.count_box:SetContent(cell.count_text)
                    -- over the whole cell, so the cell's width is the count's room: smaller letters when it is long, dots when it is too long
                    kit.slot(cell.stack:AddChild(cell.count_box), { h = H.Right, v = VA.Bottom, pad = style.margin(0, 0, 1, 1) })
                    kit.fit(cell.count_text, size - slots.COUNT_EDGE, { sizes = slots.COUNT_SIZES })
                elseif count then
                    kit.set_text(cell.count_text, count)
                end
                if cell.count_box then cell.count_box:SetVisibility(count and V.HitTestInvisible or V.Collapsed) end
                cell.count, cell.whole = count, count and kit.whole(cell.count_text) or nil
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
            -- faint: the picture, and the icon of a cell that has no picture
            local dim = look.dim and true or false
            if dim ~= cell.dim then
                cell.dim = dim
                cell.picture:SetRenderOpacity(dim and 0.35 or 1)
            end
            if cell.glyph and dim ~= cell.glyph_dim then
                cell.glyph_dim = dim
                cell.glyph:SetRenderOpacity(dim and 0.35 or 1)
            end
        end

        local function make(index)
            local button = kit.button(nil, { shape = "round6", color = theme.clear, hover = theme.hover, press = theme.press,
                padding = style.margin(0), cursor = block.off and style.Cursor.Default or nil })
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
            local cell = { button = button, layers = layers, picture = picture, back = back, stack = stack, box = cell_box, shown = true, plain = false,
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

        -- Changes how many cells stand in a row and how large a cell is. The cells that exist are kept and put in their new rows.
        function control:SetLayout(new_columns, new_size)
            new_columns, new_size = math.max(1, math.floor(tonumber(new_columns) or columns)), tonumber(new_size) or size
            if new_columns == columns and new_size == size then return end
            local reflow, before = new_columns ~= columns, block.count
            columns, size = new_columns, new_size
            block.count, block.size, block.columns = columns * rows, size, columns
            unfinished = true
            holder:SetWidthOverride(columns * size + (columns - 1) * gap)
            holder:SetHeightOverride(rows * size + (rows - 1) * gap)
            if reflow then
                for row = 1, rows do lines[row]:ClearChildren() end
            end
            for index = 1, #cells do
                local cell = cells[index]
                cell.box:SetWidthOverride(size)
                cell.box:SetHeightOverride(size)
                if cell.count_text then
                    kit.fit(cell.count_text, size - slots.COUNT_EDGE, { sizes = slots.COUNT_SIZES })
                    cell.whole = cell.count and kit.whole(cell.count_text) or nil
                end
                if reflow then
                    -- a cell there is no room for any more stays where the engine keeps it, out of sight at the end of the last row
                    local used = index <= block.count
                    local row = used and math.floor((index - 1) / columns) + 1 or rows
                    kit.slot(lines[row]:AddChild(cell.box), { pad = style.margin(used and (index - 1) % columns > 0 and gap or 0, 0, 0, 0) })
                    if used ~= cell.used then
                        cell.used = used
                        cell.box:SetVisibility(used and V.SelfHitTestInvisible or V.Collapsed)
                    end
                end
            end
            for index = block.count + 1, math.max(before, #cells) do looks[index] = nil end
            if over and over.block == block then over.changed = true end
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
    return host.shown ~= false and host.on_screen ~= false and not host.minimized
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
        ghost = grab.float(function(made)
            made.layers = root.new("Overlay")
            made.picture = kit.image(style.WHITE, nil, 1, 1)
            kit.slot(made.layers:AddChild(made.picture), { h = H.Fill, v = VA.Fill })
            made.glyph = kit.icon("package", 20, style.theme.text)
            kit.slot(made.layers:AddChild(made.glyph), { h = H.Center, v = VA.Center })
            made.box = kit.sized(made.layers, 36, 36)
            return made.box
        end)
    end
    local size = block.size or 36
    ghost.box:SetWidthOverride(size)
    ghost.box:SetHeightOverride(size)
    if look.image then
        pictures.show(ghost.picture, look.image, ghost)
        ghost.glyph:SetVisibility(V.Collapsed)
    else
        pictures.clear(ghost.picture)
        kit.set_icon(ghost.glyph, look.icon or "package", math.floor(size * 0.5))
        ghost.glyph:SetVisibility(V.HitTestInvisible)
    end
    ghost:show(x, y, (block.host.place and 1 or style.scale) * (block.host.zoom or 1), 0.9)
end

local function ghost_hide()
    if ghost then ghost:hide() end
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
    if not unfinished then return end
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
    -- every block has its cells: nothing is looked at again until a block is made or laid out anew
    unfinished = false
end

-- Whether the mouse is over what a block sits in. A panel was asked this frame already (overlay.watch); a window is asked here, once.
local function host_hovered(host, asked)
    if host.hovered ~= nil then return host.hovered end
    local known = asked[host]
    if known == nil then
        if asked.windows == nil then asked.windows = root.layer("windows"):IsHovered() == true end
        known = asked.windows and host.frame ~= nil and host.frame:IsHovered() == true
        asked[host] = known
    end
    return known
end

-- The cell of a block that the mouse is over: its row is found first, so a large block costs a few questions and not one a cell.
local function cell_under(block)
    local cells, columns = block.cells, block.columns
    for row = 1, #block.lines do
        local first = (row - 1) * columns + 1
        if first > #cells or first > block.count then return nil end
        if block.lines[row]:IsHovered() then
            for index = first, math.min(first + columns - 1, #cells, block.count) do
                local cell = cells[index]
                if cell.shown and cell.button:IsHovered() then return index end
            end
            return nil
        end
    end
    return nil
end

-- A block the mouse can be over: it shows, and was neither hidden nor switched off.
local function takes_mouse(block)
    return not block.hidden and not block.off and showing(block)
end

-- How large one unit of a block is drawn on the screen.
local function drawn(block)
    return (block.host.place and 1 or style.scale) * (block.host.zoom or 1)
end

-- The mouse at x, y is over this cell: so the block's top left corner is within one cell's width and height of a known place.
-- Every look narrows that down. A look that cannot be true of the place kept (the block has moved) starts it again.
local function learn_place(block, index, x, y)
    local scale = drawn(block)
    local pitch, size = (block.size + block.gap) * scale, block.size * scale
    local column, row = (index - 1) % block.columns, (index - 1) // block.columns
    local high_x, high_y = x - column * pitch, y - row * pitch
    local low_x, low_y = high_x - size, high_y - size
    local place = block.place
    if place and place.scale == scale and place.columns == block.columns and place.size == block.size then
        low_x, high_x = math.max(low_x, place.low_x), math.min(high_x, place.high_x)
        low_y, high_y = math.max(low_y, place.low_y), math.min(high_y, place.high_y)
        if low_x <= high_x and low_y <= high_y then
            place.low_x, place.high_x, place.low_y, place.high_y = low_x, high_x, low_y, high_y
            return
        end
        low_x, high_x, low_y, high_y = x - column * pitch - size, x - column * pitch, y - row * pitch - size, y - row * pitch
    end
    block.place = { scale = scale, columns = block.columns, size = block.size, low_x = low_x, high_x = high_x, low_y = low_y, high_y = high_y }
end

-- The cell of a block whose place is known that x, y is in. Nothing between two cells, off the block, or on an empty cell.
local function cell_at(block, x, y)
    local place = block.place
    if not place or place.scale ~= drawn(block) or place.columns ~= block.columns or place.size ~= block.size then return nil end
    local pitch, size = (block.size + block.gap) * place.scale, block.size * place.scale
    local across, down = x - (place.low_x + place.high_x) / 2, y - (place.low_y + place.high_y) / 2
    local column, row = math.floor(across / pitch), math.floor(down / pitch)
    if column < 0 or column >= block.columns or row < 0 or row >= #block.lines then return nil end
    if across - column * pitch > size or down - row * pitch > size then return nil end
    local index = row * block.columns + column + 1
    local cell = block.cells[index]
    if index > block.count or not cell or not cell.shown or cell.plain then return nil end
    return index
end

-- While the right or the middle button is held: the block and the cell the mouse is in, from where the mouse is.
local function cell_at_mouse()
    local x, y = root.mouse()
    for at = 1, #blocks do
        local block = blocks[at]
        if block.place and takes_mouse(block) then
            local index = cell_at(block, x, y)
            if index then return block, index end
        end
    end
    return nil, nil
end

local function mouse_held()
    return input.is_down("MiddleMouseButton") or input.is_down("RightMouseButton")
end

-- Every frame while something that takes the mouse is showing: which cell is under the mouse, and what was pressed on it.
-- key_down: false when the caller knows that no key or button went down in this frame.
-- over_host: false when the caller knows that the mouse is over nothing a block of slots could be in.
function slots.step(active, key_down, over_host)
    if not active then
        if over then
            over = nil
            if on_hover then on_hover(nil, nil) end
        end
        held, following = nil, false
        return
    end
    if drag then
        local cell = showing(drag.block) and drag.block.cells[drag.index] or nil
        local dx, dy, x, y = grab.moved(drag.hold, (drag.block.host.place and 1 or style.scale) * (drag.block.host.zoom or 1))
        if cell and grab.down(cell.button) then
            ghost:move(x, y)
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
    if over and takes_mouse(over.block) then
        local cell = over.block.cells[over.index]
        if cell and cell.shown and cell.button:IsHovered() then found_block, found_index = over.block, over.index end
    end
    if not found_block and over_host ~= false then
        -- only what the mouse is over is asked: the panel or window first, then its blocks that show, then one row
        local asked = {}
        for at = 1, #blocks do
            local block = blocks[at]
            if takes_mouse(block) and host_hovered(block.host, asked) and block.control.widget:IsHovered() then
                found_index = cell_under(block)
                if found_index then
                    found_block = block
                    break
                end
            end
        end
    end
    local time = now()
    if slots.FOLLOW_HELD then
        if found_block then
            following = false
            -- the mouse is read until the block's place is known to a unit; after that only when it comes to another cell,
            -- and now and then, in case the block has moved
            local place = found_block.place
            looked = looked + 1
            if not place or looked >= 20 or not over or over.block ~= found_block or over.index ~= found_index
                or place.high_x - place.low_x > 1 or place.high_y - place.low_y > 1 then
                looked = 0
                local x, y = root.mouse()
                learn_place(found_block, found_index, x, y)
            end
        elseif following or (last and time - last.at <= slots.GRACE) then
            -- the game has the mouse while one of these buttons is down, and no cell says the mouse is over it
            local ok, down = pcall(mouse_held)
            following = ok and down == true
            if following then found_block, found_index = cell_at_mouse() end
        end
    end
    -- The right and the middle button are read from the game, and count when they come up again: beside the game's own
    -- screens it is not told of the press itself, only of the release. The game also takes the mouse for itself while
    -- a button is down, so a cell may stop saying the mouse is over it: the cell it was over a moment ago gets the click.
    -- With no cell under the mouse now or a moment ago there is nobody to give a click to, and nothing is read.
    local right, middle = false, false
    if found_block or (last and time - last.at <= slots.GRACE) then
        local ok, up = pcall(input.any, true)
        if not ok or up then
            local fine, was = pcall(input.just_released, "RightMouseButton")
            right = fine and was == true
            fine, was = pcall(input.just_released, "MiddleMouseButton")
            middle = fine and was == true
        end
        if key_down ~= false then
            local told, pressed = pcall(input.just_pressed, "RightMouseButton")
            if told and pressed == true then seen.pressed = (seen.pressed or 0) + 1 end
        end
    end
    if found_block then
        if last and last.block == found_block and last.index == found_index then
            last.at = time
        else
            last = { block = found_block, index = found_index, at = time }
        end
    elseif (right or middle) and last and time - last.at <= slots.GRACE and takes_mouse(last.block) and last.block.cells[last.index] then
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
        -- a count that shows cut is said in full beside the mouse
        local cell = found_block and found_block.cells[found_index]
        if on_hover then on_hover(look, found_block, cell and cell.whole or nil) end
    end
    if not over then return end
    local block, index = over.block, over.index
    local cell = block.cells[index]
    -- a click is the button going down and coming up again over the same cell
    local down = cell.button:IsPressed()
    if down then
        if held ~= cell then
            held = cell
            press = grab.hold(cell.button)
        elseif block.drag and press and block.looks[index] then
            -- held and moved far enough: from here on it is a drag, and letting go is not a click
            local far, x, y = grab.far(press, slots.DRAG_AFTER)
            if far then
                local look = block.looks[index]
                drag = { block = block, index = index, hold = press, dx = 0, dy = 0 }
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
    unfinished, following = true, false
    if ghost then ghost:forget() end
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
