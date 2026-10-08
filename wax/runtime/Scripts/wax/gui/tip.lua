-- The tooltip: a small panel that follows the mouse and says what is under it

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")
local guard = Wax.import("core.guard")

local tip = {}

tip.LINES = 8           -- lines under the title, at most
tip.ZOOM = 1.2          -- it is read beside the game's own text, which is larger than a window's
local AWAY_X, AWAY_Y = 16, 20

local V = style.Visibility
local panel = nil       -- { outer, slot, title, lines = { label }, destroyed }
local shown, flipped_x, flipped_y = false, nil, nil
local keep = nil        -- asked every frame while a tip shows: false takes the tip away

local function build()
    local theme = style.theme
    local made = { lines = {}, destroyed = false }
    style.build(made, function()
        local box = kit.box(style.with_alpha(theme.window, 0.97), "round6", style.margin(9, 6, 9, 7))
        local column = root.new("VerticalBox")
        made.title = kit.label("", { face = "Bold", free = true })
        column:AddChild(made.title)
        for index = 1, tip.LINES do
            local line = kit.label("", { size = theme.small_size, color = theme.dim, free = true })
            kit.slot(column:AddChild(line), { pad = style.margin(0, 2, 0, 0) })
            line:SetVisibility(V.Collapsed)
            made.lines[index] = { label = line, text = "", tone = "dim", shown = false }
        end
        local frame = root.new("Overlay")
        frame:AddChild(box)
        box:SetContent(column)
        local outline = kit.image(theme.outline, "frame6", 1, 1)
        kit.slot(frame:AddChild(outline), { h = style.HAlign.Fill, v = style.VAlign.Fill })
        made.outer = kit.scaled(frame)
        made.zoom = tip.ZOOM
        made.outer:SetUserSpecifiedScale(style.scale * tip.ZOOM)
        made.outer:SetVisibility(V.Collapsed)
        made.slot = root.layer("toasts"):AddChild(made.outer)
        made.slot:SetAutoSize(true)
        made.slot:SetZOrder(1000)
    end)
    made.title_text = ""
    return made
end

-- content: a text, { title = "...", lines = { "text" or { text, tone } } }, or a function that returns one of those.
-- options: { keep = function that says each frame whether the tip stays, zoom = its size beside a window's text (1.2 when left out) }
function tip.show(content, options)
    if not root.exists() then return end
    if type(content) == "function" then
        local ok, result = guard.call("tooltip", content)
        content = ok and result or nil
    end
    if content == nil or content == "" then return tip.hide() end
    panel = panel or build()
    keep = options and options.keep or nil
    local zoom = options and options.zoom or tip.ZOOM
    if zoom ~= panel.zoom then
        panel.zoom = zoom
        panel.outer:SetUserSpecifiedScale(style.scale * zoom)
    end
    local title, lines = content, nil
    if type(content) == "table" then title, lines = content.title or content[1] or "", content.lines end
    title = tostring(title)
    if title ~= panel.title_text then
        panel.title_text = title
        kit.set_text(panel.title, title)
    end
    for index = 1, tip.LINES do
        local line, given = panel.lines[index], lines and lines[index]
        local text, tone = given, "dim"
        if type(given) == "table" then text, tone = given[1] or given.text, given[2] or given.tone or "dim" end
        if text ~= nil and text ~= "" then
            text = tostring(text)
            if text ~= line.text then
                line.text = text
                kit.set_text(line.label, text)
            end
            if tone ~= line.tone then
                line.tone = tone
                style.tint(line.label, "text", style.theme[tone] or style.theme.dim)
            end
            if not line.shown then
                line.shown = true
                line.label:SetVisibility(V.HitTestInvisible)
            end
        elseif line.shown then
            line.shown = false
            line.label:SetVisibility(V.Collapsed)
        end
    end
    if not shown then
        shown = true
        flipped_x, flipped_y = nil, nil
        tip.step()
        panel.outer:SetVisibility(V.HitTestInvisible)
    end
end

function tip.hide()
    if shown and panel then panel.outer:SetVisibility(V.Collapsed) end
    shown, keep = false, nil
end

-- The same tip with one more line under it, or that line alone: what shows cut is said in full here.
function tip.plus(content, line)
    line = tostring(line)
    if content == nil or content == "" then return line end
    return function()
        local inner = content
        if type(inner) == "function" then inner = inner() end
        if inner == nil or inner == "" then return line end
        local title, lines = inner, {}
        if type(inner) == "table" then
            title = inner.title or inner[1] or ""
            for index, given in ipairs(inner.lines or {}) do lines[index] = given end
        end
        if #lines >= tip.LINES then lines[tip.LINES] = nil end
        lines[#lines + 1] = { line, "text" }
        return { title = tostring(title), lines = lines }
    end
end

-- Whether a tip shows, and its first line.
function tip.showing() return shown, shown and panel and panel.title_text or nil end

-- Every frame while it shows: stay beside the mouse, on the side that has room.
function tip.step()
    if not (shown and panel) then return end
    if keep then
        local ok, stay = pcall(keep)
        if not (ok and stay) then return tip.hide() end
    end
    local x, y = root.mouse()
    local width, height = root.viewport_size()
    local left, up = x > width * 0.66, y > height * 0.7
    if left ~= flipped_x or up ~= flipped_y then
        flipped_x, flipped_y = left, up
        panel.slot:SetAlignment({ X = left and 1 or 0, Y = up and 1 or 0 })
    end
    panel.slot:SetPosition({ X = x + (left and -AWAY_X or AWAY_X), Y = y + (up and -AWAY_Y or AWAY_Y) })
end

function tip.rescale()
    if panel then panel.outer:SetUserSpecifiedScale(style.scale * panel.zoom) end
end

-- The interface was rebuilt: the old panel must not be touched again.
function tip.forget()
    if panel then panel.destroyed = true end
    panel, shown, keep = nil, false, nil
end

return tip
