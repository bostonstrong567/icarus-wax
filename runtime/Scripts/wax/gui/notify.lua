-- Notifications: short messages that slide in at a corner of the screen and fade away

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")
local tween = Wax.import("gui.tween")

local notify = {}

local V, H, VA = style.Visibility, style.HAlign, style.VAlign
local KINDS = { info = { "accent", "info" }, good = { "good", "check-circle" }, warn = { "warn", "alert-triangle" },
    bad = { "bad", "x-circle" } }
local CORNERS = { ["top-left"] = { 0, 0 }, ["top-right"] = { 1, 0 }, ["bottom-left"] = { 0, 1 }, ["bottom-right"] = { 1, 1 } }
local WIDTH, MARGIN = 300, 20

local shown = {}            -- oldest first
local leaving = {}          -- closed and fading out
local stack, stack_box, stack_slot = nil, nil, nil
local corner, limit = "bottom-right", 5
local clock = os.clock

local function place_stack()
    local at = CORNERS[corner]
    stack_slot:SetAnchors({ Minimum = { X = at[1], Y = at[2] }, Maximum = { X = at[1], Y = at[2] } })
    stack_slot:SetAlignment({ X = at[1], Y = at[2] })
    stack_slot:SetAutoSize(true)
    stack_slot:SetPosition({ X = at[1] == 1 and -MARGIN or MARGIN, Y = at[2] == 1 and -MARGIN or MARGIN })
end

local function get_stack()
    if stack then return stack end
    stack = root.new("VerticalBox")
    local at = CORNERS[corner]
    stack_box = kit.scaled(stack, at[1] == 1 and H.Right or H.Left, at[2] == 1 and VA.Bottom or VA.Top)
    stack_slot = root.layer("toasts"):AddChild(stack_box)
    place_stack()
    return stack
end

local Notification = {}
Notification.__index = Notification

function Notification:SetText(text)
    if self.closed then return end
    self.text = tostring(text)
    self.body:SetText(kit.text(self.text))
end

function Notification:SetTitle(title)
    if self.closed or not self.heading then return end
    self.title = tostring(title)
    self.heading:SetText(kit.text(self.title))
end

-- Shows how far a task is, 0..1, in place of the countdown. The notification then stays until closed.
function Notification:SetProgress(amount)
    if self.closed then return end
    self.progress = math.max(0, math.min(1, amount or 0))
    self.expires = nil
    self:fill(self.progress)
end

function Notification:Close()
    if self.closed then return end
    self.closed = true
    for index, other in ipairs(shown) do
        if other == self then
            table.remove(shown, index)
            break
        end
    end
    local card = self.card
    leaving[self] = true
    tween.run(style.theme.animation, function(progress)
        card:SetRenderOpacity(1 - progress)
        card:SetRenderTranslation({ X = self.slide * progress * 24, Y = 0 })
    end, function()
        card:RemoveFromParent()
        self.destroyed, leaving[self] = true, nil
    end, nil, self)
end

function Notification:fill(amount)
    self.bar:SetVisibility(amount > 0.002 and V.HitTestInvisible or V.Hidden)
    self.bar_slot:SetSize({ SizeRule = style.SizeRule.Fill, Value = math.max(amount, 0.0001) })
    self.rest_slot:SetSize({ SizeRule = style.SizeRule.Fill, Value = math.max(1 - amount, 0.0001) })
end

local function build(self, options)
    local theme, kind, text = style.theme, self.kind, self.text
    local color = theme[kind[1]]
    local card = root.new("Overlay")
    kit.slot(card:AddChild(kit.box(theme.window, "round8")), { h = H.Fill, v = VA.Fill })
    local column = root.new("VerticalBox")
    local row = root.new("HorizontalBox")
    kit.slot(row:AddChild(kit.icon(options.icon or kind[2], 16, color)), { v = VA.Top, pad = style.margin(0, 1, 10, 0) })
    local words = root.new("VerticalBox")
    local heading = nil
    if options.title then
        heading = kit.label(options.title, { face = "Bold", wrap = true })
        heading:SetWrapTextAt(WIDTH - 84)
        kit.slot(words:AddChild(heading), { pad = style.margin(0, 0, 0, 2) })
    end
    local body = kit.label(text, { wrap = true, color = options.title and theme.dim or theme.text })
    body:SetWrapTextAt(WIDTH - 84)
    words:AddChild(body)
    kit.slot(row:AddChild(words), { v = VA.Center, fill = 1 })
    local counter = kit.label("", { color = theme.dim, family = "mono", size = theme.small_size })
    kit.slot(row:AddChild(counter), { v = VA.Top, pad = style.margin(8, 1, 0, 0) })
    local padded = kit.box(theme.clear, nil, style.margin(12, 10, 12, 9))
    padded:SetContent(row)
    kit.slot(column:AddChild(padded), { h = H.Fill })

    -- a thin line along the bottom: time left, or progress
    local cells = root.new("HorizontalBox")
    local bar = kit.box(color, style.capsule(2))
    local bar_slot = cells:AddChild(bar)
    local rest_slot = cells:AddChild(root.new("Spacer"))
    local line = kit.box(theme.clear, nil, style.margin(10, 0, 10, 5))
    line:SetContent(kit.sized(cells, nil, 2))
    kit.slot(column:AddChild(line), { h = H.Fill })

    kit.slot(card:AddChild(kit.sized(column, WIDTH)), { h = H.Fill, v = VA.Fill })
    local outline = kit.image(theme.outline, "frame8", 1, 1)
    kit.slot(card:AddChild(outline), { h = H.Fill, v = VA.Fill })
    kit.slot(get_stack():AddChild(card), { pad = style.margin(0, 8, 0, 0) })
    self.card, self.body, self.heading, self.counter = card, body, heading, counter
    self.bar, self.bar_slot, self.rest_slot = bar, bar_slot, rest_slot
end

-- options: { title, kind = "info" | "good" | "warn" | "bad", icon, seconds = 4 (0 = until closed), progress = 0..1 }
function notify.show(text, options)
    if type(text) == "table" and type(text.Notify) == "function" then error("write ui.Notify(...) with a dot, not a colon", 2) end
    if not root.exists() then return nil end
    options = options or {}
    local theme = style.theme
    local kind = KINDS[options.kind or "info"]
    if not kind then error("a notification's kind is \"info\", \"good\", \"warn\" or \"bad\"", 2) end
    text = tostring(text)

    -- the same message again restarts the one already showing instead of stacking a copy
    for _, other in ipairs(shown) do
        if other.text == text and other.title == options.title and other.kind == kind then
            other.count = other.count + 1
            other.counter:SetText(kit.text("x" .. other.count))
            if other.expires then other.started, other.expires = clock(), clock() + other.seconds end
            return other
        end
    end
    -- make room: the oldest one that is only counting down goes first, so running tasks stay visible
    while #shown >= limit do
        local oldest = shown[1]
        for _, other in ipairs(shown) do
            if other.expires then
                oldest = other
                break
            end
        end
        oldest:Close()
    end

    local seconds = options.seconds or 4
    local self = setmetatable({ text = text, title = options.title, kind = kind, count = 1, seconds = seconds,
        slide = CORNERS[corner][1] == 1 and 1 or -1 }, Notification)
    style.build(self, build, self, options)
    if options.progress then
        self:SetProgress(options.progress)
    elseif seconds > 0 then
        self.started, self.expires = clock(), clock() + seconds
        self:fill(1)
    else
        self:fill(0)
    end
    shown[#shown + 1] = self
    local card = self.card
    tween.run(theme.animation, function(progress)
        card:SetRenderOpacity(progress)
        card:SetRenderTranslation({ X = self.slide * (1 - progress) * 24, Y = 0 })
    end, nil, nil, self)
    return self
end

function notify.step()
    if #shown == 0 then return end
    local now = clock()
    for i = #shown, 1, -1 do
        local item = shown[i]
        if item.expires then
            if now >= item.expires then
                item:Close()
            else
                item:fill((item.expires - now) / item.seconds)
            end
        end
    end
end

-- Which corner notifications appear in: "top-left", "top-right", "bottom-left" or "bottom-right".
function notify.set_corner(name)
    if not CORNERS[name] then error("unknown corner '" .. tostring(name) .. "'", 2) end
    notify.clear()
    corner = name
    -- the ones still fading out are removed with the stack they are in
    for item in pairs(leaving) do item.destroyed = true end
    leaving = {}
    if stack_box then stack_box:RemoveFromParent() end
    stack, stack_box = nil, nil
end

function notify.rescale()
    if stack_box then stack_box:SetUserSpecifiedScale(style.scale) end
end

function notify.set_limit(count) limit = math.max(1, math.floor(count)) end
function notify.count() return #shown end

function notify.clear()
    for i = #shown, 1, -1 do shown[i]:Close() end
end

-- Forgets every notification without touching one (the interface is gone or about to go).
function notify.destroy_all()
    for _, item in ipairs(shown) do item.closed, item.destroyed = true, true end
    for item in pairs(leaving) do item.destroyed = true end
    shown, leaving, stack, stack_box, stack_slot = {}, {}, nil, nil, nil
end

return notify
