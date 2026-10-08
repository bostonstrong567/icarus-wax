-- Offline tests for game.Workshop: the store read from the game's own rows, shapes, the requirement graph, the checks
-- of a described store, the command line's listing, and game.Workshop itself over a stand-in engine.
-- workshop_fixture.lua holds the store's rows of the game build it was taken from, so the numbers here are that build's.
-- Nothing here reaches the game.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\workshop_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_world.lua")
local tables = dofile("wax/tests/offline/fake_tables.lua")
local wording = dofile("wax/tests/offline/wording.lua")
fake.install()
tables.install()
local find_table = StaticFindObject
function StaticFindObject(path) return fake.static[path] or find_table(path) end
-- a name the engine made: a Lua string in its place crashes the real game
function FName(text)
    local name = fake.name(text)
    name.fname = text
    return name
end

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)
local sched = Wax.import("core.sched")
local guard = Wax.import("core.guard")
local scope = Wax.import("core.scope")
local log = Wax.import("core.log")
local instance = Wax.import("engine.instance")
local game = Wax.import("engine.game")
local data = Wax.import("data.tables")
local workshop = Wax.import("world.workshop")
local spec = Wax.import("world.workshop_spec")
local graph = Wax.import("world.workshop_graph")
local layout = Wax.import("world.workshop_layout")
local check = Wax.import("world.workshop_check")
local cli = dofile("wax/cli/workshop_offline.lua")
cli.suggest = Wax.import("core.suggest")
local WALLET_CALL = workshop.WALLET_CALL      -- as the module ships it, before any test switches it

local function fold(name) return (tostring(name):lower()) end

-- Calls fn as pcall does, under a limit of Lua steps: a loop that never ends fails its test and does not hang the suite.
local STEPS = 20000000
local function bounded(fn, ...)
    local ran_out = false
    local hook, mask, count = debug.gethook()
    debug.sethook(function()
        ran_out = true
        error("stopped after " .. STEPS .. " steps of Lua", 2)
    end, "", STEPS)
    local results = table.pack(pcall(fn, ...))
    debug.sethook(hook, mask, count)
    if ran_out then error("it did not end within " .. STEPS .. " steps of Lua", 2) end
    return table.unpack(results, 1, results.n)
end

local function count_by(list, key_of)
    local out = {}
    for _, item in ipairs(list) do
        local key = key_of(item)
        if key ~= nil then out[key] = (out[key] or 0) + 1 end
    end
    return out
end

local function codes(problems)
    return count_by(problems, function(problem) return problem.Code end)
end

local function text_of(problems, code)
    for _, problem in ipairs(problems) do
        if problem.Code == code then return problem.Text, problem end
    end
    return nil
end

local function at(place) return place.x .. "," .. place.y end

local function spots(places)
    local out = {}
    for index, place in ipairs(places) do out[index] = at(place) end
    return table.concat(out, " ")
end

local function apart(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

local function as_nodes(places)
    local out = {}
    for index, place in ipairs(places) do out[index] = { id = "n" .. index, x = place.x, y = place.y } end
    return out
end

-- ---------------------------------------------------------------- shapes

t.test("line: one after the other, by a distance and an angle or by a step", function()
    t.eq(spots(layout.place("line", 3)), "500,850 850,850 1200,850")
    t.eq(spots(layout.place("line", 3, { from = { 600, 250 }, step = { 0, 300 } })), "600,250 600,550 600,850")
    t.eq(spots(layout.place("line", 2, { angle = 90 })), "500,850 500,1200")
    t.eq(spots(layout.place("line", 2, { from = { x = 100, y = 200 }, step = 400 })), "100,200 500,200")
    t.eq(#layout.place("line", 0), 0)
    t.raises(function() layout.place("line", 2, { step = { 10, 10 }, angle = 5 }) end, "`angle` goes with a `step` that is one number")
end)

t.test("grid: as many rows as the screen's height takes, the rest goes sideways", function()
    t.eq(spots(layout.place("grid", 7)), "500,250 850,250 500,550 850,550 500,850 850,850 500,1150")
    t.eq(spots(layout.place("grid", 5, { rows = 2 })), "500,250 850,250 1200,250 500,550 850,550")
    -- `rows` is the most rows there can be: five nodes in at most four rows make rows of 2, 2 and 1
    t.eq(spots(layout.place("grid", 5, { rows = 4 })), "500,250 850,250 500,550 850,550 500,850")
    t.eq(spots(layout.place("grid", 5, { columns = 4 })), "500,250 850,250 1200,250 1550,250 500,550")
    t.eq(spots(layout.place("grid", 3, { from = { 100, 300 }, cell = 400, columns = 2 })), "100,300 500,300 100,700")
    -- 23 nodes in five rows: nothing leaves the heights that fit
    local places = layout.place("grid", 23)
    for _, place in ipairs(places) do t.ok(place.y >= layout.TOP and place.y <= layout.BOTTOM, at(place)) end
    t.eq(#layout.report(as_nodes(places)), 0)
    t.raises(function() layout.place("grid", 3, { rows = 2, columns = 2 }) end, "give `columns` or `rows`, not both")
    t.raises(function() layout.place("grid", 3, { rows = 0 }) end, "`rows` is a whole number of 1 or more")
end)

t.test("ring: round a middle, far enough apart, and an oval when a circle would be too tall", function()
    local six = layout.place("ring", 6)
    t.eq(#six, 6)
    local top = six[1]
    for index, place in ipairs(six) do
        t.ok(place.y >= top.y, "the first is the highest")
        t.ok(math.abs(apart(place, { x = top.x, y = 850 }) - 360) <= 1.5, "node " .. index .. " is 360 from the middle")
        t.ok(apart(place, six[index % 6 + 1]) >= 358, "neighbours are apart")
    end
    t.eq(#layout.report(as_nodes(six)), 0)
    for _, count in ipairs({ 1, 2, 7, 12, 13, 30, 60 }) do
        local places = layout.place("ring", count)
        t.eq(#places, count)
        local left = math.huge
        for _, place in ipairs(places) do
            left = math.min(left, place.x)
            t.ok(place.y >= layout.TOP and place.y <= layout.BOTTOM, count .. " nodes: " .. at(place) .. " fits the height")
        end
        t.eq(left, 500, count .. " nodes begin where the game's categories do")
        t.eq(#layout.report(as_nodes(places)), 0, count .. " nodes lie free")
    end
    -- what the mod author asks for is used as it is, and the report says what comes of it
    local tight = layout.place("ring", 6, { center = { 1000, 850 }, radius = 100 })
    t.eq(at(tight[1]), "1000,750")
    t.ok(#layout.report(as_nodes(tight)) > 0)
    local oval = layout.place("ring", 4, { center = { 2000, 850 }, radius = { 900, 300 }, start = 0 })
    t.eq(at(oval[1]), "2900,850")
    t.eq(at(oval[3]), "1100,850")
    t.raises(function() layout.place("ring", 3, { radius = 0 }) end, "`radius` is larger than 0")
end)

t.test("arc: from one end to the other over the top", function()
    local places = layout.place("arc", 5)
    t.eq(at(places[1]), "500,850")
    t.eq(places[5].y, 850)
    t.ok(places[5].x > places[1].x)
    for index, place in ipairs(places) do t.ok(place.y >= places[3].y, "the middle one is the highest, node " .. index) end
    t.eq(#layout.report(as_nodes(places)), 0)
    t.eq(#layout.report(as_nodes(layout.place("arc", 20))), 0)
    -- a quarter turn downwards from the right
    local quarter = layout.place("arc", 2, { center = { 1000, 500 }, radius = 400, start = 0, sweep = 90 })
    t.eq(spots(quarter), "1400,500 1000,900")
end)

t.test("spiral: outwards from a middle, a gap apart", function()
    local places = layout.place("spiral", 9)
    for index = 2, #places do
        t.ok(apart(places[index], places[index - 1]) >= 358, "node " .. index .. " is a gap from the one before")
    end
    t.eq(#layout.report(as_nodes(places)), 0)
    local own = layout.place("spiral", 3, { center = { 2000, 850 }, gap = 400 })
    t.eq(spots(own), "2000,850 2000,450 " .. at(own[3]))
    -- the first node is the middle, and `start` is the way to the second
    t.eq(spots(layout.place("spiral", 2, { center = { 2000, 850 }, start = 0 })), "2000,850 2360,850")
    -- a gap so small that no two places are ever a gap apart is refused, and the smallest one still ends
    t.raises(function() layout.place("spiral", 3, { gap = 1e-300 }) end, "`gap` is 1 or more")
    t.raises(function() layout.place("spiral", 3, { gap = 0 }) end, "`gap` is 1 or more")
    local ok, tiny = bounded(layout.place, "spiral", 50, { gap = 1 })
    t.ok(ok, tostring(tiny))
    t.eq(#tiny, 50)
    local left = layout.place("spiral", 3, { center = { 2000, 850 }, gap = 400, turn = "left" })
    t.eq(left[3].x, 4000 - own[3].x, "the other way round")
    -- a spiral grows every way, so a long one leaves the heights that fit, and the report says so
    local kinds = count_by(layout.report(as_nodes(layout.place("spiral", 40))), function(found) return found.kind end)
    t.ok((kinds["off-screen"] or 0) + (kinds["off-canvas"] or 0) > 0)
    t.raises(function() layout.place("spiral", 3, { turn = "up" }) end, "`turn` is \"right\" or \"left\"")
end)

t.test("tree: a node goes one step further than the last node it needs", function()
    local chain = { { id = "a" }, { id = "b", needs = { "a" } }, { id = "c", needs = { "b" } } }
    t.eq(spots(layout.place("tree", chain)), "500,850 1000,850 1500,850")
    local diamond = { { id = "a" }, { id = "b", needs = { "a" } }, { id = "c", needs = { "a" } }, { id = "d", needs = { "b", "c" } } }
    t.eq(spots(layout.place("tree", diamond)), "500,850 1000,675 1000,1025 1500,850")
    -- the longest way counts: d also needs a, and still comes after b and c
    diamond[4].needs = { "a", "b", "c" }
    t.eq(at(layout.place("tree", diamond)[4]), "1500,850")
    t.eq(spots(layout.place("tree", chain, { from = { 100, 400 }, step = { 300, 300 } })), "100,400 400,400 700,400")
    -- a node that needs something outside the list is placed as if it needed nothing
    t.eq(spots(layout.place("tree", { { id = "a", needs = { "elsewhere" } }, { id = "b", needs = { "a" } } })), "500,850 1000,850")
    -- a plain list of ids has no needs: every node is a root
    t.eq(spots(layout.place("tree", { "a", "b" })), "500,675 500,1025")
    -- needs as a described store writes them: one id, or the long form with any and all
    t.eq(spots(layout.place("tree", { { id = "a" }, { id = "b", needs = "a" } })), "500,850 1000,850")
    t.eq(spots(layout.place("tree", { { id = 1 }, { id = 2, needs = 1 } })), "500,850 1000,850")
    t.eq(spots(layout.place("tree", { { id = "a" }, { id = "b" }, { id = "c", needs = { any = "a", all = { "b" }, level = 3 } } })),
        "500,675 500,1025 1000,850")
    t.eq(spots(layout.place("tree", { { id = "a" }, { id = "b", needs = { level = 3 } } })), "500,675 500,1025", "a level is no parent")
    t.raises(function() layout.place("tree", { { id = "a" }, { id = "b", needs = true } }) end,
        "node 2 of the list: `needs` is an id, a list of ids, or a table with any and all, got boolean")
    t.raises(function() layout.place("grid", { { id = "a", needs = { "x", all = { "y" } } } }) end, "got a table with both a list and names")
end)

t.test("tree: a column too tall for the screen is drawn tighter, then split", function()
    local roots = {}
    for index = 1, 6 do roots[index] = { id = index } end
    t.eq(spots(layout.place("tree", roots)), "500,250 500,550 500,850 500,1150 500,1450 1000,850")
    -- the nodes after the split column move along with it
    roots[7] = { id = 7, needs = { 1 } }
    t.eq(at(layout.place("tree", roots)[7]), "1500,850")
    local many = {}
    for index = 1, 40 do many[index] = { id = index, needs = index > 20 and { index - 20 } or nil } end
    local places = layout.place("tree", many)
    for _, place in ipairs(places) do t.ok(place.y >= layout.TOP and place.y <= layout.BOTTOM, at(place)) end
    t.eq(#layout.report(as_nodes(places)), 0)
    -- with the mod author's own step the column is split and never drawn tighter
    t.eq(spots(layout.place("tree", roots, { step = { 500, 400 } })), "500,250 500,650 500,1050 500,1450 1000,650 1000,1050 1500,850")
end)

t.test("tree: downwards, round a middle, and with needs that go in a circle", function()
    local chain = { { id = "a" }, { id = "b", needs = { "a" } }, { id = "c", needs = { "a" } } }
    t.eq(spots(layout.place("tree", chain, { direction = "down" })), "500,250 500,550 850,550")
    local radial = layout.place("tree", { { id = "a" }, { id = "b", needs = { "a" } }, { id = "c", needs = { "a" } }, { id = "d", needs = { "a" } } },
        { direction = "radial" })
    t.eq(at(radial[1]), "860,850")
    t.eq(at(radial[2]), "860,490", "the first branch points up")
    for index = 2, 4 do t.ok(math.abs(apart(radial[index], radial[1]) - 360) <= 1, "node " .. index .. " is on the first ring") end
    t.eq(#layout.report(as_nodes(radial)), 0)
    local two = layout.place("tree", { { id = "a" }, { id = "b" } }, { direction = "radial", center = { 1000, 850 }, step = 400 })
    t.eq(spots(two), "1000,450 1000,1250", "with two roots nothing is in the middle")
    local circle = layout.place("tree", { { id = "a", needs = { "b" } }, { id = "b", needs = { "a" } }, { id = "c", needs = { "c" } } })
    t.eq(#circle, 3)
    t.raises(function() layout.place("tree", chain, { direction = "radial", from = { 1, 2 } }) end, "placed with `center`")
    t.raises(function() layout.place("tree", chain, { center = { 1, 2 } }) end, "`center` goes with direction = \"radial\"")
    t.raises(function() layout.place("tree", chain, { direction = "up" }) end, "`direction` is \"right\", \"down\" or \"radial\"")
end)

t.test("path and a function of the mod's own", function()
    local points = { { 500, 850 }, { 1500, 400 }, { 2500, 850 } }
    t.eq(spots(layout.place("path", 5, { points = points })), "500,850 1000,625 1500,400 2000,625 2500,850")
    t.eq(spots(layout.place("path", 1, { points = points })), "500,850")
    t.eq(spots(layout.place("path", 2, { points = { { 700, 700 } } })), "700,700 700,700")
    t.raises(function() layout.place("path", 3) end, "`points` is a list of places")
    local seen = {}
    local places = layout.place(function(index, id, count)
        seen[#seen + 1] = index .. ":" .. tostring(id) .. ":" .. count
        return 100 * index, 200.4
    end, { "Rope", "Fire" })
    t.eq(spots(places), "100,200 200,200")
    t.eq(table.concat(seen, " "), "1:Rope:2 2:Fire:2")
    t.eq(spots(layout.place(function(index) return { index, index } end, 2)), "1,1 2,2")
    local err = t.raises(function() layout.place(function() end, { "Rope" }) end, "the function gave no place for node 1 (Rope)")
    t.ok(tostring(err):find("It returns two numbers", 1, true))
end)

t.test("a wrong shape or option says what the right one is called", function()
    t.raises(function() layout.place("gird", 3) end, "the store has no shape named 'gird'. Did you mean 'grid'?")
    t.raises(function() layout.place("ring", 3, { radious = 3 }) end, "the shape \"ring\" has no option named 'radious'. Did you mean 'radius'?")
    t.raises(function() layout.place("line", 3, { from = "left" }) end, "`from` is two numbers such as { 500, 850 }")
    t.raises(function() layout.place("line", 3, { step = "far" }) end, "`step` is a number, got string")
    t.raises(function() layout.place("line", -1) end, "the number of nodes")
    t.raises(function() layout.place("line", "three") end, "the nodes to place are a number or a list")
    t.raises(function() layout.place("line", 3, "wide") end, "the options of a shape are a table")
    t.raises(function() layout.place(5, 3) end, "the store has no shape named '5'")
    for _, shape in ipairs(layout.SHAPES) do
        if shape ~= "path" then t.eq(#layout.place(shape, 4), 4, shape) end
    end
end)

t.test("a number that is endless, no number or far away is refused where it comes in", function()
    local huge, nan = math.huge, 0 / 0
    t.eq(layout.usable(layout.FAR), true)
    t.eq(layout.usable(-layout.FAR), true)
    for _, value in ipairs({ huge, -huge, nan, 1e19, layout.FAR + 1, "500", false }) do t.eq(layout.usable(value), false, tostring(value)) end
    local function refused(fragment, ...)
        local ok, err = bounded(layout.place, ...)
        t.eq(ok, false, fragment)
        t.ok(tostring(err):find(fragment, 1, true), ("expected %q, got %q"):format(fragment, tostring(err)))
    end
    -- a function of the mod's own: a division by nothing, and a number that is only very large
    for _, x in ipairs({ huge, -huge, nan, 1e19 }) do
        refused("the function gave no place for node 1 (Rope). It returns two numbers, each no further than 1000000 from 0",
            function() return x, 850 end, { "Rope" })
    end
    refused("the function gave no place for node 1 (1)", function(index, _, count) return 500 + 3000 * index / (count - 1), 850 end, 1)
    refused("the function gave no place for node 1 (1)", function() return { 500, huge } end, 1)
    -- an option of a named shape
    refused("`from` is two numbers no further than 1000000 from 0, got inf, 850", "line", 3, { from = { huge, 850 } })
    refused("`from` is two numbers no further than 1000000 from 0, got nan, 850", "line", 3, { from = { nan, 850 } })
    refused("`step` is a number no further than 1000000 from 0, got 1e+308", "line", 2, { step = 1e308 })
    refused("`step` is a number no further than 1000000 from 0, got inf", "line", 2, { step = huge })
    refused("`cell` is two numbers no further than 1000000 from 0, got inf, 300", "grid", 3, { cell = { huge, 300 } })
    refused("`cell` is a number no further than 1000000 from 0", "grid", 3, { cell = 1e308 })
    refused("`radius` is a number no further than 1000000 from 0", "ring", 3, { radius = 1e308 })
    refused("`radius` is two numbers no further than 1000000 from 0", "arc", 3, { radius = { 900, nan } })
    refused("`gap` is a number no further than 1000000 from 0", "spiral", 600, { gap = 1e308 })
    refused("`step` is two numbers no further than 1000000 from 0, got 500, inf", "tree", 3, { step = { 500, huge } })
    refused("`step` is a number no further than 1000000 from 0", "tree", 3, { direction = "radial", step = 1e308 })
    refused("`points` is two numbers no further than 1000000 from 0", "path", 3, { points = { { 500, 850 }, { 1e19, 400 } } })
    refused("`center` is two numbers no further than 1000000 from 0", "ring", 3, { center = { 0, -huge } })
    -- options that are each fine, and a place that is not: the third node of this line would be at 1800500
    refused("with these options node 3 of 3 gets no place. A place is two numbers, each no further than 1000000 from 0", "line", 3,
        { step = 900000 })
    -- and how many nodes
    refused("the number of nodes is a whole number from 0 to 10000, got 1000000000000", "line", 1e12)
    refused("the number of nodes is a whole number from 0 to 10000, got 2.5", "line", 2.5)
    t.eq(#layout.place("line", layout.MOST, { step = 1 }), layout.MOST)
end)

t.test("report: a node at a place that is no place is told, compared with nothing, and never waited on", function()
    for _, x in ipairs({ math.huge, -math.huge, 1e19, 3e18, 1e300, 0 / 0 }) do
        local ok, found = bounded(layout.report, { { id = "a", x = x, y = 850 }, { id = "b", x = 500, y = 850 }, { id = "c", x = 600, y = 850 } })
        t.ok(ok, tostring(found))
        t.eq(#found, 2, tostring(x))
        t.eq(found[1].kind .. " " .. found[1].a.id, "far a")
        t.eq(found[2].kind .. " " .. found[2].a.id .. " " .. found[2].b.id, "overlap b c", "the others are still compared")
    end
    local ok, found = bounded(layout.report, { { id = "a", x = 500, y = math.huge }, { id = "j", x = 0 / 0, y = 850, size = 0 } })
    t.ok(ok, tostring(found))
    t.eq(#found, 1, "a joint is left out wherever it is")
    t.eq(found[1].kind, "far")
    t.eq(#layout.report({ { id = "a", x = layout.FAR, y = 850 } }), 0, "the furthest place there is")
    -- the same through the checks, as a sentence
    local problems = check.list()
    check.placed(problems, { { id = "Rope", x = math.huge, y = 850 } }, "Kit")
    t.eq(problems.sorted()[1].Text, "Rope is at inf, 850. No place in the store is further than 1000000 from 0, 0, so it was compared with nothing.")
end)

t.test("report: what lies on what, what is too close, and what the screen does not show", function()
    local nodes = {
        { id = "a", x = 500, y = 850 }, { id = "b", x = 600, y = 900 },
        { id = "c", x = 1000, y = 850 }, { id = "d", x = 1280, y = 850 },
        { id = "e", x = 2000, y = 200 }, { id = "f", x = 60, y = 850 }, { id = "g", x = 3000, y = 1500 },
        { id = "joint", x = 500, y = 850, size = 0 }, { id = "h", x = 3000, y = 1200 },
    }
    local found = {}
    for _, finding in ipairs(layout.report(nodes)) do
        found[#found + 1] = finding.kind .. " " .. finding.a.id .. (finding.b and (" " .. finding.b.id) or "")
            .. (finding.distance and (" " .. finding.distance) or "")
    end
    t.eq(table.concat(found, " | "), "overlap a b | close c d 280 | off-screen e | off-canvas f | off-screen g")
    -- two nodes 300 apart along a diagonal lie on each other, though their middles are far enough apart
    local diagonal = layout.report({ { id = "a", x = 500, y = 500 }, { id = "b", x = 712, y = 712 } })
    t.eq(diagonal[1].kind, "overlap")
    -- a large category is looked at without comparing every node with every other
    local many = {}
    for index = 0, 2999 do many[#many + 1] = { id = index, x = 500 + (index % 600) * 350, y = 250 + (index // 600) * 300 } end
    t.eq(#layout.report(many), 0)
end)

t.test("crossings: a straight line that runs over another node", function()
    local a, m, b, n = { id = "a", x = 500, y = 850 }, { id = "m", x = 1000, y = 850 }, { id = "b", x = 1500, y = 850 }, { id = "n", x = 1000, y = 1300 }
    local joint = { id = "j", x = 750, y = 850, size = 0 }
    local found = layout.crossings({ a, m, b, n, joint }, { { from = a, to = b }, { from = a, to = n }, { from = a, to = m } })
    t.eq(#found, 1)
    t.eq(found[1].from.id .. found[1].to.id .. found[1].over.id, "abm")
end)

-- ---------------------------------------------------------------- the requirement graph

t.test("graph: what can ever be bought, with one-of, all-of and nodes that are free", function()
    local nodes = {
        a = { any = {}, all = {}, category = "two" },
        b = { any = { "a" } },
        c = { any = { "x", "b" } },
        d = { all = { "b", "c" } },
        e = { any = { "f" } }, f = { any = { "e" } },
        g = { any = { "g" } },
        h = { all = { "a", "e" } },
        i = { any = { "gone" } },
        j = { any = { "e" }, free = true },
        k = { any = { "a" }, category = "one" },
        l = { any = { "i", "h" } },
    }
    local order = { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l" }
    local found = graph.analyse(nodes, order)
    local reachable = {}
    for _, key in ipairs(order) do
        if found.reachable[key] then reachable[#reachable + 1] = key end
    end
    t.eq(table.concat(reachable), "abcdjk")
    t.eq(table.concat(found.unreachable), "efghil")
    t.eq(#found.circles, 2)
    local circles = {}
    for index, circle in ipairs(found.circles) do circles[index] = table.concat(circle, ">") end
    table.sort(circles)
    t.eq(table.concat(circles, " "), "e>f g")
    t.eq(found.cause.e.kind, "circle")
    t.eq(found.cause.g.kind, "circle")
    t.eq(found.cause.h.kind .. " " .. found.cause.h.parent, "behind e")
    t.eq(found.cause.i.kind .. " " .. found.cause.i.parent, "missing gone")
    t.eq(found.cause.l.kind .. " " .. found.cause.l.parent, "behind i")
    local missing = {}
    for index, gone in ipairs(found.missing) do missing[index] = gone.node .. ">" .. gone.parent end
    t.eq(table.concat(missing, " "), "c>x i>gone")
    t.eq(#found.cross, 1)
    t.eq(found.cross[1].node .. ">" .. found.cross[1].parent, "k>a")
end)

t.test("graph: a circle of three is walked once, and a long chain does not take long", function()
    local found = graph.analyse({ a = { any = { "b" } }, b = { all = { "c" } }, c = { any = { "a", "d" } }, d = { any = { "c" } } },
        { "a", "b", "c", "d" })
    t.eq(#found.circles, 1)
    t.eq(table.concat(found.circles[1], ">"), "a>b>c")
    t.eq(found.cause.d.kind, "circle", "d is part of the same knot")
    local nodes, order = {}, {}
    for index = 3000, 1, -1 do
        nodes[index] = { any = { index - 1 } }
        order[#order + 1] = index
    end
    local chain = graph.analyse(nodes, order)
    t.eq(#chain.unreachable, 3000, "the first needs a node that is not there")
    t.eq(#chain.circles, 0)
    nodes[1] = { any = {} }
    t.eq(#graph.analyse(nodes, order).unreachable, 0)
end)

-- ---------------------------------------------------------------- the game's own store, from its real rows

-- Rows that raise when a field is read that was not asked for, as game.Data would not have read it.
local function strict(provider)
    local asked = {}
    local function covered(path, fields)
        if path == "Name" then return true end
        for _, wanted in ipairs(fields) do
            if wanted == path or wanted:sub(1, #path + 1) == path .. "." or path:sub(1, #wanted + 1) == wanted .. "." then return true end
        end
        return false
    end
    local function guarded(value, fields, path, what)
        if type(value) ~= "table" then return value end
        return setmetatable({}, {
            __index = function(_, key)
                if type(key) == "number" then return guarded(value[key], fields, path, what) end
                local full = path == "" and key or (path .. "." .. key)
                if not covered(full, fields) then error(("%s.%s was read and never asked for"):format(what, full), 2) end
                return guarded(value[key], fields, full, what)
            end,
            __len = function() return #value end,
            __newindex = function(_, key) error(("%s.%s was written"):format(what, tostring(key)), 2) end,
        })
    end
    local rows = { names = provider.names }
    function rows.row(name, row, fields)
        local found = provider.row(name, row)
        if found == nil then return nil end
        asked[name] = asked[name] or {}
        asked[name][fold(row)] = true
        return guarded(found, fields or {}, "", name .. "." .. row)
    end
    -- how many different rows of a table were asked for
    function rows.asked(name)
        local count = 0
        for _ in pairs(asked[name] or {}) do count = count + 1 end
        return count
    end
    function rows.forget() asked = {} end
    return rows
end

local function new_store()
    local rows = strict(workshop.plain(dofile("wax/tests/offline/workshop_fixture.lua")))
    return workshop.reader(rows), rows
end

local store = new_store()

local ORDER = "Envirosuits Armor Backpacks Modules Gadgets Axes Pickaxes Knives Spears Sickles Hammers Bows Crossbows Firearms Deployables "
    .. "Farming Consumables Extraction Resources Resources_Refined Creatures Creature_Equipment Biolab"

t.test("reader: the 23 categories, in the game's order, read from two tables and nothing else", function()
    local fresh, rows = new_store()
    local categories = fresh.categories()
    local ids = {}
    for index, category in ipairs(categories) do ids[index] = category.Id:gsub("^Workshop_", "") end
    t.eq(table.concat(ids, " "), ORDER)
    t.eq(rows.asked("TalentArchetypes"), 74, "every category row is looked at once")
    t.eq(rows.asked("TalentTrees"), 85)
    t.eq(rows.asked("Talents"), 0, "the nodes are not looked at for this")
    local axes = fresh.category("WORKSHOP_axes")
    t.eq(axes.Id, "Workshop_Axes")
    t.eq(axes.Name, "Axes")
    t.eq(axes.Icon, "/Game/Assets/2DArt/UI/Icons/Icon_ContextChop.Icon_ContextChop")
    t.eq(axes.Tree, "Workshop_Axes")
    t.eq(axes.Background, "/Game/Assets/2DArt/UI/Windows/EmptyAsset.EmptyAsset")
    t.eq(axes.Level, 0)
    t.eq(fresh.category("Workshop_Armor").Tree, "Workshop_Armors", "a category and its tree need not share a name")
    t.eq(fresh.category("Blueprint_Crafting"), nil, "a category of the tech tree is not the store's")
    t.eq(fresh.category("Nothing"), nil)
    t.eq(fresh.category(12), nil)
    rows.forget()
    fresh.categories()
    t.eq(rows.asked("TalentArchetypes"), 0, "what was read is kept")
end)

t.test("reader: all 329 nodes, as the notes counted them in the game", function()
    local nodes = store.nodes()
    t.eq(#nodes, 329)
    local joints = count_by(nodes, function(node) return node.Joint and "joint" or "node" end)
    t.eq(joints.joint, 14)
    t.eq(joints.node, 315)
    local parents = count_by(nodes, function(node) return #node.Needs end)
    t.eq(parents[0], 127)
    t.eq(parents[1], 185)
    t.eq(parents[2], 15)
    t.eq(parents[3], 2)
    local lines = count_by(nodes, function(node) return node.Line or "unset" end)
    t.eq(lines.elbow, 135)
    t.eq(lines["elbow-down"], 72)
    t.eq(lines.unset, 122)
    t.eq(lines.straight, nil, "the game's store has no straight line")
    local flagged, kinds = 0, {}
    for _, node in ipairs(nodes) do
        if #node.Flags > 0 then flagged = flagged + 1 end
        for _, flag in ipairs(node.Flags) do kinds[flag.Kind] = (kinds[flag.Kind] or 0) + 1 end
    end
    t.eq(flagged, 21)
    t.eq(kinds.dlc, 17)
    t.eq(kinds.account, 5)
    local per = count_by(nodes, function(node) return node.Category end)
    t.eq(per.Workshop_Farming, 36)
    t.eq(per.Workshop_Resources_Refined, 1)
    t.eq(per.Workshop_Armor, 30, "the nodes of the tree Workshop_Armors belong to the category Workshop_Armor")
    for _, node in ipairs(nodes) do
        if node.Joint then
            t.eq(node.Size, 0, node.Id)
            t.eq(node.StoreItem, nil, node.Id)
            t.eq(next(node.Research), nil, node.Id)
        else
            t.eq(node.Size, 250, node.Id)
            t.ok(node.StoreItem and node.Gives and node.Item, node.Id .. " sells something")
            t.ok(node.Name and node.Name ~= "" and node.Icon, node.Id .. " has the item's name and picture")
            t.ok(next(node.Research) and next(node.Replicate), node.Id .. " has both prices")
        end
        t.eq(node.Level, 0, node.Id)
    end
    t.eq(#store.nodes("workshop_AXES"), 11)
    t.eq(#store.nodes("Nothing"), 0)
    -- with no category named: one category after the other as the store lists them, not the order of the table
    t.eq(nodes[1].Id, "Workshop_Envirosuit_1")
    local place, last = {}, 0
    for index, category in ipairs(store.categories()) do place[category.Id] = index end
    for _, node in ipairs(nodes) do
        t.ok(place[node.Category] >= last, node.Id .. " comes after a node of a later category")
        last = place[node.Category]
    end
    -- and inside a category the order of the table
    local axes, wanted = {}, {}
    for index, node in ipairs(store.nodes("Workshop_Axes")) do axes[index] = node.Id end
    for _, row in ipairs(dofile("wax/tests/offline/workshop_fixture.lua").Talents.rows) do
        local node = store.node(row[1])
        if node and node.Category == "Workshop_Axes" then wanted[#wanted + 1] = node.Id end
    end
    t.eq(table.concat(axes, " "), table.concat(wanted, " "))
end)

t.test("reader: single nodes say what the running game said of them", function()
    -- names and pictures as the live game answered them
    local first = store.node("Workshop_Envirosuit_1")
    t.eq(first.Gives, "Envirosuit_Tier3")
    t.eq(first.Name, "Xigo S5-X Envirosuit")
    t.eq(store.node("Workshop_Envirosuit_3").Name, "Xigo \"Duo\" S5 Envirosuit")
    t.eq(store.node("Workshop_Deluxe_Envirosuit").Name, "First Cohort Envirosuit")
    local axe = store.node("workshop_axe_PRINTED")
    t.eq(axe.Id, "Workshop_Axe_Printed", "the game's own spelling")
    t.eq(axe.Category, "Workshop_Axes")
    t.eq(axe.StoreItem, "Meta_Axe_Printed")
    t.eq(axe.Gives, "Meta_Axe_Printed")
    t.eq(axe.Item, "Meta_Axe_Printed")
    t.eq(axe.Name, "MXC Axe")
    t.eq(axe.Icon, "/Game/Assets/2DArt/UI/Items/Item_Icons/Tools/ITEM_Meta_Axe_Printed.ITEM_Meta_Axe_Printed")
    t.eq(axe.Research.Credits, 75)
    t.eq(axe.Replicate.Credits, 25)
    t.eq(axe.At.X .. "," .. axe.At.Y, "500,800")
    t.eq(math.type(axe.At.X), "integer")
    t.eq(axe.Line, "elbow")
    t.eq(axe.Free, false)
    local two = store.node("Workshop_Axe_Shengong_Charlie")
    t.eq(two.Research.Credits, 1000)
    t.eq(two.Research.Exotic1, 250)
    t.eq(table.concat(two.Needs, " "), "Workshop_Axe_Shengong_Beta Workshop_Axe_Shengong_Alpha")
    local seven = store.node("Workshop_Envirosuit_7")
    t.eq(table.concat(seven.Needs, " "), "Workshop_Envirosuit_5 Workshop_Envirosuit_3")
    t.eq(seven.At.X .. "," .. seven.At.Y, "1950,800")
    local joint = store.node("Workshop_Envirosuit_Reroute")
    t.eq(joint.Joint, true)
    t.eq(joint.Free, true)
    t.eq(#joint.Needs, 3)
    t.eq(joint.At.X .. "," .. joint.At.Y, "3000,800")
    t.eq(joint.Name, nil)
    local banana = store.node("Workshop_Seed_Banana")
    t.eq(banana.Flags[1].Id .. " " .. banana.Flags[1].Kind, "GrantedWorkshop_BananaPack account")
    t.eq(banana.Flags[2].Id .. " " .. banana.Flags[2].Kind, "Great_Hunts dlc")
    t.eq(banana.Line, nil)
    local free = store.node("Workshop_Deluxe_Envirosuit")
    t.eq(free.Research.Credits, 0, "a price of nothing is a price all the same")
    t.eq(free.Flags[1].Id, "Deluxe_Edition_Envirosuit")
    -- a parent the game does not have keeps the name its row gives
    t.eq(table.concat(store.node("Workshop_Sickle_Reroute").Needs, " "), "Workshop_Sickle_Shengong_02 Workshop_Sickle_Inaris_00")
    t.eq(store.node("Stone_Axe"), nil, "a node of the tech tree")
    t.eq(store.node("Nothing_At_All"), nil)
    t.eq(store.node(5), nil)
    t.eq(store.is_node("workshop_axe_printed"), "Workshop_Axe_Printed")
    t.eq(store.is_node("Stone_Axe"), nil)
end)

t.test("reader: one node is read without looking through the whole table", function()
    local fresh, rows = new_store()
    t.ok(fresh.node("Workshop_Envirosuit_7"))
    t.ok(rows.asked("Talents") <= 3, "rows of D_Talents asked for: " .. rows.asked("Talents"))
    t.eq(rows.asked("WorkshopItems"), 1)
    t.eq(rows.asked("ItemTemplate"), 1)
    t.eq(rows.asked("ItemsStatic"), 1)
    t.eq(rows.asked("Itemable"), 1)
    rows.forget()
    fresh.is_node("Workshop_Axe_Printed")
    t.eq(rows.asked("Talents"), 1)
    t.eq(rows.asked("WorkshopItems"), 0, "asking whether it is a node reads nothing of what it sells")
    rows.forget()
    t.eq(#fresh.nodes("Workshop_Axes"), 11)
    t.eq(rows.asked("Talents"), 369, "listing a category looks at every row once: the 329 of the store and the 40 others in these rows")
    rows.forget()
    t.eq(#fresh.nodes(), 329)
    t.eq(rows.asked("Talents"), 318, "and not again: only the 318 nodes that were not worked out yet are asked for")
    rows.forget()
    fresh.flush()
    fresh.nodes("Workshop_Axes")
    t.eq(rows.asked("Talents"), 369, "until what was read is dropped")
end)

t.test("reader: currencies, what a template is of, stack sizes and the rows it knows", function()
    local currencies = store.currencies()
    local ids = {}
    for index, currency in ipairs(currencies) do ids[index] = currency.Id end
    t.eq(table.concat(ids, " "), "Credits Exotic1 Refund Exotic_Red Biomass Exotic_Uranium Licence Biomass_Converter")
    t.eq(currencies[1].Name, "Ren")
    t.eq(currencies[1].Shown, true)
    t.eq(currencies[2].Name, "Exotics", "the mark in front of the name is left off")
    t.eq(currencies[3].Shown, false)
    t.eq(currencies[1].Icon, "/Game/Assets/2DArt/UI/Icons/Icon_RenCurrency.Icon_RenCurrency")
    t.eq(store.has("currency", "credits"), "Credits")
    t.eq(store.has("currency", "Credit"), nil)
    t.eq(store.has("template", "meta_cot_printed"), "Meta_Cot_Printed")
    t.eq(store.has("talent", "Stone_Axe"), "Stone_Axe")
    t.eq(store.has("node", "Stone_Axe"), nil)
    t.eq(store.has("flag", "GrantedWorkshop_BananaPack"), "GrantedWorkshop_BananaPack")
    t.eq(store.has("category", "Workshop_Axes"), "Workshop_Axes")
    t.eq(store.where("template"), "D_ItemTemplate")
    t.eq(store.where("talent"), "D_Talents")
    t.eq(store.template("Meta_Cot_Printed").item, "Meta_Cot_Printed")
    t.eq(store.template("Nothing"), nil)
    t.eq(store.stack("Meta_Cot_Printed"), 1)
    t.eq(store.stack("Nothing"), nil)
    t.eq(#store.names("category"), 23)
    t.eq(#store.names("node"), 329)
    t.eq(#store.names("currency"), 8)
    local item = store.store_item("meta_dog_a1")
    t.eq(item.row .. " " .. item.gives, "Meta_Dog_A1 Workshop_Dog_A1")
    t.eq(item.research.Credits .. " " .. item.research.Exotic1, "500 250")
end)

t.test("reader: what the game only sells to owners of a DLC", function()
    local gates = store.gates()
    t.eq(table.concat(gates.templates.workshop_dog_a1, " "), "Pet_Companions")
    t.eq(table.concat(gates.items.workshop_dog_a1, " "), "Pet_Companions")
    t.eq(table.concat(gates.templates.envirosuit_deluxe, " "), "Deluxe_Edition_Envirosuit")
    t.eq(table.concat(gates.templates.meta_banana_seed, " "), "Great_Hunts", "the account flag beside it is no DLC")
    local gated = 0
    for _ in pairs(gates.templates) do gated = gated + 1 end
    t.eq(gated, 17)
    t.eq(gates.templates.meta_axe_printed, nil)
end)

t.test("reader: what was worked out is dropped at once when the rows count a change", function()
    local plain, changes, level = workshop.plain(dofile("wax/tests/offline/workshop_fixture.lua")), 0, 0
    local rows = { names = plain.names, epoch = function() return changes end }
    function rows.row(name, row)
        local found = plain.row(name, row)
        if found and name == "Talents" and found.Name == "Workshop_Axe_Printed" then found.RequiredLevel = level end
        return found
    end
    local reader = workshop.reader(rows)
    t.eq(reader.node("Workshop_Axe_Printed").Level, 0)
    t.eq(#reader.nodes("Workshop_Axes"), 11)
    level = 5
    t.eq(reader.node("Workshop_Axe_Printed").Level, 0, "what was read is kept while the rows count no change")
    changes = changes + 1
    t.eq(reader.node("Workshop_Axe_Printed").Level, 5, "and is read again by the next call, with no frame in between")
    level, changes = 9, changes + 1
    local found = nil
    for _, node in ipairs(reader.nodes("Workshop_Axes")) do
        if node.Id == "Workshop_Axe_Printed" then found = node.Level end
    end
    t.eq(found, 9, "through a list as well")
    -- rows that count nothing, as the plain ones, are read once and kept
    local kept = workshop.reader({ names = plain.names, row = rows.row })
    t.eq(kept.node("Workshop_Axe_Printed").Level, 9)
    level = 1
    t.eq(kept.node("Workshop_Axe_Printed").Level, 9)
    kept.flush()
    t.eq(kept.node("Workshop_Axe_Printed").Level, 1)
end)

t.test("the game's own store has the loose ends the notes found, and no other", function()
    local problems = check.store(store)
    local found = codes(problems)
    t.eq(found["game-parent"], 1)
    t.eq(found["game-unsold"], 18)
    t.eq(found["off-screen"], 14)
    t.eq(#problems, 33)
    for _, problem in ipairs(problems) do t.eq(problem.Level, "warning", problem.Text) end
    local text, problem = text_of(problems, "game-parent")
    t.eq(text, "Workshop_Sickle_Reroute needs \"Workshop_Sickle_Shengong_02\", and the game has no node of that name.")
    t.eq(problem.Node, "Workshop_Sickle_Reroute")
    t.eq(problem.Category, "Workshop_Sickles")
    t.ok(text_of(problems, "game-unsold"):find("No node sells it.", 1, true))
    t.ok(text_of(problems, "off-screen"):find("Heights from 250 to 1450 are known to fit a 1080p screen", 1, true))
    -- nothing lies on anything, nothing is closer than the game's 300, every node can be bought, no circles
    t.eq(found.overlap, nil)
    t.eq(found.close, nil)
    t.eq(found.unreachable, nil)
    t.eq(found.circle, nil)
    t.eq(found["cross-category"], nil)
end)

-- ---------------------------------------------------------------- a store a mod describes

local function good()
    return {
        categories = {
            { id = "Kit", name = "Field Kit", icon = "/Game/Assets/2DArt/UI/Icons/Icon_Hammer.Icon_Hammer", nodes = {
                { id = "Fire", gives = "Meta_Campfire_Printed", research = { Credits = 120, Exotic1 = 10 }, replicate = { Credits = 30 } },
                { id = "Cot", gives = "meta_cot_printed", research = { Credits = 200 }, replicate = { Credits = 60 }, needs = "Fire" },
                { id = "Flask", gives = "Meta_Canteen_Shengong", research = { exotic1 = 50 }, replicate = { Credits = 40 }, needs = { "Fire", "Cot" } },
                { id = "Bundle", gives = { item = "Meta_Campfire_Printed", count = 3 }, needs = { all = { "Fire", "Cot" }, level = 10 }, line = "straight" },
                { id = "Dog", gives = "Workshop_Dog_A1", research = { Credits = 5 }, needs = "FLASK" },
            } },
            { into = "workshop_axes", nodes = {
                { id = "GoldAxe", gives = "Meta_Axe_Larkwell", research = { Exotic1 = 5 }, needs = "Workshop_Axe_Larkwell" },
                { id = "Other", gives = "Meta_Axe_Larkwell", needs = "fire" },
            } },
        },
    }
end

local function compile(described, mod)
    return spec.compile(described, store, { mod = mod == nil and "FieldKit" or mod or nil })
end

local function one(node, category)
    return { categories = { category or { id = "Kit", name = "Kit", nodes = { node } } } }
end

t.test("spec: a described store becomes a plan of rows named after the mod", function()
    local plan = compile(good())
    t.eq(plan.ok, true)
    t.eq(plan.mod, "FieldKit")
    t.eq(#plan.nodes, 7)
    local by = {}
    for _, node in ipairs(plan.nodes) do by[node.id] = node end
    t.eq(by.Fire.row, "FieldKit_Fire")
    t.eq(by.Fire.store_item, "FieldKit_Fire")
    t.eq(by.Fire.gives.template, "Meta_Campfire_Printed")
    t.eq(by.Fire.gives.item, "Meta_Campfire_Printed")
    t.eq(by.Fire.gives.new, nil, "a template the game has is used as it is")
    t.eq(by.Cot.gives.template, "Meta_Cot_Printed", "in the game's spelling")
    -- prices in the order the game lists its currencies
    t.eq(by.Fire.research[1].currency .. " " .. by.Fire.research[1].amount, "Credits 120")
    t.eq(by.Fire.research[2].currency .. " " .. by.Fire.research[2].amount, "Exotic1 10")
    t.eq(by.Flask.research[1].currency, "Exotic1")
    t.eq(#by.Bundle.research, 0, "no price is an empty list")
    -- needs: one id, a list (one of), the long form, another letter case, a node of the game's
    t.eq(table.concat(by.Cot.any, " "), "FieldKit_Fire")
    t.eq(table.concat(by.Flask.any, " "), "FieldKit_Fire FieldKit_Cot")
    t.eq(#by.Bundle.any, 0)
    t.eq(table.concat(by.Bundle.all, " "), "FieldKit_Fire FieldKit_Cot")
    t.eq(by.Bundle.level, 10)
    t.eq(table.concat(by.Dog.any, " "), "FieldKit_Flask")
    t.eq(table.concat(by.GoldAxe.any, " "), "Workshop_Axe_Larkwell")
    t.eq(table.concat(by.Other.any, " "), "FieldKit_Fire")
    -- an item and a count ask for a template row of the mod's own
    t.eq(by.Bundle.gives.new, true)
    t.eq(by.Bundle.gives.template, "FieldKit_Bundle")
    t.eq(by.Bundle.gives.item .. " x" .. by.Bundle.gives.count, "Meta_Campfire_Printed x3")
    t.eq(by.Bundle.line, "straight")
    t.eq(by.Fire.line, nil)
    t.eq(by.Fire.free, false)
    t.eq(by.Fire.size, 250)
    -- categories: a new one, and one of the game's
    local kit, axes = plan.categories[1], plan.categories[2]
    t.eq(kit.row .. " " .. kit.tree, "FieldKit_Kit FieldKit_Kit")
    t.eq(kit.new, true)
    t.eq(kit.name, "Field Kit")
    t.eq(kit.icon, "/Game/Assets/2DArt/UI/Icons/Icon_Hammer.Icon_Hammer")
    t.eq(kit.level, 0)
    t.eq(#kit.nodes, 5)
    t.eq(axes.row .. " " .. axes.tree, "Workshop_Axes Workshop_Axes")
    t.eq(axes.new, false)
    t.eq(by.GoldAxe.category, axes)
end)

t.test("spec: nodes without a place are laid out by what they need, beside what a game's category has", function()
    local plan = compile(good())
    local by = {}
    for _, node in ipairs(plan.nodes) do by[node.id] = at(node.at) end
    t.eq(by.Fire, "500,850")
    t.eq(by.Cot, "1000,850")
    t.eq(by.Flask, "1500,675")
    t.eq(by.Bundle, "1500,1025")
    t.eq(by.Dog, "2000,850")
    t.eq(by.GoldAxe, "4500,675", "the game's last axe is at 4000")
    t.eq(by.Other, "4500,1025")
    -- a place of the mod author's own is kept, and the rest is arranged round it
    local described = good()
    described.categories[1].nodes[1].at = { 600.4, 300 }
    described.categories[1].arrange = { shape = "grid", from = { 1000, 250 }, rows = 2 }
    local placed = compile(described)
    t.eq(at(placed.nodes[1].at), "600,300")
    t.eq(at(placed.nodes[2].at), "1000,250")
    t.eq(at(placed.nodes[3].at), "1350,250")
    t.eq(at(placed.nodes[4].at), "1000,550")
    -- a shape by name, and a function
    described.categories[1].arrange = "line"
    t.eq(at(compile(described).nodes[3].at), "850,850")
    local ids = {}
    described.categories[1].arrange = function(index, id)
        ids[#ids + 1] = id
        return 1000 * index, 850
    end
    t.eq(at(compile(described).nodes[5].at), "4000,850")
    t.eq(table.concat(ids, " "), "Cot Flask Bundle Dog", "the function is given the ids as the mod wrote them")
    -- in one of the game's categories a line and a grid start to its right as well, unless the mod says where
    described = good()
    described.categories[2].arrange = "grid"
    t.eq(at(compile(described).nodes[6].at), "4500,250")
    described.categories[2].arrange = { shape = "line", from = { 100, 1450 } }
    t.eq(at(compile(described).nodes[6].at), "100,1450")
    -- two entries into the same category of the game's: the later one starts to the right of the earlier one's nodes
    local twice = compile({ categories = {
        { into = "Workshop_Axes", nodes = { { id = "One", gives = "Meta_Cot_Printed" } } },
        { into = "workshop_axes", arrange = "line", nodes = { { id = "Two", gives = "Meta_Cot_Printed" }, { id = "Three", gives = "Meta_Cot_Printed" } } },
        { into = "Workshop_Axes", nodes = { { id = "Four", gives = "Meta_Cot_Printed", needs = "One" } } } } })
    local spots_of = {}
    for index, node in ipairs(twice.nodes) do spots_of[index] = at(node.at) end
    t.eq(table.concat(spots_of, " "), "4500,850 5000,850 5350,850 5850,850")
    t.eq(#twice.problems, 0, twice.problems[1] and twice.problems[1].Text)
    t.eq(#twice.categories, 3, "each entry stays an entry of the plan, with its own way of arranging")
end)

t.test("spec: what is unusual about a good store is said as a warning", function()
    local plan = compile(good())
    local order = {}
    for index, problem in ipairs(plan.problems) do
        order[index] = problem.Code
        t.eq(problem.Level, "warning", problem.Text)
    end
    t.eq(table.concat(order, " "), "dlc cross-category all-of stack line-through")
    local text, problem = text_of(plan.problems, "dlc")
    t.eq(text, "Dog sells what the game only sells to owners of Pet_Companions. The same rule is put on Dog, and it cannot be taken off.")
    t.eq(problem.Node, "Dog")
    t.eq(problem.Category, "Kit")
    -- and the rule is in the plan
    local dog = plan.nodes[5]
    t.eq(#dog.flags, 1)
    t.eq(dog.flags[1].row .. " " .. dog.flags[1].kind .. " " .. tostring(dog.flags[1].inherited), "Pet_Companions dlc true")
    t.eq(text_of(plan.problems, "cross-category"),
        "Other needs Fire, which is in another category (Kit). The game draws no line between categories, and nothing in its own store does this.")
    t.ok(text_of(plan.problems, "all-of"):find("Bundle needs all of Fire and Cot. The game itself only knows \"one of\"", 1, true))
    t.eq(text_of(plan.problems, "stack"), "Bundle gives 3 of Meta_Campfire_Printed, and one stack of it holds 1.")
    t.eq(text_of(plan.problems, "line-through"), "The straight line from Fire to Bundle runs through Cot.")
    -- the same item sold as an item and a count is gated all the same
    local gated = compile(one({ id = "Pup", gives = { item = "Workshop_Dog_A1" } }))
    t.eq(gated.nodes[1].flags[1].row, "Pet_Companions")
    t.eq(codes(gated.problems).dlc, 1)
end)

t.test("spec: a plan holds plain values, and nothing of what the mod wrote", function()
    local plan = compile(good())
    local seen = {}
    local function walk(value, where)
        local kind = type(value)
        t.ok(kind == "table" or kind == "string" or kind == "number" or kind == "boolean", where .. " is a " .. kind)
        if kind ~= "table" or seen[value] then return end
        seen[value] = true
        t.eq(getmetatable(value), nil, where .. " has no metatable")
        for key, inner in pairs(value) do walk(inner, where .. "." .. tostring(key)) end
    end
    walk(plan, "plan")
    for _, node in ipairs(plan.nodes) do t.eq(node.source, nil) end
    for _, category in ipairs(plan.categories) do t.eq(category.source, nil) end
end)

t.test("spec: ids, and the rows they would be", function()
    local problems = compile({ categories = { { id = "Kit", name = "Kit", nodes = {
        { id = "A", gives = "Meta_Cot_Printed" }, { id = "a", gives = "Meta_Cot_Printed" }, { id = "D d", gives = "Meta_Cot_Printed" },
        { gives = "Meta_Cot_Printed" }, "Fire", { id = 7, gives = "Meta_Cot_Printed" },
    } } } }).problems
    local found = codes(problems)
    t.eq(text_of(problems, "id-twice"), "Two nodes have the id a. Every id is used once in a mod, whatever the letter case.")
    t.eq(found["id-bad"], 2)
    t.eq(text_of(problems, "id-bad"), "The id 'D d' can only use letters, digits and _.")
    t.eq(text_of(problems, "id"), "Node 4 of category Kit needs an id, such as id = \"Rope\".")
    t.eq(text_of(problems, "node-shape"), "Node 5 of category Kit is not a table.")
    -- a row the game already has: the mod "Workshop" may not add an "Axe_Printed"
    local taken = compile(one({ id = "Axe_Printed", gives = "Meta_Cot_Printed" }, { id = "Axes", name = "More axes", nodes = {
        { id = "Axe_Printed", gives = "Meta_Cot_Printed" }, { id = "Other", gives = { item = "Meta_Cot_Printed" } } } }), "Workshop")
    local texts = {}
    for _, problem in ipairs(taken.problems) do
        if problem.Code == "id-taken" then texts[#texts + 1] = problem.Text end
    end
    t.eq(#texts, 3)
    t.eq(texts[1], "Category Axes would be the row Workshop_Axes, and D_TalentArchetypes already has a row of that name. Choose another id.")
    t.eq(texts[2], "Category Axes would be the row Workshop_Axes, and D_TalentTrees already has a row of that name. Choose another id.")
    t.eq(texts[3], "Axe_Printed would be the row Workshop_Axe_Printed, and D_Talents already has a row of that name. Choose another id.")
    t.eq(taken.ok, false)
    -- a store item and a template of that name count as well
    local item = compile(one({ id = "Axe_Printed", gives = { item = "Meta_Cot_Printed" } }), "Meta")
    t.eq(text_of(item.problems, "id-taken"),
        "Axe_Printed would be the row Meta_Axe_Printed, and D_WorkshopItems already has a row of that name. Choose another id.")
    t.eq(codes(item.problems)["id-taken"], 2, "D_ItemTemplate has a Meta_Axe_Printed too")
    -- a row name longer than game.Data takes for a row a mod adds: "FieldKit_" and 92 letters are 101
    local long_id = ("n"):rep(92)
    local long = compile(one({ id = long_id, gives = "Meta_Cot_Printed" }))
    t.eq(text_of(long.problems, "row-long"),
        ("%s would be the row FieldKit_%s, which is 101 characters long. A row name has at most 100. Choose a shorter id."):format(long_id, long_id))
    t.eq(long.ok, false)
    t.eq(compile(one({ id = ("n"):rep(91), gives = "Meta_Cot_Printed" })).ok, true, "100 characters are a row name")
    local wide = compile({ categories = { { id = ("c"):rep(92), name = "Kit", nodes = { { id = "A", gives = "Meta_Cot_Printed" } } } } })
    t.eq(codes(wide.problems)["row-long"], 1)
    t.ok(text_of(wide.problems, "row-long"):find("^Category c+ would be the row FieldKit_c+, which is 101 characters long%."))
    t.eq(compile({ categories = { { id = ("c"):rep(91), name = "Kit", nodes = { { id = "A", gives = "Meta_Cot_Printed" } } } } }).ok, true)
    -- the limit is game.Data's own, which is written in the module that adds rows
    local file = io.open("wax/runtime/Scripts/wax/data/patch.lua", "rb")
    if file then
        local limit = file:read("a"):match("MAX_NAME = (%d+)")
        file:close()
        t.ok(limit, "data/patch.lua no longer says MAX_NAME = a number. Compare its limit with workshop_spec.MAX_ROW and change this test")
        t.eq(tonumber(limit), spec.MAX_ROW)
    end
end)

t.test("spec: what a node gives", function()
    local function problem_of(gives)
        local plan = compile(one({ id = "A", gives = gives }))
        return plan.problems[1] and plan.problems[1].Code, plan.problems[1] and plan.problems[1].Text, plan
    end
    local code, text = problem_of("Meta_Campfire_Printd")
    t.eq(code, "gives-template")
    t.eq(text, "A gives \"Meta_Campfire_Printd\", but D_ItemTemplate has no row of that name. Did you mean 'Meta_Campfire_Printed'?")
    code, text = problem_of({ item = "Meta_Campfire_Printd" })
    t.eq(code, "gives-item")
    t.eq(text, "A gives the item \"Meta_Campfire_Printd\", but D_ItemsStatic has no row of that name. Did you mean 'Meta_Campfire_Printed'?")
    code, text = problem_of(nil)
    t.eq(code, "gives")
    t.eq(text, "A sells nothing. Say what it gives: gives = \"a row of D_ItemTemplate\", or gives = { item = \"a row of D_ItemsStatic\", count = 10 }.")
    t.eq(problem_of(12), "gives")
    t.eq(problem_of({ item = "Meta_Cot_Printed", count = 0 }), "count")
    t.eq(problem_of({ item = "Meta_Cot_Printed", count = 1.5 }), "count")
    t.eq(problem_of({ item = "Meta_Cot_Printed", count = "two" }), "count")
    code, text = problem_of({ item = "Meta_Cot_Printed", amount = 2 })
    t.eq(code, "key")
    t.ok(text:find("A: gives has no option named 'amount'.", 1, true), text)
    local _, _, plan = problem_of({ item = "Meta_Cot_Printed" })
    t.eq(plan.ok, true)
    t.eq(plan.nodes[1].gives.count, 1)
    -- the tables in these rows share their names, so the two "it is the other kind" cases get rows of their own
    local world = setmetatable({}, { __index = store })
    function world.has(kind, name)
        if kind == "item" and name == "Rope" then return "Rope" end
        if kind == "template" and name == "Rope_x10" then return "Rope_x10" end
        if (kind == "item" or kind == "template") and (name == "Rope" or name == "Rope_x10") then return nil end
        return store.has(kind, name)
    end
    local swapped = spec.compile({ categories = { { id = "Kit", name = "Kit", nodes = {
        { id = "A", gives = "Rope" }, { id = "B", gives = { item = "Rope_x10" } } } } } }, world, { mod = "FieldKit" }).problems
    t.eq(text_of(swapped, "gives-is-item"),
        "A gives \"Rope\", which is a row of D_ItemsStatic, not of D_ItemTemplate. Write gives = { item = \"Rope\" }.")
    t.eq(text_of(swapped, "gives-is-template"),
        "B gives the item \"Rope_x10\", which is a row of D_ItemTemplate, not of D_ItemsStatic. Write gives = \"Rope_x10\".")
end)

t.test("spec: prices", function()
    local function price(research, replicate)
        return compile(one({ id = "A", gives = "Meta_Cot_Printed", research = research, replicate = replicate })).problems
    end
    t.eq(text_of(price({ Credit = 5 }), "price-currency"),
        "A: the research price names the currency \"Credit\", and D_MetaCurrency has no row of that name. Did you mean 'Credits'?")
    t.eq(text_of(price(nil, { Credits = -5 }), "price-negative"), "A: the replicate price in Credits is -5. A price cannot be below 0.")
    t.eq(text_of(price({ Credits = 1.5 }), "price-amount"), "A: the research price in Credits is 1.5. A price is a whole number, such as 50.")
    -- what is no number is shown as it was written, so "50" does not read as if 50 were refused
    t.eq(text_of(price({ Credits = "50" }), "price-amount"), "A: the research price in Credits is \"50\". A price is a whole number, such as 50.")
    t.eq(text_of(price({ Credits = "many" }), "price-amount"), "A: the research price in Credits is \"many\". A price is a whole number, such as 50.")
    t.eq(text_of(price({ Credits = {} }), "price-amount"), "A: the research price in Credits is a table. A price is a whole number, such as 50.")
    t.eq(text_of(price({ Credits = true }), "price-amount"), "A: the research price in Credits is true. A price is a whole number, such as 50.")
    t.eq(text_of(price({ Credits = 0 / 0 }), "price-amount"), "A: the research price in Credits is nan. A price is a whole number, such as 50.")
    -- a number the game's field cannot hold is told as that, with the limit
    local large = "A: the research price in Credits is %s. The largest price the game can keep is 2147483647."
    t.eq(text_of(price({ Credits = 2147483648 }), "price-large"), large:format("2147483648"))
    t.eq(text_of(price({ Credits = 3e9 }), "price-large"), large:format("3000000000"))
    t.eq(text_of(price({ Credits = math.huge }), "price-large"), large:format("inf"))
    t.eq(codes(price({ Credits = 2 ^ 63 }))["price-large"], 1)
    t.eq(codes(price({ Credits = 2147483648 }))["price-amount"], nil)
    -- one currency written in two letter cases adds up, and the sum has the same limit
    t.eq(text_of(price({ Credits = 2000000000, credits = 2000000000 }), "price-large"), large:format("4000000000"))
    t.eq(codes(price({ Credits = 2147483647, credits = 1 }))["price-large"], 1)
    local summed = compile(one({ id = "A", gives = "Meta_Cot_Printed", research = { Credits = 20, credits = 30 } }))
    t.eq(summed.ok, true)
    t.eq(summed.nodes[1].research[1].currency .. " " .. summed.nodes[1].research[1].amount, "Credits 50")
    t.eq(codes(price(nil, { Credits = -3000000000 }))["price-negative"], 1, "below 0 is said first, however far below")
    t.eq(text_of(price(50), "price-shape"), "A: research is a price such as { Credits = 50 }: a currency and how many.")
    t.eq(codes(price({ 50 }))["price-shape"], 1)
    t.eq(#price({ Credits = 0 }, { Credits = 2147483647 }), 0)
    local three = price({ Credits = 1, Exotic1 = 2, Biomass = 3 })
    t.eq(three[1].Level, "warning")
    t.eq(three[1].Text, "A: the research price uses 3 currencies. Every price of the game's own store uses one or two.")
    -- 5.0 is a whole number too
    local plan = compile(one({ id = "A", gives = "Meta_Cot_Printed", research = { Credits = 5.0 } }))
    t.eq(math.type(plan.nodes[1].research[1].amount), "integer")
end)

t.test("spec: needs that name nothing, another tree, or go round in a circle", function()
    local problems = compile({ categories = { { id = "Kit", name = "Kit", nodes = {
        { id = "A", gives = "Meta_Cot_Printed", needs = "B" },
        { id = "B", gives = "Meta_Cot_Printed", needs = { "A" } },
        { id = "C", gives = "Meta_Cot_Printed", needs = { any = "Workshop_Axe_Printd" } },
        { id = "E", gives = "Meta_Cot_Printed", needs = "E" },
        { id = "F", gives = "Meta_Cot_Printed", needs = { "Stone_Axe" } },
        { id = "G", gives = "Meta_Cot_Printed", needs = { all = { "E" }, flags = { "GrantedWorkshop_BananaPak" } } },
        { id = "H", gives = "Meta_Cot_Printed", needs = { any = { "A" }, al = "x" } },
        { id = "I", gives = "Meta_Cot_Printed", needs = { "A", all = { "B" } } },
        { id = "J", gives = "Meta_Cot_Printed", needs = { level = -1 } },
        { id = "K", gives = "Meta_Cot_Printed", needs = 7 },
        { id = "L", gives = "Meta_Cot_Printed", needs = { { "A" } } },
        { id = "M", gives = "Meta_Cot_Printed", needs = { "Ki" } },
    } } } }).problems
    local found = codes(problems)
    t.eq(text_of(problems, "circle"), "These nodes wait for each other, so none of them can ever be bought: A needs B, B needs A.")
    t.eq(text_of(problems, "needs-itself"), "E needs itself, so it can never be bought.")
    t.eq(found.unreachable, 2, "G waits for E, and H for the two that wait for each other")
    t.ok(text_of(problems, "unreachable"):find("can never be bought, because it needs", 1, true))
    t.eq(text_of(problems, "needs-missing"),
        "C needs \"Workshop_Axe_Printd\", which is neither a node of this store nor one of the game's store. Did you mean 'Workshop_Axe_Printed'?")
    t.eq(found["needs-missing"], 2)
    t.eq(text_of(problems, "needs-foreign"),
        "F needs \"Stone_Axe\", which is a row of D_Talents but not a node of the store. The store could never count it as bought.")
    t.eq(text_of(problems, "flag"),
        "G asks for the flag \"GrantedWorkshop_BananaPak\", and D_AccountFlags has no row of that name. Did you mean 'GrantedWorkshop_BananaPack'?")
    t.eq(text_of(problems, "key"), "H: needs has no option named 'al'. Did you mean 'all'?")
    t.eq(found["needs-shape"], 3, "I mixes a list with names, K is a number, L holds a list")
    t.eq(text_of(problems, "level"), "J: level is a whole number of 0 or more.")
    -- a short id is suggested from this store's own ids too
    local _, short = text_of(problems, "needs-missing")
    t.eq(short.Node, "C")
    local last = nil
    for _, problem in ipairs(problems) do
        if problem.Code == "needs-missing" then last = problem.Text end
    end
    t.ok(last:find("M needs \"Ki\"", 1, true), last)
    -- a flag the game has goes into the plan as an account flag
    local plan = compile(one({ id = "A", gives = "Meta_Cot_Printed", needs = { flags = "grantedworkshop_bananapack", level = 5 } }))
    t.eq(plan.ok, true)
    t.eq(plan.nodes[1].flags[1].row .. " " .. plan.nodes[1].flags[1].kind, "GrantedWorkshop_BananaPack account")
    t.eq(plan.nodes[1].level, 5)
end)

t.test("spec: places, lines and switches", function()
    local function problem_of(fields)
        local node = { id = "A", gives = "Meta_Cot_Printed" }
        for key, value in pairs(fields) do node[key] = value end
        local plan = compile(one(node))
        return plan.problems[1] and plan.problems[1].Code, plan.problems[1] and plan.problems[1].Text
    end
    local code, text = problem_of({ at = "here" })
    t.eq(code, "at")
    t.eq(text, "A: at is the middle of the node, such as at = { 500, 850 }.")
    t.eq(problem_of({ at = { 500 } }), "at")
    code, text = problem_of({ line = "elbo" })
    t.eq(code, "line")
    t.eq(text, "A: line is \"elbow\", \"elbow-down\", \"straight\" or \"none\". Did you mean 'elbow' or 'elbow-down'?")
    t.eq(problem_of({ line = 3 }), "line")
    code, text = problem_of({ free = 1 })
    t.eq(code, "free")
    code, text = problem_of({ lin = "elbow" })
    t.eq(text, "A has no option named 'lin'. Did you mean 'line'?")
    t.eq(problem_of({ at = { 500, 850 }, line = "none", free = true }), nil)
    t.eq(compile(one({ id = "A", gives = "Meta_Cot_Printed", free = true })).nodes[1].free, true)
    -- a node outside what the screen shows, on another node, and too close to one
    local placed = compile({ categories = { { id = "Kit", name = "Kit", nodes = {
        { id = "A", gives = "Meta_Cot_Printed", at = { 500, 100 } }, { id = "B", gives = "Meta_Cot_Printed", at = { 500, 1500 } },
        { id = "C", gives = "Meta_Cot_Printed", at = { 1000, 850 } }, { id = "D", gives = "Meta_Cot_Printed", at = { 1100, 900 } },
        { id = "E", gives = "Meta_Cot_Printed", at = { 2000, 850 } }, { id = "F", gives = "Meta_Cot_Printed", at = { 2280, 850 } },
    } } } })
    t.eq(placed.ok, true, "none of it stops the store")
    t.eq(text_of(placed.problems, "off-canvas"), "A is at 500, 100, so part of it lies outside the store's canvas, which begins at 0, 0.")
    t.eq(text_of(placed.problems, "off-screen"),
        "B is at height 1500. Heights from 250 to 1450 are known to fit a 1080p screen, and the store pans sideways only.")
    t.eq(text_of(placed.problems, "overlap"), "C and D lie on top of each other, at 1000, 850 and at 1100, 900. A node is 250 wide and high.")
    t.eq(text_of(placed.problems, "close"), "E and F are 280 apart. In the game's own store the middles of two nodes are never closer than 300.")
    -- a node put on one of the game's own is told so, and two of the game's own are left alone
    local onto = compile(one(nil, { into = "Workshop_Axes", nodes = { { id = "A", gives = "Meta_Cot_Printed", at = { 500, 800 } } } }))
    t.eq(text_of(onto.problems, "overlap"), "Workshop_Axe_Printed and A lie on top of each other, at 500, 800 and at 500, 800. A node is 250 wide and high.")
    t.eq(#onto.problems, 1)
    -- a place that is endless or far away is an error with the limit in it, and the check ends
    for _, x in ipairs({ math.huge, -math.huge, 1e19, 1e300, 2000000 }) do
        local ok, plan = bounded(compile, one({ id = "A", gives = "Meta_Cot_Printed", at = { x, 850 } }))
        t.ok(ok, tostring(plan))
        t.eq(plan.problems[1].Code, "at-far", tostring(x))
        t.eq(plan.ok, false)
    end
    t.eq(text_of(compile(one({ id = "A", gives = "Meta_Cot_Printed", at = { 2000000, -850 } })).problems, "at-far"),
        "A: at is 2000000, -850. No place in the store is further than 1000000 from 0, 0.")
    t.eq(problem_of({ at = { 0 / 0, 850 } }), "at")
    t.eq(problem_of({ at = { 1000000, -1000000 } }), "off-canvas", "the furthest place there is, and no error")
    -- nodes of two entries into one category lie on one canvas: on each other, and under each other's lines
    local shared = compile({ categories = {
        { into = "Workshop_Axes", nodes = { { id = "One", gives = "Meta_Cot_Printed", at = { 60000, 850 } } } },
        { into = "workshop_axes", nodes = { { id = "Two", gives = "Meta_Cot_Printed", at = { 60000, 850 } } } } } })
    t.eq(text_of(shared.problems, "overlap"), "One and Two lie on top of each other, at 60000, 850 and at 60000, 850. A node is 250 wide and high.")
    t.eq(#shared.problems, 1)
    local across = compile({ categories = {
        { into = "Workshop_Axes", nodes = { { id = "A", gives = "Meta_Cot_Printed", at = { 60000, 850 } },
            { id = "B", gives = "Meta_Cot_Printed", at = { 60500, 850 } } } },
        { into = "Workshop_Axes", nodes = { { id = "C", gives = "Meta_Cot_Printed", at = { 61000, 850 }, needs = "A", line = "straight" } } } } })
    t.eq(text_of(across.problems, "line-through"), "The straight line from A to C runs through B.")
    t.eq(#across.problems, 1)
    -- two entries into two categories are still looked at each by itself
    local apart_ = compile({ categories = {
        { into = "Workshop_Axes", nodes = { { id = "One", gives = "Meta_Cot_Printed", at = { 60000, 850 } } } },
        { into = "Workshop_Knives", nodes = { { id = "Two", gives = "Meta_Cot_Printed", at = { 60000, 850 } } } } } })
    t.eq(#apart_.problems, 0, apart_.problems[1] and apart_.problems[1].Text)
end)

t.test("spec: categories", function()
    local function category(fields)
        local entry = { id = "Kit", name = "Kit", nodes = { { id = "A", gives = "Meta_Cot_Printed" } } }
        for key, value in pairs(fields) do
            if value == false then entry[key] = nil else entry[key] = value end
        end
        return compile({ categories = { entry } })
    end
    t.eq(text_of(category({ name = "" }).problems, "category-name"), "Category Kit needs a name to show, such as name = \"Field Kit\".")
    t.eq(text_of(category({ icon = 5 }).problems, "texture"),
        "Category Kit: icon is the path of a texture, such as \"/Game/Assets/2DArt/UI/Icons/Icon_Hammer.Icon_Hammer\".")
    t.eq(codes(category({ background = "Icon_Hammer" }).problems).texture, 1)
    t.eq(text_of(category({ level = -1 }).problems, "level"), "Category Kit: level is a whole number of 0 or more.")
    t.eq(category({ level = 20, background = "/Game/Assets/2DArt/UI/Windows/EmptyAsset.EmptyAsset" }).categories[1].level, 20)
    t.eq(text_of(category({ nodes = {} }).problems, "category-empty"), "Category Kit has no nodes, so it would show nothing.")
    t.eq(text_of(category({ into = "Workshop_Axes" }).problems, "category-kind"),
        "Category Kit needs either id and name, to add a category, or into, to add nodes to one of the game's. It cannot have both.")
    t.eq(codes(category({ id = false }).problems)["category-kind"], 1)
    t.eq(text_of(category({ id = "K it" }).problems, "id-bad"), "The id 'K it' can only use letters, digits and _.")
    t.eq(text_of(category({ colour = "red" }).problems, "key"), "Category Kit has no option named 'colour'.")
    t.eq(text_of(category({ arrange = "gird" }).problems, "arrange"), "Category Kit: the store has no shape named 'gird'. Did you mean 'grid'?")
    t.eq(text_of(category({ arrange = { shape = "ring", radious = 2 } }).problems, "arrange"),
        "Category Kit: the shape \"ring\" has no option named 'radious'. Did you mean 'radius'?")
    t.eq(text_of(category({ arrange = 5 }).problems, "arrange"),
        "Category Kit: arrange is the name of a shape, a function, or a table such as { shape = \"grid\", rows = 4 }.")
    t.eq(text_of(category({ arrange = function() error("no idea") end }).problems, "arrange"), "Category Kit: no idea.")
    -- `shape` in another spelling is told as that, and not as an option the default shape lacks
    for key, arrange in pairs({ Shape = { Shape = "grid" }, SHAPE = { SHAPE = "ring", radius = 400 }, shap = { shap = "grid", rows = 2 } }) do
        local problems = category({ arrange = arrange }).problems
        t.eq(#problems, 1, key)
        t.eq(problems[1].Text, ("Category Kit: arrange has no option named '%s'. Did you mean 'shape'?"):format(key))
    end
    t.ok(text_of(category({ arrange = { rows = 2 } }).problems, "arrange"):find("Category Kit: the shape \"tree\" has no option named 'rows'.", 1, true))
    t.eq(#category({ arrange = { shape = "grid", rows = 2 } }).problems, 0)
    -- what a shape cannot make a place of is the category's problem, in the shape's words
    t.eq(text_of(category({ arrange = function(index, _, count) return 500 + 3000 * index / (count - 1), 850 end }).problems, "arrange"),
        "Category Kit: the function gave no place for node 1 (A). It returns two numbers, each no further than 1000000 from 0.")
    t.eq(text_of(category({ arrange = { shape = "tree", step = { 500, 1 / 0 } } }).problems, "arrange"),
        "Category Kit: `step` is two numbers no further than 1000000 from 0, got 500, inf.")
    t.eq(text_of(category({ arrange = { shape = "line", step = 1e308 } }).problems, "arrange"),
        "Category Kit: `step` is a number no further than 1000000 from 0, got 1e+308.")
    local ok, far = bounded(category, { arrange = { shape = "line", from = { 1000000, 850 }, step = 1 }, nodes = {
        { id = "A", gives = "Meta_Cot_Printed" }, { id = "B", gives = "Meta_Cot_Printed" } } })
    t.ok(ok, tostring(far))
    t.eq(text_of(far.problems, "arrange"),
        "Category Kit: with these options node 2 of 2 gets no place. A place is two numbers, each no further than 1000000 from 0.")
    local missing = compile(one(nil, { into = "Workshop_Axs", nodes = { { id = "A", gives = "Meta_Cot_Printed" } } })).problems
    t.ok(text_of(missing, "category-missing"):find("The game's store has no category named 'Workshop_Axs'. Did you mean 'Workshop_Axes'", 1, true))
    local fixed = compile(one(nil, { into = "Workshop_Axes", name = "My axes", nodes = { { id = "A", gives = "Meta_Cot_Printed" } } })).problems
    t.eq(text_of(fixed, "category-fixed"), "Category Workshop_Axes is one of the game's, so it keeps its own name. Take name out.")
    local twice = compile({ categories = { { id = "Kit", name = "Kit", nodes = { { id = "A", gives = "Meta_Cot_Printed" } } },
        { id = "KIT", name = "Kit", nodes = { { id = "B", gives = "Meta_Cot_Printed" } } }, "third" } }).problems
    t.eq(text_of(twice, "category-twice"), "Two categories have the id KIT. Every id is used once in a mod, whatever the letter case.")
    t.eq(text_of(twice, "category-shape"), "Category 3 is not a table.")
end)

t.test("spec: the store as a whole", function()
    t.eq(compile(5).problems[1].Text, "A store is a table with a list named categories.")
    t.eq(compile({}).problems[1].Code, "spec")
    t.eq(compile({ categories = {} }).problems[1].Text, "The store has no categories. Add at least one to categories.")
    local none = compile(good(), false)
    t.eq(none.problems[1].Text, "The store does not say which mod it belongs to. Add mod = \"MyMod\": every row it adds is named after its mod.")
    t.eq(none.ok, false)
    t.eq(#none.nodes, 0)
    t.eq(compile(good(), "9lives").problems[1].Text, "The mod id '9lives' has to start with a letter and use only letters, digits and _.")
    -- an id that is the name of the calling mod's folder cannot be given differently, so the sentence says what to do about the folder
    local folder = spec.compile(good(), store, { mod = "my-store", folder = true })
    t.eq(#folder.problems, 1)
    t.eq(folder.problems[1].Code, "mod-folder")
    t.ok(folder.problems[1].Text:find("^This mod's folder is named 'my%-store'%. .+ Rename the folder%.$"), folder.problems[1].Text)
    t.eq(#folder.nodes, 0)
    t.eq(spec.compile(good(), store, { mod = "FieldKit", folder = true }).ok, true)
    -- every id the plan takes is its own row prefix by game.Data's rule for a row a mod adds, so the two name the same rows
    for _, id in ipairs({ "FieldKit", "a", "Mod_2", "x9_", "my-store", "9lives", "a.b", "my mod", "_Kit", "" }) do
        local plan = compile(good(), id)
        if plan.mod then
            t.eq((id:gsub("[^%w_]", "_")), id)
            t.eq(plan.nodes[1].row, id .. "_Fire")
        else
            t.eq(plan.problems[1].Code, "mod-bad", id)
        end
    end
    t.eq(compile(good(), "Mod_2").mod, "Mod_2")
    t.eq(compile(good(), "my-store").mod, nil)
    -- the store may name its mod itself
    local described = good()
    described.mod = "Camp"
    t.eq(spec.compile(described, store).nodes[1].row, "Camp_Fire")
    t.eq(spec.compile(described, store, { mod = "Other" }).nodes[1].row, "Other_Fire", "what the caller says counts first")
    described.catagories = 1
    t.eq(text_of(compile(described).problems, "key"), "The store has no option named 'catagories'. Did you mean 'categories'?")
    -- a very large store is told what it costs
    local nodes = {}
    for index = 1, 150 do nodes[index] = { id = "N" .. index, gives = "Meta_Cot_Printed" } end
    local large = compile(one(nil, { id = "Kit", name = "Kit", arrange = "grid", nodes = nodes }))
    t.eq(large.ok, true)
    t.eq(text_of(large.problems, "large"),
        "This store adds 150 nodes. The game makes a widget for every node at each change of map, so a very large store slows loading.")
    t.eq(#large.problems, 1, "and a grid of them fits the screen")
end)

t.test("every sentence a mod author reads is plain, and every kind of problem has one", function()
    -- the owner's list of unwanted words is in one file, which the public copy does not have
    local list = wording.unwanted()
    if list then
        t.ok(wording.complete(list), "the owner's list was read whole from " .. wording.SOURCE)
        t.eq(wording.listed("It adjusts the richness", list), nil, "a part of a longer word is no listed word")
        t.ok(wording.listed("A node of " .. list.words[1] .. " kind.", list), "the check finds a word of the list")
    else
        print("workshop: the list of unwanted words is not here, so only the marks were checked")
    end
    local sentences = 0
    for code, text in pairs(check.TEXT) do
        sentences = sentences + 1
        t.ok(text:find("[%.%?%)s]$") or code == "key" or code == "arrange", code .. " ends as a sentence: " .. text)
        t.ok(not text:find("!", 1, true) and not text:find("; ", 1, true), code .. " has no exclamation mark and no semicolon")
        if list then t.eq(wording.listed(text, list), nil, "the sentence for " .. code) end
        for index = 1, #text do t.ok(text:byte(index) < 128, code .. " is plain ASCII") end
    end
    t.ok(sentences >= 55, "the sentences were looked at (" .. sentences .. ")")
    local problems = check.list()
    t.raises(function() problems.error("no-such-code") end, "there is no text for the problem no-such-code")
    problems.warn("large", nil, 200.0)
    problems.error("needs-itself", { node = "A", category = "Kit" }, "A")
    local sorted = problems.sorted()
    t.eq(sorted[1].Code .. " " .. sorted[2].Code, "needs-itself large", "errors come first")
    t.ok(sorted[2].Text:find("adds 200 nodes", 1, true), "a number is written the way a person writes it")
    t.eq(sorted[1].Node .. " " .. sorted[1].Category, "A Kit")
    local errors, warnings = problems.count()
    t.eq(errors .. " " .. warnings, "1 1")
end)

-- ---------------------------------------------------------------- the command line's part that needs no game

t.test("command line: the store as a list", function()
    local lines = cli.list(store)
    t.eq(lines[1], "The store: 23 categories, 329 nodes")
    t.eq(#lines, 25)
    t.ok(lines[8]:find("^  Workshop_Axes%s+Axes%s+11 nodes$"), lines[8])
    t.ok(lines[22]:find("Refined Resources%s+1 node$"), lines[22])
    local axes = table.concat(cli.list(store, "workshop_axes"), "\n")
    t.ok(axes:find("Workshop_Axes (Axes): 11 nodes", 1, true))
    local printed = ("  %-34s %s\n"):format("Workshop_Axe_Printed", "MXC Axe")
        .. "      research 75 Credits   replicate 25 Credits   at 500, 800   line elbow\n"
    t.ok(axes:find(printed, 1, true), axes)
    t.ok(axes:find("research 1000 Credits, 250 Exotic1   replicate 750 Credits, 250 Exotic1", 1, true))
    t.ok(axes:find("needs one of Workshop_Axe_Shengong_Beta, Workshop_Axe_Shengong_Alpha", 1, true))
    local joint = ("  %-34s %s\n"):format("Workshop_Axe_Shengong_Reroute", "a joint: it shows nothing and passes its parents on")
        .. "      at 2250, 800\n      needs one of Workshop_Axe_Larkwell, Workshop_Axe_Inaris_Alpha"
    t.ok(axes:find(joint, 1, true), axes)
    local farming = table.concat(cli.list(store, "Workshop_Farming"), "\n")
    t.ok(farming:find("asks for GrantedWorkshop_BananaPack (account), Great_Hunts (dlc)", 1, true))
    local none, problem = cli.list(store, "Workshop_Axs")
    t.eq(none, nil)
    t.ok(problem:find("The store has no category named 'Workshop_Axs'. Did you mean 'Workshop_Axes'", 1, true), problem)
end)

t.test("command line: what is wrong, as lines", function()
    local lines, errors = cli.report("The game's own store", check.store(store))
    t.eq(lines[1], "The game's own store: 0 errors, 33 warnings")
    t.eq(errors, 0)
    t.eq(#lines, 35)
    t.ok(lines[3]:find("^  warning  "), lines[3])
    lines, errors = cli.report("store.lua", compile(one({ id = "A", gives = "Nothing" })).problems)
    t.eq(lines[1], "store.lua: 1 error, 0 warnings")
    t.eq(errors, 1)
    t.ok(lines[3]:find("^  error    A gives \"Nothing\""), lines[3])
    lines, errors = cli.report("store.lua", {})
    t.eq(lines[1], "store.lua: nothing wrong.")
    t.eq(errors, 0)
    -- an id taken from the folder the store file is in is told as the folder's name, one given with --mod as an id
    local from_folder = cli.options("my-store", "folder")
    t.eq(from_folder.mod .. " " .. tostring(from_folder.folder), "my-store true")
    t.eq(cli.options("my-store", "given").folder, false)
    t.eq(cli.options("", "folder").mod, nil)
    t.eq(cli.options("", "folder").folder, false)
    lines, errors = cli.report("store.lua", spec.compile(good(), store, from_folder).problems)
    t.eq(lines[1], "store.lua: 1 error, 0 warnings")
    t.ok(lines[3]:find("This mod's folder is named 'my-store'.", 1, true) and lines[3]:find("Rename the folder.", 1, true), lines[3])
    lines = cli.report("store.lua", spec.compile(good(), store, cli.options("my-store", "given")).problems)
    t.ok(lines[3]:find("The mod id 'my-store' has to start with a letter", 1, true), lines[3])
    -- two entries into one category, which the file's check once passed with both nodes on one place
    lines, errors = cli.report("store.lua", spec.compile({ categories = {
        { into = "Workshop_Axes", nodes = { { id = "One", gives = "Meta_Cot_Printed", at = { 60000, 850 } } } },
        { into = "Workshop_Axes", nodes = { { id = "Two", gives = "Meta_Cot_Printed", at = { 60000, 850 } } } } } }, store, cli.options("MyStore", "folder")).problems)
    t.eq(lines[1], "store.lua: 0 errors, 1 warning")
    t.ok(lines[3]:find("^  warning  One and Two lie on top of each other"), lines[3])
    local described, problem = cli.read("wax/tests/offline/no_such_store.lua")
    t.eq(described, nil)
    t.ok(problem:find("does not load", 1, true), problem)
    -- a file that stops with an error, here because it is a module of Wax and not a store
    described, problem = cli.read("wax/runtime/Scripts/wax/core/guard.lua")
    t.eq(described, nil)
    t.ok(problem:find("stopped with an error", 1, true), problem)
end)

-- ---------------------------------------------------------------- game.Workshop over a stand-in engine

local S, U, C = "/Script/Icarus.", "/Script/IcarusUtilities.", "/Script/CoreUObject."
tables.struct("/Script/Engine.TableRowBase", nil, {})
tables.struct(U .. "IcarusTableRowBase", "/Script/Engine.TableRowBase", { { "CachedHardReferences", "ArrayProperty", inner = "ObjectProperty" } })
tables.struct(U .. "RowHandle", nil, { { "DataTablePtr", "WeakObjectProperty" }, { "RowName", "NameProperty" }, { "DataTableName", "NameProperty" } })
for _, name in ipairs({ "TalentModels", "TalentArchetypes", "TalentTrees", "Talents", "TalentRanks", "ItemTemplate", "ItemsStatic", "Itemable",
    "MetaCurrency" }) do
    tables.struct(S .. name .. "RowHandle", U .. "RowHandle", {})
end
tables.struct(U .. "MultiRowHandle", nil, { { "RowName", "NameProperty" } })
tables.struct(S .. "FlagsMultiRowHandle", U .. "MultiRowHandle", { { "DataTableName", "EnumProperty" } })
tables.struct(C .. "Vector2D", nil, { { "X", "FloatProperty" }, { "Y", "FloatProperty" } })
tables.struct(S .. "TalentReward", nil, { { "GrantedStats", "MapProperty" },
    { "GrantedFlags", "ArrayProperty", inner = "StructProperty", struct = S .. "FlagsMultiRowHandle" } })
-- the live struct says "position" with a small p, and so do the rows
tables.struct(S .. "Talent", U .. "IcarusTableRowBase", {
    { "TalentType", "EnumProperty" }, { "DisplayName", "TextProperty" }, { "Description", "TextProperty" }, { "Icon", "SoftObjectProperty" },
    { "ExtraData", "StructProperty", struct = U .. "RowHandle" }, { "TalentTree", "StructProperty", struct = S .. "TalentTreesRowHandle" },
    { "position", "StructProperty", struct = C .. "Vector2D" }, { "Size", "StructProperty", struct = C .. "Vector2D" },
    { "Rewards", "ArrayProperty", inner = "StructProperty", struct = S .. "TalentReward" },
    { "RequiredTalents", "ArrayProperty", inner = "StructProperty", struct = S .. "TalentsRowHandle" },
    { "RequiredFlags", "ArrayProperty", inner = "StructProperty", struct = S .. "FlagsMultiRowHandle" },
    { "ForbiddenFlags", "ArrayProperty", inner = "StructProperty", struct = S .. "FlagsMultiRowHandle" },
    { "RequiredRank", "StructProperty", struct = S .. "TalentRanksRowHandle" }, { "RequiredLevel", "IntProperty" },
    { "bDefaultUnlocked", "BoolProperty" }, { "DrawMethodOverride", "EnumProperty" } })
tables.struct(S .. "TalentArchetype", U .. "IcarusTableRowBase", { { "Model", "StructProperty", struct = S .. "TalentModelsRowHandle" },
    { "DisplayName", "TextProperty" }, { "BackgroundTexture", "SoftObjectProperty" }, { "Icon", "SoftObjectProperty" },
    { "RequiredLevel", "IntProperty" } })
tables.struct(S .. "TalentTree", U .. "IcarusTableRowBase", { { "DisplayName", "TextProperty" }, { "BackgroundTexture", "SoftObjectProperty" },
    { "Icon", "SoftObjectProperty" }, { "Archetype", "StructProperty", struct = S .. "TalentArchetypesRowHandle" },
    { "FirstRank", "StructProperty", struct = S .. "TalentRanksRowHandle" }, { "RequiredLevel", "IntProperty" } })
tables.struct(S .. "WorkshopCost", nil, { { "Meta", "StructProperty", struct = S .. "MetaCurrencyRowHandle" }, { "Amount", "IntProperty" } })
tables.struct(S .. "WorkshopItem", U .. "IcarusTableRowBase", { { "Item", "StructProperty", struct = S .. "ItemTemplateRowHandle" },
    { "ResearchCost", "ArrayProperty", inner = "StructProperty", struct = S .. "WorkshopCost" },
    { "ReplicationCost", "ArrayProperty", inner = "StructProperty", struct = S .. "WorkshopCost" },
    { "RequiredMission", "StructProperty", struct = S .. "TalentsRowHandle" } })
tables.struct(S .. "ItemData", U .. "IcarusTableRowBase", { { "ItemStaticData", "StructProperty", struct = S .. "ItemsStaticRowHandle" },
    { "CachedStats", "MapProperty" }, { "DatabaseGUID", "StrProperty" } })
tables.struct(S .. "ItemStaticData", U .. "IcarusTableRowBase", { { "Itemable", "StructProperty", struct = S .. "ItemableRowHandle" },
    { "AdditionalStats", "MapProperty" } })
tables.struct(S .. "ItemableData", U .. "IcarusTableRowBase", { { "DisplayName", "TextProperty" }, { "Icon", "SoftObjectProperty" },
    { "Description", "TextProperty" }, { "Weight", "IntProperty" }, { "MaxStack", "IntProperty" } })
tables.struct(S .. "MetaCurrency", U .. "IcarusTableRowBase", { { "DisplayName", "TextProperty" }, { "Icon", "SoftObjectProperty" },
    { "Description", "TextProperty" }, { "DecoratorText", "StrProperty" }, { "bDisplayOnMainScreen", "BoolProperty" } })
tables.struct(S .. "AccountFlag", U .. "IcarusTableRowBase", { { "WorkshopUnlocks", "ArrayProperty", inner = "ObjectProperty" } })
tables.struct(S .. "DLCPackageData", U .. "IcarusTableRowBase", { { "DLCName", "TextProperty" } })

local STRUCTS = { TalentArchetypes = "TalentArchetype", TalentTrees = "TalentTree", Talents = "Talent", WorkshopItems = "WorkshopItem",
    ItemTemplate = "ItemData", ItemsStatic = "ItemStaticData", Itemable = "ItemableData", MetaCurrency = "MetaCurrency",
    AccountFlags = "AccountFlag", DLCPackageData = "DLCPackageData" }
do
    -- the same rows again, as tables of the stand-in engine: nothing is shared with the rows above
    local plain = workshop.plain(dofile("wax/tests/offline/workshop_fixture.lua"))
    for name, struct in pairs(STRUCTS) do
        local order, rows = plain.names(name), {}
        for _, row in ipairs(order) do rows[row] = plain.row(name, row) end
        tables.table(name, S .. struct, rows, order)
    end
    tables.fill(245)
end

instance.start()
game.start()
Wax.game = game.root
data.start()
workshop.start()
local Workshop = game.root.Workshop
tables.reset()

local now = 0
sched.clock = function() return now end

local function frames(count)
    for _ = 1, count do
        now = now + 1 / 60
        tables.next_frame()
        sched.step()
    end
end

-- Runs fn in a task and gives what it returned once it has ended.
local function in_task(fn)
    local got = nil
    sched.task.spawn(function() got = table.pack(fn()) end)
    for _ = 1, 20000 do
        if got then break end
        frames(1)
    end
    assert(got, "the task did not end")
    return table.unpack(got, 1, got.n)
end

local function errors() return #guard.errors() end
local function warnings() return log.since(0, { level = "warn", channel = "wax.workshop" }) end

local function clean()
    for _, name in ipairs({ "stale", "grown", "crashes", "misuse", "unknown_names", "never_reads", "misses" }) do
        t.eq(tables[name], 0, "the engine counted " .. name)
    end
end

t.test("engine: game.Workshop is read-only and says what it has", function()
    t.eq(rawget(game.root, "Workshop"), Workshop)
    t.eq(tostring(Workshop), "Workshop")
    local err = t.raises(function() return Workshop.GetNods end, "GetNods is not a member of game.Workshop.")
    t.ok(tostring(err):find("GetNodes", 1, true), tostring(err))
    t.raises(function() Workshop.Other = 1 end, "read-only")
    t.eq(tostring(Workshop.Layout), "Workshop.Layout")
    t.raises(function() return Workshop.Layout.Plac end, "Plac is not a member of game.Workshop.Layout. Did you mean 'Place'?")
    t.raises(function() Workshop.Layout.Other = 1 end, "read-only")
    -- nothing that buys, and nothing that changes a row
    for _, name in ipairs({ "Research", "Replicate", "Buy", "Unlock", "Define", "AddCategory", "Refresh" }) do
        t.raises(function() return Workshop[name] end, "is not a member of game.Workshop")
    end
end)

t.test("engine: at the title screen the store's tables are read, and there is no player to ask", function()
    t.eq(Workshop:IsReady(), false)
    local categories = Workshop:GetCategories()
    t.eq(#categories, 23)
    t.eq(categories[6].Id, "Workshop_Axes")
    t.eq(categories[6].Name, "Axes")
    t.eq(categories[6].Icon, "/Game/Assets/2DArt/UI/Icons/Icon_ContextChop.Icon_ContextChop")
    t.eq(tables.rows_asked, 74 + 85, "one look at each category and tree row")
    t.eq(Workshop:GetState("Workshop_Axe_Printed"), nil)
    t.eq(Workshop:GetBalance("Credits"), nil)
    t.eq(Workshop:GetBalance(), nil)
    t.eq(#warnings(), 0, "having no player is nothing to warn about")
    clean()
end)

t.test("engine: the same store as from the plain rows, field for field", function()
    local function same(got, want, where)
        t.eq(type(got), type(want), where)
        if type(want) ~= "table" then return t.eq(got, want, where) end
        for key, value in pairs(want) do same(got[key], value, where .. "." .. tostring(key)) end
        for key in pairs(got) do t.ok(want[key] ~= nil, where .. "." .. tostring(key) .. " is not in the plain store") end
    end
    tables.next_frame()
    same(Workshop:GetCategories(), store.categories(), "categories")
    same(Workshop:GetNodes("Workshop_Axes"), store.nodes("Workshop_Axes"), "axes")
    tables.next_frame()
    same(Workshop:GetNodes(), store.nodes(), "nodes")
    same(Workshop:GetCurrencies(), store.currencies(), "currencies")
    same(Workshop:GetNode("workshop_seed_BANANA"), store.node("Workshop_Seed_Banana"), "banana")
    t.eq(Workshop:GetNode("Stone_Axe"), nil)
    t.eq(Workshop:GetNode("Nothing_At_All"), nil)
    t.eq(tables.enum_reads > 0, true, "the node type and the line style are numbers the engine was asked for by name")
    t.eq(errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    clean()
end)

t.test("engine: what was read is kept, and what is handed out is the caller's own", function()
    tables.next_frame()
    local before = tables.touches
    local first, second = Workshop:GetNodes("Workshop_Axes"), Workshop:GetNodes("workshop_axes")
    Workshop:GetCategories()
    Workshop:GetNode("Workshop_Axe_Printed")
    Workshop:GetCurrencies()
    t.eq(tables.touches, before, "the engine was not asked again")
    t.ok(first ~= second and first[1] ~= second[1], "a new table each time")
    first[1].Research.Credits = 1
    first[1].Needs[1] = "Changed"
    t.eq(Workshop:GetNodes("Workshop_Axes")[1].Research.Credits, second[1].Research.Credits)
    t.eq(Workshop:GetNodes("Workshop_Axes")[1].Needs[1], second[1].Needs[1])
    -- every table inside a node is the caller's own as well
    local banana = Workshop:GetNode("Workshop_Seed_Banana")
    banana.Flags[1].Id, banana.At.X, banana.Replicate.Credits = "Changed", -1, -1
    banana.Flags[3] = { Id = "More" }
    local again = Workshop:GetNode("Workshop_Seed_Banana")
    t.eq(again.Flags[1].Id, "GrantedWorkshop_BananaPack")
    t.eq(#again.Flags, 2)
    t.ok(again.At.X ~= -1 and again.Replicate.Credits ~= -1)
    t.ok(again.Flags ~= banana.Flags and again.At ~= banana.At and again.Needs ~= banana.Needs and again.Research ~= banana.Research)
    clean()
end)

t.test("engine: a wrong name is an error that says the right one, at the caller's line", function()
    local err = t.raises(function() Workshop:GetNodes("Workshop_Axs") end, "the store has no category named 'Workshop_Axs'. Did you mean 'Workshop_Axes'")
    t.ok(tostring(err):find("workshop_test.lua:%d+: the store has no category"), tostring(err))
    t.raises(function() Workshop:GetBalance("Credit") end, "the game has no currency named 'Credit'. Did you mean 'Credits'?")
    t.raises(function() Workshop:GetNode(5) end, "game.Workshop:GetNode expects a node's row name such as \"Workshop_Axe_Printed\", got number")
    t.raises(function() Workshop:GetNode("") end, "got an empty text")
    t.raises(function() Workshop:GetState(nil) end, "game.Workshop:GetState expects a node's row name")
    t.raises(function() Workshop:GetNodes(7) end, "game.Workshop:GetNodes expects a category's row name such as \"Workshop_Axes\", got number")
    t.raises(function() Workshop:GetBalance(7) end, "game.Workshop:GetBalance expects a currency's row name such as \"Credits\", got number")
    t.eq(errors(), 0)
    clean()
end)

-- The player's side: a store model that follows the game's own rules over the nodes of the plain store.
local player = { bought = {}, spent = 0, asked = {}, calls = { buy = 0, wallet = 0 }, credits = 1200 }

local function key_of(handle, home)
    assert(type(handle) == "table" and getmetatable(handle) == nil, "a handle is a plain table")
    assert(type(handle.RowName) == "table" and handle.RowName.fname, "CRASH: a Lua string where the engine wants a name")
    assert(type(handle.DataTableName) == "table" and handle.DataTableName.fname == home, "the handle names its table")
    player.asked[#player.asked + 1] = handle.RowName.fname
    return fold(handle.RowName.fname)
end

local function counts(key, seen)
    local node = store.node(key)
    if not node or seen[key] then return false end
    if not node.Joint then return player.bought[key] == true end
    seen[key] = true
    for _, parent in ipairs(node.Needs) do
        if counts(fold(parent), seen) then return true end
    end
    return false
end

local function can(key)
    local node = store.node(key)
    if not node or node.Joint or player.bought[key] or #node.Flags > 0 then return false end
    if #node.Needs == 0 then return true end
    for _, parent in ipairs(node.Needs) do
        if counts(fold(parent), {}) then return true end
    end
    return false
end

local function new_player()
    local buy = function() player.calls.buy = player.calls.buy + 1 end
    local model = fake.object("WorkshopTalentModel", {
        GetSpentPoints = function() return player.spent end,
        GetAvailablePoints = function() return 500 - player.spent end,
        DoesModelContainTalent = function(_, handle) return store.node(key_of(handle, "D_Talents")) ~= nil and not player.elsewhere end,
        IsTalentUnlocked = function(_, handle) return counts(key_of(handle, "D_Talents"), {}) end,
        GetTalentRank = function(_, handle) return player.bought[key_of(handle, "D_Talents")] and 1 or 0 end,
        CanUnlockTalent = function(_, handle, rank, force)
            local key = key_of(handle, "D_Talents")
            assert(force == false, "the last argument stays false")
            assert(rank == (player.bought[key] and 2 or 1), "the rank asked for is the one after the current")
            return can(key)
        end,
        UnlockNextTalentRank = buy,
    })
    local resources = fake.array({ { MetaRow = "Credits", Count = player.credits }, { MetaRow = fake.name("Exotic1"), Count = 75 },
        { MetaRow = "Old_Currency", Count = 3 } })
    local profile = fake.object("OnlineProfileUser", { MetaResources = resources,
        Talents = fake.array({ { RowName = "Workshop_Axe_Printed", Rank = 1 } }) })
    local component = fake.object("WorkshopTalentController", { Model = model, UnlockNextTalentRank = buy })
    local state = fake.object("BP_IcarusPlayerState_C", { WorkshopTalentController = component, ActiveUserProfile = profile })
    local wallet = fake.object("PlayerDataComponent", {
        GetAvailableMetaResource = function(_, handle)
            player.calls.wallet = player.calls.wallet + 1
            return key_of(handle, "D_MetaCurrency") == "credits" and 1111 or 0
        end,
        Client_ResearchWorkshopItem = buy, Client_PurchaseWorkshopItem = buy, ClientOnly_PurchaseMetaItem = buy, ConvertCurrency = buy,
        ClientGrantMetaResource = buy, ClientConsumeMetaResource = buy,
    })
    fake.controller.PlayerState = state
    fake.controller.PlayerDataComponent = wallet
    player.model, player.resources, player.profile, player.component, player.state, player.wallet = model, resources, profile, component, state, wallet
    return player
end

fake.possess(nil)
rawset(fake.controller, "__class", fake.class("/Script/Icarus.IcarusPlayerController", fake.class("/Script/CoreUObject.Object")))

t.test("engine: a player whose state has no store, as at the title screen", function()
    fake.controller.PlayerState = fake.object("PlayerState", {})
    t.eq(Workshop:IsReady(), false)
    t.eq(Workshop:GetState("Workshop_Axe_Printed"), nil)
    t.eq(Workshop:GetBalance("Credits"), nil)
    t.eq(#warnings(), 0)
end)

t.test("engine: where a node stands is the game's own answer, asked with a handle the engine takes", function()
    new_player()
    player.bought = { workshop_axe_printed = true, workshop_axe_shengong_alpha = true }
    t.eq(Workshop:IsReady(), true)
    t.eq(Workshop:GetState("workshop_axe_PRINTED"), "bought")
    t.eq(player.asked[1], "Workshop_Axe_Printed", "the engine is given the name as the game spells it")
    t.eq(Workshop:GetState("Workshop_Axe_Shengong_Beta"), "available")
    t.eq(Workshop:GetState("Workshop_Axe_Shengong_Charlie"), "available", "one bought parent is enough")
    t.eq(Workshop:GetState("Workshop_Axe_Larkwell"), "locked")
    t.eq(Workshop:GetState("Workshop_Axe_Shengong_Reroute"), "locked", "a joint none of whose parents is bought")
    player.bought.workshop_axe_shengong_charlie, player.bought.workshop_axe_larkwell = true, true
    t.eq(Workshop:GetState("Workshop_Axe_Shengong_Reroute"), "bought", "a joint counts as the game counts it")
    t.eq(Workshop:GetState("Workshop_Axe_Shengong_Echo"), "available")
    t.eq(Workshop:GetState("Workshop_Creature_Dog_A1"), "locked", "the game says no while a DLC is missing")
    -- not the store's, not the game's, and not in this player's store
    player.asked = {}
    t.eq(Workshop:GetState("Stone_Axe"), nil)
    t.eq(Workshop:GetState("Nothing_At_All"), nil)
    t.eq(#player.asked, 0, "the engine is never asked about a name the store does not have")
    player.elsewhere = true
    t.eq(Workshop:GetState("Workshop_Axe_Printed"), nil)
    player.elsewhere = nil
    t.eq(player.calls.buy, 0)
    t.eq(errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    t.eq(#warnings(), 0, warnings()[1] and warnings()[1].message or "")
end)

t.test("engine: what the account holds is read from its profile, inside the list's length", function()
    t.eq(Workshop:GetBalance("credits"), 1200)
    t.eq(Workshop:GetBalance("Exotic1"), 75, "a name the engine hands out as its own kind of text")
    t.eq(Workshop:GetBalance("Biomass"), 0, "a currency the profile does not list")
    local all = Workshop:GetBalance()
    t.eq(all.Credits, 1200)
    t.eq(all.Exotic1, 75)
    t.eq(all.Licence, 0)
    t.eq(all.Old_Currency, nil, "only currencies the game has")
    t.eq(player.resources:GetArrayNum(), 3, "reading one past the end would have made the game's list longer")
    t.eq(player.calls.wallet, 0, "the wallet's own function is not called unless it is switched on")
    workshop.WALLET_CALL = true
    t.eq(Workshop:GetBalance("Credits"), 1111)
    t.eq(Workshop:GetBalance("Exotic1"), 0)
    t.eq(player.calls.wallet, 2)
    workshop.WALLET_CALL = false
    t.eq(Workshop:GetBalance("Credits"), 1200)
    t.eq(player.calls.buy, 0)
    t.eq(errors(), 0)
end)

t.test("engine: Changed costs nothing until something listens, then looks about twice a second", function()
    t.eq(sched.Frame.count, 0, "nothing runs each frame before anyone listens")
    local heard = {}
    local owner = scope.new("listener")
    scope.run(owner, function()
        Workshop.Changed:Connect(function(what) heard[#heard + 1] = what end)
    end)
    t.eq(sched.Frame.count, 1)
    frames(90)
    t.eq(#heard, 0, "nothing changed")
    player.spent = player.spent + 1
    fake.watch = {}
    frames(workshop.POLL_FRAMES)
    t.eq(table.concat(heard, " "), "player")
    t.ok((fake.watch.PlayerState or 0) <= 1, "the player's state was looked at once in those frames")
    t.ok((fake.watch.MetaResources or 0) <= 1)
    fake.watch = nil
    player.resources[1].Count = 900
    frames(workshop.POLL_FRAMES)
    t.eq(table.concat(heard, " "), "player player", "a balance changed")
    player.profile.Talents[2] = { RowName = "Workshop_Axe_Larkwell", Rank = 1 }
    frames(workshop.POLL_FRAMES)
    t.eq(#heard, 3, "something was researched")
    frames(workshop.POLL_FRAMES * 3)
    t.eq(#heard, 3)
    -- the store goes away with the map, and that is a change too
    local state = fake.controller.PlayerState
    fake.controller.PlayerState = fake.INVALID
    frames(workshop.POLL_FRAMES)
    t.eq(#heard, 4)
    fake.controller.PlayerState = state
    frames(workshop.POLL_FRAMES)
    t.eq(#heard, 5)
    -- the listener's mod is gone: the look each frame stops with it
    owner:destroy()
    frames(2)
    t.eq(sched.Frame.count, 0)
    t.eq(Workshop.Changed.count, 0)
    t.raises(function() Workshop.Changed:Connect("no") end, "Connect expects a function")
    t.eq(errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    t.eq(#warnings(), 0, warnings()[1] and warnings()[1].message or "")
end)

t.test("engine: when game.Data drops rows the store is read again, and listeners hear of it", function()
    local heard = {}
    local connection = Workshop.Changed:Connect(function(what) heard[#heard + 1] = what end)
    tables.next_frame()
    local before = tables.touches
    Workshop:GetNodes("Workshop_Axes")
    t.eq(tables.touches, before)
    game.root.Data:Flush()
    frames(1)
    t.eq(table.concat(heard, " "), "store")
    t.eq(#Workshop:GetNodes("Workshop_Axes"), 11)
    t.ok(tables.touches > before, "the rows were read again")
    -- a table that is not the store's leaves it alone
    data.api.Changed:Fire("ProcessorRecipes")
    t.eq(#heard, 1)
    data.api.Changed:Fire("D_Talents")
    t.eq(#heard, 2)
    connection:Disconnect()
    frames(1)
    t.eq(sched.Frame.count, 0)
    clean()
end)

t.test("engine: a read in the very frame game.Data forgot rows is not an old one", function()
    if type(data.epoch) ~= "number" then
        -- the count is data.tables' to keep: until it does, the store only learns of a change at the end of the frame
        print("workshop: data.tables counts no changes yet, so a read in the frame of a change was only tried on rows that do")
        return
    end
    tables.next_frame()
    Workshop:GetNodes("Workshop_Axes")
    local before = tables.touches
    game.root.Data:Flush()
    t.eq(#Workshop:GetNodes("Workshop_Axes"), 11)
    t.ok(tables.touches > before, "the rows were read again in the same frame")
    frames(1)
    clean()
end)

t.test("engine: the first Check of a store that gives something looks at every row of D_Talents once, and at no row of another tree twice", function()
    game.root.Data:Flush()
    frames(1)
    tables.next_frame()
    tables.asked = {}
    t.eq(#Workshop:Check(one({ id = "A", gives = "Meta_Cot_Printed" }), { mod = "FieldKit" }), 0)
    local all = game.root.Data:Table("Talents"):Count()
    local different, others, total = 0, 0, 0
    for name, times in pairs(tables.asked.Talents) do
        different, total = different + 1, total + times
        if not store.is_node(name) then
            others = others + 1
            t.eq(times, 1, name .. " is no node of the store, and a second look through the table would ask for it again")
        end
    end
    t.eq(different, all, "every row was looked at")
    t.eq(others, all - 329)
    t.ok(total <= all + 5 * 329, "D_Talents was asked for a row " .. total .. " times")
    -- and what that worked out is kept: the same check again asks for nothing
    tables.next_frame()
    local before = tables.touches
    t.eq(#Workshop:Check(one({ id = "A", gives = "Meta_Cot_Printed" }), { mod = "FieldKit" }), 0)
    t.eq(tables.touches, before, "the second check asked the engine nothing")
    clean()
end)

t.test("engine: Load reads the whole store a slice a frame, and is for a task", function()
    t.raises(function() Workshop:Load() end, "game.Workshop:Load can only be used inside a task")
    game.root.Data:Flush()
    frames(1)
    local started = sched.stats.frame
    local count = in_task(function() return Workshop:Load() end)
    t.eq(count, 329)
    t.ok(sched.stats.frame - started >= 329 // workshop.SLICE, "it took " .. (sched.stats.frame - started) .. " frames")
    tables.next_frame()
    local before = tables.touches
    t.eq(#Workshop:GetNodes(), 329)
    t.eq(#Workshop:GetCategories(), 23)
    t.eq(#Workshop:GetCurrencies(), 8)
    t.eq(tables.touches, before, "after Load nothing has to be read")
    t.eq(errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    clean()
end)

t.test("engine: after a map change nothing of the old player is touched", function()
    local old = { player.model, player.component, player.state, player.profile, player.resources, player.wallet }
    new_player()
    for _, object in ipairs(old) do rawset(object, "__freed", true) end
    game.root.MapChanged:Fire("Next")
    frames(2)
    t.eq(Workshop:IsReady(), true)
    t.eq(Workshop:GetState("Workshop_Axe_Printed"), "bought")
    t.eq(Workshop:GetBalance("Credits"), 1200)
    local heard = 0
    local connection = Workshop.Changed:Connect(function() heard = heard + 1 end)
    player.spent = player.spent + 1
    frames(workshop.POLL_FRAMES)
    t.eq(heard, 1)
    connection:Disconnect()
    frames(1)
    t.eq(fake.dead_touches, 0, fake.dead_where)
    t.eq(errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
    t.eq(#warnings(), 0, warnings()[1] and warnings()[1].message or "")
end)

t.test("engine: a call the game no longer answers gives nothing, is logged once, and breaks nothing", function()
    local props = rawget(player.model, "__props")
    local spent = props.GetSpentPoints
    props.GetSpentPoints = nil
    local heard = 0
    local connection = Workshop.Changed:Connect(function() heard = heard + 1 end)
    frames(workshop.POLL_FRAMES)
    player.resources[1].Count = 5
    frames(workshop.POLL_FRAMES)
    t.eq(heard, 1, "the account is still looked at")
    connection:Disconnect()
    frames(1)
    props.GetSpentPoints = spent
    local logged = warnings()
    t.eq(#logged, 1)
    t.ok(logged[1].message:find("looking at the store's points failed", 1, true), logged[1].message)
    -- the model stops answering about nodes
    local unlocked = props.IsTalentUnlocked
    props.IsTalentUnlocked = function() error("no such function") end
    t.eq(Workshop:GetState("Workshop_Axe_Printed"), nil)
    t.eq(Workshop:GetState("Workshop_Axe_Printed"), nil)
    props.IsTalentUnlocked = unlocked
    t.eq(#warnings(), 2, "each kind of failure is logged once")
    t.eq(Workshop:GetState("Workshop_Axe_Printed"), "bought")
    t.eq(errors(), 0)
end)

t.test("engine: Check names rows after the mod that calls it, and Layout answers as the shapes do", function()
    local described = { categories = { { id = "Axes", name = "More axes", nodes = { { id = "Axe_Printed", gives = "Meta_Cot_Printed" } } } } }
    -- mods as the loader has them: a mod is its id and the scope its code runs under
    local loaded = {}
    local function mod(id)
        loaded[id] = { id = id, scope = scope.new(id) }
        return loaded[id].scope
    end
    rawset(Wax, "mods", { get = function(id) return loaded[id] end })
    local mine = mod("Workshop")
    local problems = scope.run(mine, function() return Workshop:Check(described) end)
    t.eq(codes(problems)["id-taken"], 3)
    t.ok(text_of(problems, "id-taken"):find("would be the row Workshop_Axes", 1, true))
    -- the mod's code under a scope of its own is still the mod's, and a mod cannot pass for another
    problems = scope.run(scope.new("window", mine), function() return Workshop:Check(described, { mod = "FieldKit" }) end)
    t.eq(codes(problems)["id-taken"], 3)
    t.eq(#Workshop:Check(described, { mod = "FieldKit" }), 0)
    t.eq(Workshop:Check(described)[1].Code, "mod", "called by no mod, and told of none")
    -- a scope that only has a loaded mod's name is not that mod
    t.eq(scope.run(scope.new("Workshop"), function() return Workshop:Check(described) end)[1].Code, "mod")
    -- the command bar runs every line under a scope named console, which is no mod: the option counts there
    local console = scope.new("console")
    t.eq(codes(scope.run(console, function() return Workshop:Check(described, { mod = "Workshop" }) end))["id-taken"], 3)
    t.eq(scope.run(console, function() return Workshop:Check(described) end)[1].Code, "mod")
    t.eq(#scope.run(console, function() return Workshop:Check(described, { mod = "FieldKit" }) end), 0)
    t.eq(scope.run(console, function() return workshop.plan(described, { mod = "FieldKit" }) end).nodes[1].row, "FieldKit_Axe_Printed")
    described.mod = "Workshop"
    t.eq(codes(scope.run(console, function() return Workshop:Check(described) end))["id-taken"], 3, "the store's own word for its mod")
    t.eq(#scope.run(console, function() return Workshop:Check(described, { mod = "FieldKit" }) end), 0, "the option counts before it")
    described.mod = nil
    -- a loaded mod that is itself named console keeps its name, and the command bar beside it is still no mod
    local namesake = mod("console")
    t.eq(scope.run(namesake, function() return workshop.plan(described) end).mod, "console")
    t.eq(scope.run(console, function() return workshop.plan(described) end).mod, nil)
    -- a mod in a folder whose name cannot name rows is told to rename the folder, whatever it says its id is
    local refused = scope.run(mod("my-store"), function() return Workshop:Check(described, { mod = "MyStore" }) end)
    t.eq(#refused, 1)
    t.eq(refused[1].Code, "mod-folder")
    t.ok(refused[1].Text:find("This mod's folder is named 'my-store'.", 1, true), refused[1].Text)
    -- and from the command bar the same id is an id that was given
    t.eq(scope.run(console, function() return Workshop:Check(described, { mod = "my-store" }) end)[1].Code, "mod-bad")
    -- with no loader at all nobody is a mod, and the option is used
    rawset(Wax, "mods", nil)
    t.eq(#scope.run(scope.new("Workshop"), function() return Workshop:Check(described, { mod = "FieldKit" }) end), 0)
    -- an option in another spelling is told as that, and the store is not blamed for it
    t.raises(function() Workshop:Check(described, { Mod = "FieldKit" }) end, "Check has no option named 'Mod'. Did you mean 'mod'?")
    t.raises(function() Workshop:Check(described, { mod = "FieldKit", strict = true }) end, "Check has no option named 'strict'.")
    t.raises(function() Workshop:Check(described, "FieldKit") end, "the options are a table such as { mod = \"MyMod\" }")
    local plan = workshop.plan(described, { mod = "FieldKit" })
    t.eq(plan.ok, true)
    t.eq(plan.nodes[1].row, "FieldKit_Axe_Printed")
    -- the checks through the game's tables say what they said over the plain rows
    local live, plain = Workshop:Check(good(), { mod = "FieldKit" }), compile(good()).problems
    t.eq(#live, #plain)
    for index, problem in ipairs(plain) do t.eq(live[index].Text, problem.Text) end
    local places = Workshop.Layout:Place("grid", 3, { columns = 2 })
    t.eq(places[3].X .. "," .. places[3].Y, "500,550")
    t.eq(#Workshop.Layout:Place("tree", { { id = "a" }, { id = "b", needs = { "a" } } }), 2)
    t.raises(function() Workshop.Layout:Place("gird", 3) end, "the store has no shape named 'gird'. Did you mean 'grid'?")
    local found = Workshop.Layout:Check({ { X = 500, Y = 850 }, { X = 600, Y = 900, Id = "Rope" }, { X = 3000, Y = 100, Size = 0 }, { 5000, 1500 } })
    t.eq(#found, 2)
    t.eq(found[1].Text, "Place 1 and Rope lie on top of each other, at 500, 850 and at 600, 900. A node is 250 wide and high.")
    t.eq(found[2].Code, "off-screen")
    t.raises(function() Workshop.Layout:Check({ "here" }) end, "place 1 of the list is not two numbers")
    -- a wrong Size, no number and a place far away are told with the place they are of, and nothing waits on them
    t.raises(function() Workshop.Layout:Check({ { X = 500, Y = 850 }, { X = 600, Y = 900, Size = "250" } }) end,
        "place 2 of the list: Size is a number, 0 for a joint")
    t.raises(function() Workshop.Layout:Check({ { X = 500, Y = 850, Size = {} } }) end, "place 1 of the list: Size is a number, 0 for a joint")
    t.raises(function() Workshop.Layout:Check({ { X = 500, Y = 850, Size = 0 / 0 } }) end, "place 1 of the list: Size is a number, 0 for a joint")
    t.raises(function() Workshop.Layout:Check({ { X = 500, Y = 850, Size = false } }) end, "place 1 of the list: Size is a number, 0 for a joint")
    t.raises(function() Workshop.Layout:Check({ { X = 0 / 0, Y = 850 } }) end, "place 1 of the list is not two numbers")
    for _, x in ipairs({ math.huge, -math.huge, 1e19, 1e300 }) do
        local ok, err = bounded(Workshop.Layout.Check, Workshop.Layout, { { X = 500, Y = 850 }, { X = x, Y = 850 } })
        t.eq(ok, false, tostring(x))
        t.ok(tostring(err):find("place 2 of the list is further than 1000000 from 0, 0, and no place in the store is", 1, true), tostring(err))
    end
    t.eq(#Workshop.Layout:Check({ { X = 1000000, Y = 850 } }), 0)
    -- needs in the forms a described store takes give the same tree
    t.eq(Workshop.Layout:Place("tree", { { id = "a" }, { id = "b", needs = "a" } })[2].X, 1000)
    t.raises(function() Workshop.Layout:Place("tree", { { id = "a" }, { id = "b", needs = true } }) end, "`needs` is an id, a list of ids")
    t.raises(function() Workshop.Layout:Place("line", 3, { from = { 1 / 0, 850 } }) end, "`from` is two numbers no further than 1000000 from 0")
    t.eq(table.concat(Workshop.Layout:GetShapes(), " "), "line grid ring arc spiral tree path")
    local limits = Workshop.Layout:GetLimits()
    t.eq(limits.Size .. " " .. limits.Gap .. " " .. limits.Top .. " " .. limits.Bottom .. " " .. limits.Edge, "250 300 250 1450 125")
    t.eq(limits.Far, 1000000)
    clean()
end)

-- Everything the flags of a store decide, as lines: each flag of each node, then what is sold to owners of a DLC only.
local function flag_lines(reader)
    local out = {}
    for _, node in ipairs(reader.nodes()) do
        for index, flag in ipairs(node.Flags) do out[#out + 1] = ("%s %d %s %s"):format(node.Id, index, flag.Id, tostring(flag.Kind)) end
    end
    local flags, gates = #out, reader.gates()
    for _, kind in ipairs({ "templates", "items" }) do
        local lines = {}
        for key, list in pairs(gates[kind]) do lines[#lines + 1] = ("%s %s %s"):format(kind, key, table.concat(list, ",")) end
        table.sort(lines)
        table.move(lines, 1, #lines, #out + 1, out)
    end
    return out, flags
end

-- This one logs a warning, so it comes after the tests that count them.
t.test("reader: when the game does not say which table a flag is of, the tables say it, with the same answer", function()
    local direct, flags = flag_lines(store)
    t.eq(flags, 22)
    t.ok(#direct >= 22 + 17 + 17, "the lines of the direct read: " .. #direct)
    local before = #warnings()
    for _, mode in ipairs({ "raises", "nothing", "absent" }) do
        local source = dofile("wax/tests/offline/workshop_fixture.lua")
        if mode == "absent" then
            for _, row in ipairs(source.Talents.rows) do
                for _, flag in ipairs(row.RequiredFlags or {}) do flag.DataTableName = nil end
            end
        end
        local rows, asked = strict(workshop.plain(source)), 0
        local row = rows.row
        function rows.row(name, wanted, fields)
            if fields and fields[1] == "RequiredFlags.DataTableName" then
                asked = asked + 1
                if mode == "raises" then error("the game refused this read") end
                if mode == "nothing" then return nil end
            end
            return row(name, wanted, fields)
        end
        local lines = flag_lines(workshop.reader(rows))
        t.eq(table.concat(lines, "\n"), table.concat(direct, "\n"), mode)
        t.eq(asked, 21, mode .. ": the kind is asked for once for each node that has flags")
    end
    local logged = warnings()
    t.eq(#logged - before, 1, "a read the game refuses is logged, and once")
    t.ok(logged[#logged].message:find("reading which table a flag is of failed: ", 1, true), logged[#logged].message)
    t.ok(logged[#logged].message:find("the game refused this read", 1, true), logged[#logged].message)
end)

t.test("the words for a line style and the game's numbers for them go both ways", function()
    for _, word in ipairs(spec.LINES) do
        local number = workshop.line_number(word)
        t.ok(number > 0, word)
        t.eq(workshop.LINES[number], word)
    end
    local words = 0
    for _ in pairs(workshop.LINES) do words = words + 1 end
    t.eq(words, #spec.LINES, "no number without a word")
    t.eq(workshop.line_number("elbow"), 3)
    t.eq(workshop.line_number("sideways"), 0)
    t.eq(workshop.line_number(nil), 0)
end)

t.test("the list for the check against game updates has the store's part, with what the switches reach", function()
    local part = nil
    for _, entry in ipairs(assert(loadfile("wax/runtime/data/needs.lua"))()) do
        if entry.id == "workshop" then part = entry end
    end
    t.ok(part, "data/needs.lua has a part with the id workshop")
    t.eq(part.name, "Store")
    local function names(class, kind, name)
        for _, entry in ipairs(part.classes) do
            if entry.class == class then
                for _, known in ipairs(entry[kind] or {}) do
                    if known == name then return true end
                end
            end
        end
        return false
    end
    t.ok(names("/Script/Icarus.WorkshopTalentControllerComponent", "properties", "Model"))
    t.ok(names("/Script/Icarus.TalentModelInterface", "functions", "CanUnlockTalent"))
    t.eq(names("/Script/Icarus.TalentModelInterface", "functions", "NoSuchFunction"), false)
    -- the wallet's own function is behind a switch that ships off. Shipping it on means naming what it calls here, in the same change
    if WALLET_CALL then
        t.ok(names("/Script/Icarus.IcarusPlayerController", "properties", "PlayerDataComponent"), "the part names PlayerDataComponent")
        t.ok(names("/Script/Icarus.PlayerDataComponent", "functions", "GetAvailableMetaResource"), "the part names GetAvailableMetaResource")
    end
end)

t.test("nothing in the store's modules buys, or writes a row", function()
    t.eq(player.calls.buy, 0, "no function that spends was called")
    t.eq(tables.crashes, 0, "nothing was written to a table")
    local spending = { "UnlockNextTalentRank", "Client_ResearchWorkshopItem", "Client_PurchaseWorkshopItem", "PurchaseMetaItem",
        "GrantMetaResource", "ConsumeMetaResource", "ConvertCurrency", "AddRow", "RemoveRow", "ImportText", "RefreshConstants",
        "ForceRefresh" }
    for _, name in ipairs({ "workshop", "workshop_spec", "workshop_graph", "workshop_layout", "workshop_check" }) do
        local file = assert(io.open("wax/runtime/Scripts/wax/world/" .. name .. ".lua", "rb"))
        local text = file:read("a")
        file:close()
        for _, word in ipairs(spending) do t.ok(not text:find(word, 1, true), name .. ".lua names " .. word) end
    end
end)

t.finish("workshop")
