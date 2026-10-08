-- Shapes that place the store's nodes, and what of a category does not fit the store's screen

local Wax = ...
local suggest = Wax.import("core.suggest")

local M = {}

M.SIZE = 250                    -- a node is this wide and high
M.GAP = 300                     -- the middles of two nodes are never closer in the game's own store
M.ROUND = 360                   -- at this distance two nodes cannot lie on each other, whatever the direction between them
M.TOP, M.BOTTOM = 250, 1450     -- middles between these fit a 1080p screen, and the store only pans sideways
M.EDGE = 125                    -- a middle nearer to the canvas's left or top has part of its box outside
M.START = 500                   -- where the game's own categories begin
M.MIDDLE = 850
M.STEP_X, M.STEP_Y = 500, 350   -- from a node to the one it leads to, and to the one beside it
M.FAR = 1000000                 -- no place and no measure of a shape is further than this from 0
M.MOST = 10000                  -- nodes one call places
M.SHAPES = { "line", "grid", "ring", "arc", "spiral", "tree", "path" }

local OPTIONS = {
    line = { "from", "step", "angle" },
    grid = { "from", "cell", "columns", "rows" },
    ring = { "center", "radius", "start", "sweep" },
    arc = { "center", "radius", "start", "sweep" },
    spiral = { "center", "gap", "start", "turn" },
    tree = { "from", "center", "step", "direction" },
    path = { "points" },
}
local DIRECTIONS = { "right", "down", "radial" }
local TURNS = { "right", "left" }
local SAMPLES = 720             -- pieces an oval is cut into to space nodes evenly along it
local TWO_PI = 2 * math.pi

local cos, sin, floor, ceil, abs, sqrt, max, min = math.cos, math.sin, math.floor, math.ceil, math.abs, math.sqrt, math.max, math.min

local function fail(text, ...) error(select("#", ...) > 0 and text:format(...) or text, 0) end

-- True for a number a place can be made of: not NaN, not endless, and no further than FAR from 0.
function M.usable(value) return type(value) == "number" and abs(value) <= M.FAR end

-- A number for a sentence, the same on every build of Lua: 850 and not 850.0, and inf and nan by those names.
function M.written(value)
    if value ~= value then return "nan" end
    if value == math.huge or value == -math.huge then return value > 0 and "inf" or "-inf" end
    return tostring(math.tointeger(value) or value)
end
local written = M.written

local function number(value, name, fallback)
    if value == nil then return fallback end
    if type(value) ~= "number" then fail("`%s` is a number, got %s", name, type(value)) end
    if not M.usable(value) then fail("`%s` is a number no further than %d from 0, got %s", name, M.FAR, written(value)) end
    return value
end

local function whole(value, name, least)
    local found = type(value) == "number" and math.tointeger(value)
    if not found or found < least then fail("`%s` is a whole number of %d or more", name, least) end
    return found
end

local function pair(value, name, example, x, y)
    if value == nil then return x, y end
    if type(value) == "table" then
        local a, b = value[1] or value.x or value.X, value[2] or value.y or value.Y
        if M.usable(a) and M.usable(b) then return a, b end
        if type(a) == "number" and type(b) == "number" then
            fail("`%s` is two numbers no further than %d from 0, got %s, %s", name, M.FAR, written(a), written(b))
        end
    end
    fail("`%s` is two numbers such as %s", name, example)
end

local function choice(value, name, known, fallback)
    if value == nil then return fallback end
    for _, word in ipairs(known) do
        if value == word then return word end
    end
    local listed = "\"" .. table.concat(known, "\", \"", 1, #known - 1) .. "\" or \"" .. known[#known] .. "\""
    fail("`%s` is %s.%s", name, listed, type(value) == "string" and suggest.phrase(value, known) or "")
end

local function distance(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

local shapes = {}

function shapes.line(count, o)
    local x, y = pair(o.from, "from", "{ 500, 850 }", M.START, M.MIDDLE)
    local dx, dy
    if type(o.step) == "table" then
        if o.angle ~= nil then fail("`angle` goes with a `step` that is one number") end
        dx, dy = pair(o.step, "step", "{ 350, 0 }")
    else
        local step, angle = number(o.step, "step", 350), math.rad(number(o.angle, "angle", 0))
        dx, dy = step * cos(angle), step * sin(angle)
    end
    local out = {}
    for index = 0, count - 1 do out[index + 1] = { x = x + index * dx, y = y + index * dy } end
    return out
end

function shapes.grid(count, o)
    local x, y = pair(o.from, "from", "{ 500, 250 }", M.START, M.TOP)
    local wide, high = 350, 300
    if type(o.cell) == "table" then
        wide, high = pair(o.cell, "cell", "{ 350, 300 }")
    elseif o.cell ~= nil then
        wide = number(o.cell, "cell")
        high = wide
    end
    if wide <= 0 or high <= 0 then fail("`cell` is larger than 0") end
    if o.columns ~= nil and o.rows ~= nil then fail("give `columns` or `rows`, not both") end
    local columns
    if o.columns ~= nil then
        columns = whole(o.columns, "columns", 1)
    else
        -- as many rows as the screen's height takes, the rest goes sideways
        local rows = o.rows ~= nil and whole(o.rows, "rows", 1) or max(1, floor((M.BOTTOM - y) / high) + 1)
        columns = max(1, ceil(count / rows))
    end
    local out = {}
    for index = 0, count - 1 do out[index + 1] = { x = x + (index % columns) * wide, y = y + (index // columns) * high } end
    return out
end

-- `count` places along an oval, the same distance apart along the curve. A full turn does not repeat its first place.
local function along(wide, high, start, sweep, count, closed)
    if count == 1 then return { { x = wide * cos(start), y = high * sin(start) } } end
    local gaps = closed and count or count - 1
    local out = {}
    if wide == high then
        for index = 0, count - 1 do
            local angle = start + sweep * index / gaps
            out[index + 1] = { x = wide * cos(angle), y = high * sin(angle) }
        end
        return out
    end
    local xs, ys, lengths = {}, {}, { 0 }
    for index = 0, SAMPLES do
        local angle = start + sweep * index / SAMPLES
        xs[index + 1], ys[index + 1] = wide * cos(angle), high * sin(angle)
        if index > 0 then lengths[index + 1] = lengths[index] + distance(xs[index], ys[index], xs[index + 1], ys[index + 1]) end
    end
    local at = 1
    for index = 0, count - 1 do
        local wanted = lengths[SAMPLES + 1] * index / gaps
        while at < SAMPLES and lengths[at + 1] < wanted do at = at + 1 end
        local span = lengths[at + 1] - lengths[at]
        local part = span > 0 and (wanted - lengths[at]) / span or 0
        out[index + 1] = { x = xs[at] + (xs[at + 1] - xs[at]) * part, y = ys[at] + (ys[at + 1] - ys[at]) * part }
    end
    return out
end

local function nearest_neighbours(places, closed)
    local least = math.huge
    for index = 1, #places - 1 do
        least = min(least, distance(places[index].x, places[index].y, places[index + 1].x, places[index + 1].y))
    end
    if closed and #places > 2 then least = min(least, distance(places[1].x, places[1].y, places[#places].x, places[#places].y)) end
    return least
end

local function round(count, o, start_angle, sweep_angle)
    local start = math.rad(number(o.start, "start", start_angle))
    local degrees = number(o.sweep, "sweep", sweep_angle)
    if degrees == 0 then fail("`sweep` is how far round the nodes go, in degrees, and not 0") end
    local sweep, closed = math.rad(degrees), abs(degrees) >= 360
    local wide, high, places
    if type(o.radius) == "table" then
        wide, high = pair(o.radius, "radius", "{ 900, 600 }")
    elseif o.radius ~= nil then
        wide = number(o.radius, "radius")
        high = wide
    end
    if wide then
        if wide <= 0 or high <= 0 then fail("`radius` is larger than 0") end
        places = along(wide, high, start, sweep, count, closed)
    else
        -- the smallest circle that keeps neighbours apart. One too tall for the screen becomes an oval that is wider instead
        local gaps = closed and count or count - 1
        local needed = gaps > 0 and M.ROUND / (2 * sin(min(abs(sweep) / gaps, math.pi) / 2)) or 0
        local tallest = (M.BOTTOM - M.TOP) / 2
        wide = max(M.ROUND, needed)
        high = min(wide, tallest)
        places = along(wide, high, start, sweep, count, closed)
        local tries = 0
        while high < wide and nearest_neighbours(places, closed) < M.ROUND and tries < 60 do
            wide, tries = wide * 1.08, tries + 1
            places = along(wide, high, start, sweep, count, closed)
        end
    end
    local left = math.huge
    for _, place in ipairs(places) do left = min(left, place.x) end
    local x, y = pair(o.center, "center", "{ 1200, 850 }", M.START - left, M.MIDDLE)
    for _, place in ipairs(places) do place.x, place.y = place.x + x, place.y + y end
    return places
end

function shapes.ring(count, o) return round(count, o, -90, 360) end
function shapes.arc(count, o) return round(count, o, 180, 180) end

function shapes.spiral(count, o)
    local gap = number(o.gap, "gap", M.ROUND)
    if gap < 1 then fail("`gap` is 1 or more") end
    local start = math.rad(number(o.start, "start", -90))
    local way = choice(o.turn, "turn", TURNS, "right") == "left" and -1 or 1
    -- one node in the middle, then outwards: each time round the arm is one gap further out
    local function at(turned)
        local radius = gap + gap * turned / TWO_PI
        return radius * cos(start + way * turned), radius * sin(start + way * turned)
    end
    local out, turned = {}, 0
    if count >= 1 then out[1] = { x = 0, y = 0 } end
    if count >= 2 then
        local x, y = at(0)
        out[2] = { x = x, y = y }
    end
    for index = 3, count do
        local before = out[index - 1]
        local x, y
        -- a sixth of a turn further on is always a gap away, so the search is given no more than that
        for _ = 1, 120 do
            turned = turned + 0.01
            x, y = at(turned)
            if distance(x, y, before.x, before.y) >= gap then break end
        end
        out[index] = { x = x, y = y }
    end
    local left = 0
    for _, place in ipairs(out) do left = min(left, place.x) end
    local x, y = pair(o.center, "center", "{ 1200, 850 }", M.START - left, M.MIDDLE)
    for _, place in ipairs(out) do place.x, place.y = place.x + x, place.y + y end
    return out
end

function shapes.path(count, o)
    local points = o.points
    if type(points) ~= "table" or #points == 0 then fail("`points` is a list of places such as { { 500, 850 }, { 1500, 400 } }") end
    local xs, ys, lengths = {}, {}, { 0 }
    for index, point in ipairs(points) do
        xs[index], ys[index] = pair(point, "points", "{ 500, 850 }")
        if index > 1 then lengths[index] = lengths[index - 1] + distance(xs[index - 1], ys[index - 1], xs[index], ys[index]) end
    end
    local out, at = {}, 1
    for index = 0, count - 1 do
        local wanted = count > 1 and lengths[#points] * index / (count - 1) or 0
        while at < #points - 1 and lengths[at + 1] < wanted do at = at + 1 end
        local span = (lengths[at + 1] or lengths[at]) - lengths[at]
        local part = span > 0 and (wanted - lengths[at]) / span or 0
        local to = min(at + 1, #points)
        out[index + 1] = { x = xs[at] + (xs[to] - xs[at]) * part, y = ys[at] + (ys[to] - ys[at]) * part }
    end
    return out
end

-- Each item's depth: the longest way to it from one that needs nothing. A way round a circle is not followed.
local function depths(items)
    local index, parents = {}, {}
    for position, item in ipairs(items) do index[item.id] = position end
    for position, item in ipairs(items) do
        local list = {}
        for _, parent in ipairs(item.needs or {}) do
            local at = index[parent]
            if at and at ~= position then list[#list + 1] = at end
        end
        parents[position] = list
    end
    local depth, walking = {}, {}
    local function of(position)
        local known = depth[position]
        if known then return known end
        if walking[position] then return nil end
        walking[position] = true
        local deepest = 0
        for _, parent in ipairs(parents[position]) do
            local found = of(parent)
            if found and found + 1 > deepest then deepest = found + 1 end
        end
        walking[position] = nil
        depth[position] = deepest
        return deepest
    end
    local layers, last = {}, 0
    for position = 1, #items do
        local found = of(position)
        layers[found] = layers[found] or {}
        layers[found][#layers[found] + 1] = position
        if found > last then last = found end
    end
    return layers, last, parents, depth
end

-- Orders each layer by where its parents sit, so fewer lines cross.
local function untangle(layers, last, parents)
    local row = {}
    for depth = 0, last do
        for at, position in ipairs(layers[depth]) do row[position] = at end
    end
    for depth = 1, last do
        local keys = {}
        for at, position in ipairs(layers[depth]) do
            local sum, count = 0, 0
            for _, parent in ipairs(parents[position]) do sum, count = sum + row[parent], count + 1 end
            keys[position] = count > 0 and sum / count or at
        end
        table.sort(layers[depth], function(a, b)
            if keys[a] ~= keys[b] then return keys[a] < keys[b] end
            return a < b
        end)
        for at, position in ipairs(layers[depth]) do row[position] = at end
    end
end

local function tree_right(o, layers, last)
    local x, y = pair(o.from, "from", "{ 500, 850 }", M.START, M.MIDDLE)
    local dx, dy = pair(o.step, "step", "{ 500, 350 }", M.STEP_X, M.STEP_Y)
    if dy <= 0 then fail("`step` is larger than 0 both ways") end
    local room, out, column = M.BOTTOM - M.TOP, {}, 0
    for depth = 0, last do
        local layer, apart = layers[depth], dy
        -- a full column is drawn tighter before it is split, unless the mod author gave the step
        if o.step == nil and #layer > floor(room / apart) + 1 then apart = M.GAP end
        local fit = max(1, floor(room / apart) + 1)
        for first = 1, #layer, fit do
            local final = min(#layer, first + fit - 1)
            for at = first, final do
                out[layer[at]] = { x = x + column * dx, y = y + ((at - first) - (final - first) / 2) * apart }
            end
            column = column + 1
        end
    end
    return out
end

local function tree_down(o, layers, last)
    local x, y = pair(o.from, "from", "{ 500, 250 }", M.START, M.TOP)
    local dx, dy = pair(o.step, "step", "{ 350, 300 }", 350, 300)
    local out = {}
    for depth = 0, last do
        for at, position in ipairs(layers[depth]) do out[position] = { x = x + (at - 1) * dx, y = y + depth * dy } end
    end
    return out
end

local function tree_radial(o, layers, last, parents, depth, count)
    if type(o.step) == "table" then fail("`step` is one number when the direction is \"radial\": how far one ring is from the next") end
    local step = number(o.step, "step", M.ROUND)
    local children, leaves = {}, {}
    for position = 1, count do children[position] = {} end
    for position = 1, count do
        -- the parent it hangs on: the one a ring further in, else any further in
        local chosen = nil
        for _, parent in ipairs(parents[position]) do
            if depth[parent] == depth[position] - 1 then
                chosen = parent
                break
            end
            if not chosen and depth[parent] < depth[position] then chosen = parent end
        end
        if chosen then children[chosen][#children[chosen] + 1] = position end
    end
    local function count_leaves(position)
        if leaves[position] then return leaves[position] end
        local total = 0
        for _, child in ipairs(children[position]) do total = total + count_leaves(child) end
        leaves[position] = max(1, total)
        return leaves[position]
    end
    local roots, out = layers[0], {}
    local function lay(position, from, to, ring)
        local angle = (from + to) / 2
        out[position] = { x = ring * step * cos(angle), y = ring * step * sin(angle) }
        local at, total = from, count_leaves(position)
        for _, child in ipairs(children[position]) do
            local span = (to - from) * count_leaves(child) / total
            lay(child, at, at + span, ring + 1)
            at = at + span
        end
    end
    local single, total = #roots == 1, 0
    local firsts = single and children[roots[1]] or roots
    for _, position in ipairs(firsts) do total = total + count_leaves(position) end
    -- the first branch points up
    local from = math.rad(-90) - (firsts[1] and TWO_PI * count_leaves(firsts[1]) / total / 2 or 0)
    if single then
        lay(roots[1], from, from + TWO_PI, 0)
    else
        for _, position in ipairs(roots) do
            local span = TWO_PI * count_leaves(position) / total
            lay(position, from, from + span, 1)
            from = from + span
        end
    end
    local rings = single and last or last + 1
    local x, y = pair(o.center, "center", "{ 1200, 850 }", M.START + rings * step, M.MIDDLE)
    for _, place in pairs(out) do place.x, place.y = place.x + x, place.y + y end
    return out
end

function shapes.tree(count, o, items)
    local direction = choice(o.direction, "direction", DIRECTIONS, "right")
    local layers, last, parents, depth = depths(items)
    if count == 0 then return {} end
    untangle(layers, last, parents)
    if direction == "radial" then
        if o.from ~= nil then fail("a tree that is \"radial\" is placed with `center`, not `from`") end
        return tree_radial(o, layers, last, parents, depth, count)
    end
    if o.center ~= nil then fail("`center` goes with direction = \"radial\". Use `from` otherwise") end
    if direction == "down" then return tree_down(o, layers, last) end
    return tree_right(o, layers, last)
end

-- What a node needs as a list of ids: one id, a list of ids, or the long form of a described store with `any` and `all`.
local function needs_of(value, index)
    if value == nil then return nil end
    if type(value) == "string" or type(value) == "number" then return { value } end
    local mixed = false
    if type(value) == "table" then
        local named = false
        for key in pairs(value) do named = named or type(key) ~= "number" end
        if not named then return value end
        mixed = #value > 0
        if not mixed then
            local out = {}
            for _, kind in ipairs({ "any", "all" }) do
                local ids = value[kind]
                if type(ids) == "table" then
                    table.move(ids, 1, #ids, #out + 1, out)
                elseif ids ~= nil then
                    out[#out + 1] = ids
                end
            end
            return out
        end
    end
    fail("node %d of the list: `needs` is an id, a list of ids, or a table with any and all, got %s", index,
        mixed and "a table with both a list and names" or type(value))
end

-- Places for `items`: a count, a list of ids, or for a tree a list of { id = , needs = ids }. `shape` is a name or a function.
function M.place(shape, items, options)
    local list = {}
    if type(items) == "number" then
        local count = math.tointeger(items)
        if not count or count < 0 or count > M.MOST then
            fail("the number of nodes is a whole number from 0 to %d, got %s", M.MOST, written(items))
        end
        for index = 1, count do list[index] = { id = index } end
    elseif type(items) == "table" then
        if #items > M.MOST then fail("one call places up to %d nodes, and this list has %d", M.MOST, #items) end
        for index, item in ipairs(items) do
            list[index] = type(item) == "table" and { id = item.id, needs = needs_of(item.needs, index) } or { id = item }
            if list[index].id == nil then fail("node %d of the list has no id", index) end
        end
    else
        fail("the nodes to place are a number or a list, got %s", type(items))
    end
    if options ~= nil and type(options) ~= "table" then fail("the options of a shape are a table, got %s", type(options)) end
    options = options or {}
    local count, places = #list, {}
    if type(shape) == "function" then
        for index, item in ipairs(list) do
            local x, y = shape(index, item.id, count)
            if type(x) == "table" then x, y = x[1] or x.x or x.X, x[2] or x.y or x.Y end
            if not (M.usable(x) and M.usable(y)) then
                fail("the function gave no place for node %d (%s). It returns two numbers, each no further than %d from 0", index,
                    tostring(item.id), M.FAR)
            end
            places[index] = { x = x, y = y }
        end
    else
        local make = type(shape) == "string" and shapes[shape]
        if not make then
            fail("the store has no shape named '%s'.%s", tostring(shape), type(shape) == "string" and suggest.phrase(shape, M.SHAPES) or "")
        end
        for key in pairs(options) do
            local known = false
            for _, name in ipairs(OPTIONS[shape]) do known = known or name == key end
            if not known then
                fail("the shape \"%s\" has no option named '%s'.%s", shape, tostring(key), suggest.phrase(tostring(key), OPTIONS[shape]))
            end
        end
        places = make(count, options, list)
    end
    -- whatever the shape and its options, a place that is no usable number goes no further than this
    for index = 1, count do
        local place = places[index]
        if not (place and M.usable(place.x) and M.usable(place.y)) then
            fail("with these options node %d of %d gets no place. A place is two numbers, each no further than %d from 0", index, count, M.FAR)
        end
        place.x, place.y = floor(place.x + 0.5), floor(place.y + 0.5)
    end
    return places
end

-- What does not fit among the nodes of one category: { id, x, y, size }. A node of size 0 is a joint, which nobody sees.
function M.report(nodes)
    local out, cells = {}, {}
    local size, gap = M.SIZE, M.GAP
    for _, node in ipairs(nodes) do
        local wide = node.size == nil and size or node.size
        local seen = node.x ~= nil and node.y ~= nil and type(wide) == "number" and wide > 0
        if seen and not (M.usable(node.x) and M.usable(node.y)) then
            -- it is compared with nothing: a cell worked out from such a number is no cell
            out[#out + 1] = { kind = "far", a = node }
        elseif seen then
            if node.x < M.EDGE or node.y < M.EDGE then
                out[#out + 1] = { kind = "off-canvas", a = node }
            elseif node.y < M.TOP or node.y > M.BOTTOM then
                out[#out + 1] = { kind = "off-screen", a = node }
            end
            local column, row = node.x // gap, node.y // gap
            for beside = -1, 1 do
                for below = -1, 1 do
                    for _, other in ipairs(cells[(column + beside) * 65536 + row + below] or {}) do
                        local dx, dy = abs(node.x - other.x), abs(node.y - other.y)
                        if dx < size and dy < size then
                            out[#out + 1] = { kind = "overlap", a = other, b = node }
                        elseif dx * dx + dy * dy < gap * gap then
                            out[#out + 1] = { kind = "close", a = other, b = node, distance = floor(sqrt(dx * dx + dy * dy) + 0.5) }
                        end
                    end
                end
            end
            local key = column * 65536 + row
            cells[key] = cells[key] or {}
            cells[key][#cells[key] + 1] = node
        end
    end
    return out
end

-- True when the straight line from one place to another passes through the box round a third.
local function through(ax, ay, bx, by, x, y, half)
    local from, to = 0, 1
    local function clip(p, q)
        if p == 0 then return q >= 0 end
        local at = q / p
        if p < 0 then
            if at > to then return false end
            if at > from then from = at end
        else
            if at < from then return false end
            if at < to then to = at end
        end
        return true
    end
    local dx, dy = bx - ax, by - ay
    return clip(-dx, ax - (x - half)) and clip(dx, (x + half) - ax) and clip(-dy, ay - (y - half)) and clip(dy, (y + half) - ay)
end

-- The straight lines { from = node, to = node } that run over another node of `nodes`: { from, to, over }.
function M.crossings(nodes, lines)
    local out, half = {}, M.SIZE / 2 - 1
    for _, line in ipairs(lines) do
        local a, b = line.from, line.to
        for _, node in ipairs(nodes) do
            if node ~= a and node ~= b and node.x and (node.size or M.SIZE) > 0
                and through(a.x, a.y, b.x, b.y, node.x, node.y, half) then
                out[#out + 1] = { from = a, to = b, over = node }
            end
        end
    end
    return out
end

return M
