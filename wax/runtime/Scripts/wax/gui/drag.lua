-- Dragging: a button held and moved, a box resized by its edges, what is drawn under the mouse meanwhile, and a list put in a new order by it

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")
local tween = Wax.import("gui.tween")
local guard = Wax.import("core.guard")

local drag = {}

drag.AFTER = 6          -- how far the mouse moves with the button down before it is a drag
drag.SLIDE = 0.14       -- seconds a row takes to slide out of the way, and the held one to settle
drag.EDGE = 28          -- this near the top or bottom of a list, holding a row scrolls it
drag.SPEED = 480        -- units a second the list scrolls at most
drag.REACH = 40         -- this far above or below a list, letting go still counts as in it
drag.LIFT = 0.012       -- how much larger the held row is drawn
drag.SLACK = 5          -- how far past the point where two rows change places the held one goes before they do, either way

local V = style.Visibility
local current = nil     -- the list that is being put in a new order

local function now() return (Wax.perf and Wax.perf.now or os.clock)() end
local function seconds() return math.min(drag.SLIDE, style.theme.animation or 0) end

-- A button that has just gone down: where the mouse was then.
function drag.hold(button)
    local x, y = root.mouse()
    return { button = button, x = x, y = y }
end

-- Whether a button that went down is still held. It keeps saying so while the mouse is away from it.
function drag.down(button) return button:IsPressed() == true end

-- True once the mouse is further than `after` from where the button went down. Then where the mouse is.
function drag.far(hold, after)
    local x, y = root.mouse()
    after = after or drag.AFTER
    return math.abs(x - hold.x) > after or math.abs(y - hold.y) > after, x, y
end

-- How far the mouse is from where the button went down, in the units of something drawn at `scale`. Then where it is.
function drag.moved(hold, scale)
    local x, y = root.mouse()
    return (x - hold.x) / scale, (y - hold.y) / scale, x, y
end

-- One direction of drag.resize: the far side of a span (far) or its near side goes with the mouse, and the other side stays.
local function stretch(at, size, moved, far, least, low, high, reach)
    if far then
        local room = high and math.max(0, high - at - size) or math.huge
        return at, size + math.max(least - size, math.min(room, moved))
    end
    local out = low and math.min(0, low - at) or -math.huge
    local back = math.min(size - least, reach and math.max(0, reach - at) or math.huge)
    moved = math.max(out, math.min(back, moved))
    return at + moved, size - moved
end

-- A box { x, y, width, height } after the edges named ("n", "s", "e", "w", or a corner such as "nw") went dx, dy with the mouse.
-- limits: min_width, min_height; left, top, right, bottom (no edge is taken past these); reach_x, reach_y (the left and top edge go no further in).
function drag.resize(box, edges, dx, dy, limits)
    limits = limits or {}
    local x, y, width, height = box.x, box.y, box.width, box.height
    local east, south = edges:find("e", 1, true), edges:find("s", 1, true)
    if east or edges:find("w", 1, true) then
        x, width = stretch(x, width, dx, east, limits.min_width or 0, limits.left, limits.right, limits.reach_x)
    end
    if south or edges:find("n", 1, true) then
        y, height = stretch(y, height, dy, south, limits.min_height or 0, limits.top, limits.bottom, limits.reach_y)
    end
    return x, y, width, height
end

local Float = {}
Float.__index = Float

-- Something drawn over everything else, where it is told. make(float) builds what it shows; align is the point of it put there (its middle).
function drag.float(make, align)
    local float = setmetatable({ destroyed = false }, Float)
    style.build(float, function()
        float.outer = kit.scaled(make(float))
        float.outer:SetVisibility(V.Collapsed)
        float.slot = root.layer("toasts"):AddChild(float.outer)
        float.slot:SetAutoSize(true)
        float.slot:SetZOrder(1001)
        float.slot:SetAlignment(align or { X = 0.5, Y = 0.5 })
    end)
    return float
end

function Float:show(x, y, scale, opacity)
    if self.destroyed then return end
    self.outer:SetUserSpecifiedScale(scale or style.scale)
    self.slot:SetPosition({ X = x, Y = y })
    self.outer:SetRenderOpacity(opacity or 1)
    self.outer:SetVisibility(V.HitTestInvisible)
end

function Float:move(x, y)
    if not self.destroyed then self.slot:SetPosition({ X = x, Y = y }) end
end

function Float:hide()
    if not self.destroyed then self.outer:SetVisibility(V.Collapsed) end
end

-- Takes it off the screen for good.
function Float:destroy()
    if self.destroyed then return end
    self.destroyed = true
    pcall(function() self.outer:RemoveFromParent() end)
end

-- The interface was built again: it is gone, and is not touched.
function Float:forget() self.destroyed = true end

-- The place the row at `from` has reached, `moved` units below where it stood. A row is passed once the held row's leading edge is over its middle.
function drag.target(heights, gap, from, moved)
    local to, passed = from, 0
    local step = moved > 0 and 1 or -1
    local reach = math.abs(moved)
    for index = from + step, step > 0 and #heights or 1, step do
        if reach <= passed + gap + heights[index] / 2 then break end
        passed = passed + gap + heights[index]
        to = index
    end
    return to
end

-- How far the row at `from` is from its own place when it sits at `to`, and how far each row between the two gives way.
function drag.landing(heights, gap, from, to)
    if to == from then return 0, 0 end
    local step, offset = to > from and 1 or -1, 0
    for index = from + step, to, step do offset = offset + (heights[index] + gap) * step end
    return offset, -step * (heights[from] + gap)
end

local Sort = {}
Sort.__index = Sort

local function slide(row, shift)
    row.shift = shift
    if row.sliding then row.sliding.cancel() end
    local from = row.drawn or 0
    row.sliding = tween.run(seconds(), function(progress)
        row.drawn = from + (shift - from) * progress
        row.widget:SetRenderTranslation({ X = 0, Y = row.drawn })
    end, nil, "out", row.owner)
end

-- The rows between where the held one came from and where it is now give way. The others go home.
function Sort:retarget(to)
    if to == self.at then return end
    self.at = to
    local _, give = drag.landing(self.heights, self.gap, self.from, to)
    local low, high = math.min(self.from, to), math.max(self.from, to)
    for index, row in ipairs(self.rows) do
        local shift = (index ~= self.from and index >= low and index <= high) and give or 0
        if shift ~= (row.shift or 0) then slide(row, shift) end
    end
end

-- The place the held row is over, `moved` units from its own. A mouse that rests where two rows change places does not
-- send them back and forth: the row has to go a little past that point, either way, before they move.
function Sort:aim(moved)
    local low = drag.target(self.heights, self.gap, self.from, moved - drag.SLACK)
    local high = drag.target(self.heights, self.gap, self.from, moved + drag.SLACK)
    self:retarget(math.max(low, math.min(high, self.at)))
end

-- How far a scroll box is really scrolled. What it says can be more than there is to scroll, once its content got shorter
-- or its window taller: taken as it is, a held row would jump by the difference the moment the box puts itself right.
function drag.offset(scroller)
    return math.max(0, math.min(scroller:GetScrollOffsetOfEnd(), scroller:GetScrollOffset()))
end

-- How far the list has been scrolled since the row was picked up.
function Sort:scrolled()
    return self.scroller and drag.offset(self.scroller) - self.scroll0 or 0
end

-- Where the top of the held row may be on the screen: no higher than the list's first place and no lower than its last,
-- and inside the part of the list that shows (top to bottom). So it never lies over what stands above or below the list.
function Sort:reach(top, bottom, scrolled)
    local scale = self.scale
    local shift = self.pushed - scrolled
    local first = self.y + (drag.landing(self.heights, self.gap, self.from, 1) + shift) * scale
    local last = self.y + (drag.landing(self.heights, self.gap, self.from, #self.heights) + shift) * scale
    local low = math.max(top, first)
    return low, math.max(low, math.min(bottom - self.height * scale, last))
end

-- Rows change height under a drag (text wraps once it is seen, the held row folds): what is above the held one moves its place.
function Sort:measure()
    local changed = false
    for index, row in ipairs(self.rows) do
        local height = row.widget:GetDesiredSize().Y
        if height ~= self.heights[index] then
            if index < self.from then self.pushed = self.pushed + height - self.heights[index] end
            self.heights[index], changed = height, true
        end
    end
    if not changed then return end
    local at = self.at
    self.at = nil
    self:retarget(at)
end

function Sort:lift(amount)
    if amount == self.lifted then return end
    self.lifted = amount
    local size = 1 + drag.LIFT * amount
    self.float.outer:SetRenderScale({ X = size, Y = size })
end

-- True when the list was built again, its window went away, or the interface did: nothing that is gone is touched after.
function Sort:lost()
    if self.float.destroyed or (self.showing and not self.showing()) then return true end
    for _, row in ipairs(self.rows) do
        if row.owner.destroyed then return true end
    end
    return false
end

-- Ends it. to: where the row was let go, or nil when it goes back. done may build the list again, so it runs before the rows are put right.
function Sort:finish(to)
    if self.state == "over" then return false end
    self.state = "over"
    if current == self then current = nil end
    if not self.float.destroyed then
        self.float:hide()
        self:lift(0)
    end
    if to and self.done then guard.call("drag", self.done, self.from, to) end
    for index, row in ipairs(self.rows) do
        if row.sliding then row.sliding.cancel() end
        if not row.owner.destroyed then
            if (row.drawn or 0) ~= 0 then row.widget:SetRenderTranslation({ X = 0, Y = 0 }) end
            if index == self.from then row.widget:SetRenderOpacity(1) end
        end
    end
    if self.ended then guard.call("drag", self.ended) end
    return false
end

-- Ends it at once, with every row back where it stands in the list.
function Sort:stop() self:finish(nil) end

function Sort:release(state)
    self.state, self.since, self.glide = state, now(), seconds()
    self:measure()
    if state == "returning" then self:retarget(self.from) end
    self.rest = drag.landing(self.heights, self.gap, self.from, self.at)
    self.left_y, self.left_lift = self.float_y, self.lifted
end

-- Puts the held row back where it came from. The button may still be down: nothing follows it any more.
function Sort:cancel()
    if self.state ~= "held" then return end
    if self:lost() then self:finish(nil) else self:release("returning") end
end

-- Once a frame. False when it is over.
function Sort:step()
    if self.state == "over" then return false end
    if self:lost() then return self:finish(nil) end
    local scale, time = self.scale, now()
    if self.state == "held" then
        local _, dy, x, y = drag.moved(self.hold, scale)
        local left, top, right, bottom = self.area()
        if drag.down(self.hold.button) then
            local scrolled = 0
            if self.scroller then
                local offset, edge = drag.offset(self.scroller), drag.EDGE * scale
                local push = (y < top + edge and (y - top - edge) / edge) or (y > bottom - edge and (y - bottom + edge) / edge) or 0
                if push ~= 0 then
                    local step = math.max(-1, math.min(1, push)) * drag.SPEED * math.min(0.05, time - self.time)
                    local wanted = math.max(0, math.min(self.scroller:GetScrollOffsetOfEnd(), offset + step))
                    if wanted ~= offset then
                        self.scroller:SetScrollOffset(wanted)
                        offset = wanted
                    end
                end
                -- what scrolling brings into view is measured again, for a few frames after it stops too
                if offset ~= self.seen_at then self.seen_at, self.looks = offset, 3 end
                scrolled = offset - self.scroll0
            end
            if self.looks > 0 or time < self.settled then
                self.looks = math.max(0, self.looks - 1)
                self:measure()
            end
            self.time = time
            -- the row stays inside its list, and the others give way to where it is drawn, not to where the mouse is
            local low, high = self:reach(top, bottom, scrolled)
            local float_y = math.max(low, math.min(high, self.y + dy * scale))
            self:aim((float_y - self.y) / scale + scrolled - self.pushed)
            if float_y ~= self.float_y then
                self.float_y = float_y
                self.float:move(self.x, float_y)
            end
            local lifting = seconds()
            self:lift(lifting > 0 and math.min(1, (time - self.started) / lifting) or 1)
            return true
        end
        local reach = drag.REACH * scale
        self:release(x >= left and x <= right and y >= top - reach and y <= bottom + reach and "landing" or "returning")
    end
    -- let go: it glides to its new place, or back to where it came from
    local progress = self.glide > 0 and math.min(1, (time - self.since) / self.glide) or 1
    local eased = 1 - (1 - progress) ^ 3
    local rest_y = self.y + (self.rest - self:scrolled() + self.pushed) * scale
    self.float_y = self.left_y + (rest_y - self.left_y) * eased
    self.float:move(self.x, self.float_y)
    self:lift(self.left_lift * (1 - eased))
    if progress >= 1 then return self:finish(self.state == "landing" and self.at or nil) end
    return true
end

-- Picks up one row of a list that stands top to bottom. Call step() on what it returns every frame, until that answers false. options:
--   rows { { widget, owner, height } ... }, index (the one picked up), gap (between two rows), hold (drag.hold), scale (of the list),
--   float (drag.float, aligned top left), height (of the float), x, y (where the row is on the screen), settle (seconds a row is still folding),
--   scroller, area() (left, top, right, bottom of the list), showing(), done(from, to) (let go in the list), ended() (over, however)
function drag.sort(options)
    if current then current:stop() end
    local self = setmetatable({
        rows = options.rows, from = options.index, at = options.index, gap = options.gap or 0, heights = {},
        hold = options.hold, scale = options.scale or style.scale, float = options.float, x = options.x, y = options.y,
        float_y = options.y, scroller = options.scroller, area = options.area, showing = options.showing, done = options.done,
        ended = options.ended, state = "held", started = now(), lifted = 0, scroll0 = 0, pushed = 0, looks = 0,
    }, Sort)
    self.time, self.settled = self.started, self.started + (options.settle or 0)
    self.height = options.height or self.rows[self.from].height
    for index, row in ipairs(self.rows) do self.heights[index] = row.height end
    if self.scroller then self.scroll0 = drag.offset(self.scroller) end
    self.seen_at = self.scroll0
    self.rows[self.from].widget:SetRenderOpacity(0)
    self.float:show(self.x, self.y, self.scale, 1)
    current = self
    -- the mouse has moved since the button went down: the row is drawn where that puts it from its first frame
    self:step()
    return self
end

-- Puts back the row that is being dragged. True when one was: the key that asked for it has done its work.
function drag.cancel()
    if not current or current.state ~= "held" then return false end
    current:cancel()
    return true
end

-- The list that has a row held or still gliding to its place, or nil.
function drag.sorting() return current end

-- The interface was built again: what was held is gone with it.
function drag.forget() current = nil end

return drag
